#!/bin/sh
set -e
# Mosaico installation script for macOS.
#
# The macOS counterpart of install.sh, reached through the platform bootstrap at
# https://get.mosaico.dev. It installs mosaicod (the Mosaico daemon) as a Podman
# container, together with an embedded PostgreSQL instance in a second container
# (or, if you already run PostgreSQL, pointed at that instead) and, unless
# --no-cleanup is given, the data retention routine in a third one
#
# In particular:
#
# - Do not run this inside a macOS virtual machine. Podman needs a Linux virtual
#   machine to run containers at all, so on a virtualised Mac that machine is a
#   guest inside a guest: nested virtualization, which most Mac hypervisors do
#   not expose to their guests, and which is unreliable where they do. Expect
#   `podman machine init` or `podman machine start` to fail, or the machine to
#   come up and behave erratically. Install on the host instead.
#
# Both are printed at the start of a run, so they are read before the install
# rather than after it.
#
# How this differs from the Linux installer
# ==============================================================================
#
# macOS cannot run Linux containers itself, so Podman runs them inside a Linux
# virtual machine of its own, a "podman machine". Everything below follows from
# that, and from macOS having launchd instead of systemd:
#
# - Needs no root. The virtual machine, the containers and every file this script
#   writes belong to the user running it, so there is no sudo anywhere and no
#   /var/lib. State lives in ~/.mosaico, commands in ~/.local/bin.
#
# - $HOME is the only shared filesystem. A podman machine mounts the user's home
#   directory into the virtual machine and nothing else, so a directory the
#   containers have to see (the local frame storage, the TLS material) has to
#   live under $HOME. A path outside it would silently become an empty directory
#   inside the virtual machine, which is why --fs-dir is rejected when it points
#   elsewhere.
#
# - launchd starts Mosaico at login, not at boot. A LaunchAgent is per-user and
#   runs in the user's session: the podman machine belongs to that user, so a
#   system-wide LaunchDaemon could not reach it. Mosaico therefore comes up when
#   you log in, and stops when the machine is stopped or the Mac shuts down.
#
# - Let's Encrypt is not available. Automatic issuance needs a public name
#   pointing at this host and port 443 reachable from the internet, which a
#   workstation does not have; and renewal on Linux is driven by certbot's
#   systemd timer, which does not exist here. --enable-tls therefore requires
#   --tls-cert and --tls-key, and renewal is manual: replace the two files and
#   restart the container.
#
# - Re-running recreates the containers. There is no unit file to rewrite, so a
#   changed setting is applied by removing and recreating them. No data is lost by
#   that: the database lives in a Podman volume and the frames in a directory
#   under $HOME, both of which outlive the containers.
#
# - No man page is installed. mosaico(7) documents the Linux layout (systemd
#   units, Quadlet, /var/lib/mosaico), none of which exists here, so installing
#   it would describe a machine you are not on. The layout of this installation
#   is printed at the end of the run and documented at https://docs.mosaico.dev.
#
# The script:
#
# - Installs podman with Homebrew if it is missing, and creates a podman machine
#   named `mosaico` if there is none.
# - Guides you through the configuration interactively, or runs fully
#   unattended when `-y` / `--yes` is given.
# - Generates a random PostgreSQL password on first run and reuses it on
#   subsequent runs, it is never printed to the terminal or the log. Only for the
#   embedded database: the credentials of an existing instance are asked for.
# - Installs a CLI wrapper at ~/.local/bin/mosaicod that forwards commands into
#   the running container, and copies itself to ~/.local/bin/mosaicoctl.
# - Installs a LaunchAgent that starts the virtual machine and the containers
#   when you log in.
#
# Source code is available at https://github.com/mosaico-labs/mosaico
#
# Usage
# ==============================================================================
#
# 1. download the script
#
#   $ curl -fsSL https://get.mosaico.dev -o install-mosaico.sh
#
# 2. verify the script's content
#
#   $ cat install-mosaico.sh
#
# 3. run the script with --dry-run to verify the steps it executes
#
#   $ sh install-mosaico.sh --dry-run
#
# 4. run the script. Do not use sudo: everything is installed for the current
#    user, and a root-owned podman machine would not be the one the CLI talks to.
#
#   $ sh install-mosaico.sh
#
# Paired options
# ==============================================================================
#
# Several options only make sense together. Each feature toggle has a set of
# dependent options:
#
#   --postgres external  requires  --pg-host, --pg-password
#   --store-backend obj  requires  --obj-endpoint, --obj-bucket,
#                                  --obj-access-key, --obj-secret-key
#   --store-backend fs   requires  --fs-dir (under $HOME)
#   --enable-tls         requires  --domain, --tls-cert, --tls-key
#
# In an interactive session you may pass any subset of a group: whatever is
# missing is asked for at the prompt. With -y the run aborts with a list of the
# missing options, unless they have a documented default.
#
# Passing a dependent option also turns its feature on, so
# `--domain mosaico.example.com` implies --enable-tls.
#
# Command-line options
# ==============================================================================
#
# Every option of the Linux installer is accepted with the same meaning, so that
# a command line can be moved between the two. The differences are noted below.
#
# -y, --yes
# Run unattended: never prompt, apply the documented defaults for anything not
# passed explicitly, and fail fast if a mandatory option is missing.
#
# --postgres <embedded|external>
# Where mosaicod keeps its metadata. `embedded` runs PostgreSQL in a container of
# its own, with a password this script generates: nothing has to exist
# beforehand. `external` uses a PostgreSQL instance you already run and creates
# no database container at all. Default: embedded.
#
# --pg-host <HOST>
# Host name or address of the existing instance. Required when --postgres is
# `external`. An IPv6 literal has to be given in brackets, as in [2001:db8::1].
#
# An instance running on this Mac is reached as host.containers.internal, which
# resolves to the virtual machine's gateway rather than to macOS itself, so a
# loopback --pg-host is rewritten to that name and warned about: PostgreSQL then
# has to listen on an address other than 127.0.0.1 and accept connections from
# the virtual machine. Passing the Mac's LAN address avoids the indirection.
#
# --pg-port <PORT>
# Port of the existing instance. Default: 5432.
#
# --pg-db <NAME>
# --pg-user <NAME>
# Database and role mosaicod connects as. Both have to exist already, and the
# role needs enough privilege to create mosaicod's schema on first start.
# Default: mosaico for both.
#
# --pg-password <PASSWORD>
# Password of that role. Required when --postgres is `external`; asked for
# without echo in an interactive session.
#
# --store-backend <fs|obj>
# Selects where dataset frames are stored. `fs` keeps them in a local directory
# (see --fs-dir), `obj` uses an S3-compatible object store. Default: fs.
#
# --fs-dir <PATH>
# Directory used when --store-backend is `fs`. It has to be under $HOME, since
# that is the only part of this Mac the containers can see.
# Default: ~/.mosaico/storage.
#
# --obj-endpoint <URL>
# --obj-bucket <NAME>
# --obj-access-key <KEY>
# --obj-secret-key <SECRET>
# Object store endpoint, bucket and credentials. The endpoint and both keys are
# required when --store-backend is `obj`; the bucket defaults to mosaico.
#
# --enable-tls
# Serves gRPC over TLS. Unlike on Linux, no certificate is obtained for you:
# --tls-cert, --tls-key and --domain are all required. Default: disabled.
#
# --tls-cert <PATH>
# --tls-key <PATH>
# Paths of the PEM-encoded certificate chain and of its private key. They may
# live anywhere on this Mac: both are copied into ~/.mosaico/secrets/tls/, which
# is what the container mounts. To install a renewed certificate, replace those
# two copies and restart the container.
#
# --domain <FQDN>
# Name the certificate is issued for, and therefore the name clients have to
# connect to for validation to succeed. Required with --enable-tls.
#
# --api-key
# Creates a master API key on first run, stores it in
# ~/.mosaico/secrets/master_api_key and prints it once at the end. It also starts
# the daemon with API key enforcement, so every client then needs a key.
# Default: disabled with -y, asked for (and suggested) in an interactive session.
#
# The key is created with `read|write|delete`, which since 0.6 is the whole set:
# the `manage` permission was removed in favour of granular ones. Managing keys is
# not a permission any more either: `mosaicod api-key` reaches the database
# directly, so it is running that command in the container that grants it.
#
# --no-cleanup
# Turns off the automated data retention routine that prunes obsolete store
# files. The routine runs by default. Since 0.6 it is a mosaicod subcommand of its
# own rather than a thread inside the daemon, so declining it simply means no
# mosaico-cleanup container is created, and re-running the installer with this
# flag removes one left by an earlier run.
# See https://docs.mosaico.dev/config/cleanup
#
# --cleanup-retention <DURATION>
# How long obsolete files are kept, for example 7d or 30d. Becomes
# --retention-duration on the cleanup container; omitted when not given, so that
# the subcommand applies its own default.
#
# --cleanup-time-interval <DURATION>
# How often the routine runs. Becomes --time-interval on the cleanup container.
# Unlike the retention it is never omitted: the subcommand reads a missing interval
# as "clean once and exit", which for a container created with --restart=always
# means restarting forever, so an unset value becomes one day.
# See CLEANUP_DEFAULT_INTERVAL_SECONDS.
#
# --sdk
# Installs the mosaicolabs Python SDK into a virtual environment at
# ~/.mosaico/sdk, created with the python3 on your PATH (installed with Homebrew
# if missing). Not /opt/mosaico as on Linux: that would need root. The SDK needs
# Python 3.10 or newer. Activate it with `. ~/.mosaico/sdk/bin/activate`.
#
# --ai
# Installs Mosaico's skills for AI coding assistants into two folders of your
# home, always both: ~/.claude/skills, read by Claude Code, and ~/.agents/skills,
# the shared folder read by Codex, GitHub Copilot, Cursor and Gemini CLI. They
# come from the .agents/skills folder of https://github.com/mosaico-labs/mosaico,
# at the one commit this installer pins (AI_SKILLS_REF), downloaded over HTTPS
# and checked against the hash of their content (AI_SKILLS_SHA256): on a
# mismatch nothing is installed, nor when the skills folder holds anything but
# directories and regular files. Until the skills are released no commit is
# pinned, and --ai says so and installs nothing, the rest of the installation
# going on. They are written for Mosaico 0.8 or newer (AI_MIN_MOSAICO_VERSION):
# for an older version they are skipped with a warning, the rest of the
# installation going on (--ai alone refuses it when MOSAICO_VERSION is set),
# and a version that is not a release number (latest, a commit sha, even one of
# digits alone) is let through with a warning. They are copied as they are.
# Every file written is recorded with its hash in ~/.mosaico/ai-manifest: a
# re-run updates them and deletes those Mosaico no longer ships, but leaves
# alone, with a warning, any file changed since, and any it did not write.
# The vendor documentation behind each folder is cited in mosaico.7, in the
# repository of this script. Default: not installed.
#
# --ai alone
# Given with no option that installs Mosaico (--dry-run aside; --version and -y
# are such options, so --ai --version 0.8.0 installs Mosaico 0.8.0 and the
# skills, and -y --ai Mosaico with its defaults and the skills), --ai installs
# the skills and nothing else: no daemon, no Podman, no prompt, so they can be
# added for a Mosaico that is already installed, or that runs on another
# machine: sh install-mosaico.sh --ai. The version check above applies only
# when MOSAICO_VERSION is set in the environment, as in
# MOSAICO_VERSION=0.8.0 sh install-mosaico.sh --ai. Otherwise a note says what
# the skills are for. A download, an unpack or a check that fails makes it exit
# 1, where a full installation only warns; skills not released yet exit 0.
#
# --ai --remove
# Deletes the files listed in ~/.mosaico/ai-manifest whose content is still the
# one installed, then the manifest, and does nothing else: Mosaico itself is
# removed with --uninstall, which in turn leaves these files alone: the two are
# separate runs, and --ai together with --uninstall is refused.
#
# --version <VERSION>
# Image tag to install. The default is 0.6.0-rc.
# Anything below 0.6 is refused outright rather than installed.
# `latest` is accepted as given, and so is a commit sha
# (`sha-<hex>`, or the bare hex): neither can be resolved to a number without
# pulling the image, so both are taken on trust and not checked at all. Any other
# tag is refused, a branch name being the case in point: it says nothing about the
# release behind it and moves under the installation.
# See DEFAULT_MOSAICO_VERSION and MIN_MOSAICO_VERSION.
#
# --port <PORT>
# Port mosaicod serves gRPC on, published on this Mac under the same number.
# Asked for in an interactive session and defaulted to 6726 otherwise, which is
# mosaicod's own default and what the SDK and the published examples assume;
# change it when something else already holds that port. Not to be confused with
# --pg-port, which is the database's.
#
# --host <ADDRESS>
# Address of this Mac the port above is published on. Default: 127.0.0.1, which
# keeps Mosaico reachable from this Mac alone. Pass 0.0.0.0 to publish it on every
# address, so that other machines on the network can reach it, or a single address
# to publish it on one interface only. An IPv6 literal has to be given in
# brackets, as in [::1]. Not to be confused with --pg-host, which is the
# database's.
#
# This is the host side of the port publication and nothing else: inside the
# container mosaicod always binds 0.0.0.0, because a published port is DNAT'd to
# the container's own address, which a process listening on the container's
# loopback never sees. See run_mosaicod.
#
# --platform <PLATFORM>
# Passed to `podman run` as --platform for the mosaicod container, for example
# linux/amd64. Only useful on Apple Silicon and only when the tag being installed
# has no arm64 image: the pull then fails, and this is the way to run the amd64
# one under emulation. Default: unset, so Podman picks the machine's own
# architecture.
#
# --machine <NAME>
# Podman machine to use, created if it does not exist. Default: mosaico. Pass the
# name of your existing machine to install into that one instead.
#
# --bin-dir <PATH>
# Where the mosaicod and mosaicoctl commands are written.
# Default: ~/.local/bin, which needs no root. The script says so when that
# directory is not on your PATH.
#
# --uninstall
# Stops and removes the containers, the LaunchAgent and the installed commands,
# leaving stored data (the database volume, the frames, the secrets) in place.
# The podman machine is left alone as well, since it may hold other containers;
# the command to remove it is printed at the end.
#
# --dry-run
# Prints every command this script would run, without running any of them or
# changing anything.
#
# Environment variables
# ==============================================================================
#
# NON_INTERACTIVE          Same as --yes.
# MOSAICO_VERSION          Sets the version like --version, but does not by
#                          itself install Mosaico: with --ai alone, it is the
#                          version the skills are checked against.
# MOSAICO_AI_SOURCE        A local .agents folder, holding skills/,
#                          for --ai to install from instead of the download.
#                          Meant for testing: it is not checked against
#                          AI_SKILLS_SHA256, with a warning.
# MOSAICO_MACHINE_CPUS     CPUs of a machine created by this script. Default: 2.
# MOSAICO_MACHINE_MEMORY   Its memory in MB. Default: 4096.
# MOSAICO_MACHINE_DISK     Its disk size in GB. Default: 20.
#
# ==============================================================================

SCRIPT_VERSION="1.1.0"

# --- Configuration ---

# Under $HOME, since that is the only directory the podman machine mounts, and
# without a space in the path: it is bind-mounted and quoted through several
# layers of shell.
DATA_DIR="$HOME/.mosaico"
SECRETS_DIR="$DATA_DIR/secrets"
MOSAICOD_ENV_FILE="$SECRETS_DIR/mosaicod.env"
TLS_DIR="$SECRETS_DIR/tls"
# Paths of the certificate and key as seen from inside the container.
TLS_CERT_IN_CONTAINER="/certs/cert.pem"
TLS_KEY_IN_CONTAINER="/certs/key.pem"
# Pinned: the generated command lines and environment keys belong to one mosaicod
# release. Change this together with the flags in run_mosaicod, run_cleanup and
# the keys in write_secrets, never independently. `latest` is still 0.5.x, which
# has no `server` and no `cleanup` subcommand.
DEFAULT_MOSAICO_VERSION="0.6.0-rc"
# Set when a version was asked for, by --version or MOSAICO_VERSION: --ai alone,
# which only MOSAICO_VERSION can set it for, checks the skills against it only
# then. See ai_check_version.
MOSAICO_VERSION_SET=0
[ -z "${MOSAICO_VERSION:-}" ] || MOSAICO_VERSION_SET=1
MOSAICO_VERSION="${MOSAICO_VERSION:-$DEFAULT_MOSAICO_VERSION}"
# The oldest release this installer can set up, checked against --version. Kept
# apart from DEFAULT_MOSAICO_VERSION on purpose: the default moves with every
# release, this floor only moves when the generated command lines stop working on
# an older mosaicod.
MIN_MOSAICO_VERSION="0.6"
MOSAICOD_IMAGE_REPO="ghcr.io/mosaico-labs/mosaicod"
POSTGRES_IMAGE="docker.io/library/postgres:18"
# mosaicod's own default, and the port clients and the SDK assume.
DEFAULT_MOSAICOD_PORT="6726"
# The address of this Mac that port is published on. The loopback by default: an
# installation is not put on the network unless it is asked for.
DEFAULT_MOSAICOD_HOST="127.0.0.1"
MOSAICOD_CONTAINER="mosaicod"
POSTGRES_CONTAINER="mosaico-postgres"
CLEANUP_CONTAINER="mosaico-cleanup"
PODMAN_NETWORK="mosaico"
POSTGRES_VOLUME="mosaico-postgres-data"
# A machine of Mosaico's own, so that stopping or removing it cannot disturb
# whatever else the user runs in Podman. --machine overrides it.
MACHINE="mosaico"
MACHINE_CPUS="${MOSAICO_MACHINE_CPUS:-2}"
MACHINE_MEMORY="${MOSAICO_MACHINE_MEMORY:-4096}"
MACHINE_DISK="${MOSAICO_MACHINE_DISK:-20}"
# ~/.local/bin, not /usr/local/bin: it belongs to the user, so nothing needs root.
# check_bin_dir reports it when it is not on the PATH.
BIN_DIR="$HOME/.local/bin"
CLI_WRAPPER_NAME="mosaicod"
MOSAICOCTL_NAME="mosaicoctl"
# Used only when this script was piped in and so cannot copy itself. It names
# install-macos.sh rather than https://get.mosaico.dev, which serves the bootstrap.
INSTALLER_URL="https://raw.githubusercontent.com/mosaico-labs/get.mosaico.dev/main/install-macos.sh"
# A script and not a list of arguments in the plist: starting Mosaico is three
# ordered steps with a wait in the middle, which a plist cannot express.
STARTER="$DATA_DIR/bin/mosaico-start"
LAUNCH_LABEL="dev.mosaico.mosaicod"
LAUNCH_AGENT_DIR="$HOME/Library/LaunchAgents"
LAUNCH_AGENT="$LAUNCH_AGENT_DIR/$LAUNCH_LABEL.plist"
STARTER_LOG="$DATA_DIR/launchd.log"
SDK_VENV="$DATA_DIR/sdk"
SDK_PACKAGE="mosaicolabs"
DOCS_URL="https://docs.mosaico.dev"
CLEANUP_DOCS_URL="https://docs.mosaico.dev/config/cleanup"
# The subcommand defaults --time-interval to 0, which means "clean once and exit".
# A container created with --restart=always would then be restarted forever, so an
# interval has to be supplied.
CLEANUP_DEFAULT_INTERVAL_SECONDS="86400"
PLATFORM=""
LOG_FILE="/tmp/mosaico-install-macos-$(id -u).log"
: > "$LOG_FILE" 2>/dev/null || LOG_FILE="$(mktemp -t mosaico-install-macos)"

UNINSTALL=0
DRY_RUN="${DRY_RUN:-}"

# --- Helpers ---

command_exists() {
	command -v "$@" > /dev/null 2>&1
}

# Terminal.app and iTerm2 both support the full glyph set, but a Mac reached
# through a more limited terminal (e.g. a serial console or an old SSH client)
# is not impossible, so the same fallback as the Linux installer applies here
# too. $TERM is one of the few things SSH does forward, unlike $LANG, which
# reflects the remote shell's locale rather than what the display can render.
is_limited_console() {
	case "${TERM:-}" in
		linux | dumb | "") return 0 ;;
	esac
	return 1
}

