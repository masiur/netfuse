//! Netfuse engine: sends every new connection out of one of the Mac's internet adapters, picked
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
mod sites;
mod speedtest;
mod tunnel;

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, RwLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use ipstack::{IpStack, IpStackConfig, IpStackStream};
use serde::{Deserialize, Serialize};

use sched::{Route, Scheduler, parse_route, route_text};

const USAGE: &str = "usage:
  sudo netfuse-engine run [--rules FILE] [--status FILE] [--for SECONDS] [--while FILE]
                                     capture and route traffic until Ctrl+C, the time is up,
                                     or FILE (the app's on switch) is gone
  netfuse-engine list                                       show the adapters it would use
  netfuse-engine phone                                      check an Android phone's USB tethering
  netfuse-engine rules [--rules FILE]                       show the rules it would apply";

const STATUS_PATH: &str = "/var/run/netfuse/status.json";

pub struct State {
    pub sched: Arc<Scheduler>,
    rules: RwLock<Rules>,
}

/// What rules.json says: per-app routes, and the route for apps without one.
#[derive(Default)]
struct Rules {
    apps: HashMap<String, Route>,
    /// Per-site routes (domain, route); they win over the app's.
    sites: Vec<(String, Route)>,
    default: Route,
    disabled: Vec<String>,
    /// Keep capturing while a VPN is up (its traffic then skips the VPN). Off: step aside.
    keep_with_vpn: bool,
}

impl Rules {
    /// Some app's route names the VPN.
    fn uses_vpn(&self) -> bool {
        self.apps.values().chain(self.sites.iter().map(|(_, r)| r)).flatten().flatten().any(|a| a.eq_ignore_ascii_case(adapters::VPN))
    }
}

impl State {
    /// The app behind a flow, "" when it cannot be found. Only looked up when there are rules.
    pub async fn app_for(&self, tcp: bool, port: u16) -> String {
        if !self.has_rules() {
            return String::new();
        }
        tokio::task::spawn_blocking(move || owner::app_for_port(tcp, port)).await.ok().flatten().unwrap_or_default()
    }

    fn has_rules(&self) -> bool {
        let r = self.rules.read().unwrap();
        !r.apps.is_empty() || !r.sites.is_empty()
    }

    pub fn has_sites(&self) -> bool { !self.rules.read().unwrap().sites.is_empty() }

    /// A site rule for `host` first, then the app's, then the default.
    pub fn route_for(&self, app: &str, host: Option<&str>) -> Route {
        let r = self.rules.read().unwrap();
        host.and_then(|h| sites::best(&r.sites, h))
            .or_else(|| r.apps.get(app))
            .cloned()
            .unwrap_or_else(|| r.default.clone())
    }
}

#[derive(Deserialize)]
struct RulesFile {
    #[serde(default)]
    rules: HashMap<String, String>,
    /// Per-site routes: {"youtube.com": "vpn"}.
    #[serde(default)]
    sites: HashMap<String, String>,
    /// Adapters switched off in the app: no flow uses them.
    #[serde(default)]
    disabled: Vec<String>,
    /// Priority order: apps without a rule use the first working adapter in it, then the next.
    /// Empty = combine every adapter.
    #[serde(default)]
    order: Vec<String>,
    #[serde(default)]
    keep_with_vpn: bool,
}

/// "en4 > en0 > *": each adapter in turn, then anything left.
fn order_route(order: &[String]) -> Route {
    if order.is_empty() {
        return Route::new();
    }
    order.iter().map(|a| vec![a.clone()]).chain([vec!["*".to_string()]]).collect()
}

/// Reads rules.json. A missing file is no rules; a route that does not parse is skipped.
fn load_rules(path: &Path) -> Rules {
    let Ok(text) = std::fs::read_to_string(path) else { return Rules::default() };
    let file: RulesFile = match serde_json::from_str(&text) {
        Ok(f) => f,
        Err(e) => {
            eprintln!("{}: {e} (no rules applied)", path.display());
            return Rules::default();
        }
    };
    let parse = |(name, r): (String, String)| match parse_route(&r) {
        Ok(route) if !route.is_empty() => Some((name, route)),
        Ok(_) => None,
        Err(e) => {
            eprintln!("{}: {name}: {e} (skipped)", path.display());
            None
        }
    };
    let apps = file.rules.into_iter().filter_map(parse).collect();
    let sites = file.sites.into_iter().filter_map(|(d, r)| Some((sites::normalize(&d)?, r))).filter_map(parse).collect();
    Rules { apps, sites, default: order_route(&file.order), disabled: file.disabled, keep_with_vpn: file.keep_with_vpn }
}

/// The menu-bar app saves rules for the user who runs it; under sudo that is SUDO_USER.
fn default_rules_path() -> PathBuf {
    let home = match std::env::var("SUDO_USER") {
        Ok(user) if !user.is_empty() => PathBuf::from("/Users").join(user),
        _ => PathBuf::from(std::env::var("HOME").unwrap_or_default()),
    };
    home.join("Library/Application Support/Netfuse/rules.json")
}

#[derive(Serialize)]
struct Status {
    pid: u32,
    updated: u64,
    tunnel: String,
    vpn: Option<String>, // a VPN is up and the engine stepped aside for it
    adapters: Vec<sched::AdapterStatus>,
    apps: Vec<sched::AppFlows>,
}

fn write_status(path: &Path, st: &State, tunnel: &str, vpn: Option<&str>) {
    let (mut adapters, apps) = st.sched.snapshot();
    if let Some((name, label)) = phone::label() {
        adapters.iter_mut().filter(|a| a.name == name).for_each(|a| a.label = Some(label.clone()));
    }
    let s = Status {
        pid: std::process::id(),
        updated: SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs()),
        tunnel: tunnel.to_string(),
        vpn: vpn.map(str::to_string),
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
            if args.get(1).is_some_and(|a| a == "--reset") {
                if let Some((info, _, _)) = rndis::find() {
                    println!("resetting the phone's USB connection: {:?}", rndis::reset(&info).await);
                    tokio::time::sleep(Duration::from_secs(4)).await;
                }
            }
            if let Err(e) = phone::probe().await {
                eprintln!("error: {e}");
                std::process::exit(1);
            }
        }
        Some("rules") => {
            println!("{}", rules_path.display());
            let loaded = load_rules(&rules_path);
            println!("default: {}  disabled: {:?}", route_text(&loaded.default), loaded.disabled);
            let mut rules: Vec<_> = loaded.apps.into_iter().chain(loaded.sites.into_iter().map(|(d, r)| (format!("site {d}"), r))).collect();
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
        return Err(std::io::Error::other("needs root: sudo netfuse-engine run"));
    }
    let rules = load_rules(&rules_path);
    let st = Arc::new(State { sched: Arc::new(Scheduler::default()), rules: RwLock::new(Rules::default()) });
    st.sched.set_disabled(rules.disabled.clone());
    *st.rules.write().unwrap() = rules;
    let found = adapters::discover();
    if found.is_empty() {
        return Err(std::io::Error::other("no adapter with internet found"));
    }
    for a in &found {
        println!("  + {} {}", a.name, a.ip);
    }
    st.sched.update(found);
    println!("rules: {} ({} apps)", rules_path.display(), st.rules.read().unwrap().apps.len());

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
    println!("Netfuse is ON through {name}. Ctrl+C to stop.");

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
        let mut tested = std::collections::HashSet::new(); // speedtest keys done this run
        let mut last = std::time::Instant::now();
        let mut aside = false; // our routes are out, leaving all traffic to the VPN
        loop {
            bg.sched.tick(last.elapsed().as_secs_f64().max(0.001));
            last = std::time::Instant::now();
            let vpn = tunnel::vpn(&tun_name); // the connected VPN's tunnel
            // Step aside for a VPN unless something wants to keep going: a rule that sends apps
            // through it, or the setting to keep combining beside it.
            let keep = { let r = bg.rules.read().unwrap(); r.keep_with_vpn || r.uses_vpn() };
            let step_aside = vpn.is_some() && !keep;
            if step_aside != aside {
                if step_aside {
                    println!("VPN on {}: stepping aside", vpn.as_deref().unwrap_or("?"));
                    tunnel::close_routes(&tun_name);
                    aside = true;
                } else {
                    match tunnel::add_routes(&tun_name) {
                        Ok(()) => {
                            println!("capturing again{}", if vpn.is_some() { " (VPN used by rules)" } else { "" });
                            aside = false;
                        }
                        Err(e) => eprintln!("warning: routes: {e}"), // tried again next second
                    }
                }
            }
            // While capturing beside a VPN, its server is reached directly, never through us.
            scoped::bypass(&if vpn.is_some() && !aside { tunnel::vpn_servers() } else { Vec::new() });
            if on_flag.as_ref().is_some_and(|f| !f.exists()) {
                off.notify_one();
                return;
            }
            if tick % 3 == 0 {
                let mut found = adapters::discover();
                if let (Some(v), false) = (&vpn, aside) {
                    if let Some(a) = adapters::vpn_adapter(v) {
                        scoped::tunnel_default(v);
                        found.push(a);
                    }
                }
                bg.sched.update(found.clone());
                for a in found {
                    let key = speedtest::key(&a);
                    if !tested.insert(key.clone()) {
                        continue;
                    }
                    if let Some(speed) = speedtest::cached(&key) {
                        bg.sched.tested(&a.name, speed);
                        continue;
                    }
                    let sched = bg.sched.clone();
                    tokio::task::spawn_blocking(move || {
                        if let Some(speed) = speedtest::measure(&a.name, &key) {
                            println!("{}: download test {:.0} Mbit/s", a.name, speed * 8.0 / 1e6);
                            sched.tested(&a.name, speed);
                        }
                    });
                }
                if let Err(e) = scoped::sync() {
                    eprintln!("warning: scoped routes: {e}");
                }
            }
            let m = std::fs::metadata(&rules_path).and_then(|m| m.modified()).ok();
            if m != mtime {
                mtime = m;
                let rules = load_rules(&rules_path);
                if tick > 0 {
                    println!("rules reloaded ({} apps, {} sites)", rules.apps.len(), rules.sites.len());
                }
                bg.sched.set_disabled(rules.disabled.clone());
                *bg.rules.write().unwrap() = rules;
            }
            write_status(&status_for_bg, &bg, &tun_name, vpn.as_deref().filter(|_| aside));
            tick += 1;
            tokio::time::sleep(Duration::from_secs(1)).await;
        }
    });

    let mut cfg = IpStackConfig::default();
    cfg.mtu(tunnel::MTU).map_err(std::io::Error::other)?;
    // The stack has no window scaling, so 64 KB is the most a flow can have in flight to the app
    // and the most it can be sent; the 16 KB defaults cap each flow at a quarter of that.
    let mut tcp = ipstack::TcpConfig::default();
    tcp.max_unacked_bytes = u16::MAX.into();
    tcp.read_buffer_size = u16::MAX.into();
    cfg.tcp_config = Arc::new(tcp);
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
    println!("Netfuse is OFF.");
    std::process::exit(0); // don't wait for open flows: their routes are gone
}


#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn order_becomes_failover_route() {
        assert_eq!(route_text(&order_route(&[])), "auto");
        assert_eq!(route_text(&order_route(&["en4".into(), "en0".into()])), "en4 > en0 > *");
    }
}
