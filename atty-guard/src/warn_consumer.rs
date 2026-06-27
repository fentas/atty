//! Drains VERDICT_WARN events from the kernel-side ringbuf and
//! fans them out to in-process subscribers (added/removed via
//! `register_subscriber` from server.rs's SubscribeWarnEvents
//! handler).
//!
//! Lives behind the `ebpf` cargo feature. Without it, the daemon
//! is unchanged: subscribers get nothing (the no-feature stub
//! returns a `Subscribed` ack then idles until disconnect — same
//! semantics as a healthy subscribe to a no-warn-mode daemon).
//!
//! Wire-format invariant: the `ExecveEvent` struct mirrors
//! `atty-guard/ebpf/atty_guard.bpf.c`'s C struct byte-for-byte.
//! Layout is hand-padded so `#[repr(C)]` matches without
//! compiler-padding surprises (BPF map values aren't CO-RE-
//! relocated — see #347 design comment). Any change to the C
//! struct MUST update this Rust mirror in lockstep.

use crate::protocol::ResponseBody;

/// One slot in the broadcast list. `pid_tree_root` is the PID
/// the subscriber registered as its ancestor; events whose pid
/// (or any ancestor up to pid 1) doesn't match get filtered out
/// before the channel send.
///
/// `pid_tree_root = 0` means "no filter" — operator-debug
/// subscribers (e.g. `atty-guard subscribe-warns` CLI) want the
/// full stream.
///
/// `tx` is a SyncSender (bounded) so a slow subscriber drops
/// the oldest event (via `try_send` returning Full) instead of
/// growing the daemon's memory unbounded. `dropped_since_notice`
/// counts the drops between `WarnDropped` notice emissions so
/// the subscriber knows they fell behind.
pub struct Subscriber {
    pub pid_tree_root: u32,
    pub tx: std::sync::mpsc::SyncSender<ResponseBody>,
    pub dropped_since_notice: std::cell::Cell<u32>,
    /// Unique registration id, assigned by `register`. Lets a
    /// subscriber deregister explicitly on disconnect instead of
    /// waiting for the next `broadcast()` to reap its dead sender.
    id: u64,
}

impl Subscriber {
    pub fn new(pid_tree_root: u32, tx: std::sync::mpsc::SyncSender<ResponseBody>) -> Self {
        Self {
            pid_tree_root,
            tx,
            dropped_since_notice: std::cell::Cell::new(0),
            id: 0,
        }
    }
}

/// Thread-safe broadcast list. `register` appends a subscriber;
/// the consumer thread drops senders whose downstream receivers
/// have disconnected. Kept generic over the channel type so unit
/// tests can substitute mpsc / crossbeam / Vec sinks.
#[derive(Default)]
pub struct Broadcast {
    subs: std::sync::Mutex<Vec<Subscriber>>,
    next_id: std::sync::atomic::AtomicU64,
}

impl Broadcast {
    pub fn new() -> Self {
        Self::default()
    }

    /// Append a subscriber and return its registration id. Pass the
    /// id to `deregister` on disconnect so a quiet subscriber (no
    /// events flowing, so `broadcast`'s lazy reap never runs) doesn't
    /// linger in the list and grow it unbounded across
    /// connect/subscribe/disconnect cycles.
    pub fn register(&self, mut sub: Subscriber) -> u64 {
        let id = self
            .next_id
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        sub.id = id;
        self.subs.lock().expect("broadcast poisoned").push(sub);
        id
    }

    /// Remove the subscriber with `id` if still present (it may have
    /// already been reaped by a `broadcast` that found its receiver
    /// gone). Idempotent.
    pub fn deregister(&self, id: u64) {
        self.subs
            .lock()
            .expect("broadcast poisoned")
            .retain(|s| s.id != id);
    }

