#!/bin/bash
# Builds the Graphify code graph at the start of a Claude Code cloud session.
# Code-only AST extraction: no LLM calls, no token cost.
set -uo pipefail

# Only in Claude Code on the web (cloud sessions).
[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0

GRAPHIFY_VERSION="0.9.113"
cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}" || exit 0
export PATH="$HOME/.local/bin:$PATH"

log() { echo "[graphify session-start] $*" >&2; }

if ! command -v graphify >/dev/null 2>&1; then
  log "installing graphifyy==$GRAPHIFY_VERSION"
  if command -v uv >/dev/null 2>&1; then
    uv tool install --quiet "graphifyy==$GRAPHIFY_VERSION" >&2 || true
  else
    python3 -m pip install --quiet --user "graphifyy==$GRAPHIFY_VERSION" >&2 \
      || python3 -m pip install --quiet --user --break-system-packages "graphifyy==$GRAPHIFY_VERSION" >&2 \
      || true
  fi
fi

if ! command -v graphify >/dev/null 2>&1; then
  log "graphify not available, skipping graph build"
  exit 0
fi

# Rebuild only when HEAD changed since the last build.
HEAD_SHA="$(git rev-parse HEAD 2>/dev/null || echo none)"
STAMP="graphify-out/.built_head"
if [ -f graphify-out/graph.json ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$HEAD_SHA" ]; then
  log "graph is up to date for $HEAD_SHA"
  exit 0
fi

log "building code graph for $HEAD_SHA"
if graphify extract . --code-only --no-label >&2 \
   && graphify cluster-only . --no-label --no-viz >&2; then
  echo "$HEAD_SHA" > "$STAMP"
  log "done"
else
  log "graph build failed, continuing without it"
fi
exit 0
