mod db;
mod ipc;
mod sample;

use clap::Parser;
use std::sync::Arc;
use tokio::sync::Mutex;

#[derive(Parser, Debug)]
struct Args {
    #[arg(long, default_value_t = 2)]
    interval_secs: u64,
    #[arg(long, default_value = "")]
    socket: String,
    #[arg(long, default_value = "")]
    db: String,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args = Args::parse();
    let runtime = dirs_socket(&args.socket);
    let db_path = dirs_db(&args.db);
    if let Some(p) = std::path::Path::new(&db_path).parent() {
        std::fs::create_dir_all(p)?;
    }
    let conn = db::open(&db_path)?;
    db::init(&conn)?;

    let state = Arc::new(Mutex::new(sample::State::new(args.interval_secs)));
    let tick_state = state.clone();
    let db_writer = Arc::new(Mutex::new(conn));
    let db_reader = db_writer.clone();
    let interval = std::env::var("REWIND_INTERVAL")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(args.interval_secs);

    tokio::spawn(async move {
        let mut tick: u64 = 0;
        // DB minute rollup: write every ~60s regardless of sample interval.
        let ticks_per_minute = (60 / interval.max(1)).max(1);
        let ticks_per_prune = ticks_per_minute * 10;
        loop {
            tick += 1;
            let (snap, meta, event) = {
                let mut st = tick_state.lock().await;
                st.tick()
            };
            {
                let dbw = db_writer.lock().await;
                // per-minute rollup
                if tick % ticks_per_minute == 0 {
                    let _ = db::insert_minute(&dbw, &snap);
                }
                if let Some(ev) = event {
                    let _ = db::insert_event(&dbw, &ev);
                }
                // keep DB bounded in background every ~10 min
                if tick % ticks_per_prune == 0 {
                    let _ = db::prune(&dbw);
                }
                let _ = meta;
            }
            tokio::time::sleep(std::time::Duration::from_secs(interval)).await;
        }
    });

    ipc::serve(&runtime, state, db_reader).await?;
    Ok(())
}

fn dirs_socket(override_: &str) -> String {
    if !override_.is_empty() {
        return override_.to_string();
    }
    if let Ok(r) = std::env::var("XDG_RUNTIME_DIR") {
        return format!("{r}/rewind.sock");
    }
    "/tmp/rewind.sock".to_string()
}

fn dirs_db(override_: &str) -> String {
    if !override_.is_empty() {
        return override_.to_string();
    }
    if let Ok(h) = std::env::var("HOME") {
        return format!("{h}/.local/share/rewind/history.db");
    }
    "./history.db".to_string()
}
