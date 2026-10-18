use serde::{Deserialize, Serialize};
use std::collections::{HashMap, VecDeque};

use crate::metrics::SystemSample;
use crate::processes::{FlatProcess, ProcessMeta};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Snapshot {
    pub ts_ms: i64,
    pub system: SystemSample,
    pub processes: Vec<FlatProcess>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProcessSnapshotFull {
    pub pid: u32,
    pub ts_ms: i64,
    pub cpu: f32,
    pub ram: u64,
    pub net: u64,
    pub disk: u64,
}

// Bounded in-memory history: full-res ring (~5 min at 2s) + event list.
pub const HISTORY_FULL_CAP: usize = 150;

pub struct History {
    pub samples: VecDeque<SystemSample>,
    pub snapshots: VecDeque<Snapshot>,
    pub meta: HashMap<u32, ProcessMeta>,
    pub per_process: HashMap<u32, VecDeque<ProcessSnapshotFull>>,
}

impl Default for History {
    fn default() -> Self {
        Self {
            samples: VecDeque::new(),
            snapshots: VecDeque::new(),
            meta: HashMap::new(),
            per_process: HashMap::new(),
        }
    }
}

impl History {
    pub fn push(&mut self, snap: Snapshot, meta: HashMap<u32, ProcessMeta>) {
        if self.samples.len() >= HISTORY_FULL_CAP {
            self.samples.pop_front();
        }
        self.samples.push_back(snap.system.clone());
        // per-process sparkline (cap 150 points each, cap 512 pids)
        for p in &snap.processes {
            let e = self.per_process.entry(p.pid).or_insert_with(VecDeque::new);
            if e.len() >= HISTORY_FULL_CAP {
                e.pop_front();
            }
            e.push_back(ProcessSnapshotFull {
                pid: p.pid,
                ts_ms: snap.ts_ms,
                cpu: p.cpu,
                ram: p.ram,
                net: p.net,
                disk: p.disk,
            });
            if self.per_process.len() > 512 {
                break;
            }
        }
        if self.snapshots.len() >= HISTORY_FULL_CAP {
            self.snapshots.pop_front();
        }
        self.snapshots.push_back(snap);
        self.meta.extend(meta);
        let referenced: std::collections::HashSet<u32> = self
            .snapshots
            .iter()
            .flat_map(|s| s.processes.iter().map(|p| p.pid))
            .collect();
        self.meta.retain(|pid, _| referenced.contains(pid));
        self.per_process.retain(|pid, _| referenced.contains(pid));
    }

    pub fn get(&self, index: usize) -> Option<&Snapshot> {
        self.snapshots.get(index)
    }

    pub fn latest(&self) -> Option<&Snapshot> {
        self.snapshots.back()
    }
}
