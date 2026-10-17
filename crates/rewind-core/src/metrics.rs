use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use sysinfo::{Disks, Networks, ProcessesToUpdate, System};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SystemSample {
    pub ts_ms: i64,
    pub cpu_percent: f32,
    pub cpu_per_core: Vec<f32>,
    pub load_avg_1: f64,
    pub load_avg_5: f64,
    pub ram_used: u64,
    pub ram_total: u64,
    pub swap_used: u64,
    pub swap_total: u64,
    pub disk: DiskStat,
    pub net: NetStat,
    pub temp_max_c: Option<f32>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct DiskStat {
    pub used: u64,
    pub total: u64,
    pub read_bps: u64,
    pub write_bps: u64,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct NetStat {
    pub down_bps: u64,
    pub up_bps: u64,
}

pub struct Sampler {
    sys: System,
    disks: Disks,
    networks: Networks,
    disk_index: Option<usize>,
    prev_rx: u64,
    prev_tx: u64,
    disk_io: DiskIo,
    interval_secs: u64,
}

struct DiskIo {
    devices: Vec<String>,
    prev_read: u64,
    prev_write: u64,
}

impl DiskIo {
    fn new() -> Self {
        let mut devices = Vec::new();
        if let Ok(entries) = std::fs::read_dir("/sys/block") {
            for entry in entries.flatten() {
                let name = entry.file_name().to_string_lossy().to_string();
                if !name.starts_with("loop")
                    && !name.starts_with("ram")
                    && !name.starts_with("zram")
                    && !name.starts_with("dm-")
                    && !name.starts_with("md")
                    && !name.starts_with("sr")
                    && !name.starts_with("nbd")
                    && !name.starts_with("fd")
                {
                    devices.push(name);
                }
            }
        }
        Self {
            devices,
            prev_read: 0,
            prev_write: 0,
        }
    }

    fn rates(&mut self, interval_secs: u64) -> (u64, u64) {
        let Ok(text) = std::fs::read_to_string("/proc/diskstats") else {
            return (0, 0);
        };
        let mut sectors_read = 0u64;
        let mut sectors_written = 0u64;
        for line in text.lines() {
            let f: Vec<&str> = line.split_whitespace().collect();
            if f.len() < 10 || !self.devices.iter().any(|d| d == f[2]) {
                continue;
            }
            sectors_read += f[5].parse::<u64>().unwrap_or(0);
            sectors_written += f[9].parse::<u64>().unwrap_or(0);
        }
        let read_bps = sectors_read.saturating_sub(self.prev_read) * 512 / interval_secs.max(1);
        let write_bps =
            sectors_written.saturating_sub(self.prev_write) * 512 / interval_secs.max(1);
        self.prev_read = sectors_read;
        self.prev_write = sectors_written;
        (read_bps, write_bps)
    }
}

impl Sampler {
    pub fn new(interval_secs: u64) -> Self {
        let mut sys = System::new();
        sys.refresh_cpu_all();
        std::thread::sleep(sysinfo::MINIMUM_CPU_UPDATE_INTERVAL);
        let disks = Disks::new_with_refreshed_list();
        let networks = Networks::new_with_refreshed_list();
        let target = std::path::PathBuf::from("/");
        let disk_index = disks
            .iter()
            .position(|d| target.starts_with(d.mount_point()));
        Self {
            sys,
            disks,
            networks,
            disk_index,
            prev_rx: 0,
            prev_tx: 0,
            disk_io: DiskIo::new(),
            interval_secs: interval_secs.max(1),
        }
    }

    pub fn refresh(&mut self) {
        self.sys.refresh_cpu_all();
        self.sys.refresh_memory();
        self.sys.refresh_processes(ProcessesToUpdate::All, true);
        self.networks.refresh(false);
        self.disks.refresh(false);
    }

    pub fn system(&self) -> &System {
        &self.sys
    }

    pub fn interval_secs(&self) -> u64 {
        self.interval_secs
    }

    pub fn sample_system(&mut self, ts_ms: i64) -> SystemSample {
        let disk_rates = self.disk_io.rates(self.interval_secs);
        sample_system(
            &self.sys,
            &self.disks,
            &self.networks,
            self.disk_index,
            &mut self.prev_rx,
            &mut self.prev_tx,
            self.interval_secs,
            disk_rates,
            ts_ms,
        )
    }
}

pub fn sample_system(
    sys: &System,
    disks: &Disks,
    networks: &Networks,
    disk_index: Option<usize>,
    prev_rx: &mut u64,
    prev_tx: &mut u64,
    interval_secs: u64,
    disk_rates: (u64, u64),
    ts_ms: i64,
) -> SystemSample {
    let cpu_percent = sys.global_cpu_usage();
    let cpu_per_core: Vec<f32> = sys.cpus().iter().map(|c| c.cpu_usage()).collect();
    let load = System::load_average();

    let ram_used = sys.used_memory();
    let ram_total = sys.total_memory();

    let (disk_used, disk_total) = match disk_index.and_then(|i| disks.get(i)) {
        Some(d) => (
            d.total_space().saturating_sub(d.available_space()),
            d.total_space(),
        ),
        None => (0, 0),
    };

    let rx: u64 = networks.iter().map(|(_, n)| n.received()).sum();
    let tx: u64 = networks.iter().map(|(_, n)| n.transmitted()).sum();
    let down_bps = rx.saturating_sub(*prev_rx) / interval_secs.max(1);
    let up_bps = tx.saturating_sub(*prev_tx) / interval_secs.max(1);
    *prev_rx = rx;
    *prev_tx = tx;

    SystemSample {
        ts_ms,
        cpu_percent,
        cpu_per_core,
        load_avg_1: load.one,
        load_avg_5: load.five,
        ram_used,
        ram_total,
        swap_used: sys.used_swap(),
        swap_total: sys.total_swap(),
        disk: DiskStat {
            used: disk_used,
            total: disk_total,
            read_bps: disk_rates.0,
            write_bps: disk_rates.1,
        },
        net: NetStat { down_bps, up_bps },
        temp_max_c: None,
    }
}

pub struct NetTracker {
    smoothed: HashMap<u32, f64>,
    decay_ticks: HashMap<u32, u8>,
}

impl NetTracker {
    pub fn new() -> Self {
        Self {
            smoothed: HashMap::new(),
            decay_ticks: HashMap::new(),
        }
    }

    pub fn update(&mut self, total_bps: u64) -> HashMap<u32, u64> {
        use netstat2::{get_sockets_info, AddressFamilyFlags, ProtocolFlags, TcpState};
        let mut scores: HashMap<u32, f64> = HashMap::new();
        let mut remotes: HashMap<u32, std::collections::HashSet<String>> = HashMap::new();
        if let Ok(infos) = get_sockets_info(
            AddressFamilyFlags::IPV4 | AddressFamilyFlags::IPV6,
            ProtocolFlags::TCP | ProtocolFlags::UDP,
        ) {
            for info in infos {
                for pid in info.associated_pids.iter().copied() {
                    let entry = scores.entry(pid).or_insert(0.0);
                    match &info.protocol_socket_info {
                        netstat2::ProtocolSocketInfo::Tcp(tcp) => {
                            if tcp.state == TcpState::Listen {
                                continue;
                            }
                            *entry += 1.0;
                            remotes
                                .entry(pid)
                                .or_default()
                                .insert(format!("{:?}", tcp.remote_addr));
                        }
                        netstat2::ProtocolSocketInfo::Udp(_) => {
                            *entry += 0.5;
                        }
                    }
                }
            }
        }
        for (pid, set) in &remotes {
            if let Some(s) = scores.get_mut(pid) {
                *s += set.len() as f64 * 0.5;
            }
        }
        let total_score: f64 = scores.values().sum();
        let mut out = HashMap::new();
        if total_score > 0.0 && total_bps > 0 {
            for (pid, score) in scores {
                let raw = score / total_score * total_bps as f64;
                let prev = self.smoothed.get(&pid).copied().unwrap_or(0.0);
                let ema = 0.7 * prev + 0.3 * raw;
                self.smoothed.insert(pid, ema);
                self.decay_ticks.insert(pid, 0);
                if ema >= 512.0 {
                    out.insert(pid, ema as u64);
                }
            }
        }
        let stale: Vec<u32> = self
            .smoothed
            .keys()
            .filter(|p| !out.contains_key(p))
            .copied()
            .collect();
        for pid in stale {
            let ticks = self.decay_ticks.entry(pid).or_insert(0);
            *ticks += 1;
            if *ticks > 4 {
                self.smoothed.remove(&pid);
                self.decay_ticks.remove(&pid);
            } else if let Some(v) = self.smoothed.get_mut(&pid) {
                *v *= 0.5;
                if *v >= 512.0 {
                    out.insert(pid, *v as u64);
                }
            }
        }
        out
    }
}

impl Default for NetTracker {
    fn default() -> Self {
        Self::new()
    }
}
