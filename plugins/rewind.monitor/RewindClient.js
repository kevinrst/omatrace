// Rewind socket client: line-delimited JSON over $XDG_RUNTIME_DIR/rewind.sock.
// Falls back to mock data when rewindd is offline so the widget stays useful.
.pragma library

function socketPath() {
  var rt = Qt.getenv ? "" : "";
  return "/run/user/1000/rewind.sock";
}

function mockSnapshot() {
  var now = Date.now();
  return {
    ts_ms: now,
    system: {
      ts_ms: now, cpu_percent: 12.0, cpu_per_core: [],
      load_avg_1: 0.5, load_avg_5: 0.4,
      ram_used: 4000000000, ram_total: 16000000000,
      swap_used: 0, swap_total: 0,
      disk: { used: 0, total: 0, read_bps: 0, write_bps: 0 },
      net: { down_bps: 0, up_bps: 0 },
      temp_max_c: null
    },
    processes: []
  };
}

function fmtBytes(b) {
  if (b >= 1e9) return (b / 1e9).toFixed(1) + "G";
  if (b >= 1e6) return (b / 1e6).toFixed(0) + "M";
  if (b >= 1e3) return (b / 1e3).toFixed(0) + "K";
  return b + "B";
}

function fmtBps(b) {
  return fmtBytes(b) + "/s";
}
