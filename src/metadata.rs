use std::{
    error::Error,
    fmt,
    io::Read,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, ToSocketAddrs},
    sync::{Arc, OnceLock, mpsc},
    thread,
    time::Duration,
};

use regex::Regex;
use reqwest::{
    blocking::Client,
    dns::{Addrs, Name, Resolve, Resolving},
    header::{ACCEPT, CONTENT_TYPE},
    redirect::{Attempt, Policy},
};
use serde::Serialize;
use url::{Host, Url};

use crate::repository::{MAX_DESCRIPTION, MAX_TITLE};

const MAX_BODY: usize = 1_000_000;
const MAX_REDIRECTS: usize = 4;
const READ_CHUNK: usize = 16 * 1024;

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Metadata {
    pub title: String,
    pub description: String,
    pub final_url: String,
}

/// Destination rules for a fetch. Production fetches only reach public
/// addresses on default ports; tests relax this to use loopback servers.
#[derive(Clone, Copy)]
struct FetchPolicy {
    connect_timeout: Duration,
    overall_timeout: Duration,
    public_only: bool,
}

/// Raised when a destination is refused, so the reason survives reqwest's
/// error wrapping and can be reported without echoing remote content.
#[derive(Debug)]
struct Blocked(&'static str);
impl fmt::Display for Blocked {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.0)
    }
}
impl Error for Blocked {}

pub fn fetch(url: &str) -> Result<Metadata, String> {
    fetch_with(
        url,
        FetchPolicy {
            connect_timeout: Duration::from_secs(3),
            overall_timeout: Duration::from_secs(8),
            public_only: true,
        },
    )
}

