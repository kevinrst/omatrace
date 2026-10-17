use rewind_core::{collect_processes, History, NetTracker, ProcessMeta, Sampler, Snapshot};
use std::collections::{HashMap, VecDeque};

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct Event {
    pub ts_ms: i64,
    pub kind: String,
    pub label: String,
    pub cpu: f32,
    pub ram_used: u64,
    pub ram_total: u64,
}

pub struct State {
    sampler: Sampler,
    net: NetTracker,
    history: History,
    meta: HashMap<u32, ProcessMeta>,
    prev_cpu: f32,
    events: VecDeque<Event>,
}

const EVENT_CAP: usize = 200;

impl State {
    pub fn new(interval_secs: u64) -> Self {
        Self {
            sampler: Sampler::new(interval_secs),
            net: NetTracker::new(),
            history: History::default(),
            meta: HashMap::new(),
            prev_cpu: 0.0,
            events: VecDeque::new(),
        }
    }

    pub fn tick(&mut self) -> Snapshot {
        self.sampler.refresh();
        let ts_ms = chrono::Utc::now().timestamp_millis();
        let mut sample = self.sampler.sample_system(ts_ms);
        // total network for attribution split
        let total_bps = sample.net.down_bps + sample.net.up_bps;
        let net_map = self.net.update(total_bps);
        let interval = self.sampler.interval_secs();
        let mut procs =
            collect_processes(self.sampler.system(), &net_map, &mut self.meta, interval);
        procs.sort_by(|a, b| b.cpu.partial_cmp(&a.cpu).unwrap());
        let mut top = procs;
        if top.len() > 40 {
            let rest = top.split_off(40);
            let mut movers: Vec<_> = rest
                .into_iter()
                .filter(|p| p.disk >= 256 * 1024 || p.net >= 256 * 1024)
                .collect();
            movers.sort_by(|a, b| (b.disk + b.net).cmp(&(a.disk + a.net)));
            movers.truncate(20);
            top.append(&mut movers);
        }

        sample.temp_max_c = read_temp_max();
        if let Some(ev) = detect_event(self.prev_cpu, &sample, &top) {
            if self.events.len() >= EVENT_CAP {
                self.events.pop_front();
            }
            self.events.push_back(ev);
        }
        self.prev_cpu = sample.cpu_percent;

        let snap = Snapshot {
            ts_ms,
            system: sample.clone(),
            processes: top,
        };
        self.history.push(snap.clone(), self.meta.clone());
        snap
    }

    pub fn latest(&self) -> Option<Snapshot> {
        self.history.latest().cloned()
    }

    pub fn get(&self, index: usize) -> Option<Snapshot> {
        self.history.get(index).cloned()
    }

    pub fn len(&self) -> usize {
        self.history.snapshots.len()
    }

    pub fn proc_history(&self, pid: u32) -> Vec<rewind_core::ProcessSnapshotFull> {
        self.history
            .per_process
            .get(&pid)
            .map(|d| d.iter().cloned().collect())
            .unwrap_or_default()
    }

    pub fn system_history(&self, from_ms: i64) -> Vec<rewind_core::SystemSample> {
        self.history
            .samples
            .iter()
            .filter(|s| s.ts_ms >= from_ms)
            .cloned()
            .collect()
    }

    pub fn events(&self, from_ms: i64) -> Vec<Event> {
        self.events
            .iter()
            .rev()
            .filter(|e| e.ts_ms >= from_ms)
            .cloned()
            .collect()
    }
}

fn detect_event(
    prev_cpu: f32,
    s: &rewind_core::SystemSample,
    top: &[rewind_core::FlatProcess],
) -> Option<Event> {
    // Spike: jump > 30 pts and absolute > 70%.
    if s.cpu_percent - prev_cpu > 30.0 && s.cpu_percent > 70.0 {
        let who = top
            .first()
            .map(|p| format!("{} ({:.0}%)", p.name, p.cpu))
            .unwrap_or_default();
        return Some(Event {
            ts_ms: s.ts_ms,
            kind: "cpu_spike".into(),
            label: format!("CPU spike to {:.0}% — top: {who}", s.cpu_percent),
            cpu: s.cpu_percent,
            ram_used: s.ram_used,
            ram_total: s.ram_total,
        });
    }
    // Memory pressure: > 90%.
    if s.ram_total > 0 && s.ram_used * 100 / s.ram_total >= 90 {
        return Some(Event {
            ts_ms: s.ts_ms,
            kind: "mem_pressure".into(),
            label: "Memory above 90%".into(),
            cpu: s.cpu_percent,
            ram_used: s.ram_used,
            ram_total: s.ram_total,
        });
    }
    // Temperature: > 85C.
    if let Some(t) = s.temp_max_c {
        if t > 85.0 {
            return Some(Event {
                ts_ms: s.ts_ms,
                kind: "temp".into(),
                label: format!("Temperature {t:.0}°C"),
                cpu: s.cpu_percent,
                ram_used: s.ram_used,
                ram_total: s.ram_total,
            });
        }
    }
    None
}

fn read_temp_max() -> Option<f32> {
    let mut max: Option<f32> = None;
    let Ok(entries) = std::fs::read_dir("/sys/class/hwmon") else {
        return None;
    };
    for entry in entries.flatten() {
        let dev = entry.path();
        for i in 1..=16 {
            let p = dev.join(format!("temp{i}_input"));
            if let Ok(raw) = std::fs::read_to_string(&p) {
                if let Ok(milli) = raw.trim().parse::<f32>() {
                    let c = milli / 1000.0;
                    max = Some(max.map_or(c, |m: f32| m.max(c)));
                }
            }
        }
    }
    max
}
