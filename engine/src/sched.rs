//! Picks an adapter for each new flow: per-app routes, least busy within a route tier, and a
//! cooldown for adapters whose link just failed.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde::Serialize;

use crate::adapters::Adapter;

/// Where one app's flows may go: tiers tried in order, flows balanced inside a tier. An entry is an
/// adapter name ("en0") or "*" (every adapter). A tier is used while any of its adapters works;
/// without a "*" tier an app is held to its adapters and gets no internet when they are all gone.
/// Empty = every adapter, what apps without a rule get. Text form: "en4", "en4 > *", "en0+en4 > en7".
pub type Route = Vec<Vec<String>>;

pub fn parse_route(s: &str) -> Result<Route, String> {
    let s = s.trim();
    if s.is_empty() {
        return Err("empty route".into());
    }
    if s.eq_ignore_ascii_case("auto") || s == "*" {
        return Ok(Route::new());
    }
    s.split('>')
        .map(|tier| {
            tier.split('+')
                .map(|a| match a.trim() {
                    "" => Err(format!("route {s:?}: empty adapter name")),
                    a => Ok(a.to_string()),
                })
                .collect()
        })
        .collect()
}

pub fn route_text(r: &Route) -> String {
    if r.is_empty() {
        return "auto".into();
    }
    r.iter().map(|t| t.join("+")).collect::<Vec<_>>().join(" > ")
}

struct Slot {
    adapter: Adapter,
    present: bool,
    active: u32,
    total: u64,
    failed: u64,
    down_until: Option<Instant>,
}

#[derive(Default)]
struct Inner {
    slots: Vec<Slot>,
    apps: HashMap<(String, String), u32>, // (app, adapter) -> open flows
    turn: usize,                          // rotates the starting point so ties spread out
}

#[derive(Default)]
pub struct Scheduler(Mutex<Inner>);

/// An adapter handed to one flow. Dropping it ends the flow's claim.
pub struct Lease {
    pub adapter: Adapter,
    app: String,
    sched: Arc<Scheduler>,
}

impl Drop for Lease {
    fn drop(&mut self) {
        let mut s = self.sched.0.lock().unwrap();
        if let Some(sl) = s.slots.iter_mut().find(|sl| sl.adapter.name == self.adapter.name) {
            sl.active -= 1;
        }
        let key = (self.app.clone(), self.adapter.name.clone());
        if let Some(n) = s.apps.get_mut(&key) {
            *n -= 1;
            if *n == 0 {
                s.apps.remove(&key);
            }
        }
        s.slots.retain(|sl| sl.present || sl.active > 0);
    }
}

#[derive(Serialize)]
pub struct AdapterStatus {
    pub name: String,
    pub ip: String,
    pub active: u32,
    pub total: u64,
    pub failed: u64,
    pub cooling_down: bool,
    /// A display name when macOS has none for it (the phone's model, "HONOR DNY-NX9").
    #[serde(skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
}

#[derive(Serialize)]
pub struct AppFlows {
    pub app: String,
    pub adapter: String,
    pub flows: u32,
}

impl Scheduler {
    /// Applies a re-scan: keeps counters of known adapters, picks up new addresses and adapters,
    /// and drops vanished ones once their last flow ends.
    pub fn update(&self, adapters: Vec<Adapter>) {
        let mut s = self.0.lock().unwrap();
        for sl in &mut s.slots {
            sl.present = false;
        }
        for a in adapters {
            match s.slots.iter_mut().find(|sl| sl.adapter.name == a.name) {
                Some(sl) => {
                    sl.present = true;
                    sl.adapter = a;
                }
                None => s.slots.push(Slot { adapter: a, present: true, active: 0, total: 0, failed: 0, down_until: None }),
            }
        }
        s.slots.retain(|sl| sl.present || sl.active > 0);
    }

    /// Picks an adapter for a new flow of `app`: the first route tier with a working adapter, the
    /// least busy adapter in it. Adapters in `skip` (already failed for this flow) are left out.
    /// When every allowed adapter is cooling down the flow still gets one rather than none.
    pub fn acquire(self: &Arc<Self>, route: &Route, skip: &[String], app: &str) -> Option<Lease> {
        let every = vec![vec!["*".to_string()]];
        let route = if route.is_empty() { &every } else { route };
        let mut s = self.0.lock().unwrap();
        let now = Instant::now();
        let (mut pool, mut dead) = (Vec::new(), Vec::new());
        for tier in route {
            let allowed = |sl: &Slot| {
                sl.present
                    && !skip.contains(&sl.adapter.name)
                    && tier.iter().any(|t| t == "*" || t.eq_ignore_ascii_case(&sl.adapter.name))
            };
            let (up, down): (Vec<usize>, Vec<usize>) = (0..s.slots.len())
                .filter(|&i| allowed(&s.slots[i]))
                .partition(|&i| s.slots[i].down_until.is_none_or(|t| t <= now));
            if !up.is_empty() {
                pool = up;
                break;
            }
            if dead.is_empty() {
                dead = down;
            }
        }
        if pool.is_empty() {
            pool = dead;
        }
        if pool.is_empty() {
            return None;
        }
        s.turn = s.turn.wrapping_add(1);
        let start = s.turn % pool.len();
        let i = (0..pool.len()).map(|k| pool[(start + k) % pool.len()]).min_by_key(|&i| s.slots[i].active)?;
        let sl = &mut s.slots[i];
        sl.active += 1;
        sl.total += 1;
        let adapter = sl.adapter.clone();
        *s.apps.entry((app.to_string(), adapter.name.clone())).or_default() += 1;
        Some(Lease { adapter, app: app.to_string(), sched: self.clone() })
    }

