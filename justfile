# claude-mem justfile — simplified commands for build, dev, and deployment
#
# Usage: just <recipe>        Run a recipe
#        just --list          Show all available recipes
#        just                  Same as just --list (default)
#
# Requires: fnm (Fast Node Manager) for automatic Node version management.
# All pnpm recipes run under the correct Node version via `fnm exec`.

node_version := "24.13.0"
fnm := "fnm exec --using=" + node_version
compose := "podman-compose -f podman-compose.yml"

# ─── Default ──────────────────────────────────────────

# List available recipes
default:
    @just --list

# ─── Node Environment ────────────────────────────────

# Install required Node version via fnm (if not already present)
ensure-node:
    #!/usr/bin/env bash
    if ! command -v fnm &>/dev/null; then
        echo "Error: fnm is not installed. Install via: brew install fnm"
        exit 1
    fi
    if ! fnm ls | grep -q "v{{ node_version }}"; then
        echo "Installing Node {{ node_version }} via fnm..."
        fnm install {{ node_version }}
    fi
    # Ensure corepack is enabled so pnpm matches packageManager field
    {{ fnm }} corepack enable 2>/dev/null || true
    echo "Node $({{ fnm }} node --version), pnpm $({{ fnm }} pnpm --version) ready"

# ─── Build ────────────────────────────────────────────

# Build all packages
build: ensure-node
    {{ fnm }} pnpm -r build

# Build and bundle the Claude Code plugin
build-plugin: ensure-node
    {{ fnm }} pnpm build:plugin

# Build shared type definitions
build-types: ensure-node
    {{ fnm }} pnpm build:types

# Build the backend server
build-backend: ensure-node
    {{ fnm }} pnpm build:backend

# Build the worker service
build-worker: ensure-node
    {{ fnm }} pnpm build:worker

# Build the web UI
build-ui: ensure-node
    {{ fnm }} pnpm build:ui

# ─── Dev ──────────────────────────────────────────────

# Build plugin and sync to marketplace
dev: ensure-node
    {{ fnm }} pnpm dev

# Kill, reinstall, rebuild, and restart dev services
dev-restart: ensure-node
    {{ fnm }} pnpm dev:restart

# Start Vite dev server for UI
dev-ui: ensure-node
    {{ fnm }} pnpm dev:ui

# Sync plugin to Claude Code marketplace directories
sync: ensure-node
    {{ fnm }} pnpm sync-marketplace

# ─── Quality ──────────────────────────────────────────

# Run tests (vitest)
test: ensure-node
    {{ fnm }} pnpm test

# Run tests in watch mode
test-watch: ensure-node
    {{ fnm }} pnpm test:watch

# Run tests with coverage
test-coverage: ensure-node
    {{ fnm }} pnpm test:coverage

# Run TypeScript type checking
typecheck: ensure-node
    {{ fnm }} pnpm typecheck

# ─── Podman (containers) ─────────────────────────────

# First-time bootstrap (generate .env, build images)
setup:
    ./setup.sh

# Start containers in the background
up:
    {{ compose }} up -d

# Stop containers
down:
    {{ compose }} down

# Follow container logs
logs:
    {{ compose }} logs -f

# Restart containers (down + up)
restart: down up

# Check backend health endpoint (uses CLAUDE_MEM_REMOTE_TOKEN from .env)
health:
    #!/usr/bin/env bash
    port="${CLAUDE_MEM_HOST_PORT:-38888}"
    token=""
    if [ -f .env ]; then
        env_port=$(grep '^CLAUDE_MEM_HOST_PORT=' .env | cut -d= -f2)
        [ -n "$env_port" ] && port="$env_port"
        token=$(grep '^CLAUDE_MEM_REMOTE_TOKEN=' .env | cut -d= -f2)
    fi
    auth_header=""
    [ -n "$token" ] && auth_header="-H Authorization:\ Bearer\ $token"
    if [ -n "$token" ]; then
        curl -sf -H "Authorization: Bearer $token" "http://localhost:${port}/api/health" | python3 -m json.tool
    else
        curl -sf "http://localhost:${port}/api/health" | python3 -m json.tool
    fi || echo "Health check failed (port $port)"

# Show container status
ps:
    {{ compose }} ps

# Build container images without starting
build-images:
    {{ compose }} build

# ─── Data ─────────────────────────────────────────────

