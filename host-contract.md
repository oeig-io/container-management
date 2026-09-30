# host-* Contract

The purpose of this document is to govern how a `host-*` repo and its container are built, launched, changed, and copied, so that "look at container-management and build me a host-…" has exactly one answer. This is important because a `host-*` container is a one-of-a-kind production identity whose credentials live outside its repo — when every `host-*` repo follows the same contract, anyone who can operate one can launch, redeploy, rotate, and clone them all.

The `install-*` factory variant and the orchestration standard that both variants share are in [README.md](README.md).

## TOC

- [What a host-* Repo Is](#what-a-host--repo-is)
- [Naming](#naming)
- [Worked Examples](#worked-examples)
- [Lifecycle](#lifecycle)
- [Repo Layout](#repo-layout)
- [launch.conf](#launchconf)
- [Container Vault Identity](#container-vault-identity)
  - [Minting and Delivering the Token](#minting-and-delivering-the-token)
  - [Token Lifetime](#token-lifetime)
- [Service Credentials](#service-credentials)
- [deploy.sh](#deploysh)
- [Building a New host-* Repo](#building-a-new-host--repo)
- [Delete Protection on -00](#delete-protection-on--00)
- [Clone Script](#clone-script)
  - [Give Every Payload Timer a Clone Buffer](#give-every-payload-timer-a-clone-buffer)
- [Migrating an install-* Repo to host-*](#migrating-an-install--repo-to-host-)
- [Legacy Local File Channel](#legacy-local-file-channel)

## What a host-* Repo Is

A `host-*` repo owns a single long-lived container identity. It is an **open system** by definition: it has inputs (API keys, licensed artifacts) that cannot live in the repo and must enter from outside.

| Property | Value |
|----------|-------|
| Container naming | Full-word prefix (`lead-helper-00`) — a stranger must understand purpose from `incus list`. Short legacy names (`id-01`) are grandfathered. |
| `launch.conf` | Inside the repo, not in `configs/` — the repo is self-contained |
| `INSTALL_PATH` | `/opt/<name>/` — the repo **is** the runtime |
| Instances | `-01`, `-02`, … are disposable iterations; `-00` is the blessed production singleton |
| Credentials | One couriered secret: the container's own vault token — see [Container Vault Identity](#container-vault-identity) |
| Ownership | `launch.sh` and `deploy.sh` enforce `root:root` on `INSTALL_PATH` after every push (README → "Ownership Note") |

Both variants also satisfy the shared payload contract — README → "Standard 1: Application Payload".

## Naming

The purpose of this section is to derive every name a `host-*` repo creates from one root, `<name>`, so a human or model who knows the repo name can predict every other name without looking. This is important because three scripts depend on the pattern mechanically: `launch.sh` refuses a container that is not `PREFIX-NN`, `deploy.sh` expects its token to carry `team-host-<name>-reader`, and `bao-mint-login-token.sh` refuses any user not named `*-service`.

`<name>` is lowercase, dashed, and full words (`lead-helper`, not `lh`) — a stranger reading `incus list` must understand what the container does. Code examples in this document use `myname`.

| Thing | Pattern | Example (`<name>` = `lead-helper`) | Set by |
|-------|---------|-------------------------------------|--------|
| Repo | `host-<name>` | `host-lead-helper` | you |
| `PREFIX` | `<name>` | `lead-helper` | `launch.conf` |
| Container | `<name>-NN`; `-00` is production | `lead-helper-00`, `lead-helper-01` | `launch.sh` |
| Code on the container (`INSTALL_PATH`) | `/opt/<name>/` | `/opt/lead-helper/` | `launch.conf` |
| State and secrets | `/var/lib/<name>/` | `/var/lib/lead-helper/` | `.nix` tmpfiles |
| Container vault token (`SECRETS_TARGET`) | `/var/lib/<name>/openbao-token` | `/var/lib/lead-helper/openbao-token` | `launch.conf` |
| Linux service user | `<name>` | `lead-helper` | `<name>-service.nix` |
| OpenBao team | `host-<name>` — the repo name | `host-lead-helper` | `bao-create-team.sh` |
| Team secrets path | `secret/teams/host-<name>/` | `secret/teams/host-lead-helper/` | first write |
| Team policies and groups | `team-host-<name>-reader`, `team-host-<name>-manager` | `team-host-lead-helper-reader` | `bao-create-team.sh` |
| OpenBao service user | `<name>-service` | `lead-helper-service` | `bao-create-user.sh` |
| Working secret | `<upstream>-<scope>-<purpose>` | `fastmail-api-leads-reader` | a team manager |

Two names differ on purpose:

- **The team is named for the repo** (`host-<name>`) because its members are the *people* who may deploy and rotate that repo's container.
- **The service user is named for the machine** (`<name>-service`). The suffix marks an identity no person logs in as: a person is never `*-service`, and a `*-service` user is never a person — which is what makes the mint script's password reset safe.

> 📝 **Note** — Older repos predate this table: `host-marketing-system` uses `PREFIX="marketing"`, `host-idempiere` and `host-openbao` keep `/opt/<name>-install/` from their `install-*` forks, and `host-ai-user`, `host-elevenlabs`, and `host-marketing-system` courier env files instead of a vault token. Do not copy those; new repos follow the table.

## Worked Examples

No single repo yet shows everything. Copy each part from the repo that does it best:

| Part | Copy from | Note |
|------|-----------|------|
| Vault identity, service credentials, `deploy.sh --token-stdin` | `host-lead-helper` | First of its kind |
| `nix-modules.conf` manifest, `clone.sh` | `host-idempiere` | `host-lead-helper` has no `clone.sh` yet |
| Guarded production deploy | `host-idempiere/deploy-nixos.sh` | Dry-activate preview + `--confirm` |
| Minimal `deploy.sh` | `host-ai-user/deploy.sh` | No secrets |
| Fork from an `install-*` repo | `host-openbao` | |

`host-elevenlabs` predates the vault identity and `clone.sh` — do not copy its secrets layout.

## Lifecycle

| Stage | Command | Runs |
|-------|---------|------|
| First boot | `container-management/launch.sh ../host-<name>/launch.conf <name>-NN --secrets -` | Once per container |
| Every change after | `host-<name>/deploy.sh [--token-stdin] <name>-NN` | As often as needed |
| Bless production | [Delete Protection on -00](#delete-protection-on--00) | Once, on `-00` only |
| Copy | `host-<name>/clone.sh` | Per clone — see [Clone Script](#clone-script) |

`launch.sh` is first boot only; it refuses a container that already exists. Iterate `-01`, `-02`, … (delete and relaunch freely, after confirming with the owner) and bless `-00` only after two consecutive clean launches.

## Repo Layout

```
host-myname/
├── README.md                   # Purpose, status, quick start
├── CLAUDE.md                   # AI-agent guidance
├── launch.conf                 # Container config (lives HERE, not in configs/)
├── install.sh                  # First boot: prereq check + wire .nix + nixos-rebuild
├── deploy.sh                   # Every change after first boot (see deploy.sh)
├── clone.sh                    # Clone into a distinct machine (see Clone Script)
├── nix-modules.conf            # Manifest: every .nix and its clone disposition
├── nix-modules.sh              # Reads the manifest (copied from any host-* repo)
├── myname-prerequisites.nix    # Base packages; disables IPv6 temporary addresses
├── myname-service.nix          # Service user, systemd units, tmpfiles
├── bin/                        # Runtime code, including the credential wrapper
└── docs/
    └── secrets.md              # Vault paths that must pre-exist, who provisions them, rotation
```

`install.sh` checks `test -f <SECRETS_TARGET>` first, wires the manifest's modules into `/etc/nixos/configuration.nix` idempotently, and ends with `sudo nixos-rebuild switch` (always `sudo`, even as root).

## launch.conf

```bash
# host-myname/launch.conf
PREFIX="myname"                 # full word, not abbreviation
PORT_BASE=0                     # 0 = outbound-only (no inbound proxy)
CONNECT_PORT=0
MEMORY="2GB"                    # nixos-rebuild OOMs at 512MB
CPU="1"
DISK="5GB"

INSTALLER_REPO="../host-myname"
INSTALL_PATH="/opt/myname"      # unified — repo IS the runtime

SECRETS_TARGET="/var/lib/myname/openbao-token"   # the container's vault token
```

`deploy.sh` sources the same file, so `INSTALL_PATH` and `SECRETS_TARGET` are defined once. The full variable reference is README → "Config File Reference".

## Container Vault Identity

The purpose of this section is to give each `host-*` container its own vault identity, so its services can start — and restart — without anyone injecting a secret. This is important because systemd restarts services often; a service that needs a person at every start is not a service.

- **One team per host.** The team `host-<name>` owns `secret/teams/host-<name>/` ([Naming](#naming)). Its managers and readers are the people who may deploy and rotate it. The team path holds **only what the service needs**: everything in it is readable by the container.
- **One service user.** A userpass user named `<name>-service` is a **reader** — never a manager — of that team. Team access arrives through group membership, so the container's token must be a *login* token of that user; the `host-openbao` "Users and Teams" model covers why.
- **The token lives only in the container**, at `SECRETS_TARGET` (`0600 root:root`). It is never stored in the vault or on an operator's disk. OpenBao cannot return a token's value after issuing it, so a lost token is replaced by minting another, never by reading one back.
- **One token per container.** Every mint is a new token, so `-00` and `-01` never share one and revoking an iteration never touches production.
- **Clones scrub it.** The token is egress authority; `clone.sh` removes `SECRETS_TARGET` — see the `incus-instance-clone` skill.

**Worst case.** Anyone who gains the service user's permissions can read the token and every working secret — the credential directory is readable by that user for as long as the unit runs. They get everything the team path holds, including secrets added later (group policies resolve per request), from any machine that can reach the vault, until the token is revoked. They cannot write to the vault. Keep the team path minimal and revoke by accessor on any suspicion.

### Minting and Delivering the Token

The token goes from the mint straight into its consumer through a pipe — no file, no environment variable, no stored copy:

```bash
bao login -method=userpass username=<admin>
cd container-management

# First boot
../host-openbao/scripts/bao-mint-login-token.sh myname-service \
    | ./launch.sh ../host-myname/launch.conf myname-01 --secrets -

# Replace the token on a running container
../host-openbao/scripts/bao-mint-login-token.sh myname-service \
    | ../host-myname/deploy.sh --token-stdin myname-01
```

Minting resets the service user's password, so it is an OpenBao admin's action. The mint script's header documents what it does and refuses. If `launch.sh` fails after the mint, revoke the accessor the mint printed; `deploy.sh` does that for itself.

> ⚠️ **Warning** — **Minting never revokes.** Every login adds a token, and the one it replaces stays valid until it expires. Revoking is its own step: once the new token is confirmed working, run the `bao token revoke -accessor <accessor>` line the mint script printed for the old token.

> ⚠️ **Warning** — An AI agent's command runner is not a terminal, so the mint script's terminal guard cannot stop a token from landing in the agent's transcript. Always pipe into a consumer; when testing, pipe into `wc -c`. A token that reaches a transcript is revoked immediately.

### Token Lifetime

The service user's `token_period` (720h) makes the token periodic: it expires when a full period passes without a renewal, and renewals are unlimited. **Nothing renews it yet**, so a container needs a fresh mint and `deploy.sh --token-stdin` within each period — otherwise its next service start fails. Renewal is the planned sidecar's job; until it exists, record the mint date in the repo's `docs/secrets.md`.

## Service Credentials

The purpose of this section is to define how a unit turns the container's vault token into the working secrets it needs, so a rotated secret reaches the service without a person.

- **`LoadCredential=`** hands `SECRETS_TARGET` to the unit as `$CREDENTIALS_DIRECTORY/openbao-token`; the service user never reads the source file.
- **Fetch at start.** A wrapper `ExecStart` reads the working secrets from `secret/teams/host-<name>/`, passes them to the service, and `exec`s it. The service holds no vault client.
- **Exit on rejection.** When an upstream rejects a credential (HTTP 401/403), the service exits non-zero instead of retrying. systemd restarts it, and the wrapper fetches the current value. To rotate a working secret, write the new value to the vault **first**, then revoke the old one at the upstream — the reverse order leaves the service restarting against a vault that still holds the dead value.
- **Bounded restarts are the monitor.** Set `startLimitIntervalSec` / `startLimitBurst` on the unit (top-level NixOS unit options — systemd ignores them in `serviceConfig`). A credential that stays rejected then ends in `failed` instead of looping forever, and `failed` is the signal: `systemctl --failed`, or `systemctl is-failed <unit>`. After fixing the cause: `systemctl reset-failed <unit> && systemctl start <unit>`. Active alerting on failure is not yet standard.

Worked example: `host-lead-helper` → `bin/lead-helper-env.sh` and `lead-helper-service.nix`.

## deploy.sh

The purpose of `deploy.sh` is to apply every change to a running container after first boot — repo content, `.nix` modules, and, when one is piped in, a new vault token. This is important because it is the one predictable path to a running container; nothing reaches production by hand.

| Requirement | Why |
|-------------|-----|
| Anchors to its own directory (`SCRIPT_DIR`) | `incus file push -rq .` from a parent workspace scans sibling repos |
| Refuses a dirty working tree unless `--dirty` | The server never drifts ahead of git; follow a `--dirty` deploy with a clean one |
| Sources `launch.conf` for `INSTALL_PATH` and `SECRETS_TARGET` | Defined once |
| Pushes the repo, `chown -R root:root`, then `sudo nixos-rebuild switch` — by re-running `install.sh` when it is idempotent, so a newly added module gets wired | The same ownership invariant as `launch.sh` |
| `--token-stdin` reads stdin **before the first `incus` call** and refuses a terminal | `incus exec` reads stdin too and would swallow the token |
| `--token-stdin` preflights the token — valid, and carrying `team-host-<name>-reader` | A wrong or dead token never replaces a working one |
| `--token-stdin` pushes the token `0600 root:root` to `SECRETS_TARGET`, restarts the units that load it, and verifies they are active | `nixos-rebuild` does not restart an unchanged unit |
| Without `--token-stdin`, the container's token is untouched | Routine deploys need no vault login |
| Never revokes the token it replaces; revokes a piped token it failed to deliver | Replacing is deliberate and separate — see [Minting and Delivering the Token](#minting-and-delivering-the-token); an undelivered token must not linger |

`incus file push -r` does not delete files removed locally — `rm` them on the container before deploying. For a `-00` whose rebuild can bounce a customer-facing service, add a dry-activate preview and `--confirm <name>`, as `host-idempiere/deploy-nixos.sh` does.

## Building a New host-* Repo

1. [ ] Create `host-<name>/` from the [Repo Layout](#repo-layout), copying each part from its [Worked Examples](#worked-examples) row; create the private `oeig-io/host-<name>` repo
1. [ ] Author [launch.conf](#launchconf)
1. [ ] Provision the vault (`host-openbao/scripts`; an OpenBao admin), and record every path in `docs/secrets.md`
   - [ ] `./bao-create-team.sh host-<name>`, then grant the deployers their roles with `./bao-team-membership.sh`
   - [ ] Create the service user with a password nobody keeps: `pw=$(openssl rand -hex 32); printf '%s\n%s\n' "$pw" "$pw" | ./bao-create-user.sh <name>-service; unset pw`
   - [ ] `./bao-team-membership.sh add <name>-service host-<name> reader`
   - [ ] Write each working secret under `secret/teams/host-<name>/`
1. [ ] Write the service per [Service Credentials](#service-credentials) and a [deploy.sh](#deploysh)
1. [ ] Launch `-01` by piping a mint into `launch.sh` ([Minting and Delivering the Token](#minting-and-delivering-the-token)); iterate until two consecutive clean launches
1. [ ] Launch `-00` and enable [Delete Protection on -00](#delete-protection-on--00)
1. [ ] Author the [Clone Script](#clone-script)

## Delete Protection on -00

**A blessed `host-*` production singleton (`myname-00`) must have incus delete protection enabled.** This is important because `-00` is a long-lived, one-of-a-kind production identity — unlike the throwaway `-01`/`-02` iterations, losing it means losing production. Incus `security.protection.delete` makes `incus delete` fail closed until the flag is deliberately cleared, so no reflex or scripted deletion can wipe production.

Enable it the moment you bless `-00`, and only on `-00`:

```bash
incus config set myname-00 security.protection.delete=true
incus config get myname-00 security.protection.delete   # -> true
```

Deleting a protected singleton is therefore a two-step, deliberate act — clear the flag first, then delete:

```bash
incus config set myname-00 security.protection.delete=false
incus delete myname-00
```

> ⚠️ **Warning** — This is a mandatory step of blessing `-00`, not optional hardening. Audit it periodically: every `*-00` `host-*` container should report `security.protection.delete=true`. The flag belongs to the singleton **only** — a clone that wears it cannot be rolled back or reaped, and clearing it routinely on clones is what eventually gets it cleared on production. Clone scripts set it `false` explicitly rather than inheriting it.

## Clone Script

**A `host-*` repo ships a `clone.sh`, and the `incus-instance-clone` skill is its specification.** This is important because a long-lived singleton accumulates things a generic copy cannot know about — an application-level production flag, a licensed artifact, a credential that writes to a shared destination. Only this repo knows that list, so the clone script is part of the payload contract, not an afterthought someone improvises later under pressure.

Write it against that skill's **Clone Script Checklist**, which covers the three phases a clone must pass (machine identity, egress authority, application sanitization), the all-or-nothing failure contract, and the verification that gates it. `host-idempiere/clone.sh` is the worked example.

Two obligations outlive the first draft:

- **Re-run the checklist whenever the payload changes.** A new `.nix` module, a new credential, or a new outbound integration can invalidate a clone script that still reports success. Say so in the repo's `CLAUDE.md`.
- **Make the drift mechanical where you can.** Classify every `.nix` in one manifest and have `install.sh`, `deploy.sh`, and `clone.sh` all read it, so an unclassified module fails the run instead of shipping in a clone. See `host-idempiere/nix-modules.conf`.

Compose the payload so a clone is defined by what its config **omits**: keep a scheduled unit's timer in its own module so a clone can delete the schedule and keep the capability. The skill's "Subtract, Never Shadow" section explains why an override module is the wrong instinct.

### Give Every Payload Timer a Clone Buffer

**A timer in a `host-*`/`install-*` payload must not be able to fire during a clone's first boot. Set `OnBootSec` to at least 15 minutes.**

This is important because subtracting a timer's module removes its *declaration*, not the unit. NixOS boots the generation the **source** built, and `configuration.nix` is only input to a rebuild — so a subtracted timer is live from the clone's first boot until the clone script's `nixos-rebuild switch` tears it down. A timer that elapses inside that gap runs on a machine holding production's credentials that nothing has sanitized yet.

The buffer has to be generous because there is no way to boot a container without timers: the mechanisms that would do it (`systemd.mask=` on the kernel command line, an offline `/dev/null` mask under `/etc/systemd/system`) are unavailable to a container or blocked by read-only Nix-rendered `/etc`. A clone script needs a few minutes to settle the boot and disarm; 15 minutes leaves headroom for a slow boot and for someone cloning by hand.

Two companions to get right at the same time:

- **`Persistent=` only works with `OnCalendar=`.** On a monotonic timer (`OnUnitActiveSec=`) it is inert, so do not use it to promise catch-up after downtime — switch the cadence to `OnCalendar=` if catch-up is what you want. Note that `OnCalendar=` **plus** `Persistent=true` fires *immediately* on boot when a run was missed, which defeats the buffer: pair it with `RandomizedDelaySec=` past the window, or accept that the clone script's disarm is the only guard.
- **Never shorten the buffer to make a job start sooner.** A job that must run at boot is a job that has no buffer; give it a `ConditionPathExists=` or an environment gate instead, so a clone can decline it.

## Migrating an install-* Repo to host-*

The purpose of this section is to define how a factory payload becomes a production singleton: **fork the `install-*` repo into a `host-*` repo** and grow the production layer on top of the copy. This matters because production must be a closed, pinned system — it must not silently inherit factory churn.

Migrate when a service is headed for a blessed `-00` singleton and the repo needs things the factory must never carry: backup schedules and off-host pushes, production sizing, a clone script. Until then, `-01`/`-02` iterations keep running from the `install-*` repo.

Worked examples: `host-openbao` (forked from `install-openbao`) and `host-idempiere` (forked from `install-idempiere`).

1. [ ] Copy and re-init: `cp -r install-openbao host-openbao && rm -rf host-openbao/.git`, then `git init`, first commit, new private `oeig-io` repo
2. [ ] Record **Fork Provenance** in the README (source repo + commit) — the fork is *pinned*: factory changes are deliberate, reviewed ports, diffed against that commit (never a blind merge)
3. [ ] Make it self-referential: add a `launch.conf` in the repo with `INSTALLER_REPO="../host-openbao"`, a full-word `PREFIX`, and production sizing
4. [ ] Add `nix-modules.conf` + `nix-modules.sh` (copy from any `host-*` repo) so `install.sh`, `deploy.sh`, and `clone.sh` share one module manifest — every `.nix` must be classified `keep` / `clone-remove` / `library`, and each script refuses to run while one is unclassified
5. [ ] Add the production-only modules, split along the clone boundary (see [Give Every Payload Timer a Clone Buffer](#give-every-payload-timer-a-clone-buffer)): capability `keep`, schedule `*-timer.nix` `clone-remove`, off-host push `clone-remove`
6. [ ] If it needs credentials, give it a [Container Vault Identity](#container-vault-identity) and a [deploy.sh](#deploysh)
7. [ ] Author `clone.sh` ([Clone Script](#clone-script))
8. [ ] On blessing `-00`: [Delete Protection on -00](#delete-protection-on--00)

> 💡 **Tip** — The copy *is* the point, not a shortcut around writing a fresh repo: a `host-*` payload is self-contained by definition, so the fork starts from a known-good, fully exercised installer and diverges deliberately from there.

## Legacy Local File Channel

`launch.sh --secrets <local-path>` pushes a file from the operator's disk to `SECRETS_TARGET` (`0600 root:root`, parent `0711 root:root`). `host-elevenlabs` still uses it for an env file of working secrets. New `host-*` repos use [Container Vault Identity](#container-vault-identity) instead: a file on an operator's disk is a copy that goes stale and a secret at rest outside the vault.

Tags: #host-contract #container-management #openbao #deploy
