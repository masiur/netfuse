//! Each flow the utun captures is ended in the userland stack and dialed again from the adapter its
//! app's route allows, with a socket bound to that adapter (IP_BOUND_IF) so it cannot loop back.

use std::io;
use std::net::SocketAddr;
use std::num::NonZeroU32;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use ipstack::{IpStackTcpStream, IpStackUdpStream};
use socket2::{Domain, Protocol, Socket, Type};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::{TcpSocket, TcpStream, UdpSocket};

use crate::State;
use crate::adapters::Adapter;
use crate::sched::{Lease, Route};
use crate::sites::{Sniff, sniff};

const CONNECT_TIMEOUT: Duration = Duration::from_secs(8);
const FAIL_COOLDOWN: Duration = Duration::from_secs(15);
const UDP_IDLE: Duration = Duration::from_secs(60);
const HALF_CLOSE_WAIT: Duration = Duration::from_secs(60);
/// Per direction of a TCP flow; tokio::io::copy's 8 KB means many more small reads and writes.
/// How long a new TCP flow may take to show which site it is for (TLS ClientHello, HTTP request).
const PEEK_WAIT: Duration = Duration::from_millis(500);
const PEEK_MAX: usize = 16 * 1024;
const COPY_BUFFER: usize = 64 * 1024;

pub async fn tcp(mut client: IpStackTcpStream, st: Arc<State>) {
    let (src, dst) = (client.local_addr(), client.peer_addr());
    let app = st.app_for(true, src.port()).await;
    let (first, host) = if st.has_sites() && matches!(dst.port(), 80 | 443) { peek(&mut client).await } else { (Vec::new(), None) };
    let route = st.route_for(&app, host.as_deref());
    let Some((mut upstream, lease)) = dial(&st, &app, &route, dst, |a| tcp_connect(a, dst)).await else { return };
    if upstream.write_all(&first).await.is_err() {
        return;
    }
    let (mut cr, mut cw) = tokio::io::split(client);
    let (mut ur, mut uw) = upstream.into_split();
    let meter = lease.meter.clone();
    let up = async {
        let _ = copy(&mut cr, &mut uw, &meter.tx).await;
        let _ = uw.shutdown().await;
    };
    let down = async {
        let _ = copy(&mut ur, &mut cw, &meter.rx).await;
        let _ = cw.shutdown().await;
    };
    tokio::pin!(up, down);
    let moved = rerouted(&st, &app, host.as_deref(), &route);
    tokio::pin!(moved);
    // The flow stops counting as busy at the first half-close: a finished request can wait a long
    // time for the other side's FIN, and counting it would steer new flows away from that adapter.
    tokio::select! {
        _ = &mut up => { drop(lease); let _ = tokio::time::timeout(HALF_CLOSE_WAIT, down).await; }
        _ = &mut down => { drop(lease); let _ = tokio::time::timeout(HALF_CLOSE_WAIT, up).await; }
        // Its rule now says another route: close it, and the app reconnects through that route.
        _ = &mut moved => {}
    }
}

pub async fn udp(mut client: IpStackUdpStream, st: Arc<State>) {
    let (src, dst) = (client.local_addr(), client.peer_addr());
    // QUIC hides the site name, so with site rules it is refused and browsers fall back to TCP,
    // where the name can be read. ponytail: every app loses QUIC then; read the QUIC Initial's SNI
    // if that costs too much speed.
    if dst.port() == 443 && st.has_sites() {
        return;
    }
    let app = st.app_for(false, src.port()).await;
    let route = st.route_for(&app, None);
    let Some((sock, lease)) = dial(&st, &app, &route, dst, |a| udp_connect(a, dst)).await else { return };
    let meter = &lease.meter;
    let (mut up, mut down) = (vec![0u8; 65535], vec![0u8; 65535]);
    let moved = rerouted(&st, &app, None, &route);
    tokio::pin!(moved);
    loop {
        tokio::select! {
            _ = &mut moved => break,
            r = client.read(&mut up) => match r {
                Ok(n) if n > 0 => {
                    meter.tx.fetch_add(n as u64, Ordering::Relaxed);
                    if sock.send(&up[..n]).await.is_err() { break }
                }
                _ => break,
            },
            r = sock.recv(&mut down) => match r {
                Ok(n) => {
                    meter.rx.fetch_add(n as u64, Ordering::Relaxed);
                    if client.write_all(&down[..n]).await.is_err() { break }
                }
                Err(_) => break,
            },
            _ = tokio::time::sleep(UDP_IDLE) => break,
        }
    }
}

