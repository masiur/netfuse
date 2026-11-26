//! Android USB tethering as one of the engine's adapters. While a phone with USB tethering on is
//! plugged in, the engine drives it (RNDIS), gets an address from it (DHCP) and gives it a feth
//! interface, so it is routed like any other adapter. Unplugging it removes the adapter.
//! ponytail: one phone at a time; a unit per device when two are plugged in.

use std::io;
use std::net::Ipv4Addr;
use std::sync::Mutex;
use std::time::Duration;

use tokio::sync::mpsc;
use tokio::time::{Instant, sleep_until, timeout_at};

use crate::adapters::Adapter;
use crate::dhcp::{self, Reply};
use crate::feth::{self, Feth};
use crate::rndis;

/// fethN is the adapter, fethN+1 its other end; high so other tools' feth0.. are left alone.
const UNIT: u32 = 7700;
const IN_FLIGHT: usize = 8;

/// The phone's adapter while it has an address, and the phone's name.
static ADAPTER: Mutex<Option<(Adapter, String)>> = Mutex::new(None);

/// For adapters::discover().
pub fn adapter() -> Option<Adapter> {
    ADAPTER.lock().unwrap().as_ref().map(|(a, _)| a.clone())
}

/// (adapter name, phone name), for the status file.
pub fn label() -> Option<(String, String)> {
    ADAPTER.lock().unwrap().as_ref().map(|(a, n)| (a.name.clone(), n.clone()))
}

/// A phone's USB link: Ethernet frames in and out.
struct Link {
    name: String,
    mac: [u8; 6],
    to_phone: mpsc::Sender<Vec<u8>>,
    from_phone: mpsc::Receiver<Vec<u8>>,
    tasks: Vec<tokio::task::JoinHandle<()>>,
}

impl Drop for Link {
    fn drop(&mut self) {
        self.tasks.iter().for_each(|t| t.abort());
    }
}

async fn connect() -> io::Result<Option<Link>> {
    let Some((info, ctrl, data)) = rndis::find() else { return Ok(None) };
    let rndis::Phone { name, mac, max_transfer, control, mut tx, mut rx } = rndis::open(&info, ctrl, data).await?;
    let (to_phone, mut outgoing) = mpsc::channel::<Vec<u8>>(256);
    let (incoming, from_phone) = mpsc::channel::<Vec<u8>>(256);
    let sender = tokio::spawn(async move {
        let _control = control; // keeps the control interface claimed while the link runs
        let mps = tx.max_packet_size();
        while let Some(frame) = outgoing.recv().await {
            tx.submit(rndis::wrap(&frame, mps));
            while tx.pending() >= IN_FLIGHT {
                if tx.next_complete().await.status.is_err() {
                    return; // unplugged
                }
            }
        }
    });
    let receiver = tokio::spawn(async move {
        while rx.pending() < IN_FLIGHT {
            let b = rx.allocate(max_transfer);
            rx.submit(b);
        }
        loop {
            let c = rx.next_complete().await;
            if c.status.is_err() {
                return; // unplugged: dropping `incoming` tells the reader
            }
            for frame in rndis::unwrap(&c.buffer[..c.actual_len]) {
                if incoming.send(frame.to_vec()).await.is_err() {
                    return;
                }
            }
            rx.submit(c.buffer);
        }
    });
    Ok(Some(Link { name, mac, to_phone, from_phone, tasks: vec![sender, receiver] }))
}

/// DISCOVER until an OFFER, then REQUEST until an ACK. Frames that are not for us are passed
/// to `other` (macOS, once the adapter exists).
async fn lease(link: &mut Link, xid: u32, mut other: impl FnMut(&[u8])) -> io::Result<Reply> {
    let mut offer = None;
    for _ in 0..4 {
        let msg = match &offer {
            None => dhcp::discover(link.mac, xid),
            Some(o) => dhcp::request(link.mac, xid, o),
        };
        link.to_phone.send(msg).await.map_err(|_| unplugged())?;
        let deadline = Instant::now() + Duration::from_secs(3);
        while let Ok(frame) = timeout_at(deadline, link.from_phone.recv()).await {
            let frame = frame.ok_or_else(unplugged)?;
            match dhcp::parse(&frame, xid) {
                Some(r) if r.kind == dhcp::OFFER && offer.is_none() => {
                    offer = Some(r);
                    break;
                }
                Some(r) if r.kind == dhcp::ACK && offer.is_some() => return Ok(r),
                Some(r) if r.kind == dhcp::NAK => offer = None,
                _ => other(&frame),
            }
        }
    }
    Err(io::Error::new(io::ErrorKind::TimedOut, "the phone gave no address (is USB tethering on?)"))
}