fn fetch_with(url: &str, policy: FetchPolicy) -> Result<Metadata, String> {
    let parsed = Url::parse(url).map_err(|_| "Invalid URL")?;
    check_destination(&parsed, policy.public_only).map_err(|b| b.0.to_string())?;
    let mut builder = Client::builder()
        .connect_timeout(policy.connect_timeout)
        .timeout(policy.overall_timeout)
        .redirect(redirect_policy(policy.public_only))
        .referer(false)
        .no_proxy()
        .user_agent("OmarchyBookmarks/2.0");
    if policy.public_only {
        builder = builder.dns_resolver(Arc::new(PublicResolver {
            timeout: policy.connect_timeout,
        }));
    }
    let client = builder
        .build()
        .map_err(|_| "Could not create HTTP client")?;
    let mut response = client
        .get(parsed)
        .header(ACCEPT, "text/html, application/xhtml+xml")
        .send()
        .map_err(describe_error)?;
    if !response.status().is_success() {
        return Err(format!(
            "Page lookup returned HTTP {}",
            response.status().as_u16()
        ));
    }
    let content_type = response
        .headers()
        .get(CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_ascii_lowercase();
    if !content_type.contains("text/html") && !content_type.contains("application/xhtml+xml") {
        return Err("Page is not HTML".into());
    }
    let final_url = response.url().to_string();
    let (title, description) = read_metadata(&mut response)?;
    Ok(Metadata {
        title,
        description,
        final_url,
    })
}

/// Reads only the useful prefix of a decoded HTML response. Content-Length is
/// deliberately not used as a rejection or allocation hint: it describes the
/// whole representation, while metadata normally lives in the document head.
fn read_metadata(reader: &mut impl Read) -> Result<(String, String), String> {
    let mut bytes = Vec::with_capacity(READ_CHUNK);
    let mut chunk = [0; READ_CHUNK];
    loop {
        let remaining = MAX_BODY - bytes.len();
        if remaining == 0 {
            let mut extra = [0];
            let exceeds_limit = reader.read(&mut extra).map_err(|_| "Could not read page")? != 0;
            let (title, description) = extract_metadata(&bytes);
            if exceeds_limit && title.is_empty() && description.is_empty() {
                return Err("Page metadata was not found within the read limit".into());
            }
            return Ok((title, description));
        }

        let count = reader
            .read(&mut chunk[..remaining.min(READ_CHUNK)])
            .map_err(|_| "Could not read page")?;
        if count == 0 {
            return Ok(extract_metadata(&bytes));
        }
        bytes.extend_from_slice(&chunk[..count]);

        let (title, description) = extract_metadata(&bytes);
        if (!title.is_empty() && !description.is_empty()) || head_has_ended(&bytes) {
            return Ok((title, description));
        }
    }
}

fn extract_metadata(bytes: &[u8]) -> (String, String) {
    let end = [b"</head".as_slice(), b"<body".as_slice()]
        .into_iter()
        .filter_map(|needle| find_ascii_case_insensitive(bytes, needle))
        .min()
        .unwrap_or(bytes.len());
    let html = String::from_utf8_lossy(&bytes[..end]);
    let title = meta(&html, "property", "og:title")
        .filter(|value| !value.trim().is_empty())
        .or_else(|| title_tag(&html))
        .unwrap_or_default();
    let description = meta(&html, "property", "og:description")
        .filter(|value| !value.trim().is_empty())
        .or_else(|| meta(&html, "name", "description"))
        .unwrap_or_default();
    (
        decode(&title, MAX_TITLE),
        decode(&description, MAX_DESCRIPTION),
    )
}

fn head_has_ended(bytes: &[u8]) -> bool {
    find_ascii_case_insensitive(bytes, b"</head").is_some()
        || find_ascii_case_insensitive(bytes, b"<body").is_some()
}

fn find_ascii_case_insensitive(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack
        .windows(needle.len())
        .position(|window| window.eq_ignore_ascii_case(needle))
}

fn describe_error(error: reqwest::Error) -> String {
    let mut source: Option<&(dyn Error + 'static)> = Some(&error);
    while let Some(current) = source {
        if let Some(blocked) = current.downcast_ref::<Blocked>() {
            return blocked.0.to_string();
        }
        source = current.source();
    }
    if error.is_timeout() {
        "Page lookup timed out".into()
    } else if error.is_redirect() {
        "Page lookup stopped after too many redirects".into()
    } else if error.is_connect() {
        "Could not connect to the website".into()
    } else {
        "Page lookup failed".into()
    }
}

fn check_destination(url: &Url, public_only: bool) -> Result<(), Blocked> {
    if !matches!(url.scheme(), "http" | "https") {
        return Err(Blocked("Only HTTP and HTTPS pages can be looked up"));
    }
    if !url.username().is_empty() || url.password().is_some() {
        return Err(Blocked("URLs containing credentials are not supported"));
    }
    if !public_only {
        return Ok(());
    }
    // `Url::port` is None for the scheme's default port.
    if url.port().is_some() {
        return Err(Blocked("Page lookup only uses default web ports"));
    }
    match url.host() {
        Some(Host::Ipv4(ip)) if is_public_ip(IpAddr::V4(ip)) => Ok(()),
        Some(Host::Ipv6(ip)) if is_public_ip(IpAddr::V6(ip)) => Ok(()),
        Some(Host::Domain(_)) => Ok(()),
        _ => Err(Blocked("Page lookup only contacts public addresses")),
    }
}

fn redirect_policy(public_only: bool) -> Policy {
    Policy::custom(move |attempt: Attempt| {
        if attempt.previous().len() > MAX_REDIRECTS {
            return attempt.error(Blocked("Page lookup stopped after too many redirects"));
        }
        let downgrade = attempt
            .previous()
            .last()
            .is_some_and(|previous| previous.scheme() == "https")
            && attempt.url().scheme() != "https";
        if downgrade {
            return attempt.error(Blocked("Page lookup refused an HTTPS to HTTP redirect"));
        }
        match check_destination(attempt.url(), public_only) {
            Ok(()) => attempt.follow(),
            Err(blocked) => attempt.error(blocked),
        }
    })
}

/// Resolves names itself so every address is checked before reqwest connects
/// to it. The connection uses exactly these addresses, so DNS rebinding
/// between the check and the connect is not possible.
struct PublicResolver {
    timeout: Duration,
}

impl Resolve for PublicResolver {
    fn resolve(&self, name: Name) -> Resolving {
        let host = name.as_str().to_owned();
        let timeout = self.timeout;
        Box::pin(async move {
            let (tx, rx) = mpsc::channel();
            thread::spawn(move || {
                let _ = tx.send((host.as_str(), 0).to_socket_addrs().map(Vec::from_iter));
            });
            let addresses: Vec<SocketAddr> = match rx.recv_timeout(timeout) {
                Ok(Ok(addresses)) => addresses,
                Ok(Err(_)) => return Err("Could not resolve the website".into()),
                Err(_) => return Err("Resolving the website timed out".into()),
            };
            if addresses.is_empty() || addresses.iter().any(|a| !is_public_ip(a.ip())) {
                return Err(
                    Box::new(Blocked("Page lookup only contacts public addresses"))
                        as Box<dyn Error + Send + Sync>,
                );
            }
            Ok(Box::new(addresses.into_iter()) as Addrs)
        })
    }
}

pub fn is_public_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => is_public_v4(v4),
        IpAddr::V6(v6) => is_public_v6(v6),
    }
}

