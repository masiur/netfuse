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
use tokio::time::{Instant, sleep, sleep_until, timeout};

use crate::State;
use crate::adapters::Adapter;
use crate::sched::{Lease, Route};
use crate::sites::{Sniff, sniff};

const CONNECT_TIMEOUT: Duration = Duration::from_secs(8);
const FALLBACK_DELAY: Duration = Duration::from_millis(1200);
const FAIL_COOLDOWN: Duration = Duration::from_secs(15);
const UDP_IDLE: Duration = Duration::from_secs(60);
const MAX_PENDING_DNS_QUERIES: usize = 8;
const DNS_QUERY_LIFETIME: Duration = Duration::from_secs(8);
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
    let moved = rerouted(&st, &app, host.as_deref(), &route);
    tokio::pin!(moved);
    let connected = tokio::select! {
        biased;
        _ = &mut moved => return,
        result = dial_tcp(&st, &app, &route, dst, |a| tcp_connect(a, dst)) => result,
    };
    let Some((mut upstream, lease)) = connected else { return };
    let mut disconnect = lease.disconnect.clone();
    let disconnected = {
        let forward = async {
            if upstream.write_all(&first).await.is_err() { return; }
            let (mut cr, mut cw) = tokio::io::split(&mut client);
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
            // The flow stops counting as busy at the first half-close: a finished request can wait a long
            // time for the other side's FIN, and counting it would steer new flows away from that adapter.
            tokio::select! {
                _ = &mut up => { drop(lease); let _ = timeout(HALF_CLOSE_WAIT, down).await; }
                _ = &mut down => { drop(lease); let _ = timeout(HALF_CLOSE_WAIT, up).await; }
            }
        };
        tokio::select! {
            biased;
            _ = disconnect.changed() => true,
            _ = &mut moved => false,
            _ = forward => false,
        }
    };
    if disconnected { let _ = client.abort(); }
}

pub async fn udp(client: IpStackUdpStream, st: Arc<State>) {
    let (src, dst) = (client.local_addr(), client.peer_addr());
    // QUIC hides the site name, so with site rules it is refused and browsers fall back to TCP,
    // where the name can be read. ponytail: every app loses QUIC then; read the QUIC Initial's SNI
    // if that costs too much speed.
    if dst.port() == 443 && st.has_sites() {
        return;
    }
    let app = st.app_for(false, src.port()).await;
    let route = st.route_for(&app, None);
    relay_udp(client, &st, &app, &route, |a| udp_connect(a, dst)).await;
}