    /// Sidelines an adapter whose link itself failed (no route, network down) for a while.
    pub fn fail(&self, name: &str, cooldown: Duration) {
        let mut s = self.0.lock().unwrap();
        if let Some(sl) = s.slots.iter_mut().find(|sl| sl.adapter.name == name) {
            sl.down_until = Some(Instant::now() + cooldown);
            sl.failed += 1;
        }
    }

    pub fn snapshot(&self) -> (Vec<AdapterStatus>, Vec<AppFlows>) {
        let s = self.0.lock().unwrap();
        let now = Instant::now();
        let adapters = s
            .slots
            .iter()
            .filter(|sl| sl.present)
            .map(|sl| AdapterStatus {
                name: sl.adapter.name.clone(),
                ip: sl.adapter.ip.to_string(),
                active: sl.active,
                total: sl.total,
                failed: sl.failed,
                cooling_down: sl.down_until.is_some_and(|t| t > now),
                label: None,
            })
            .collect();
        let mut apps: Vec<AppFlows> =
            s.apps.iter().map(|((app, adapter), &flows)| AppFlows { app: app.clone(), adapter: adapter.clone(), flows }).collect();
        apps.sort_by(|a, b| (&a.app, &a.adapter).cmp(&(&b.app, &b.adapter)));
        (adapters, apps)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    fn ad(name: &str, last: u8) -> Adapter {
        Adapter { name: name.into(), index: 1, ip: [10, 0, 0, last].into() }
    }

    #[test]
    fn route_text_round_trips() {
        for (input, want) in [("en4", "en4"), (" en4 >  * ", "en4 > *"), ("en0+en4 > en7", "en0+en4 > en7"), ("auto", "auto"), ("*", "auto")] {
            assert_eq!(route_text(&parse_route(input).unwrap()), want, "{input}");
        }
        for bad in ["", "en0 >", "+en0", "en0 > > en4"] {
            assert!(parse_route(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn routes_pick_tiers_in_order() {
        let s = Arc::new(Scheduler::default());
        s.update(vec![ad("en0", 1), ad("en4", 2), ad("en7", 3)]);
        let picks = |route: &str| -> HashSet<String> {
            let r = parse_route(route).unwrap();
            (0..30).map(|_| s.acquire(&r, &[], "x").map_or("none".into(), |l| l.adapter.name.clone())).collect()
        };
        let set = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<HashSet<_>>();
        assert_eq!(picks("en4"), set(&["en4"]));
        assert_eq!(picks("en0+en4 > en7"), set(&["en0", "en4"]));
        assert_eq!(picks("auto"), set(&["en0", "en4", "en7"]));

        s.update(vec![ad("en0", 1), ad("en7", 3)]); // Ethernet unplugged
        assert_eq!(picks("en4"), set(&["none"]));
        assert_eq!(picks("en4 > en7"), set(&["en7"]));

        s.fail("en0", Duration::from_secs(60)); // Wi-Fi link broke
        assert_eq!(picks("en0 > *"), set(&["en7"]));
        assert_eq!(picks("en0"), set(&["en0"])); // nothing else allowed: still try it
    }

    #[test]
    fn leases_balance_and_count_per_app() {
        let s = Arc::new(Scheduler::default());
        s.update(vec![ad("en0", 1), ad("en4", 2)]);
        let a = s.acquire(&Route::new(), &[], "Safari").unwrap();
        let b = s.acquire(&Route::new(), &[], "Safari").unwrap();
        assert_ne!(a.adapter.name, b.adapter.name, "two flows should land on two adapters");
        let (_, apps) = s.snapshot();
        assert_eq!(apps.iter().map(|f| f.flows).sum::<u32>(), 2);
        drop((a, b));
        let (adapters, apps) = s.snapshot();
        assert!(apps.is_empty());
        assert!(adapters.iter().all(|a| a.active == 0 && a.total == 1));
    }
}
