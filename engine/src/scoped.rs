//! Scoped default routes, so sockets bound to an adapter still reach the internet while the utun
//! captures everything else.
//!
//! A socket bound with IP_BOUND_IF only sees routes scoped to its adapter. macOS keeps a scoped
//! default for every service except the primary one, which has only the unscoped default; with the
//! utun's /1 routes in place, a bound lookup on the primary adapter then finds no way out ("no
//! route to host" and the Mac is offline). So every adapter with an unscoped default also gets a
//! scoped copy while the engine runs, kept in step with gateway changes. (net-merge does the same.)

use std::collections::{HashMap, HashSet};
use std::process::Command;
use std::sync::Mutex;

use crate::adapters::is_hardware;

/// Scoped defaults we added: adapter -> gateway.
static ADDED: Mutex<Option<HashMap<String, String>>> = Mutex::new(None);

struct DefaultRoute {
    netif: String,
    gateway: Option<String>, // None for "link#N" defaults (tunnels, bridges)
    scoped: bool,            // flag I
}

/// IPv4 default routes, from `netstat -rn -f inet`.
fn default_routes() -> std::io::Result<Vec<DefaultRoute>> {
    let out = Command::new("/usr/sbin/netstat").args(["-rn", "-f", "inet"]).output()?;
    Ok(parse_netstat(&String::from_utf8_lossy(&out.stdout)))
}

fn parse_netstat(text: &str) -> Vec<DefaultRoute> {
    text.lines()
        .filter_map(|line| {
            let f: Vec<&str> = line.split_whitespace().collect();
            if f.len() < 4 || f[0] != "default" {
                return None;
            }
            let gateway = f[1].parse::<std::net::Ipv4Addr>().ok().map(|g| g.to_string());
            Some(DefaultRoute { netif: f[3].to_string(), gateway, scoped: f[2].contains('I') })
        })
        .collect()
}

fn route(verb: &str, netif: &str, gw: &str) -> Result<(), String> {
    let out = Command::new("/sbin/route")
        .args(["-q", "-n", verb, "-inet", "default", gw, "-ifscope", netif])
        .output()
        .map_err(|e| e.to_string())?;
    let err = String::from_utf8_lossy(&out.stderr);
    if out.status.success() || err.contains("File exists") { Ok(()) } else { Err(err.trim().to_string()) }
}

/// Adds or updates the scoped defaults. Called at start (an error there is fatal: without them
/// the Mac would go offline) and then every few seconds.
pub fn sync() -> Result<(), String> {
    let routes = default_routes().map_err(|e| e.to_string())?;
    let mut want = HashMap::new(); // primary-style adapters: unscoped default with a gateway
    let mut have = HashSet::new(); // adapters that already have a scoped default
    for r in routes.iter().filter(|r| is_hardware(&r.netif)) {
        match (&r.gateway, r.scoped) {
            (_, true) => {
                have.insert(r.netif.clone());
            }
            (Some(gw), false) => {
                want.insert(r.netif.clone(), gw.clone());
            }
            _ => {}
        }
    }
    let mut guard = ADDED.lock().unwrap();
    let added = guard.get_or_insert_with(HashMap::new);
    let mut first_err = None;
    for (netif, gw) in &want {
        match added.get(netif) {
            Some(old) if old == gw && have.contains(netif) => continue,
            None if have.contains(netif) => continue, // macOS keeps its own scoped default here
            Some(old) => {
                let _ = route("delete", netif, old);
            }
            None => {}
        }
        match route("add", netif, gw) {
            Ok(()) => {
                added.insert(netif.clone(), gw.clone());
            }
            Err(e) => {
                added.remove(netif);
                first_err.get_or_insert(format!("{netif}: {e}"));
            }
        }
    }
    // An adapter that stopped being primary: macOS now wants a scoped default there itself, and ours
    // already stands in its place, so leave it rather than cut the adapter off until it reconnects.
    added.retain(|netif, _| want.contains_key(netif));
    first_err.map_or(Ok(()), Err)
}

/// A scoped default on a VPN's tunnel, so sockets bound to it (apps routed to "vpn") get out.
/// VPNs only install an unscoped default. It goes away with the tunnel.
pub fn tunnel_default(netif: &str) {
    let _ = Command::new("/sbin/route")
        .args(["-q", "-n", "add", "-inet", "default", "-interface", netif, "-ifscope", netif])
        .output();
}

/// Host routes sending VPN servers straight out a real adapter, past the engine: server -> gateway.
static BYPASS: Mutex<Option<HashMap<std::net::Ipv4Addr, String>>> = Mutex::new(None);

/// Keeps one host route per VPN server via the first hardware adapter's gateway, so the VPN's own
/// encrypted traffic is never captured. An empty list removes them.
pub fn bypass(servers: &[std::net::Ipv4Addr]) {
    if servers.is_empty() && BYPASS.lock().unwrap().as_ref().is_none_or(HashMap::is_empty) {
        return; // the usual case, every second: no VPN, nothing to do
    }
    let gw = default_routes().unwrap_or_default().into_iter()
        .find(|r| is_hardware(&r.netif) && !r.scoped && r.gateway.is_some())
        .or_else(|| default_routes().unwrap_or_default().into_iter().find(|r| is_hardware(&r.netif) && r.gateway.is_some()))
        .and_then(|r| r.gateway);
    let mut guard = BYPASS.lock().unwrap();
    let have = guard.get_or_insert_with(HashMap::new);
    let host = |verb: &str, ip: &std::net::Ipv4Addr, gw: &str| {
        let _ = Command::new("/sbin/route").args(["-q", "-n", verb, "-host", &ip.to_string(), gw]).output();
    };
    have.retain(|ip, old| {
        let keep = servers.contains(ip) && gw.as_deref() == Some(old.as_str());
        if !keep { host("delete", ip, old); }
        keep
    });
    if let Some(gw) = gw {
        let new: Vec<_> = servers.iter().filter(|ip| !have.contains_key(ip)).copied().collect();
        for ip in &new {
            host("add", ip, &gw);
            have.insert(*ip, gw.clone());
        }
    }
}

/// Removes the scoped defaults we added where the adapter is still primary (elsewhere macOS
/// relies on them). ponytail: a crash leaves them behind; harmless duplicates of the primary
/// default, cleaned at the next stop.
pub fn restore() {
    bypass(&[]);
    let primary: HashSet<String> = default_routes()
        .unwrap_or_default()
        .into_iter()
        .filter(|r| !r.scoped && r.gateway.is_some())
        .map(|r| r.netif)
        .collect();
    if let Some(added) = ADDED.lock().unwrap().take() {
        for (netif, gw) in added {
            if primary.contains(&netif) {
                let _ = route("delete", &netif, &gw);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_netstat_defaults() {
        let text = "Routing tables\n\nInternet:\nDestination        Gateway            Flags               Netif Expire\n\
                    default            192.168.1.1        UGScg                en10\n\
                    default            10.10.50.1         UGScIg                en0\n\
                    default            link#29            UCSIg           bridge100      !\n\
                    10.10.50/24        link#14            UCS                   en0      !\n";
        let r = parse_netstat(text);
        assert_eq!(r.len(), 3);
        assert_eq!((r[0].netif.as_str(), r[0].gateway.as_deref(), r[0].scoped), ("en10", Some("192.168.1.1"), false));
        assert_eq!((r[1].netif.as_str(), r[1].scoped), ("en0", true));
        assert_eq!(r[2].gateway, None);
    }
}
