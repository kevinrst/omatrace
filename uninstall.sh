#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ID="kevin.omatrace"
PLUGIN_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"

if systemctl --user is-active --quiet omatraced 2>/dev/null; then
  echo "Stopping omatraced"
  systemctl --user disable --now omatraced
fi
rm -f "$HOME/.config/systemd/user/omatraced.service"
rm -f "$HOME/.local/bin/omatraced"
systemctl --user daemon-reload 2>/dev/null || true

echo "Removing the shell plugin"
omarchy plugin remove "$PLUGIN_ID" --yes >/dev/null 2>&1 || rm -rf "$PLUGIN_DIR"

echo "Done. Restart the shell to drop the bar icon: omarchy restart shell"
