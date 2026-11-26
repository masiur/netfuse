//! RNDIS over USB: how Android phones (and some USB modems) offer USB tethering. macOS has no
//! driver for it, so the engine speaks it itself: control messages on endpoint 0, Ethernet frames
//! wrapped in REMOTE_NDIS_PACKET_MSG on the data interface's bulk endpoints. (Per [MS-RNDIS];
//! the same steps as Linux's rndis_host.)

use std::io;
use std::time::Duration;

use nusb::transfer::{Buffer, Bulk, ControlIn, ControlOut, ControlType, In, Out, Recipient};
use nusb::{DeviceInfo, Endpoint, MaybeFuture};

const MSG_PACKET: u32 = 0x1;
const MSG_INIT: u32 = 0x2;
const MSG_QUERY: u32 = 0x4;
const MSG_SET: u32 = 0x5;
const CMPLT: u32 = 0x8000_0000;
const OID_PERMANENT_ADDRESS: u32 = 0x0101_0101;
const OID_PACKET_FILTER: u32 = 0x0001_010E;
/// directed | all multicast | broadcast | promiscuous, as Linux sets it
const FILTER: u32 = 0x1 | 0x4 | 0x8 | 0x20;
const PACKET_HEADER: usize = 44;
const TIMEOUT: Duration = Duration::from_secs(2);

/// An RNDIS function on a USB device: (device, control interface, data interface).
pub fn find() -> Option<(DeviceInfo, u8, u8)> {
    nusb::list_devices().wait().ok()?.find_map(|d| {
        let ctrl = d.interfaces().find(|i| is_rndis_control(i.class(), i.subclass(), i.protocol()))?.interface_number();
        let data = d.interfaces().find(|i| i.class() == 0x0A && i.interface_number() != ctrl)?.interface_number();
        Some((d, ctrl, data))
    })
}

fn is_rndis_control(class: u8, sub: u8, proto: u8) -> bool {
    matches!((class, sub, proto), (0xEF, 4, 1) | (0xE0, 1, 3) | (0x02, 0x02, 0xFF))
}

pub struct Control {
    iface: nusb::Interface, // the claimed control interface; requests go through it
    ctrl: u8,
    next_id: u32,
}

pub struct Phone {
    pub name: String,
    pub mac: [u8; 6],
    pub max_transfer: usize,
    pub control: Control,
    pub tx: Endpoint<Bulk, Out>,
    pub rx: Endpoint<Bulk, In>,
}

pub async fn open(info: &DeviceInfo, ctrl: u8, data: u8) -> io::Result<Phone> {
    let name = format!("{} {}", info.manufacturer_string().unwrap_or(""), info.product_string().unwrap_or("phone"))
        .trim()
        .to_string();
    let dev = info.open().await?;
    let ctrl_if = dev.claim_interface(ctrl).await?;
    let data_if = dev.claim_interface(data).await?;
    let (mut ep_in, mut ep_out) = (None, None);
    for ep in data_if.descriptor().into_iter().flat_map(|d| d.endpoints().collect::<Vec<_>>()) {
        if ep.transfer_type() != nusb::descriptors::TransferType::Bulk {
            continue;
        }
        match ep.direction() {
            nusb::transfer::Direction::In => ep_in = Some(ep.address()),
            nusb::transfer::Direction::Out => ep_out = Some(ep.address()),
        }
    }
    let (Some(ep_in), Some(ep_out)) = (ep_in, ep_out) else {
        return Err(io::Error::other("RNDIS data interface has no bulk endpoints"));
    };
    let mut control = Control { iface: ctrl_if, ctrl, next_id: 1 };

    let mut init = Vec::new();
    for v in [MSG_INIT, 24, 0, 1, 0, 0x4000] {
        init.extend_from_slice(&v.to_le_bytes());
    }
    let r = control.request(init).await?;
    let max_transfer = (u32_at(&r, 36) as usize).clamp(2048, 0x4000);

    let mac = control.query(OID_PERMANENT_ADDRESS).await?;
    let mac: [u8; 6] = mac.get(..6).and_then(|m| m.try_into().ok()).ok_or_else(|| io::Error::other("RNDIS: no MAC address"))?;
    control.set(OID_PACKET_FILTER, &FILTER.to_le_bytes()).await?;

    Ok(Phone {
        name,
        mac,
        max_transfer,
        control,
        tx: data_if.endpoint::<Bulk, Out>(ep_out)?,
        rx: data_if.endpoint::<Bulk, In>(ep_in)?,
    })
}