setup_colors() {
	# Independent of tty-ness: a limited console mangles the glyph whether the
	# output is a terminal or piped into a log.
	if supports_utf8; then
		ARROW="➜"
	else
		ARROW="->"
	fi

	if [ -t 1 ]; then
		RESET=$(printf '\033[0m')
		BOLD=$(printf '\033[1m')
		DIM=$(printf '\033[2m')
		# Plain ANSI, not the brand's actual hex: it needs no truecolor or 256-color
		# detection, so it renders the same everywhere, including TERM=linux.
		BRAND=$(printf '\033[96m')
		GREEN=$(printf '\033[32m')
		YELLOW=$(printf '\033[33m')
		RED=$(printf '\033[31m')
	else
		RESET=""
		BOLD=""
		DIM=""
		BRAND=""
		GREEN=""
		YELLOW=""
		RED=""
	fi
}

# The block-drawing glyphs in print_logo render correctly on every terminal
# emulator, but not on the limited console above: what the remote shell's own
# locale is does not matter, since it has no bearing on how the display renders
# the bytes this script sends it.
supports_utf8() {
	! is_limited_console
}

info()  { printf "${BRAND}Info:${RESET} %s\n" "$*"; }
warn()  { printf "${YELLOW}Warning:${RESET} %s\n" "$*" >&2; }
fatal() { printf "${RED}Error:${RESET} %s\n" "$*" >&2; exit 1; }

is_dry_run() {
	[ -n "$DRY_RUN" ]
}

lower() {
	printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# Normalizes a human-written boolean into 1 or 0.
to_bool() {
	case "$(lower "$1")" in
		1|y|yes|true|on)     echo 1 ;;
		""|0|n|no|false|off) echo 0 ;;
		*) fatal "invalid boolean value '$1' (expected true or false)." ;;
	esac
}

bool_str() {
	[ "$1" -eq 1 ] && echo true || echo false
}

# Percent-encodes everything outside the unreserved set of RFC 3986: the database
# credentials end up inside a URL, where @ : / ? # would be syntax.
urlencode() {
	_ue_rest="$1"
	_ue_out=""
	while [ -n "$_ue_rest" ]; do
		_ue_char="${_ue_rest%"${_ue_rest#?}"}"
		_ue_rest="${_ue_rest#?}"
		case "$_ue_char" in
			[A-Za-z0-9.~_-]) _ue_out="$_ue_out$_ue_char" ;;
			*) _ue_out="$_ue_out$(printf '%%%02X' "'$_ue_char")" ;;
		esac
	done
	printf '%s' "$_ue_out"
}

setup_colors

# --- Configuration state ---
#
# The companion *_SET marker of each option distinguishes a value the user asked
# for from a default, so that interactive mode prompts only for what is unknown.

NON_INTERACTIVE="$(to_bool "${NON_INTERACTIVE:-0}")"

MOSAICOD_PORT="$DEFAULT_MOSAICOD_PORT"; MOSAICOD_PORT_SET=0
MOSAICOD_HOST="$DEFAULT_MOSAICOD_HOST"; MOSAICOD_HOST_SET=0

PG_MODE="embedded";           PG_MODE_SET=0
PG_HOST="";                   PG_HOST_SET=0
PG_PORT="5432";               PG_PORT_SET=0
PG_USER="mosaico";            PG_USER_SET=0
PG_PASSWORD="";               PG_PASSWORD_SET=0
PG_DB="mosaico";              PG_DB_SET=0
# Derived in derive_pg_container_host, not passed by the user.
PG_HOST_IN_CONTAINER=""
PG_HOST_IS_LOCAL=0

STORE_BACKEND="fs";           STORE_BACKEND_SET=0
FS_DIR="$DATA_DIR/storage";   FS_DIR_SET=0
OBJ_ENDPOINT="";              OBJ_ENDPOINT_SET=0
OBJ_BUCKET="mosaico";         OBJ_BUCKET_SET=0
OBJ_ACCESS_KEY="";            OBJ_ACCESS_KEY_SET=0
OBJ_SECRET_KEY="";            OBJ_SECRET_KEY_SET=0
ENABLE_TLS=0;                 ENABLE_TLS_SET=0
TLS_CERT="";                  TLS_CERT_SET=0
TLS_KEY="";                   TLS_KEY_SET=0
DOMAIN="";                    DOMAIN_SET=0
API_KEY=0;                    API_KEY_SET=0
CLEANUP=1;                    CLEANUP_SET=0
CLEANUP_RETENTION="";         CLEANUP_RETENTION_SET=0
CLEANUP_INTERVAL="";          CLEANUP_INTERVAL_SET=0
SDK=0;                        SDK_SET=0
AI=0;                         AI_SET=0
AI_REMOVE=0
# Set by parse_args: --ai with no option that installs Mosaico (MOSAICO_ARGS),
# so the skills are installed and nothing else. See do_ai_only.
AI_ONLY=0
MOSAICO_ARGS=0
# Set by install_ai: print_success only reports files that were written.
AI_INSTALLED=0

usage() {
	cat <<-EOF
	mosaicoctl for macOS (v$SCRIPT_VERSION)

	This script installs Mosaico (mosaicod, plus an embedded PostgreSQL unless
	you already run one) as Podman containers inside a podman machine, started
	at login by a LaunchAgent. It needs no root: run it without sudo.

	Usage:
	  \$ curl -fsSL https://get.mosaico.dev | sh
	  \$ $MOSAICOCTL_NAME [options]

	General options:
	  -h, --help                      Show this help message and exit
	  -y, --yes                       Skip all prompts (unattended install)
	      --uninstall                 Remove Mosaico, leaving stored data in place
	      --dry-run                   Print commands without running them
	      --version <tag>             Install a specific image tag, $MIN_MOSAICO_VERSION or newer
	                                  (default: $DEFAULT_MOSAICO_VERSION)
	      --platform <platform>       Image platform, e.g. linux/amd64. Only for a
	                                  tag with no arm64 image on Apple Silicon
	      --machine <name>            Podman machine to use, created if missing
	                                  (default: $MACHINE)
	      --bin-dir <path>            Where mosaicod and $MOSAICOCTL_NAME go
	                                  (default: $BIN_DIR)

	Network options:
	      --port <port>               Port mosaicod serves on, published on this
	                                  Mac under the same number
	                                  (default: $DEFAULT_MOSAICOD_PORT)
	      --host <address>            Address that port is published on. Pass
	                                  0.0.0.0 to publish it on every address, so
	                                  the network can reach it
	                                  (default: $DEFAULT_MOSAICOD_HOST, this Mac only)

	Database options:
	      --postgres <embedded|external>
	                                  Run PostgreSQL in a container of its own
	                                  (default: embedded), or use an instance you
	                                  already have
	      --pg-host <host>            Host or address of the existing instance
	                                  (IPv6 in brackets)
	      --pg-port <port>            Port of the existing instance (default: 5432)
	      --pg-db <name>              Database name (default: mosaico)
	      --pg-user <name>            Role to connect as (default: mosaico)
	      --pg-password <password>    Password of that role

	Storage options:
	      --store-backend <fs|obj>    Local filesystem or object store (default: fs)
	      --fs-dir <path>             Local storage path when backend is fs, which
	                                  has to be under \$HOME
	                                  (default: $DATA_DIR/storage)
	      --obj-endpoint <url>        Object store endpoint URL
	      --obj-bucket <name>         Object store bucket name (default: mosaico)
	      --obj-access-key <key>      Object store access key / key ID
	      --obj-secret-key <key>      Object store secret key

	TLS options:
	      --enable-tls                Serve over TLS (default: off)
	      --domain <fqdn>             Name the certificate is issued for
	      --tls-cert <path>           PEM certificate chain and matching private
	      --tls-key <path>            key, both required with TLS

	  Certificates are not obtained for you on macOS: pass your own. Renewal is
	  manual: replace the copies under $TLS_DIR and restart the container.

	Security options:
	      --api-key                   Create a master API key on first run and
	                                  require API keys from every client

	Data retention options:
	      --no-cleanup                Do not run the automated cleanup routine
	                                  (default: it runs)
	      --cleanup-retention <dur>   How long frames are kept
	      --cleanup-time-interval <dur>
	                                  How often cleanup runs
	                                  Both fall back to the mosaicod defaults:
	                                  $CLEANUP_DOCS_URL

	SDK options:
	      --sdk                       Install the $SDK_PACKAGE Python SDK into a
	                                  virtual environment at $SDK_VENV
	                                  (default: not installed)

	AI assistant options:
	      --ai                        Install Mosaico's skills for AI coding
	                                  assistants into ~/.claude/skills and
	                                  ~/.agents/skills (default: not installed).
	                                  Written for Mosaico $AI_MIN_MOSAICO_VERSION or newer:
	                                  skipped, with a warning, for an older version
	      --ai alone                  With no option that installs Mosaico
	                                  (--dry-run aside; -y and --version are
	                                  such options), the skills alone: no
	                                  daemon is installed or changed. Checked
	                                  against MOSAICO_VERSION only when it is set
	      --ai --remove               Remove them, keeping the files you edited

	Paired options: with -y all of a group must be given, interactively the
	missing ones are asked for:
	      --postgres external  ->  --pg-host, --pg-password
	      --store-backend obj  ->  --obj-endpoint, --obj-bucket,
	                               --obj-access-key, --obj-secret-key
	      --enable-tls         ->  --domain, --tls-cert, --tls-key

	Environment variables:
	  NON_INTERACTIVE          Same as --yes
	  MOSAICO_VERSION          Sets the version like --version, but does not
	                           install Mosaico by itself: with --ai alone, the
	                           version the skills are checked against
	  MOSAICO_AI_SOURCE        Local .agents folder for --ai, instead of the download
	                           (testing only: not checked against the pinned hash)
	  MOSAICO_MACHINE_CPUS     CPUs of a machine created here (default: $MACHINE_CPUS)
	  MOSAICO_MACHINE_MEMORY   Its memory in MB (default: $MACHINE_MEMORY)
	  MOSAICO_MACHINE_DISK     Its disk in GB (default: $MACHINE_DISK)

	Documentation: $DOCS_URL
	EOF
}

# --- Argument parsing ---

require_value() {
	if [ $# -lt 2 ] || [ -z "$2" ]; then
		fatal "option $1 requires a value."
	fi
}

normalize_pg_mode() {
	case "$(lower "$1")" in
		embedded|internal|container|local|managed) echo embedded ;;
		external|existing|remote)                 echo external ;;
		*)                                        echo "$1" ;;
	esac
}

normalize_backend() {
	case "$(lower "$1")" in
		fs|local|filesystem) echo fs ;;
		obj|object|s3)       echo obj ;;
		*)                   echo "$1" ;;
	esac
}

# Values may be passed either as `--flag value` or as `--flag=value`.
parse_args() {
	while [ $# -gt 0 ]; do
		# Any option but these asks for Mosaico to be installed (or uninstalled),
		# --version and -y included: -y --ai installs Mosaico with its defaults
		# and the skills. A value is shifted away below, so only option names are
		# seen here.
		case "$1" in
			--ai|--install-ai|--ai=*|--install-ai=*|--no-ai|--remove) ;;
			--dry-run|-h|--help) ;;
			*) MOSAICO_ARGS=1 ;;
		esac
		case "$1" in
			--uninstall) UNINSTALL=1 ;;
			--dry-run) DRY_RUN=1 ;;
			-y|--yes) NON_INTERACTIVE=1 ;;

			--version) require_value "$@"; MOSAICO_VERSION="${2#v}"; MOSAICO_VERSION_SET=1; shift ;;
			--version=*) MOSAICO_VERSION="${1#*=}"; MOSAICO_VERSION="${MOSAICO_VERSION#v}"; MOSAICO_VERSION_SET=1 ;;

			--platform) require_value "$@"; PLATFORM="$2"; shift ;;
			--platform=*) PLATFORM="${1#*=}" ;;

			# --port is mosaicod's, not the database's: that one is --pg-port.
			--port|--mosaicod-port)
				require_value "$@"; MOSAICOD_PORT="$2"; MOSAICOD_PORT_SET=1; shift ;;
			--port=*|--mosaicod-port=*) MOSAICOD_PORT="${1#*=}"; MOSAICOD_PORT_SET=1 ;;

			# --host is the address the port is published on, not the database's:
			# that one is --pg-host.
			--host|--bind|--bind-address|--listen-address)
				require_value "$@"; MOSAICOD_HOST="$2"; MOSAICOD_HOST_SET=1; shift ;;
			--host=*|--bind=*|--bind-address=*|--listen-address=*)
				MOSAICOD_HOST="${1#*=}"; MOSAICOD_HOST_SET=1 ;;

			--machine) require_value "$@"; MACHINE="$2"; shift ;;
			--machine=*) MACHINE="${1#*=}" ;;

			--bin-dir) require_value "$@"; BIN_DIR="$2"; shift ;;
			--bin-dir=*) BIN_DIR="${1#*=}" ;;

			--postgres|--postgres-mode|--db)
				require_value "$@"
				PG_MODE="$(normalize_pg_mode "$2")"; PG_MODE_SET=1; shift ;;
			--postgres=*|--postgres-mode=*|--db=*)
				PG_MODE="$(normalize_pg_mode "${1#*=}")"; PG_MODE_SET=1 ;;
			--external-postgres|--existing-postgres) PG_MODE="external"; PG_MODE_SET=1 ;;
			--embedded-postgres) PG_MODE="embedded"; PG_MODE_SET=1 ;;

			--pg-host|--postgres-host|--db-host)
				require_value "$@"; PG_HOST="$2"; PG_HOST_SET=1; shift ;;
			--pg-host=*|--postgres-host=*|--db-host=*) PG_HOST="${1#*=}"; PG_HOST_SET=1 ;;

			--pg-port|--postgres-port|--db-port)
				require_value "$@"; PG_PORT="$2"; PG_PORT_SET=1; shift ;;
			--pg-port=*|--postgres-port=*|--db-port=*) PG_PORT="${1#*=}"; PG_PORT_SET=1 ;;

			--pg-user|--postgres-user|--db-user)
				require_value "$@"; PG_USER="$2"; PG_USER_SET=1; shift ;;
			--pg-user=*|--postgres-user=*|--db-user=*) PG_USER="${1#*=}"; PG_USER_SET=1 ;;

			--pg-password|--postgres-password|--db-password)
				require_value "$@"; PG_PASSWORD="$2"; PG_PASSWORD_SET=1; shift ;;
			--pg-password=*|--postgres-password=*|--db-password=*)
				PG_PASSWORD="${1#*=}"; PG_PASSWORD_SET=1 ;;

			--pg-db|--pg-database|--postgres-db|--db-name)
				require_value "$@"; PG_DB="$2"; PG_DB_SET=1; shift ;;
			--pg-db=*|--pg-database=*|--postgres-db=*|--db-name=*)
				PG_DB="${1#*=}"; PG_DB_SET=1 ;;

			--store-backend|--storage-backend)
				require_value "$@"
				STORE_BACKEND="$(normalize_backend "$2")"; STORE_BACKEND_SET=1; shift ;;
			--store-backend=*|--storage-backend=*)
				STORE_BACKEND="$(normalize_backend "${1#*=}")"; STORE_BACKEND_SET=1 ;;

			--fs-dir) require_value "$@"; FS_DIR="$2"; FS_DIR_SET=1; shift ;;
			--fs-dir=*) FS_DIR="${1#*=}"; FS_DIR_SET=1 ;;

			--obj-endpoint) require_value "$@"; OBJ_ENDPOINT="$2"; OBJ_ENDPOINT_SET=1; shift ;;
			--obj-endpoint=*) OBJ_ENDPOINT="${1#*=}"; OBJ_ENDPOINT_SET=1 ;;

			--obj-bucket) require_value "$@"; OBJ_BUCKET="$2"; OBJ_BUCKET_SET=1; shift ;;
			--obj-bucket=*) OBJ_BUCKET="${1#*=}"; OBJ_BUCKET_SET=1 ;;

			--obj-access-key) require_value "$@"; OBJ_ACCESS_KEY="$2"; OBJ_ACCESS_KEY_SET=1; shift ;;
			--obj-access-key=*) OBJ_ACCESS_KEY="${1#*=}"; OBJ_ACCESS_KEY_SET=1 ;;

			--obj-secret-key) require_value "$@"; OBJ_SECRET_KEY="$2"; OBJ_SECRET_KEY_SET=1; shift ;;
			--obj-secret-key=*) OBJ_SECRET_KEY="${1#*=}"; OBJ_SECRET_KEY_SET=1 ;;

			--enable-tls|--tls) ENABLE_TLS=1; ENABLE_TLS_SET=1 ;;
			--enable-tls=*|--tls=*) ENABLE_TLS="$(to_bool "${1#*=}")"; ENABLE_TLS_SET=1 ;;

			--tls-cert|--tls-certificate)
				require_value "$@"; TLS_CERT="$2"; TLS_CERT_SET=1; shift ;;
			--tls-cert=*|--tls-certificate=*) TLS_CERT="${1#*=}"; TLS_CERT_SET=1 ;;

			--tls-key|--tls-private-key)
				require_value "$@"; TLS_KEY="$2"; TLS_KEY_SET=1; shift ;;
			--tls-key=*|--tls-private-key=*) TLS_KEY="${1#*=}"; TLS_KEY_SET=1 ;;

			--domain) require_value "$@"; DOMAIN="$2"; DOMAIN_SET=1; shift ;;
			--domain=*) DOMAIN="${1#*=}"; DOMAIN_SET=1 ;;

			--api-key|--generate-api-key) API_KEY=1; API_KEY_SET=1 ;;
			--api-key=*|--generate-api-key=*) API_KEY="$(to_bool "${1#*=}")"; API_KEY_SET=1 ;;

			--no-cleanup|--disable-cleanup) CLEANUP=0; CLEANUP_SET=1 ;;

			--sdk|--install-sdk) SDK=1; SDK_SET=1 ;;
			--sdk=*|--install-sdk=*) SDK="$(to_bool "${1#*=}")"; SDK_SET=1 ;;
			--no-sdk) SDK=0; SDK_SET=1 ;;

			--ai|--install-ai) AI=1; AI_SET=1 ;;
			--ai=*|--install-ai=*) AI="$(to_bool "${1#*=}")"; AI_SET=1 ;;
			--no-ai) AI=0; AI_SET=1 ;;

			# Only meaningful with --ai: Mosaico itself is removed with --uninstall.
			--remove) AI_REMOVE=1 ;;

			--cleanup-retention) require_value "$@"; CLEANUP_RETENTION="$2"; CLEANUP_RETENTION_SET=1; shift ;;
			--cleanup-retention=*) CLEANUP_RETENTION="${1#*=}"; CLEANUP_RETENTION_SET=1 ;;

			--cleanup-time-interval|--cleanup-interval)
				require_value "$@"; CLEANUP_INTERVAL="$2"; CLEANUP_INTERVAL_SET=1; shift ;;
			--cleanup-time-interval=*|--cleanup-interval=*)
				CLEANUP_INTERVAL="${1#*=}"; CLEANUP_INTERVAL_SET=1 ;;

			-h|--help)
				usage
				exit 0
				;;
			*)
				printf "${RED}Error:${RESET} illegal option %s\n\n" "$1" >&2
				usage >&2
				exit 1
				;;
		esac
		shift
	done

	if [ "$AI" -eq 1 ] && [ "$AI_REMOVE" -eq 0 ] && [ "$MOSAICO_ARGS" -eq 0 ]; then
		AI_ONLY=1
	fi
}

# --- Option pairing ---

