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
    rewind-core/               # portable engine: sampling model, aggregation, metrics
    rewindd/                   # daemon: sampling, in-memory ring, Unix-socket JSON
  plugins/
    rewind.monitor/            # Omarchy shell plugin (bar-widget + panel)
```

## IPC

Unix socket `$XDG_RUNTIME_DIR/rewind.sock`, one JSON object per line.
Timestamps are unix millis; CPU is 0-100 float; RAM/net are bytes and bytes/sec.

| method | args | returns |
|---|---|---|
| `latest` | — | newest snapshot (system + every process) |
| `get` | `index` | snapshot at ring-buffer index, plus `len` |
| `len` | — | snapshot count |
| `proc_history` | `pid`, or `pids` | per-process sparkline (up to 150 pts), or one summed series for several pids |
| `history` | `from_ms` (optional) | session samples from the ring, oldest first |
| `events` | `from_ms` (optional) | recent threshold crossings, newest first |
| `kill` | `pid` or `pids`, `signal` (`term`/`kill`) | graceful TERM by default, KILL only on confirm; a `pids` list ends a whole app, in the order given |

## Metrics

| metric | source | per process |
|---|---|---|
| CPU | `/proc/stat`, sysinfo | yes, rolled up over the process tree |
| Memory | sysinfo | yes, own RSS only (no tree sum — shared pages would double-count) |
| Network | socket table / total throughput split | yes, estimated share, rolled up |
| Disk I/O | `/proc/diskstats` (whole disks) | yes, own I/O from `/proc/<pid>/io` |

Disk is own-I/O per process on purpose: every process descends from pid 1, so
tree-summing would credit the whole system's traffic to `systemd`. Root-owned
processes can't be read unprivileged and report 0. Battery is not tracked —
Linux has no per-process energy accounting, only system-wide
`/sys/class/power_supply`.

## Process list

The dashboard lists apps, not processes. Snapshots carry every process (no
top-N cut), and the UI folds processes sharing an executable into one row, so
a browser's dozen helpers become a single `Zen Browser` entry. A group's
numbers are the sum of its members' *own* usage (the `self_*` fields), which is
why nothing is counted twice — tree values would make a terminal's row include
the shell and editor listed separately below it.

Rows with more than one process carry a chevron and the process count next to
the name. The two actions are separate: the chevron's own strip expands the
processes in place, while a click anywhere else on the row opens that app's own
view — its chart, its totals, and the processes it is made of. The hit test and
the chevron share one geometry, so a click can never both disclose and open.
The filter matches app names and process names, and opens a group when only one
of its processes matched. The list is capped at the 40 busiest groups for the
active metric, sorted by it.

The app view leads with the main process (the member whose parent is not in the
group), tagged `main`, then the rest by the active metric. Any of them opens the
full process view, which is where a single process is ended. `End`/`Kill` in the
app view itself ends every process of the app — the main process is signalled
first so it cannot respawn the processes that follow it.

An app's chart is the summed own usage of its processes, computed per ring
snapshot (`proc_history` with `pids`), so the curve agrees with the totals
above it rather than with the main process alone.

Threads are filtered out (`Process::thread_kind`). sysinfo lists tasks as
processes, and each task row repeats its thread group's CPU and RSS, inflating
both the row count and the totals.

## Icons

Process icons come from the freedesktop chain: executable basename → `.desktop`
`Exec=` → `Icon=` → a file in the icon theme (`hicolor`, `Adwaita`, `Yaru`,
`pixmaps`, plus flatpak and `~/.local/share` exports), SVG first. The index is
built at daemon start, so a newly installed app needs
`systemctl --user restart rewindd`. When several desktop files share one
`Exec=` — kitty also ships `kitty-open.desktop`, "kitty URL Launcher" — the
entry named after the binary and not marked `NoDisplay` wins.

The same entry supplies the display name, so groups read `Zen Browser` and
`Neovim` rather than `zen-bin` and `nvim`. Processes without an entry are
labelled with their own name.

Processes with no matching entry get a default: `utilities-terminal` when the
process owns a pseudo-terminal (`pts` major 136–143 in `/proc/<pid>/stat`),
`system-run` (a plain gear) otherwise (daemons, kernel threads, VT console).
Backgrounded terminal servers such as `tmux: server` detach from their tty and
fall into the generic bucket. Root-owned processes can't be read unprivileged:
their executable is unknown, so they group by process name and take the
default icon.

## Status

Scaffold v0.1. Daemon runs, QML plugin loads with mock fallback
when daemon is offline.

## Quick start

```bash
./install.sh
# then: omarchy plugin enable rewind.monitor --section right
#       omarchy restart shell
```

Manual equivalent: `cargo build --release -p rewindd`, copy the binary to
`~/.local/bin`, the unit to `~/.config/systemd/user`, the plugin to
`~/.config/omarchy/plugins/rewind.monitor`. See `install.sh`.

Daemon socket: `$XDG_RUNTIME_DIR/rewind.sock` (JSON lines, see IPC table above).

History is in-memory only: the daemon keeps a ring of the last 150 samples
(~5 min at the default 2s interval), so charts start empty after a reboot and
fill as it runs. Nothing is written to disk or kept across restarts.

## Floating dashboard

The dashboard is a regular window — keep it out of the tiling layout
with a Hyprland rule (matches the window title):

```lua
o.window({ title = "Rewind" }, { float = true, center = true })
```

The bar icon is a placeholder glyph; swap `BarWidget.qml`'s `text` for an
`iconComponent` when the custom icon lands.
