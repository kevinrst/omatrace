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
```

## IPC

Unix socket `$XDG_RUNTIME_DIR/rewind.sock`, one JSON object per line.
Timestamps are unix millis; CPU is 0-100 float; RAM/net are bytes and bytes/sec.

| method | args | returns |
|---|---|---|
| `latest` | — | newest snapshot (system + top-40 processes) |
| `get` | `index` | snapshot at ring-buffer index, plus `len` |
| `len` | — | snapshot count |
| `proc_history` | `pid` | per-process sparkline (up to 150 pts) |
| `history` | `from_ms`, `to_ms` (default 24h) | per-minute rollups |
| `events` | `from_ms`, `to_ms` (default 24h) | threshold crossings, newest first |
| `kill` | `pid`, `signal` (`term`/`kill`) | graceful TERM by default, KILL only on confirm |

## Status

Scaffold v0.1. Daemon runs, QML plugin loads with mock fallback
when daemon is offline.

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

Daemon socket: `$XDG_RUNTIME_DIR/rewind.sock` (JSON lines, see IPC table above).
DB: `~/.local/share/rewind/history.db` (SQLite, 24h retention, downsampled).

## Floating dashboard

The dashboard is a regular window — keep it out of the tiling layout
with a Hyprland rule (matches the window title):

```lua
o.window({ title = "Rewind" }, { float = true, center = true })
```

The bar icon is a placeholder glyph; swap `BarWidget.qml`'s `text` for an
`iconComponent` when the custom icon lands.
