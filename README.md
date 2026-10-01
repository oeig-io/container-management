# Container Management

Generic container lifecycle management for NixOS-based application deployments using Incus.

## TOC

- [Summary](#summary)
- [Standards Overview](#standards-overview)
  - [Standard 1: Application Payload](#standard-1-application-payload)
  - [Two Payload Variants](#two-payload-variants)
  - [Standard 2: Container Orchestration](#standard-2-container-orchestration)
- [Quick Start](#quick-start)
  - [Spin Up a Throwaway NixOS Container](#spin-up-a-throwaway-nixos-container)
  - [Create an iDempiere Container](#create-an-idempiere-container)
  - [Create a Metabase Container](#create-a-metabase-container)
  - [Create a host-* Container](#create-a-host--container)
  - [Create Without Installing](#create-without-installing)
- [Configuration](#configuration)
- [Config File Reference](#config-file-reference)
- [Prerequisites](#prerequisites)
- [Related Documentation](#related-documentation)

## Summary

The purpose of this system is to enable consistent, repeatable deployment of applications into isolated NixOS containers. This is important because it provides a unified approach to packaging applications (regardless of complexity) and orchestrating them at scale.

To build a payload repo, start with its contract: [install-contract.md](install-contract.md) for an `install-*` factory, [host-contract.md](host-contract.md) for a `host-*` production singleton. [Two Payload Variants](#two-payload-variants) explains which one you need.

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
│  │  │  id-47, mb-01           lead-helper-00                │   │   │
│  │  └────────────────────────────────────────────────────────┘   │   │
│  │                                                               │   │
│  │  • install.sh entry point                                    │   │
│  │  • NixOS modules + sudo nixos-rebuild switch                 │   │
│  │  • install-contract.md, host-contract.md                     │   │
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

Both variants satisfy this contract.

### Two Payload Variants

The two variants differ in how many containers a repo serves, whether anything enters from outside, and what happens after first boot:

| | `install-*` — factory | `host-*` — production singleton |
|---|---|---|
| Instances | 1:N, disposable (`id-47`, `mb-01`) | 1:1, one long-lived identity (`lead-helper-00`) |
| System | **Closed** — nothing enters from outside the repo | **Open** — its own vault token is couriered in |
| Config | `configs/<app>.conf`, in this repo | `launch.conf`, in the payload repo |
| `INSTALL_PATH` | `/opt/<app>-install/` — throwaway | `/opt/<name>/` — the live runtime |
| After first boot | Delete and relaunch | The repo's `deploy.sh` |
| Also owns | — | Vault identity, `clone.sh`, delete protection on `-00` |
| Governed by | [install-contract.md](install-contract.md) | [host-contract.md](host-contract.md) |

**An `install-*` repo is the usual on-ramp.** It is where we learn to stand an application up on NixOS, cheaply and repeatably, with nothing depending on it. When the service needs an input from outside the repo or becomes a production singleton, its `install-*` repo is **forked** into a `host-*` repo — `host-idempiere` and `host-openbao` from their namesakes, `host-elevenlabs` from `install-npm`. The `install-*` repo keeps serving disposable boxes; the fork is pinned and grows the production layer. A service born as a singleton with outside inputs starts directly as a `host-*` (`host-lead-helper`).

### Standard 2: Container Orchestration

**Scope**: This repository (`container-management`)

**Purpose**: Provision and manage NixOS containers at scale using Incus.

**Contract**:

| Element | Requirement |
|---------|-------------|
| Client | Local Incus installation |
| Config | `configs/<app>.conf` (`install-*`) or `launch.conf` in the payload repo (`host-*`) |
| Naming | `PREFIX-NN` format (e.g., `id-47`, `lead-helper-00`) |
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

`launch.sh` requires container names of the form `PREFIX-NN`, where `NN` is the instance number that also sets the host port. `install-*` prefixes are short (`id-47`); `host-*` prefixes are full words (`lead-helper-00`). Each contract's "Naming" section owns the rest.

### Port Allocation

Final port = `PORT_BASE` + container number

| Container | PORT_BASE | Calculation | Host Port |
|-----------|-----------|-------------|-----------|
| id-47 | 9000 | 9000 + 47 | 9047 |
| id-01 | 9000 | 9000 + 1 | 9001 |
| mb-01 | 9100 | 9100 + 1 | 9101 |

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

- [install-contract.md](install-contract.md) — The `install-*` contract
- [host-contract.md](host-contract.md) — The `host-*` contract
- [CLAUDE.md](CLAUDE.md) — Technical details for Claude Code
- [github.com/oeig-io/install-idempiere](https://github.com/oeig-io/install-idempiere) — install-* example (complex)
- [github.com/oeig-io/install-metabase](https://github.com/oeig-io/install-metabase) — install-* example (complex)
- [github.com/oeig-io/install-opencode](https://github.com/oeig-io/install-opencode) — install-* example (simple)
- [github.com/oeig-io/host-elevenlabs](https://github.com/oeig-io/host-elevenlabs) — host-* example (first of its kind)
- [corporate/planning/host-elevenlabs/README.md](../corporate/planning/host-elevenlabs/README.md) — Planning doc that produced the host-* pattern
- [wi-base/WORK_INSTRUCTIONS.md](../wi-base/WORK_INSTRUCTIONS.md) — Documentation standards
