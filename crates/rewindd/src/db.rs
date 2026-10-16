use anyhow::Result;
use rusqlite::Connection;

use crate::sample::Event;
use rewind_core::Snapshot;

pub fn open(path: &str) -> Result<Connection> {
    Ok(Connection::open(path)?)
}

pub fn init(conn: &Connection) -> Result<()> {
    conn.execute_batch(
        "
        CREATE TABLE IF NOT EXISTS minute_rollup (
          ts_ms INTEGER PRIMARY KEY,
          cpu REAL NOT NULL,
          ram_used INTEGER NOT NULL,
          ram_total INTEGER NOT NULL,
          down_bps INTEGER NOT NULL,
          up_bps INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS events (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          ts_ms INTEGER NOT NULL,
          kind TEXT NOT NULL,
          label TEXT NOT NULL,
          cpu REAL NOT NULL,
          ram_used INTEGER NOT NULL,
          ram_total INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts_ms);
        CREATE INDEX IF NOT EXISTS idx_minute_ts ON minute_rollup(ts_ms);
        ",
    )?;
    Ok(())
}

pub fn insert_minute(conn: &Connection, snap: &Snapshot) -> Result<()> {
    conn.execute(
        "INSERT OR REPLACE INTO minute_rollup (ts_ms, cpu, ram_used, ram_total, down_bps, up_bps)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        rusqlite::params![
            snap.ts_ms,
            snap.system.cpu_percent,
            snap.system.ram_used as i64,
            snap.system.ram_total as i64,
            snap.system.net.down_bps as i64,
            snap.system.net.up_bps as i64,
        ],
    )?;
    Ok(())
}

pub fn insert_event(conn: &Connection, ev: &Event) -> Result<()> {
    conn.execute(
        "INSERT INTO events (ts_ms, kind, label, cpu, ram_used, ram_total)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        rusqlite::params![
            ev.ts_ms,
            ev.kind,
            ev.label,
            ev.cpu,
            ev.ram_used as i64,
            ev.ram_total as i64,
        ],
    )?;
    Ok(())
}

pub fn prune(conn: &Connection) -> Result<()> {
    let cutoff = chrono::Utc::now().timestamp_millis() - 24 * 3600 * 1000;
    conn.execute("DELETE FROM minute_rollup WHERE ts_ms < ?1", [cutoff])?;
    conn.execute("DELETE FROM events WHERE ts_ms < ?1", [cutoff])?;
    Ok(())
}

pub fn query_range(conn: &Connection, from_ms: i64, to_ms: i64) -> Result<Vec<serde_json::Value>> {
    let mut stmt = conn.prepare(
        "SELECT ts_ms, cpu, ram_used, ram_total, down_bps, up_bps
         FROM minute_rollup WHERE ts_ms BETWEEN ?1 AND ?2 ORDER BY ts_ms",
    )?;
    let rows = stmt.query_map([from_ms, to_ms], |r| {
        Ok(serde_json::json!({
            "ts_ms": r.get::<_, i64>(0)?,
            "cpu": r.get::<_, f64>(1)?,
            "ram_used": r.get::<_, i64>(2)?,
            "ram_total": r.get::<_, i64>(3)?,
            "down_bps": r.get::<_, i64>(4)?,
            "up_bps": r.get::<_, i64>(5)?,
        }))
    })?;
    Ok(rows.filter_map(|r| r.ok()).collect())
}

pub fn query_events(conn: &Connection, from_ms: i64, to_ms: i64) -> Result<Vec<Event>> {
    let mut stmt = conn.prepare(
        "SELECT ts_ms, kind, label, cpu, ram_used, ram_total
         FROM events WHERE ts_ms BETWEEN ?1 AND ?2 ORDER BY ts_ms DESC LIMIT 200",
    )?;
    let rows = stmt.query_map([from_ms, to_ms], |r| {
        Ok(Event {
            ts_ms: r.get(0)?,
            kind: r.get(1)?,
            label: r.get(2)?,
            cpu: r.get(3)?,
            ram_used: r.get::<_, i64>(4)? as u64,
            ram_total: r.get::<_, i64>(5)? as u64,
        })
    })?;
    Ok(rows.filter_map(|r| r.ok()).collect())
}
