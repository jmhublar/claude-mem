# Harness Integration Guide

Connect any AI coding harness to a containerized claude-mem backend.

## Architecture

```
┌─────────────────┐     stdio      ┌──────────────────┐     HTTP/WS     ┌───────────────────┐
│  Claude Code    │ ──────────────▶│  MCP Server      │ ──────────────▶│  Backend          │
│  OpenCode       │                │  (mcp-server.cjs)│                │  :37777 (internal)│
│  Any Harness    │                └──────────────────┘                │  :38888 (host)    │
└─────────────────┘                                                    └────────┬──────────┘
                                                                                │ WebSocket
                                                                       ┌────────▼──────────┐
                                                                       │  Worker           │
                                                                       │  (AI processing)  │
                                                                       └───────────────────┘
```

- **Backend** serves the REST API, WebSocket hub, database, and web UI on port 37777 inside the container
- **Worker** connects to the backend via internal WebSocket and processes AI extraction tasks
- **MCP Server** is a stdio bridge that harnesses talk to; it forwards requests to the backend HTTP API
- **Host port** is configurable via `CLAUDE_MEM_HOST_PORT` (default: `38888`)

## 1. Claude Code

Claude Code connects via the MCP server script bundled in the plugin package.

### Step 1: Build and sync the plugin

The `plugin/` directory contains the full Claude Code plugin with hooks and MCP server.

```bash
just build-plugin && just sync
```

This syncs the plugin to `~/.claude/plugins/marketplaces/customable/`. The hooks
will fire automatically on session start, tool use, and session end.

### Step 2: Register the MCP server via CLI

> **Important**: Claude Code CLI does **not** read `.mcp.json` files from plugin
> directories. The plugin's hooks work, but the MCP server (which provides search
> and management tools) must be registered separately.

```bash
claude mcp add claude-mem \
  --transport stdio \
  --scope user \
  --env CLAUDE_MEM_REMOTE_MODE=true \
  --env CLAUDE_MEM_REMOTE_URL=http://127.0.0.1:38888 \
  --env "CLAUDE_MEM_REMOTE_TOKEN=$CLAUDE_MEM_REMOTE_TOKEN" \
  -- node ~/.claude/plugins/marketplaces/customable/scripts/mcp-server.cjs
```

Verify: `claude mcp list | grep claude-mem` should show `✓ Connected`.

### Step 3: Set the auth token

The hooks need `CLAUDE_MEM_REMOTE_TOKEN` in the environment. Use direnv:

```bash
# In your project .envrc:
export CLAUDE_MEM_REMOTE_TOKEN=<token-from-.env>
direnv allow .
```

### Step 4: Enable the plugin

In `~/.claude/settings.json`, ensure the plugin is enabled:

```json
{
  "enabledPlugins": {
    "claude-mem@customable": true
  }
}
```

### Migrating from thedotmack plugin

If you previously had the `thedotmack/claude-mem` plugin installed, you need to
fully remove it — otherwise both plugins will conflict on the `mcp-search` server
name, and the old one will auto-reinstall on every Claude Code restart.

