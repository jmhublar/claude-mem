# claude-mem justfile — simplified commands for build, dev, and deployment
#
# Usage: just <recipe>        Run a recipe
#        just --list          Show all available recipes
#        just                  Same as just --list (default)

compose := "podman-compose -f podman-compose.yml"

# ─── Default ──────────────────────────────────────────

# List available recipes
default:
    @just --list

# ─── Build ────────────────────────────────────────────

# Build all packages
build:
    pnpm -r build

# Build and bundle the Claude Code plugin
build-plugin:
    pnpm build:plugin

# Build shared type definitions
build-types:
    pnpm build:types

# Build the backend server
build-backend:
    pnpm build:backend

# Build the worker service
build-worker:
    pnpm build:worker

# Build the web UI
build-ui:
    pnpm build:ui

# ─── Dev ──────────────────────────────────────────────

# Build plugin and sync to marketplace
dev:
    pnpm dev

# Kill, reinstall, rebuild, and restart dev services
dev-restart:
    pnpm dev:restart

# Start Vite dev server for UI
dev-ui:
    pnpm dev:ui

# Sync plugin to Claude Code marketplace directories
sync:
    pnpm sync-marketplace

# ─── Quality ──────────────────────────────────────────

# Run tests (vitest)
test:
    pnpm test

# Run tests in watch mode
test-watch:
    pnpm test:watch

# Run tests with coverage
test-coverage:
    pnpm test:coverage

# Run TypeScript type checking
typecheck:
    pnpm typecheck

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

# Check backend health endpoint
health:
    #!/usr/bin/env bash
    port="${CLAUDE_MEM_HOST_PORT:-38888}"
    if [ -f .env ]; then
        env_port=$(grep '^CLAUDE_MEM_HOST_PORT=' .env | cut -d= -f2)
        [ -n "$env_port" ] && port="$env_port"
    fi
    curl -sf "http://localhost:${port}/api/health" && echo || echo "Health check failed (port $port)"

# Show container status
ps:
    {{ compose }} ps

# Build container images without starting
build-images:
    {{ compose }} build

# ─── Housekeeping ─────────────────────────────────────

# Remove all build artifacts and node_modules
clean:
    pnpm -r clean && rm -rf node_modules

# Install dependencies
install:
    pnpm install
