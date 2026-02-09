# Deployment Guide

Deploy containerized claude-mem and connect it to Claude Code, OpenCode, or any MCP-compatible harness.

## Prerequisites

- **Podman** (or Docker) with compose support
- **Node.js 24+** via [fnm](https://github.com/Schniz/fnm) (for building plugin and images)
- **just** task runner (`brew install just`)
- **direnv** (recommended, for managing secrets per-directory)
- An API key for your AI provider (OpenAI, Anthropic, Mistral, etc.)

## Quick Start

```bash
git clone <repo-url> && cd claude-mem

# 1. Bootstrap: generates .env, builds container images
just setup

# 2. Set your AI provider key in .env
#    (setup.sh generates auth tokens automatically)
vi .env

# 3. Start the stack
just up

# 4. Verify
just health
# → {"status":"ok","coreReady":true,"workers":{"connected":1}}
```

The web UI is available at `http://localhost:38888`.

## Stack Architecture

```
┌──────────────────┐
│  Claude Code     │──stdio──▶ MCP Server ──HTTP──┐
│  OpenCode        │                               │
│  Any Harness     │──HTTP────────────────────────▶│
└──────────────────┘                               │
                                          ┌────────▼──────────┐
                                          │  Backend :38888    │
                                          │  (API, DB, UI)     │
                                          └──┬──────────┬──────┘
                                             │ WS       │ HTTP
                                    ┌────────▼──┐  ┌────▼──────┐
                                    │  Worker    │  │  Qdrant   │
                                    │  (AI proc) │  │  (vectors)│
                                    └───────────┘  └───────────┘
```

| Service | Purpose | Port |
|---------|---------|------|
| **backend** | REST API, WebSocket hub, SQLite DB, React UI | `38888` (host) → `37777` (container) |
| **worker** | AI observation extraction, summarization, embeddings | Internal only |
| **qdrant** | Vector database for semantic search | Internal only |

## Connecting Claude Code

Claude Code's plugin system loads hooks (for automatic observation capture) and an MCP server (for search/management tools). The plugin hooks work from the marketplace directory, but **the MCP server must be registered separately via the CLI**.

### Step 1: Build and sync the plugin

```bash
just build-plugin
just sync    # → syncs to ~/.claude/plugins/marketplaces/customable/
```

### Step 2: Register the MCP server

Plugin `.mcp.json` files are not loaded by Claude Code CLI. Add the MCP server directly:

```bash
claude mcp add claude-mem \
  --transport stdio \
  --scope user \
  --env CLAUDE_MEM_REMOTE_MODE=true \
  --env CLAUDE_MEM_REMOTE_URL=http://127.0.0.1:38888 \
  --env "CLAUDE_MEM_REMOTE_TOKEN=$(just show-token | head -1 | cut -d= -f2)" \
  -- node ~/.claude/plugins/marketplaces/customable/scripts/mcp-server.cjs
```

Verify it connected:

```bash
claude mcp list
# → claude-mem: node ... /mcp-server.cjs - ✓ Connected
```

### Step 3: Set the auth token in your environment

The plugin hooks also need the token. Use **direnv** (recommended) or your shell profile:

```bash
# In your project's .envrc (or ~/.zshenv for global access):
export CLAUDE_MEM_REMOTE_TOKEN=<your-token-from-.env>
```

If using direnv, allow it:

```bash
direnv allow .
```

### Step 4: Enable the plugin

If migrating from the `thedotmack` marketplace plugin, update `~/.claude/settings.json`:

```json
{
  "enabledPlugins": {
    "claude-mem@customable": true
  }
}
```

### Step 5: Verify

Restart Claude Code, then:

```bash
# MCP tools should be available
claude mcp list | grep claude-mem

# Hooks should fire on every tool use (check backend logs)
just logs
```

## Connecting OpenCode

In `opencode.jsonc`:

```jsonc
{
  "mcp": {
    "claude-mem": {
      "type": "local",
      "command": ["node", "<repo-path>/plugin/scripts/mcp-server.cjs"],
      "environment": {
        "CLAUDE_MEM_REMOTE_MODE": "true",
        "CLAUDE_MEM_REMOTE_URL": "http://127.0.0.1:38888",
        "CLAUDE_MEM_REMOTE_TOKEN": "{env:CLAUDE_MEM_REMOTE_TOKEN}"
      }
    }
  }
}
```

Set `CLAUDE_MEM_REMOTE_TOKEN` in the `.envrc` next to `opencode.jsonc`.

## Migrating from Vanilla claude-mem

If you have an existing `~/.claude-mem/claude-mem.db` from the thedotmack plugin:

### Option A: Let MikroORM migrate the schema (if compatible)

```bash
# Stop containers
just down

# Point CLAUDE_MEM_DATA_DIR at your existing data
echo "CLAUDE_MEM_DATA_DIR=$HOME/.claude-mem" >> .env

# Start — backend runs migrations automatically
just up
```

> **Caveat**: The plugin DB schema (raw SQL) and the containerized backend schema (MikroORM) differ significantly. If you see migration errors like `table already exists`, use Option B instead.

### Option B: Bulk import via SQLite (recommended)

Start fresh, then import observations from the old DB:

```bash
# 1. Start with a fresh database
just up
just health  # wait for coreReady: true

# 2. Stop services to get exclusive DB access
just down

# 3. Import observations
sqlite3 <new-db-path> <<'SQL'
ATTACH DATABASE '<old-db-path>' AS old;

INSERT INTO main.observations (
    memory_session_id, project, text, type, title, subtitle, narrative,
    concepts, facts, files_read, files_modified, prompt_number,
    created_at, created_at_epoch, discovery_tokens, memory_tier
)
SELECT
    COALESCE(o.memory_session_id, 'migrated-plugin'),
    COALESCE(o.project, 'default'),
    COALESCE(o.narrative, o.title, 'No content'),
    COALESCE(o.type, 'discovery'),
    o.title, o.subtitle, o.narrative, o.concepts, o.facts,
    o.files_read, o.files_modified, o.prompt_number,
    COALESCE(o.created_at, datetime('now')),
    COALESCE(o.created_at_epoch, CAST(strftime('%s','now') AS INTEGER) * 1000),
    COALESCE(o.discovery_tokens, 0),
    'working'
FROM old.observations o ORDER BY o.id ASC;

DETACH DATABASE old;
SQL

echo "Imported $(sqlite3 <new-db-path> 'SELECT count(*) FROM observations') observations"

# 4. Restart
just up
```

The FTS triggers on the `observations` table fire automatically on INSERT, so full-text search works immediately.

### Option C: Rebuild vector index

After importing, queue a Qdrant full-sync to build the vector index for semantic search:

```bash
# With containers running:
TOKEN=$(just show-token | head -1 | cut -d= -f2)
curl -X POST "http://localhost:38888/api/data/observations" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"type":"note","title":"trigger","text":"trigger embedding pipeline"}'
```

Or insert a `qdrant-sync` task directly:

```bash
just down
sqlite3 <db-path> "INSERT INTO tasks (id, type, status, required_capability, priority, payload, retry_count, max_retries, created_at)
VALUES (lower(hex(randomblob(16))), 'qdrant-sync', 'pending', 'qdrant:sync', 50,
'{\"mode\":\"full\",\"project\":\"default\"}', 0, 3, $(date +%s)000);"
just up
# Worker will pick up the task and sync all observations to Qdrant
```

## Removing the Old Plugin

If you previously had `thedotmack/claude-mem` installed:

```bash
# 1. Remove the marketplace subscription (prevents auto-reinstall)
#    Edit ~/.claude/plugins/known_marketplaces.json
#    Delete the "thedotmack" entry

# 2. Remove the marketplace and cache directories
rm -rf ~/.claude/plugins/marketplaces/thedotmack
rm -rf ~/.claude/plugins/cache/thedotmack

# 3. Remove from installed plugins
#    Edit ~/.claude/plugins/installed_plugins.json
#    Delete the "claude-mem@thedotmack" entry

# 4. Update enabledPlugins in ~/.claude/settings.json
#    Change "claude-mem@thedotmack": true → "claude-mem@customable": true
```

If the old plugin keeps reappearing after restart, check `known_marketplaces.json` — that's the registry Claude Code uses to auto-update from GitHub.

## LAN Access

Expose the web UI on your local network via Caddy reverse proxy:

```bash
just proxy       # starts Caddy on 0.0.0.0:38889
just proxy-stop  # stops Caddy
```

The Caddyfile injects the auth header so LAN clients don't need the token. Edit `Caddyfile` to set your token.

> **Security note**: Anyone on your LAN can access the UI and API through the proxy without authentication. Only use this on trusted networks.

## Operational Reference

### Daily commands

| Command | What it does |
|---------|-------------|
| `just up` | Start the stack |
| `just down` | Stop the stack |
| `just logs` | Tail all container logs |
| `just health` | Check backend health + worker status |
| `just ps` | Show container status |
| `just restart` | Stop + start |

### Data management

| Command | What it does |
|---------|-------------|
| `just data-info` | Show DB location and size |
| `just data-backup` | Create timestamped backup |
| `just data-backups` | List existing backups |
| `just data-restore <file>` | Restore from backup |
| `just data-clone` | Clone data for parallel testing |

### Development

| Command | What it does |
|---------|-------------|
| `just build` | Build all packages |
| `just build-plugin` | Build the Claude Code plugin |
| `just sync` | Sync plugin to marketplace |
| `just dev` | Build + sync in one step |
| `just test` | Run tests |
| `just build-images` | Rebuild container images |

## Troubleshooting

### Worker registers but doesn't process embedding tasks

The worker auto-detects capabilities but **does not auto-detect embedding capabilities**. If you see `No subscribers for channel task:queued` in the backend logs, the worker is missing `embedding:openai` in its capability set.

**Fix**: The `WORKER_CAPABILITIES` env var in `podman-compose.yml` explicitly lists all capabilities including `embedding:openai`. If you've overridden worker env, make sure it includes the embedding capability.

### Embedding tasks complete instantly with "No texts to embed"

The `embedding` task handler expects `payload.texts` (an array of strings), but the backend queues tasks with `payload.observationIds` (an array of IDs). This is an upstream bug — the embedding handler doesn't resolve observation IDs to text.

**Workaround**: Semantic search works through the `qdrant-sync` task path instead, which correctly resolves observation IDs. Use the Qdrant full-sync approach described in the migration section.

### Backend says "initialized: false"

MikroORM migrations failed. Check backend logs for the specific error:

```bash
just logs 2>&1 | grep -i "migration\|error"
```

Common causes:
- **`table already exists`**: Plugin DB schema conflicts with MikroORM migrations. Use a fresh DB and bulk import.
- **`no such table: hubs`**: Migration records exist for tables that don't. Reset the migration tracking table.

### Plugin hooks fire but MCP tools aren't available

Plugin `.mcp.json` files are not read by Claude Code CLI. Register the MCP server via:

```bash
claude mcp add claude-mem --transport stdio --scope user \
  --env CLAUDE_MEM_REMOTE_MODE=true \
  --env CLAUDE_MEM_REMOTE_URL=http://127.0.0.1:38888 \
  --env "CLAUDE_MEM_REMOTE_TOKEN=$CLAUDE_MEM_REMOTE_TOKEN" \
  -- node ~/.claude/plugins/marketplaces/customable/scripts/mcp-server.cjs
```

### Old thedotmack plugin keeps reinstalling

Claude Code auto-discovers plugins from `~/.claude/plugins/known_marketplaces.json`. Remove the `thedotmack` entry from that file, then delete its directories.

### Podman volume mount uses named volume instead of bind mount

If `CLAUDE_MEM_DATA_DIR` from `.env` isn't substituted in compose, the justfile's `set dotenv-load` handles it for `just` commands. If running `podman-compose` directly, export the variable first:

```bash
export CLAUDE_MEM_DATA_DIR=$HOME/.claude-mem
podman-compose -f podman-compose.yml up -d
```

### WebSocket disconnects every ~3 minutes

The worker reconnects automatically (up to 10 attempts). This is typically caused by the Podman VM's TCP keepalive settings. It's harmless — the worker re-registers and resumes task processing after each reconnect.
