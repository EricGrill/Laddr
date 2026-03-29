#!/usr/bin/env bash
# Launch OpenAI Codex as a Laddr pull-based agent worker.
# Codex reads the bootstrap prompt and enters the claim/work/submit loop.
#
# Prerequisites:
#   - codex CLI installed and authenticated
#   - Network access to https://laddr.chainbytes.io
#
# Usage:
#   ./run-codex-agent.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP="${SCRIPT_DIR}/codex-bootstrap.md"

if ! command -v codex &>/dev/null; then
    echo "Error: codex CLI not found. Install it first." >&2
    exit 1
fi

if [[ ! -f "$BOOTSTRAP" ]]; then
    echo "Error: Bootstrap prompt not found at $BOOTSTRAP" >&2
    exit 1
fi

echo "Starting Codex agent worker (codex-agent-01)..."
codex --prompt-file "$BOOTSTRAP"
