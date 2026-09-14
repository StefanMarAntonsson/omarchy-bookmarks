use serde::Serialize;
use std::{
    collections::HashSet,
    env, fs,
    io::Read,
    os::unix::fs::OpenOptionsExt,
    path::{Path, PathBuf},
};

const MAX_DESKTOP_FILE_BYTES: u64 = 256 * 1024;
const MAX_MIMEAPPS_FILE_BYTES: u64 = 256 * 1024;
const MAX_APPLICATION_ENTRIES: usize = 20_000;
const MAX_BROWSERS: usize = 256;
const MAX_BROWSER_ID_LENGTH: usize = 256;
const MAX_BROWSER_NAME_LENGTH: usize = 512;

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Browser {
    pub id: String,
    pub name: String,
    #[serde(rename = "isDefault")]
    pub is_default: bool,
    #[serde(skip)]
    pub desktop_path: PathBuf,
}

pub fn discover() -> Result<Vec<Browser>, String> {
    let home = env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or("HOME is not set")?;
    let directories = application_dirs(&home);
    let default_id = default_browser_id(&home);
    Ok(discover_in(&directories, default_id.as_deref()))
}

pub fn find(identifier: &str) -> Result<Browser, String> {
    if identifier.is_empty() || identifier.len() > MAX_BROWSER_ID_LENGTH || identifier.contains('/')
    {
        return Err("Invalid browser selection".into());
    }
    discover()?
        .into_iter()
        .find(|browser| browser.id == identifier)
        .ok_or_else(|| "Selected browser is no longer available".into())
}

fn application_dirs(home: &Path) -> Vec<PathBuf> {
    let data_home = env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .unwrap_or_else(|| home.join(".local/share"));
    let mut directories = vec![
        data_home.join("applications"),
        home.join(".nix-profile/share/applications"),
    ];
    let data_dirs = env::var_os("XDG_DATA_DIRS")
        .and_then(|value| value.into_string().ok())
        .unwrap_or_else(|| "/usr/local/share:/usr/share".into());
    directories.extend(
        data_dirs
            .split(':')
            .map(PathBuf::from)
            .filter(|path| path.is_absolute())
            .map(|path| path.join("applications")),
    );
    deduplicate_paths(directories)
}

fn mimeapps_paths(home: &Path) -> Vec<PathBuf> {
    let config_home = env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .unwrap_or_else(|| home.join(".config"));
    let data_home = env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .unwrap_or_else(|| home.join(".local/share"));
    let mut paths = vec![
        config_home.join("mimeapps.list"),
        config_home.join("applications/mimeapps.list"),
    ];
    if let Some(config_dirs) = env::var_os("XDG_CONFIG_DIRS").and_then(|v| v.into_string().ok()) {
        paths.extend(
            config_dirs
                .split(':')
                .map(PathBuf::from)
                .filter(|path| path.is_absolute())
                .map(|path| path.join("mimeapps.list")),
        );
    }
    paths.push(data_home.join("applications/mimeapps.list"));
    let data_dirs = env::var_os("XDG_DATA_DIRS")
        .and_then(|value| value.into_string().ok())
        .unwrap_or_else(|| "/usr/local/share:/usr/share".into());
    paths.extend(
        data_dirs
            .split(':')
            .map(PathBuf::from)
            .filter(|path| path.is_absolute())
            .map(|path| path.join("applications/mimeapps.list")),
    );
    deduplicate_paths(paths)
}

fn deduplicate_paths(paths: Vec<PathBuf>) -> Vec<PathBuf> {
    let mut seen = HashSet::new();
    paths
        .into_iter()
        .filter(|path| seen.insert(path.clone()))
        .collect()
}

fn default_browser_id(home: &Path) -> Option<String> {
    mimeapps_paths(home)
        .into_iter()
        .find_map(|path| default_from_mimeapps(&path))
}

fn default_from_mimeapps(path: &Path) -> Option<String> {
    let raw = read_bounded(path, MAX_MIMEAPPS_FILE_BYTES)?;
    let mut in_defaults = false;
    for raw_line in raw.lines() {
        let line = raw_line.trim();
        if line.starts_with('[') && line.ends_with(']') {
            in_defaults = line == "[Default Applications]";
            continue;
        }
        if !in_defaults {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        if key.trim() != "x-scheme-handler/https" {
            continue;
        }
        let identifier = value.split(';').next().unwrap_or("").trim();
        if valid_identifier(identifier) {
            return Some(identifier.into());
        }
    }
    None
}

fn discover_in(directories: &[PathBuf], default_id: Option<&str>) -> Vec<Browser> {
    let mut browsers = Vec::new();
    let mut seen = HashSet::new();
    let mut scanned = 0usize;
    'directories: for directory in directories {
        let Ok(entries) = fs::read_dir(directory) else {
            continue;
        };
        for entry in entries.flatten() {
            scanned += 1;
            if scanned > MAX_APPLICATION_ENTRIES {
                break 'directories;
            }
            let path = entry.path();
            let Some(identifier) = path.file_name().and_then(|name| name.to_str()) else {
                continue;
            };
            if !valid_identifier(identifier) || !seen.insert(identifier.to_owned()) {
                continue;
            }
            let Some(mut browser) = parse_desktop_file(&path) else {
                continue;
            };
            browser.is_default = default_id == Some(identifier);
            browsers.push(browser);
            if browsers.len() >= MAX_BROWSERS {
                break 'directories;
            }
        }
    }
    browsers.sort_by(|first, second| {
        second
            .is_default
            .cmp(&first.is_default)
            .then_with(|| first.name.to_lowercase().cmp(&second.name.to_lowercase()))
            .then_with(|| first.id.cmp(&second.id))
    });
    browsers
}