async fn relay_udp<F, Fut>(mut client: IpStackUdpStream, st: &Arc<State>, app: &str, route: &Route, connect: F)
where
    F: Fn(Adapter) -> Fut,
    Fut: Future<Output = io::Result<UdpSocket>>,
{
    let dst = client.peer_addr();
    let mut tried = Vec::new();
    let moved = rerouted(st, app, None, route);
    tokio::pin!(moved);
    let connected = tokio::select! {
        biased;
        _ = &mut moved => return,
        result = dial(st, app, route, dst, &mut tried, &connect) => result,
    };
    let Some(mut primary) = connected else { return };
    let mut backup: Option<(UdpSocket, Lease)> = None;
    let (mut up, mut down) = (vec![0u8; 65535], vec![0u8; 65535]);
    let mut backup_down = Vec::new();
    // DNS can switch again after a reply. QUIC can switch only until its first reply.
    let mut probe_quic = dst.port() == 443;
    let mut pending_dns: Vec<(Instant, Vec<u8>)> = Vec::new();
    let mut replay_dns = dst.port() == 53;
    let mut outstanding_dns = std::collections::HashMap::new();
    let mut retry_at: Option<Instant> = None;
    loop {
        let (from_backup, result) = tokio::select! {
            _ = &mut moved => break,
            _ = primary.1.disconnect.changed() => {
                if let Some(path) = backup.take() { primary = path; continue; }
                break;
            },
            r = client.read(&mut up) => match r {
                Ok(n) if n > 0 => {
                    let payload = &up[..n];
                    if dst.port() == 53 {
                        if payload.len() >= 12 && payload[2] & 0xf8 == 0 {
                            let now = Instant::now();
                            outstanding_dns.retain(|_, sent| now.duration_since(*sent) < DNS_QUERY_LIFETIME);
                            outstanding_dns.insert([payload[0], payload[1]], now);
                        }
                        replay_dns = dns_query(payload);
                        if replay_dns {
                            let now = Instant::now();
                            if backup.is_none() {
                                backup = tokio::select! {
                                    biased;
                                    _ = &mut moved => break,
                                    path = dial(st, app, route, dst, &mut tried, &connect) => path,
                                };
                                if backup.is_some() { backup_down.resize(down.len(), 0); }
                            }
                            pending_dns.retain(|(sent, query)| {
                                now.duration_since(*sent) < DNS_QUERY_LIFETIME && query[..2] != payload[..2]
                            });
                            if pending_dns.len() == MAX_PENDING_DNS_QUERIES {
                                pending_dns.remove(0);
                            }
                            pending_dns.push((now, payload.to_vec()));
                        } else {
                            // For example, a DNS UPDATE must stay on one path.
                            pending_dns.clear();
                            retry_at = None;
                            backup = None;
                        }
                    }
                    if replay_dns || (probe_quic && quic_initial(payload)) {
                        retry_at.get_or_insert_with(|| Instant::now() + FALLBACK_DELAY);
                    }
                    // A reply may still arrive on the original path during a DNS probe.
                    // Give both paths the new query so neither can strand it.
                    if replay_dns && backup.is_some() {
                        if let Ok(n) = primary.0.send(payload).await {
                            primary.1.meter.tx.fetch_add(n as u64, Ordering::Relaxed);
                        }
                    }
                    let (socket, lease) = backup.as_ref().unwrap_or(&primary);
                    lease.meter.tx.fetch_add(n as u64, Ordering::Relaxed);
                    if socket.send(payload).await.is_err() {
                        if retry_at.is_none() { break; }
                        retry_at = Some(Instant::now());
                    }
                    continue;
                }
                _ => break,
            },
            r = primary.0.recv(&mut down) => (false, r),
            r = async { backup.as_ref().unwrap().0.recv(&mut backup_down).await }, if backup.is_some() => (true, r),
            _ = async { sleep_until(retry_at.unwrap()).await }, if retry_at.is_some() => {
                retry_at = None;
                let next = tokio::select! {
                    biased;
                    _ = &mut moved => break,
                    result = dial(st, app, route, dst, &mut tried, &connect) => result,
                };
                if let Some(path) = next {
                    for (_, query) in &pending_dns {
                        if let Ok(n) = path.0.send(query).await {
                            path.1.meter.tx.fetch_add(n as u64, Ordering::Relaxed);
                        }
                    }
                    if !pending_dns.is_empty() {
                        retry_at = Some(Instant::now() + FALLBACK_DELAY);
                    }
                    backup_down.resize(down.len(), 0);
                    backup = Some(path);
                } else if replay_dns {
                    // On a new query, retry any currently available path without reconnecting
                    // one of the sockets that is already listening.
                    tried.clear();
                    tried.push(primary.1.adapter.name.clone());
                    if let Some((_, lease)) = &backup {
                        tried.push(lease.adapter.name.clone());
                    }
                }
                continue;
            },
            _ = sleep(UDP_IDLE) => break,
        };
        let payload = match result {
            Ok(n) if from_backup => &backup_down[..n],
            Ok(n) => &down[..n],
            Err(_) => {
                if from_backup {
                    backup = None;
                } else if let Some(path) = backup.take() {
                    primary = path;
                } else if retry_at.is_none() {
                    break;
                }
                if retry_at.is_some() { retry_at = Some(Instant::now()); }
                continue;
            }
        };
        let answered = if replay_dns && payload.len() >= 12 && payload[2] & 0xf8 == 0x80 {
            pending_dns.iter().position(|(_, query)| query[..2] == payload[..2])
        } else {
            None
        };
        // Each outstanding transaction accepts exactly one standard reply, from either socket.
        if dst.port() == 53 && payload.len() >= 12 && payload[2] & 0xf8 == 0x80
            && outstanding_dns.remove(&[payload[0], payload[1]]).is_none() {
            continue;
        }
        let received_on = if from_backup { backup.as_ref().unwrap() } else { &primary };
        received_on.1.meter.rx.fetch_add(payload.len() as u64, Ordering::Relaxed);
        if from_backup && (!replay_dns || outstanding_dns.is_empty()) {
            primary = backup.take().unwrap();
        }
        if client.write_all(payload).await.is_err() { break; }

        if replay_dns {
            if let Some(index) = answered {
                pending_dns.remove(index);
            }
            if outstanding_dns.is_empty() {
                backup = None;
                retry_at = None;
                tried.clear();
                tried.push(primary.1.adapter.name.clone());
            } else if from_backup {
                retry_at = Some(Instant::now() + FALLBACK_DELAY);
            }
        } else {
            probe_quic = false;
            backup = None;
            retry_at = None;
        }
    }
}