fn unplugged() -> io::Error {
    io::Error::new(io::ErrorKind::NotConnected, "phone unplugged")
}

fn xid() -> u32 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(7, |d| d.subsec_nanos())
}

/// `netfuse-engine phone`: talks to the phone and asks it for an address, without creating an
/// adapter (works without root). Shows whether the USB side works.
pub async fn probe() -> io::Result<()> {
    let Some(mut link) = connect().await? else {
        println!("no phone with USB tethering found");
        return Ok(());
    };
    println!("{}: RNDIS up, MAC {}", link.name, link.mac.map(|b| format!("{b:02x}")).join(":"));
    let mut heard = 0;
    match lease(&mut link, xid(), |_| heard += 1).await {
        Ok(r) => println!("lease: {} mask {} router {:?} for {} s", r.ip, r.mask, r.router, r.lease_secs),
        Err(e) => println!("{e}; {heard} other frames came from the phone meanwhile"),
    }
    Ok(())
}

/// Runs for the engine's lifetime: picks up a phone when one is plugged in.
pub async fn run() {
    loop {
        match connect().await {
            Ok(Some(link)) => {
                let name = link.name.clone();
                println!("phone: {name} connected");
                if let Err(e) = serve(link).await {
                    println!("phone: {name}: {e}");
                }
                *ADAPTER.lock().unwrap() = None;
            }
            Ok(None) => {}
            Err(e) => eprintln!("phone: {e}"),
        }
        tokio::time::sleep(Duration::from_secs(3)).await;
    }
}

/// Removes the adapter; called when the engine stops (it exits without unwinding).
pub fn stop() {
    *ADAPTER.lock().unwrap() = None;
    feth::destroy(UNIT);
}

async fn serve(mut link: Link) -> io::Result<()> {
    let f = std::sync::Arc::new(Feth::create(UNIT, link.mac)?);
    // macOS -> phone, on a thread of its own (BPF reads block)
    let (to_phone, reader) = (link.to_phone.clone(), f.reader());
    std::thread::spawn(move || reader(&mut |frame| to_phone.blocking_send(frame.to_vec()).is_ok()));

    let xid = xid();
    let mut current: Option<Reply> = None;
    loop {
        let r = lease(&mut link, xid, |frame| f.send(frame)).await?;
        if current.as_ref().is_none_or(|c| (c.ip, c.mask, c.router) != (r.ip, r.mask, r.router)) {
            f.configure(r.ip, r.mask, r.router)?;
            let index = if_index(&f.name)?;
            *ADAPTER.lock().unwrap() = Some((Adapter { name: f.name.clone(), index, ip: r.ip }, link.name.clone()));
            println!("phone: {} on {} via {}", r.ip, f.name, r.router.map_or("-".into(), |g: Ipv4Addr| g.to_string()));
        }
        // phone -> macOS until it is time to renew (half the lease)
        let renew = Instant::now() + Duration::from_secs(u64::from(r.lease_secs.max(60)) / 2);
        current = Some(r);
        loop {
            tokio::select! {
                frame = link.from_phone.recv() => f.send(&frame.ok_or_else(unplugged)?),
                _ = sleep_until(renew) => break,
            }
        }
    }
}

fn if_index(name: &str) -> io::Result<u32> {
    let c = std::ffi::CString::new(name).unwrap();
    match unsafe { libc::if_nametoindex(c.as_ptr()) } {
        0 => Err(io::Error::last_os_error()),
        i => Ok(i),
    }
}
