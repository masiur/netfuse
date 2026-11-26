//! The virtual adapter that captures traffic: a utun whose two /1 routes beat the default route
//! without touching it. When the process exits the utun goes away and its routes with it, so a
//! crash cannot leave the Mac without internet.

use std::io;
use std::net::Ipv4Addr;
use std::pin::Pin;
use std::process::Command;
use std::task::{Context, Poll, ready};

use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tun_rs::{AsyncDevice, DeviceBuilder};

/// Traffic on the utun never leaves the Mac, so the links' 1500 does not apply; bigger packets
/// cost far less CPU in the userland stack.
pub const MTU: u16 = 9000;

/// 198.18.0.0/15 is reserved for benchmarks (RFC 2544), so no real network uses it.
/// ponytail: fixed /24; pick a free one if another TUN app (Clash, sing-box) already sits here.
const TUN_IP: Ipv4Addr = Ipv4Addr::new(198, 18, 123, 1);
const ROUTES: [&str; 2] = ["0.0.0.0/1", "128.0.0.0/1"];

/// IPv6 is not routed by the engine, so while it runs IPv6 is refused instead: a connect fails at
/// once and apps fall back to IPv4, which the engine routes. Left alone, IPv6 would leave through
/// whichever adapter has it and ignore every rule. (Link-local, multicast and loopback have more
/// specific routes and keep working.)
/// ponytail: no IPv6 while on; route it like IPv4 (utun v6 address, v6 dials) when someone needs it.
/// These go via lo0, so unlike the utun's routes they survive a crash: open() clears leftovers.
const REJECT6: [&str; 2] = ["::", "8000::"];

pub struct Tunnel {
    pub io: TunIo,
    pub name: String,
}

pub fn open() -> io::Result<Tunnel> {
    let dev = DeviceBuilder::new().ipv4(TUN_IP, 24, None).mtu(MTU).build_async()?;
    let name = dev.name()?;
    add_routes(&name)?;
    Ok(Tunnel { io: TunIo(dev), name })
}

/// Points all IPv4 at the utun and refuses IPv6. Also used to come back after a VPN disconnects.
pub fn add_routes(name: &str) -> io::Result<()> {
    let res = (|| {
        for net in ROUTES {
            let _ = route(&["delete", "-net", net]); // ours, left from before a pause or crash
            route(&["add", "-net", net, "-interface", name])?;
        }
        for net in REJECT6 {
            let _ = route(&["delete", "-inet6", "-net", net, "-prefixlen", "1"]); // left by a crash
            route(&["add", "-inet6", "-net", net, "-prefixlen", "1", "::1", "-reject"])?;
        }
        Ok(())
    })();
    if res.is_err() {
        close_routes(name);
    }
    res
}

/// The VPN macOS sends traffic through, if one is connected: the primary interface is then the
/// VPN's tunnel (WireGuard, Proton, IKEv2…). Our routes would pull its traffic out of it and send
/// it straight out the adapters, so the engine steps aside while one is up. Our own utun never
/// becomes primary: it only adds routes. A split-tunnel VPN (Tailscale without an exit node) does
/// not become primary either, and is left to coexist.
pub fn vpn(ours: &str) -> Option<String> {
    use std::io::Write;
    let mut child = Command::new("/usr/sbin/scutil")
        .stdin(std::process::Stdio::piped()).stdout(std::process::Stdio::piped()).spawn().ok()?;
    child.stdin.take()?.write_all(b"show State:/Network/Global/IPv4\n").ok()?;
    let out = String::from_utf8(child.wait_with_output().ok()?.stdout).ok()?;
    primary_vpn(&out, ours)
}

fn primary_vpn(scutil: &str, ours: &str) -> Option<String> {
    let iface = scutil.lines().find_map(|l| l.trim().strip_prefix("PrimaryInterface : "))?.trim();
    let tunnel = ["utun", "ipsec", "ppp", "tun", "tap"].iter().any(|p| iface.starts_with(p));
    (tunnel && iface != ours).then(|| iface.to_string())
}

#[test]
fn finds_primary_vpn() {
    let s = "<dictionary> {\n  PrimaryInterface : utun7\n  PrimaryService : X\n}";
    assert_eq!(primary_vpn(s, "utun3").as_deref(), Some("utun7"));
    assert_eq!(primary_vpn(s, "utun7"), None);
    assert_eq!(primary_vpn("  PrimaryInterface : en0", "utun3"), None);
    assert_eq!(primary_vpn("", "utun3"), None);
}

/// Removes the routes. Closing the utun would remove its own; doing it first makes stopping instant.
pub fn close_routes(name: &str) {
    for net in ROUTES {
        let _ = route(&["delete", "-net", net, "-interface", name]);
    }
    for net in REJECT6 {
        let _ = route(&["delete", "-inet6", "-net", net, "-prefixlen", "1"]);
    }
}

fn route(args: &[&str]) -> io::Result<()> {
    let out = Command::new("/sbin/route").arg("-n").args(args).output()?;
    if out.status.success() {
        Ok(())
    } else {
        Err(io::Error::other(format!("route {}: {}", args.join(" "), String::from_utf8_lossy(&out.stderr).trim())))
    }
}

/// The utun as a byte stream of whole packets, which is what ipstack reads and writes.
pub struct TunIo(AsyncDevice);

impl AsyncRead for TunIo {
    fn poll_read(self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &mut ReadBuf<'_>) -> Poll<io::Result<()>> {
        let n = ready!(self.0.poll_recv(cx, buf.initialize_unfilled()))?;
        buf.advance(n);
        Poll::Ready(Ok(()))
    }
}

impl AsyncWrite for TunIo {
    fn poll_write(self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &[u8]) -> Poll<io::Result<usize>> {
        self.0.poll_send(cx, buf)
    }
    fn poll_flush(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Ok(()))
    }
    fn poll_shutdown(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Ok(()))
    }
}
