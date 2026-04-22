#!/usr/bin/env bash
# Container Management: Generic Container Launch Script
#
# Usage:
#   ./launch.sh <config-file> <container-name> [--no-install] [--secrets <path>]
#
# Arguments:
#   config-file     Required. Path to config file (e.g., configs/idempiere.conf)
#   container-name  Required. The incus container to create (e.g., id-47, mb-01)
#
# Options:
#   --no-install        Stop after pushing repo and secrets (before install.sh).
#                       Useful for manual install with special flags.
#   --secrets <path>    Push a local secrets file to the container at
#                       SECRETS_TARGET (defined in config) with mode 0600
#                       root:root. Required for host-* containers whose
#                       services need out-of-repo credentials at first boot.
#
# This script creates a fresh container:
#   1. Creates NixOS container with incus
#   2. Adds proxy port forward (based on config; skipped when CONNECT_PORT=0)
#   3. Pre-seeds download (if configured)
#   4. Pushes installer repo to container
#   5. Pushes secrets to container (if --secrets given)
#   6. Runs install.sh (unless --no-install)
#   7. Waits for health check
#
# Prerequisites:
#   - incus installed and configured
#   - Installer repo exists at INSTALLER_REPO path
#   - When using --secrets: SECRETS_TARGET set in config; source file readable
#
# Examples:
#   ./launch.sh configs/idempiere.conf id-47
#   ./launch.sh configs/metabase.conf mb-01
#   ./launch.sh configs/idempiere.conf id-47 --no-install
#   ./launch.sh ../host-elevenlabs/launch.conf elevenlabs-01 \
#       --secrets ~/.config/oeig/host-elevenlabs.env

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse arguments
if [[ $# -lt 2 || "$1" == "--help" || "$1" == "-h" ]]; then
    echo "Usage: $0 <config-file> <container-name> [--no-install] [--secrets <path>]"
    echo ""
    echo "Arguments:"
    echo "  config-file         Config file (e.g., configs/idempiere.conf)"
    echo "  container-name      Container name (e.g., id-47, mb-01)"
    echo ""
    echo "Options:"
    echo "  --no-install        Stop before install.sh (for manual install)"
    echo "  --secrets <path>    Push local secrets file to SECRETS_TARGET (0600 root:root)"
    echo ""
    echo "Examples:"
    echo "  $0 configs/idempiere.conf id-47"
    echo "  $0 configs/metabase.conf mb-01"
    echo "  $0 ../host-elevenlabs/launch.conf elevenlabs-01 --secrets ~/.config/oeig/host-elevenlabs.env"
    exit 0
fi

CONFIG_FILE="$1"
CONTAINER="$2"
shift 2
NO_INSTALL=false
SECRETS_SOURCE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-install)
            NO_INSTALL=true
            shift
            ;;
        --secrets)
            if [[ $# -lt 2 || -z "${2:-}" ]]; then
                echo "ERROR: --secrets requires a path argument"
                exit 1
            fi
            SECRETS_SOURCE="$2"
            shift 2
            ;;
        *)
            echo "ERROR: Unknown option: $1"
            echo "See '$0 --help' for usage."
            exit 1
            ;;
    esac
done

# Validate secrets source path (before loading config, to fail fast)
if [[ -n "$SECRETS_SOURCE" ]]; then
    # Expand leading ~ if the shell didn't
    SECRETS_SOURCE="${SECRETS_SOURCE/#\~/$HOME}"
    if [[ ! -f "$SECRETS_SOURCE" ]]; then
        echo "ERROR: Secrets source file not found: $SECRETS_SOURCE"
        exit 1
    fi
fi

# Load config
if [[ ! -f "$SCRIPT_DIR/$CONFIG_FILE" ]]; then
    echo "ERROR: Config file not found: $SCRIPT_DIR/$CONFIG_FILE"
    exit 1
fi
# shellcheck source=/dev/null
source "$SCRIPT_DIR/$CONFIG_FILE"

# Validate required config variables
for var in PREFIX PORT_BASE CONNECT_PORT MEMORY CPU DISK INSTALL_PATH INSTALLER_REPO; do
    if [[ -z "${!var:-}" ]]; then
        echo "ERROR: Required config variable $var not set in $CONFIG_FILE"
        exit 1
    fi
done

# --secrets requires SECRETS_TARGET in config
if [[ -n "$SECRETS_SOURCE" && -z "${SECRETS_TARGET:-}" ]]; then
    echo "ERROR: --secrets requires SECRETS_TARGET to be defined in $CONFIG_FILE"
    exit 1
fi

# Validate container name matches prefix
if [[ ! "$CONTAINER" =~ ^${PREFIX}-[0-9]+$ ]]; then
    echo "ERROR: Container name must be in format ${PREFIX}-XX (e.g., ${PREFIX}-47)"
    exit 1
fi

# Derive port from container name
CONTAINER_NUM="${CONTAINER##${PREFIX}-}"
PROXY_PORT=$((PORT_BASE + CONTAINER_NUM))

# Resolve installer repo path
INSTALLER_REPO_PATH="$(cd "$SCRIPT_DIR" && cd "$INSTALLER_REPO" && pwd)"
if [[ ! -d "$INSTALLER_REPO_PATH" ]]; then
    echo "ERROR: Installer repo not found: $INSTALLER_REPO_PATH"
    exit 1
fi

echo "=== Container Launch ==="
echo ""
echo "Config:    $CONFIG_FILE"
echo "Container: $CONTAINER"
echo "Port:      $PROXY_PORT -> $CONNECT_PORT"
echo "Resources: $MEMORY RAM, $CPU CPUs, $DISK disk"
echo "Installer: $INSTALLER_REPO_PATH"
if [[ -n "$SECRETS_SOURCE" ]]; then
    echo "Secrets:   $SECRETS_SOURCE -> $SECRETS_TARGET"
fi
echo ""

# Check if container already exists
if incus info "$CONTAINER" &>/dev/null; then
    echo "ERROR: Container '$CONTAINER' already exists"
    echo "       To recreate, first run: incus delete $CONTAINER --force"
    exit 1
fi

# Step 1: Create container
NIXOS_IMAGE="${NIXOS_IMAGE:-nixos/25.11}"
echo ">>> Step 1: Creating NixOS container (image: ${NIXOS_IMAGE})..."
incus launch images:${NIXOS_IMAGE} "$CONTAINER" \
    -c security.nesting=true \
    -c limits.memory="$MEMORY" \
    -c limits.cpu="$CPU" \
    -d root,size="$DISK"
echo "    Container created."
echo ""

# Step 2: Add proxy port forward (skip if no inbound port)
if [[ "$CONNECT_PORT" != "0" ]]; then
    echo ">>> Step 2: Adding proxy port forward..."
    sleep 2  # Brief pause to ensure container is ready
    incus config device add "$CONTAINER" myproxy proxy \
        listen=tcp:0.0.0.0:"$PROXY_PORT" \
        connect=tcp:127.0.0.1:"$CONNECT_PORT"
    echo "    Proxy configured: port $PROXY_PORT -> $CONNECT_PORT"
    echo ""
else
    echo ">>> Step 2: Skipped (no inbound port)"
    echo ""
fi

# Step 3: Pre-seed download (if configured)
echo ">>> Step 3: Pre-seeding download..."
if [[ -n "${SEED_FILE:-}" && -n "${SEED_DIR:-}" && -f "$SEED_DIR/$SEED_FILE" ]]; then
    incus exec "$CONTAINER" -- mkdir -p /tmp/idempiere-seed
    incus file push "$SEED_DIR/$SEED_FILE" "$CONTAINER/tmp/idempiere-seed/" -q
    echo "    Pre-seeded from $SEED_DIR/$SEED_FILE"
else
    echo "    No seed file configured or found (skipped)"
fi
echo ""

# Step 4: Push installer repo
echo ">>> Step 4: Pushing installer repo..."
incus exec "$CONTAINER" -- mkdir -p "$INSTALL_PATH"
# Must push from within the repo directory to avoid nesting
(cd "$INSTALLER_REPO_PATH" && incus file push -rq . "$CONTAINER$INSTALL_PATH/")
# Normalize ownership: the application payload is couriered content, owned by root.
# Without this, `incus file push -r` preserves the pusher's uid/gid (e.g., host uid
# 1000 maps to whatever container user has uid 1000). That would let the service
# user mutate its own code — violates the couriers-not-configurators principle.
incus exec "$CONTAINER" -- chown -R root:root "$INSTALL_PATH"
echo "    Repo pushed to $INSTALL_PATH/ (owned by root:root)"
echo ""

# Step 5: Push secrets (if --secrets given)
if [[ -n "$SECRETS_SOURCE" ]]; then
    echo ">>> Step 5: Pushing secrets..."
    SECRETS_PARENT="$(dirname "$SECRETS_TARGET")"
    incus exec "$CONTAINER" -- mkdir -p "$SECRETS_PARENT"
    incus exec "$CONTAINER" -- chown root:root "$SECRETS_PARENT"
    incus exec "$CONTAINER" -- chmod 0711 "$SECRETS_PARENT"
    incus file push --mode=0600 --uid=0 --gid=0 -q \
        "$SECRETS_SOURCE" "$CONTAINER$SECRETS_TARGET"
    echo "    Secrets pushed to $SECRETS_TARGET (0600 root:root)"
    echo ""
else
    echo ">>> Step 5: Skipped (no --secrets provided)"
    echo ""
fi

# Step 6: Run installer (unless --no-install)
if [[ "$NO_INSTALL" == true ]]; then
    echo ">>> Step 6: Skipped (--no-install)"
    echo ""
    echo "=== Container Ready for Manual Install ==="
    echo ""
    echo "To install with default settings:"
    echo "  incus exec $CONTAINER -- $INSTALL_PATH/install.sh"
    echo ""
    exit 0
fi

echo ">>> Step 6: Running installation..."
incus exec "$CONTAINER" -- "$INSTALL_PATH/install.sh"
echo "    Installation complete."
echo ""

# Step 7: Wait for health check
if [[ -n "${HEALTH_ENDPOINT:-}" && "${HEALTH_TIMEOUT:-0}" -gt 0 ]]; then
    echo ">>> Step 7: Waiting for service to be ready..."
    max_attempts=$((HEALTH_TIMEOUT / HEALTH_INTERVAL))
    for i in $(seq 1 "$max_attempts"); do
        status=$(incus exec "$CONTAINER" -- curl -s -o /dev/null -w "%{http_code}" "$HEALTH_ENDPOINT" 2>/dev/null || echo "000")
        if [[ "$status" == "$HEALTH_EXPECTED" ]]; then
            echo "    Service is ready! (attempt $i)"
            break
        fi
        if [[ $i -eq $max_attempts ]]; then
            echo "    ERROR: Timeout waiting for service after $max_attempts attempts"
            exit 1
        fi
        echo "    Attempt $i: HTTP $status (waiting...)"
        sleep "$HEALTH_INTERVAL"
    done
else
    echo ">>> Step 7: Skipping health check (no endpoint configured)"
fi
echo ""

echo "=== Container Launch Complete ==="
echo ""
echo "Container: $CONTAINER"
echo "Port:      $PROXY_PORT"