apply_pairings() {
	if [ "$PG_MODE_SET" -eq 0 ]; then
		if [ "$PG_HOST_SET" -eq 1 ] || [ "$PG_USER_SET" -eq 1 ] ||
		   [ "$PG_PASSWORD_SET" -eq 1 ] || [ "$PG_DB_SET" -eq 1 ]; then
			PG_MODE="external"
			PG_MODE_SET=1
			info "PostgreSQL connection options given; selecting --postgres external."
		elif [ "$PG_PORT_SET" -eq 1 ]; then
			warn "--pg-port alone does not select an existing instance: pass --pg-host as well. The embedded database is used, and the port is ignored."
		fi
	elif [ "$PG_MODE" = "embedded" ]; then
		if [ "$PG_HOST_SET" -eq 1 ] || [ "$PG_USER_SET" -eq 1 ] ||
		   [ "$PG_PASSWORD_SET" -eq 1 ] || [ "$PG_DB_SET" -eq 1 ] || [ "$PG_PORT_SET" -eq 1 ]; then
			warn "--postgres embedded was requested; the --pg-* options are ignored."
		fi
	fi

	if [ "$STORE_BACKEND_SET" -eq 0 ]; then
		if [ "$OBJ_ENDPOINT_SET" -eq 1 ] || [ "$OBJ_BUCKET_SET" -eq 1 ] ||
		   [ "$OBJ_ACCESS_KEY_SET" -eq 1 ] || [ "$OBJ_SECRET_KEY_SET" -eq 1 ]; then
			STORE_BACKEND="obj"
			STORE_BACKEND_SET=1
			info "Object store options given; selecting --store-backend obj."
		fi
	elif [ "$STORE_BACKEND" = "fs" ]; then
		if [ "$OBJ_ENDPOINT_SET" -eq 1 ] || [ "$OBJ_ACCESS_KEY_SET" -eq 1 ] ||
		   [ "$OBJ_SECRET_KEY_SET" -eq 1 ]; then
			warn "--store-backend fs was requested; the --obj-* options are ignored."
		fi
	elif [ "$STORE_BACKEND" = "obj" ] && [ "$FS_DIR_SET" -eq 1 ]; then
		warn "--store-backend obj was requested; --fs-dir is ignored."
	fi

	if [ "$ENABLE_TLS_SET" -eq 0 ]; then
		if [ "$DOMAIN_SET" -eq 1 ] || [ "$TLS_CERT_SET" -eq 1 ] || [ "$TLS_KEY_SET" -eq 1 ]; then
			ENABLE_TLS=1
			ENABLE_TLS_SET=1
			info "TLS options given; enabling TLS."
		fi
	elif [ "$ENABLE_TLS" -eq 0 ]; then
		if [ "$DOMAIN_SET" -eq 1 ] || [ "$TLS_CERT_SET" -eq 1 ] || [ "$TLS_KEY_SET" -eq 1 ]; then
			warn "TLS is disabled; --domain, --tls-cert and --tls-key are ignored."
		fi
	fi

	if [ "$CLEANUP" -eq 0 ]; then
		if [ "$CLEANUP_RETENTION_SET" -eq 1 ] || [ "$CLEANUP_INTERVAL_SET" -eq 1 ]; then
			warn "--no-cleanup given; --cleanup-retention and --cleanup-time-interval are ignored."
		fi
	fi
}

# --- Validation ---

is_valid_backend() {
	case "$1" in
		fs|obj) return 0 ;;
		*) return 1 ;;
	esac
}

is_valid_pg_mode() {
	case "$1" in
		embedded|external) return 0 ;;
		*) return 1 ;;
	esac
}

# Looser than is_valid_domain, which insists on a dot: a database may be reachable
# as `localhost` or as an address. IPv6 literals are accepted only in brackets,
# which is how they have to appear in the connection URL.
is_valid_host() {
	case "$1" in
		\[*\]) echo "$1" | grep -Eq '^\[[0-9A-Fa-f:]+\]$' && return 0
		       return 1 ;;
		*:*)   return 1 ;;
	esac
	echo "$1" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$'
}

is_valid_port() {
	echo "$1" | grep -Eq '^[1-9][0-9]{0,4}$' && [ "$1" -le 65535 ]
}

# Stricter than is_valid_host: a published port is bound to an address, so a name
# is not accepted here even though PostgreSQL's host may be one. IPv6 literals need
# brackets, which is also how Podman wants them in a port mapping.
is_valid_bind_address() {
	case "$1" in
		\[*\]) echo "$1" | grep -Eq '^\[[0-9A-Fa-f:]+\]$' && return 0
		       return 1 ;;
	esac
	echo "$1" | grep -Eq '^((25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])$'
}

# The wildcards: every address of this Mac, so the service is on the network.
is_any_address() {
	case "$1" in
		0.0.0.0|"[::]") return 0 ;;
		*) return 1 ;;
	esac
}

is_loopback_address() {
	case "$1" in
		127.*|"[::1]") return 0 ;;
		*) return 1 ;;
	esac
}

is_valid_endpoint() {
	case "$1" in
		http://?*|https://?*) return 0 ;;
		*) return 1 ;;
	esac
}

is_valid_domain() {
	echo "$1" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?)+$'
}

is_valid_duration() {
	echo "$1" | grep -Eq '^[1-9][0-9]*[hdwm]$'
}

is_valid_bucket() {
	echo "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{1,61}[A-Za-z0-9]$'
}

is_absolute_path() {
	case "$1" in
		/?*) return 0 ;;
		*) return 1 ;;
	esac
}