/// Tries the adapters the app's route allows until one connects. Link-level errors sideline the
/// adapter for a while; a refused connection is the server's answer and is not retried.
async fn dial<C, F, Fut>(st: &Arc<State>, app: &str, route: &Route, dst: SocketAddr, connect: F) -> Option<(C, Lease)>
where
    F: Fn(Adapter) -> Fut,
    Fut: Future<Output = io::Result<C>>,
{
    let mut tried = Vec::new();
    loop {
        let lease = st.sched.acquire(route, &tried, app)?;
        match tokio::time::timeout(CONNECT_TIMEOUT, connect(lease.adapter.clone())).await {
            Ok(Ok(c)) => return Some((c, lease)),
            Ok(Err(e)) => {
                let (retry, link_down) = classify(&e);
                if link_down {
                    st.sched.fail(&lease.adapter.name, FAIL_COOLDOWN);
                }
                eprintln!("{app} -> {dst} via {}: {e}", lease.adapter.name);
                if !retry {
                    return None;
                }
            }
            Err(_) => eprintln!("{app} -> {dst} via {}: timed out", lease.adapter.name),
        }
        tried.push(lease.adapter.name.clone());
    }
}

/// (worth trying another adapter, this adapter's link is broken)
fn classify(e: &io::Error) -> (bool, bool) {
    use io::ErrorKind::*;
    match e.kind() {
        NetworkUnreachable | NetworkDown | AddrNotAvailable => (true, true),
        HostUnreachable | TimedOut => (true, false),
        _ => (false, false),
    }
}

fn bound_socket(a: &Adapter, ty: Type, proto: Protocol) -> io::Result<Socket> {
    let s = Socket::new(Domain::IPV4, ty, Some(proto))?;
    s.bind_device_by_index_v4(NonZeroU32::new(a.index))?; // egress through this adapter only
    s.bind(&SocketAddr::new(a.ip.into(), 0).into())?;
    s.set_nonblocking(true)?;
    Ok(s)
}

async fn tcp_connect(a: Adapter, dst: SocketAddr) -> io::Result<TcpStream> {
    let s = bound_socket(&a, Type::STREAM, Protocol::TCP)?;
    s.set_tcp_nodelay(true)?; // the app's own socket already decided how to batch its writes
    TcpSocket::from_std_stream(std::net::TcpStream::from(s)).connect(dst).await
}

/// Copies until EOF, adding what passes to `count` (the adapter's meter) as it goes.
async fn copy<R, W>(r: &mut R, w: &mut W, count: &AtomicU64) -> io::Result<()>
where
    R: AsyncRead + Unpin + ?Sized,
    W: AsyncWrite + Unpin + ?Sized,
{
    let mut buf = vec![0u8; COPY_BUFFER];
    loop {
        let n = r.read(&mut buf).await?;
        if n == 0 {
            return Ok(());
        }
        w.write_all(&buf[..n]).await?;
        count.fetch_add(n as u64, Ordering::Relaxed);
    }
}

async fn udp_connect(a: Adapter, dst: SocketAddr) -> io::Result<UdpSocket> {
    let s = UdpSocket::from_std(std::net::UdpSocket::from(bound_socket(&a, Type::DGRAM, Protocol::UDP)?))?;
    s.connect(dst).await?;
    Ok(s)
}

/// The client's first bytes (sent on once the flow is dialed) and the site they name, if any.
/// Gives up after PEEK_WAIT, or when the bytes are not TLS or HTTP.
async fn peek(client: &mut IpStackTcpStream) -> (Vec<u8>, Option<String>) {
    let mut buf = Vec::new();
    let mut chunk = [0u8; 4096];
    let deadline = tokio::time::Instant::now() + PEEK_WAIT;
    while buf.len() < PEEK_MAX {
        match sniff(&buf) {
            Sniff::Host(h) => return (buf, Some(h)),
            Sniff::None => break,
            Sniff::NeedMore => {}
        }
        match tokio::time::timeout_at(deadline, client.read(&mut chunk)).await {
            Ok(Ok(n)) if n > 0 => buf.extend_from_slice(&chunk[..n]),
            _ => break,
        }
    }
    (buf, None)
}

/// Resolves once a rules reload gives this flow a different route than the one it was dialed on.
async fn rerouted(st: &State, app: &str, host: Option<&str>, route: &Route) {
    let mut reloads = st.rules_gen.subscribe();
    while reloads.changed().await.is_ok() {
        if st.route_for(app, host) != *route {
            return;
        }
    }
    std::future::pending().await
}