impl Control {
    /// Sends one control message and waits for its completion (same request id).
    async fn request(&mut self, mut msg: Vec<u8>) -> io::Result<Vec<u8>> {
        let id = self.next_id;
        self.next_id += 1;
        msg[8..12].copy_from_slice(&id.to_le_bytes());
        let kind = u32_at(&msg, 0);
        let out = ControlOut {
            control_type: ControlType::Class,
            recipient: Recipient::Interface,
            request: 0x00, // SEND_ENCAPSULATED_COMMAND
            value: 0,
            index: self.ctrl as u16,
            data: &msg,
        };
        self.iface.control_out(out, TIMEOUT).await.map_err(io::Error::other)?;
        // The reply is ready once the device signals it on its interrupt endpoint; polling for
        // it works as well and keeps this simple. Other messages (status indications) are skipped.
        for _ in 0..50 {
            let get = ControlIn {
                control_type: ControlType::Class,
                recipient: Recipient::Interface,
                request: 0x01, // GET_ENCAPSULATED_RESPONSE
                value: 0,
                index: self.ctrl as u16,
                length: 1025,
            };
            match self.iface.control_in(get, TIMEOUT).await {
                Ok(r) if r.len() >= 16 && u32_at(&r, 0) == kind | CMPLT && u32_at(&r, 8) == id => {
                    let status = u32_at(&r, 12);
                    if status != 0 {
                        return Err(io::Error::other(format!("RNDIS message {kind:#x}: status {status:#x}")));
                    }
                    return Ok(r);
                }
                _ => tokio::time::sleep(Duration::from_millis(20)).await,
            }
        }
        Err(io::Error::new(io::ErrorKind::TimedOut, format!("RNDIS message {kind:#x}: no reply")))
    }

    async fn query(&mut self, oid: u32) -> io::Result<Vec<u8>> {
        let mut m = Vec::new();
        for v in [MSG_QUERY, 28, 0, oid, 0, 20, 0] {
            m.extend_from_slice(&v.to_le_bytes());
        }
        let r = self.request(m).await?;
        let (len, off) = (u32_at(&r, 16) as usize, 8 + u32_at(&r, 20) as usize);
        r.get(off..off + len).map(<[u8]>::to_vec).ok_or_else(|| io::Error::other("RNDIS: short query reply"))
    }

    async fn set(&mut self, oid: u32, value: &[u8]) -> io::Result<()> {
        let mut m = Vec::new();
        for v in [MSG_SET, 28 + value.len() as u32, 0, oid, value.len() as u32, 20, 0] {
            m.extend_from_slice(&v.to_le_bytes());
        }
        m.extend_from_slice(value);
        self.request(m).await.map(|_| ())
    }
}

/// Wraps an Ethernet frame for the bulk OUT endpoint.
pub fn wrap(frame: &[u8], max_packet: usize) -> Buffer {
    let mut len = PACKET_HEADER + frame.len();
    // A transfer that is an exact multiple of the packet size would need a zero-length packet to
    // end it; one byte of padding (counted in the message length, not the data) avoids that.
    if len % max_packet == 0 {
        len += 1;
    }
    let mut b = Buffer::new(len);
    for v in [MSG_PACKET, len as u32, 36, frame.len() as u32, 0, 0, 0, 0, 0, 0, 0] {
        b.extend_from_slice(&v.to_le_bytes());
    }
    b.extend_from_slice(frame);
    b.extend_fill(len - PACKET_HEADER - frame.len(), 0);
    b
}

/// The Ethernet frames in one bulk IN transfer (it may hold several packet messages).
pub fn unwrap(mut buf: &[u8]) -> Vec<&[u8]> {
    let mut out = Vec::new();
    while buf.len() >= PACKET_HEADER {
        let (kind, len) = (u32_at(buf, 0), u32_at(buf, 4) as usize);
        if len < 8 || len > buf.len() {
            break;
        }
        if kind == MSG_PACKET {
            let (off, n) = (8 + u32_at(buf, 8) as usize, u32_at(buf, 12) as usize);
            if let Some(f) = buf.get(off..off + n) {
                out.push(f);
            }
        }
        buf = &buf[len..];
    }
    out
}

fn u32_at(b: &[u8], at: usize) -> u32 {
    b.get(at..at + 4).map_or(0, |s| u32::from_le_bytes(s.try_into().unwrap()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn packets_wrap_and_unwrap() {
        let a = wrap(&[1, 2, 3], 512);
        let b = wrap(&[0xAA; 512 - PACKET_HEADER], 512); // would end on a packet boundary
        assert_eq!(a.len(), PACKET_HEADER + 3);
        assert_eq!(b.len(), 513);
        let both = [&a[..], &b[..]].concat();
        let frames = unwrap(&both);
        assert_eq!(frames, vec![&[1u8, 2, 3][..], &[0xAA; 512 - PACKET_HEADER][..]]);
        assert!(is_rndis_control(0xEF, 4, 1) && !is_rndis_control(0x0A, 0, 0));
    }
}
