# CLAUDE.md

This file provides guidance to Claude Code when working with this repository.

## Project Overview

Generic container lifecycle management for NixOS incus containers. This module handles container creation, configuration, and installer execution for multiple application types (iDempiere, Metabase, etc.).

## Architecture

The system uses a config-driven approach:

1. **Config files** — Define container type settings. Two locations:
   - `configs/*.conf` — for `install-*` repos (1:N factory pattern)
   - Inside each `host-*` repo as `launch.conf` — for `host-*` repos (1:1 dedicated pattern)
2. **Launch script** (`launch.sh`) — Generic container lifecycle manager; accepts either config location
3. **Application payload repos** (external) — Two variants:
   - `install-*` — closed systems, no out-of-repo inputs
   - `host-*` — open systems governed by `host-contract.md`: their own vault token piped to `launch.sh --secrets -`, every later change through the repo's `deploy.sh`

## Key Commands

```bash
# Create iDempiere container
./launch.sh configs/idempiere.conf id-47

# Create Metabase container
./launch.sh configs/metabase.conf mb-01

# Create without installing (for manual install with env vars)
./launch.sh configs/idempiere.conf id-47 --no-install

# Create a host-* container; the piped secret is its own vault token
bao login -method=userpass username=<admin>
../host-openbao/scripts/bao-mint-login-token.sh myname-service \
    | ./launch.sh ../host-myname/launch.conf myname-01 --secrets -
```

## File Structure

```
container-management/
├── launch.sh               # Generic config-driven launcher
├── configs/
│   ├── idempiere.conf     # iDempiere container config (install-*)
│   ├── metabase.conf      # Metabase container config (install-*)
│   ├── npm.conf           # npm prerequisites config (install-*)
│   └── opencode.conf      # opencode config (install-*)
├── README.md              # User documentation
├── host-contract.md       # The host-* contract (governs every host-* repo)
└── CLAUDE.md              # This file
```

Note: `host-*` repos ship their own `launch.conf` inside the repo itself — not in `configs/`.

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
- `NIXOS_IMAGE` - Override base image as a full incus image reference (default `images:nixos/26.05`). Use `images:nixos/...` for remote, or a local alias/fingerprint for cached images.
- `SECRETS_TARGET` - where `--secrets` lands in a host-* container; see
  `host-contract.md`. `install-*` configs do not set it.

## `--secrets`

`launch.sh --secrets -` reads one secret from stdin **before any `incus`
call** (`incus exec` reads stdin too and would swallow it), and pushes it to
`SECRETS_TARGET` as `0600 root:root` under a `0711 root:root` parent after the
repo push and before `install.sh`. `--secrets <path>` is the legacy local-file
form. `launch.sh` is a courier only: it never parses the secret, and it never
touches a container after first boot — that is the host-* repo's `deploy.sh`.
The contract is `host-contract.md`.

## Port Conventions

| Type | Pattern | Prefix | Port Range | Example |
|------|---------|--------|------------|---------|
| iDempiere | install-* | id- | 9000-9099 | id-47 -> 9047 |
| Metabase | install-* | mb- | 9100-9199 | mb-01 -> 9101 |
| host-elevenlabs | host-* | elevenlabs- | n/a (outbound-only, `CONNECT_PORT=0`) | elevenlabs-01 |

`host-*` containers commonly run with `PORT_BASE=0` / `CONNECT_PORT=0` because they do not expose an inbound service — they poll outward and push to other systems.

## Installer Contract

Each installer repo must provide:
- `install.sh` — Takes no arguments, runs inside the container
- Assumes NixOS base system
- Handles all application-specific setup
- Disables IPv6 temporary addresses in its prerequisites `.nix` — NixOS enables them by default and re-asserts that at every boot, overriding the host profile; see the `incus-environment-management-task` skill

For `host-*` repos, `install.sh` has additional duties — see `host-contract.md`
→ "Repo Layout".

## Common Operations

**Delete and recreate an install-* container:**
```bash
incus delete id-47 --force
./launch.sh configs/idempiere.conf id-47
```

**Delete and recreate a host-* container (iteration workflow; confirm first):**
see `host-contract.md` → "Lifecycle".

**Manual install with environment variables:**
```bash
./launch.sh configs/idempiere.conf id-47 --no-install
incus exec id-47 -- env SOME_VAR=value /opt/idempiere-install/install.sh
```

## Ownership Invariant on `$INSTALL_PATH`

After `incus file push -r` delivers the repo to `$INSTALL_PATH`, `launch.sh` runs `chown -R root:root $INSTALL_PATH`. Without this step, `incus file push` preserves the pusher's uid/gid (typically `1000:1000` on the operator's machine), which maps to whichever container user happens to have uid `1000` — often the unprivileged service user in a `host-*` container. That would let the service user mutate its own code at runtime, violating the couriers-not-configurators principle.

The step is unconditional and harmless for `install-*` (whose install paths are throwaway anyway).
