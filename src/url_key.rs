use url::Url;

pub const MAX_URL_LEN: usize = 8_192;

/// Normalize only syntax that is demonstrably equivalent for HTTP(S).
/// Paths, query strings, fragments and trailing slashes are preserved.
pub fn normalize_url(input: &str) -> Result<(String, String), String> {
    let original = input.trim();
    if original.is_empty() || original.len() > MAX_URL_LEN {
        return Err("URL is empty or too long".into());
    }
    let parsed = Url::parse(original).map_err(|_| "Enter a valid HTTP or HTTPS URL")?;
    if !matches!(parsed.scheme(), "http" | "https") || parsed.host_str().is_none() {
        return Err("Only HTTP and HTTPS URLs are supported".into());
    }
    if !parsed.username().is_empty() || parsed.password().is_some() {
        return Err("URLs containing credentials are not supported".into());
    }

    let mut key = parsed.clone();
    key.set_scheme(&parsed.scheme().to_ascii_lowercase())
        .map_err(|_| "Invalid URL scheme")?;
    if let Some(host) = parsed.host_str() {
        key.set_host(Some(&host.to_ascii_lowercase()))
            .map_err(|_| "Invalid URL host")?;
    }
    if (key.scheme() == "http" && key.port() == Some(80))
        || (key.scheme() == "https" && key.port() == Some(443))
    {
        key.set_port(None).map_err(|_| "Invalid URL port")?;
    }
    Ok((original.to_string(), key.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn conservative_normalization() {
        assert_eq!(
            normalize_url("HTTPS://Example.COM:443/a/?x=1#f").unwrap().1,
            "https://example.com/a/?x=1#f"
        );
        assert_ne!(
            normalize_url("https://example.com/a").unwrap().1,
            normalize_url("https://example.com/a/").unwrap().1
        );
        assert_ne!(
            normalize_url("https://example.com/?a=1").unwrap().1,
            normalize_url("https://example.com/?a=2").unwrap().1
        );
        assert_ne!(
            normalize_url("https://example.com/#a").unwrap().1,
            normalize_url("https://example.com/#b").unwrap().1
        );
    }

    #[test]
    fn rejects_unsafe_schemes_and_credentials() {
        assert!(normalize_url("javascript:alert(1)").is_err());
        assert!(normalize_url("https://user:pass@example.com").is_err());
    }
}