fn dns_query(packet: &[u8]) -> bool {
    // Only standard queries are replayable. DNS UPDATE and other opcodes stay on one path.
    packet.len() >= 12 && packet[2] & 0xf8 == 0 && packet[4..6] != [0, 0]
}

fn quic_initial(packet: &[u8]) -> bool {
    // Switch paths only during connection setup. The client controls retransmissions.
    packet.len() >= 1200
        && matches!(
            (packet[0] & 0xf0, &packet[1..5]),
            (0xc0, [0, 0, 0, 1]) | (0xd0, [0x6b, 0x33, 0x43, 0xcf])
        )
}

async fn dial_tcp<C, F, Fut>(st: &Arc<State>, app: &str, route: &Route, dst: SocketAddr, connect: F) -> Option<(C, Lease)>
where
    F: Fn(Adapter) -> Fut,
    Fut: Future<Output = io::Result<C>>,
{
    stagger_tcp(st, app, route, dst, &mut Vec::new(), &connect).await
}

async fn stagger_tcp<C, F, Fut>(
    st: &Arc<State>, app: &str, route: &Route, dst: SocketAddr, tried: &mut Vec<String>, connect: &F,
) -> Option<(C, Lease)>
where
    F: Fn(Adapter) -> Fut,
    Fut: Future<Output = io::Result<C>>,
{
    let lease = st.sched.acquire(route, tried, app)?;
    tried.push(lease.adapter.name.clone());
    let preferred = connect_on(st, app, dst, lease, connect);
    tokio::pin!(preferred);
    tokio::select! {
        biased;
        result = &mut preferred => return match result {
            Ok(connection) => Some(connection),
            Err(DialError::Retry) => Box::pin(stagger_tcp(st, app, route, dst, tried, connect)).await,
            Err(DialError::Stop) => None,
        },
        _ = sleep(FALLBACK_DELAY) => {},
    }
    // Keep a slow-but-working preferred connection eligible. Only the winner sends payload.
    let mut fallback = Box::pin(stagger_tcp(st, app, route, dst, tried, connect));
    tokio::select! {
        biased;
        result = &mut preferred => match result {
            Ok(connection) => Some(connection),
            Err(DialError::Retry) => fallback.await,
            Err(DialError::Stop) => None,
        },
        result = &mut fallback => match result {
            Some(connection) => Some(connection),
            None => preferred.await.ok(),
        },
    }
}

/// Tries the adapters the app's route allows until one connects. Link-level errors sideline the
/// adapter for a while; a refused connection is the server's answer and is not retried.
async fn dial<C, F, Fut>(st: &Arc<State>, app: &str, route: &Route, dst: SocketAddr, tried: &mut Vec<String>, connect: &F) -> Option<(C, Lease)>
where
    F: Fn(Adapter) -> Fut,
    Fut: Future<Output = io::Result<C>>,
{
    loop {
        let lease = st.sched.acquire(route, tried, app)?;
        tried.push(lease.adapter.name.clone());
        match connect_on(st, app, dst, lease, connect).await {
            Ok(connection) => return Some(connection),
            Err(DialError::Retry) => continue,
            Err(DialError::Stop) => return None,
        }
    }
}

enum DialError { Retry, Stop }

