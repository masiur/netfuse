//! Finds which app opened a flow, from the flow's local port, so per-app rules can pick its adapter.

use std::collections::HashMap;
use std::ffi::CStr;
use std::os::raw::{c_char, c_int};
use std::sync::{LazyLock, Mutex};

unsafe extern "C" {
    fn nethance_has_port(pid: c_int, tcp: c_int, lport: c_int) -> c_int;
    fn nethance_find_pid(tcp: c_int, lport: c_int, this: c_int) -> c_int;
    fn nethance_pid_path(pid: c_int, buf: *mut c_char, size: c_int) -> c_int;
}

const RECENT_MAX: usize = 16;
const PATH_MAX: usize = 4 * 1024; // PROC_PIDPATHINFO_MAXSIZE

struct Cache {
    recent: Vec<i32>,           // pids that owned recent flows, newest first: apps open many flows
    names: HashMap<i32, String>, // pid -> app name
}

static CACHE: LazyLock<Mutex<Cache>> = LazyLock::new(|| Mutex::new(Cache { recent: Vec::new(), names: HashMap::new() }));

/// Names the app holding a TCP (`tcp`) or UDP socket on `port`, or None if none is found (the socket
/// is already gone, or this process lacks the rights to see it). Blocking: a miss scans every
/// process (a few ms), so call it from `spawn_blocking`.
/// ponytail: one global lock and a full scan per miss; a per-port cache or Apple's
/// NETransparentProxyProvider (which hands over the app's identity) if this shows in profiles.
pub fn app_for_port(tcp: bool, port: u16) -> Option<String> {
    let t = tcp as c_int;
    let me = std::process::id() as c_int;
    let mut c = CACHE.lock().unwrap();
    let hit = c.recent.iter().position(|&p| unsafe { nethance_has_port(p, t, port as c_int) } != 0);
    let pid = match hit {
        Some(i) => c.recent.remove(i),
        None => match unsafe { nethance_find_pid(t, port as c_int, me) } {
            0 => return None,
            p => p,
        },
    };
    c.recent.insert(0, pid);
    c.recent.truncate(RECENT_MAX);
    if let Some(n) = c.names.get(&pid) {
        return Some(n.clone());
    }
    let mut buf = vec![0 as c_char; PATH_MAX];
    if unsafe { nethance_pid_path(pid, buf.as_mut_ptr(), PATH_MAX as c_int) } <= 0 {
        return None;
    }
    let path = unsafe { CStr::from_ptr(buf.as_ptr()) }.to_string_lossy().into_owned();
    let name = app_name(&path);
    if c.names.len() > 4096 {
        c.names.clear(); // pids get reused; a clear now and then keeps stale names rare
    }
    c.names.insert(pid, name.clone());
    Some(name)
}

/// The name a rule uses: the outermost .app bundle's name ("/Applications/Google Chrome.app/.../
/// Google Chrome Helper.app/..." -> "Google Chrome"), so helpers share the app's rule; else the
/// executable's name ("curl"). The menu-bar app derives names the same way.
pub fn app_name(path: &str) -> String {
    let p = match path.find(".app/") {
        Some(i) => &path[..i],
        None => path,
    };
    p.rsplit('/').next().unwrap_or(p).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names() {
        assert_eq!(app_name("/Applications/Google Chrome.app/Contents/Frameworks/X.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"), "Google Chrome");
        assert_eq!(app_name("/usr/bin/curl"), "curl");
    }

    #[test]
    fn finds_a_socket_of_another_process() {
        // A child process holds the socket; the lookup skips its own process.
        let mut child = std::process::Command::new("/usr/bin/nc").args(["-l", "127.0.0.1", "47123"]).spawn().unwrap();
        std::thread::sleep(std::time::Duration::from_millis(300));
        let got = app_for_port(true, 47123);
        child.kill().ok();
        assert_eq!(got.as_deref(), Some("nc"));
        assert_eq!(app_for_port(true, 47124), None);
    }
}
