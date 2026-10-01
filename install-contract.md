# install-* Contract

The purpose of this document is to govern how an `install-*` repo is built and launched, so that "look at container-management and build me an install-…" has exactly one answer. This is important because an `install-*` repo is the usual on-ramp for a new service: it is how we learn to stand an application up on NixOS, cheaply and repeatably, before anything depends on it — and a clean `install-*` repo is what a `host-*` repo is forked from when the service grows up.

How the two payload variants relate, and the orchestration both share, is in [README.md](README.md). The production variant is [host-contract.md](host-contract.md).

## TOC

- [What an install-* Repo Is](#what-an-install--repo-is)
- [Naming](#naming)
- [Worked Examples](#worked-examples)
- [Lifecycle](#lifecycle)
- [Repo Layout](#repo-layout)
- [install.sh](#installsh)
- [The Config File](#the-config-file)
- [Building a New install-* Repo](#building-a-new-install--repo)
- [When an install-* Becomes a host-*](#when-an-install--becomes-a-host-)

## What an install-* Repo Is

An `install-*` repo is a **factory**: one repo, any number of independent, disposable containers. It is a **closed system** — everything needed to stand the application up lives in the repo.

| Property | Value |
|----------|-------|
| Instances | 1:N — `id-01`, `id-47`, … are interchangeable and disposable |
| Config | `container-management/configs/<app>.conf`, not in the repo |
| `INSTALL_PATH` | `/opt/<app>-install/` — a throwaway bootstrap artifact, not the live runtime |
| Inputs from outside | **None.** It may create secrets inside the container (`install-openbao`'s unseal ceremony); it never takes one in |
| Changing a container | Delete and relaunch. There is no `deploy.sh` and no in-place update path |
| Not needed | Vault identity, `deploy.sh`, `clone.sh`, delete protection — those are `host-*` concerns |

It must also satisfy the shared payload contract — README → "Standard 1: Application Payload".

## Naming

| Thing | Pattern | Example (`<app>` = `metabase`) | Set by |
|-------|---------|--------------------------------|--------|
| Repo | `install-<app>` | `install-metabase` | you |
| Config | `configs/<app>.conf` (variants: `<app>-<variant>.conf`) | `configs/metabase.conf` | you |
| `PREFIX` | Short abbreviation | `mb` | the config |
| Container | `<prefix>-NN` | `mb-01` | `launch.sh` |
| `INSTALL_PATH` | `/opt/<app>-install/` | `/opt/metabase-install/` | the config |
| `PORT_BASE` | The next unused block of 100 at 9000 and above; `0` when outbound-only | `9100` | the config |
| Host port | `PORT_BASE + NN` | `9101` for `mb-01` | `launch.sh` |

Discover the prefixes and port blocks already taken rather than consulting a list:

```bash
rg -N '^PREFIX=|^PORT_BASE=' configs/*.conf
```

> 📝 **Note** — Short prefixes are an `install-*` convenience for disposable boxes. A `host-*` repo uses a full-word prefix, because its one container is a long-lived identity a stranger must recognize — see [host-contract.md](host-contract.md) → "Naming".

## Worked Examples

Copy from the example closest in shape to your application:

| Shape | Copy from | Note |
|-------|-----------|------|
| Single phase, good nixpkg | `install-opencode` | The simplest payload |
| Single phase with health check and a stated host boundary | `install-openfga` | Its README section "When This Becomes a host-* Repo" is the model for yours |
| Multi-phase with Ansible, no good nixpkg, pre-seeded download | `install-idempiere`, `install-metabase` | |
| Imperative first-run bootstrap that creates secrets inside | `install-openbao` | Secrets never leave the container through an agent or log |

## Lifecycle

| Stage | Command |
|-------|---------|
| Launch | `./launch.sh configs/<app>.conf <prefix>-NN` |
| Launch, then install by hand with options | `./launch.sh configs/<app>.conf <prefix>-NN --no-install`, then `incus exec <prefix>-NN -- env SOME_VAR=value /opt/<app>-install/install.sh` |
| Change | `incus delete <prefix>-NN --force`, then launch again — confirm with the owner before deleting |

`launch.sh` is the only script; it refuses a container that already exists. An application-layer deploy owned by another repo (such as `idempiere-golive-deploy`) may still target an `install-*` container — that is that repo's contract, not this one.

## Repo Layout

```
install-myapp/
├── README.md               # Purpose, quick start, and when it becomes a host-*
├── CLAUDE.md               # AI-agent guidance
├── install.sh              # Required: the entry point
├── myapp-prerequisites.nix # Phase 1: system dependencies; disables IPv6 temporary addresses
├── myapp-service.nix       # Phase 2: the systemd service
└── ansible/                # Optional: only when no good nixpkg exists
    ├── myapp-install.yml
    └── vars/
        └── myapp.yml
```

## install.sh

`install.sh` runs inside the container with no arguments; options arrive as environment variables. It:

1. Wires each `.nix` module into `/etc/nixos/configuration.nix` idempotently — `grep -q` for the module, then `sed` it in after the `./incus.nix` anchor every incus NixOS container has.
1. Runs `sudo nixos-rebuild switch` — always `sudo`, even as root, for the proper `NIX_PATH`.
1. Runs any imperative phase (Ansible) that the Nix modules cannot express.
1. Optionally polls the service until it is healthy.

A timer in the payload follows [host-contract.md](host-contract.md) → "Give Every Payload Timer a Clone Buffer" from day one, because this repo may become a `host-*` that gets cloned.

## The Config File

```bash
# configs/myapp.conf
PREFIX="ma"                         # short abbreviation (see Naming)
PORT_BASE=9500                      # next unused block of 100; 0 = outbound-only
CONNECT_PORT=8080                   # port inside the container; 0 = no proxy
MEMORY="2GiB"                       # a safe start; nixos-rebuild can OOM at 512MB
CPU=2
DISK="10GiB"

SEED_DIR="/opt/myapp-seed"          # optional pre-seeded download
SEED_FILE=""                        # empty = skip

INSTALL_PATH="/opt/myapp-install"
INSTALLER_REPO="../install-myapp"

HEALTH_ENDPOINT="http://localhost:8080/health"
HEALTH_EXPECTED=200
HEALTH_TIMEOUT=60
HEALTH_INTERVAL=5
```

An `install-*` config never sets `SECRETS_TARGET`. Every variable is in README → "Config File Reference".

## Building a New install-* Repo

1. [ ] Create `install-<app>/` from the [Repo Layout](#repo-layout), copying from the closest [Worked Examples](#worked-examples) row; create the `oeig-io/install-<app>` repo
1. [ ] Pick the `PREFIX` and `PORT_BASE` ([Naming](#naming)) and write `configs/<app>.conf` in `container-management`
1. [ ] Write the README, including a "When This Becomes a host-* Repo" section naming the input or need that would push this payload over the line
1. [ ] Launch `<prefix>-01`; delete and relaunch until a launch comes up healthy with no manual step
1. [ ] Launch a second instance (`<prefix>-02`) alongside it to prove the payload really is a factory — no shared state, no port clash

## When an install-* Becomes a host-*

An `install-*` repo crosses the line the moment any of these is true:

- It needs an **input from outside the repo** — an API key, a preshared key, a licensed artifact. It is then an open system.
- It is headed for a **blessed production singleton** (`-00`) that other systems depend on.
- It needs **off-host backups**, production sizing, or a schedule that must not run on copies.
- It must be **changed in place** rather than deleted and relaunched.
- Other systems' configuration **references its identity** (store IDs, hostnames, tokens).

Then fork it: [host-contract.md](host-contract.md) → "Migrating an install-* Repo to host-*". The `install-*` repo keeps serving disposable `-01`/`-02` boxes; the `host-*` fork is pinned and diverges deliberately.

Not every `host-*` starts here. A service that is born a singleton with out-of-repo inputs — `host-lead-helper` was one — starts directly as a `host-*`.

Tags: #install-contract #container-management #nixos
