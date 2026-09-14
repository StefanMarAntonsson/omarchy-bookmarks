use omarchy_bookmarks_worker::{
    Repository,
    protocol::{self, Effect, Response},
};
use std::{
    io::{self, BufRead, Write},
    path::PathBuf,
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
        mpsc,
    },
    thread,
};

const MAX_CONCURRENT_METADATA: usize = 2;

enum Event {
    Line(Result<String, &'static str>),
    Metadata(Response),
    InputClosed,
}

fn main() {
    // Setup verifies a candidate binary with this before installing it.
    if std::env::args().nth(1).as_deref() == Some("--version") {
        println!("omarchy-bookmarks-worker {}", env!("CARGO_PKG_VERSION"));
        return;
    }
    if let Err(e) = run() {
        let _ = emit(&Response::error(0, e));
        std::process::exit(1)
    }
}
fn run() -> Result<(), String> {
    // Backups and import copies contain bookmarks; keep new files private.
    unsafe {
        libc::umask(0o077);
    }
    #[cfg(target_os = "linux")]
    unsafe {
        if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM) < 0 {
            return Err("Could not configure parent-death signal".into());
        }
    }
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or("HOME is not set")?;
    let data = std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .unwrap_or_else(|| home.join(".local/share"))
        .join("stefanmara.bookmarks");
    let mut repo = Repository::open(
        &data.join("bookmarks.sqlite3"),
        &data.join("bookmarks.json"),
    )
    .map_err(|e| e.to_string())?;
    let (tx, rx) = mpsc::channel::<Event>();
    let stdin_tx = tx.clone();
    thread::spawn(move || {
        let mut stdin = io::stdin().lock();
        while let Ok(Some(line)) = read_bounded_line(&mut stdin, protocol::MAX_LINE) {
            if stdin_tx.send(Event::Line(line)).is_err() {
                return;
            }
        }
        let _ = stdin_tx.send(Event::InputClosed);
    });
    let in_flight = Arc::new(AtomicUsize::new(0));
    while let Ok(event) = rx.recv() {
        let line = match event {
            Event::Metadata(response) => {
                emit(&response)?;
                continue;
            }
            Event::InputClosed => break,
            Event::Line(Ok(line)) => line,
            Event::Line(Err(message)) => {
                emit(&Response::error(0, message))?;
                continue;
            }
        };
        let request = match protocol::parse_request(&line) {
            Ok(v) => v,
            Err((id, message)) => {
                emit(&Response::error(id, message))?;
                continue;
            }
        };
        match protocol::handle(&mut repo, request) {
            Effect::Response(r) => emit(&r)?,
            Effect::Metadata {
                response_id,
                metadata_request_id,
                url,
            } => {
                if in_flight.fetch_add(1, Ordering::SeqCst) >= MAX_CONCURRENT_METADATA {
                    in_flight.fetch_sub(1, Ordering::SeqCst);
                    emit(&Response::error(
                        response_id,
                        "Another page lookup is still running",
                    ))?;
                    continue;
                }
                let tx = tx.clone();
                let in_flight = Arc::clone(&in_flight);
                thread::spawn(move || {
                    let response =
                        protocol::metadata_response(response_id, metadata_request_id, &url);
                    in_flight.fetch_sub(1, Ordering::SeqCst);
                    let _ = tx.send(Event::Metadata(response));
                });
            }
        }
    }
    Ok(())
}

/// Reads one newline-terminated line without buffering more than `limit`
/// bytes. Oversized lines are consumed and reported instead of retained.
fn read_bounded_line(
    reader: &mut impl BufRead,
    limit: usize,
) -> io::Result<Option<Result<String, &'static str>>> {
    let mut buffer = Vec::new();
    let read = io::Read::take(&mut *reader, limit as u64 + 1).read_until(b'\n', &mut buffer)?;
    if read == 0 {
        return Ok(None);
    }
    if buffer.last() == Some(&b'\n') {
        buffer.pop();
    } else if buffer.len() > limit {
        loop {
            let available = reader.fill_buf()?;
            if available.is_empty() {
                break;
            }
            match available.iter().position(|&byte| byte == b'\n') {
                Some(position) => {
                    reader.consume(position + 1);
                    break;
                }
                None => {
                    let length = available.len();
                    reader.consume(length);
                }
            }
        }
        return Ok(Some(Err("Protocol message is too large")));
    }
    Ok(Some(
        String::from_utf8(buffer).map_err(|_| "Invalid protocol message"),
    ))
}

fn emit(response: &Response) -> Result<(), String> {
    let text = protocol::encode_response(response);
    let mut out = io::stdout().lock();
    writeln!(out, "{text}")
        .and_then(|_| out.flush())
        .map_err(|_| "Could not write worker response".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bounded_lines_discard_oversized_input_and_continue() {
        let input = format!("{}\nok\n", "x".repeat(100));
        let mut reader = io::BufReader::with_capacity(8, input.as_bytes());
        assert_eq!(
            read_bounded_line(&mut reader, 10).unwrap(),
            Some(Err("Protocol message is too large"))
        );
        assert_eq!(
            read_bounded_line(&mut reader, 10).unwrap(),
            Some(Ok("ok".into()))
        );
        assert_eq!(read_bounded_line(&mut reader, 10).unwrap(), None);
    }

    #[test]
    fn bounded_lines_accept_exact_limit_and_final_line_without_newline() {
        let mut reader = io::BufReader::new("abc\nde".as_bytes());
        assert_eq!(
            read_bounded_line(&mut reader, 3).unwrap(),
            Some(Ok("abc".into()))
        );
        assert_eq!(
            read_bounded_line(&mut reader, 3).unwrap(),
            Some(Ok("de".into()))
        );
    }
}
