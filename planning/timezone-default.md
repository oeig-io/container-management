# Timezone Default Strategy

## Status: Planned (Not Yet Implemented)

This document outlines the strategy for setting a default timezone (America/Chicago) for all NixOS containers while maintaining the ability to override per-container for customer-specific needs.

## Problem Statement

Currently, all containers default to UTC timezone. This causes issues with:
- PostgreSQL timestamps
- Application logs showing wrong times
- Java application behavior (iDempiere, Metabase)
- User experience for ANS team

## Proposed Solution

Three-phase implementation that sets America/Chicago as the default while allowing per-container overrides through config files.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Standard 2: Container Orchestration (container-management)               │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │  Config File (configs/*.conf)                                    │   │
│  │  • TIMEZONE="" (optional, empty = use default)                   │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                              ↓                                          │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │  launch.sh                                                       │   │
│  │  • Copies install-* repo to container                           │   │
│  │  • If TIMEZONE set: modifies .nix file via sed                  │   │
│  │  • Calls install.sh                                             │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                              ↓                                          │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │  Standard 1: Application Installer (install-*)                  │   │
│  │  • *-prerequisites.nix has default: America/Chicago               │   │
│  │  • install.sh runs nixos-rebuild with (possibly modified) .nix  │   │
│  └─────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────┘
```

## Implementation Phases

### Phase 1: Set Default in Install Submodules

Modify the following `.nix` files to include `time.timeZone = "America/Chicago";`:

| Submodule | File Path | Location in File |
|-----------|-----------|------------------|
| install-idempiere | `idempiere-prerequisites.nix` | After the `in {` block, before system.activationScripts |
| install-metabase | `metabase-prerequisites.nix` | After the `in {` block, before system.activationScripts |
| install-opencode | `opencode.nix` | After the `in {` block, before system.activationScripts |

**Example addition to each file:**
```nix
in {
  #############################################################################
  # Timezone Configuration - Default to America/Chicago
  # Can be overridden by container-management/launch.sh when needed
  #############################################################################
  time.timeZone = "America/Chicago";

  #############################################################################
  # Compatibility: Scripts may expect /bin/bash
  ...
```

**Why prerequisites.nix?**
- Timezone is a system-level prerequisite (like PostgreSQL, Java)
- Follows Standard 1 contract: "Phases: 1-N: prerequisites → ansible → service → nginx"
- Single location controls OS-level configuration
- All containers will inherit this default unless explicitly overridden

### Phase 2: Add Config Variable

Add to all config files in `container-management/configs/`:

```bash
# Timezone configuration (optional)
# Set to override the default America/Chicago from *-prerequisites.nix
# Leave empty or unset to use default
# Examples: "America/New_York", "America/Los_Angeles", "Europe/London"
TIMEZONE=""
```

**Files to update:**
- `configs/idempiere.conf`
- `configs/idempiere-no-cache.conf`
- `configs/metabase.conf`
- `configs/opencode.conf`

### Phase 3: Modify launch.sh

Add a new step (Step 4b) after Step 4 (push installer repo) in `launch.sh`:

```bash
# Step 4b: Update timezone if specified in config
if [[ -n "${TIMEZONE:-}" ]]; then
    echo ">>> Step 4b: Updating timezone to $TIMEZONE..."
    
    # Determine which .nix file to modify based on container type
    case "$PREFIX" in
        "id")
            NIX_FILE="$INSTALL_PATH/idempiere-prerequisites.nix"
            ;;
        "mb")
            NIX_FILE="$INSTALL_PATH/metabase-prerequisites.nix"
            ;;
        "oc")
            NIX_FILE="$INSTALL_PATH/opencode.nix"
            ;;
        *)
            echo "WARNING: Unknown prefix '$PREFIX', cannot update timezone"
            NIX_FILE=""
            ;;
    esac
    
    if [[ -n "$NIX_FILE" ]]; then
        # Replace the timezone value in the .nix file
        # This assumes the line exists from Phase 1 (the default)
        incus exec "$CONTAINER" -- sed -i "s|time.timeZone = \"America/Chicago\";|time.timeZone = \"$TIMEZONE\";|" "$NIX_FILE"
        echo "    Timezone updated in $(basename "$NIX_FILE")"
    fi
    echo ""
fi
```

## Flow Diagram

```
┌─────────────────────────────────────────────────────────────┐
│  Create New Container                                         │
│  ./launch.sh configs/idempiere.conf id-47                     │
└─────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────┐
│  Step 4: Push installer repo                                │
│  • Copies install-idempiere/* to /opt/idempiere-install/     │
│  • Includes idempiere-prerequisites.nix with default Chicago  │
└─────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────┐
│  Step 4b: Check TIMEZONE in config                            │
│  • If TIMEZONE="" or not set: Skip (use default from .nix)    │
│  • If TIMEZONE="America/New_York":                           │
│    → Run sed to replace "America/Chicago" with "America/NY"   │
└─────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────┐
│  Step 5: Run install.sh                                       │
│  • Runs nixos-rebuild switch                                  │
│  • Uses (possibly modified) prerequisites.nix                 │
└─────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────┐
│  Result                                                       │
│  • Container has specified timezone (or default Chicago)    │
│  • PostgreSQL, Java, logs all use local time                  │
└─────────────────────────────────────────────────────────────┘
```

## Customer-Specific Usage Examples

### For a customer in New York:

Create custom config:
```bash
# configs/idempiere-ny.conf
cp configs/idempiere.conf configs/idempiere-ny.conf
# Edit to add: TIMEZONE="America/New_York"
```

Launch container:
```bash
./launch.sh configs/idempiere-ny.conf id-ny-01
```

### For default (Chicago) customers:

Just use the standard config:
```bash
./launch.sh configs/idempiere.conf id-01
```

## Backward Compatibility

- **Existing containers**: Unaffected (already have their .nix files deployed)
- **New containers without TIMEZONE set**: Get America/Chicago (from .nix defaults)
- **New containers with TIMEZONE set**: Get specified timezone (override works)
- **Existing config files without TIMEZONE**: Continue working (defaults apply)
- **No breaking changes**: The default behavior changes (UTC → Chicago), but this is the intended fix

## Testing Plan

After implementation, verify:

1. **Create container without TIMEZONE**
   ```bash
   ./launch.sh configs/idempiere.conf id-test-01
   incus exec id-test-01 -- date  # Should show Chicago time
   incus exec id-test-01 -- psqli -c "SHOW timezone;"  # Should show America/Chicago
   ```

2. **Create container with custom TIMEZONE**
   ```bash
   # Edit configs/idempiere.conf temporarily: TIMEZONE="America/New_York"
   ./launch.sh configs/idempiere.conf id-test-02
   # Should show New York time
   ```

3. **Verify PostgreSQL uses correct timezone**
   ```bash
   incus exec id-test-01 -- psqli -c "SELECT NOW();"  # Should show Chicago time
   ```

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| sed pattern fails if .nix syntax changes | Low | High | Document the dependency; use simple sed pattern |
| TIMEZONE not set in config causes confusion | Medium | Low | Empty default is documented; logs show "skipping" |
| Customer forgets to set TIMEZONE | Medium | Medium | Most customers are in Chicago area, so default is correct |
| Wrong timezone format (e.g., "EST") | Low | Medium | Document IANA timezone format; add validation in launch.sh |

## Alternative Approaches Considered

### Option A: Hardcoded in .nix only (rejected)
- Add `time.timeZone = "America/Chicago";` to all .nix files
- **Pros**: Simple, one-time change
- **Cons**: No per-container override capability; customer-specific deployments need custom submodules

### Option B: Container-level environment variable (rejected per user requirement)
- Use `incus config set $CONTAINER environment.TZ=America/Chicago`
- **Pros**: No NixOS rebuild needed
- **Cons**: Violates requirement to only use NixOS config; may not affect all services uniformly

### Option C: Config-driven injection into .nix (chosen)
- Default in .nix files, optional override via config + sed in launch.sh
- **Pros**: Clean separation, per-container flexibility, follows existing architecture
- **Cons**: sed-based modification is slightly fragile

## Future Enhancements

1. **Validation**: Add timezone format validation in launch.sh (check against known IANA zones)
2. **Logging**: Log timezone change in container logs for audit purposes
3. **Template approach**: Instead of sed, use a template file with `@@TIMEZONE@@` placeholder
4. **Documentation**: Update customer-facing docs to explain timezone configuration

## Files to Modify (Checklist)

- [ ] `install-idempiere/idempiere-prerequisites.nix`
- [ ] `install-metabase/metabase-prerequisites.nix`
- [ ] `install-opencode/opencode.nix`
- [ ] `container-management/configs/idempiere.conf`
- [ ] `container-management/configs/idempiere-no-cache.conf`
- [ ] `container-management/configs/metabase.conf`
- [ ] `container-management/configs/opencode.conf`
- [ ] `container-management/launch.sh`

## Decision Log

**2026-03-20**: Plan created based on investigation of all install-* submodules and container-management architecture. Strategy approved by user: Default in .nix files (Chicago), optional override via config files + sed in launch.sh.

---

**Last Updated**: 2026-03-20  
**Status**: Planned (awaiting implementation)  
**Owner**: TBD
