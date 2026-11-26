//! Site rules: the host a TCP flow is for, read from its first bytes (TLS SNI, or HTTP's Host
//! header), matched against domains like "youtube.com" (which also covers "m.youtube.com").

/// The rule for `host` among `sites`: the longest matching domain, so "music.youtube.com" beats
/// "youtube.com".
pub fn best<'a, T>(sites: &'a [(String, T)], host: &str) -> Option<&'a T> {
    let host = host.trim_end_matches('.').to_ascii_lowercase();
    sites
        .iter()
        .filter(|(d, _)| host == *d || host.strip_suffix(d.as_str()).is_some_and(|p| p.ends_with('.')))
        .max_by_key(|(d, _)| d.len())
        .map(|(_, r)| r)
}

/// "https://www.YouTube.com/watch" -> "www.youtube.com"; "*.x.com" -> "x.com". None if empty.
pub fn normalize(domain: &str) -> Option<String> {
    let d = domain.trim().to_ascii_lowercase();
    let d = d.split("://").last()?.split(['/', ':', '?']).next()?.trim_start_matches("*.").trim_matches('.');
    (!d.is_empty()).then(|| d.to_string())
}

pub enum Sniff {
    Host(String),
    NeedMore,
    /// Not TLS or HTTP, or no name in it.
    None,
}

/// The host named in a flow's first bytes.
pub fn sniff(b: &[u8]) -> Sniff {
    match b.first() {
        None => Sniff::NeedMore,
        Some(0x16) => tls_sni(b),
        Some(_) => http_host(b),
    }
}

fn http_host(b: &[u8]) -> Sniff {
    let Some(end) = b.windows(4).position(|w| w == b"\r\n\r\n") else {
        return if b.len() < 8192 && b.iter().all(|c| c.is_ascii()) { Sniff::NeedMore } else { Sniff::None };
    };
    let head = String::from_utf8_lossy(&b[..end]);
    head.lines()
        .skip(1)
        .find_map(|l| l.split_once(':').filter(|(k, _)| k.trim().eq_ignore_ascii_case("host")).map(|(_, v)| v.trim()))
        .and_then(normalize)
        .map_or(Sniff::None, Sniff::Host)
}

/// The server_name of a TLS ClientHello. Waits for the whole first record (post-quantum key
/// shares push it past one TCP segment).
fn tls_sni(b: &[u8]) -> Sniff {
    if b.len() < 5 {
        return Sniff::NeedMore;
    }
    let len = u16::from_be_bytes([b[3], b[4]]) as usize;
    if b.len() < 5 + len {
        return Sniff::NeedMore;
    }
    parse_hello(&b[5..5 + len]).map_or(Sniff::None, Sniff::Host)
}

fn parse_hello(h: &[u8]) -> Option<String> {
    let mut r = Reader(h);
    if r.u8()? != 1 {
        return None; // not a ClientHello
    }
    r.take(3 + 2 + 32)?; // length, version, random
    let n = r.u8()? as usize;
    r.take(n)?; // session id
    let n = r.u16()? as usize;
    r.take(n)?; // cipher suites
    let n = r.u8()? as usize;
    r.take(n)?; // compression
    let n = r.u16()? as usize;
    let mut ext = Reader(r.take(n)?);
    while let (Some(ty), Some(n)) = (ext.u16(), ext.u16()) {
        let body = ext.take(n as usize)?;
        if ty == 0 {
            let mut s = Reader(body);
            s.u16()?; // list length
            if s.u8()? == 0 {
                let n = s.u16()? as usize;
                return normalize(std::str::from_utf8(s.take(n)?).ok()?);
            }
            return None;
        }
    }
    None
}

struct Reader<'a>(&'a [u8]);

impl<'a> Reader<'a> {
    fn take(&mut self, n: usize) -> Option<&'a [u8]> {
        let (a, b) = (self.0.get(..n)?, self.0.get(n..)?);
        self.0 = b;
        Some(a)
    }
    fn u8(&mut self) -> Option<u8> { self.take(1).map(|b| b[0]) }
    fn u16(&mut self) -> Option<u16> { self.take(2).map(|b| u16::from_be_bytes([b[0], b[1]])) }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hello(name: &str) -> Vec<u8> {
        let sni: Vec<u8> = [&((name.len() + 3) as u16).to_be_bytes()[..], &[0], &(name.len() as u16).to_be_bytes(), name.as_bytes()].concat();
        let exts: Vec<u8> = [&[0, 10, 0, 2, 0, 0][..], &[0, 0], &(sni.len() as u16).to_be_bytes(), &sni].concat();
        let body: Vec<u8> = [&[3, 3][..], &[7; 32], &[0], &[0, 2, 0x13, 1], &[1, 0], &(exts.len() as u16).to_be_bytes(), &exts].concat();
        let hs: Vec<u8> = [&[1, 0][..], &(body.len() as u16).to_be_bytes(), &body].concat();
        [&[0x16, 3, 1][..], &(hs.len() as u16).to_be_bytes(), &hs].concat()
    }

    #[test]
    fn reads_sni_and_host() {
        let h = hello("Www.YouTube.com");
        assert!(matches!(sniff(&h), Sniff::Host(ref s) if s == "www.youtube.com"));
        assert!(matches!(sniff(&h[..h.len() - 1]), Sniff::NeedMore));
        assert!(matches!(sniff(b"GET / HTTP/1.1\r\nHost: example.com:80\r\n\r\n"), Sniff::Host(ref s) if s == "example.com"));
        assert!(matches!(sniff(b"GET / HTTP/1.1\r\nHo"), Sniff::NeedMore));
        assert!(matches!(sniff(&[0xff, 0, 1]), Sniff::None));
    }

    #[test]
    fn matches_longest_domain() {
        let sites = vec![("youtube.com".to_string(), 1), ("music.youtube.com".to_string(), 2)];
        assert_eq!(best(&sites, "youtube.com"), Some(&1));
        assert_eq!(best(&sites, "m.youtube.com."), Some(&1));
        assert_eq!(best(&sites, "a.music.youtube.com"), Some(&2));
        assert_eq!(best(&sites, "notyoutube.com"), None);
        assert_eq!(normalize("https://*.YouTube.com/watch?v=1").as_deref(), Some("youtube.com"));
    }
}
