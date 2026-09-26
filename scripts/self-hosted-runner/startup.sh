#!/usr/bin/env bash
# Run on every Coder workspace start: trust mkcert, restore Git config, and
# start the runner. The optional DDEV project starts once it has been created.
set -u

RUNNER_DIR="$HOME/.claude-runner"
CONFIG="$RUNNER_DIR/config"
LOG=/tmp/claude-runner-startup.log

if [ ! -f "$RUNNER_DIR/environment-secret" ] || [ ! -r "$CONFIG" ]; then
  echo "$(date): runner is not configured; run scripts/self-hosted-runner/setup.sh" >>"$LOG"
  exit 0
fi

# shellcheck source=/dev/null
. "$CONFIG"

marker=/tmp/.claude-runner-startup-done
[ -e "$marker" ] && exit 0
touch "$marker"
exec >>"$LOG" 2>&1
echo "=== startup $(date)"

mkcert -install
sudo install -m 644 "$RUNNER_DIR/gitconfig" /etc/gitconfig

if ! pgrep -f '^claude self-hosted-runner' >/dev/null; then
  tmux new-session -d -s claude-runner "$RUNNER_DIR/run.sh"
fi

# The first workspace start precedes creation of the throwaway DDEV project.
# Retrying is useful after DDEV has removed its router network; a missing
# project is otherwise harmless because the runner has already started.
if ! ddev start "$PROJECT_NAME" -y; then
  sleep 5
  ddev start "$PROJECT_NAME" -y || \
    echo "DDEV project '$PROJECT_NAME' is not available yet; it will start after project setup"
fi
