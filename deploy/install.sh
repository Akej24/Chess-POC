#!/usr/bin/env bash
# Bootstrap the Stockfish FEN viewer on a fresh Debian/Ubuntu VM. Run as root.
#
#   sudo REPO_URL=https://github.com/YOU/REPO.git bash install.sh
#   sudo REPO_URL=... BRANCH=main bash install.sh     # BRANCH is optional
#
# Safe to run again: it only fills in what is missing.
set -euo pipefail

: "${REPO_URL:?Set REPO_URL to your GitHub repository URL}"
BRANCH="${BRANCH:-main}"
APP_DIR="/opt/chess-stockfish"
APP_USER="stockfish"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this script as root (sudo)." >&2
  exit 1
fi

echo "==> Installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y python3 python3-venv git stockfish

echo "==> Creating service user"
if ! id -u "$APP_USER" >/dev/null 2>&1; then
  useradd --system --create-home --shell /usr/sbin/nologin "$APP_USER"
fi

echo "==> Fetching code from $REPO_URL ($BRANCH)"
mkdir -p "$APP_DIR"
chown "$APP_USER": "$APP_DIR"
if [ ! -d "$APP_DIR/.git" ]; then
  runuser -u "$APP_USER" -- git clone --branch "$BRANCH" "$REPO_URL" "$APP_DIR"
fi

echo "==> Setting up Python environment"
if [ ! -x "$APP_DIR/.venv/bin/python" ]; then
  runuser -u "$APP_USER" -- python3 -m venv "$APP_DIR/.venv"
fi
runuser -u "$APP_USER" -- "$APP_DIR/.venv/bin/pip" install --quiet -r "$APP_DIR/requirements.txt"

echo "==> Installing systemd units"
for unit in stockfish-web.service stockfish-web-update.service stockfish-web-update.timer; do
  install -m 644 "$APP_DIR/deploy/$unit" "/etc/systemd/system/$unit"
done
systemctl daemon-reload
systemctl enable --now stockfish-web.service
systemctl enable --now stockfish-web-update.timer

echo
echo "Done. The viewer is running on port 8000."
echo "  Logs   : journalctl -u stockfish-web -f"
echo "  Updates: checked from GitHub every 5 minutes (journalctl -u stockfish-web-update)"