    /// Fan a single ResponseBody out to all matching subscribers.
    /// Drops disconnected subscribers; slow subscribers (inbox
    /// full) get the event dropped + a `WarnDropped` notice
    /// queued on their next-event opportunity. `pid_tree_match`
    /// decides if an event matches a given subscriber's root —
    /// caller-supplied so the (potentially I/O-bound) /proc walk
    /// can be stubbed in tests.
    pub fn broadcast<F>(&self, event_pid: u32, body: ResponseBody, mut pid_tree_match: F)
    where
        F: FnMut(u32, u32) -> bool,
    {
        let mut subs = self.subs.lock().expect("broadcast poisoned");
        subs.retain(|s| {
            if s.pid_tree_root != 0 && !pid_tree_match(event_pid, s.pid_tree_root) {
                // Not for this subscriber — keep them around but
                // don't forward.
                return true;
            }
            // Flush the WarnDropped notice first if there's a
            // pending count — the subscriber needs to learn
            // they missed events BEFORE seeing the next live
            // one. Best-effort: if their inbox is still full
            // we'll try again next time.
            let pending = s.dropped_since_notice.get();
            if pending > 0 {
                if s.tx
                    .try_send(ResponseBody::WarnDropped { count: pending })
                    .is_ok()
                {
                    s.dropped_since_notice.set(0);
                }
                // If the notice itself couldn't fit either, fall
                // through to attempt the live event; either both
                // queue or both increment the drop counter.
            }
            match s.tx.try_send(body.clone()) {
                Ok(()) => true,
                Err(std::sync::mpsc::TrySendError::Full(_)) => {
                    s.dropped_since_notice
                        .set(s.dropped_since_notice.get().saturating_add(1));
                    true
                }
                Err(std::sync::mpsc::TrySendError::Disconnected(_)) => false,
            }
        });
    }

    pub fn len(&self) -> usize {
        self.subs.lock().expect("broadcast poisoned").len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

/// Walks `/proc/<pid>/status` PPid chain looking for `root` as
/// an ancestor (or `pid == root` itself). Stops at pid 1 or any
/// read error. Bounded depth to defend against pathological
/// kernels — cycles shouldn't happen but the loop bound keeps
/// us honest.
///
/// Lives here (not in a generic util) because warn dispatch is
/// the only caller today. If a second use site appears, lift to
/// a `proc.rs` helper.
pub fn pid_in_tree_root(pid: u32, root: u32) -> bool {
    if pid == root || root == 0 {
        return true;
    }
    let mut cursor = pid;
    for _ in 0..64 {
        if cursor <= 1 {
            return false;
        }
        match read_ppid(cursor) {
            Some(ppid) if ppid == root => return true,
            Some(ppid) => cursor = ppid,
            None => return false,
        }
    }
    false
}

fn read_ppid(pid: u32) -> Option<u32> {
    let status = std::fs::read_to_string(format!("/proc/{pid}/status")).ok()?;
    for line in status.lines() {
        if let Some(rest) = line.strip_prefix("PPid:") {
            return rest.trim().parse::<u32>().ok();
        }
    }
    None
}

// ===========================================================================
// Wire-format mirror of atty_guard.bpf.c's execve_event.

const EVENT_EXECVE: u8 = 1;
#[allow(dead_code)]
const EVENT_AF_ALG: u8 = 2;

const VERDICT_TRACE: u8 = 0;
const VERDICT_WARN: u8 = 1;
#[allow(dead_code)]
const VERDICT_BLOCK: u8 = 2;
const VERDICT_CLASSIFY: u8 = 3;

/// Byte-for-byte mirror of the C struct (156 bytes). Hand-padded
/// so `#[repr(C)]` matches the kernel-side layout regardless of
/// rustc / clang padding rules.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct ExecveEvent {
    pub kind: u8,
    pub verdict: u8,
    // Layout-only filler — keep private so callers don't reach
    // for it. Total struct stays 156 bytes (size_of assert below).
    _pad: [u8; 2],
    pub pid: u32,
    pub ppid: u32,
    pub comm: [u8; 16],
    pub argv0: [u8; 128],
}

const _: () = assert!(std::mem::size_of::<ExecveEvent>() == 156);

impl ExecveEvent {
    /// Decode a raw event from the ringbuf. Returns `None` for
    /// truncated buffers — kernel can hand us a runt if the
    /// emitter died mid-write; logging would be noise.
    pub fn from_bytes(bytes: &[u8]) -> Option<Self> {
        if bytes.len() < std::mem::size_of::<Self>() {
            return None;
        }
        let mut e = ExecveEvent {
            kind: 0,
            verdict: 0,
            _pad: [0; 2],
            pid: 0,
            ppid: 0,
            comm: [0; 16],
            argv0: [0; 128],
        };
        unsafe {
            std::ptr::copy_nonoverlapping(
                bytes.as_ptr(),
                &mut e as *mut Self as *mut u8,
                std::mem::size_of::<Self>(),
            );
        }
        Some(e)
    }

