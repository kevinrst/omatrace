#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

echo "Building rewindd (release)…"
cargo build --release -p rewindd

echo "Installing binary to ~/.local/bin/rewindd"
install -Dm755 target/release/rewindd "$HOME/.local/bin/rewindd"

echo "Installing systemd user service"
install -Dm644 systemd/user/rewindd.service "$HOME/.config/systemd/user/rewindd.service"
systemctl --user daemon-reload
systemctl --user enable --now rewindd

echo "Installing shell plugin"
mkdir -p "$HOME/.config/omarchy/plugins/rewind.monitor"
cp plugins/rewind.monitor/* "$HOME/.config/omarchy/plugins/rewind.monitor/"
omarchy plugin validate "$HOME/.config/omarchy/plugins/rewind.monitor"
omarchy-shell shell rescanPlugins

echo ""
echo "Done. Daemon: $(systemctl --user is-active rewindd)."
echo "Next:"
echo "  1. omarchy plugin enable rewind.monitor --section right"
echo "  2. omarchy restart shell"
echo "  3. Optional floating dashboard rule in ~/.config/hypr/hyprland.lua:"
echo '       o.window({ title = "Rewind" }, { float = true, center = true })'
