use omarchy_bookmarks_worker::{
    Repository,
    protocol::{self, Effect, Request, Response},
};
use std::{
    io::{self, BufRead, Write},
    path::PathBuf,
    sync::mpsc,
    thread,
};

fn main() {
    if let Err(e) = run() {
        let _ = emit(&Response::error(0, e));
        std::process::exit(1)
    }
}
fn run() -> Result<(), String> {
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
        .unwrap_or_else(|| home.join(".local/share"))
        .join("stefanmara.bookmarks");
    let mut repo = Repository::open(
        &data.join("bookmarks.sqlite3"),
        &data.join("bookmarks.json"),
    )
    .map_err(|e| e.to_string())?;
    let (tx, rx) = mpsc::channel::<String>();
    thread::spawn(move || {
        let stdin = io::stdin();
        for line in stdin.lock().lines() {
            match line {
                Ok(v) => {
                    if tx.send(v).is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
    });
    let (metadata_tx, metadata_rx) = mpsc::channel();
    loop {
        while let Ok(response) = metadata_rx.try_recv() {
            emit(&response)?;
        }
        let line = match rx.recv_timeout(std::time::Duration::from_millis(25)) {
            Ok(v) => v,
            Err(mpsc::RecvTimeoutError::Timeout) => continue,
            Err(_) => break,
        };
        let request: Request = match protocol::parse_request(&line) {
            Ok(v) => v,
            Err(message) => {
                emit(&Response::error(0, message))?;
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
                let tx = metadata_tx.clone();
                thread::spawn(move || {
                    let _ = tx.send(protocol::metadata_response(
                        response_id,
                        metadata_request_id,
                        &url,
                    ));
                });
            }
        }
    }
    Ok(())
}
fn emit(response: &Response) -> Result<(), String> {
    let text = protocol::encode_response(response).map_err(str::to_string)?;
    let mut out = io::stdout().lock();
    writeln!(out, "{text}")
        .and_then(|_| out.flush())
        .map_err(|_| "Could not write worker response".into())
}