fn is_public_v4(ip: Ipv4Addr) -> bool {
    let [a, b, c, _] = ip.octets();
    !(a == 0
        || a == 10
        || a == 127
        || (a == 100 && (64..=127).contains(&b))
        || (a == 169 && b == 254)
        || (a == 172 && (16..=31).contains(&b))
        || (a == 192 && b == 0 && c == 0)
        || (a == 192 && b == 0 && c == 2)
        || (a == 192 && b == 88 && c == 99)
        || (a == 192 && b == 168)
        || (a == 198 && (18..=19).contains(&b))
        || (a == 198 && b == 51 && c == 100)
        || (a == 203 && b == 0 && c == 113)
        || a >= 224)
}

fn is_public_v6(ip: Ipv6Addr) -> bool {
    if let Some(v4) = ip.to_ipv4_mapped() {
        return is_public_v4(v4);
    }
    let s = ip.segments();
    // Only global unicast (2000::/3), minus ranges that embed or tunnel to
    // other addresses or are reserved for documentation.
    (s[0] & 0xe000) == 0x2000
        && !(s[0] == 0x2001 && s[1] < 0x0200) // Teredo, benchmarking, ORCHID and IETF protocol ranges
        && !(s[0] == 0x2001 && s[1] == 0x0db8) // documentation
        && s[0] != 0x2002 // 6to4
        && s[0] != 0x3fff // documentation
}

