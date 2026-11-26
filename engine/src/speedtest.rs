//! A short download test per adapter, so a new adapter's share of flows matches its speed from the
//! start; once it carries traffic, what it relays takes over (sched.rs). Results are kept for a day
//! per adapter and network, so switching on and off does not spend a phone's data again.

use std::collections::HashMap;
use std::path::Path;
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::adapters::Adapter;

/// At most 10 MB or 3 seconds, whichever comes first.
const URL: &str = "https://speed.cloudflare.com/__down?bytes=10000000";
const CACHE: &str = "/var/db/netfuse/speeds.json";
const KEEP_SECS: u64 = 24 * 3600;

/// The network an adapter is on, roughly: its name and /24.
pub fn key(a: &Adapter) -> String {
    let o = a.ip.octets();
    format!("{} {}.{}.{}", a.name, o[0], o[1], o[2])
}

/// A cached result for this adapter and network, bytes/s.
pub fn cached(key: &str) -> Option<f64> {
    let (speed, at) = load().get(key).copied()?;
    (now().saturating_sub(at) < KEEP_SECS).then_some(speed)
}

/// Downloads through `adapter` (curl binds to it) and returns bytes/s; blocks for up to 3 s.
pub fn measure(adapter: &str, key: &str) -> Option<f64> {
    let out = Command::new("/usr/bin/curl")
        .args(["-s", "-o", "/dev/null", "-m", "3", "-w", "%{speed_download}", "--interface", adapter, URL])
        .output()
        .ok()?;
    // curl ends with "operation timed out" after 3 s on a slow link; its speed is still right
    let speed: f64 = String::from_utf8_lossy(&out.stdout).trim().parse().ok()?;
    if speed <= 0.0 {
        return None;
    }
    let mut all = load();
    all.retain(|_, (_, at)| now().saturating_sub(*at) < KEEP_SECS);
    all.insert(key.to_string(), (speed, now()));
    if let Some(dir) = Path::new(CACHE).parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let _ = std::fs::write(CACHE, serde_json::to_vec(&all).unwrap_or_default());
    Some(speed)
}

fn load() -> HashMap<String, (f64, u64)> {
    std::fs::read(CACHE).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
}

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs())
}
