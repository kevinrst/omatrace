# Rewind — System Monitoring & Diagnostics for Omarchy

See what's happening. Understand why.

Native Omarchy app: Rust engine (`rewindd` daemon) + Quickshell plugin
(bar widget + dashboard window). Timeline-first: every sample is a
snapshot you can scrub back through, with per-process attribution.

## Layout

```
rewind/
  Cargo.toml                  # workspace
  crates/
    rewind-core/               # portable engine (ported from Kova, Linux-fixed)
    rewindd/                   # daemon: sampling, ring buffers, SQLite 24h, Unix-socket JSON
  plugins/
    rewind.monitor/            # Omarchy shell plugin (bar-widget + panel)
  docs/
    ipc.md                    # socket protocol (timestamps + units, versioned)
```

## Status

Scaffold v0.1. Daemon compiles, QML plugin loads with mock fallback
when daemon is offline. See `docs/ipc.md` for the contract.

## Quick start

```bash
cd rewind
cargo build -p rewindd
./target/debug/rewindd --socket $XDG_RUNTIME_DIR/rewind.sock --db ~/.local/share/rewind/history.db

# link plugin for testing
omarchy plugin validate ./plugins/rewind.monitor
mkdir -p ~/.config/omarchy/plugins/rewind.monitor
cp -r plugins/rewind.monitor/* ~/.config/omarchy/plugins/rewind.monitor/
omarchy plugin enable rewind.monitor
```

Daemon socket: `$XDG_RUNTIME_DIR/rewind.sock` (JSON lines, see `docs/ipc.md`).
DB: `~/.local/share/rewind/history.db` (SQLite, 24h retention, downsampled).
