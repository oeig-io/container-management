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
- `PORT_BASE` - Base port number (final port = PORT_BASE + container number)
- `CONNECT_PORT` - Internal port to proxy to
- `MEMORY`, `CPU`, `DISK` - Resource limits
- `INSTALL_PATH` - Path inside container for installer
- `INSTALLER_REPO` - Relative path to installer repo
- `HEALTH_*` - Health check configuration

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