fn valid_identifier(identifier: &str) -> bool {
    !identifier.is_empty()
        && identifier.len() <= MAX_BROWSER_ID_LENGTH
        && identifier.ends_with(".desktop")
        && !identifier.contains('/')
}

fn parse_desktop_file(path: &Path) -> Option<Browser> {
    let raw = read_bounded(path, MAX_DESKTOP_FILE_BYTES)?;
    let mut in_desktop_entry = false;
    let mut name = "";
    let mut entry_type = "Application";
    let mut mime_types = "";
    let mut hidden = false;
    let mut no_display = false;
    for raw_line in raw.lines() {
        let line = raw_line.trim();
        if line.starts_with('[') && line.ends_with(']') {
            if in_desktop_entry {
                break;
            }
            in_desktop_entry = line == "[Desktop Entry]";
            continue;
        }
        if !in_desktop_entry || line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        match key {
            "Name" => name = value.trim(),
            "Type" => entry_type = value.trim(),
            "MimeType" => mime_types = value.trim(),
            "Hidden" => hidden = value.trim().eq_ignore_ascii_case("true"),
            "NoDisplay" => no_display = value.trim().eq_ignore_ascii_case("true"),
            _ => {}
        }
    }
    let identifier = path.file_name()?.to_str()?;
    if entry_type != "Application"
        || hidden
        || no_display
        || name.is_empty()
        || name.len() > MAX_BROWSER_NAME_LENGTH
        || !mime_types
            .split(';')
            .any(|mime| mime == "x-scheme-handler/https")
    {
        return None;
    }
    Some(Browser {
        id: identifier.into(),
        name: name.into(),
        is_default: false,
        desktop_path: path.canonicalize().ok()?,
    })
}

fn read_bounded(path: &Path, limit: u64) -> Option<String> {
    // Validate and read through one descriptor. Reopening the path after a
    // metadata check would allow a symlink swap or an unbounded replacement.
    let file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(path)
        .ok()?;
    let metadata = file.metadata().ok()?;
    if !metadata.file_type().is_file() || metadata.len() > limit {
        return None;
    }
    let mut raw = Vec::new();
    file.take(limit + 1).read_to_end(&mut raw).ok()?;
    if raw.len() as u64 > limit {
        return None;
    }
    String::from_utf8(raw).ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn discovers_https_browsers_with_default_first() {
        let temp = tempdir().unwrap();
        fs::write(
            temp.path().join("alpha.desktop"),
            "[Desktop Entry]\nType=Application\nName=Alpha\nMimeType=x-scheme-handler/https;\n",
        )
        .unwrap();
        fs::write(
            temp.path().join("zeta.desktop"),
            "[Desktop Entry]\nType=Application\nName=Zeta\nMimeType=text/html;x-scheme-handler/https;\n",
        )
        .unwrap();
        fs::write(
            temp.path().join("editor.desktop"),
            "[Desktop Entry]\nType=Application\nName=Editor\nMimeType=text/plain;\n",
        )
        .unwrap();
        let browsers = discover_in(&[temp.path().into()], Some("zeta.desktop"));
        assert_eq!(browsers.len(), 2);
        assert_eq!(browsers[0].id, "zeta.desktop");
        assert!(browsers[0].is_default);
        assert_eq!(browsers[1].id, "alpha.desktop");
    }

    #[test]
    fn reads_https_default_from_mimeapps() {
        let temp = tempdir().unwrap();
        let path = temp.path().join("mimeapps.list");
        fs::write(
            &path,
            "[Default Applications]\nx-scheme-handler/http=other.desktop;\nx-scheme-handler/https=browser.desktop;fallback.desktop;\n",
        )
        .unwrap();
        assert_eq!(
            default_from_mimeapps(&path).as_deref(),
            Some("browser.desktop")
        );
    }

    #[test]
    fn symlinked_desktop_and_mimeapps_files_are_not_read() {
        let temp = tempdir().unwrap();
        let real_desktop = temp.path().join("real");
        fs::write(
            &real_desktop,
            "[Desktop Entry]\nName=Browser\nMimeType=x-scheme-handler/https;\n",
        )
        .unwrap();
        let desktop = temp.path().join("browser.desktop");
        std::os::unix::fs::symlink(&real_desktop, &desktop).unwrap();
        assert!(parse_desktop_file(&desktop).is_none());

        let real_mimeapps = temp.path().join("real-mimeapps");
        fs::write(
            &real_mimeapps,
            "[Default Applications]\nx-scheme-handler/https=browser.desktop;\n",
        )
        .unwrap();
        let mimeapps = temp.path().join("mimeapps.list");
        std::os::unix::fs::symlink(&real_mimeapps, &mimeapps).unwrap();
        assert!(default_from_mimeapps(&mimeapps).is_none());
    }
}