    /// True iff this event should be forwarded to warn subscribers.
    /// VERDICT_TRACE and VERDICT_BLOCK go to other code paths
    /// (tracepoint logging / set_threat banner respectively).
    pub fn is_warn(&self) -> bool {
        self.kind == EVENT_EXECVE && self.verdict == VERDICT_WARN
    }

    /// A watch-scoped execve the daemon should classify out-of-band
    /// (security profiles). Distinct from `is_warn` (block-mode pilot).
    #[allow(dead_code)]
    pub fn is_classify(&self) -> bool {
        self.kind == EVENT_EXECVE && self.verdict == VERDICT_CLASSIFY
    }

    /// Convert to a wire-format ResponseBody for subscribers.
    /// `now_ms` is the daemon-side timestamp the consumer thread
    /// passes in (monotonic when available, system time as the
    /// fallback in tests).
    pub fn to_warn_event(&self, now_ms: u64) -> ResponseBody {
        ResponseBody::WarnEvent {
            pid: self.pid,
            ppid: self.ppid,
            comm: cstr_trim(&self.comm),
            argv0: cstr_trim(&self.argv0),
            timestamp_ms: now_ms,
        }
    }
}

fn cstr_trim(buf: &[u8]) -> String {
    let len = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
    String::from_utf8_lossy(&buf[..len]).into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;

    #[test]
    fn execve_event_size_matches_c_struct() {
        // Sentinel — the C struct is 156 bytes; any drift breaks
        // the ringbuf wire contract.
        assert_eq!(std::mem::size_of::<ExecveEvent>(), 156);
    }

    #[test]
    fn from_bytes_rejects_runt() {
        let runt = [0u8; 100];
        assert!(ExecveEvent::from_bytes(&runt).is_none());
    }

    #[test]
    fn from_bytes_roundtrips() {
        let mut buf = vec![0u8; 156];
        buf[0] = EVENT_EXECVE;
        buf[1] = VERDICT_WARN;
        buf[4..8].copy_from_slice(&1234u32.to_ne_bytes());
        buf[8..12].copy_from_slice(&5678u32.to_ne_bytes());
        buf[12..28].copy_from_slice(b"bash\0\0\0\0\0\0\0\0\0\0\0\0");
        buf[28..36].copy_from_slice(b"/bin/ls\0");
        let e = ExecveEvent::from_bytes(&buf).expect("parse");
        assert_eq!(e.kind, EVENT_EXECVE);
        assert_eq!(e.verdict, VERDICT_WARN);
        assert!(e.is_warn());
        assert_eq!(e.pid, 1234);
        assert_eq!(e.ppid, 5678);
        let wire = e.to_warn_event(42);
        match wire {
            ResponseBody::WarnEvent {
                pid,
                ppid,
                comm,
                argv0,
                timestamp_ms,
            } => {
                assert_eq!(pid, 1234);
                assert_eq!(ppid, 5678);
                assert_eq!(comm, "bash");
                assert_eq!(argv0, "/bin/ls");
                assert_eq!(timestamp_ms, 42);
            }
            _ => panic!("expected WarnEvent"),
        }
    }

    #[test]
    fn is_warn_filters_non_warn_events() {
        let mut buf = vec![0u8; 156];
        buf[0] = EVENT_EXECVE;
        buf[1] = VERDICT_TRACE;
        let e = ExecveEvent::from_bytes(&buf).expect("parse");
        assert!(!e.is_warn(), "tracepoint events shouldn't be forwarded");
        buf[1] = VERDICT_BLOCK;
        let e = ExecveEvent::from_bytes(&buf).expect("parse");
        assert!(
            !e.is_warn(),
            "block events go to the banner path, not subscribers"
        );
    }

    #[test]
    fn deregister_removes_by_token_without_a_broadcast() {
        let bcast = Broadcast::new();
        let (tx_a, _rx_a) = mpsc::sync_channel(16);
        let (tx_b, _rx_b) = mpsc::sync_channel(16);
        let id_a = bcast.register(Subscriber::new(0, tx_a));
        let id_b = bcast.register(Subscriber::new(0, tx_b));
        assert_eq!(bcast.len(), 2);
        assert_ne!(id_a, id_b, "registration ids must be unique");
        // Quiet disconnect of A: deregister WITHOUT any broadcast()
        // (the lazy reap never runs when no events flow).
        bcast.deregister(id_a);
        assert_eq!(bcast.len(), 1, "deregister must remove the dead entry");
        // Idempotent — deregistering an already-removed id is a no-op.
        bcast.deregister(id_a);
        assert_eq!(bcast.len(), 1);
        bcast.deregister(id_b);
        assert_eq!(bcast.len(), 0);
    }

    #[test]
    fn broadcast_drops_disconnected_subscriber() {
        let bcast = Broadcast::new();
        let (tx, rx) = mpsc::sync_channel(16);
        bcast.register(Subscriber::new(0, tx));
        assert_eq!(bcast.len(), 1);
        drop(rx); // simulate subscriber disconnect
        bcast.broadcast(
            123,
            ResponseBody::WarnEvent {
                pid: 123,
                ppid: 1,
                comm: "x".into(),
                argv0: "x".into(),
                timestamp_ms: 0,
            },
            |_pid, _root| true,
        );
        assert_eq!(bcast.len(), 0, "disconnected subscriber should be reaped");
    }

    #[test]
    fn broadcast_filters_by_pid_tree() {
        let bcast = Broadcast::new();
        let (tx_alice, rx_alice) = mpsc::sync_channel(16);
        let (tx_bob, rx_bob) = mpsc::sync_channel(16);
        // alice's atty proxy: subscribed to its own PID tree
        // (parent_pid_tree = 999, alice's atty pid).
        bcast.register(Subscriber::new(999, tx_alice));
        // bob's atty proxy: subscribed to a different tree.
        bcast.register(Subscriber::new(888, tx_bob));
        // event from bob's tree (pid 1234 has bob's atty 888 as
        // ancestor); the filter closure returns true only for bob.
        bcast.broadcast(
            1234,
            ResponseBody::WarnEvent {
                pid: 1234,
                ppid: 888,
                comm: "rm".into(),
                argv0: "/bin/rm".into(),
                timestamp_ms: 0,
            },
            |_evt_pid, root| root == 888,
        );
        assert!(
            rx_alice.try_recv().is_err(),
            "alice shouldn't see bob's tree event"
        );
        assert!(
            rx_bob.try_recv().is_ok(),
            "bob should see his own tree event"
        );
    }

    #[test]
    fn broadcast_root_zero_means_no_filter() {
        let bcast = Broadcast::new();
        let (tx, rx) = mpsc::sync_channel(16);
        bcast.register(Subscriber::new(0, tx));
        bcast.broadcast(
            1234,
            ResponseBody::WarnEvent {
                pid: 1234,
                ppid: 1,
                comm: "x".into(),
                argv0: "x".into(),
                timestamp_ms: 0,
            },
            |_p, _r| false, // filter says "doesn't match" — should be IGNORED for root=0
        );
        assert!(rx.try_recv().is_ok(), "root=0 subscriber sees all events");
    }

    #[test]
    fn pid_in_tree_root_self_match() {
        assert!(pid_in_tree_root(1234, 1234));
    }

    #[test]
    fn pid_in_tree_root_zero_is_unfiltered() {
        assert!(pid_in_tree_root(1234, 0));
    }

    #[test]
    fn broadcast_drops_oldest_when_inbox_full_then_emits_warn_dropped() {
        let bcast = Broadcast::new();
        // Inbox of 2: third push drops, fourth drops, fifth drops.
        // First subsequent push after rx drains should carry the
        // WarnDropped notice before the live event.
        let (tx, rx) = mpsc::sync_channel(2);
        bcast.register(Subscriber::new(0, tx));
        let event = || ResponseBody::WarnEvent {
            pid: 1,
            ppid: 1,
            comm: "x".into(),
            argv0: "x".into(),
            timestamp_ms: 0,
        };
        // Fill the inbox plus a few drops on top.
        for _ in 0..5 {
            bcast.broadcast(1, event(), |_p, _r| true);
        }
        // Drain the two queued events.
        for _ in 0..2 {
            match rx.recv().unwrap() {
                ResponseBody::WarnEvent { .. } => {}
                other => panic!("expected WarnEvent, got {other:?}"),
            }
        }
        // Next broadcast should: try to send pending WarnDropped
        // notice (succeeds since inbox is empty), then send the
        // event. Verify both.
        bcast.broadcast(1, event(), |_p, _r| true);
        match rx.recv().unwrap() {
            ResponseBody::WarnDropped { count } => {
                assert_eq!(count, 3, "should have counted the 3 dropped events");
            }
            other => panic!("expected WarnDropped first, got {other:?}"),
        }
        match rx.recv().unwrap() {
            ResponseBody::WarnEvent { .. } => {}
            other => panic!("expected WarnEvent after notice, got {other:?}"),
        }
    }
}
