#!/usr/bin/env bash
# setup.sh — Bootstrap script for containerized claude-mem
#
# Creates data directory, generates auth tokens, prompts for AI provider,
# and builds container images via podman-compose.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${CLAUDE_MEM_DATA_DIR:-$HOME/.claude-mem}"
ENV_FILE="$SCRIPT_DIR/.env"

echo "=== claude-mem containerized setup ==="
echo

# 1. Create data directory
if [ ! -d "$DATA_DIR" ]; then
  echo "Creating data directory: $DATA_DIR"
  mkdir -p "$DATA_DIR"
else
  echo "Data directory exists: $DATA_DIR"
fi
echo

# 2. Copy .env.example → .env if not present
if [ ! -f "$ENV_FILE" ]; then
  echo "Creating .env from .env.example..."
  cp "$SCRIPT_DIR/.env.example" "$ENV_FILE"

  # Generate auth tokens
  WORKER_TOKEN=$(openssl rand -hex 32)
  REMOTE_TOKEN=$(openssl rand -hex 32)

  # Platform-compatible sed -i
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "s/^CLAUDE_MEM_WORKER_AUTH_TOKEN=$/CLAUDE_MEM_WORKER_AUTH_TOKEN=$WORKER_TOKEN/" "$ENV_FILE"
    sed -i '' "s/^CLAUDE_MEM_REMOTE_TOKEN=$/CLAUDE_MEM_REMOTE_TOKEN=$REMOTE_TOKEN/" "$ENV_FILE"
    sed -i '' "s/^CLAUDE_MEM_AI_PROVIDER=mistral$/CLAUDE_MEM_AI_PROVIDER=openai/" "$ENV_FILE"
  else
    sed -i "s/^CLAUDE_MEM_WORKER_AUTH_TOKEN=$/CLAUDE_MEM_WORKER_AUTH_TOKEN=$WORKER_TOKEN/" "$ENV_FILE"
    sed -i "s/^CLAUDE_MEM_REMOTE_TOKEN=$/CLAUDE_MEM_REMOTE_TOKEN=$REMOTE_TOKEN/" "$ENV_FILE"
    sed -i "s/^CLAUDE_MEM_AI_PROVIDER=mistral$/CLAUDE_MEM_AI_PROVIDER=openai/" "$ENV_FILE"
  fi

  echo "  Generated CLAUDE_MEM_WORKER_AUTH_TOKEN"
  echo "  Generated CLAUDE_MEM_REMOTE_TOKEN"
  echo "  Set default AI provider to: openai"
else
  echo ".env already exists, skipping token generation."
fi
echo

# 3. Prompt for AI provider and API key
echo "--- AI Provider Configuration ---"
echo
echo "Available providers: openai, anthropic, mistral, gemini, openrouter"
echo "Current setting: $(grep '^CLAUDE_MEM_AI_PROVIDER=' "$ENV_FILE" | cut -d= -f2)"
echo
read -rp "Change AI provider? [press Enter to keep current, or type provider name]: " NEW_PROVIDER

if [ -n "$NEW_PROVIDER" ]; then
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "s/^CLAUDE_MEM_AI_PROVIDER=.*/CLAUDE_MEM_AI_PROVIDER=$NEW_PROVIDER/" "$ENV_FILE"
  else
    sed -i "s/^CLAUDE_MEM_AI_PROVIDER=.*/CLAUDE_MEM_AI_PROVIDER=$NEW_PROVIDER/" "$ENV_FILE"
  fi
  echo "  Updated provider to: $NEW_PROVIDER"
fi

# Determine which API key var to prompt for
PROVIDER=$(grep '^CLAUDE_MEM_AI_PROVIDER=' "$ENV_FILE" | cut -d= -f2)
case "$PROVIDER" in
  openai)      KEY_VAR="CLAUDE_MEM_OPENAI_API_KEY" ;;
  anthropic)   KEY_VAR="CLAUDE_MEM_ANTHROPIC_API_KEY" ;;
  mistral)     KEY_VAR="CLAUDE_MEM_MISTRAL_API_KEY" ;;
  gemini)      KEY_VAR="CLAUDE_MEM_GEMINI_API_KEY" ;;
  openrouter)  KEY_VAR="CLAUDE_MEM_OPENROUTER_API_KEY" ;;
  *)           KEY_VAR="" ;;
esac

if [ -n "$KEY_VAR" ]; then
  CURRENT_KEY=$(grep "^${KEY_VAR}=" "$ENV_FILE" | cut -d= -f2)
  if [ -z "$CURRENT_KEY" ]; then
    read -rp "Enter your $PROVIDER API key (or press Enter to skip): " API_KEY
    if [ -n "$API_KEY" ]; then
      if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s/^${KEY_VAR}=.*/${KEY_VAR}=$API_KEY/" "$ENV_FILE"
      else
        sed -i "s/^${KEY_VAR}=.*/${KEY_VAR}=$API_KEY/" "$ENV_FILE"
      fi
      echo "  API key saved."
    else
      echo "  Skipped. Set $KEY_VAR in .env before starting."
    fi
  else
    echo "  API key already configured for $PROVIDER."
  fi
fi
echo

# 4. Optionally set host port
echo "--- Port Configuration ---"
echo
echo "Default host port: 38888 (avoids conflict with vanilla claude-mem on 37777)"
read -rp "Custom host port? [press Enter for 38888]: " CUSTOM_PORT

if [ -n "$CUSTOM_PORT" ]; then
  # Add or update CLAUDE_MEM_HOST_PORT in .env
  if grep -q '^CLAUDE_MEM_HOST_PORT=' "$ENV_FILE"; then
    if [[ "$OSTYPE" == "darwin"* ]]; then
      sed -i '' "s/^CLAUDE_MEM_HOST_PORT=.*/CLAUDE_MEM_HOST_PORT=$CUSTOM_PORT/" "$ENV_FILE"
    else
      sed -i "s/^CLAUDE_MEM_HOST_PORT=.*/CLAUDE_MEM_HOST_PORT=$CUSTOM_PORT/" "$ENV_FILE"
    fi
  else
    echo "" >> "$ENV_FILE"
    echo "# Host port mapping (container always uses 37777 internally)" >> "$ENV_FILE"
    echo "CLAUDE_MEM_HOST_PORT=$CUSTOM_PORT" >> "$ENV_FILE"
  fi
  echo "  Host port set to: $CUSTOM_PORT"
fi
echo

# 5. Build images
echo "--- Building container images ---"
echo
cd "$SCRIPT_DIR"
podman-compose -f podman-compose.yml build
echo

# 6. Done
HOST_PORT="${CUSTOM_PORT:-38888}"
echo "=== Setup complete! ==="
echo
echo "Next steps:"
echo "  1. Review .env and add your API key if not set"
echo "  2. Start services:  podman-compose -f podman-compose.yml up -d"
echo "  3. Check health:    curl http://localhost:$HOST_PORT/api/health"
echo "  4. Open web UI:     http://localhost:$HOST_PORT"
echo "  5. View logs:       podman-compose -f podman-compose.yml logs -f"
echo
echo "Data directory: $DATA_DIR"
echo "Database file:  $DATA_DIR/claude-mem.db"
echo
echo "See docs/harness-integration.md for connecting Claude Code, OpenCode, or other tools."
