use anyhow::Result;
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::Mutex;

use crate::sample::State;

pub async fn serve(sock: &str, state: Arc<Mutex<State>>) -> Result<()> {
    let _ = std::fs::remove_file(sock);
    let listener = UnixListener::bind(sock)?;
    println!("rewindd listening on {sock}");
    loop {
        let (stream, _) = listener.accept().await?;
        let st = state.clone();
        tokio::spawn(async move {
            if let Err(e) = handle(stream, st).await {
                eprintln!("ipc error: {e:#}");
            }
        });
    }
}

async fn handle(stream: UnixStream, state: Arc<Mutex<State>>) -> Result<()> {
    let (r, mut w) = stream.into_split();
    let mut lines = BufReader::new(r).lines();
    while let Some(line) = lines.next_line().await? {
        let req: serde_json::Value = serde_json::from_str(&line).unwrap_or(serde_json::json!({}));
        let method = req.get("method").and_then(|m| m.as_str()).unwrap_or("");
        let resp = match method {
            "latest" => {
                let st = state.lock().await;
                serde_json::json!({"ok": true, "snapshot": st.latest()})
            }
            "get" => {
                let idx = req.get("index").and_then(|i| i.as_u64()).unwrap_or(0) as usize;
                let st = state.lock().await;
                serde_json::json!({"ok": true, "snapshot": st.get(idx), "len": st.len()})
            }
            "len" => {
                let st = state.lock().await;
                serde_json::json!({"ok": true, "len": st.len()})
            }
            "proc_history" => {
                let pid = req.get("pid").and_then(|p| p.as_u64()).unwrap_or(0) as u32;
                let st = state.lock().await;
                serde_json::json!({"ok": true, "points": st.proc_history(pid)})
            }
            "kill" => {
                let pid = req.get("pid").and_then(|p| p.as_u64()).unwrap_or(0) as u32;
                let sig = req.get("signal").and_then(|s| s.as_str()).unwrap_or("term");
                serde_json::json!({"ok": kill(pid, sig), "pid": pid})
            }
            _ => serde_json::json!({"ok": false, "error": "unknown method"}),
        };
        w.write_all(format!("{}\n", resp).as_bytes()).await?;
    }
    Ok(())
}

fn kill(pid: u32, signal: &str) -> bool {
    use sysinfo::{Pid, Signal, System};
    let mut sys = System::new();
    sys.refresh_processes(sysinfo::ProcessesToUpdate::All, true);
    let Some(proc_) = sys.process(Pid::from_u32(pid)) else {
        return false;
    };
    match signal {
        "kill" => proc_.kill(),
        _ => proc_.kill_with(Signal::Term).unwrap_or(false),
    }
}