# A podman machine mounts $HOME and nothing else. A bind mount of a path outside
# it does not fail: Podman creates an empty directory of that name inside the
# virtual machine, and whatever is written there disappears with the container.
is_under_home() {
	case "$1" in
		"$HOME"|"$HOME"/*) return 0 ;;
		*) return 1 ;;
	esac
}

is_readable_file() {
	is_absolute_path "$1" || return 1
	[ -r "$1" ]
}

# Converts the durations accepted by is_valid_duration into the seconds that
# mosaicod expects. A month is taken as 30 days.
duration_to_seconds() {
	_num="${1%?}"
	case "${1#"$_num"}" in
		h) echo $((_num * 3600)) ;;
		d) echo $((_num * 86400)) ;;
		w) echo $((_num * 604800)) ;;
		m) echo $((_num * 2592000)) ;;
		*) fatal "internal error: unsupported duration '$1'." ;;
	esac
}

# mosaicod stores both durations as a 32-bit number of seconds, so a value that
# parses correctly can still be out of range.
check_duration_fits() {
	if [ "$(duration_to_seconds "$2")" -ge 4294967296 ]; then
		fatal "$1 '$2' is too large (the limit is about 49700 days)."
	fi
}

# The tag's major and minor as two words, or nothing at all when the tag is not a
# release number: a patch or prerelease suffix is ignored, so 0.6.0-rc reads as
# "0 6", a major on its own as "1 0", and `latest` or a commit sha as nothing. The
# leading `v` is stripped here as well as in parse_args, since MOSAICO_VERSION
# from the environment does not go through it.
version_major_minor() {
	echo "${1#v}" | sed -n \
		-e 's/^\([0-9][0-9]*\)\.\([0-9][0-9]*\).*$/\1 \2/p' \
		-e 's/^\([0-9][0-9]*\)$/\1 0/p'
}

# A tag naming a commit rather than a release: the `sha-<hex>` form the image build
# produces, or the bare hex.
is_commit_sha() {
	echo "${1#sha-}" | grep -Eq '^[0-9a-fA-F]{7,40}$'
}

check_min_version() {
	[ "$MOSAICO_VERSION" = "latest" ] && return 0

	_mv="$(version_major_minor "$MOSAICO_VERSION")"
	if [ -z "$_mv" ]; then
		is_commit_sha "$MOSAICO_VERSION" && return 0
		fatal "--version '$MOSAICO_VERSION' is not a release number: pass a version tag ($MIN_MOSAICO_VERSION or newer), 'latest', or a commit sha."
	fi

	_major="${_mv% *}"
	_minor="${_mv#* }"
	_min_major="${MIN_MOSAICO_VERSION%%.*}"
	_min_minor="${MIN_MOSAICO_VERSION#*.}"

	if [ "$_major" -lt "$_min_major" ] || \
		{ [ "$_major" -eq "$_min_major" ] && [ "$_minor" -lt "$_min_minor" ]; }; then
		fatal "--version '$MOSAICO_VERSION' is older than mosaicod $MIN_MOSAICO_VERSION,
    Pass $MIN_MOSAICO_VERSION or newer, or drop --version to use the default ($DEFAULT_MOSAICO_VERSION)."
	fi
}

# Rejects a malformed value as soon as it is seen, so the user is not walked
# through a whole questionnaire before learning that a flag was wrong.
validate_flags() {
	# A MOSAICO_VERSION set for --ai alone names the daemon the skills are for,
	# not an image to pull: only the skills' own check applies to it.
	[ "$AI_ONLY" -eq 1 ] || check_min_version
	[ "$AI" -eq 0 ] || [ "$AI_REMOVE" -eq 1 ] || [ "$UNINSTALL" -eq 0 ] || \
		fatal "--ai and --uninstall are separate runs: --uninstall leaves the skills in place, and --ai --remove removes them."
	ai_check_version

	if [ "$AI_REMOVE" -eq 1 ]; then
		[ "$AI" -eq 1 ] || \
			fatal "--remove only applies to --ai: pass --ai --remove to remove the Mosaico skills, or --uninstall to remove Mosaico."
		[ "$UNINSTALL" -eq 0 ] || \
			fatal "--ai --remove and --uninstall are separate runs: pass one, then the other."
	fi

	is_valid_pg_mode "$PG_MODE" || \
		fatal "invalid --postgres '$PG_MODE' (expected 'embedded' or 'external')."

	is_valid_backend "$STORE_BACKEND" || \
		fatal "invalid --store-backend '$STORE_BACKEND' (expected 'fs' or 'obj')."

	if [ "$MOSAICOD_PORT_SET" -eq 1 ] && ! is_valid_port "$MOSAICOD_PORT"; then
		fatal "--port '$MOSAICOD_PORT' is not a valid port number."
	fi
	if [ "$MOSAICOD_HOST_SET" -eq 1 ] && ! is_valid_bind_address "$MOSAICOD_HOST"; then
		fatal "--host '$MOSAICOD_HOST' is not a valid address: pass an IPv4 address such as 127.0.0.1 (this Mac only) or 0.0.0.0 (every address), or an IPv6 literal in brackets, as in [::1]."
	fi

	if [ "$PG_HOST_SET" -eq 1 ] && ! is_valid_host "$PG_HOST"; then
		fatal "--pg-host '$PG_HOST' is not a valid host name or address (an IPv6 literal needs brackets, as in [2001:db8::1])."
	fi
	if [ "$PG_PORT_SET" -eq 1 ] && ! is_valid_port "$PG_PORT"; then
		fatal "--pg-port '$PG_PORT' is not a valid port number."
	fi

	if [ "$FS_DIR_SET" -eq 1 ]; then
		is_absolute_path "$FS_DIR" || \
			fatal "--fs-dir must be an absolute path, got '$FS_DIR'."
		is_under_home "$FS_DIR" || \
			fatal "--fs-dir '$FS_DIR' is outside \$HOME. Only $HOME is shared with the podman machine, so the containers cannot see anything else: choose a path under it, for example $DATA_DIR/storage."
	fi
	if [ "$OBJ_ENDPOINT_SET" -eq 1 ] && ! is_valid_endpoint "$OBJ_ENDPOINT"; then
		fatal "--obj-endpoint must start with http:// or https://, got '$OBJ_ENDPOINT'."
	fi
	if [ "$OBJ_BUCKET_SET" -eq 1 ] && ! is_valid_bucket "$OBJ_BUCKET"; then
		fatal "--obj-bucket '$OBJ_BUCKET' is not a valid bucket name."
	fi
	if [ "$DOMAIN_SET" -eq 1 ] && ! is_valid_domain "$DOMAIN"; then
		fatal "--domain '$DOMAIN' is not a valid fully qualified domain name."
	fi
	if [ "$TLS_CERT_SET" -eq 1 ] && ! is_readable_file "$TLS_CERT"; then
		fatal "--tls-cert '$TLS_CERT' is not an absolute path to a readable file."
	fi
	if [ "$TLS_KEY_SET" -eq 1 ] && ! is_readable_file "$TLS_KEY"; then
		fatal "--tls-key '$TLS_KEY' is not an absolute path to a readable file."
	fi
	if [ "$CLEANUP_RETENTION_SET" -eq 1 ]; then
		is_valid_duration "$CLEANUP_RETENTION" || \
			fatal "--cleanup-retention '$CLEANUP_RETENTION' is not a valid duration (e.g. 7d, 14d, 30d)."
		check_duration_fits --cleanup-retention "$CLEANUP_RETENTION"
	fi
	if [ "$CLEANUP_INTERVAL_SET" -eq 1 ]; then
		is_valid_duration "$CLEANUP_INTERVAL" || \
			fatal "--cleanup-time-interval '$CLEANUP_INTERVAL' is not a valid duration (e.g. 7d, 14d, 30d)."
		check_duration_fits --cleanup-time-interval "$CLEANUP_INTERVAL"
	fi
	if [ "$BIN_DIR" != "$HOME/.local/bin" ]; then
		is_absolute_path "$BIN_DIR" || \
			fatal "--bin-dir must be an absolute path, got '$BIN_DIR'."
	fi
}

# Collected rather than reported one at a time, so a single run tells the user
# everything that is missing instead of one flag per attempt.
MISSING=""

add_missing() {
	MISSING="$MISSING  - $1
"
}

validate_non_interactive() {
	MISSING=""

	if [ "$PG_MODE" = "external" ]; then
		if [ -z "$PG_HOST" ] || [ -z "$PG_PASSWORD" ]; then
			add_missing "Database mode 'external' requires --pg-host and --pg-password."
		fi
	fi

	if [ "$STORE_BACKEND" = "obj" ]; then
		if [ -z "$OBJ_ENDPOINT" ] || [ -z "$OBJ_ACCESS_KEY" ] || [ -z "$OBJ_SECRET_KEY" ]; then
			add_missing "Storage backend 'obj' requires --obj-endpoint, --obj-access-key, and --obj-secret-key."
		fi
	elif [ -z "$FS_DIR" ]; then
		add_missing "Storage backend 'fs' requires --fs-dir."
	fi

	# Certificates are never obtained here, so all three are mandatory.
	if [ "$ENABLE_TLS" -eq 1 ]; then
		if [ -z "$DOMAIN" ]; then
			add_missing "TLS is enabled, which requires --domain <fqdn>."
		fi
		if [ -z "$TLS_CERT" ] || [ -z "$TLS_KEY" ]; then
			add_missing "TLS on macOS requires --tls-cert and --tls-key: certificates are not obtained automatically."
		fi
	fi

	if [ -n "$MISSING" ]; then
		printf "${RED}Error:${RESET} Non-interactive mode (-y) active, but required parameters are missing:\n" >&2
		printf "%s" "$MISSING" >&2
		echo >&2
		echo "Please provide the missing flags or run without -y for interactive setup." >&2
		echo >&2
		exit 1
	fi
}

# --- Interactive prompts ---
#
# Prompts read from and write to /dev/tty, not stdin/stdout: under
# `curl … | sh` stdin is the script itself, not the keyboard.

TTY="/dev/tty"

has_tty() {
	[ -r "$TTY" ] && [ -w "$TTY" ] && ( exec < "$TTY" ) 2>/dev/null
}

tty_print() {
	printf "%s\n" "$*" > "$TTY"
}

# ask_plain <rendered-prompt> [default] -> answer on stdout
ask_plain() {
	printf '%s' "$1" > "$TTY"
	IFS= read -r _ans < "$TTY" || _ans=""
	[ -n "$_ans" ] || _ans="${2:-}"
	printf '%s' "$_ans"
}

# ask <question> [default] -> answer on stdout
ask() {
	_q="$1"
	_def="${2:-}"
	if [ -n "$_def" ]; then
		_rendered="$(printf "${BOLD}?${RESET} %s [${BRAND}%s${RESET}]: " "$_q" "$_def")"
	else
		_rendered="$(printf "${BOLD}?${RESET} %s: " "$_q")"
	fi
	ask_plain "$_rendered" "$_def"
}

# ask_required <question> <validator|""> <error-hint> [default] -> answer on stdout
ask_required() {
	_q="$1"
	_validator="$2"
	_hint="$3"
	_def="${4:-}"
	while :; do
		_val="$(ask "$_q" "$_def")"
		if [ -z "$_val" ]; then
			tty_print "  ${RED}This value is required.${RESET}"
			continue
		fi
		if [ -z "$_validator" ] || "$_validator" "$_val"; then
			printf '%s' "$_val"
			return 0
		fi
		tty_print "  ${RED}$_hint${RESET}"
	done
}

# ask_secret <question> -> answer on stdout, echoed back as asterisks so the
# value never appears on screen or in the scrollback.
ask_secret() {
	_q="$1"
	while :; do
		printf "${BOLD}?${RESET} %s: " "$_q" > "$TTY"
		_stty_saved=""
		if _stty_saved="$(stty -g < "$TTY" 2>/dev/null)"; then
			stty -echo < "$TTY" 2>/dev/null || _stty_saved=""
		fi
		IFS= read -r _secret < "$TTY" || _secret=""
		[ -n "$_stty_saved" ] && stty "$_stty_saved" < "$TTY" 2>/dev/null || true
		tty_print "$(mask_of "$_secret")"
		if [ -n "$_secret" ]; then
			printf '%s' "$_secret"
			return 0
		fi
		tty_print "  ${RED}This value is required.${RESET}"
	done
}

mask_of() {
	_m=""
	_i=0
	while [ "$_i" -lt "${#1}" ]; do
		_m="$_m*"
		_i=$((_i + 1))
	done
	printf '%s' "$_m"
}

# ask_yn_raw <rendered-prompt> <y|n default> -> 0 for yes, 1 for no
ask_yn_raw() {
	_q="$1"
	_def="$2"
	if [ "$_def" = "y" ]; then _hint="[Y/n]"; else _hint="[y/N]"; fi
	while :; do
		printf '%s %s: ' "$_q" "$_hint" > "$TTY"
		IFS= read -r _ans < "$TTY" || _ans=""
		[ -n "$_ans" ] || _ans="$_def"
		case "$(lower "$_ans")" in
			y|yes) return 0 ;;
			n|no) return 1 ;;
			*) tty_print "  ${RED}Please answer y or n.${RESET}" ;;
		esac
	done
}

ask_yn() {
	ask_yn_raw "$(printf "${BOLD}?${RESET} %s" "$1")" "$2"
}

section() {
	echo
	echo "${BOLD}$1${RESET}"
	echo "${DIM}--------------------------------------------------------------------------------${RESET}"
}

configure_interactive() {
	info "Interactive configuration started. Press Enter to accept [default values]."

	# --- [1/7] Database ---
	section "[1/7] PostgreSQL Database"
	if [ "$PG_MODE_SET" -eq 0 ]; then
		tty_print "${BOLD}?${RESET} Choose how mosaicod reaches PostgreSQL:"
		tty_print "  ${BRAND}>${RESET} [1] Install an embedded PostgreSQL container (nothing needed beforehand)"
		tty_print "    [2] Use a PostgreSQL instance I already have"
		while :; do
			_choice="$(ask_plain "  Select [1-2] (default: 1): " "1")"
			case "$(lower "$_choice")" in
				1|embedded|internal|local) PG_MODE="embedded"; break ;;
				2|external|existing|remote) PG_MODE="external"; break ;;
				*) tty_print "  ${RED}Please enter 1 or 2.${RESET}" ;;
			esac
		done
		echo
	else
		info "Database mode '$PG_MODE' taken from the command line."
	fi

	if [ "$PG_MODE" = "external" ]; then
		echo "  The database and the role have to exist already; mosaicod creates its"
		echo "  own schema inside them on first start."
		echo "  ${DIM}An instance on this Mac is reached from the container as"
		echo "  host.containers.internal, which needs it to listen on more than 127.0.0.1.${RESET}"
		[ "$PG_HOST_SET" -eq 1 ] || PG_HOST="$(ask_required \
			"PostgreSQL host or address (e.g., db.example.com or 10.0.0.5)" \
			is_valid_host "Enter a host name or an address; an IPv6 literal needs brackets.")"
		[ "$PG_PORT_SET" -eq 1 ] || PG_PORT="$(ask_required \
			"PostgreSQL port" is_valid_port "Enter a port number between 1 and 65535." "$PG_PORT")"
		[ "$PG_DB_SET" -eq 1 ] || PG_DB="$(ask_required \
			"Database name" "" "" "$PG_DB")"
		[ "$PG_USER_SET" -eq 1 ] || PG_USER="$(ask_required \
			"Database user" "" "" "$PG_USER")"
		[ "$PG_PASSWORD_SET" -eq 1 ] || PG_PASSWORD="$(ask_secret "Database password")"
	fi

	# --- [2/7] Storage ---
	section "[2/7] Storage Configuration"
	if [ "$STORE_BACKEND_SET" -eq 0 ]; then
		tty_print "${BOLD}?${RESET} Choose storage backend:"
		tty_print "  ${BRAND}>${RESET} [1] Local Filesystem (fs)"
		tty_print "    [2] Generic Object Storage (obj)"
		while :; do
			_choice="$(ask_plain "  Select [1-2] (default: 1): " "1")"
			case "$(lower "$_choice")" in
				1|fs)      STORE_BACKEND="fs"; break ;;
				2|obj|object) STORE_BACKEND="obj"; break ;;
				*) tty_print "  ${RED}Please enter 1 or 2.${RESET}" ;;
			esac
		done
		echo
	else
		info "Storage backend '$STORE_BACKEND' taken from the command line."
	fi

	if [ "$STORE_BACKEND" = "fs" ]; then
		echo "  The directory has to be under $HOME: that is the only part of this Mac"
		echo "  the containers can see."
		[ "$FS_DIR_SET" -eq 1 ] || FS_DIR="$(ask_required \
			"Local storage directory" is_under_home \
			"Enter an absolute path under $HOME." "$FS_DIR")"
	else
		[ "$OBJ_ENDPOINT_SET" -eq 1 ] || OBJ_ENDPOINT="$(ask_required \
			"Object Storage Endpoint (e.g., https://s3.amazonaws.com or http://minio:9000)" \
			is_valid_endpoint "The endpoint must start with http:// or https://.")"
		[ "$OBJ_BUCKET_SET" -eq 1 ] || OBJ_BUCKET="$(ask_required \
			"Bucket name" is_valid_bucket "That is not a valid bucket name." "$OBJ_BUCKET")"
		[ "$OBJ_ACCESS_KEY_SET" -eq 1 ] || OBJ_ACCESS_KEY="$(ask_required \
			"Access Key / Key ID" "" "")"
		[ "$OBJ_SECRET_KEY_SET" -eq 1 ] || OBJ_SECRET_KEY="$(ask_secret "Secret Key")"
	fi

	# --- [3/7] Network, TLS & domain ---
	section "[3/7] Network, TLS & Domain Setup"
	if [ "$MOSAICOD_PORT_SET" -eq 0 ]; then
		echo "  mosaicod serves gRPC on this port, published on this Mac by Podman."
		echo "  Clients, the SDK and the published examples all assume $DEFAULT_MOSAICOD_PORT."
		MOSAICOD_PORT="$(ask_required "Port for mosaicod" is_valid_port \
			"Enter a port number between 1 and 65535." "$MOSAICOD_PORT")"
		echo
	else
		info "Port $MOSAICOD_PORT taken from the command line."
	fi

	if [ "$MOSAICOD_HOST_SET" -eq 0 ]; then
		echo "  That port is published on this address alone. The default, $DEFAULT_MOSAICOD_HOST,"
		echo "  keeps Mosaico reachable from this Mac only."
		echo "  ${BOLD}Enter 0.0.0.0 to publish it on every address${RESET}, so that other machines"
		echo "  on the network can reach it."
		MOSAICOD_HOST="$(ask_required "Address to publish mosaicod on" is_valid_bind_address \
			"Enter an IPv4 address such as 127.0.0.1 or 0.0.0.0, or an IPv6 literal in brackets, as in [::1]." \
			"$MOSAICOD_HOST")"
		echo
	else
		info "Address $MOSAICOD_HOST taken from the command line."
	fi

	if [ "$ENABLE_TLS_SET" -eq 0 ]; then
		echo "  Certificates are not obtained for you on macOS: you supply the"
		echo "  certificate chain and the private key."
		if ask_yn "Do you want to configure TLS/HTTPS?" "n"; then
			ENABLE_TLS=1
		else
			ENABLE_TLS=0
		fi
	fi
	if [ "$ENABLE_TLS" -eq 1 ]; then
		[ "$DOMAIN_SET" -eq 1 ] || DOMAIN="$(ask_required \
			"Enter the fully qualified domain name the certificate is issued for" \
			is_valid_domain "That does not look like a valid domain name.")"
		[ "$TLS_CERT_SET" -eq 1 ] || TLS_CERT="$(ask_required \
			"Path of the PEM certificate chain for $DOMAIN" \
			is_readable_file "That is not an absolute path to a readable file.")"
		[ "$TLS_KEY_SET" -eq 1 ] || TLS_KEY="$(ask_required \
			"Path of the matching PEM private key" \
			is_readable_file "That is not an absolute path to a readable file.")"
	fi

	# --- [4/7] Security ---
	#
	# The suggested answer is yes, where -y defaults to no: a client needs a key to
	# talk to a daemon that enforces them.
	section "[4/7] Security & API Keys"
	if [ "$API_KEY_SET" -eq 0 ]; then
		if ask_yn "Do you want to generate an initial Master API Key for clients?" "y"; then
			API_KEY=1
		else
			API_KEY=0
		fi
	fi

	# --- [5/7] Retention ---
	section "[5/7] Data Retention & Cleanup"
	if [ "$CLEANUP_SET" -eq 0 ]; then
		echo "  The cleanup routine prunes obsolete dataset frames and runs by default,"
		echo "  with mosaicod's own settings, documented at:"
		echo "  ${BRAND}$CLEANUP_DOCS_URL${RESET}"
		if ask_yn "Disable the automated cleanup routine?" "n"; then
			CLEANUP=0
		else
			CLEANUP=1
		fi
	fi
	if [ "$CLEANUP" -eq 1 ]; then
		if [ "$CLEANUP_RETENTION_SET" -eq 0 ] && [ "$CLEANUP_INTERVAL_SET" -eq 0 ]; then
			if ask_yn "Keep those default values?" "y"; then
				CLEANUP_RETENTION_SET=1
				CLEANUP_INTERVAL_SET=1
			fi
		fi
		[ "$CLEANUP_RETENTION_SET" -eq 1 ] || CLEANUP_RETENTION="$(ask_required \
			"Custom retention policy (e.g., 7d, 14d, 90d)" is_valid_duration \
			"Use a number followed by h, d, w or m (e.g. 14d).")"
		[ "$CLEANUP_INTERVAL_SET" -eq 1 ] || CLEANUP_INTERVAL="$(ask_required \
			"How often should the cleanup run (e.g., 1d, 7d, 30d)" is_valid_duration \
			"Use a number followed by h, d, w or m (e.g. 7d).")"
	fi

	# --- [6/7] Python SDK ---
	section "[6/7] Python SDK"
	if [ "$SDK_SET" -eq 0 ]; then
		echo "  The Python SDK ($SDK_PACKAGE) is installed into a virtual environment"
		echo "  at $SDK_VENV."
		if ask_yn "Install the Python SDK?" "n"; then
			SDK=1
		else
			SDK=0
		fi
	fi

	# --- [7/7] AI coding assistants ---
	section "[7/7] AI Coding Assistants"
	if [ "$AI_SET" -eq 0 ]; then
		if ! ai_released; then
			echo "  Mosaico's skills for AI coding assistants are not released yet."
			AI=0
		elif ! ai_version_supported; then
			echo "  Mosaico's skills for AI coding assistants are written for Mosaico"
			echo "  $AI_MIN_MOSAICO_VERSION or newer: not offered for $MOSAICO_VERSION."
			AI=0
		else
			echo "  Mosaico's skills can be added to ~/.claude/skills (Claude Code) and to"
			echo "  ~/.agents/skills (Codex, GitHub Copilot, Cursor, Gemini CLI)."
			echo "  A file you edit afterwards is never overwritten."
			if ask_yn "Install Mosaico skills for your AI coding assistants?" "n"; then
				AI=1
			else
				AI=0
			fi
		fi
	elif [ "$AI" -eq 1 ] && ai_released && ! ai_version_supported; then
		echo "  Mosaico's skills for AI coding assistants are written for Mosaico"
		echo "  $AI_MIN_MOSAICO_VERSION or newer: --ai is skipped for $MOSAICO_VERSION."
	fi
}

# Reports an omitted option as "default" rather than naming a value, which stays
# documented in $CLEANUP_DOCS_URL alone.
cleanup_summary() {
	_parts=""
	[ -n "$CLEANUP_RETENTION" ] && _parts="Retention: $CLEANUP_RETENTION"
	if [ -n "$CLEANUP_INTERVAL" ]; then
		[ -n "$_parts" ] && _parts="$_parts, "
		_parts="${_parts}Interval: $CLEANUP_INTERVAL"
	fi
	if [ -z "$_parts" ]; then
		echo "default retention and interval"
	else
		echo "$_parts"
	fi
}

# 127.0.0.1 inside the container is neither the virtual machine nor the Mac, so a
# loopback --pg-host is rewritten to host.containers.internal, which resolves out
# to the host side.
derive_pg_container_host() {
	[ "$PG_MODE" = "external" ] || return 0

	PG_HOST_IN_CONTAINER="$PG_HOST"
	case "$(lower "$PG_HOST")" in
		localhost|localhost.localdomain|127.*|0.0.0.0|::1|"[::1]")
			PG_HOST_IS_LOCAL=1
			PG_HOST_IN_CONTAINER="host.containers.internal"
			;;
	esac
}

# TLS is about clients on other machines, so a certificate buys nothing while the
# port is published on the loopback alone. Reported rather than refused: a name
# that resolves to this Mac is a legitimate way to reach a local installation.
warn_tls_bind_mismatch() {
	[ "$ENABLE_TLS" -eq 1 ] || return 0
	is_loopback_address "$MOSAICOD_HOST" || return 0
	warn "TLS is enabled for '$DOMAIN', but the port is published on $MOSAICOD_HOST, so no other machine can reach it. Pass --host 0.0.0.0 to publish it on every address."
}

print_summary() {
	echo
	echo "${DIM}--------------------------------------------------------------------------------${RESET}"
	echo "${BOLD}Configuration Summary:${RESET}"
	echo "  - Podman machine  : $MACHINE"
	echo "  - Port            : $MOSAICOD_PORT"
	if is_any_address "$MOSAICOD_HOST"; then
		echo "  - Published on    : $MOSAICOD_HOST (every address of this Mac, reachable from the network)"
	else
		echo "  - Published on    : $MOSAICOD_HOST"
	fi
	if [ "$PG_MODE" = "embedded" ]; then
		echo "  - Database        : Embedded PostgreSQL container (created and managed here)"
	else
		echo "  - Database        : Existing PostgreSQL at $PG_HOST:$PG_PORT/$PG_DB as $PG_USER"
		if [ "$PG_HOST_IS_LOCAL" -eq 1 ]; then
			echo "                      ${DIM}reached from the container as $PG_HOST_IN_CONTAINER${RESET}"
		fi
	fi
	if [ "$STORE_BACKEND" = "fs" ]; then
		echo "  - Storage Backend : Local Filesystem ($FS_DIR)"
	else
		echo "  - Storage Backend : Generic Object Storage ($OBJ_ENDPOINT / $OBJ_BUCKET)"
	fi
	if [ "$ENABLE_TLS" -eq 1 ]; then
		echo "  - TLS / Domain    : Enabled ($DOMAIN)"
		echo "  - TLS Certificate : $TLS_CERT"
		echo "  - TLS Private Key : $TLS_KEY"
	else
		echo "  - TLS / Domain    : Disabled (plain HTTP)"
	fi
	if [ "$API_KEY" -eq 1 ]; then
		echo "  - Master API Key  : Yes (will be created, clients will need a key)"
	else
		echo "  - Master API Key  : No (the daemon accepts unauthenticated clients)"
	fi
	if [ "$CLEANUP" -eq 1 ]; then
		echo "  - Cleanup Routine : Enabled in the $CLEANUP_CONTAINER container ($(cleanup_summary))"
	else
		echo "  - Cleanup Routine : Disabled (no cleanup container)"
	fi
	if [ "$SDK" -eq 1 ]; then
		echo "  - Python SDK      : $SDK_PACKAGE in a venv at $SDK_VENV"
	else
		echo "  - Python SDK      : Not installed"
	fi
	if [ "$AI" -eq 1 ] && ! ai_released; then
		echo "  - AI Skills       : Not released yet: none are installed"
	elif [ "$AI" -eq 1 ] && ! ai_version_supported; then
		echo "  - AI Skills       : Skipped: written for Mosaico $AI_MIN_MOSAICO_VERSION or newer"
	elif [ "$AI" -eq 1 ]; then
		echo "  - AI Skills       : ~/.claude/skills and ~/.agents/skills"
	else
		echo "  - AI Skills       : Not installed"
	fi
	echo "  - Image Version   : $MOSAICO_VERSION"
	[ -n "$PLATFORM" ] && echo "  - Image Platform  : $PLATFORM"
	echo "  - Commands in     : $BIN_DIR"
	echo
}

confirm_summary() {
	if ! ask_yn "Proceed with installation using these settings?" "y"; then
		echo
		info "Installation cancelled; nothing was changed."
		exit 0
	fi
	echo
}

# Non-fatal: a name clients cannot use is worth reporting before the first
# connection attempt. getent does not exist on macOS; host(1) and dig(1) ship with
# the system.
check_domain_dns() {
	[ "$ENABLE_TLS" -eq 1 ] && [ -n "$DOMAIN" ] || return 0

	resolved=""
	if command_exists host; then
		resolved="$(host -t A "$DOMAIN" 2>/dev/null | awk '/has address/ {print $NF; exit}' || true)"
	elif command_exists dig; then
		resolved="$(dig +short A "$DOMAIN" 2>/dev/null | awk 'NR==1' || true)"
	fi

	if [ -z "$resolved" ]; then
		warn "could not resolve '$DOMAIN': clients will not reach Mosaico by that name until DNS is configured."
		return 0
	fi

	local_ips="$(local_addresses)"
	public_ip=""
	command_exists curl && public_ip="$(curl -s --max-time 2 ifconfig.me 2>/dev/null || true)"
	for ip in $local_ips $public_ip; do
		[ "$ip" = "$resolved" ] && return 0
	done
	warn "'$DOMAIN' resolves to $resolved, which does not match this Mac's addresses."
}

# `hostname -I` is a GNU extension; ipconfig only answers for a named interface,
# so the usual Wi-Fi and Ethernet ones are asked in turn.
local_addresses() {
	for _if in en0 en1 en2; do
		_addr="$(ipconfig getifaddr "$_if" 2>/dev/null || true)"
		[ -n "$_addr" ] && printf '%s\n' "$_addr"
	done
	# An absent en2 would otherwise leave a non-zero status for the caller's
	# assignment to propagate into set -e.
	return 0
}

# --- Command execution ---
#
# Nothing here runs as root: a command that would need privileges is a bug.

# The container commands are assembled over several lines, which leaves their
# indentation inside the string. eval does not care, a dry run is meant to be read.
squeeze() {
	printf '%s' "$*" | tr -s ' \t' ' '
}

run_cmd() {
	if is_dry_run; then
		echo "  ${DIM}(dry-run)${RESET} $(squeeze "$*")"
		return 0
	fi
	printf '+ %s\n' "$*" >> "$LOG_FILE"
	if ! eval "$*" >> "$LOG_FILE" 2>&1; then
		echo
		echo "${RED}Error: command failed:${RESET} $*" >&2
		echo "See $LOG_FILE for the full output." >&2
		exit 1
	fi
}

run_ignore_errors() {
	if is_dry_run; then
		echo "  ${DIM}(dry-run)${RESET} $(squeeze "$*")"
		return 0
	fi
	printf '+ %s\n' "$*" >> "$LOG_FILE"
	eval "$*" >> "$LOG_FILE" 2>&1 || true
}

run_capture() {
	eval "$*" 2>> "$LOG_FILE"
}

# Always through the machine's own connection, so the run neither depends on nor
# changes whatever Podman considers the default one.
podman_c() {
	podman --connection "$MACHINE" "$@"
}

# The same as a string, for the commands handed to run_cmd and to the generated
# scripts.
PODMAN_BIN=""
podman_cmd() {
	printf '%s --connection %s' "$PODMAN_BIN" "$MACHINE"
}

# --- Step output ---

step() {
	printf "${BRAND}+${RESET} %s" "$*"
}

step_ok() {
	printf " ${GREEN}%s${RESET}\n" "${1:-OK}"
}

step_line() {
	printf "${BRAND}+${RESET} %s\n" "$*"
}

# --- Install steps ---

check_macos() {
	_os="$(uname -s 2>/dev/null || echo unknown)"
	[ "$_os" = "Darwin" ] || \
		fatal "this is the macOS installer, but this system reports '$_os'. On Linux use install.sh instead: curl -fsSL https://get.mosaico.dev | sh"

	# Under sudo the machine, the containers, the wrapper and the LaunchAgent would
	# all be root's: an installation no user session can reach.
	if [ "$(id -u)" -eq 0 ]; then
		fatal "do not run this installer as root. Everything is installed for the current user, and a root-owned podman machine is not the one your shell would talk to. Run it again without sudo."
	fi
}

check_homebrew() {
	command_exists brew && return 0
	fatal "Homebrew was not found, and it is how podman is installed on macOS.
       Install it from https://brew.sh and run this again, or install podman
       yourself and re-run:

         /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
}

check_podman() {
	step "Checking podman..."
	if command_exists podman; then
		step_ok "OK (v$(podman --version | awk '{print $NF}'))"
	else
		step_ok "missing, installing with Homebrew"
		check_homebrew
		run_cmd "brew install podman"
		command_exists podman || is_dry_run || \
			fatal "podman is still not on the PATH after 'brew install podman'. Open a new shell and run this again."
	fi

	# Absolute: the generated starter and CLI wrapper run with launchd's minimal
	# PATH, which has neither /opt/homebrew/bin nor /usr/local/bin in it.
	PODMAN_BIN="$(command -v podman 2>/dev/null || echo podman)"

	check_podman_version
}

# Rejects 3.x builds, still shipped by some third-party taps, with a clear message
# instead of letting them fail on an unknown flag.
check_podman_version() {
	is_dry_run && ! command_exists podman && return 0

	version="$(podman --version | awk '{print $NF}')"
	major="$(echo "$version" | cut -d. -f1)"
	minor="$(echo "$version" | cut -d. -f2)"
	if [ "$major" -lt 4 ] 2>/dev/null || { [ "$major" -eq 4 ] 2>/dev/null && [ "$minor" -lt 4 ] 2>/dev/null; }; then
		fatal "podman $version is too old (needs >= 4.4). Upgrade it with 'brew upgrade podman'."
	fi
}

# GHCR serves manifests through the standard OCI Distribution API, which requires
# a short-lived bearer token before it can be read, even for a public image.
fetch_ghcr_token() {
	_repo_path="${MOSAICOD_IMAGE_REPO#ghcr.io/}"
	_url="https://ghcr.io/token?scope=repository:$_repo_path:pull&service=ghcr.io"
	if command_exists curl; then
		curl -fsSL "$_url" 2>> "$LOG_FILE"
	elif command_exists wget; then
		wget -qO- "$_url" 2>> "$LOG_FILE"
	fi
}

# The default tag ships together with this script, so only a --version pointed
# elsewhere is worth a round-trip to the registry, and only curl can tell a
# missing tag (404) apart from a network hiccup, so wget can only confirm the
# tag exists, never that it is missing.
check_mosaico_version() {
	[ "$MOSAICO_VERSION" = "$DEFAULT_MOSAICO_VERSION" ] && return 0
	{ command_exists curl || command_exists wget; } || return 0

	step "Checking that $MOSAICOD_IMAGE_REPO:$MOSAICO_VERSION exists..."

	_token="$(fetch_ghcr_token | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
	if [ -z "$_token" ]; then
		step_ok "skipped (could not reach ghcr.io)"
		return 0
	fi

	_repo_path="${MOSAICOD_IMAGE_REPO#ghcr.io/}"
	_manifest_url="https://ghcr.io/v2/$_repo_path/manifests/$MOSAICO_VERSION"
	_accept="application/vnd.oci.image.index.v1+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json"

	if command_exists curl; then
		_http_code="$(curl -s -o /dev/null -w '%{http_code}' -L \
			-H "Authorization: Bearer $_token" -H "Accept: $_accept" \
			"$_manifest_url")"
		case "$_http_code" in
			200) step_ok ;;
			404)
				echo
				fatal "image $MOSAICOD_IMAGE_REPO:$MOSAICO_VERSION was not found. Check that the tag is correct, or drop --version to use the default ($DEFAULT_MOSAICO_VERSION)."
				;;
			*) step_ok "skipped (registry returned HTTP $_http_code)" ;;
		esac
	elif wget -q --spider --header="Authorization: Bearer $_token" --header="Accept: $_accept" "$_manifest_url" 2>> "$LOG_FILE"; then
		step_ok
	else
		step_ok "skipped (could not verify with wget)"
	fi
}

machine_exists() {
	podman machine inspect "$MACHINE" >/dev/null 2>&1
}

# Asks the machine instead of parsing `podman machine list`, whose output format
# has changed between Podman releases.
machine_running() {
	podman_c info >/dev/null 2>&1
}

wait_for_machine() {
	_tries=0
	while [ "$_tries" -lt 60 ]; do
		machine_running && return 0
		_tries=$((_tries + 1))
		sleep 2
	done
	return 1
}

setup_machine() {
	step "Checking the podman machine '$MACHINE'..."

	if is_dry_run; then
		step_ok "skipped (dry-run)"
		echo "  ${DIM}(dry-run)${RESET} podman machine init $MACHINE --cpus $MACHINE_CPUS --memory $MACHINE_MEMORY --disk-size $MACHINE_DISK --now"
		echo "  ${DIM}(dry-run)${RESET} podman machine start $MACHINE"
		return 0
	fi

	if machine_exists; then
		if machine_running; then
			step_ok "running"
			return 0
		fi
		step_ok "stopped, starting"
		run_cmd "podman machine start $MACHINE"
	else
		step_ok "missing, creating"
		info "The first run downloads a virtual machine image; this takes a few minutes."
		run_cmd "podman machine init $MACHINE --cpus $MACHINE_CPUS --memory $MACHINE_MEMORY --disk-size $MACHINE_DISK --now"
	fi

	step "Waiting for the machine to accept commands..."
	if wait_for_machine; then
		step_ok "Ready"
	else
		step_ok "timed out"
		echo
		fatal "the podman machine '$MACHINE' did not become ready. Check it with 'podman machine list' and 'podman machine start $MACHINE'."
	fi
}

setup_directories() {
	step_line "Preparing $DATA_DIR"
	run_cmd "install -d -m 755 '$DATA_DIR'"
	run_cmd "install -d -m 755 '$DATA_DIR/bin'"
	run_cmd "install -d -m 700 '$SECRETS_DIR'"
	run_cmd "install -d -m 755 '$BIN_DIR'"
	if [ "$STORE_BACKEND" = "fs" ]; then
		step_line "Preparing local storage directory $FS_DIR"
		run_cmd "install -d -m 750 '$FS_DIR'"
	fi
}

# Copied into the secrets directory rather than mounted where they lie: a
# certificate outside $HOME could not be mounted into the virtual machine at all.
install_tls_material() {
	[ "$ENABLE_TLS" -eq 1 ] || return 0

	step_line "Installing TLS material in $TLS_DIR"

	if is_dry_run; then
		echo "  ${DIM}(dry-run)${RESET} copy $TLS_CERT to $TLS_DIR/cert.pem"
		echo "  ${DIM}(dry-run)${RESET} copy $TLS_KEY to $TLS_DIR/key.pem"
		return 0
	fi

	run_cmd "install -d -m 700 '$TLS_DIR'"
	run_cmd "install -m 600 '$TLS_CERT' '$TLS_DIR/cert.pem'"
	run_cmd "install -m 600 '$TLS_KEY' '$TLS_DIR/key.pem'"
}

# Reads a secret from disk when it already exists, otherwise generates it and
# persists it with 0600 permissions. Secrets never reach the terminal or the log.
read_or_create_secret() {
	_file="$1"
	_generator="$2"

	if [ -f "$_file" ]; then
		cat "$_file"
		return
	fi

	_value="$($_generator)"
	( umask 077 && printf '%s' "$_value" > "$_file" )
	printf '%s' "$_value"
}

# LC_ALL=C is required: under a UTF-8 locale the BSD tr rejects the bytes from
# /dev/urandom ("Illegal byte sequence") and the password comes out empty.
gen_password() {
	LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32
}

# Set by create_master_api_key(), which runs after the daemon is up: only
# mosaicod itself can mint a valid key.
MASTER_API_KEY=""

write_secrets() {
	step_line "Writing configuration secrets to $MOSAICOD_ENV_FILE"

	if is_dry_run; then
		if [ "$PG_MODE" = "embedded" ]; then
			echo "  ${DIM}(dry-run)${RESET} generate PostgreSQL password and mosaicod.env"
		else
			echo "  ${DIM}(dry-run)${RESET} write mosaicod.env pointing at $PG_HOST_IN_CONTAINER:$PG_PORT/$PG_DB"
		fi
		return 0
	fi

	# Must stay a plain KEY=VALUE list: the CLI wrapper feeds it back into
	# `podman exec --env-file`. It is read by the podman client on this Mac, not
	# inside the virtual machine, which is what keeps the credentials in a 0600 file
	# instead of on a command line.
	if [ "$PG_MODE" = "embedded" ]; then
		password="$(read_or_create_secret "$SECRETS_DIR/postgres_password" gen_password)"

		( umask 077 && cat > "$SECRETS_DIR/postgres.env" <<-EOF
		POSTGRES_USER=mosaico
		POSTGRES_DB=mosaico
		POSTGRES_PASSWORD=$password
		EOF
		)

		env_body="MOSAICOD_DB_URL=postgresql://mosaico:$password@$POSTGRES_CONTAINER:5432/mosaico"
	else
		env_body="MOSAICOD_DB_URL=postgresql://$(urlencode "$PG_USER"):$(urlencode "$PG_PASSWORD")@$PG_HOST_IN_CONTAINER:$PG_PORT/$(urlencode "$PG_DB")"
	fi

	# There is no backend key: mosaicod derives it from the endpoint scheme. The
	# file:// path is the mount inside the container, not the path on this Mac.
	if [ "$STORE_BACKEND" = "fs" ]; then
		env_body="$env_body
MOSAICOD_STORE_ENDPOINT=file:///data
MOSAICOD_STORE_BUCKET=mosaico"
	else
		env_body="$env_body
MOSAICOD_STORE_ENDPOINT=$OBJ_ENDPOINT
MOSAICOD_STORE_BUCKET=$OBJ_BUCKET
MOSAICOD_STORE_ACCESS_KEY=$OBJ_ACCESS_KEY
MOSAICOD_STORE_SECRET_KEY=$OBJ_SECRET_KEY"
	fi

	# TLS is switched on by --tls on the daemon's command line; these two keys only
	# say where the material is, in container paths.
	if [ "$ENABLE_TLS" -eq 1 ]; then
		env_body="$env_body
MOSAICOD_TLS_CERT_FILE=$TLS_CERT_IN_CONTAINER
MOSAICOD_TLS_PRIVATE_KEY_FILE=$TLS_KEY_IN_CONTAINER"
	fi

	# No cleanup keys: the routine is configured by the flags run_cleanup passes,
	# and MOSAICOD_CLEANUP_* no longer exists. That container reads this same file
	# for the connection string and the store keys above.

	( umask 077 && cat > "$MOSAICOD_ENV_FILE" <<-EOF
	$env_body
	EOF
	)
}

# Non-secret record of the choices made, read back by --uninstall. The database
# password is absent on purpose: it belongs in the 0600 environment file.
write_install_conf() {
	if is_dry_run; then
		echo "  ${DIM}(dry-run)${RESET} record configuration in $DATA_DIR/install.conf"
		return 0
	fi

	pg_record="PG_MODE=$PG_MODE"
	if [ "$PG_MODE" = "external" ]; then
		pg_record="$pg_record
PG_HOST=$PG_HOST
PG_HOST_IN_CONTAINER=$PG_HOST_IN_CONTAINER
PG_PORT=$PG_PORT
PG_USER=$PG_USER
PG_DB=$PG_DB"
	fi

	( umask 022 && cat > "$DATA_DIR/install.conf" <<-EOF
	# Generated by mosaicoctl (macOS) v$SCRIPT_VERSION. Do not edit by hand.
	PLATFORM=macos
	MOSAICO_VERSION=$MOSAICO_VERSION
	MOSAICOD_PORT=$MOSAICOD_PORT
	MOSAICOD_HOST=$MOSAICOD_HOST
	MACHINE=$MACHINE
	BIN_DIR=$BIN_DIR
	$pg_record
	STORE_BACKEND=$STORE_BACKEND
	FS_DIR=$FS_DIR
	OBJ_ENDPOINT=$OBJ_ENDPOINT
	OBJ_BUCKET=$OBJ_BUCKET
	ENABLE_TLS=$(bool_str "$ENABLE_TLS")
	TLS_CERT=$TLS_CERT
	TLS_KEY=$TLS_KEY
	DOMAIN=$DOMAIN
	API_KEY=$(bool_str "$API_KEY")
	CLEANUP=$(bool_str "$CLEANUP")
	CLEANUP_RETENTION=$CLEANUP_RETENTION
	CLEANUP_INTERVAL=$CLEANUP_INTERVAL
	SDK=$(bool_str "$SDK")
	EOF
	)
}

# A step of its own so that a missing image is reported with its tag and
# architecture, rather than as a failure of the run command below.
pull_images() {
	step_line "Pulling container images"

	_images="$MOSAICOD_IMAGE_REPO:$MOSAICO_VERSION"
	[ "$PG_MODE" = "embedded" ] && _images="$_images $POSTGRES_IMAGE"

	for _image in $_images; do
		_platform_arg=""
		[ -n "$PLATFORM" ] && [ "$_image" != "$POSTGRES_IMAGE" ] && _platform_arg=" --platform $PLATFORM"

		step "  $_image..."
		if is_dry_run; then
			step_ok "skipped (dry-run)"
			continue
		fi

		if run_capture "$(podman_cmd) pull$_platform_arg '$_image'" >/dev/null 2>&1; then
			step_ok "Done"
		else
			step_ok "failed"
			echo
			printf "${RED}Error:${RESET} could not pull %s.\n" "$_image" >&2
			if [ -z "$PLATFORM" ] && [ "$(uname -m)" = "arm64" ]; then
				echo >&2
				echo "This is an Apple Silicon Mac. If that tag is published only for" >&2
				echo "linux/amd64, re-run with --platform linux/amd64 to run it emulated." >&2
			fi
			echo >&2
			echo "See $LOG_FILE for the full output." >&2
			exit 1
		fi
	done
}

ensure_network() {
	if is_dry_run; then
		echo "  ${DIM}(dry-run)${RESET} podman network create $PODMAN_NETWORK"
		return 0
	fi

	# `network exists` returning 1 is a test result, not a failure, so it cannot go
	# through run_cmd.
	if podman_c network exists "$PODMAN_NETWORK" >/dev/null 2>&1; then
		return 0
	fi
	step_line "Creating the $PODMAN_NETWORK container network"
	run_cmd "$(podman_cmd) network create $PODMAN_NETWORK"
}

container_exists() {
	podman_c container exists "$1" >/dev/null 2>&1
}

# A container's command line, mounts and environment are fixed when it is created,
# so applying a changed setting means removing and creating it again. Nothing
# durable lives inside: the database is in a Podman volume, the frames under $HOME.
recreate_container() {
	_name="$1"
	if is_dry_run; then
		echo "  ${DIM}(dry-run)${RESET} podman rm -f $_name (if present)"
		return 0
	fi
	container_exists "$_name" || return 0
	run_ignore_errors "$(podman_cmd) rm -f $_name"
}

run_postgres() {
	[ "$PG_MODE" = "embedded" ] || return 0

	step_line "Creating the $POSTGRES_CONTAINER container"
	recreate_container "$POSTGRES_CONTAINER"

	# --restart=always covers a crash while the Mac is up; it does not survive a
	# reboot, which is what the LaunchAgent is for.
	run_cmd "$(podman_cmd) run -d \
		--name $POSTGRES_CONTAINER \
		--network $PODMAN_NETWORK \
		--restart=always \
		--env-file '$SECRETS_DIR/postgres.env' \
		-v $POSTGRES_VOLUME:/var/lib/postgresql \
		$POSTGRES_IMAGE"
}

wait_for_postgres() {
	[ "$PG_MODE" = "embedded" ] || return 0

	if is_dry_run; then
		echo "  ${DIM}(dry-run)${RESET} wait for PostgreSQL to accept connections"
		return 0
	fi

	step "Waiting for PostgreSQL to accept connections..."
	tries=0
	while [ "$tries" -lt 30 ]; do
		if podman_c exec "$POSTGRES_CONTAINER" pg_isready -U mosaico >> "$LOG_FILE" 2>&1; then
			step_ok "Ready"
			return 0
		fi
		tries=$((tries + 1))
		sleep 2
	done

	echo
	printf "${RED}Error:${RESET} PostgreSQL did not become ready in time. Container logs:\n" >&2
	podman_c logs --tail 40 "$POSTGRES_CONTAINER" 2>&1 | tee -a "$LOG_FILE" >&2
	exit 1
}

# Non-fatal: a probe from this Mac cannot prove what the container will manage, and
# the tools it needs may not be installed.
check_external_postgres() {
	[ "$PG_MODE" = "external" ] || return 0

	step "Checking the PostgreSQL instance at $PG_HOST:$PG_PORT..."

	if is_dry_run; then
		step_ok "skipped (dry-run)"
		return 0
	fi

	if command_exists pg_isready; then
		if pg_isready -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -t 5 >> "$LOG_FILE" 2>&1; then
			step_ok "Accepting connections"
		else
			step_ok "unreachable"
			warn "pg_isready could not reach $PG_HOST:$PG_PORT from this Mac. The installation continues, but mosaicod will fail to start if the database is not reachable from the container."
		fi
	elif command_exists nc; then
		if nc -z -G 5 "$PG_HOST" "$PG_PORT" >> "$LOG_FILE" 2>&1; then
			step_ok "Port open"
		else
			step_ok "unreachable"
			warn "nothing is listening on $PG_HOST:$PG_PORT as seen from this Mac. The installation continues, but mosaicod will fail to start if the database is not reachable from the container."
		fi
	else
		step_ok "skipped (no pg_isready or nc on this Mac)"
	fi

	if [ "$PG_HOST_IS_LOCAL" -eq 1 ]; then
		warn "PostgreSQL is on this Mac, so the container reaches it as $PG_HOST_IN_CONTAINER: it has to listen on an address other than 127.0.0.1 (listen_addresses) and accept connections from the podman machine in pg_hba.conf. Passing the Mac's LAN address as --pg-host avoids this."
	fi
}

# Removes a database container left by a previous embedded installation. The volume
# is kept: it is the old database, and switching back has to find it there.
drop_embedded_postgres() {
	[ "$PG_MODE" = "external" ] || return 0

	if is_dry_run; then
		echo "  ${DIM}(dry-run)${RESET} remove any embedded PostgreSQL container left from a previous run"
		return 0
	fi

	container_exists "$POSTGRES_CONTAINER" || return 0

	step_line "Removing the embedded PostgreSQL container of the previous installation"
	run_ignore_errors "$(podman_cmd) rm -f $POSTGRES_CONTAINER"
	warn "the embedded database container was removed; its data is still in the $POSTGRES_VOLUME volume, which was left in place."
}

run_mosaicod() {
	step_line "Creating the $MOSAICOD_CONTAINER container"
	recreate_container "$MOSAICOD_CONTAINER"

	# `server` exists from 0.6 on; 0.5 images take `run` instead. --host 0.0.0.0 is
	# mandatory and is not $MOSAICOD_HOST: mosaicod binds the loopback by default, and
	# a published port is DNAT'd to the container's address, which a process on
	# 127.0.0.1 inside it never sees. What the operator chose is the host side of the
	# -p mapping below. --tls and --api-key are switches, not configuration keys:
	# without them the daemon ignores the TLS material and the keys in the environment
	# file.
	_exec_args="server --host 0.0.0.0 --port $MOSAICOD_PORT"
	[ "$ENABLE_TLS" -eq 1 ] && _exec_args="$_exec_args --tls"
	[ "$API_KEY" -eq 1 ] && _exec_args="$_exec_args --api-key"

	_mounts=""
	[ "$STORE_BACKEND" = "fs" ] && _mounts="$_mounts -v '$FS_DIR':/data"
	# Read-only: the daemon only reads this material.
	[ "$ENABLE_TLS" -eq 1 ] && _mounts="$_mounts -v '$TLS_DIR':/certs:ro"

	_platform_arg=""
	[ -n "$PLATFORM" ] && _platform_arg="--platform $PLATFORM"

	run_cmd "$(podman_cmd) run -d \
		--name $MOSAICOD_CONTAINER \
		--network $PODMAN_NETWORK \
		--restart=always \
		--env-file '$MOSAICOD_ENV_FILE' \
		-p $MOSAICOD_HOST:$MOSAICOD_PORT:$MOSAICOD_PORT \
		$_mounts $_platform_arg \
		$MOSAICOD_IMAGE_REPO:$MOSAICO_VERSION \
		$_exec_args"

	is_dry_run || sleep 3

	# `podman run -d` reports success for a container that then exits immediately
	# (a bad connection string, an unreadable certificate), so the state is checked
	# explicitly and the logs printed.
	if ! is_dry_run && ! podman_c ps --filter "name=^${MOSAICOD_CONTAINER}$" --format '{{.Names}}' 2>/dev/null | grep -q "^${MOSAICOD_CONTAINER}$"; then
		echo
		printf "${RED}Error:${RESET} the %s container is not running. Container logs:\n" "$MOSAICOD_CONTAINER" >&2
		echo >&2
		podman_c logs --tail 40 "$MOSAICOD_CONTAINER" 2>&1 | tee -a "$LOG_FILE" >&2
		echo >&2
		exit 1
	fi
}

# The cleanup routine is a separate process from 0.6 on. Same image, environment
# file and store (it deletes frames from the store and reads the database to know
# which ones), with no published port and no certificate.
run_cleanup() {
	[ "$CLEANUP" -eq 1 ] || return 0

	step_line "Creating the $CLEANUP_CONTAINER container"
	recreate_container "$CLEANUP_CONTAINER"

	_interval_seconds="$CLEANUP_DEFAULT_INTERVAL_SECONDS"
	[ -n "$CLEANUP_INTERVAL" ] && _interval_seconds="$(duration_to_seconds "$CLEANUP_INTERVAL")"

	_cleanup_args="cleanup --time-interval $_interval_seconds"
	# Omitted when unset, so the subcommand applies its own retention default.
	[ -n "$CLEANUP_RETENTION" ] && \
		_cleanup_args="$_cleanup_args --retention-duration $(duration_to_seconds "$CLEANUP_RETENTION")"

	_cleanup_mounts=""
	[ "$STORE_BACKEND" = "fs" ] && _cleanup_mounts="-v '$FS_DIR':/data"

	_platform_arg=""
	[ -n "$PLATFORM" ] && _platform_arg="--platform $PLATFORM"

	run_cmd "$(podman_cmd) run -d \
		--name $CLEANUP_CONTAINER \
		--network $PODMAN_NETWORK \
		--restart=always \
		--env-file '$MOSAICOD_ENV_FILE' \
		$_cleanup_mounts $_platform_arg \
		$MOSAICOD_IMAGE_REPO:$MOSAICO_VERSION \
		$_cleanup_args"
}

# A container left by an earlier run would keep pruning frames after --no-cleanup.
drop_cleanup_container() {
	[ "$CLEANUP" -eq 0 ] || return 0

	if is_dry_run; then
		echo "  ${DIM}(dry-run)${RESET} remove any cleanup container left from a previous run"
		return 0
	fi

	container_exists "$CLEANUP_CONTAINER" || return 0

	step_line "Removing the cleanup container of the previous installation"
	run_ignore_errors "$(podman_cmd) rm -f $CLEANUP_CONTAINER"
}

# A key is a database row, so only mosaicod can mint one: this cannot happen while
# the environment file is being written. read|write|delete is the whole permission
# set from 0.6 on, `manage` having been removed. An existing key on disk is reused
# rather than adding another.
create_master_api_key() {
	[ "$API_KEY" -eq 1 ] || return 0

	step "Creating master API key..."

	if is_dry_run; then
		echo
		echo "  ${DIM}(dry-run)${RESET} podman exec $MOSAICOD_CONTAINER mosaicod api-key create --permissions 'read|write|delete'"
		return 0
	fi

	if [ -f "$SECRETS_DIR/master_api_key" ]; then
		MASTER_API_KEY="$(cat "$SECRETS_DIR/master_api_key")"
		step_ok "Reused"
		return 0
	fi

	MASTER_API_KEY="$(run_capture "$(podman_cmd) exec --env-file='$MOSAICOD_ENV_FILE' $MOSAICOD_CONTAINER \
		mosaicod api-key create --permissions 'read|write|delete' --description 'Master key created by mosaicoctl'" \
		| tr -d '\r\n')"

	if [ -z "$MASTER_API_KEY" ]; then
		echo
		printf "${RED}Error:${RESET} the daemon did not return an API key. See %s for the full output.\n" "$LOG_FILE" >&2
		exit 1
	fi

	( umask 077 && printf '%s' "$MASTER_API_KEY" > "$SECRETS_DIR/master_api_key" )
	step_ok "Done"
}

# Makes `mosaicod ...` behave like a native binary: it forwards into the container
# and re-injects the environment file, so the CLI sees the daemon's configuration.
# It needs no privileges, and it only works while the daemon is up: `podman exec`
# needs a running container.
install_cli_wrapper() {
	_wrapper="$BIN_DIR/$CLI_WRAPPER_NAME"
	step_line "Creating CLI wrapper in $_wrapper"

	if is_dry_run; then
		echo "  ${DIM}(dry-run)${RESET} write $_wrapper and chmod 755"
		return 0
	fi

	# Unquoted heredoc: paths and machine name are baked in now, so the wrapper does
	# not depend on $HOME or on the active Podman connection when it runs. $@ and the
	# wrapper's own variables are escaped to survive until then.
	cat > "$_wrapper" <<-EOF
	#!/bin/sh
	# Generated by mosaicoctl (macOS) v$SCRIPT_VERSION. Do not edit by hand.
	set -e

	PODMAN="$PODMAN_BIN"
	CONNECTION="$MACHINE"
	ENV_FILE="$MOSAICOD_ENV_FILE"
	CONTAINER="$MOSAICOD_CONTAINER"

	# An interactive terminal gets one in the container too.
	TTY_ARGS=""
	if [ -t 0 ] && [ -t 1 ]; then
	    TTY_ARGS="-it"
	fi

	ENV_ARGS=""
	if [ -f "\$ENV_FILE" ]; then
	    ENV_ARGS="--env-file=\$ENV_FILE"
	fi

	# Podman's own error for a stopped machine ("unable to connect") says nothing
	# about what to do.
	if ! "\$PODMAN" --connection "\$CONNECTION" info >/dev/null 2>&1; then
	    echo "mosaicod: the podman machine '\$CONNECTION' is not running." >&2
	    echo "          Start it with: podman machine start \$CONNECTION" >&2
	    exit 1
	fi

	exec "\$PODMAN" --connection "\$CONNECTION" exec \$TTY_ARGS \$ENV_ARGS "\$CONTAINER" mosaicod "\$@"
	EOF
	# An absolute mode, not +x: `cat >` creates the file according to the current
	# umask, which +x would only add the execute bit on top of.
	run_cmd "chmod 755 '$_wrapper'"
}

install_mosaicoctl() {
	_mosaicoctl="$BIN_DIR/$MOSAICOCTL_NAME"

	if is_dry_run; then
		echo "  ${DIM}(dry-run)${RESET} copy installer to $_mosaicoctl"
		return 0
	fi

	step_line "Installing management CLI in $_mosaicoctl"
	if [ -f "$0" ] && [ -s "$0" ]; then
		run_cmd "cp '$0' '$_mosaicoctl'"
	else
		# Reached when the script was piped in (curl | sh) and so has no readable
		# path on disk.
		run_cmd "curl -fsSL $INSTALLER_URL -o '$_mosaicoctl'"
	fi
	# An absolute mode, not +x: cp/curl create the file according to the current
	# umask, which +x would only add the execute bit on top of.
	run_cmd "chmod 755 '$_mosaicoctl'"
}

# Brings Mosaico back after a reboot: a starter script, and a LaunchAgent that runs
# it at login. An agent and not a daemon, because a podman machine belongs to a
# user and root would not find it: Mosaico therefore comes up at login, not at boot.
install_launch_agent() {
	step_line "Installing the login starter in $STARTER"

	if is_dry_run; then
		echo "  ${DIM}(dry-run)${RESET} write $STARTER and chmod 755"
		echo "  ${DIM}(dry-run)${RESET} write $LAUNCH_AGENT"
		echo "  ${DIM}(dry-run)${RESET} launchctl bootout/bootstrap gui/$(id -u) $LAUNCH_AGENT"
		return 0
	fi

	# Only the containers this installation has are named. Each line is written to
	# expand when the starter runs, not now.
	_start_postgres=""
	[ "$PG_MODE" = "embedded" ] && \
		_start_postgres="\"\$PODMAN\" --connection \"\$CONNECTION\" start $POSTGRES_CONTAINER >/dev/null 2>&1 || true"
	_start_cleanup=""
	[ "$CLEANUP" -eq 1 ] && \
		_start_cleanup="\"\$PODMAN\" --connection \"\$CONNECTION\" start $CLEANUP_CONTAINER >/dev/null 2>&1 || true"

	# Absolute podman path: launchd gives its jobs a minimal PATH with neither
	# /opt/homebrew/bin nor /usr/local/bin in it.
	cat > "$STARTER" <<-EOF
	#!/bin/sh
	# Generated by mosaicoctl (macOS) v$SCRIPT_VERSION. Do not edit by hand.
	#
	# Started by launchd at login through $LAUNCH_AGENT.
	# Errors are not fatal: a machine already running, or containers already up,
	# must not turn into a failed job.

	PODMAN="$PODMAN_BIN"
	CONNECTION="$MACHINE"

	"\$PODMAN" machine start "\$CONNECTION" >/dev/null 2>&1 || true

	# The machine answers a few seconds after start returns.
	tries=0
	while [ "\$tries" -lt 60 ]; do
	    "\$PODMAN" --connection "\$CONNECTION" info >/dev/null 2>&1 && break
	    tries=\$((tries + 1))
	    sleep 2
	done

	# Ordered: mosaicod fails its first connection if the database is not up yet, and
	# the cleanup needs the schema the daemon creates.
	$_start_postgres
	sleep 5
	"\$PODMAN" --connection "\$CONNECTION" start $MOSAICOD_CONTAINER >/dev/null 2>&1 || true
	$_start_cleanup
	EOF
	# An absolute mode, not +x: `cat >` creates the file according to the current
	# umask, which +x would only add the execute bit on top of.
	run_cmd "chmod 755 '$STARTER'"

	step_line "Installing the LaunchAgent in $LAUNCH_AGENT"
	run_cmd "install -d -m 755 '$LAUNCH_AGENT_DIR'"

	# RunAtLoad with no KeepAlive: the starter exits once the containers are up, and
	# KeepAlive would have launchd restart it forever.
	cat > "$LAUNCH_AGENT" <<-EOF
	<?xml version="1.0" encoding="UTF-8"?>
	<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
	<plist version="1.0">
	<dict>
	    <key>Label</key>
	    <string>$LAUNCH_LABEL</string>
	    <key>ProgramArguments</key>
	    <array>
	        <string>/bin/sh</string>
	        <string>$STARTER</string>
	    </array>
	    <key>RunAtLoad</key>
	    <true/>
	    <key>StandardOutPath</key>
	    <string>$STARTER_LOG</string>
	    <key>StandardErrorPath</key>
	    <string>$STARTER_LOG</string>
	</dict>
	</plist>
	EOF
	run_cmd "chmod 644 '$LAUNCH_AGENT'"

	# bootout first, so a re-run replaces an already registered job instead of
	# failing on it. Both may fail without consequence: the containers are running,
	# and the agent only matters at the next login.
	run_ignore_errors "launchctl bootout gui/$(id -u)/$LAUNCH_LABEL"
	run_ignore_errors "launchctl bootstrap gui/$(id -u) '$LAUNCH_AGENT'"
}

# Checked up front because pip reports an interpreter that is too old as "no
# matching distribution", which reads as a network or naming problem.
SDK_MIN_PYTHON="3.10"

check_python() {
	step "Checking Python for the SDK..."

	# On a bare macOS /usr/bin/python3 is a stub that opens the Xcode Command Line
	# Tools installer, and command_exists cannot tell it from a real interpreter, so
	# the probe below is what decides.
	if ! command_exists python3 || ! python3 -c 'import sys' >/dev/null 2>&1; then
		step_ok "missing, installing with Homebrew"
		check_homebrew
		run_cmd "brew install python3"
		return
	fi

	if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null; then
		step_ok "too old"
		echo
		fatal "$SDK_PACKAGE needs Python $SDK_MIN_PYTHON or newer, but python3 here is
       $(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || echo unknown).
       Install a newer interpreter with 'brew install python3', or re-run without
       --sdk and install the SDK yourself in an environment of your choosing."
	fi

	step_ok "OK (v$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])'))"
}

install_sdk() {
	[ "$SDK" -eq 1 ] || return 0

	check_python

	step_line "Installing the $SDK_PACKAGE SDK in $SDK_VENV"

	if is_dry_run; then
		echo "  ${DIM}(dry-run)${RESET} python3 -m venv $SDK_VENV"
		echo "  ${DIM}(dry-run)${RESET} $SDK_VENV/bin/pip install --upgrade $SDK_PACKAGE"
		return 0
	fi

	# Created only when absent, so a re-run keeps whatever else was pip installed
	# into it; --upgrade is then what actually updates the SDK, since a plain install
	# would report the requirement as already satisfied.
	if [ ! -x "$SDK_VENV/bin/python" ]; then
		run_cmd "python3 -m venv '$SDK_VENV'"
	fi
	run_cmd "'$SDK_VENV/bin/pip' install --quiet --upgrade pip"
	run_cmd "'$SDK_VENV/bin/pip' install --quiet --upgrade $SDK_PACKAGE"
}

# ~/.local/bin is on the default PATH of a recent macOS zsh but not of every shell.
# Reported rather than fixed: this script does not edit shell profiles.
BIN_DIR_ON_PATH=1

check_bin_dir() {
	case ":$PATH:" in
		*":$BIN_DIR:"*) BIN_DIR_ON_PATH=1 ;;
		*) BIN_DIR_ON_PATH=0 ;;
	esac
}

print_logo() {
	echo
	if supports_utf8; then
		echo "${BOLD}                           ▀▀${RESET}"
		echo "${BOLD}███▄███▄ ▄███▄ ▄█▀▀▀  ▀▀█▄ ██  ▄████ ▄███▄${RESET}"
		echo "${BOLD}██ ██ ██ ██ ██ ▀███▄ ▄█▀██ ██  ██    ██ ██${RESET}"
		echo "${BOLD}██ ██ ██ ▀███▀ ▄▄▄█▀ ▀█▄██ ██▄ ▀████ ▀███▀${RESET}"
	else
		echo "${BOLD}mosaico${RESET}"
	fi
	echo
	echo "  ${BRAND}${ARROW}${RESET}  System detected: ${BRAND}${BOLD}macOS${RESET}"
}

print_disclaimer() {
	section "Before you begin"
	echo "  ${YELLOW}!${RESET} ${BOLD}Do not run this inside a macOS virtual machine.${RESET}"
	echo "    macOS cannot run Linux containers itself, so podman runs them in a Linux"
	echo "    virtual machine of its own. On a virtualised Mac that machine is a guest"
	echo "    inside a guest, which needs nested virtualization: most Mac hypervisors"
	echo "    do not expose it, and where they do it is unreliable. Expect the podman"
	echo "    machine to fail to start, or to start and behave erratically. Install on"
	echo "    the host instead."
}

# --- AI coding assistant skills (--ai) ---
#
# Mosaico publishes skills for AI coding assistants in the .agents/skills/ folder
# of its main repository, one folder per skill holding a SKILL.md and any file next
# to it. --ai copies each of them, as it is, into two folders of the home of the
# user who ran the installer, always both: ~/.claude/skills, which Claude Code
# reads, and ~/.agents/skills, the shared folder Codex, GitHub Copilot, Cursor and
# Gemini CLI read. The documentation behind each is cited in mosaico.7. Anything
# else in .agents/, the agents folder included, is ignored.
#
# The installer runs as the user (check_macos refuses root), so they go into that
# user's own home. Writing and removing files is done by the same small script as
# in install.sh, run here directly rather than through runuser.
#
# Every file written is recorded with its sha256 in ~/.mosaico/ai-manifest. A
# re-run replaces a file only while its content is still the one recorded there,
# so an edit made by the user survives with a warning, and a file this installer
# did not write is never touched. On the same condition a re-run deletes the
# recorded files Mosaico no longer ships, and --ai --remove deletes all of them,
# then the manifest; both only inside those two folders.

AI_REPO_URL="https://github.com/mosaico-labs/mosaico"
# The skills come from one commit of that repository, pinned by its full sha (40
# lowercase hex characters) and never by a branch or a tag, which can move, and
# are checked against the hash of their content before anything is written. Of
# the content and not of the archive: GitHub generates those on the fly and does
# not promise the same bytes twice. While AI_SKILLS_REF is empty the skills are
# not released, and --ai installs nothing; set without a 64-character
# AI_SKILLS_SHA256 next to it, --ai refuses to install anything.
#
# The two change together. For a new ref, compute the hash on the archive GitHub
# serves for that commit, the one the installer downloads, never on a checkout:
# untracked files (.DS_Store, editor swap files), line endings rewritten by
# core.autocrlf, Git LFS pointers and export-ignore all make a working tree
# differ from it. In an empty directory, with <sha> the full commit sha:
#
#   curl -fsSL https://github.com/mosaico-labs/mosaico/archive/<sha>.tar.gz |
#       tar -xzf - mosaico-<sha>/.agents/skills &&
#   cd mosaico-<sha>/.agents && find skills -type f | LC_ALL=C sort |
#       while IFS= read -r f; do
#           printf '%s  %s\n' "$(sha256sum < "$f" | cut -d' ' -f1)" "$f"
#       done | sha256sum | cut -d' ' -f1
#
# with `shasum -a 256` in place of both sha256sum where there is none, as on
# macOS. That is ai_verify in the worker: one "<sha256>  <path>" line for every
# regular file under skills/, its path relative to .agents/, the lines sorted
# bytewise, and the sha256 of that list. A skills folder holding anything but
# directories and regular files, or a name with a newline in it, is refused
# before that, so the list is always well defined.
AI_SKILLS_REF=""
AI_SKILLS_SHA256=""
# The oldest Mosaico the skills are written for, compared on major and minor
# alone: they describe the main branch after mosaico-labs/mosaico#817, which no
# release before 0.8 has.
AI_MIN_MOSAICO_VERSION="0.8.0"
# Set by ai_resolve_user, ai_fetch_bundle and ai_download.
AI_USER=""
AI_HOME=""
AI_MANIFEST=""
AI_SOURCE_DIR=""
AI_SOURCE_LABEL=""
AI_SOURCE_SHA256=""
AI_REFUSAL=""
AI_TMP=""

# The user running the installer: check_macos has already refused root.
ai_resolve_user() {
	AI_USER="$(id -un)"
	AI_HOME="$HOME"
	[ -n "$AI_HOME" ] && [ -d "$AI_HOME" ] || return 1
	AI_MANIFEST="$AI_HOME/.mosaico/ai-manifest"
}

# Whether there are skills to install: a pinned commit, or a local source.
ai_released() {
	[ -n "$AI_SKILLS_REF" ] || [ -n "${MOSAICO_AI_SOURCE:-}" ]
}

# The major and minor of a version, as version_major_minor gives them, for the
# skills' check alone, which reads two kinds of value differently: one of digits
# alone, 7 or more of them, is a short commit sha (is_commit_sha) rather than a
# major, and a number of 10 digits or more does not fit the shell's arithmetic.
# Nothing for both, as for any value that is not a release number.
ai_version_mm() {
	case "${1#v}" in
		*.*) ;;
		*) if is_commit_sha "$1"; then return 0; fi ;;
	esac
	_mm="$(version_major_minor "$1")"
	case "${_mm% *}/${_mm#* }" in
		??????????*/*|*/??????????*) return 0 ;;
	esac
	echo "$_mm"
}