# Show configured data directory and database size
data-info:
    #!/usr/bin/env bash
    dir="${CLAUDE_MEM_DATA_DIR:-$HOME/.claude-mem}"
    if [ -f .env ]; then
        env_dir=$(grep '^CLAUDE_MEM_DATA_DIR=' .env | cut -d= -f2)
        [ -n "$env_dir" ] && dir="$env_dir"
    fi
    echo "Data directory: $dir"
    if [ -f "$dir/claude-mem.db" ]; then
        echo "Database size:  $(du -sh "$dir/claude-mem.db" | cut -f1)"
        echo "Total size:     $(du -sh "$dir" | cut -f1)"
        ls -lh "$dir/"
    else
        echo "No database found at $dir/claude-mem.db"
    fi

# Clone existing data to a test directory for parallel testing
data-clone target="$HOME/.claude-mem-test":
    #!/usr/bin/env bash
    src="${CLAUDE_MEM_DATA_DIR:-$HOME/.claude-mem}"
    target="{{ target }}"
    if [ ! -d "$src" ]; then
        echo "Source directory not found: $src"
        exit 1
    fi
    if [ -d "$target" ]; then
        echo "Target already exists: $target"
        echo "Remove it first with: just data-rm {{ target }}"
        exit 1
    fi
    echo "Cloning $src → $target ..."
    cp -R "$src" "$target"
    echo "Done. Update .env to use the clone:"
    echo "  CLAUDE_MEM_DATA_DIR=$target"

# Back up the database with a timestamp
data-backup:
    #!/usr/bin/env bash
    dir="${CLAUDE_MEM_DATA_DIR:-$HOME/.claude-mem}"
    if [ -f .env ]; then
        env_dir=$(grep '^CLAUDE_MEM_DATA_DIR=' .env | cut -d= -f2)
        [ -n "$env_dir" ] && dir="$env_dir"
    fi
    db="$dir/claude-mem.db"
    if [ ! -f "$db" ]; then
        echo "No database at $db"
        exit 1
    fi
    ts=$(date +%Y%m%d-%H%M%S)
    backup="$dir/claude-mem.db.backup-$ts"
    echo "Backing up $db → $backup ..."
    sqlite3 "$db" ".backup '$backup'"
    echo "Done. Backup: $backup ($(du -sh "$backup" | cut -f1))"

# List existing backups
data-backups:
    #!/usr/bin/env bash
    dir="${CLAUDE_MEM_DATA_DIR:-$HOME/.claude-mem}"
    if [ -f .env ]; then
        env_dir=$(grep '^CLAUDE_MEM_DATA_DIR=' .env | cut -d= -f2)
        [ -n "$env_dir" ] && dir="$env_dir"
    fi
    echo "Backups in $dir:"
    ls -lh "$dir"/claude-mem.db.backup-* 2>/dev/null || echo "  (none)"

# Restore database from a backup file
data-restore backup:
    #!/usr/bin/env bash
    dir="${CLAUDE_MEM_DATA_DIR:-$HOME/.claude-mem}"
    if [ -f .env ]; then
        env_dir=$(grep '^CLAUDE_MEM_DATA_DIR=' .env | cut -d= -f2)
        [ -n "$env_dir" ] && dir="$env_dir"
    fi
    db="$dir/claude-mem.db"
    backup="{{ backup }}"
    if [ ! -f "$backup" ]; then
        echo "Backup file not found: $backup"
        echo "Available backups:"
        ls -1 "$dir"/claude-mem.db.backup-* 2>/dev/null || echo "  (none)"
        exit 1
    fi
    echo "Restoring $backup → $db ..."
    echo "WARNING: This will overwrite the current database."
    read -rp "Continue? [y/N] " confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        cp "$backup" "$db"
        rm -f "$db-shm" "$db-wal"
        echo "Done. Restart containers: just restart"
    else
        echo "Aborted."
    fi

# Remove a cloned test data directory
data-rm target="$HOME/.claude-mem-test":
    #!/usr/bin/env bash
    target="{{ target }}"
    if [ ! -d "$target" ]; then
        echo "Directory not found: $target"
        exit 1
    fi
    echo "Will remove: $target"
    ls -lh "$target/"
    read -rp "Continue? [y/N] " confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        rm -rf "$target"
        echo "Removed."
    else
        echo "Aborted."
    fi

# ─── Proxy (LAN access) ───────────────────────────────

# Start Caddy reverse proxy for LAN access (0.0.0.0:38889 → localhost:38888)
proxy:
    caddy start --config Caddyfile

# Stop Caddy reverse proxy
proxy-stop:
    caddy stop

# ─── Housekeeping ─────────────────────────────────────

# Remove all build artifacts and node_modules
clean: ensure-node
    {{ fnm }} pnpm -r clean && rm -rf node_modules

# Install dependencies
install: ensure-node
    {{ fnm }} pnpm install
