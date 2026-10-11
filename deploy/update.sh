#!/usr/bin/env bash
# Pull new commits from GitHub and redeploy, but only when something changed.
# Run by stockfish-web-update.timer as root. It follows whichever branch is
# checked out in /opt/chess-stockfish.
#
# Local edits on the VM are discarded (git reset --hard): GitHub is the source
# of truth.
set -euo pipefail

APP_DIR="/opt/chess-stockfish"
APP_USER="stockfish"

run() { runuser -u "$APP_USER" -- "$@"; }

main() {
  cd "$APP_DIR"
  local branch local_rev remote_rev
  branch="$(run git rev-parse --abbrev-ref HEAD)"

  run git fetch --quiet origin "$branch"
  local_rev="$(run git rev-parse HEAD)"
  remote_rev="$(run git rev-parse "origin/$branch")"

  if [ "$local_rev" = "$remote_rev" ]; then
    exit 0
  fi

  echo "Updating $branch: ${local_rev:0:7} -> ${remote_rev:0:7}"
  run git reset --hard "origin/$branch"
  run "$APP_DIR/.venv/bin/pip" install --quiet -r requirements.txt

  # Pick up changes to the service files themselves.
  for unit in stockfish-web.service stockfish-web-update.service stockfish-web-update.timer; do
    install -m 644 "deploy/$unit" "/etc/systemd/system/$unit"
  done
  systemctl daemon-reload
  systemctl restart stockfish-web.service
  echo "Deployed ${remote_rev:0:7}"
}

# Everything runs inside main() and we exit right after, so bash never reads a
# half-replaced copy of this file when git rewrites it mid-run.
main "$@"
exit 0
