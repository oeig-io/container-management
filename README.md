# Container Management

Generic container lifecycle management for NixOS-based application deployments using Incus.

## TOC

- [Summary](#summary)
- [Standards Overview](#standards-overview)
  - [Standard 1: Application Installer](#standard-1-application-installer)
  - [Standard 2: Container Orchestration](#standard-2-container-orchestration)
- [Quick Start](#quick-start)
- [Configuration](#configuration)
- [Secrets (host-* containers)](#secrets-host--containers)
- [Adding New Container Types](#adding-new-container-types)
- [Config File Reference](#config-file-reference)

## Summary

The purpose of this system is to enable consistent, repeatable deployment of applications into isolated NixOS containers. This is important because it provides a unified approach to packaging applications (regardless of complexity) and orchestrating them at scale.

## Standards Overview

This system implements **two complementary standards** that work together:

```
┌─────────────────────────────────────────────────────────────────────┐
│  Standard 2: Container Orchestration (this repository)              │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  Standard 1: Application Installer (external repos)           │   │
│  │  ┌────────────────────────────────────────────────────────┐   │   │
│  │  │  Application (e.g., iDempiere, Metabase, OpenCode)    │   │   │
│  │  └────────────────────────────────────────────────────────┘   │   │
│  │                                                               │   │
│  │  • install.sh entry point                                    │   │
│  │  • Multi-phase NixOS deployment                              │   │
│  │  • PostgreSQL + .pgpass pattern                              │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                     │
│  • launch.sh orchestration                                         │
│  • Config-driven container creation                                │
│  • Port allocation & lifecycle management                          │
└─────────────────────────────────────────────────────────────────────┘
```

### Standard 1: Application Installer

**Scope**: `install-xxxx` repositories (e.g., `install-idempiere`, `install-metabase`)

**Purpose**: Package an application for automated deployment on NixOS.

**Contract**:

| Element | Requirement |
|---------|-------------|
| Entry Point | `install.sh` script in repository root |
| Arguments | None (environment variables for options) |
| Base OS | NixOS with systemd |
| Database | PostgreSQL with `.pgpass` credential management |
| Phases | 1-N: prerequisites → ansible (optional) → service → nginx (optional) |
| Output | Running systemd service on configured port(s) |

**Complexity Range**: As simple as the application allows:
- **Simple** (nixpkg available): Single phase, no Ansible, just `nixos-rebuild switch`
- **Complex** (no viable nixpkg): Multi-phase with Ansible orchestration

**Examples**:
- [github.com/oeig-io/install-idempiere](https://github.com/oeig-io/install-idempiere) - Complex: No nixpkg, multi-phase with Ansible
- [github.com/oeig-io/install-metabase](https://github.com/oeig-io/install-metabase) - Complex: No nixpkg, multi-phase with Ansible
- [github.com/oeig-io/install-opencode](https://github.com/oeig-io/install-opencode) - Simple: Good nixpkg, single phase

### Standard 2: Container Orchestration

**Scope**: This repository (`container-management`)

**Purpose**: Provision and manage NixOS containers at scale using Incus.

**Contract**:

| Element | Requirement |
|---------|-------------|
| Client | Local Incus installation |
| Config | `configs/<app>.conf` file defining container parameters |
| Naming | `PREFIX-XX` format (e.g., `id-47`, `mb-01`) |
| Ports | `PORT_BASE + container_number` (e.g., `9000 + 47 = 9047`) |
| Launcher | `launch.sh <config> <container-name>` |

**Orchestration Flow**:
1. Create NixOS container with configured resources
2. Add proxy port forward (host port → container internal port) — skipped when `CONNECT_PORT=0` (outbound-only containers)
3. Pre-seed downloads (if configured)
4. Push installer repository to container
5. Push secrets file to container (only when `--secrets` is given; see [Secrets](#secrets-host--containers))
6. Execute `install.sh` (unless `--no-install`)
7. Wait for health check

**Key Insight**: The orchestration layer treats installers as black boxes. It does not care *what* is being installed, only that the installer follows the Standard 1 contract.

## Quick Start

### Create an iDempiere Container

```bash
./launch.sh configs/idempiere.conf id-47
```

This creates container `id-47` with:
- **Host port**: 9047 (9000 + 47)
- **Container internal**: Port 443 (HTTPS via nginx)
- **Resources**: 4GiB RAM, 2 CPUs, 20GiB disk
- **Access**: https://<host>:9047/webui/

### Create a Metabase Container

```bash
./launch.sh configs/metabase.conf mb-01
```

This creates container `mb-01` with:
- **Host port**: 9101 (9100 + 1)
- **Container internal**: Port 3000 (Metabase HTTP)
- **Resources**: 2GiB RAM, 2 CPUs, 10GiB disk
- **Access**: http://<host>:9101/

### Create a host-* Container With Secrets

`host-*` repos (1:1 container-per-service) often need out-of-repo credentials at
first boot. Pass `--secrets <path>` and `launch.sh` will courier the file to the
path defined by `SECRETS_TARGET` in the config, with mode `0600 root:root`,
**before** `install.sh` runs:

```bash
cd container-management
./launch.sh ../host-elevenlabs/launch.conf elevenlabs-01 \
    --secrets ~/.config/oeig/host-elevenlabs.env
```

See [Secrets (host-* containers)](#secrets-host--containers) for the full
contract.

### Create Without Installing

Useful for manual install with special flags:

```bash
# Stop after pushing repo
./launch.sh configs/idempiere.conf id-47 --no-install

# Then manually install with environment variables
incus exec id-47 -- env SOME_VAR=value /opt/idempiere-install/install.sh
```

## Configuration

### Config Files

Each container type has a config file in `configs/`:

| Config | Application | Naming | Port Range |
|--------|-------------|--------|------------|
| `idempiere.conf` | iDempiere ERP | `id-XX` | 9000-9099 |
| `metabase.conf` | Metabase BI | `mb-XX` | 9100-9199 |

`host-*` repos (1:1 container-per-service) ship their own `launch.conf`
alongside the installer and are invoked by path, e.g.
`./launch.sh ../host-elevenlabs/launch.conf elevenlabs-01 --secrets <path>`.

### Container Naming Convention

Container names follow the pattern: `PREFIX-XX`

- `PREFIX`: Short application identifier (e.g., `id`, `mb`, `oc`)
- `XX`: Numeric instance identifier (01-99)
- Examples: `id-47`, `mb-01`, `oc-01`

### Port Allocation

Final port = `PORT_BASE` + container number

| Container | PORT_BASE | Calculation | Host Port |
|-----------|-----------|-------------|-----------|
| id-47 | 9000 | 9000 + 47 | 9047 |
| id-01 | 9000 | 9000 + 1 | 9001 |
| mb-01 | 9100 | 9100 + 1 | 9101 |

## Adding New Container Types

### Step 1: Create the Application Installer

Create a new `install-<app>` repository following [Standard 1](#standard-1-application-installer):

```
install-myapp/
├── install.sh              # Required: Entry point
├── myapp-prerequisites.nix # Phase 1: System dependencies
├── myapp-service.nix       # Phase 2: systemd service
└── ansible/                # Optional: Complex apps only
    ├── myapp-install.yml
    └── vars/
        └── myapp.yml
```

### Step 2: Create Config File

Add `configs/myapp.conf` following [Standard 2](#standard-2-container-orchestration):

```bash
# Container naming
PREFIX="ma"

# Port configuration
PORT_BASE=9200
CONNECT_PORT=8080

# Resource limits
MEMORY="2GiB"
CPU=2
DISK="10GiB"

# Pre-seed (optional)
SEED_DIR="/opt/myapp-seed"
SEED_FILE=""  # Skip pre-seeding

# Installation paths
INSTALL_PATH="/opt/myapp-install"
INSTALLER_REPO="../install-myapp"

# Health check
HEALTH_ENDPOINT="http://localhost:8080/health"
HEALTH_EXPECTED=200
HEALTH_TIMEOUT=60
HEALTH_INTERVAL=5
```

### Step 3: Deploy

```bash
./launch.sh configs/myapp.conf ma-01
```

## Config File Reference

Required variables in config files:

| Variable | Description | Example |
|----------|-------------|---------|
| `PREFIX` | Container name prefix | `"id"`, `"mb"`, `"oc"` |
| `PORT_BASE` | Base port number (ignored when `CONNECT_PORT=0`) | `9000`, `9100`, `0` |
| `CONNECT_PORT` | Internal port to proxy to; set to `0` for outbound-only containers (no proxy created) | `443`, `3000`, `8080`, `0` |
| `MEMORY` | RAM limit | `"4GiB"`, `"2GiB"` |
| `CPU` | CPU limit | `2`, `4` |
| `DISK` | Disk size | `"20GiB"`, `"10GiB"` |
| `INSTALL_PATH` | Path inside container for installer | `"/opt/app-install"` |
| `INSTALLER_REPO` | Relative path to installer repo | `"../install-app"` |
| `HEALTH_ENDPOINT` | URL to check for readiness | `"http://localhost:3000/api/health"` |
| `HEALTH_EXPECTED` | Expected HTTP status code | `200`, `405` |
| `HEALTH_TIMEOUT` | Max seconds to wait | `60`, `90` |
| `HEALTH_INTERVAL` | Seconds between checks | `5` |

Optional variables:

| Variable | Description | Example |
|----------|-------------|---------|
| `SEED_DIR` | Pre-seed directory inside container | `"/opt/app-seed"` |
| `SEED_FILE` | Pre-seed filename (empty string to skip) | `"app.zip"`, `""` |
| `SECRETS_TARGET` | Absolute path inside container where `--secrets` file lands (`0600 root:root`). Required **only** when `--secrets` is passed on the CLI. | `"/var/lib/elevenlabs/env"` |
| `NIXOS_IMAGE` | Incus image to launch from | `"nixos/25.11"`, `"nixos/unstable"` |

## Secrets (host-* containers)

`host-*` repos are **open systems** — they have inputs (API keys, passwords)
that cannot live in the repo. `launch.sh --secrets <path>` is the bootstrap
courier for those inputs.

### CLI flag

```
./launch.sh <config-file> <container-name> --secrets <local-path>
```

- `<local-path>` is a file on the operator's machine (leading `~` is expanded).
- Missing file → fail fast, no container is created beyond that point.

### Config variable

The config file declares **where** on the container the secrets land:

```bash
# host-elevenlabs/launch.conf
SECRETS_TARGET="/var/lib/elevenlabs/env"
```

- Absolute path.
- Required only when the operator passes `--secrets`. `install-*` configs
  should **not** set it.

### What `launch.sh` does

1. Resolves and validates `<local-path>` before creating the container.
2. After pushing the repo, creates `$(dirname SECRETS_TARGET)` on the container
   as `0700 root:root`.
3. Pushes the file to `SECRETS_TARGET` with `--mode=0600 --uid=0 --gid=0`.
4. Proceeds to `install.sh` — which can now assume the secrets file exists
   (and should `test -f` it as its first prereq check).

### What `launch.sh` does **not** do

- Does not read or parse the secrets file.
- Does not rotate secrets on existing containers. Steady-state rotation is a
  separate channel (Ansible playbook in the `host-*` repo, or CI/CD). See
  `corporate/planning/host-elevenlabs/README.md`.
- Does not create `SECRETS_TARGET` automatically for `install-*` configs —
  the flag is optional and silently skipped when not passed.

### Why this exists

`install-*` repos are closed systems: push repo, run `install.sh`, done.
`host-*` repos are open by definition — secrets must enter from outside the
repo. Rather than force a separate Ansible bootstrap step, `launch.sh` gains
one generic extra channel (`--secrets`) so the operator experience stays
one-shot. Future out-of-repo artifacts (e.g., licensed binaries) would follow
the same pattern with a new flag; deferred until concretely needed.

## Prerequisites

- Incus installed and configured locally
- Installer repositories exist at configured `INSTALLER_REPO` paths
- NixOS base image available in Incus (auto-downloaded if needed)

## Related Documentation

- [CLAUDE.md](CLAUDE.md) - Technical details for Claude Code
- [github.com/oeig-io/install-idempiere](https://github.com/oeig-io/install-idempiere) - Complex installer example
- [github.com/oeig-io/install-metabase](https://github.com/oeig-io/install-metabase) - Complex installer example
- [wi-base/WORK_INSTRUCTIONS.md](../wi-base/WORK_INSTRUCTIONS.md) - Documentation standards