# True when MOSAICO_VERSION is AI_MIN_MOSAICO_VERSION or newer, by major and minor,
# or is not a release number at all (latest, a commit sha), which cannot be
# compared: ai_check_version warns about that one.
ai_version_supported() {
	_av="$(ai_version_mm "$MOSAICO_VERSION")"
	[ -n "$_av" ] || return 0
	_amin="$(version_major_minor "$AI_MIN_MOSAICO_VERSION")"
	if [ "${_av% *}" -ne "${_amin% *}" ]; then
		[ "${_av% *}" -gt "${_amin% *}" ]
	else
		[ "${_av#* }" -ge "${_amin#* }" ]
	fi
}

# Refuses --ai alone, before anything is installed, for a Mosaico older than the
# skills. Checked only when MOSAICO_VERSION is set, since the daemon may run on
# another machine. A full installation is not refused: install_ai skips the
# skills with a warning, and the rest of it goes on. Not applied while there are
# no skills.
ai_check_version() {
	[ "$AI" -eq 1 ] && [ "$AI_REMOVE" -eq 0 ] && ai_released || return 0
	[ "$AI_ONLY" -eq 0 ] || [ "$MOSAICO_VERSION_SET" -eq 1 ] || return 0
	if [ -z "$(ai_version_mm "$MOSAICO_VERSION")" ]; then
		warn "'$MOSAICO_VERSION' is not a release number, so it cannot be checked against Mosaico $AI_MIN_MOSAICO_VERSION, the oldest the skills are written for: they may describe commands it does not have."
	elif [ "$AI_ONLY" -eq 1 ] && ! ai_version_supported; then
		fatal "--ai: Mosaico's skills are written for Mosaico $AI_MIN_MOSAICO_VERSION or newer, and MOSAICO_VERSION is $MOSAICO_VERSION: they would describe commands and options it does not have.
    Once you run $AI_MIN_MOSAICO_VERSION or newer, give that version: MOSAICO_VERSION=$AI_MIN_MOSAICO_VERSION sh install-mosaico.sh --ai. Or leave MOSAICO_VERSION out to skip the check."
	fi
}

