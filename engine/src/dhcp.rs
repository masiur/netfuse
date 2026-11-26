//! Just enough DHCP to get an address from a tethering phone: DISCOVER, OFFER, REQUEST, ACK,
//! as raw Ethernet frames (the phone's link has no OS interface until this succeeds).

use std::net::Ipv4Addr;

use etherparse::{PacketBuilder, SlicedPacket, TransportSlice};

pub const OFFER: u8 = 2;
pub const ACK: u8 = 5;
pub const NAK: u8 = 6;
const MAGIC: [u8; 4] = [99, 130, 83, 99];

#[derive(Debug, Clone, PartialEq)]
pub struct Reply {
    pub kind: u8,
    pub ip: Ipv4Addr,
    pub server: Ipv4Addr,
    pub router: Option<Ipv4Addr>,
    pub mask: Ipv4Addr,
    pub lease_secs: u32,
}

pub fn discover(mac: [u8; 6], xid: u32) -> Vec<u8> {
    frame(mac, xid, &[53, 1, 1])
}

pub fn request(mac: [u8; 6], xid: u32, offer: &Reply) -> Vec<u8> {
    let (ip, srv) = (offer.ip.octets(), offer.server.octets());
    frame(mac, xid, &[53, 1, 3, 50, 4, ip[0], ip[1], ip[2], ip[3], 54, 4, srv[0], srv[1], srv[2], srv[3]])
}

/// A broadcast BOOTP request from 0.0.0.0 with `options` plus a parameter request list.
fn frame(mac: [u8; 6], xid: u32, options: &[u8]) -> Vec<u8> {
    let mut b = vec![0u8; 240];
    b[0] = 1; // BOOTREQUEST
    b[1] = 1; // Ethernet
    b[2] = 6;
    b[4..8].copy_from_slice(&xid.to_be_bytes());
    b[10] = 0x80; // ask for broadcast replies: we have no address to receive unicast on yet
    b[28..34].copy_from_slice(&mac);
    b[236..240].copy_from_slice(&MAGIC);
    b.extend_from_slice(options);
    b.extend_from_slice(&[55, 4, 1, 3, 6, 51, 255]); // want: mask, router, DNS, lease time; end
    let mut out = Vec::new();
    PacketBuilder::ethernet2(mac, [0xFF; 6])
        .ipv4([0; 4], [255; 4], 64)
        .udp(68, 67)
        .write(&mut out, &b)
        .expect("writing to a Vec");
    out
}

/// A reply to our `xid` in an Ethernet frame, if it is one.
pub fn parse(frame: &[u8], xid: u32) -> Option<Reply> {
    let p = SlicedPacket::from_ethernet(frame).ok()?;
    let Some(TransportSlice::Udp(udp)) = p.transport else { return None };
    let b = udp.payload();
    if udp.destination_port() != 68 || b.len() < 240 || b[0] != 2 || b[4..8] != xid.to_be_bytes() || b[236..240] != MAGIC {
        return None;
    }
    let ip4 = |s: &[u8]| -> Option<Ipv4Addr> { Some(Ipv4Addr::from(<[u8; 4]>::try_from(s.get(..4)?).ok()?)) };
    let mut r = Reply {
        kind: 0,
        ip: ip4(&b[16..20])?,
        server: ip4(&b[20..24])?,
        router: None,
        mask: Ipv4Addr::new(255, 255, 255, 0),
        lease_secs: 3600,
    };
    let mut o = &b[240..];
    while let [code, rest @ ..] = o {
        match code {
            0 => o = rest,
            255 => break,
            _ => {
                let [len, rest @ ..] = rest else { break };
                let Some(v) = rest.get(..*len as usize) else { break };
                match code {
                    53 => r.kind = *v.first()?,
                    1 => r.mask = ip4(v)?,
                    3 => r.router = ip4(v),
                    51 => r.lease_secs = u32::from_be_bytes(v.get(..4)?.try_into().ok()?),
                    54 => r.server = ip4(v)?,
                    _ => {}
                }
                o = &rest[*len as usize..];
            }
        }
    }
    (r.kind != 0).then_some(r)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A server reply built from our own request: same layout, op 2, an offered address and options.
    #[test]
    fn reads_an_offer_for_our_xid_only() {
        let mac = [2, 0, 0, 0, 0, 1];
        let req = discover(mac, 0x1234);
        let p = SlicedPacket::from_ethernet(&req).unwrap();
        let Some(TransportSlice::Udp(udp)) = p.transport else { panic!() };
        let mut b = udp.payload()[..240].to_vec();
        b[0] = 2;
        b[16..20].copy_from_slice(&[192, 168, 42, 7]);
        b.extend_from_slice(&[53, 1, 2, 1, 4, 255, 255, 255, 0, 3, 4, 192, 168, 42, 129, 51, 4, 0, 0, 0x0E, 0x10]);
        b.extend_from_slice(&[54, 4, 192, 168, 42, 129, 255]);
        let mut reply = Vec::new();
        PacketBuilder::ethernet2([2; 6], mac).ipv4([192, 168, 42, 129], [255; 4], 64).udp(67, 68).write(&mut reply, &b).unwrap();

        let r = parse(&reply, 0x1234).unwrap();
        assert_eq!((r.kind, r.ip, r.router, r.lease_secs), (OFFER, Ipv4Addr::new(192, 168, 42, 7), Some(Ipv4Addr::new(192, 168, 42, 129)), 3600));
        assert_eq!(r.server, Ipv4Addr::new(192, 168, 42, 129));
        assert_eq!(parse(&reply, 0x9999), None);
        assert_eq!(parse(&req, 0x1234), None); // our own request is not a reply
    }
}
