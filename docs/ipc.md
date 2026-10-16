# Rewind IPC — v1

Transport: Unix domain socket, default `$XDG_RUNTIME_DIR/rewind.sock`.
Framing: one JSON object per line, UTF-8. Response: one JSON line.

All timestamps: `ts_ms` (unix millis). Units explicit:
CPU `%` (0-100 float), RAM bytes, network bytes/sec, temp Celsius.

## Requests

```json
{"method": "latest"}
{"method": "get", "index": 0}
{"method": "len"}
{"method": "proc_history", "pid": 1234}
{"method": "kill", "pid": 1234, "signal": "term"}
{"method": "history", "from_ms": 1791900000000, "to_ms": 1792000000000}
{"method": "events", "from_ms": 1791900000000, "to_ms": 1792000000000}
```

`signal` is `"term"` (SIGTERM, graceful) or `"kill"` (SIGKILL).
QML must confirm before sending `kill`; the daemon never escalates silently.

## Responses

`latest` / `get` return a `snapshot`:

```json
{
  "ok": true,
  "snapshot": {
    "ts_ms": 1792000000000,
    "system": {
      "ts_ms": 1792000000000,
      "cpu_percent": 23.5,
      "cpu_per_core": [10.0, 40.0],
      "load_avg_1": 1.2, "load_avg_5": 0.9,
      "ram_used": 8000000000, "ram_total": 16000000000,
      "swap_used": 0, "swap_total": 0,
      "disk": {"used": 1, "total": 2, "read_bps": 0, "write_bps": 0},
      "net": {"down_bps": 1000, "up_bps": 500},
      "temp_max_c": 55.0
    },
    "processes": [
      {"pid": 1, "parent_pid": 0, "name": "init", "exe_path": "",
       "started_at": 0, "self_cpu": 0.1, "self_ram": 1000, "self_net": 0,
       "cpu": 0.5, "ram": 2000, "net": 0}
    ]
  },
  "len": 150
}
```

`proc_history` returns per-PID sparkline points (up to 150):

```json
{"ok": true, "points": [{"pid": 1, "ts_ms": 0, "cpu": 0.5, "ram": 2000, "net": 0}]}
```

Missing sensors are `null` (temp) or `0` with graceful QML fallback —
never fake data. Per-process network is heuristic attribution;
interface totals in `system.net` are authoritative.

## 24h history

`history` returns per-minute rollups (up to ~1440 points).
`from_ms`/`to_ms` default to the last 24h when omitted.

```json
{"ok": true, "points": [
  {"ts_ms": 1791900000000, "cpu": 23.5, "ram_used": 8000000000,
   "ram_total": 16000000000, "down_bps": 1000, "up_bps": 500}
]}
```

`events` returns threshold crossings (up to 200, newest first):

```json
{"ok": true, "events": [
  {"ts_ms": 1791950000000, "kind": "cpu_spike",
   "label": "CPU spike to 85% — top: gcc (62%)",
   "cpu": 85.0, "ram_used": 8000000000, "ram_total": 16000000000}
]}
```

Event kinds: `cpu_spike`, `mem_pressure`, `temp`.
