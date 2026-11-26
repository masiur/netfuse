//! Each flow the utun captures is ended in the userland stack and dialed again from the adapter its
//! app's route allows, with a socket bound to that adapter (IP_BOUND_IF) so it cannot loop back.

use std::io;
use std::net::SocketAddr;
use std::num::NonZeroU32;
use std::sync::Arc;
use std::time::Duration;

use ipstack::{IpStackTcpStream, IpStackUdpStream};
use socket2::{Domain, Protocol, Socket, Type};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpSocket, TcpStream, UdpSocket};

use crate::State;
use crate::adapters::Adapter;
use crate::sched::Lease;

const CONNECT_TIMEOUT: Duration = Duration::from_secs(8);
const FAIL_COOLDOWN: Duration = Duration::from_secs(15);
const UDP_IDLE: Duration = Duration::from_secs(60);
const HALF_CLOSE_WAIT: Duration = Duration::from_secs(60);

pub async fn tcp(client: IpStackTcpStream, st: Arc<State>) {
    let (src, dst) = (client.local_addr(), client.peer_addr());
    let app = st.app_for(true, src.port()).await;
    let Some((upstream, lease)) = dial(&st, &app, dst, |a| tcp_connect(a, dst)).await else { return };
    let (mut cr, mut cw) = tokio::io::split(client);
    let (mut ur, mut uw) = upstream.into_split();
    let up = async {
        let _ = tokio::io::copy(&mut cr, &mut uw).await;
        let _ = uw.shutdown().await;
    };
    let down = async {
        let _ = tokio::io::copy(&mut ur, &mut cw).await;
        let _ = cw.shutdown().await;
    };
    tokio::pin!(up, down);
    // The flow stops counting as busy at the first half-close: a finished request can wait a long
    // time for the other side's FIN, and counting it would steer new flows away from that adapter.
    tokio::select! {
        _ = &mut up => { drop(lease); let _ = tokio::time::timeout(HALF_CLOSE_WAIT, down).await; }
        _ = &mut down => { drop(lease); let _ = tokio::time::timeout(HALF_CLOSE_WAIT, up).await; }
    }
}

pub async fn udp(mut client: IpStackUdpStream, st: Arc<State>) {
    let (src, dst) = (client.local_addr(), client.peer_addr());
    let app = st.app_for(false, src.port()).await;
    let Some((sock, _lease)) = dial(&st, &app, dst, |a| udp_connect(a, dst)).await else { return };
    let (mut up, mut down) = (vec![0u8; 65535], vec![0u8; 65535]);
    loop {
        tokio::select! {
            r = client.read(&mut up) => match r {
                Ok(n) if n > 0 => { if sock.send(&up[..n]).await.is_err() { break } }
                _ => break,
            },
            r = sock.recv(&mut down) => match r {
                Ok(n) => { if client.write_all(&down[..n]).await.is_err() { break } }
                Err(_) => break,
            },
            _ = tokio::time::sleep(UDP_IDLE) => break,
        }
    }
}

/// Tries the adapters the app's route allows until one connects. Link-level errors sideline the
/// adapter for a while; a refused connection is the server's answer and is not retried.
async fn dial<C, F, Fut>(st: &Arc<State>, app: &str, dst: SocketAddr, connect: F) -> Option<(C, Lease)>
where
    F: Fn(Adapter) -> Fut,
    Fut: Future<Output = io::Result<C>>,
{
    let route = st.route_for(app);
    let mut tried = Vec::new();
    loop {
        let lease = st.sched.acquire(&route, &tried, app)?;
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
    TcpSocket::from_std_stream(std::net::TcpStream::from(s)).connect(dst).await
}

async fn udp_connect(a: Adapter, dst: SocketAddr) -> io::Result<UdpSocket> {
    let s = UdpSocket::from_std(std::net::UdpSocket::from(bound_socket(&a, Type::DGRAM, Protocol::UDP)?))?;
    s.connect(dst).await?;
    Ok(s)
}
