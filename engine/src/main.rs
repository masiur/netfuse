//! Nethance engine: sends every new connection out of one of the Mac's internet adapters, picked
//! per app from the menu-bar app's rules.json.

mod adapters;
mod dhcp;
mod feth;
mod owner;
mod phone;
mod relay;
mod rndis;
mod sched;
mod scoped;
mod tunnel;

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, RwLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use ipstack::{IpStack, IpStackConfig, IpStackStream};
use serde::{Deserialize, Serialize};

use sched::{Route, Scheduler, parse_route, route_text};

const USAGE: &str = "usage:
  sudo nethance-engine run [--rules FILE] [--status FILE] [--for SECONDS] [--while FILE]
                                     capture and route traffic until Ctrl+C, the time is up,
                                     or FILE (the app's on switch) is gone
  nethance-engine list                                       show the adapters it would use
  nethance-engine phone                                      check an Android phone's USB tethering
  nethance-engine rules [--rules FILE]                       show the rules it would apply";

const STATUS_PATH: &str = "/var/run/nethance/status.json";

pub struct State {
    pub sched: Arc<Scheduler>,
    rules: RwLock<HashMap<String, Route>>,
}

impl State {
    /// The app behind a flow, "" when it cannot be found. Only looked up when there are rules.
    pub async fn app_for(&self, tcp: bool, port: u16) -> String {
        if self.rules.read().unwrap().is_empty() {
            return String::new();
        }
        tokio::task::spawn_blocking(move || owner::app_for_port(tcp, port)).await.ok().flatten().unwrap_or_default()
    }

    pub fn route_for(&self, app: &str) -> Route {
        self.rules.read().unwrap().get(app).cloned().unwrap_or_default()
    }
}

#[derive(Deserialize)]
struct RulesFile {
    rules: HashMap<String, String>,
}

/// Reads rules.json. A missing file is no rules; a route that does not parse is skipped.
fn load_rules(path: &Path) -> HashMap<String, Route> {
    let Ok(text) = std::fs::read_to_string(path) else { return HashMap::new() };
    let file: RulesFile = match serde_json::from_str(&text) {
        Ok(f) => f,
        Err(e) => {
            eprintln!("{}: {e} (no rules applied)", path.display());
            return HashMap::new();
        }
    };
    file.rules
        .into_iter()
        .filter_map(|(app, r)| match parse_route(&r) {
            Ok(route) if !route.is_empty() => Some((app, route)),
            Ok(_) => None,
            Err(e) => {
                eprintln!("{}: {app}: {e} (skipped)", path.display());
                None
            }
        })
        .collect()
}

/// The menu-bar app saves rules for the user who runs it; under sudo that is SUDO_USER.
fn default_rules_path() -> PathBuf {
    let home = match std::env::var("SUDO_USER") {
        Ok(user) if !user.is_empty() => PathBuf::from("/Users").join(user),
        _ => PathBuf::from(std::env::var("HOME").unwrap_or_default()),
    };
    home.join("Library/Application Support/Nethance/rules.json")
}

#[derive(Serialize)]
struct Status {
    pid: u32,
    updated: u64,
    tunnel: String,
    adapters: Vec<sched::AdapterStatus>,
    apps: Vec<sched::AppFlows>,
}

fn write_status(path: &Path, st: &State, tunnel: &str) {
    let (mut adapters, apps) = st.sched.snapshot();
    if let Some((name, label)) = phone::label() {
        adapters.iter_mut().filter(|a| a.name == name).for_each(|a| a.label = Some(label.clone()));
    }
    let s = Status {
        pid: std::process::id(),
        updated: SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs()),
        tunnel: tunnel.to_string(),
        adapters,
        apps,
    };
    let tmp = path.with_extension("tmp");
    if let Ok(json) = serde_json::to_vec_pretty(&s) {
        if std::fs::write(&tmp, json).is_ok() {
            let _ = std::fs::rename(&tmp, path);
        }
    }
}

fn flag(args: &[String], name: &str) -> Option<PathBuf> {
    args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).map(PathBuf::from)
}

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let rules_path = flag(&args, "--rules").unwrap_or_else(default_rules_path);
    match args.first().map(String::as_str) {
        Some("list") => {
            for a in adapters::discover() {
                println!("{:<8} {:<16} index {}", a.name, a.ip, a.index);
            }
        }
        Some("phone") => {
            if let Err(e) = phone::probe().await {
                eprintln!("error: {e}");
                std::process::exit(1);
            }
        }
        Some("rules") => {
            println!("{}", rules_path.display());
            let mut rules: Vec<_> = load_rules(&rules_path).into_iter().collect();
            rules.sort();
            for (app, r) in rules {
                println!("  {app:<24} {}", route_text(&r));
            }
        }
        Some("run") => {
            let status = flag(&args, "--status").unwrap_or_else(|| PathBuf::from(STATUS_PATH));
            let limit = flag(&args, "--for").and_then(|p| p.to_str()?.parse().ok()).map(Duration::from_secs);
            if let Err(e) = run(rules_path, status, limit, flag(&args, "--while")).await {
                eprintln!("error: {e}");
                std::process::exit(1);
            }
        }
        _ => {
            eprintln!("{USAGE}");
            std::process::exit(2);
        }
    }
}

