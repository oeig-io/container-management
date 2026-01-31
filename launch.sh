#!/usr/bin/env bash
# Container Management: Generic Container Launch Script
#
# Usage:
#   ./launch.sh <config-file> <container-name> [--no-install]
#
# Arguments:
#   config-file     Required. Path to config file (e.g., configs/idempiere.conf)
#   container-name  Required. The incus container to create (e.g., id-47, mb-01)
#
# Options:
#   --no-install    Stop after pushing repo (before install.sh). Useful for
#                   manual install with special flags.
#
# This script creates a fresh container:
#   1. Creates NixOS container with incus
#   2. Adds proxy port forward (based on config)
#   3. Pre-seeds download (if configured)
#   4. Pushes installer repo to container
#   5. Runs install.sh (unless --no-install)
#   6. Waits for health check
#
# Prerequisites:
#   - incus installed and configured
#   - Installer repo exists at INSTALLER_REPO path
#
# Examples:
#   ./launch.sh configs/idempiere.conf id-47
#   ./launch.sh configs/metabase.conf mb-01
#   ./launch.sh configs/idempiere.conf id-47 --no-install

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse arguments
if [[ $# -lt 2 || "$1" == "--help" || "$1" == "-h" ]]; then
    echo "Usage: $0 <config-file> <container-name> [--no-install]"
    echo ""
    echo "Arguments:"
    echo "  config-file     Config file (e.g., configs/idempiere.conf)"
    echo "  container-name  Container name (e.g., id-47, mb-01)"
    echo ""
    echo "Options:"
    echo "  --no-install    Stop before install.sh (for manual install)"
    echo ""
    echo "Examples:"
    echo "  $0 configs/idempiere.conf id-47"
    echo "  $0 configs/metabase.conf mb-01"
    exit 0
fi

CONFIG_FILE="$1"
CONTAINER="$2"
NO_INSTALL=false
if [[ "${3:-}" == "--no-install" ]]; then
    NO_INSTALL=true
fi

# Load config
if [[ ! -f "$SCRIPT_DIR/$CONFIG_FILE" ]]; then
    echo "ERROR: Config file not found: $SCRIPT_DIR/$CONFIG_FILE"
    exit 1
fi
# shellcheck source=/dev/null
source "$SCRIPT_DIR/$CONFIG_FILE"

# Validate required config variables
for var in PREFIX PORT_BASE CONNECT_PORT MEMORY CPU DISK INSTALL_PATH INSTALLER_REPO \
           HEALTH_ENDPOINT HEALTH_EXPECTED HEALTH_TIMEOUT HEALTH_INTERVAL; do
    if [[ -z "${!var:-}" ]]; then
        echo "ERROR: Required config variable $var not set in $CONFIG_FILE"
        exit 1
    fi
done

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
echo ""

# Check if container already exists
if incus info "$CONTAINER" &>/dev/null; then
    echo "ERROR: Container '$CONTAINER' already exists"
    echo "       To recreate, first run: incus delete $CONTAINER --force"
    exit 1
fi

# Step 1: Create container
echo ">>> Step 1: Creating NixOS container..."
incus launch images:nixos/25.11 "$CONTAINER" \
    -c security.nesting=true \
    -c limits.memory="$MEMORY" \
    -c limits.cpu="$CPU" \
    -d root,size="$DISK"
echo "    Container created."
echo ""

# Step 2: Add proxy port forward
echo ">>> Step 2: Adding proxy port forward..."
sleep 2  # Brief pause to ensure container is ready
incus config device add "$CONTAINER" myproxy proxy \
    listen=tcp:0.0.0.0:"$PROXY_PORT" \
    connect=tcp:127.0.0.1:"$CONNECT_PORT"
echo "    Proxy configured: port $PROXY_PORT -> $CONNECT_PORT"
echo ""

# Step 3: Pre-seed download (if configured)
echo ">>> Step 3: Pre-seeding download..."
if [[ -n "${SEED_FILE:-}" && -n "${SEED_DIR:-}" && -f "$SEED_DIR/$SEED_FILE" ]]; then
    incus exec "$CONTAINER" -- mkdir -p /tmp/seed
    incus file push "$SEED_DIR/$SEED_FILE" "$CONTAINER/tmp/seed/"
    echo "    Pre-seeded from $SEED_DIR/$SEED_FILE"
else
    echo "    No seed file configured or found (skipped)"
fi
echo ""

# Step 4: Push installer repo
echo ">>> Step 4: Pushing installer repo..."
incus exec "$CONTAINER" -- mkdir -p "$INSTALL_PATH"
# Must push from within the repo directory to avoid nesting
(cd "$INSTALLER_REPO_PATH" && incus file push -r . "$CONTAINER$INSTALL_PATH/")
echo "    Repo pushed to $INSTALL_PATH/"
echo ""

# Step 5: Run installer (unless --no-install)
if [[ "$NO_INSTALL" == true ]]; then
    echo ">>> Step 5: Skipped (--no-install)"
    echo ""
    echo "=== Container Ready for Manual Install ==="
    echo ""
    echo "To install with default settings:"
    echo "  incus exec $CONTAINER -- $INSTALL_PATH/install.sh"
    echo ""
    exit 0
fi

echo ">>> Step 5: Running installation..."
incus exec "$CONTAINER" -- "$INSTALL_PATH/install.sh"
echo "    Installation complete."
echo ""

# Step 6: Wait for health check
echo ">>> Step 6: Waiting for service to be ready..."
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
echo ""

echo "=== Container Launch Complete ==="
echo ""
echo "Container: $CONTAINER"
echo "Port:      $PROXY_PORT"