# ai_is_hex <value> <length>: whether <value> is <length> lowercase hex digits.
ai_is_hex() {
	case "$1" in
		*[!0-9a-f]*) return 1 ;;
	esac
	[ "${#1}" -eq "$2" ]
}

# ai_download <url> <file>: over HTTPS alone, TLS 1.2 or newer, redirects included
# (GitHub sends archives on to codeload.github.com). wget's --https-only does not
# cover redirects, so with wget the response headers are read back and a download
# that went through a plain-HTTP Location is thrown away, refused (status 3).
ai_download() {
	if command_exists curl; then
		curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL -o "$2" "$1" 2>> "$LOG_FILE" || return 1
	elif command_exists wget; then
		_wrc=0
		wget --https-only --secure-protocol=TLSv1_2 -S -q -O "$2" "$1" 2> "$2.headers" || _wrc=$?
		cat "$2.headers" >> "$LOG_FILE" 2>/dev/null || true
		[ "$_wrc" -eq 0 ] || return 1
		if grep -Eiq '^[[:space:]]*location:[[:space:]]*http:' "$2.headers"; then
			rm -f "$2"
			AI_REFUSAL="the download of $1 was redirected to plain HTTP."
			return 3
		fi
	else
		return 1
	fi
}

# Points AI_SOURCE_DIR at a folder holding the skills/ to install: .agents/ in the
# repository archive of commit AI_SKILLS_REF, of which only .agents/skills/ is
# extracted, or a copy of MOSAICO_AI_SOURCE/skills/ when that is set. Done on a dry
# run as well, into a temporary directory, since the files it would write cannot
# be listed otherwise. Only the download runs as root: the archive is unpacked,
# and MOSAICO_AI_SOURCE copied, by AI_USER into a folder of AI_TMP that user owns,
# so root never creates a device node or a setuid file from an archive it has not
# checked, nor reads a path the user picked. ai_verify, in the worker, then refuses
# anything there but directories and regular files and computes the content hash,
# in AI_SOURCE_SHA256. Returns 1 when the source could not be reached or read, 2
# when it holds no skills folder, 3 when it is refused, with the reason in
# AI_REFUSAL: a pin that is not a full sha and a sha256, a redirect to plain HTTP,
# an archive that does not unpack cleanly, an entry that is not a directory or a
# regular file, or content that is not the pinned one; 4 when the downloaded
# archive cannot be read at all, being damaged or cut short; 5 when the check
# itself could not run. MOSAICO_AI_SOURCE stands in for the pinned commit in
# tests, so it is not checked against the hash, with a warning.
ai_fetch_bundle() {
	AI_REFUSAL=""
	AI_SOURCE_SHA256=""
	if [ -n "${MOSAICO_AI_SOURCE:-}" ]; then
		AI_SOURCE_LABEL="$MOSAICO_AI_SOURCE (MOSAICO_AI_SOURCE)"
	else
		AI_SOURCE_LABEL="$AI_REPO_URL, commit $AI_SKILLS_REF"
		if ! ai_is_hex "$AI_SKILLS_REF" 40 || ! ai_is_hex "$AI_SKILLS_SHA256" 64; then
			AI_REFUSAL="this installer pins the skills to commit '$AI_SKILLS_REF' with content hash '$AI_SKILLS_SHA256', where a full commit sha (40 lowercase hex characters) and a sha256 (64) are needed, so it cannot check them."
			return 3
		fi
	fi
	ai_make_tmp || return 1
	mkdir "$AI_TMP/src" || return 1
	if [ "$(id -u)" -eq 0 ]; then
		chown "$AI_USER" "$AI_TMP/src" 2>> "$LOG_FILE" || return 1
	fi
	if [ -n "${MOSAICO_AI_SOURCE:-}" ]; then
		AI_SOURCE_DIR="$AI_TMP/src"
		ai_as_user test -d "$MOSAICO_AI_SOURCE/skills" 2>> "$LOG_FILE" || return 2
		ai_as_user cp -R "$MOSAICO_AI_SOURCE/skills" "$AI_SOURCE_DIR/" 2>> "$LOG_FILE" || return 1
	else
		_tgz="$AI_TMP/mosaico.tar.gz"
		_frc=0
		ai_download "$AI_REPO_URL/archive/$AI_SKILLS_REF.tar.gz" "$_tgz" || _frc=$?
		[ "$_frc" -eq 0 ] || return "$_frc"
		chmod 644 "$_tgz" || return 1
		# GitHub names the archive's single top-level directory after the
		# repository and the full commit sha. Nothing else is extracted.
		_top="mosaico-$AI_SKILLS_REF"
		AI_SOURCE_DIR="$AI_TMP/src/$_top/.agents"
		if ! ai_as_user tar --no-same-owner -xzf "$_tgz" -C "$AI_TMP/src" "$_top/.agents/skills" 2>> "$LOG_FILE"; then
			# A damaged archive fails here as well: only one that can be listed
			# is known to lack the folder.
			ai_as_user tar -tzf "$_tgz" > /dev/null 2>> "$LOG_FILE" || return 4
			ai_as_user test -d "$AI_SOURCE_DIR/skills" 2>> "$LOG_FILE" || return 2
			AI_REFUSAL="the archive of $AI_SOURCE_LABEL could not be unpacked cleanly (see $LOG_FILE)."
			return 3
		fi
	fi
	_frc=0
	AI_SOURCE_SHA256="$(ai_run_worker verify)" || _frc=$?
	case "$_frc" in
		10) ;;
		11)
			AI_SOURCE_SHA256=""
			AI_REFUSAL="the skills from $AI_SOURCE_LABEL could not be checked (see the warning above)."
			return 3
			;;
		*) return 5 ;;
	esac
	if [ -n "${MOSAICO_AI_SOURCE:-}" ]; then
		warn "MOSAICO_AI_SOURCE is set: its skills are not checked against AI_SKILLS_SHA256 (their content hash is $AI_SOURCE_SHA256)."
		return 0
	fi
	if [ -z "$AI_SOURCE_SHA256" ] || [ "$AI_SOURCE_SHA256" != "$AI_SKILLS_SHA256" ]; then
		AI_REFUSAL="the skills downloaded from $AI_SOURCE_LABEL are not the ones this installer pins: their content hash is ${AI_SOURCE_SHA256:-empty}, not $AI_SKILLS_SHA256."
		return 3
	fi
}

