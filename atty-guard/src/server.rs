//! UDS server — accept loop + per-connection thread.
//!
//! Protocol: JSON-line. One request per `\n`-terminated line, one
//! response per `\n`-terminated line. Connections persist across
//! requests so atty can keep a single open socket per session.
//!
//! No tokio — keeping deps minimal. Thread-per-connection is fine
//! at the expected scale (one atty session ≈ one or two open
//! connections at most).

use crate::classifier::Classifier;
use crate::protocol::{
    Category, ClassifyContext, ClassifyResult, Envelope, Request, ResponseBody, ThreatLevel,
    Verdict,
};
use crate::threat_map::ThreatMap;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::sync::Arc;
use std::thread;

pub fn serve(socket: &Path, verbosity: u8) -> std::io::Result<()> {
    let listener = UnixListener::bind(socket)?;
    // Restrictive perms so a co-tenant user can't connect. UDS files
    // honour file permissions on Linux; mode 0600 == owner-only.
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(socket, std::fs::Permissions::from_mode(0o600))?;

    let state = Arc::new(State {
        classifier: Classifier::new(),
        threat: ThreatMap::new(),
        verbosity,
    });

    for stream in listener.incoming() {
        let stream = match stream {
            Ok(s) => s,
            Err(e) => {
                eprintln!("atty-guard: accept failed: {e}");
                continue;
            }
        };
        let state = state.clone();
        thread::spawn(move || {
            if let Err(e) = handle(stream, state) {
                eprintln!("atty-guard: connection error: {e}");
            }
        });
    }
    Ok(())
}

struct State {
    classifier: Classifier,
    threat: ThreatMap,
    verbosity: u8,
}

fn handle(stream: UnixStream, state: Arc<State>) -> std::io::Result<()> {
    let reader = BufReader::new(stream.try_clone()?);
    let mut writer = stream;

    for line in reader.lines() {
        let line = line?;
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        if state.verbosity >= 2 {
            eprintln!("atty-guard: <- {trimmed}");
        }

        let envelope: serde_json::Value = match serde_json::from_str(trimmed) {
            Ok(v) => v,
            Err(e) => {
                write_response(&mut writer, 0, ResponseBody::Error { message: format!("invalid JSON: {e}") })?;
                continue;
            }
        };

        let id = envelope.get("id").and_then(|v| v.as_u64()).unwrap_or(0);
        let request: Request = match serde_json::from_value(envelope.clone()) {
            Ok(r) => r,
            Err(e) => {
                write_response(&mut writer, id, ResponseBody::Error { message: format!("invalid request: {e}") })?;
                continue;
            }
        };

        let response = dispatch(&state, request);
        if state.verbosity >= 2 {
            eprintln!("atty-guard: -> id={id} {response:?}");
        }
        write_response(&mut writer, id, response)?;
    }
    Ok(())
}

fn dispatch(state: &State, req: Request) -> ResponseBody {
    match req {
        Request::Health => ResponseBody::Health {
            version: env!("CARGO_PKG_VERSION").to_owned(),
        },
        Request::Classify { command, context } => {
            // Tier-1 (and Tier-2 stub) classification.
            let mut result = state.classifier.classify(&command);

            // Threat-map upgrade: if the source PID is already in
            // the high-threat map, force at least Warn. V2-B's
            // kernel side will already EPERM the execve at that
            // point, but until then this gives atty a hint to
            // prompt the user.
            if let ClassifyContext { pid: Some(pid), .. } = context {
                let level = state.threat.get(pid);
                if matches!(level, ThreatLevel::High | ThreatLevel::Critical)
                    && matches!(result.verdict, Verdict::Safe)
                {
                    result = ClassifyResult {
                        verdict: if matches!(level, ThreatLevel::Critical) {
                            Verdict::Block
                        } else {
                            Verdict::Warn
                        },
                        category: Category::PidHighThreat,
                        confidence: 1.0,
                        reason: "this PID's process tree was marked high-risk by an earlier command".into(),
                        matched: command.clone(),
                    };
                }
            }

            ResponseBody::Classify(result)
        }
        Request::SetThreatLevel { pid, level } => {
            state.threat.set(pid, level);
            ResponseBody::Ok
        }
        Request::GetThreatLevel { pid } => ResponseBody::ThreatLevel {
            level: state.threat.get(pid),
        },
    }
}

