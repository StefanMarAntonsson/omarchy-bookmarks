use std::{io::Read, time::Duration};

use regex::Regex;
use reqwest::{blocking::Client, header::CONTENT_TYPE, redirect::Policy};
use serde::Serialize;
use url::Url;

const MAX_BODY: usize = 1_000_000;

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Metadata {
    pub title: String,
    pub description: String,
    pub final_url: String,
}

pub fn fetch(url: &str) -> Result<Metadata, String> {
    fetch_with_timeouts(url, Duration::from_secs(3), Duration::from_secs(8))
}

fn fetch_with_timeouts(
    url: &str,
    connect_timeout: Duration,
    overall_timeout: Duration,
) -> Result<Metadata, String> {
    let parsed = Url::parse(url).map_err(|_| "Invalid URL")?;
    if !matches!(parsed.scheme(), "http" | "https") {
        return Err("Only HTTP and HTTPS URLs are supported".into());
    }
    let client = Client::builder()
        .connect_timeout(connect_timeout)
        .timeout(overall_timeout)
        .redirect(Policy::limited(4))
        .user_agent("OmarchyBookmarks/2.0")
        .build()
        .map_err(|_| "Could not create HTTP client")?;
    let mut response = client
        .get(parsed)
        .send()
        .map_err(|e| format!("Metadata request failed: {e}"))?;
    if !response.status().is_success() {
        return Err(format!("Metadata request returned {}", response.status()));
    }
    if let Some(length) = response.content_length()
        && length > MAX_BODY as u64
    {
        return Err("Metadata response is too large".into());
    }
    let content_type = response
        .headers()
        .get(CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_ascii_lowercase();
    if !content_type.is_empty()
        && !content_type.contains("text/html")
        && !content_type.contains("application/xhtml+xml")
    {
        return Err("Metadata response is not HTML".into());
    }
    let mut bytes = Vec::new();
    response
        .by_ref()
        .take((MAX_BODY + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|_| "Could not read metadata response")?;
    if bytes.len() > MAX_BODY {
        return Err("Metadata response is too large".into());
    }
    let html = String::from_utf8_lossy(&bytes);
    let title = meta(&html, "property", "og:title")
        .or_else(|| title_tag(&html))
        .unwrap_or_default();
    let description = meta(&html, "property", "og:description")
        .or_else(|| meta(&html, "name", "description"))
        .unwrap_or_default();
    Ok(Metadata {
        title: decode(&title),
        description: decode(&description),
        final_url: response.url().to_string(),
    })
}
fn meta(html: &str, kind: &str, key: &str) -> Option<String> {
    let tag = Regex::new(r"(?is)<meta\s+[^>]*>").unwrap();
    let attr = Regex::new(r#"(?is)([a-z_:.-]+)\s*=\s*(?:\"([^\"]*)\"|'([^']*)')"#).unwrap();
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
    Regex::new(r"(?is)<title[^>]*>(.*?)</title>")
        .unwrap()
        .captures(html)
        .map(|c| c[1].trim().to_string())
}
fn decode(value: &str) -> String {
    value
        .replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .chars()
        .take(2048)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        io::{Read, Write},
        net::TcpListener,
        thread,
    };
    fn server(response: &'static [u8]) -> String {
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = l.local_addr().unwrap();
        thread::spawn(move || {
            let (mut s, _) = l.accept().unwrap();
            let mut b = [0; 1024];
            let _ = s.read(&mut b);
            s.write_all(response).unwrap();
        });
        format!("http://{addr}/")
    }
    #[test]
    fn extracts_og_and_description() {
        let u=server(b"HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n<title>Fallback</title><meta property='og:title' content='Hello &amp; world'><meta name='description' content='Desc'>");
        let m = fetch(&u).unwrap();
        assert_eq!(m.title, "Hello & world");
        assert_eq!(m.description, "Desc");
    }
    #[test]
    fn rejects_oversized() {
        let body = "x".repeat(MAX_BODY + 1);
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {}\r\n\r\n{}",
            body.len(),
            body
        );
        let leaked = Box::leak(response.into_bytes().into_boxed_slice());
        let u = server(leaked);
        assert!(fetch(&u).unwrap_err().contains("too large"));
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
        assert_eq!(fetch(&u).unwrap().title, "Final");
    }
    #[test]
    fn invalid_content_fails() {
        let u =
            server(b"HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: 3\r\n\r\nPNG");
        assert!(fetch(&u).is_err());
    }

    #[test]
    fn timeout_and_connection_failure_are_recoverable_errors() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        thread::spawn(move || {
            let (_stream, _) = listener.accept().unwrap();
            thread::sleep(Duration::from_millis(300));
        });
        assert!(
            fetch_with_timeouts(
                &format!("http://{address}/"),
                Duration::from_millis(50),
                Duration::from_millis(75)
            )
            .is_err()
        );

        let closed = TcpListener::bind("127.0.0.1:0").unwrap();
        let closed_address = closed.local_addr().unwrap();
        drop(closed);
        assert!(
            fetch_with_timeouts(
                &format!("http://{closed_address}/"),
                Duration::from_millis(50),
                Duration::from_millis(100)
            )
            .is_err()
        );
    }
}