async fn connect_on<C, F, Fut>(st: &State, app: &str, dst: SocketAddr, lease: Lease, connect: &F) -> Result<(C, Lease), DialError>
where
    F: Fn(Adapter) -> Fut,
    Fut: Future<Output = io::Result<C>>,
{
    let mut disconnect = lease.disconnect.clone();
    let result = tokio::select! {
        biased;
        _ = disconnect.changed() => return Err(DialError::Retry),
        result = timeout(CONNECT_TIMEOUT, connect(lease.adapter.clone())) => result,
    };
    let error = match result {
        Ok(Ok(connection)) => return Ok((connection, lease)),
        Ok(Err(error)) => error,
        Err(_) => io::Error::from(io::ErrorKind::TimedOut),
    };
    let (retry, link_down) = classify(&error);
    if link_down {
        st.sched.fail(&lease.adapter.name, FAIL_COOLDOWN);
    }
    eprintln!("{app} -> {dst} via {}: {error}", lease.adapter.name);
    Err(if retry { DialError::Retry } else { DialError::Stop })
}

/// (worth trying another adapter, this adapter's link is broken)
fn classify(e: &io::Error) -> (bool, bool) {
    use io::ErrorKind::*;
    if matches!(e.raw_os_error(), Some(libc::ENXIO | libc::ENODEV)) { return (true, true); }
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
    while st.route_for(app, host) == *route {
        if reloads.changed().await.is_err() {
            std::future::pending::<()>().await;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use etherparse::{PacketBuilder, SlicedPacket};
    use tokio::io::{DuplexStream, duplex};
    use tokio::net::TcpListener;
    use tokio::time::timeout;

    fn routes() -> (Arc<State>, Route) {
        let st = Arc::new(State {
            sched: Arc::default(),
            rules: Default::default(),
            rules_gen: tokio::sync::watch::Sender::new(0),
        });
        st.sched.update(["en0", "en10"].into_iter().enumerate().map(|(i, name)| Adapter {
            name: name.into(), index: i as u32 + 1, ip: "127.0.0.1".parse().unwrap(),
        }).collect());
        let route = crate::parse_route("en0 > en10").unwrap();
        st.rules.write().unwrap().default = route.clone();
        (st, route)
    }

    #[tokio::test]
    async fn http_loads_via_backup_when_primary_connect_stalls() {
        let (st, route) = routes();
        let server = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = server.local_addr().unwrap();
        let serve = tokio::spawn(async move {
            let (mut conn, _) = server.accept().await.unwrap();
            let mut request = [0; 18];
            conn.read_exact(&mut request).await.unwrap();
            assert_eq!(&request, b"GET / HTTP/1.0\r\n\r\n");
            conn.write_all(b"HTTP/1.0 200 OK\r\n\r\nNetfuse").await.unwrap();
        });
        let load = async {
            let (mut conn, lease) = dial_tcp(&st, "", &route, addr, |adapter| async move {
                if adapter.name == "en0" {
                    std::future::pending().await
                } else {
                    TcpStream::connect(addr).await
                }
            }).await.unwrap();
            assert_eq!(lease.adapter.name, "en10");
            conn.write_all(b"GET / HTTP/1.0\r\n\r\n").await.unwrap();
            let mut response = Vec::new();
            conn.read_to_end(&mut response).await.unwrap();
            assert_eq!(response, b"HTTP/1.0 200 OK\r\n\r\nNetfuse");
        };
        let start = Instant::now();
        timeout(Duration::from_secs(3), load).await.expect("page stalled waiting for backup");
        println!("HTTP response via backup in {:.3?}", start.elapsed());
        serve.await.unwrap();
    }

    #[tokio::test]
    async fn disconnect_starts_the_next_tcp_attempt_immediately() {
        let (st, route) = routes();
        let started = tokio::sync::Notify::new();
        let attempt = dial_tcp(&st, "", &route, "192.0.2.3:443".parse().unwrap(), |adapter| {
            let started = &started;
            async move {
                if adapter.name == "en0" {
                    started.notify_one();
                    std::future::pending().await
                } else { Ok(()) }
            }
        });
        let unplug = async {
            started.notified().await;
            st.sched.update(vec![Adapter {
                name: "en10".into(), index: 2, ip: "127.0.0.1".parse().unwrap(),
            }]);
        };
        let (result, ()) = timeout(Duration::from_millis(200), async { tokio::join!(attempt, unplug) })
            .await.expect("disconnect waited for the fallback timer");
        assert_eq!(result.unwrap().1.adapter.name, "en10");
    }

    #[tokio::test]
    async fn two_silent_adapters_do_not_block_the_next_tcp_route() {
        let (st, _) = routes();
        st.sched.update(["en0", "en10", "en11"].into_iter().enumerate().map(|(i, name)| Adapter {
            name: name.into(), index: i as u32 + 1, ip: "127.0.0.1".parse().unwrap(),
        }).collect());
        let route = crate::parse_route("en0 > en10 > en11").unwrap();
        let dst = "192.0.2.3:443".parse().unwrap();
        let connection = timeout(Duration::from_secs(4), dial_tcp(&st, "", &route, dst, |adapter| async move {
            if adapter.name == "en11" {
                Ok(())
            } else {
                std::future::pending().await
            }
        })).await.expect("third adapter was blocked by the second").unwrap();
        assert_eq!(connection.1.adapter.name, "en11");
    }

    #[tokio::test]
    async fn a_slow_pinned_tcp_connection_keeps_its_full_timeout() {
        let (st, _) = routes();
        let route = crate::parse_route("en0").unwrap();
        let dst = "192.0.2.3:443".parse().unwrap();
        let (_, lease) = timeout(Duration::from_secs(3), dial_tcp(&st, "", &route, dst, |adapter| async move {
            assert_eq!(adapter.name, "en0");
            sleep(Duration::from_millis(1500)).await;
            Ok(())
        })).await.expect("the pinned connection did not finish").unwrap();
        assert_eq!(lease.adapter.name, "en0");
    }

    fn datagram(port: u16, payload: &[u8]) -> Vec<u8> {
        let builder = PacketBuilder::ipv4([10, 23, 0, 2], [192, 0, 2, 3], 64).udp(40000, port);
        let mut packet = Vec::new();
        builder.write(&mut packet, payload).unwrap();
        packet
    }

    async fn udp_fixture(port: u16, first: &[u8]) -> (DuplexStream, UdpSocket, UdpSocket, tokio::task::JoinHandle<()>) {
        let (mut device, tun) = duplex(4096);
        let mut stack = ipstack::IpStack::new(ipstack::IpStackConfig::default(), tun);
        device.write_all(&datagram(port, first)).await.unwrap();
        let ipstack::IpStackStream::Udp(client) = stack.accept().await.unwrap() else { panic!("expected UDP") };
        let primary = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let backup = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let (primary_addr, backup_addr) = (primary.local_addr().unwrap(), backup.local_addr().unwrap());
        let (st, route) = routes();
        let relay = tokio::spawn(async move {
            relay_udp(client, &st, "", &route, |adapter| async move {
                let socket = UdpSocket::bind("127.0.0.1:0").await?;
                socket.connect(if adapter.name == "en0" { primary_addr } else { backup_addr }).await?;
                Ok(socket)
            }).await;
            drop(stack);
        });
        (device, primary, backup, relay)
    }

    async fn udp_payload(device: &mut DuplexStream, expected: &[u8]) {
        let mut packet = vec![0; 28 + expected.len()];
        timeout(Duration::from_secs(1), device.read_exact(&mut packet)).await.unwrap().unwrap();
        let parsed = SlicedPacket::from_ip(&packet).unwrap();
        let Some(etherparse::TransportSlice::Udp(udp)) = parsed.transport else { panic!("expected UDP reply") };
        assert_eq!(udp.payload(), expected);
    }

    #[tokio::test]
    async fn dns_retries_on_backup_when_a_previously_responsive_path_stalls() {
        let mut query = *b"\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x07example\x03com\x00\x00\x01\x00\x01";
        let (mut device, primary, backup, relay) = udp_fixture(53, &query).await;
        let mut received = [0; 128];
        let mut reply = query;
        reply[2] = 0x81;
        reply[3] = 0x83;
        let (_, from) = primary.recv_from(&mut received).await.unwrap();
        let (_, late) = timeout(Duration::from_millis(300), backup.recv_from(&mut received)).await
            .expect("fresh DNS was delayed").unwrap();
        primary.send_to(&reply, from).await.unwrap();
        udp_payload(&mut device, &reply).await;
        backup.send_to(&reply, late).await.unwrap();
        assert!(timeout(Duration::from_millis(50), device.read_u8()).await.is_err());

        query[1] += 1;
        reply[1] += 1;
        let start = Instant::now();
        device.write_all(&datagram(53, &query)).await.unwrap();
        let (len, _) = primary.recv_from(&mut received).await.unwrap();
        assert_eq!(&received[..len], query);
        let (len, from) = timeout(Duration::from_secs(3), backup.recv_from(&mut received)).await
            .expect("DNS stalled waiting for backup").unwrap();
        assert_eq!(&received[..len], query);
        backup.send_to(&reply, from).await.unwrap();
        udp_payload(&mut device, &reply).await;
        println!("DNS reply via backup in {:.3?}", start.elapsed());
        relay.abort();
    }

    #[tokio::test]
    async fn overlapping_dns_queries_reach_primary_while_backup_is_probed() {
        let mut query = *b"\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x07example\x03com\x00\x00\x01\x00\x01";
        let (mut device, primary, backup, relay) = udp_fixture(53, &query).await;
        let mut received = [0; 128];
        let (_, _from) = primary.recv_from(&mut received).await.unwrap();
        let (_, backup_peer) = timeout(Duration::from_secs(3), backup.recv_from(&mut received)).await.unwrap().unwrap();

        let mut first_reply = query;
        first_reply[2] = 0x81;
        first_reply[3] = 0x83;
        query[1] += 1;
        device.write_all(&datagram(53, &query)).await.unwrap();
        let (len, _) = timeout(Duration::from_secs(1), backup.recv_from(&mut received)).await.unwrap().unwrap();
        assert_eq!(&received[..len], query);
        backup.send_to(&first_reply, backup_peer).await.unwrap();
        udp_payload(&mut device, &first_reply).await;

        let (len, from) = timeout(Duration::from_secs(1), primary.recv_from(&mut received)).await
            .expect("second query was stranded on the backup").unwrap();
        assert_eq!(&received[..len], query);
        let mut second_reply = first_reply;
        second_reply[1] = query[1];
        primary.send_to(&second_reply, from).await.unwrap();
        udp_payload(&mut device, &second_reply).await;
        relay.abort();
    }

    #[tokio::test]
    async fn dns_update_is_sent_only_once() {
        let update = b"\x12\x34\x28\x00\x00\x01\x00\x00\x00\x00\x00\x00\x07example\x03com\x00\x00\x06\x00\x01";
        let (_device, primary, backup, relay) = udp_fixture(53, update).await;
        let mut received = [0; 128];
        let (len, _) = primary.recv_from(&mut received).await.unwrap();
        assert_eq!(&received[..len], update);
        assert!(timeout(Duration::from_millis(1500), backup.recv_from(&mut received)).await.is_err());
        relay.abort();
    }

    #[tokio::test]
    async fn quic_uses_backup_for_client_retransmission_without_replaying_packets() {
        let mut initial = vec![0; 1200];
        initial[..5].copy_from_slice(&[0xc0, 0, 0, 0, 1]);
        let (mut device, primary, backup, relay) = udp_fixture(443, &initial).await;
        let mut received = [0; 1400];
        let (len, _) = primary.recv_from(&mut received).await.unwrap();
        assert_eq!(&received[..len], &initial);
        assert!(timeout(Duration::from_millis(1500), backup.recv_from(&mut received)).await.is_err());
        initial[1199] = 1;
        device.write_all(&datagram(443, &initial)).await.unwrap();
        let (len, from) = timeout(Duration::from_secs(1), backup.recv_from(&mut received)).await
            .expect("QUIC retransmission did not reach the backup").unwrap();
        assert_eq!(&received[..len], &initial);
        backup.send_to(b"reply", from).await.unwrap();
        udp_payload(&mut device, b"reply").await;
        relay.abort();
    }
}
