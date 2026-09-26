#!/usr/bin/env bash
# Keep one Claude Code self-hosted runner available for this workspace.
set -u

while true; do
  claude self-hosted-runner \
    --environment-secret-file "$HOME/.claude-runner/environment-secret" \
    --base-dir "$HOME/workspace" \
    --capacity 1 \
    --use-anthropic-git-proxy \
    --release-idle-session-min 30 \
    --kill-session-after-min 480 \
    --health-port 0
  echo "runner exited ($?); restarting in 5s"
  sleep 5
done