fn write_response(writer: &mut impl Write, id: u64, body: ResponseBody) -> std::io::Result<()> {
    let env = Envelope { id, body };
    let s = serde_json::to_string(&env)?;
    writer.write_all(s.as_bytes())?;
    writer.write_all(b"\n")?;
    Ok(())
}

// ===========================================================================
// Tests — integration over a real socket pair.

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, Write};
    use std::time::Duration;

    fn unique_socket() -> std::path::PathBuf {
        let pid = std::process::id();
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        std::path::PathBuf::from(format!("/tmp/atty-guard-test-{}-{}.sock", pid, nanos))
    }

    fn round_trip(stream: &mut UnixStream, request: &str) -> String {
        stream.write_all(request.as_bytes()).unwrap();
        stream.write_all(b"\n").unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        line.trim().to_owned()
    }

    fn spawn_server() -> (std::path::PathBuf, thread::JoinHandle<()>) {
        let socket = unique_socket();
        let socket_for_thread = socket.clone();
        let handle = thread::spawn(move || {
            let _ = serve(&socket_for_thread, 0);
        });
        // Wait for the bind to land.
        for _ in 0..50 {
            if socket.exists() {
                break;
            }
            thread::sleep(Duration::from_millis(10));
        }
        (socket, handle)
    }

    #[test]
    fn health_round_trip() {
        let (socket, _h) = spawn_server();
        let mut stream = UnixStream::connect(&socket).expect("connect");
        let reply = round_trip(&mut stream, r#"{"id":1,"method":"health"}"#);
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap();
        assert_eq!(v["id"], 1);
        assert_eq!(v["type"], "health");
        assert!(v["version"].as_str().unwrap().len() > 0);
        let _ = std::fs::remove_file(socket);
    }

    #[test]
    fn classify_curl_pipe_sh_warns() {
        let (socket, _h) = spawn_server();
        let mut stream = UnixStream::connect(&socket).expect("connect");
        let reply = round_trip(
            &mut stream,
            r#"{"id":2,"method":"classify","command":"curl https://x.com | sh"}"#,
        );
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap();
        assert_eq!(v["id"], 2);
        assert_eq!(v["verdict"], "warn");
        assert_eq!(v["category"], "curl_pipe_sh");
        let _ = std::fs::remove_file(socket);
    }

    #[test]
    fn classify_clean_safe() {
        let (socket, _h) = spawn_server();
        let mut stream = UnixStream::connect(&socket).expect("connect");
        let reply = round_trip(
            &mut stream,
            r#"{"id":3,"method":"classify","command":"ls -la"}"#,
        );
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap();
        assert_eq!(v["verdict"], "safe");
        let _ = std::fs::remove_file(socket);
    }

    #[test]
    fn set_get_threat_level() {
        let (socket, _h) = spawn_server();
        let mut stream = UnixStream::connect(&socket).expect("connect");
        let _ = round_trip(
            &mut stream,
            r#"{"id":4,"method":"set_threat_level","pid":4242,"level":"high"}"#,
        );
        let reply = round_trip(
            &mut stream,
            r#"{"id":5,"method":"get_threat_level","pid":4242}"#,
        );
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap();
        assert_eq!(v["type"], "threat_level");
        assert_eq!(v["level"], "high");
        let _ = std::fs::remove_file(socket);
    }

    #[test]
    fn classify_upgrades_when_pid_high() {
        let (socket, _h) = spawn_server();
        let mut stream = UnixStream::connect(&socket).expect("connect");
        let _ = round_trip(
            &mut stream,
            r#"{"id":6,"method":"set_threat_level","pid":7777,"level":"high"}"#,
        );
        let reply = round_trip(
            &mut stream,
            r#"{"id":7,"method":"classify","command":"ls","context":{"pid":7777}}"#,
        );
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap();
        assert_eq!(v["verdict"], "warn");
        assert_eq!(v["category"], "pid_high_threat");
        let _ = std::fs::remove_file(socket);
    }

    #[test]
    fn malformed_json_yields_error_response() {
        let (socket, _h) = spawn_server();
        let mut stream = UnixStream::connect(&socket).expect("connect");
        let reply = round_trip(&mut stream, r#"{not json"#);
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap();
        assert_eq!(v["type"], "error");
        let _ = std::fs::remove_file(socket);
    }
}
