# Omatrace — System Monitoring & Diagnostics for Omarchy

See what's happening. Understand why.

Native Omarchy app: Rust engine (`omatraced` daemon) + Quickshell plugin
(bar widget + dashboard window). Timeline-first: every sample is a
snapshot you can scrub back through, with per-process attribution.

## Layout

The repository root is the plugin folder. `omarchy plugin add` clones it into
`~/.config/omarchy/plugins/kevin.omatrace/` and loads `BarWidget.qml` from there;
the daemon lives beside it in `daemon/`.

```
omatrace/
  manifest.json               # plugin manifest: id kevin.omatrace, bar-widget
  BarWidget.qml               # entry point: bar icon, popup, dashboard lifecycle
  Popup.qml                   # metrics panel anchored to the icon
  Dashboard.qml               # floating dashboard window (tables, charts, drill-down)
  OmatraceData.qml            # daemon connection, snapshots, history requests
  OmatraceClient.js           # formatting helpers + offline fallback snapshot
  Bars.qml                    # chart primitives (two-tone timeline bars)
  install.sh                  # builds/installs the daemon, installs the plugin
  uninstall.sh                # stops the daemon, removes binary, unit, plugin
  daemon/
    Cargo.toml                # workspace
    crates/
      omatrace-core/          # portable engine: sampling model, aggregation, metrics
      omatraced/              # daemon: sampling, in-memory ring, Unix-socket JSON
    systemd/user/omatraced.service
```

## IPC

Unix socket `$XDG_RUNTIME_DIR/omatrace.sock`, one JSON object per line.
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

A process that is gone takes its view with it: the view follows the live
snapshot, so a process that was ended — or one that exited on its own — falls
back to its app, or to the list once the app is gone too. History is left
alone: it shows what was, not what is.

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
`systemctl --user restart omatraced`. When several desktop files share one
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

## Requirements

The plugin is only the UI. It needs the `omatraced` daemon from this same repo
(`daemon/`); without it the dashboard shows its fallback snapshot and a note
that the daemon is offline.

- **Build**: Rust and cargo (rustup or your distro's packages) to build the
  daemon. The QML side needs nothing beyond the Omarchy shell.
- **Privileges**: the daemon is a **systemd user service** running as you. No
  root, no sudo, no setuid helper, no capabilities. It reads `/proc`, `/sys` and
  desktop files, and can only signal processes you own — other users' processes
  come back `EPERM` and the UI reports that nothing was signalled.
- **Socket**: `$XDG_RUNTIME_DIR/omatrace.sock`, JSON lines, reachable by your
  user only. The daemon never opens a network port.
- **Data**: samples live in memory (150-snapshot ring, ~5 min at the default 2s
  interval). Nothing is written to disk and nothing leaves the machine.
- **No second shell**: the UI is QML loaded by the long-lived `omarchy-shell`
  process. `omatraced` is a plain user service, not another Quickshell.

## Install

```bash
omarchy plugin add https://github.com/kevinrst/rewind.git --enable
~/.config/omarchy/plugins/kevin.omatrace/install.sh
omarchy restart shell
```

The first line installs and enables the widget; `install.sh` does the daemon
side: builds `omatraced`, installs it to `~/.local/bin`, installs and starts
`omatraced.service`, validates the plugin and rescans the shell. Add
`--section left|center|right` to `omarchy plugin enable kevin.omatrace` if the
widget is not where you want it.

From a development checkout the same script works: it builds the daemon and
copies the shell files into `~/.config/omarchy/plugins/kevin.omatrace/`. Manual
equivalent:

```bash
cargo build --release --manifest-path daemon/Cargo.toml -p omatraced
install -Dm755 daemon/target/release/omatraced ~/.local/bin/omatraced
install -Dm644 daemon/systemd/user/omatraced.service ~/.config/systemd/user/
systemctl --user daemon-reload && systemctl --user enable --now omatraced
```

Remove everything with `./uninstall.sh`: it stops and deletes the service and
binary and removes the plugin folder (`omarchy plugin remove kevin.omatrace` for
the UI alone). Afterwards: `omarchy restart shell`.

Daemon socket: `$XDG_RUNTIME_DIR/omatrace.sock` (JSON lines, see IPC table above).

History is in-memory only: the daemon keeps a ring of the last 150 samples
(~5 min at the default 2s interval), so charts start empty after a reboot and
fill as it runs. Nothing is written to disk or kept across restarts.

## Floating dashboard

The dashboard is a regular window — keep it out of the tiling layout
with a Hyprland rule (matches the window title):

```lua
o.window({ title = "Omatrace" }, { float = true, center = true })
```

The bar icon is a placeholder glyph; swap `BarWidget.qml`'s `text` for an
`iconComponent` when the custom icon lands.
