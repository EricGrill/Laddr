#!/usr/bin/env bash
# Launch OpenAI Codex as a Laddr pull-based agent worker.
#
# Prerequisites:
#   - codex CLI installed and authenticated
#   - Network access to https://laddr.chainbytes.io
#
# Usage:
#   ./run-codex-agent.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER="${SCRIPT_DIR}/codex_pull_worker.py"

if ! command -v codex &>/dev/null; then
    echo "Error: codex CLI not found. Install it first." >&2
    exit 1
fi

if [[ ! -f "$WORKER" ]]; then
    echo "Error: Worker script not found at $WORKER" >&2
    exit 1
fi

echo "Starting Codex agent worker (codex-agent-01)..."
exec python3 "$WORKER"