# Always under /tmp, never under $TMPDIR: with libpam-tmpdir, sudo points that at
# /tmp/user/0, which the user the worker runs as cannot enter. Mode 711: that user
# gets through it to the files it is handed by name, and can list or change none.
ai_make_tmp() {
	AI_TMP="$(mktemp -d /tmp/mosaico-ai.XXXXXX)" && chmod 711 "$AI_TMP"
}

ai_cleanup_tmp() {
	[ -z "$AI_TMP" ] || rm -rf "$AI_TMP"
	AI_TMP=""
}

# Single-quotes a value for the parameter file the worker sources.
ai_quote() {
	printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# The script that writes and removes the files, run by ai_run_worker as the user
# they belong to. Quoted heredoc: written verbatim, its variables resolved when it
# runs, from the parameter file next to it.
ai_write_worker() {
	cat <<-'AI_WORKER_EOF'
	#!/bin/sh
	# Written by the Mosaico installer into a temporary directory and run by it, as
	# the user whose home it writes to: under sudo through runuser, sudo -u or su,
	# never as root. No set -e: a file that cannot be written is reported and the
	# next one is tried. Exit status, kept clear of the 1 that runuser, sudo or su
	# return when they refuse to run it: 10 done, 11 some files failed, or for
	# verify the skills refused; for an install, 2 is added when no file is in
	# place afterwards; 14 not started.
	cd / || exit 14
	. "$(dirname "$0")/ai-params.sh" || exit 14

	AI_FAILED=0
	AI_MANAGED=0

	warn() { printf "${YELLOW}Warning:${RESET} %s\n" "$*" >&2; }

	is_dry_run() {
	    [ -n "$AI_DRY_RUN" ]
	}

	# sha256 of standard input, in hex. Files are read this way: given a name
	# holding a backslash, sha256sum would print it escaped, a \ before the hash.
	ai_hash_stdin() {
	    if command -v sha256sum > /dev/null 2>&1; then
	        sha256sum | cut -d' ' -f1
	    else
	        shasum -a 256 | cut -d' ' -f1
	    fi
	}

	ai_hash() {
	    ai_hash_stdin < "$1"
	}

	ai_mkdir() {
	    [ -d "$1" ] && return 0
	    ai_mkdir "$(dirname "$1")" || return 1
	    mkdir "$1" 2> /dev/null
	}

	# One "<sha256>  <path>" line per file. The path is matched through the
	# environment rather than awk -v, which would expand backslashes in it.
	ai_manifest_hash() {
	    [ -f "$AI_MANIFEST" ] || return 0
	    AI_P="$1" awk '{ h = $1; sub(/^[^ ]*  /, ""); if ($0 == ENVIRON["AI_P"]) { print h; exit } }' "$AI_MANIFEST"
	}

	# ai_manifest_set <path> [hash]: drops the line of <path>, then records <hash>
	# for it when one is given, so a path is never listed twice. Written to a new
	# file and renamed over the old one, never through a name chosen in advance.
	ai_manifest_set() {
	    ai_mkdir "$(dirname "$AI_MANIFEST")" || return 1
	    _m="$(mktemp "$AI_MANIFEST.XXXXXX" 2> /dev/null)" || return 1
	    if {
	        if [ -f "$AI_MANIFEST" ]; then
	            AI_P="$1" awk '{ l = $0; sub(/^[^ ]*  /, "", l); if (l != ENVIRON["AI_P"]) print }' "$AI_MANIFEST"
	        fi
	        [ -z "${2:-}" ] || printf '%s  %s\n' "$2" "$1"
	    } > "$_m" && mv -f "$_m" "$AI_MANIFEST"; then
	        return 0
	    fi
	    rm -f "$_m"
	    return 1
	}

	# The only places a file of the manifest may be: anything else in it was not
	# written by the installer, whoever put it there.
	ai_is_managed_path() {
	    case "$1" in
	        */../*|*/..|*/./*|*/.) return 1 ;;
	    esac
	    _rel="${1#"$AI_HOME"/}"
	    [ "$_rel" != "$1" ] || return 1
	    case "$_rel" in
	        .claude/skills/?*|.agents/skills/?*) return 0 ;;
	    esac
	    return 1
	}

	# ai_put <source file> <destination>: writes the destination unless it is a
	# file this installer did not write, or one the user changed since. Returns 1
	# only when writing failed.
	ai_put() {
	    _new="$(ai_hash "$1")"
	    _old="$(ai_manifest_hash "$2")"
	    if [ -L "$2" ]; then
	        warn "$2 is a symlink: left in place."
	        return 0
	    fi
	    if [ -e "$2" ]; then
	        if [ -z "$_old" ]; then
	            warn "$2 exists and was not installed by Mosaico: left in place."
	            return 0
	        fi
	        _cur="$(ai_hash "$2")"
	        if [ "$_cur" != "$_old" ]; then
	            warn "$2 was changed since Mosaico installed it: left in place, not updated."
	            AI_MANAGED=$((AI_MANAGED + 1))
	            return 0
	        fi
	        if [ "$_cur" = "$_new" ]; then
	            echo "  ${DIM}unchanged${RESET} $2"
	            AI_MANAGED=$((AI_MANAGED + 1))
	            return 0
	        fi
	    fi
	    if is_dry_run; then
	        echo "  ${DIM}(dry-run)${RESET} write $2"
	        return 0
	    fi
	    if ! ai_mkdir "$(dirname "$2")" || ! cp "$1" "$2" 2> /dev/null; then
	        warn "could not write $2."
	        return 1
	    fi
	    if ! ai_manifest_set "$2" "$_new"; then
	        warn "could not record $2 in $AI_MANIFEST."
	        return 1
	    fi
	    AI_MANAGED=$((AI_MANAGED + 1))
	    echo "  wrote $2"
	}

	# Every skill of the bundle into both folders. Symlinks in the bundle are never
	# followed.
	ai_install() {
	    for _base in "$AI_HOME/.claude/skills" "$AI_HOME/.agents/skills"; do
	        for _sdir in "$AI_SOURCE_DIR"/skills/*/; do
	            _sdir="${_sdir%/}"
	            [ -L "$_sdir" ] && continue
	            [ -f "$_sdir/SKILL.md" ] && [ ! -L "$_sdir/SKILL.md" ] || continue
	            _sname="$(basename "$_sdir")"
	            # Regular files only, one per line: find reports a symlink as one and
	            # does not descend into a symlinked directory.
	            _ifs="$IFS"
	            IFS='
	'
	            set -f
	            for _f in $(cd "$_sdir" && find . -type f); do
	                IFS="$_ifs"
	                set +f
	                _f="${_f#./}"
	                case "$_f" in
	                    ..|../*|*/../*) continue ;;
	                esac
	                ai_put "$_sdir/$_f" "$_base/$_sname/$_f" || AI_FAILED=1
	            done
	            IFS="$_ifs"
	            set +f
	        done
	    done
	}

	# Deletes empty directories from <dir> upwards, stopping at the skills folder
	# itself, which may hold files that are not Mosaico's.
	ai_prune_dirs() {
	    _d="$1"
	    while [ "$_d" != "$AI_HOME" ] && [ "$_d" != "/" ]; do
	        case "$(basename "$_d")" in
	            skills) break ;;
	        esac
	        rmdir "$_d" 2> /dev/null || break
	        _d="$(dirname "$_d")"
	    done
	}

	ai_remove() {
	    if [ ! -f "$AI_MANIFEST" ]; then
	        echo "${BRAND}Info:${RESET} nothing to remove: $AI_MANIFEST does not exist."
	        return 0
	    fi
	    # Read from a copy, so the manifest can go at the end whatever happens.
	    _copy="$(mktemp 2> /dev/null || mktemp -t mosaico-ai)" || return 1
	    cat "$AI_MANIFEST" > "$_copy" || { rm -f "$_copy"; return 1; }
	    while IFS= read -r _line; do
	        _h="${_line%%  *}"
	        _p="${_line#*  }"
	        [ -n "$_p" ] || continue
	        if ! ai_is_managed_path "$_p"; then
	            warn "$_p is not in a folder the installer writes to: refused, left in place."
	            continue
	        fi
	        if [ -L "$_p" ] || { [ -e "$_p" ] && [ "$(ai_hash "$_p")" != "$_h" ]; }; then
	            warn "$_p was changed since Mosaico installed it: left in place."
	            continue
	        fi
	        if is_dry_run; then
	            [ -e "$_p" ] && echo "  ${DIM}(dry-run)${RESET} rm $_p"
	            continue
	        fi
	        if [ -e "$_p" ]; then
	            if ! rm -f "$_p" 2> /dev/null; then
	                warn "could not remove $_p."
	                AI_FAILED=1
	                continue
	            fi
	            echo "  removed $_p"
	        fi
	        ai_prune_dirs "$(dirname "$_p")"
	    done < "$_copy"
	    rm -f "$_copy"
	    if is_dry_run; then
	        echo "  ${DIM}(dry-run)${RESET} rm $AI_MANIFEST"
	    else
	        rm -f "$AI_MANIFEST"
	        # Only when empty: on macOS it is the installation's own data directory.
	        rmdir "$(dirname "$AI_MANIFEST")" 2> /dev/null || true
	    fi
	}

	# Skills, or files of a skill, that Mosaico no longer ships: the manifest lists
	# them, the bundle just installed does not. Deleted on the same condition as
	# --remove; a file the user changed stays where it is and leaves the manifest,
	# so from then on it is theirs. Run only after an install with no failure, so a
	# bad download never empties the folders.
	ai_prune_stale() {
	    [ -f "$AI_MANIFEST" ] || return 0
	    _copy="$(mktemp 2> /dev/null || mktemp -t mosaico-ai)" || return 1
	    cat "$AI_MANIFEST" > "$_copy" || { rm -f "$_copy"; return 1; }
	    while IFS= read -r _line; do
	        _h="${_line%%  *}"
	        _p="${_line#*  }"
	        [ -n "$_p" ] || continue
	        ai_is_managed_path "$_p" || continue
	        _rest="${_p#"$AI_HOME"/}"
	        _rest="${_rest#.claude/skills/}"
	        _rest="${_rest#.agents/skills/}"
	        _src="$AI_SOURCE_DIR/skills/$_rest"
	        _sdir="$AI_SOURCE_DIR/skills/${_rest%%/*}"
	        # Still shipped, by the same test ai_install uses to copy it.
	        if [ -f "$_src" ] && [ ! -L "$_src" ] && [ ! -L "$_sdir" ] \
	            && [ -f "$_sdir/SKILL.md" ] && [ ! -L "$_sdir/SKILL.md" ]; then
	            continue
	        fi
	        if [ -L "$_p" ] || { [ -e "$_p" ] && [ "$(ai_hash "$_p")" != "$_h" ]; }; then
	            warn "$_p is no longer part of the Mosaico skills and was changed since Mosaico installed it: left in place, no longer managed."
	        elif is_dry_run; then
	            [ -e "$_p" ] && echo "  ${DIM}(dry-run)${RESET} rm $_p (no longer shipped)"
	        elif [ -e "$_p" ]; then
	            if ! rm -f "$_p" 2> /dev/null; then
	                warn "could not remove $_p."
	                AI_FAILED=1
	                continue
	            fi
	            echo "  removed $_p (no longer shipped)"
	            ai_prune_dirs "$(dirname "$_p")"
	        fi
	        is_dry_run && continue
	        if ! ai_manifest_set "$_p"; then
	            warn "could not update $AI_MANIFEST."
	            AI_FAILED=1
	        fi
	    done < "$_copy"
	    rm -f "$_copy"
	}

	# The content hash AI_SKILLS_SHA256 is checked against, printed for the
	# installer: one "<sha256>  <path>" line for every regular file under skills/,
	# its path relative to AI_SOURCE_DIR, the lines sorted bytewise, and the sha256
	# of that list. Refused first, with nothing printed, when anything under
	# skills/ is not a directory or a regular file (a symlink, a device, a FIFO),
	# or has a newline in its name, for which that list is not well defined.
	ai_verify() {
	    cd "$AI_SOURCE_DIR" || return 1
	    if ! command -v sha256sum > /dev/null 2>&1 && ! command -v shasum > /dev/null 2>&1; then
	        warn "neither sha256sum nor shasum is installed, so the skills cannot be checked."
	        return 1
	    fi
	    _bad="$(find skills ! -type f ! -type d | head -n 1)"
	    if [ -n "$_bad" ]; then
	        warn "$AI_SOURCE_DIR/$_bad is neither a directory nor a regular file."
	        return 1
	    fi
	    _nl='
	'
	    if [ -n "$(find skills -name "*$_nl*" | head -n 1)" ]; then
	        warn "a name under $AI_SOURCE_DIR/skills has a newline in it."
	        return 1
	    fi
	    find skills -type f | LC_ALL=C sort | while IFS= read -r _f; do
	        printf '%s  %s\n' "$(ai_hash_stdin < "$_f")" "$_f"
	    done | ai_hash_stdin
	}

	case "$AI_MODE" in
	    verify)
	        ai_verify || exit 11
	        exit 10
	        ;;
	    install)
	        ai_install || AI_FAILED=1
	        [ "$AI_FAILED" -ne 0 ] || ai_prune_stale || AI_FAILED=1
	        _none=0
	        [ "$AI_MANAGED" -gt 0 ] || _none=2
	        exit $((10 + AI_FAILED + _none))
	        ;;
	    remove)
	        ai_remove || AI_FAILED=1
	        exit $((10 + AI_FAILED))
	        ;;
	esac
	exit 14
	AI_WORKER_EOF
}

# ai_as_user <command> [arg...]: runs a command as AI_USER, with TMPDIR set back to
# /tmp (see ai_make_tmp). Its status is the command's, or the 1 or 126 of a
# runuser, sudo or su that refused to run it.
ai_as_user() {
	if [ "$(id -u)" -ne 0 ]; then
		"$@"
	elif command_exists runuser; then
		runuser -u "$AI_USER" -- env TMPDIR=/tmp "$@"
	elif command_exists sudo; then
		sudo -u "$AI_USER" -H env TMPDIR=/tmp "$@"
	else
		_cmd="env TMPDIR=/tmp"
		for _a in "$@"; do
			_cmd="$_cmd $(ai_quote "$_a")"
		done
		su -s /bin/sh "$AI_USER" -c "$_cmd"
	fi
}

# ai_run_worker <install|remove>: writes the worker and its parameters
# into AI_TMP and runs it as AI_USER, which on macOS is always the user running
# this script. Kept the same as in install.sh. Its status is the worker's, or
# that of a launcher that refused to run it (see ai_as_user).
ai_run_worker() {
	_mode="$1"
	ai_write_worker > "$AI_TMP/ai-worker.sh" || return 3
	{
		echo "AI_MODE=$(ai_quote "$_mode")"
		echo "AI_DRY_RUN=$(ai_quote "$DRY_RUN")"
		echo "AI_HOME=$(ai_quote "$AI_HOME")"
		echo "AI_MANIFEST=$(ai_quote "$AI_MANIFEST")"
		echo "AI_SOURCE_DIR=$(ai_quote "$AI_SOURCE_DIR")"
		echo "DIM=$(ai_quote "$DIM")"
		echo "RESET=$(ai_quote "$RESET")"
		echo "YELLOW=$(ai_quote "$YELLOW")"
		echo "BRAND=$(ai_quote "$BRAND")"
	} > "$AI_TMP/ai-params.sh" || return 3
	# For AI_USER, who gets into AI_TMP through ai_make_tmp: nothing else in it is
	# opened up, and the skills under src/ are that user's own already.
	chmod 644 "$AI_TMP/ai-worker.sh" "$AI_TMP/ai-params.sh" 2>> "$LOG_FILE" || return 3
	ai_as_user sh "$AI_TMP/ai-worker.sh"
}

# Not fatal in a full installation: the skills are an extra, and neither a
# download nor a file that fails says anything about the installation itself.
# For --ai alone (AI_ONLY) they are the whole run, so a failure exits 1; skills
# not released yet exit 0.
install_ai() {
	[ "$AI" -eq 1 ] || return 0

	step_line "Installing Mosaico skills for AI coding assistants"
	if ! ai_released; then
		info "Mosaico's skills for AI coding assistants are not released yet: none were installed. Re-run with --ai once they are."
		return 0
	fi
	if [ "$AI_ONLY" -eq 0 ] && ! ai_version_supported; then
		warn "Mosaico's skills are written for Mosaico $AI_MIN_MOSAICO_VERSION or newer, and this run is for $MOSAICO_VERSION: skipped, since they would describe commands and options it does not have. Once you run $AI_MIN_MOSAICO_VERSION or newer, add them with: sh install-mosaico.sh --ai"
		return 0
	fi
	if ! ai_resolve_user; then
		[ "$AI_ONLY" -eq 0 ] || fatal "\$HOME is not set to an existing directory: no skills were installed."
		warn "\$HOME is not set to an existing directory: skipped."
		return 0
	fi
	echo "  User            : $AI_USER ($AI_HOME)"
	echo "  Folders         : ~/.claude/skills, ~/.agents/skills"
	_rc=0
	ai_fetch_bundle || _rc=$?
	if [ "$_rc" -ne 0 ]; then
		ai_cleanup_tmp
		if [ "$_rc" -eq 2 ]; then
			[ "$AI_ONLY" -eq 0 ] || fatal "$AI_SOURCE_LABEL has no .agents/skills folder: no skills to install."
			warn "$AI_SOURCE_LABEL has no .agents/skills folder: no skills to install."
		elif [ "$_rc" -eq 3 ]; then
			_msg="$AI_REFUSAL Refused: none were installed."
			[ "$AI_ONLY" -eq 0 ] || fatal "$_msg"
			printf "${RED}Error:${RESET} %s The rest of the installation goes on.\n" "$_msg" >&2
		elif [ "$_rc" -eq 4 ]; then
			[ "$AI_ONLY" -eq 0 ] || fatal "the archive downloaded from $AI_SOURCE_LABEL cannot be read, being damaged or cut short (see $LOG_FILE): none were installed."
			warn "the archive downloaded from $AI_SOURCE_LABEL cannot be read, being damaged or cut short (see $LOG_FILE): skipped."
		elif [ "$_rc" -eq 5 ]; then
			[ "$AI_ONLY" -eq 0 ] || fatal "the skills from $AI_SOURCE_LABEL were fetched, but their check could not run as $AI_USER (see $LOG_FILE): none were installed."
			warn "the skills from $AI_SOURCE_LABEL were fetched, but their check could not run as $AI_USER (see $LOG_FILE): skipped."
		else
			[ "$AI_ONLY" -eq 0 ] || fatal "could not fetch the skills from $AI_SOURCE_LABEL (see $LOG_FILE): none were installed."
			warn "could not fetch the skills from $AI_SOURCE_LABEL (see $LOG_FILE): skipped."
		fi
		return 0
	fi
	echo "  Source          : $AI_SOURCE_LABEL"
	_rc=0
	ai_run_worker install || _rc=$?
	ai_cleanup_tmp
	# The worker's own codes: 10 and 11, files are in place; 12 and 13, none are; 11
	# and 13, some failed. Anything else means it never ran, or not to the end.
	case "$_rc" in
		10|12) ;;
		11|13)
			[ "$AI_ONLY" -eq 0 ] || fatal "some skill files could not be written: see the warnings above."
			warn "some skill files could not be written: see the warnings above. The rest of the installation goes on."
			;;
		*)
			[ "$AI_ONLY" -eq 0 ] || fatal "the AI step could not run as $AI_USER (status $_rc): no skills were installed."
			warn "the AI step could not run as $AI_USER (status $_rc): no skills were installed. The rest of the installation goes on."
			;;
	esac
	if ! is_dry_run && { [ "$_rc" -eq 10 ] || [ "$_rc" -eq 11 ]; }; then
		AI_INSTALLED=1
	fi
}

do_ai_remove() {
	step_line "Removing Mosaico skills for AI coding assistants"
	if ! ai_resolve_user; then
		warn "\$HOME is not set to an existing directory: skipped."
		return 0
	fi
	# Whether there is a manifest is the worker's to find out: root may not be able
	# to look, on a home mounted over NFS with root_squash.
	ai_make_tmp || fatal "could not create a temporary directory under /tmp."
	_rc=0
	ai_run_worker remove || _rc=$?
	ai_cleanup_tmp
	case "$_rc" in
		10) ;;
		11) warn "some skill files could not be removed: see the warnings above." ;;
		*) warn "the AI step could not run as $AI_USER (status $_rc): nothing was removed." ;;
	esac
}

# --ai with no option that installs Mosaico: the skills and nothing else, so no
# daemon, no Podman, no prompt. Run as the user, as every run of this script.
do_ai_only() {
	print_logo
	echo
	if [ "$MOSAICO_VERSION_SET" -eq 0 ] && ai_released; then
		info "the skills are written for Mosaico $AI_MIN_MOSAICO_VERSION or newer (the main branch); the daemon you use them with is not checked. To check it, give its version: MOSAICO_VERSION=$AI_MIN_MOSAICO_VERSION sh install-mosaico.sh --ai"
	fi
	is_dry_run && echo "${YELLOW}# --dry-run: no changes will be made${RESET}"
	install_ai
	if [ "$AI_INSTALLED" -eq 1 ]; then
		echo
		echo "  Mosaico skills for your AI coding assistants, listed in:"
		echo "    $AI_MANIFEST"
		echo "  ${DIM}Remove them with: curl -fsSL https://get.mosaico.dev | sh -s -- --ai --remove${RESET}"
	fi
	echo
}

# --- Uninstall ---

# Reads a single key from the install record, or nothing when the file or the key
# is absent.
read_install_conf() {
	grep -s "^$1=" "$DATA_DIR/install.conf" 2>/dev/null | cut -d= -f2- || true
}

do_uninstall() {
	print_logo
	echo
	echo "${YELLOW}Executing Mosaico uninstall script...${RESET}"
	echo

	# Recovers what was recorded at install time, so the commands below act on the
	# machine and directories in use rather than on the defaults. A --machine or
	# --bin-dir given on the command line still wins.
	if ! is_dry_run; then
		recorded="$(read_install_conf MACHINE)"
		if [ -n "$recorded" ] && [ "$MACHINE" = "mosaico" ]; then MACHINE="$recorded"; fi
		recorded="$(read_install_conf BIN_DIR)"
		if [ -n "$recorded" ] && [ "$BIN_DIR" = "$HOME/.local/bin" ]; then BIN_DIR="$recorded"; fi
		recorded="$(read_install_conf FS_DIR)"
		if [ -n "$recorded" ]; then FS_DIR="$recorded"; fi
		recorded="$(read_install_conf STORE_BACKEND)"
		if [ -n "$recorded" ]; then STORE_BACKEND="$recorded"; fi
		recorded="$(read_install_conf PG_MODE)"
		if [ -n "$recorded" ]; then PG_MODE="$recorded"; fi
		recorded="$(read_install_conf PG_HOST)"
		if [ -n "$recorded" ]; then PG_HOST="$recorded"; fi
		recorded="$(read_install_conf PG_PORT)"
		if [ -n "$recorded" ]; then PG_PORT="$recorded"; fi
		recorded="$(read_install_conf PG_DB)"
		if [ -n "$recorded" ]; then PG_DB="$recorded"; fi
	fi

	PODMAN_BIN="$(command -v podman 2>/dev/null || echo podman)"

	# The agent goes first: it would otherwise start again what is about to be
	# removed, at the next login of a half-uninstalled system.
	run_ignore_errors "launchctl bootout gui/$(id -u)/$LAUNCH_LABEL"
	run_ignore_errors "rm -f '$LAUNCH_AGENT'"
	run_ignore_errors "rm -f '$STARTER'"

	# Only reachable while the machine is running; when it is not, the containers are
	# not running either.
	run_ignore_errors "$(podman_cmd) rm -f $CLEANUP_CONTAINER"
	run_ignore_errors "$(podman_cmd) rm -f $MOSAICOD_CONTAINER"
	run_ignore_errors "$(podman_cmd) rm -f $POSTGRES_CONTAINER"
	run_ignore_errors "$(podman_cmd) network rm $PODMAN_NETWORK"

	run_ignore_errors "rm -f '$BIN_DIR/$CLI_WRAPPER_NAME'"
	# Created only by this installer, so nothing of the user's can be inside.
	run_ignore_errors "rm -rf '$SDK_VENV'"
	run_ignore_errors "rm -f '$BIN_DIR/$MOSAICOCTL_NAME'"

	echo
	echo "${GREEN}${BOLD}  Mosaico has been successfully removed.${RESET}"
	echo
	echo "  Removed commands:"
	echo "    $BIN_DIR/$CLI_WRAPPER_NAME"
	echo "    $BIN_DIR/$MOSAICOCTL_NAME"
	echo
	echo "  Removed login starter:"
	echo "    $LAUNCH_AGENT"
	echo
	echo "  To completely wipe all remaining data and secrets from this Mac,"
	echo "  execute the following commands:"
	echo
	echo "${BOLD}    rm -rf $SECRETS_DIR $DATA_DIR/install.conf${RESET}"
	if [ "$STORE_BACKEND" = "fs" ]; then
		echo "${BOLD}    rm -rf $FS_DIR${RESET}"
	fi
	# The volume exists only where the database was embedded.
	if [ "$PG_MODE" = "embedded" ]; then
		echo "${BOLD}    podman --connection $MACHINE volume rm $POSTGRES_VOLUME${RESET}"
	fi
	echo
	# Not removed here: the machine may hold containers this installer knows nothing
	# about, and removing it would take them too.
	echo "  The podman machine '$MACHINE' was left in place, since it may hold other"
	echo "  containers. Remove it (and with it the volume above) with:"
	echo
	echo "${BOLD}    podman machine rm $MACHINE${RESET}"
	if [ "$PG_MODE" != "embedded" ]; then
		echo
		echo "  The PostgreSQL instance at $PG_HOST:$PG_PORT is not touched by these"
		echo "  commands: drop the '$PG_DB' database there if you want the metadata gone."
	fi
	if [ "$STORE_BACKEND" != "fs" ]; then
		echo
		echo "  Dataset frames stored in the object store bucket are not touched by"
		echo "  these commands and must be removed there."
	fi
	# Not removed with Mosaico: they are of use without a local daemon, and
	# --ai --remove takes them away on its own.
	# Looked for as the user, for the same reason as in do_ai_remove.
	if ai_resolve_user && ai_as_user test -f "$AI_MANIFEST" 2>/dev/null; then
		echo "  The Mosaico skills installed for your AI coding assistants were left"
		echo "  in place. Remove them with:"
		echo
		echo "${BOLD}    curl -fsSL https://get.mosaico.dev | sh -s -- --ai --remove${RESET}"
		echo
	fi
	echo
}

# --- Final report ---

print_success() {
	scheme="http"
	[ "$ENABLE_TLS" -eq 1 ] && scheme="https"

	echo
	echo "${GREEN}${BOLD}  Mosaico is up and running!${RESET}"
	echo
	# One endpoint, the one the port was actually published on: the addresses this Mac
	# happens to hold say nothing about where the service answers. With TLS the
	# certified name is the only one advertised, since a client connecting to a bare
	# address would fail certificate validation.
	if [ "$ENABLE_TLS" -eq 1 ]; then
		echo "  ${BRAND}${ARROW}${RESET}  Endpoint: $scheme://$DOMAIN:$MOSAICOD_PORT"
	elif is_any_address "$MOSAICOD_HOST"; then
		echo "  ${BRAND}${ARROW}${RESET}  Endpoint: $scheme://127.0.0.1:$MOSAICOD_PORT"
		echo "     ${DIM}Published on $MOSAICOD_HOST: reachable on every address of this Mac.${RESET}"
	else
		echo "  ${BRAND}${ARROW}${RESET}  Endpoint: $scheme://$MOSAICOD_HOST:$MOSAICOD_PORT"
	fi

	if [ "$PG_MODE" = "external" ]; then
		echo
		echo "  Database: PostgreSQL at $PG_HOST:$PG_PORT/$PG_DB as $PG_USER"
		echo "  ${DIM}Not managed by this installer: backups and upgrades are yours.${RESET}"
	fi

	echo
	echo "  Security credentials saved to $SECRETS_DIR/"
	if [ -n "$MASTER_API_KEY" ]; then
		echo "  ${BRAND}${ARROW}${RESET}  Master API Key:  $(printf '%s' "$MASTER_API_KEY" | cut -c1-29)..."
		echo "     ${DIM}Full key: $SECRETS_DIR/master_api_key${RESET}"
	elif [ "$API_KEY" -eq 0 ]; then
		echo
		# "No API key" means an unauthenticated endpoint, so the note names the address
		# it was published on: on the loopback that is this Mac, on 0.0.0.0 the whole
		# network.
		echo "  ${YELLOW}Note:${RESET} API keys are not required: anyone who can reach"
		echo "        $MOSAICOD_HOST:$MOSAICOD_PORT can read and write data. Re-run the"
		echo "        installer with --api-key to require them."
	fi

	if [ "$ENABLE_TLS" -eq 1 ]; then
		echo
		echo "  TLS enabled with the certificate you provided, copied to:"
		echo "    $TLS_DIR/cert.pem"
		echo "    $TLS_DIR/key.pem"
		echo "  ${DIM}Renewal is yours: replace those two files and restart the container${RESET}"
		echo "  ${DIM}with 'podman --connection $MACHINE restart $MOSAICOD_CONTAINER'.${RESET}"
	fi

	if [ "$CLEANUP" -eq 1 ]; then
		echo
		echo "  Cleanup routine enabled: $(cleanup_summary)."
		echo "  ${DIM}It runs in its own container, $CLEANUP_CONTAINER.${RESET}"
		echo "  ${BRAND}$CLEANUP_DOCS_URL${RESET}"
	fi

	if [ "$SDK" -eq 1 ]; then
		echo
		echo "  Python SDK ($SDK_PACKAGE) installed in $SDK_VENV:"
		echo "    ${BOLD}. $SDK_VENV/bin/activate${RESET}"
	fi

	if [ "$AI_INSTALLED" -eq 1 ]; then
		echo
		echo "  Mosaico skills for your AI coding assistants, listed in:"
		echo "    $AI_MANIFEST"
		echo "  ${DIM}Remove them with: curl -fsSL https://get.mosaico.dev | sh -s -- --ai --remove${RESET}"
	fi

	echo
	echo "  Commands:"
	echo "    ${BOLD}$CLI_WRAPPER_NAME --help${RESET}                  the daemon's own CLI"
	echo "    ${BOLD}$MOSAICOCTL_NAME --help${RESET}          re-configure, upgrade or uninstall"
	if [ "$BIN_DIR_ON_PATH" -eq 0 ]; then
		echo
		echo "  ${YELLOW}Note:${RESET} $BIN_DIR is not on your PATH. Add it to use the two"
		echo "        commands above by name:"
		echo "    ${BOLD}echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zprofile${RESET}"
	fi

	echo
	echo "  Service management, through the '$MACHINE' podman machine:"
	echo "    ${BOLD}podman --connection $MACHINE ps${RESET}"
	echo "    ${BOLD}podman --connection $MACHINE logs -f $MOSAICOD_CONTAINER${RESET}"
	echo "    ${BOLD}podman --connection $MACHINE restart $MOSAICOD_CONTAINER${RESET}"
	echo "    ${BOLD}podman machine stop $MACHINE${RESET} / ${BOLD}podman machine start $MACHINE${RESET}"
	echo
	echo "  ${DIM}Mosaico is started again by a LaunchAgent when you log in:${RESET}"
	echo "  ${DIM}$LAUNCH_AGENT, logging to $STARTER_LOG.${RESET}"
	echo "  ${DIM}It runs in your session, so it does not come up before you log in.${RESET}"
	echo
	echo "  Files:"
	echo "    $MOSAICOD_ENV_FILE      ${DIM}daemon configuration${RESET}"
	echo "    $DATA_DIR/install.conf  ${DIM}record of these choices${RESET}"
	if [ "$STORE_BACKEND" = "fs" ]; then
		echo "    $FS_DIR  ${DIM}dataset frames${RESET}"
	fi
	echo
	echo "  Documentation: ${BRAND}$DOCS_URL${RESET}"
	echo
}

# --- Main execution ---

do_install() {
	if [ "$NON_INTERACTIVE" -eq 1 ]; then
		print_logo
		print_disclaimer
		check_mosaico_version
		validate_non_interactive
	else
		if ! has_tty; then
			fatal "no terminal available for interactive setup. Re-run with -y and the required flags (see --help)."
		fi
		print_logo
		print_disclaimer
		echo
		check_mosaico_version
		configure_interactive
	fi

	# Before the summary, which reports the host the container will use.
	derive_pg_container_host
	warn_tls_bind_mismatch
	print_summary
	[ "$NON_INTERACTIVE" -eq 1 ] || confirm_summary

	is_dry_run && echo "${YELLOW}# --dry-run: no changes will be made${RESET}"

	check_bin_dir
	check_domain_dns
	check_podman
	setup_machine
	setup_directories
	install_tls_material
	write_secrets
	write_install_conf
	pull_images
	ensure_network
	drop_embedded_postgres
	drop_cleanup_container
	run_postgres
	wait_for_postgres
	check_external_postgres
	run_mosaicod
	# After the daemon: it creates the schema on first start, and a cleanup that runs
	# before that fails on a missing table.
	run_cleanup
	create_master_api_key
	install_cli_wrapper
	install_mosaicoctl
	# After the containers exist: the starter it writes refers to them by name.
	install_launch_agent
	install_sdk
	install_ai

	echo
	if is_dry_run; then
		echo "${YELLOW}Dry run complete: nothing was installed or changed.${RESET}"
	else
		print_success
	fi
}

parse_args "$@"
check_macos
apply_pairings
validate_flags

if [ "$AI_REMOVE" -eq 1 ]; then
	do_ai_remove
elif [ "$AI_ONLY" -eq 1 ]; then
	do_ai_only
elif [ "$UNINSTALL" -eq 1 ]; then
	do_uninstall
else
	do_install
fi
