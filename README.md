# Container Management

Generic container lifecycle management for NixOS incus containers.

## Quick Start

```bash
# Create an iDempiere container
./launch.sh configs/idempiere.conf id-47

# Create a Metabase container
./launch.sh configs/metabase.conf mb-01

# Create container without running install (for manual install)
./launch.sh configs/idempiere.conf id-47 --no-install
```

## How It Works

The launcher performs these steps:

1. **Create container** - NixOS 25.11 with configured resources
2. **Add proxy** - Port forward from host to container
3. **Pre-seed** - Push download files if configured
4. **Push installer** - Copy installer repo to container
5. **Run install** - Execute install.sh (unless --no-install)
6. **Health check** - Wait for service readiness

## Config Files

Each container type has a config file in `configs/`:

| File | Container Type | Naming | Ports |
|------|---------------|--------|-------|
| `idempiere.conf` | iDempiere ERP | `id-XX` | `90XX` |
| `metabase.conf` | Metabase BI | `mb-XX` | `91XX` |

### Config Options

```bash
PREFIX="id"              # Container name prefix
PORT_BASE=9000           # Base port (port = PORT_BASE + XX)
CONNECT_PORT=443         # Internal port to proxy to
MEMORY="4GiB"            # RAM limit
CPU=2                    # CPU limit
DISK="20GiB"             # Disk size
SEED_DIR="/opt/seed"     # Pre-seed directory (optional)
SEED_FILE="file.zip"     # Pre-seed file (optional, "" to skip)
INSTALL_PATH="/opt/app"  # Path inside container
INSTALLER_REPO="../repo" # Relative path to installer repo
HEALTH_ENDPOINT="..."    # URL to check for readiness
HEALTH_EXPECTED=200      # Expected HTTP status
HEALTH_TIMEOUT=90        # Max seconds to wait
HEALTH_INTERVAL=5        # Seconds between checks
```

## Adding New Container Types

1. Create a new config file: `configs/myapp.conf`
2. Create the installer repo with `install.sh`
3. Run: `./launch.sh configs/myapp.conf myapp-01`

## Prerequisites

- incus installed and configured
- Installer repos exist at configured paths
