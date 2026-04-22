# CLAUDE.md

This file provides guidance to Claude Code when working with this repository.

## Project Overview

Generic container lifecycle management for NixOS incus containers. This module handles container creation, configuration, and installer execution for multiple application types (iDempiere, Metabase, etc.).

## Architecture

The system uses a config-driven approach:

1. **Config files** (`configs/*.conf`) - Define container type settings
2. **Launch script** (`launch.sh`) - Generic container lifecycle manager
3. **Installer repos** (external) - Application-specific installation scripts

## Key Commands

```bash
# Create iDempiere container
./launch.sh configs/idempiere.conf id-47

# Create Metabase container
./launch.sh configs/metabase.conf mb-01

# Create without installing (for manual install with env vars)
./launch.sh configs/idempiere.conf id-47 --no-install

# Create a host-* container and courier secrets in one shot
./launch.sh ../host-elevenlabs/launch.conf elevenlabs-01 \
    --secrets ~/.config/oeig/host-elevenlabs.env
```

## File Structure

```
container-management/
├── launch.sh               # Generic config-driven launcher
├── configs/
│   ├── idempiere.conf     # iDempiere container config
│   └── metabase.conf      # Metabase container config
├── README.md              # User documentation
└── CLAUDE.md              # This file
```

## Config File Format

Config files are sourced as bash scripts. Required variables:

- `PREFIX` - Container name prefix (e.g., "id", "mb")
- `PORT_BASE` - Base port number (final port = PORT_BASE + container number); ignored when `CONNECT_PORT=0`
- `CONNECT_PORT` - Internal port to proxy to; set to `0` for outbound-only containers (proxy step skipped)
- `MEMORY`, `CPU`, `DISK` - Resource limits
- `INSTALL_PATH` - Path inside container for installer
- `INSTALLER_REPO` - Relative path to installer repo
- `HEALTH_*` - Health check configuration

Optional variables:

- `SEED_DIR`, `SEED_FILE` - Pre-seed a file into the container before install
- `NIXOS_IMAGE` - Override base image (default `nixos/25.11`)
- `SECRETS_TARGET` - Absolute path on container where `--secrets <path>`
  couriers a local secrets file (0600 root:root). Required **only** when
  `--secrets` is passed; `install-*` configs should not set it.

## `--secrets` (host-* containers)

`host-*` repos are open systems: they need out-of-repo credentials at first
boot. `launch.sh` accepts `--secrets <path>` as a generic bootstrap channel.

Order of operations when `--secrets` is given:

1. Validate the source file exists (fail fast, before creating the container)
2. Validate `SECRETS_TARGET` is set in the config file
3. Create container, proxy (if any), pre-seed, push repo (steps 1–4)
4. `mkdir -p $(dirname SECRETS_TARGET)` as `0700 root:root`
5. `incus file push --mode=0600 --uid=0 --gid=0 <src> <container><SECRETS_TARGET>`
6. Run `install.sh` — which should `test -f SECRETS_TARGET` as a prereq

When `--secrets` is not passed, step 5 is skipped silently; existing
`install-*` configs are unaffected.

`launch.sh` is a **courier only** — it never reads or transforms the secrets
file. Steady-state rotation is a separate channel (Ansible in the `host-*`
repo, or CI/CD). See `corporate/planning/host-elevenlabs/README.md` for the
design.

## Port Conventions

| Type | Prefix | Port Range | Example |
|------|--------|------------|---------|
| iDempiere | id- | 9000-9099 | id-47 -> 9047 |
| Metabase | mb- | 9100-9199 | mb-01 -> 9101 |

## Installer Contract

Each installer repo must provide:
- `install.sh` - Takes no arguments, runs inside the container
- Assumes NixOS base system
- Handles all application-specific setup

## Common Operations

**Delete and recreate container:**
```bash
incus delete id-47 --force
./launch.sh configs/idempiere.conf id-47
```

**Manual install with environment variables:**
```bash
./launch.sh configs/idempiere.conf id-47 --no-install
incus exec id-47 -- env SOME_VAR=value /opt/idempiere-install/install.sh
```

**Launch a host-* container with secrets:**
```bash
./launch.sh ../host-elevenlabs/launch.conf elevenlabs-01 \
    --secrets ~/.config/oeig/host-elevenlabs.env
```