See [Deployment Guide: Removing the Old Plugin](deployment.md#removing-the-old-plugin)
for the full procedure.

## 2. OpenCode

OpenCode connects via either the dedicated plugin or the MCP server.

### Option A: OpenCode plugin (recommended)

Install the `@claude-mem/opencode-plugin` package, which uses OpenCode's native
plugin system with 16 hook points for richer integration than MCP alone.

In `~/.config/opencode/opencode.jsonc`:

```jsonc
{
  "plugin": ["@claude-mem/opencode-plugin@latest"]
}
```

Set environment variables:
```bash
export CLAUDE_MEM_URL=http://localhost:38888
export CLAUDE_MEM_REMOTE_TOKEN=<your-token-from-.env>
```

If you use direnv for OpenCode, put these exports in your workspace `.envrc` and
run `direnv allow` before starting OpenCode.

The plugin automatically captures session lifecycle, tool executions, compaction events,
and injects memory context into the system prompt.

### Option B: MCP server

Add claude-mem as an MCP server in OpenCode's config:

```jsonc
{
  "mcp": {
    "claude-mem": {
      "type": "local",
      "command": ["node", "/path/to/repos/claude-mem/plugin/dist/mcp-server.cjs"],
      "environment": {
        "CLAUDE_MEM_BACKEND_HOST": "127.0.0.1",
        "CLAUDE_MEM_BACKEND_PORT": "38888",
        "CLAUDE_MEM_REMOTE_TOKEN": "{env:CLAUDE_MEM_REMOTE_TOKEN}"
      }
    }
  }
}
```

This gives OpenCode agents access to claude-mem's search and management tools, but
does not capture session lifecycle events (use the plugin for that).

#### Important notes

- The Claude Code plugin hooks in `~/.claude/settings.json` do not run in OpenCode.
- MCP-only wiring will not create sessions in the web UI. If you want OpenCode
  sessions to appear, install `@claude-mem/opencode-plugin` and set
  `CLAUDE_MEM_URL` and `CLAUDE_MEM_REMOTE_TOKEN` in the OpenCode process env.

## 3. Any Harness (Generic)

### Option A: MCP server via stdio

If your harness supports the Model Context Protocol, spawn the MCP server:

```bash
node /path/to/repos/claude-mem/plugin/dist/mcp-server.cjs
```

Environment variables:
- `CLAUDE_MEM_BACKEND_HOST` — backend host (default: `127.0.0.1`)
- `CLAUDE_MEM_BACKEND_PORT` — backend port (default: `37777`, set to your host port)
- `CLAUDE_MEM_REMOTE_TOKEN` — auth token

The MCP server exposes tools for searching memory, managing observations, and
retrieving context.

### Option B: REST API directly

For harnesses that don't support MCP, call the backend HTTP API directly.

**Key endpoints:**

| Method | Path | Purpose |
|--------|------|---------|
| `GET` | `/api/health` | Health check (no auth required) |
| `GET` | `/api/hooks/context?project=<id>` | Get session context for a project |
| `POST` | `/api/hooks/session-init` | Initialize a session |
| `POST` | `/api/hooks/observation` | Record a tool observation |
| `POST` | `/api/hooks/user-prompt-submit` | Record a user prompt |
| `POST` | `/api/hooks/session/end` | End a session |
| `POST` | `/api/hooks/pre-compact` | Pre-compaction hook |
| `POST` | `/api/hooks/user-task/create` | Create a tracked task |
| `POST` | `/api/hooks/user-task/update` | Update a tracked task |
| `POST` | `/api/hooks/plan-mode/enter` | Enter plan mode |
| `POST` | `/api/hooks/plan-mode/exit` | Exit plan mode |
| `GET` | `/api/search?query=<text>` | Search memory |

**Authentication:** Include `Authorization: Bearer <CLAUDE_MEM_REMOTE_TOKEN>` header.

**Observation payload example:**
```json
{
  "sessionId": "session-uuid",
  "project": "/path/to/project",
  "toolName": "Read",
  "toolInput": "{\"file_path\":\"/src/index.ts\"}",
  "toolOutput": "file contents...",
  "gitBranch": "main",
  "cwd": "/path/to/project"
}
```

## 4. Data Migration

### Import existing database

If you have an existing `~/.claude-mem/claude-mem.db` from vanilla claude-mem,
you can use it directly:

```bash
# Stop any running containers
podman-compose -f podman-compose.yml down

# Copy your existing database (if not already in ~/.claude-mem/)
cp /path/to/existing/claude-mem.db ~/.claude-mem/claude-mem.db

# Start containers — backend will use the existing DB
podman-compose -f podman-compose.yml up -d
```

The backend runs database migrations automatically on startup, so an older
schema will be upgraded to the current version.

### Run migrations manually

If you need to run migrations explicitly:

```bash
podman exec claude-mem-backend node packages/backend/dist/cli.js migrate
```

## 5. Verification Checklist

1. `curl http://localhost:38888/api/health` returns `{"status":"ok","coreReady":true}`
2. Web UI loads at `http://localhost:38888`
3. MCP server connects: check harness logs for successful tool registration
4. Create a test observation via API and verify it appears in web UI
5. Search works: `curl "http://localhost:38888/api/search?query=test" -H "Authorization: Bearer <token>"`