fn meta(html: &str, kind: &str, key: &str) -> Option<String> {
    static TAG: OnceLock<Regex> = OnceLock::new();
    static ATTR: OnceLock<Regex> = OnceLock::new();
    let tag = TAG.get_or_init(|| Regex::new(r"(?is)<meta\s+[^>]*>").unwrap());
    let attr = ATTR.get_or_init(|| {
        Regex::new(r#"(?is)([a-z_:.-]+)\s*=\s*(?:\"([^\"]*)\"|'([^']*)')"#).unwrap()
    });
    for found in tag.find_iter(html) {
        let mut wanted = false;
        let mut content = None;
        for cap in attr.captures_iter(found.as_str()) {
            let name = cap[1].to_ascii_lowercase();
            let value = cap
                .get(2)
                .or_else(|| cap.get(3))
                .map(|v| v.as_str())
                .unwrap_or("")
                .trim();
            if name == kind && value.eq_ignore_ascii_case(key) {
                wanted = true
            }
            if name == "content" {
                content = Some(value.to_string())
            }
        }
        if wanted && content.is_some() {
            return content;
        }
    }
    None
}
fn title_tag(html: &str) -> Option<String> {
    static TITLE: OnceLock<Regex> = OnceLock::new();
    TITLE
        .get_or_init(|| Regex::new(r"(?is)<title[^>]*>(.*?)</title>").unwrap())
        .captures(html)
        .map(|c| c[1].trim().to_string())
}
fn decode(value: &str, max_bytes: usize) -> String {
    let cleaned = value
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&amp;", "&")
        .chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect::<String>()
        .trim()
        .to_string();
    let mut end = cleaned.len().min(max_bytes);
    while !cleaned.is_char_boundary(end) {
        end -= 1;
    }
    cleaned[..end].to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        io::{Read, Write},
        net::TcpListener,
    };

    fn loopback() -> FetchPolicy {
        FetchPolicy {
            connect_timeout: Duration::from_secs(3),
            overall_timeout: Duration::from_secs(8),
            public_only: false,
        }
    }
    fn fetch_local(url: &str) -> Result<Metadata, String> {
        fetch_with(url, loopback())
    }
    fn server(response: &'static [u8]) -> String {
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = l.local_addr().unwrap();
        thread::spawn(move || {
            let (mut s, _) = l.accept().unwrap();
            let mut b = [0; 1024];
            let _ = s.read(&mut b);
            let _ = s.write_all(response);
        });
        format!("http://{addr}/")
    }
    #[test]
    fn extracts_og_and_description() {
        let u=server(b"HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n<title>Fallback</title><meta property='og:title' content='Hello &amp; world'><meta name='description' content='Desc'>");
        let m = fetch_local(&u).unwrap();
        assert_eq!(m.title, "Hello & world");
        assert_eq!(m.description, "Desc");
    }
    #[test]
    fn rejects_oversized_without_metadata() {
        let body = "x".repeat(MAX_BODY + 1);
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {}\r\n\r\n{}",
            body.len(),
            body
        );
        let leaked = Box::leak(response.into_bytes().into_boxed_slice());
        let u = server(leaked);
        assert!(fetch_local(&u).unwrap_err().contains("read limit"));
    }
    #[test]
    fn extracts_metadata_from_an_oversized_page_prefix() {
        let body = format!(
            "{}<title>Fallback</title><meta property='og:title' content='Early title'><meta name='description' content='Early description'>{}",
            "x".repeat(MAX_BODY / 2),
            "x".repeat(MAX_BODY)
        );
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {}\r\n\r\n{}",
            body.len(),
            body
        );
        let u = server(Box::leak(response.into_bytes().into_boxed_slice()));
        let metadata = fetch_local(&u).unwrap();
        assert_eq!(metadata.title, "Early title");
        assert_eq!(metadata.description, "Early description");
    }
    #[test]
    fn returns_partial_metadata_when_the_limit_is_reached() {
        let body = format!("<title>Useful title</title>{}", "x".repeat(MAX_BODY));
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {}\r\n\r\n{}",
            body.len(),
            body
        );
        let u = server(Box::leak(response.into_bytes().into_boxed_slice()));
        let metadata = fetch_local(&u).unwrap();
        assert_eq!(metadata.title, "Useful title");
        assert!(metadata.description.is_empty());
    }
    #[test]
    fn stops_after_the_document_head() {
        let mut html = b"<HTML><HEAD><title>Head title</title></HeAd><body><meta name='description' content='Too late'>".to_vec();
        html.extend_from_slice(&vec![b'x'; READ_CHUNK * 2]);
        let mut reader = std::io::Cursor::new(html);
        let (title, description) = read_metadata(&mut reader).unwrap();
        assert_eq!(title, "Head title");
        assert!(description.is_empty());
        assert_eq!(reader.position(), READ_CHUNK as u64);
    }
    #[test]
    fn requests_and_decodes_compressed_html() {
        const GZIP_HTML: &[u8] = &[
            0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x6d, 0x8d, 0xb1, 0x0a,
            0x80, 0x30, 0x0c, 0x05, 0x7f, 0xa5, 0x5b, 0x46, 0x77, 0x69, 0x5d, 0xfc, 0x92, 0xd2,
            0x3e, 0xb4, 0x60, 0x93, 0x90, 0x66, 0xf1, 0xef, 0x05, 0x75, 0x70, 0x70, 0xbe, 0x3b,
            0x2e, 0xee, 0xc8, 0x75, 0x89, 0x1d, 0x9e, 0x83, 0x9a, 0x28, 0xcc, 0xcf, 0x44, 0xb2,
            0xcd, 0xde, 0xfc, 0x00, 0x85, 0x22, 0xec, 0x60, 0x4f, 0xb4, 0x4a, 0x57, 0xc3, 0x18,
            0xa8, 0xe1, 0x41, 0x6f, 0xc4, 0xb9, 0x23, 0x51, 0xc5, 0x28, 0xd6, 0xd4, 0x9b, 0xf0,
            0x7f, 0xf3, 0x15, 0x96, 0x38, 0xdd, 0xd7, 0x0b, 0xa1, 0x4b, 0xbb, 0xa5, 0x7c, 0x00,
            0x00, 0x00,
        ];
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let (request_tx, request_rx) = mpsc::channel();
        thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0; 1024];
            let count = stream.read(&mut request).unwrap();
            request_tx.send(request[..count].to_vec()).unwrap();
            let headers = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Encoding: gzip\r\nContent-Length: {}\r\n\r\n",
                GZIP_HTML.len()
            );
            stream.write_all(headers.as_bytes()).unwrap();
            stream.write_all(GZIP_HTML).unwrap();
        });

        let metadata = fetch_local(&format!("http://{address}/")).unwrap();
        let request = String::from_utf8(request_rx.recv().unwrap()).unwrap();
        assert!(request.to_ascii_lowercase().contains("accept-encoding:"));
        assert!(request.to_ascii_lowercase().contains("gzip"));
        assert_eq!(metadata.title, "Compressed title");
        assert_eq!(metadata.description, "Compressed description");
    }
    #[test]
    fn follows_redirect() {
        let final_listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let final_addr = final_listener.local_addr().unwrap();
        thread::spawn(move || {
            let (mut s, _) = final_listener.accept().unwrap();
            let mut b = [0; 512];
            let _ = s.read(&mut b);
            s.write_all(b"HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n<title>Final</title>").unwrap();
        });
        let redirect = format!(
            "HTTP/1.1 302 Found\r\nLocation: http://{final_addr}/done\r\nContent-Length: 0\r\n\r\n"
        );
        let u = server(Box::leak(redirect.into_bytes().into_boxed_slice()));
        assert_eq!(fetch_local(&u).unwrap().title, "Final");
    }
    #[test]
    fn invalid_or_missing_content_type_fails() {
        let u =
            server(b"HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: 3\r\n\r\nPNG");
        assert!(fetch_local(&u).is_err());
        let u = server(b"HTTP/1.1 200 OK\r\nContent-Length: 15\r\n\r\n<title>x</title>");
        assert!(fetch_local(&u).is_err());
    }

    #[test]
    fn decoded_fields_are_single_line_and_bounded() {
        assert_eq!(decode("  a\r\nb&lt;i&gt;  ", MAX_TITLE), "a  b<i>");
        assert_eq!(decode("&amp;lt;", MAX_TITLE), "&lt;");
        assert_eq!(decode(&"x".repeat(5000), MAX_TITLE).len(), MAX_TITLE);
        let unicode = decode(&"🦀".repeat(MAX_TITLE), MAX_TITLE);
        assert_eq!(unicode.len(), MAX_TITLE);
        assert_eq!(unicode.chars().count(), MAX_TITLE / "🦀".len());
    }

    #[test]
    fn timeout_and_connection_failure_are_recoverable_errors() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        thread::spawn(move || {
            let (_stream, _) = listener.accept().unwrap();
            thread::sleep(Duration::from_millis(300));
        });
        let quick = FetchPolicy {
            connect_timeout: Duration::from_millis(50),
            overall_timeout: Duration::from_millis(75),
            public_only: false,
        };
        assert!(fetch_with(&format!("http://{address}/"), quick).is_err());

        let closed = TcpListener::bind("127.0.0.1:0").unwrap();
        let closed_address = closed.local_addr().unwrap();
        drop(closed);
        assert!(fetch_with(&format!("http://{closed_address}/"), quick).is_err());
    }

    #[test]
    fn production_policy_refuses_private_destinations_without_connecting() {
        for url in [
            "http://127.0.0.1/",
            "http://10.0.0.1/",
            "http://192.168.1.1/",
            "http://169.254.169.254/latest/meta-data/",
            "http://[::1]/",
            "http://[fe80::1]/",
            "http://[fd00::1]/",
            "http://[::ffff:127.0.0.1]/",
            "http://0.0.0.0/",
            "http://localhost/",
            "https://example.com:8443/",
            "ftp://example.com/",
        ] {
            let error = fetch(url).unwrap_err();
            assert!(
                error.contains("public") || error.contains("port") || error.contains("HTTP"),
                "{url}: {error}"
            );
        }
    }

    #[test]
    fn production_policy_refuses_redirects_to_private_addresses() {
        let redirect =
            b"HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1/\r\nContent-Length: 0\r\n\r\n";
        let origin = server(redirect);
        let policy = redirect_policy(true);
        // Exercise the policy through a relaxed client that still applies the
        // production redirect rules.
        let client = Client::builder()
            .redirect(policy)
            .no_proxy()
            .build()
            .unwrap();
        let error = client.get(origin).send().unwrap_err();
        assert_eq!(
            describe_error(error),
            "Page lookup only contacts public addresses"
        );
    }

    #[test]
    fn classifies_public_addresses() {
        for ip in ["1.1.1.1", "8.8.8.8", "2606:4700:4700::1111"] {
            assert!(is_public_ip(ip.parse().unwrap()), "{ip}");
        }
        for ip in [
            "0.1.2.3",
            "10.1.1.1",
            "100.64.0.1",
            "127.0.0.1",
            "169.254.1.1",
            "172.16.0.1",
            "192.0.0.1",
            "192.0.2.1",
            "192.168.0.1",
            "198.18.0.1",
            "224.0.0.1",
            "255.255.255.255",
            "::",
            "::1",
            "::127.0.0.1",
            "::ffff:10.0.0.1",
            "64:ff9b::a00:1",
            "fc00::1",
            "fe80::1",
            "ff02::1",
            "2001::1",
            "2001:db8::1",
            "2002:a00:1::1",
        ] {
            assert!(!is_public_ip(ip.parse().unwrap()), "{ip}");
        }
    }
}
