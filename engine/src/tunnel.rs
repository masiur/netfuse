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

pub struct Tunnel {
    pub io: TunIo,
    pub name: String,
}

pub fn open() -> io::Result<Tunnel> {
    let dev = DeviceBuilder::new().ipv4(TUN_IP, 24, None).mtu(MTU).build_async()?;
    let name = dev.name()?;
    for net in ROUTES {
        route(&["add", "-net", net, "-interface", &name])?;
    }
    Ok(Tunnel { io: TunIo(dev), name })
}

/// Removes the routes. Closing the utun would too; doing it first makes stopping instant.
pub fn close_routes(name: &str) {
    for net in ROUTES {
        let _ = route(&["delete", "-net", net, "-interface", name]);
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
