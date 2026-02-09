#!/usr/bin/env bash
# Migrate observations from plugin DB to containerized backend API
set -euo pipefail

export PLUGIN_DB="${1:-/Users/Joshua.Hublar/.claude-mem-test/claude-mem.db.plugin-clone}"
export BACKEND_URL="${2:-http://127.0.0.1:38888}"
export TOKEN="${3:-ca079a75033fbace5288f0b72c5d102f72acca7f0fdf2ba22fcbfb00984b3a09}"
# Skip the first N observations (for resuming after partial migration)
export SKIP="${4:-0}"

if [ ! -f "$PLUGIN_DB" ]; then
  echo "Error: Plugin DB not found at $PLUGIN_DB"
  exit 1
fi

TOTAL=$(sqlite3 "$PLUGIN_DB" "SELECT count(*) FROM observations;")
echo "Migrating $TOTAL observations from plugin DB (skipping first $SKIP)"
echo "Target: $BACKEND_URL"
echo ""

python3 << 'PYEOF'
import sqlite3, json, urllib.request, urllib.error, sys, os, time

db_path = os.environ.get("PLUGIN_DB", "")
backend = os.environ.get("BACKEND_URL", "http://127.0.0.1:38888")
token = os.environ.get("TOKEN", "")
skip = int(os.environ.get("SKIP", "0"))

conn = sqlite3.connect(db_path)
conn.row_factory = sqlite3.Row
cur = conn.cursor()

rows = cur.execute("""
    SELECT id, type, title, subtitle, narrative, facts, concepts,
           files_read, files_modified, project, prompt_number,
           created_at, created_at_epoch
    FROM observations ORDER BY id ASC
""").fetchall()

total = len(rows)
success = 0
failed = 0
skipped = 0

for row in rows:
    count = success + failed + skipped
    if count < skip:
        skipped += 1
        continue

    text = row["narrative"] or row["title"] or "No content"

    payload = {
        "type": row["type"] or "discovery",
        "title": row["title"],
        "text": text,
        "project": row["project"] or "claudecode_workspace",
    }

    if row["subtitle"]:
        payload["subtitle"] = row["subtitle"]
    if row["narrative"]:
        payload["narrative"] = row["narrative"]

    for field in ["facts", "concepts", "files_read", "files_modified"]:
        val = row[field]
        if val:
            try:
                parsed = json.loads(val)
                if parsed:
                    payload[field] = parsed
            except (json.JSONDecodeError, TypeError):
                pass

    data = json.dumps(payload).encode("utf-8")

    for attempt in range(3):
        req = urllib.request.Request(
            f"{backend}/api/data/observations",
            data=data,
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                success += 1
                break
        except urllib.error.HTTPError as e:
            if e.code == 429:
                time.sleep(2)
                continue
            failed += 1
            body = e.read().decode("utf-8", errors="replace")[:100]
            print(f"  FAIL [{e.code}] id={row['id']} title={row['title'][:50] if row['title'] else '?'}: {body}")
            break
        except (ConnectionError, OSError) as e:
            if attempt < 2:
                time.sleep(3)
                continue
            failed += 1
            print(f"  CONN_ERR id={row['id']}: {e}")
            break

    processed = success + failed
    if processed % 100 == 0 and processed > 0:
        print(f"  Progress: {processed}/{total - skip} (ok={success}, fail={failed})", flush=True)

print(f"\nDone: {success} imported, {failed} failed out of {total} (skipped {skip})")
PYEOF
