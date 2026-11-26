//! A network interface for a link the engine drives itself (an Android phone over USB): a feth
//! pair, macOS's virtual Ethernet cable. `fethN` is the adapter macOS and the engine use; frames it
//! sends come out of its peer `fethN+1`, where BPF reads them for the phone, and frames written to
//! the peer through BPF arrive on `fethN` as if received from the phone.

use std::ffi::CString;
use std::io;
use std::net::Ipv4Addr;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::process::Command;
use std::sync::Arc;

pub struct Feth {
    pub name: String,
    wire: String,
    bpf: Arc<OwnedFd>,
}

impl Feth {
    pub fn create(unit: u32, mac: [u8; 6]) -> io::Result<Feth> {
        destroy(unit);
        let (name, wire) = (format!("feth{unit}"), format!("feth{}", unit + 1));
        let mac = mac.map(|b| format!("{b:02x}")).join(":");
        let setup = || {
            ifconfig(&[&name, "create"])?;
            ifconfig(&[&wire, "create"])?;
            ifconfig(&[&name, "peer", &wire])?;
            // The address the phone expects its host to use. Not essential (the phone answers any
            // address), so a feth that refuses it still works.
            let _ = ifconfig(&[&name, "lladdr", &mac]);
            ifconfig(&[&name, "mtu", "1500", "up"])?;
            ifconfig(&[&wire, "mtu", "1500", "up"])?;
            open_bpf(&wire)
        };
        match setup() {
            Ok(fd) => Ok(Feth { bpf: Arc::new(fd), name, wire }),
            Err(e) => {
                destroy(unit);
                Err(e)
            }
        }
    }

    /// Applies a DHCP lease: the address, and a default route scoped to this adapter so sockets
    /// bound to it reach the internet (it never becomes the Mac's main default route).
    pub fn configure(&self, ip: Ipv4Addr, mask: Ipv4Addr, router: Option<Ipv4Addr>) -> io::Result<()> {
        ifconfig(&[&self.name, "inet", &ip.to_string(), "netmask", &mask.to_string()])?;
        if let Some(gw) = router {
            let _ = route(&["delete", "-inet", "default", "-ifscope", &self.name]);
            route(&["add", "-inet", "default", &gw.to_string(), "-ifscope", &self.name])?;
        }
        Ok(())
    }

    /// Hands a frame from the phone to macOS.
    pub fn send(&self, frame: &[u8]) {
        unsafe { libc::write(self.bpf.as_raw_fd(), frame.as_ptr().cast(), frame.len()) };
    }

    /// Calls `f` with each frame macOS sends, until the interface goes away. Blocks: run it on its
    /// own thread.
    pub fn reader(&self) -> impl FnOnce(&mut dyn FnMut(&[u8]) -> bool) + Send + 'static {
        let fd = self.bpf.clone();
        move |f| {
            let mut buf = vec![0u8; BPF_BUFFER];
            loop {
                let n = unsafe { libc::read(fd.as_raw_fd(), buf.as_mut_ptr().cast(), buf.len()) };
                if n <= 0 {
                    return;
                }
                for frame in bpf_frames(&buf[..n as usize]) {
                    if !f(frame) {
                        return;
                    }
                }
            }
        }
    }
}

impl Drop for Feth {
    fn drop(&mut self) {
        let _ = ifconfig(&[&self.name, "destroy"]);
        let _ = ifconfig(&[&self.wire, "destroy"]);
    }
}

/// Removes a pair left behind (the engine exits without unwinding).
pub fn destroy(unit: u32) {
    for u in [unit, unit + 1] {
        let _ = ifconfig(&[&format!("feth{u}"), "destroy"]);
    }
}

fn ifconfig(args: &[&str]) -> io::Result<()> {
    run("/sbin/ifconfig", args)
}

fn route(args: &[&str]) -> io::Result<()> {
    let mut a = vec!["-q", "-n"];
    a.extend_from_slice(args);
    run("/sbin/route", &a)
}

