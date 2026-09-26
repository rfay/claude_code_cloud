#!/usr/bin/env bash
# Install the versioned self-hosted-runner files into a Coder workspace.
set -euo pipefail

SOURCE_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
RUNNER_DIR="$HOME/.claude-runner"
PROJECT_NAME="${1:-d11}"

if [[ ! "$PROJECT_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "Project name must contain only letters, numbers, dots, underscores, or hyphens" >&2
  exit 2
fi
if [ ! -f "$RUNNER_DIR/environment-secret" ]; then
  echo "Missing $RUNNER_DIR/environment-secret; store the environment key first" >&2
  exit 1
fi

for command in claude ddev mkcert tmux; do
  command -v "$command" >/dev/null || { echo "Missing required command: $command" >&2; exit 1; }
done

install -d -m 700 "$RUNNER_DIR"
chmod 600 "$RUNNER_DIR/environment-secret"
install -m 700 "$SOURCE_DIR/run.sh" "$RUNNER_DIR/run.sh"
install -m 700 "$SOURCE_DIR/startup.sh" "$RUNNER_DIR/startup.sh"
install -m 600 "$SOURCE_DIR/gitconfig" "$RUNNER_DIR/gitconfig"
install -m 600 "$SOURCE_DIR/gitignore" "$RUNNER_DIR/gitignore"
printf 'PROJECT_NAME=%q\n' "$PROJECT_NAME" >"$RUNNER_DIR/config"
chmod 600 "$RUNNER_DIR/config"
install -m 700 "$SOURCE_DIR/coder-startup.sh" "$HOME/.coder-startup.sh"

mkcert -install
sudo install -m 644 "$RUNNER_DIR/gitconfig" /etc/gitconfig
"$RUNNER_DIR/startup.sh"

echo "Runner configured for DDEV project '$PROJECT_NAME'."
echo "Check it with: tmux attach -t claude-runner"
