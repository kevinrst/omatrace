use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use sysinfo::System;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProcessMeta {
    pub name: String,
    pub exe_path: String,
    pub started_at: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FlatProcess {
    pub pid: u32,
    pub parent_pid: Option<u32>,
    pub name: String,
    pub exe_path: String,
    pub started_at: u64,
    /// Own usage.
    pub self_cpu: f32,
    pub self_ram: u64,
    pub self_net: u64,
    pub self_disk: u64,
    /// Including descendants.
    pub cpu: f32,
    pub ram: u64,
    pub net: u64,
    pub disk: u64,
}

pub fn collect_processes(
    sys: &System,
    net_map: &HashMap<u32, u64>,
    metadata_cache: &mut HashMap<u32, ProcessMeta>,
    interval_secs: u64,
) -> Vec<FlatProcess> {
    let cpu_count = sys.cpus().len().max(1) as f32;
    let mut out = Vec::new();
    for (pid, proc_) in sys.processes() {
        let pid_u32 = pid.as_u32();
        let meta = metadata_cache
            .entry(pid_u32)
            .or_insert_with(|| ProcessMeta {
                name: proc_.name().to_string_lossy().to_string(),
                exe_path: proc_
                    .exe()
                    .map(|p| p.to_string_lossy().to_string())
                    .unwrap_or_default(),
                started_at: proc_.start_time(),
            });
        let self_net = net_map.get(&pid_u32).copied().unwrap_or(0);

        let io = proc_.disk_usage();
        let self_disk = (io.read_bytes + io.written_bytes) / interval_secs.max(1);
        out.push(FlatProcess {
            pid: pid_u32,
            parent_pid: proc_.parent().map(|p| p.as_u32()),
            name: meta.name.clone(),
            exe_path: meta.exe_path.clone(),
            started_at: meta.started_at,
            self_cpu: proc_.cpu_usage() / cpu_count,
            self_ram: proc_.memory(),
            self_net,
            self_disk,
            cpu: proc_.cpu_usage() / cpu_count,
            ram: proc_.memory(),
            net: self_net,
            disk: self_disk,
        });
    }
    aggregate(&mut out);
    out
}

fn aggregate(procs: &mut [FlatProcess]) {
    use std::collections::HashMap;
    let index: HashMap<u32, usize> = procs.iter().enumerate().map(|(i, p)| (p.pid, i)).collect();
    let mut children: HashMap<u32, Vec<u32>> = HashMap::new();
    for p in procs.iter() {
        if let Some(pp) = p.parent_pid {
            if index.contains_key(&pp) {
                children.entry(pp).or_default().push(p.pid);
            }
        }
    }
    fn sum(
        pid: u32,
        index: &HashMap<u32, usize>,
        children: &HashMap<u32, Vec<u32>>,
        procs: &[FlatProcess],
        memo: &mut HashMap<u32, (f32, u64)>,
    ) -> (f32, u64) {
        if let Some(m) = memo.get(&pid) {
            return *m;
        }
        let i = index[&pid];
        let mut cpu = procs[i].self_cpu;
        let mut net = procs[i].self_net;
        if let Some(kids) = children.get(&pid) {
            for k in kids {
                let (c, n) = sum(*k, index, children, procs, memo);
                cpu += c;
                net += n;
            }
        }
        memo.insert(pid, (cpu, net));
        (cpu, net)
    }
    let mut memo = HashMap::new();
    let pids: Vec<u32> = procs.iter().map(|p| p.pid).collect();
    for pid in pids {
        let (c, n) = sum(pid, &index, &children, procs, &mut memo);
        let i = index[&pid];
        procs[i].cpu = c;
        procs[i].ram = procs[i].self_ram;
        procs[i].net = n;
        procs[i].disk = procs[i].self_disk;
    }
}