fn run(cmd: &str, args: &[&str]) -> io::Result<()> {
    let out = Command::new(cmd).args(args).output()?;
    if out.status.success() {
        Ok(())
    } else {
        Err(io::Error::other(format!("{cmd} {}: {}", args.join(" "), String::from_utf8_lossy(&out.stderr).trim())))
    }
}

const BPF_BUFFER: usize = 1 << 17;
// <net/bpf.h> ioctls (not in the libc crate for macOS)
const BIOCSBLEN: libc::c_ulong = 0xC004_4266;
const BIOCSETIF: libc::c_ulong = 0x8020_426C;
const BIOCIMMEDIATE: libc::c_ulong = 0x8004_4270;
const BIOCSHDRCMPLT: libc::c_ulong = 0x8004_4275;
const BIOCSSEESENT: libc::c_ulong = 0x8004_4277;

/// A BPF device on `ifname` that delivers each frame at once, writes frames with our source
/// addresses as given, and does not read back what we write (that would loop to the phone).
fn open_bpf(ifname: &str) -> io::Result<OwnedFd> {
    let fd = (0..256)
        .find_map(|i| {
            let path = CString::new(format!("/dev/bpf{i}")).unwrap();
            let fd = unsafe { libc::open(path.as_ptr(), libc::O_RDWR) };
            (fd >= 0).then(|| unsafe { OwnedFd::from_raw_fd(fd) })
        })
        .ok_or_else(|| io::Error::other("no free /dev/bpf device"))?;
    let raw = fd.as_raw_fd();
    let ioctl = |req: libc::c_ulong, arg: *mut libc::c_void| -> io::Result<()> {
        if unsafe { libc::ioctl(raw, req, arg) } < 0 { Err(io::Error::last_os_error()) } else { Ok(()) }
    };
    let mut blen = BPF_BUFFER as libc::c_uint;
    ioctl(BIOCSBLEN, (&raw mut blen).cast())?;
    let mut ifr = [0u8; 32];
    ifr[..ifname.len()].copy_from_slice(ifname.as_bytes());
    ioctl(BIOCSETIF, ifr.as_mut_ptr().cast())?;
    for req in [BIOCIMMEDIATE, BIOCSHDRCMPLT] {
        let mut one: libc::c_uint = 1;
        ioctl(req, (&raw mut one).cast())?;
    }
    let mut zero: libc::c_uint = 0;
    ioctl(BIOCSSEESENT, (&raw mut zero).cast())?;
    Ok(fd)
}

/// Frames in one BPF read: each behind a bpf_hdr (caplen at 8, hdrlen at 16), 4-byte aligned.
fn bpf_frames(mut buf: &[u8]) -> Vec<&[u8]> {
    let mut out = Vec::new();
    while buf.len() >= 18 {
        let caplen = u32::from_ne_bytes(buf[8..12].try_into().unwrap()) as usize;
        let hdrlen = u16::from_ne_bytes(buf[16..18].try_into().unwrap()) as usize;
        let Some(frame) = buf.get(hdrlen..hdrlen + caplen) else { break };
        out.push(frame);
        let next = (hdrlen + caplen + 3) & !3;
        buf = buf.get(next..).unwrap_or_default();
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_bpf_reads() {
        let rec = |data: &[u8]| {
            let mut h = vec![0u8; 20];
            h[8..12].copy_from_slice(&(data.len() as u32).to_ne_bytes());
            h[16..18].copy_from_slice(&20u16.to_ne_bytes());
            h.extend_from_slice(data);
            h.resize((h.len() + 3) & !3, 0);
            h
        };
        let buf = [rec(&[1, 2, 3, 4, 5]), rec(&[9; 7])].concat();
        assert_eq!(bpf_frames(&buf), vec![&[1u8, 2, 3, 4, 5][..], &[9; 7][..]]);
    }
}
