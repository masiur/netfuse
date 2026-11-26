//! Which network adapters can carry internet traffic right now.

use std::collections::HashSet;
use std::ffi::{CStr, c_void};
use std::net::Ipv4Addr;

use system_configuration::core_foundation::base::{CFType, TCFType};
use system_configuration::core_foundation::dictionary::CFDictionary;
use system_configuration::core_foundation::string::CFString;
use system_configuration::dynamic_store::SCDynamicStoreBuilder;

#[derive(Clone, Debug, PartialEq)]
pub struct Adapter {
    pub name: String, // BSD name, "en0": what rules use
    pub index: u32,   // interface index, for IP_BOUND_IF
    pub ip: Ipv4Addr,
}

/// Real hardware (enN; fethN is how TetherKit shows an Android USB tether) that is up, has an IPv4
/// address and a router. Tunnels, VPNs, bridges and our own utun are left out, which also keeps
/// our outbound sockets from looping back into the engine.
pub fn discover() -> Vec<Adapter> {
    let routers = interfaces_with_router();
    let mut out: Vec<Adapter> = ipv4_addresses()
        .into_iter()
        .filter(|(name, _, _)| is_hardware(name) && routers.contains(name))
        .map(|(name, index, ip)| Adapter { name, index, ip })
        .chain(crate::phone::adapter()) // an Android phone the engine drives itself
        .collect();
    out.sort_by(|a, b| a.name.cmp(&b.name));
    out.dedup_by(|a, b| a.name == b.name); // one address per adapter is enough
    out
}

pub fn is_hardware(name: &str) -> bool {
    let digits = name.strip_prefix("feth").or_else(|| name.strip_prefix("en"));
    digits.is_some_and(|d| !d.is_empty() && d.bytes().all(|b| b.is_ascii_digit()))
}

/// (name, index, address) of every up interface with a non-link-local IPv4 address.
fn ipv4_addresses() -> Vec<(String, u32, Ipv4Addr)> {
    let mut out = Vec::new();
    let mut head: *mut libc::ifaddrs = std::ptr::null_mut();
    if unsafe { libc::getifaddrs(&mut head) } != 0 {
        return out;
    }
    let mut p = head;
    while !p.is_null() {
        let ifa = unsafe { &*p };
        p = ifa.ifa_next;
        if ifa.ifa_addr.is_null() || ifa.ifa_flags & libc::IFF_UP as u32 == 0 {
            continue;
        }
        if unsafe { (*ifa.ifa_addr).sa_family } as i32 != libc::AF_INET {
            continue;
        }
        let sin = unsafe { &*(ifa.ifa_addr as *const libc::sockaddr_in) };
        let ip = Ipv4Addr::from(u32::from_be(sin.sin_addr.s_addr));
        if ip.is_link_local() || ip.is_loopback() {
            continue; // 169.254/16: no DHCP lease, no internet
        }
        let name = unsafe { CStr::from_ptr(ifa.ifa_name) }.to_string_lossy().into_owned();
        let index = unsafe { libc::if_nametoindex(ifa.ifa_name) };
        out.push((name, index, ip));
    }
    unsafe { libc::freeifaddrs(head) };
    out
}

/// Interfaces whose network service has an IPv4 router. macOS keeps a scoped default route for
/// each, so a socket bound to the interface (IP_BOUND_IF) reaches the internet through it.
fn interfaces_with_router() -> HashSet<String> {
    let mut out = HashSet::new();
    let Some(store) = SCDynamicStoreBuilder::new("netfuse-engine").build() else { return out };
    let Some(keys) = store.get_keys("State:/Network/Service/.*/IPv4") else { return out };
    for key in keys.iter() {
        let Some(dict) = store.get(key.clone()).and_then(|p| p.downcast_into::<CFDictionary>()) else { continue };
        let get = |k: &str| -> Option<String> {
            let key = CFString::new(k);
            let v = dict.find(key.as_concrete_TypeRef() as *const c_void)?;
            unsafe { CFType::wrap_under_get_rule(*v) }.downcast::<CFString>().map(|s| s.to_string())
        };
        if let (Some(_), Some(ifname)) = (get("Router"), get("InterfaceName")) {
            out.insert(ifname);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hardware_names() {
        for ok in ["en0", "en12", "feth3"] {
            assert!(is_hardware(ok), "{ok}");
        }
        for no in ["utun3", "bridge0", "en", "enx", "awdl0", "lo0"] {
            assert!(!is_hardware(no), "{no}");
        }
    }

    #[test]
    fn finds_this_macs_internet_adapter() {
        // Whatever machine runs the tests has at least one way to the internet.
        let a = discover();
        assert!(!a.is_empty(), "no adapters found");
        assert!(a.iter().all(|a| a.index > 0));
    }
}
