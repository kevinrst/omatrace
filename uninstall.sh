#!/usr/bin/env bash
set -euo pipefail

if systemctl --user is-active --quiet rewindd 2>/dev/null; then
  echo "Stopping rewindd"
  systemctl --user disable --now rewindd
fi
rm -f "$HOME/.config/systemd/user/rewindd.service"
rm -f "$HOME/.local/bin/rewindd"
rm -rf "$HOME/.config/omarchy/plugins/rewind.monitor"
systemctl --user daemon-reload 2>/dev/null || true

if [ "${1:-}" = "--wipe" ]; then
  rm -f "$HOME/.local/share/rewind/history.db"
  echo "History wiped"
fi

echo "Done. Restart the shell to drop the bar icon: omarchy restart shell"
