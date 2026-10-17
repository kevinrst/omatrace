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
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args = Args::parse();
    let runtime = dirs_socket(&args.socket);
    let state = Arc::new(Mutex::new(sample::State::new(args.interval_secs)));
    let tick_state = state.clone();
    let interval = std::env::var("REWIND_INTERVAL")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(args.interval_secs);

    tokio::spawn(async move {
        loop {
            {
                let mut st = tick_state.lock().await;
                st.tick();
            }
            tokio::time::sleep(std::time::Duration::from_secs(interval)).await;
        }
    });

    ipc::serve(&runtime, state).await?;
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
