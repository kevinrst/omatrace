#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
REPO="$(pwd -P)"

PLUGIN_ID="kevin.omatrace"
PLUGIN_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"

echo "Building omatraced (release)…"
cargo build --release --manifest-path daemon/Cargo.toml -p omatraced

echo "Installing daemon to ~/.local/bin/omatraced"
install -Dm755 daemon/target/release/omatraced "$HOME/.local/bin/omatraced"

echo "Installing systemd user service"
install -Dm644 daemon/systemd/user/omatraced.service "$HOME/.config/systemd/user/omatraced.service"
systemctl --user daemon-reload
systemctl --user enable --now omatraced

if [[ $REPO == "$PLUGIN_DIR" ]]; then
  echo "Shell plugin already lives in $PLUGIN_DIR"
elif [[ -d $PLUGIN_DIR/.git ]]; then
  echo "Shell plugin at $PLUGIN_DIR is a git checkout; update it with: omarchy plugin update $PLUGIN_ID"
else
  echo "Installing shell plugin into $PLUGIN_DIR"
  mkdir -p "$PLUGIN_DIR"
  cp manifest.json ./*.qml OmatraceClient.js "$PLUGIN_DIR/"
fi

omarchy plugin validate "$PLUGIN_DIR"
omarchy-shell shell rescanPlugins

echo ""
echo "Done. Daemon: $(systemctl --user is-active omatraced)."
echo "Next:"
echo "  1. omarchy plugin enable $PLUGIN_ID --section right   (only if not enabled yet)"
echo "  2. omarchy restart shell"
echo "  3. Optional floating dashboard rule in ~/.config/hypr/hyprland.lua:"
echo '       o.window({ title = "Omatrace" }, { float = true, center = true })'
