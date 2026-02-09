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

### Option A: Use the built-in plugin (recommended)

The `plugin/` directory contains the full Claude Code plugin with hooks and MCP server.

```bash
# Build the plugin
pnpm build:plugin && pnpm sync-marketplace
```

This installs the plugin to Claude Code's marketplace directory. The plugin's hooks
talk to the backend at the URL configured in `~/.claude-mem/settings.json`.

### Option B: Point an existing MCP server at the container

If you already have vanilla claude-mem installed as an MCP server, reconfigure it
to point at the containerized backend:

In `~/.claude/settings.json` or your project's `.mcp.json`:

```json
{
  "mcpServers": {
    "claude-mem": {
      "command": "node",
      "args": ["/path/to/repos/claude-mem/plugin/dist/mcp-server.cjs"],
      "env": {
        "CLAUDE_MEM_BACKEND_HOST": "127.0.0.1",
        "CLAUDE_MEM_BACKEND_PORT": "38888",
        "CLAUDE_MEM_REMOTE_TOKEN": "<your-token-from-.env>"
      }
    }
  }
}
```

### Transition strategy

During transition, run both side by side:
- Vanilla claude-mem on `:37777` (existing setup)
- Containerized fork on `:38888` (new setup)

When ready to switch, set `CLAUDE_MEM_HOST_PORT=37777` in `.env` and restart.
Stop vanilla claude-mem, and the containerized version takes over its port.

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
