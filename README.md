# Container Management

Generic container lifecycle management for NixOS-based application deployments using Incus.

## TOC

- [Summary](#summary)
- [Standards Overview](#standards-overview)
  - [Standard 1: Application Payload](#standard-1-application-payload)
    - [Variant A: install-* (factory, 1:N)](#variant-a-install--factory-1n)
    - [Variant B: host-* (dedicated, 1:1)](#variant-b-host--dedicated-11)
  - [Standard 2: Container Orchestration](#standard-2-container-orchestration)
- [Quick Start](#quick-start)
  - [Spin Up a Throwaway NixOS Container](#spin-up-a-throwaway-nixos-container)
  - [Create an iDempiere Container](#create-an-idempiere-container)
  - [Create a Metabase Container](#create-a-metabase-container)
  - [Create a host-* Container](#create-a-host--container)
  - [Create Without Installing](#create-without-installing)
- [Configuration](#configuration)
- [Adding a New install-* Container Type](#adding-a-new-install--container-type)
- [Config File Reference](#config-file-reference)

## Summary

The purpose of this system is to enable consistent, repeatable deployment of applications into isolated NixOS containers. This is important because it provides a unified approach to packaging applications (regardless of complexity) and orchestrating them at scale.

## Standards Overview

This system implements **two complementary standards** that work together:

```
┌─────────────────────────────────────────────────────────────────────┐
│  Standard 2: Container Orchestration (this repository)              │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  Standard 1: Application Payload (external repos)            │   │
│  │  ┌────────────────────────────────────────────────────────┐   │   │
│  │  │  Variant A: install-*   Variant B: host-*             │   │   │
│  │  │  (factory, 1:N)         (dedicated, 1:1)              │   │   │
│  │  │  id-47, mb-01           elevenlabs-01                 │   │   │
│  │  └────────────────────────────────────────────────────────┘   │   │
│  │                                                               │   │
│  │  • install.sh entry point                                    │   │
│  │  • NixOS modules + sudo nixos-rebuild switch                 │   │
│  │  • host-* contract: host-contract.md                         │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                     │
│  • launch.sh orchestration                                         │
│  • Config-driven container creation                                │
│  • Port allocation & lifecycle management                          │
└─────────────────────────────────────────────────────────────────────┘
```

### Standard 1: Application Payload

**Scope**: `install-*` and `host-*` repositories.

**Purpose**: Package an application for automated deployment on NixOS.

**Shared contract**:

| Element | Requirement |
|---------|-------------|
| Entry Point | `install.sh` script in repository root |
| Arguments | None (environment variables for options) |
| Base OS | NixOS with systemd |
| Phases | 1-N: prerequisites → ansible (optional) → service → nginx (optional) |
| Output | Running systemd service(s) |
| Stable IPv6 | Prerequisites `.nix` disables IPv6 temporary addresses — NixOS enables them by default and re-asserts that at every boot, overriding the host profile; see the `incus-environment-management-task` skill |

Both variants satisfy this contract. They differ in lifecycle model and whether the repo is a *closed* or *open* system.

#### Variant A: install-* (factory, 1:N)

A single repo that can be deployed to any number of independent containers. The repo is a **closed system** — everything needed to deploy lives in it.

| Property | Value |
|----------|-------|
| Container naming | `PREFIX-XX` (short abbreviation; e.g., `id-47`, `mb-01`) |
| Config file location | `container-management/configs/<app>.conf` |
| `INSTALL_PATH` convention | `/opt/<app>-install/` — throwaway bootstrap artifact |
| Secrets at bootstrap | None (or internal to the application) |
| Typical complexity | Multi-phase with Ansible when no good nixpkg exists; single-phase otherwise |

**Examples**:
- [github.com/oeig-io/install-idempiere](https://github.com/oeig-io/install-idempiere) — Complex: no nixpkg, multi-phase with Ansible
- [github.com/oeig-io/install-metabase](https://github.com/oeig-io/install-metabase) — Complex: no nixpkg, multi-phase with Ansible
- [github.com/oeig-io/install-opencode](https://github.com/oeig-io/install-opencode) — Simple: good nixpkg, single phase

#### Variant B: host-* (dedicated, 1:1)

A repo that owns a single long-lived container identity. The repo is an **open system** by definition — it has inputs (API keys, licensed artifacts) that cannot live in the repo and must enter from outside. Its container carries its own vault identity and is changed after first boot by the repo's `deploy.sh`.

**[host-contract.md](host-contract.md) governs every `host-*` repo** — layout, vault identity, `deploy.sh`, delete protection, clone script, and migration from `install-*`. Start there to build or change one.

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
4. Push installer repository to container, then `chown -R root:root $INSTALL_PATH` to normalize ownership (see [Ownership Note](#ownership-note) below)
5. Push the `--secrets` value to `SECRETS_TARGET` — piped on stdin for `host-*` (see [host-contract.md](host-contract.md))
6. Execute `install.sh` (unless `--no-install`)
7. Wait for health check

**Key Insight**: The orchestration layer treats installers as black boxes. It does not care *what* is being installed, only that the installer follows the Standard 1 contract.

#### Ownership Note

`incus file push -r` preserves the pusher's uid/gid on the source tree. On the operator's machine that is usually `1000:1000`, which maps to whichever container user happens to have uid `1000` — often the service user for `host-*` repos. Without normalization, the service user would end up owning its own code and could mutate it in place, violating the couriers-not-configurators principle.

> 💡 **Tip** — The `chown -R root:root` step is harmless for `install-*` (whose install paths are throwaway anyway) and essential for `host-*` (where the install path is the live runtime). It runs unconditionally.

## Quick Start

### Spin Up a Throwaway NixOS Container

For experiments where you need a NixOS container and nothing more — no config, no install, no payload repo — `incus launch` directly is enough. This is exactly what `launch.sh` runs as Step 1 of its orchestration flow.

```bash
incus launch images:nixos/26.05 <name> -c security.nesting=true
```

`security.nesting=true` is what lets NixOS actually work inside the container. Add resource bounds only if you want them:

```bash
incus launch images:nixos/26.05 <name> \
    -c security.nesting=true \
    -c limits.memory=2GiB \
    -c limits.cpu=2 \
    -d root,size=10GiB
```

Then:

```bash
incus exec <name> -- bash          # interactive
incus exec <name> -- nixos-version # one-shot
incus delete <name> --force        # nuke it
```

> 💡 **Tip** — Use this for sandboxing experiments (NixOS config tweaks, one-off reproductions, poking at a freshly-released image). For anything that should land as a managed container — a service, a payload with secrets, a clone of production — use the config-driven `./launch.sh configs/<app>.conf <name>` path below.

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

### Create a host-* Container

```bash
../host-openbao/scripts/bao-mint-login-token.sh myname-service \
    | ./launch.sh ../host-myname/launch.conf myname-01 --secrets -
```

The config file lives inside the `host-*` repo itself, not in `configs/`, and the piped secret is the container's own vault token. See [host-contract.md](host-contract.md) → "Container Vault Identity".

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

Each `install-*` container type has a config file in `configs/`. Discover them
rather than consulting a list — the files *are* the inventory, and each one
declares its own prefix and port base:

```bash
ls configs/*.conf                                           # available container types
rg -N '^PREFIX=|^PORT_BASE=|^CONNECT_PORT=' configs/*.conf  # naming and ports for each
```

`host-*` repos (1:1 container-per-service) ship their own `launch.conf`
alongside the installer and are invoked by path — see
[host-contract.md](host-contract.md).

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

## Adding a New install-* Container Type

For a **1:N factory** pattern (multiple independent instances of the same app).

### Step 1: Create the Application Installer Repo

Create a new `install-<app>` repository following [Variant A](#variant-a-install--factory-1n):

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

### Step 2: Create the Config File in `container-management/configs/`

```bash
# configs/myapp.conf

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
./launch.sh configs/myapp.conf ma-02
./launch.sh configs/myapp.conf ma-47   # any number of instances
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
| `SECRETS_TARGET` | Absolute path inside the container where the `--secrets` value lands (`0600 root:root`); `host-*` only — see [host-contract.md](host-contract.md) | `"/var/lib/<app>/openbao-token"` |
| `NIXOS_IMAGE` | Full incus image reference to launch from | `"images:nixos/26.05"`, `"images:nixos/unstable"`, or a local alias/fingerprint for cached images |

## Prerequisites

- Incus installed and configured locally
- Installer repositories exist at configured `INSTALLER_REPO` paths
- NixOS base image available in Incus (auto-downloaded if needed)

## Related Documentation

- [host-contract.md](host-contract.md) — The `host-*` contract
- [CLAUDE.md](CLAUDE.md) — Technical details for Claude Code
- [github.com/oeig-io/install-idempiere](https://github.com/oeig-io/install-idempiere) — install-* example (complex)
- [github.com/oeig-io/install-metabase](https://github.com/oeig-io/install-metabase) — install-* example (complex)
- [github.com/oeig-io/install-opencode](https://github.com/oeig-io/install-opencode) — install-* example (simple)
- [github.com/oeig-io/host-elevenlabs](https://github.com/oeig-io/host-elevenlabs) — host-* example (first of its kind)
- [corporate/planning/host-elevenlabs/README.md](../corporate/planning/host-elevenlabs/README.md) — Planning doc that produced the host-* pattern
- [wi-base/WORK_INSTRUCTIONS.md](../wi-base/WORK_INSTRUCTIONS.md) — Documentation standards