async fn run(rules_path: PathBuf, status_path: PathBuf, limit: Option<Duration>, on_flag: Option<PathBuf>) -> std::io::Result<()> {
    if unsafe { libc::geteuid() } != 0 {
        return Err(std::io::Error::other("needs root: sudo nethance-engine run"));
    }
    let st = Arc::new(State { sched: Arc::new(Scheduler::default()), rules: RwLock::new(load_rules(&rules_path)) });
    let found = adapters::discover();
    if found.is_empty() {
        return Err(std::io::Error::other("no adapter with internet found"));
    }
    for a in &found {
        println!("  + {} {}", a.name, a.ip);
    }
    st.sched.update(found);
    println!("rules: {} ({} apps)", rules_path.display(), st.rules.read().unwrap().len());

    // Scoped defaults first: once the utun's routes are in, bound sockets need them to get out.
    if let Err(e) = scoped::sync() {
        scoped::restore();
        return Err(std::io::Error::other(format!("scoped routes: {e}")));
    }
    phone::stop(); // a phone adapter left by a crash
    tokio::spawn(phone::run());
    let tun = match tunnel::open() {
        Ok(t) => t,
        Err(e) => {
            scoped::restore();
            return Err(e);
        }
    };
    let name = tun.name.clone();
    println!("Nethance is ON through {name}. Ctrl+C to stop.");

    if let Some(dir) = status_path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    // Background: adapter re-scan every 3 s, rules reload on change, status every second.
    let bg = st.clone();
    let tun_name = name.clone();
    let status_for_bg = status_path.clone();
    let switched_off = Arc::new(tokio::sync::Notify::new());
    let off = switched_off.clone();
    tokio::spawn(async move {
        let mut mtime = None;
        let mut tick = 0u64;
        loop {
            if on_flag.as_ref().is_some_and(|f| !f.exists()) {
                off.notify_one();
                return;
            }
            if tick % 3 == 0 {
                bg.sched.update(adapters::discover());
                if let Err(e) = scoped::sync() {
                    eprintln!("warning: scoped routes: {e}");
                }
            }
            let m = std::fs::metadata(&rules_path).and_then(|m| m.modified()).ok();
            if m != mtime {
                mtime = m;
                let rules = load_rules(&rules_path);
                if tick > 0 {
                    println!("rules reloaded ({} apps)", rules.len());
                }
                *bg.rules.write().unwrap() = rules;
            }
            write_status(&status_for_bg, &bg, &tun_name);
            tick += 1;
            tokio::time::sleep(Duration::from_secs(1)).await;
        }
    });

    let mut cfg = IpStackConfig::default();
    cfg.mtu(tunnel::MTU).map_err(std::io::Error::other)?;
    let mut stack = IpStack::new(cfg, tun.io);
    let mut sigterm = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
    let stop_at = tokio::time::Instant::now() + limit.unwrap_or(Duration::from_secs(1 << 40));
    loop {
        tokio::select! {
            s = stack.accept() => match s {
                Ok(IpStackStream::Tcp(t)) if t.peer_addr().is_ipv4() => { tokio::spawn(relay::tcp(t, st.clone())); }
                Ok(IpStackStream::Udp(u)) if u.peer_addr().is_ipv4() => { tokio::spawn(relay::udp(u, st.clone())); }
                Ok(_) => {} // IPv6 is not routed to the utun; ICMP and others are dropped
                Err(e) => { eprintln!("stack: {e}"); break; }
            },
            _ = tokio::signal::ctrl_c() => break,
            _ = sigterm.recv() => break,
            _ = switched_off.notified() => {
                println!("switched off in the app");
                break;
            }
            _ = tokio::time::sleep_until(stop_at), if limit.is_some() => {
                println!("--for time is up");
                break;
            }
        }
    }
    tunnel::close_routes(&name);
    phone::stop();
    scoped::restore();
    let _ = std::fs::remove_file(&status_path);
    println!("Nethance is OFF.");
    std::process::exit(0); // don't wait for open flows: their routes are gone
}

