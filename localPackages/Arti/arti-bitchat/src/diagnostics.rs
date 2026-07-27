//! Debug-only bridge from Arti's `tracing` output to the host application log.
//!
//! Without this, every `tracing` event inside Arti is discarded, so a bootstrap
//! that hangs is indistinguishable from one that never started. The bridge is
//! off by default and the caller must opt in; release builds of the app never
//! enable it.
//!
//! Log text is not forwarded verbatim. Arti's messages interpolate bridge
//! lines, relay identities, and peer addresses, so this module keeps only the
//! event's target, its level, and the leading run of plain words from the
//! message. The first token that could carry an identifier ends the line. That
//! rule fails closed: an unrecognized token shape is dropped rather than
//! guessed at.

use std::collections::VecDeque;
use std::ffi::{c_char, c_int};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, Once};

use tracing::field::{Field, Visit};
use tracing::level_filters::LevelFilter;
use tracing::span::{Attributes, Id, Record};
use tracing::{Event, Level, Metadata, Subscriber};

/// Ring capacity. The host drains once per second while bootstrapping, so this
/// only has to absorb a burst between polls.
const MAX_BUFFERED_LINES: usize = 512;

/// Longest sanitized message kept, in tokens and in bytes.
const MAX_MESSAGE_TOKENS: usize = 24;
const MAX_MESSAGE_BYTES: usize = 200;

/// Longest word kept intact. Opaque labels that happen to be all letters, such
/// as an onion address, are longer than any English word Arti logs.
const MAX_WORD_LEN: usize = 20;

/// Stands in for a token that could carry an identifier.
const REDACTED: &str = "[x]";

/// Targets worth following below `INFO`. These are the crates that decide
/// whether a pluggable transport is used and whether a bridge is reachable,
/// which is the only question this bridge exists to answer.
const VERBOSE_TARGETS: &[&str] = &[
    "arti_bitchat",
    "arti_client",
    "tor_bridgedesc",
    "tor_chanmgr",
    "tor_guardmgr",
    "tor_ptmgr",
];

/// Followed all the way down to `TRACE`. An unmanaged transport gives the
/// pluggable-transport manager no process to launch, so it can stay silent at
/// `DEBUG` whether or not it ever bound the transport. That ambiguity is the
/// one thing worth extra volume to settle.
const TRACE_TARGETS: &[&str] = &["tor_ptmgr"];

static ENABLED: AtomicBool = AtomicBool::new(false);
static INSTALL: Once = Once::new();
static LINES: Mutex<VecDeque<String>> = Mutex::new(VecDeque::new());

/// Install the subscriber. Idempotent, and inert until diagnostics are enabled.
pub(crate) fn install() {
    INSTALL.call_once(|| {
        // A subscriber installed by the embedding process wins; this is a
        // diagnostic aid, not a reason to fail startup.
        let _ = tracing::subscriber::set_global_default(DiagnosticSubscriber);
    });
}

fn is_enabled() -> bool {
    ENABLED.load(Ordering::Relaxed)
}

fn push(line: String) {
    if let Ok(mut lines) = LINES.lock() {
        if lines.len() == MAX_BUFFERED_LINES {
            lines.pop_front();
        }
        lines.push_back(line);
    }
}

fn pop() -> Option<String> {
    LINES.lock().ok().and_then(|mut lines| lines.pop_front())
}

fn set_enabled(enabled: bool) {
    install();
    ENABLED.store(enabled, Ordering::Relaxed);
    if !enabled {
        if let Ok(mut lines) = LINES.lock() {
            lines.clear();
        }
    }
    // Callsite interest is cached from `enabled`, so the cache has to be
    // dropped for the new setting to take effect on already-seen callsites.
    tracing::callsite::rebuild_interest_cache();
}

/// True when the token is a plain word that cannot carry an identifier.
///
/// Anything with a digit, separator, or delimiter is rejected, which covers
/// addresses, ports, fingerprints, base64 blobs, and bridge lines. Overlong
/// tokens are rejected even when they are all letters.
fn is_plain_word(token: &str) -> bool {
    let word = token.trim_end_matches([',', '.', ';', ':', '!', '?']);
    !word.is_empty()
        && word.len() <= MAX_WORD_LEN
        && word
            .chars()
            .all(|c| c.is_ascii_alphabetic() || c == '-' || c == '\'')
}

/// Replace every token that could carry an identifier and keep the rest.
///
/// Truncating at the first identifier instead would discard the tail of the
/// sentence, and Arti puts the phase it is stuck in after the value it is
/// stuck on. Runs of redacted tokens collapse so a bridge line cannot be
/// counted off from the output.
fn sanitize_message(message: &str) -> String {
    let mut out = String::new();
    let mut tokens = 0;
    let mut truncated = false;
    let mut last_was_redacted = false;
    for token in message.split_whitespace() {
        if tokens == MAX_MESSAGE_TOKENS || out.len() + token.len() > MAX_MESSAGE_BYTES {
            truncated = true;
            break;
        }
        let plain = is_plain_word(token);
        if !plain && last_was_redacted {
            continue;
        }
        if !out.is_empty() {
            out.push(' ');
        }
        out.push_str(if plain { token } else { REDACTED });
        last_was_redacted = !plain;
        tokens += 1;
    }
    if truncated {
        if !out.is_empty() {
            out.push(' ');
        }
        out.push_str("...");
    }
    out
}

fn format_line(metadata: &Metadata<'_>, message: &str) -> String {
    format!(
        "{} {}: {}",
        metadata.target(),
        metadata.level(),
        sanitize_message(message)
    )
}

/// Collects the `message` field and ignores every other field, because field
/// values are exactly where Arti puts addresses and identities.
#[derive(Default)]
struct MessageVisitor {
    message: String,
}

impl Visit for MessageVisitor {
    fn record_debug(&mut self, field: &Field, value: &dyn std::fmt::Debug) {
        if field.name() == "message" && self.message.is_empty() {
            self.message = format!("{:?}", value);
        }
    }
}

struct DiagnosticSubscriber;

impl DiagnosticSubscriber {
    fn interested(metadata: &Metadata<'_>) -> bool {
        if !is_enabled() {
            return false;
        }
        if *metadata.level() <= Level::INFO {
            return true;
        }
        let matches = |targets: &[&str]| {
            targets
                .iter()
                .any(|target| metadata.target().starts_with(target))
        };
        match *metadata.level() {
            Level::DEBUG => matches(VERBOSE_TARGETS) || matches(TRACE_TARGETS),
            _ => matches(TRACE_TARGETS),
        }
    }
}

impl Subscriber for DiagnosticSubscriber {
    fn enabled(&self, metadata: &Metadata<'_>) -> bool {
        Self::interested(metadata)
    }

    fn max_level_hint(&self) -> Option<LevelFilter> {
        if is_enabled() {
            Some(LevelFilter::TRACE)
        } else {
            Some(LevelFilter::OFF)
        }
    }

    fn event(&self, event: &Event<'_>) {
        if !Self::interested(event.metadata()) {
            return;
        }
        let mut visitor = MessageVisitor::default();
        event.record(&mut visitor);
        push(format_line(event.metadata(), &visitor.message));
    }

    // Spans are not reported. Their fields carry the same identifiers as
    // messages, and the event stream alone answers the reachability question.
    fn new_span(&self, _span: &Attributes<'_>) -> Id {
        Id::from_u64(1)
    }

    fn record(&self, _span: &Id, _values: &Record<'_>) {}

    fn record_follows_from(&self, _span: &Id, _follows: &Id) {}

    fn enter(&self, _span: &Id) {}

    fn exit(&self, _span: &Id) {}
}

/// Enable or disable the debug log bridge.
///
/// Disabling also discards anything still buffered.
///
/// # Returns
/// * 0 always
#[no_mangle]
pub extern "C" fn arti_set_diagnostics_enabled(enabled: c_int) -> c_int {
    set_enabled(enabled != 0);
    0
}

/// Take the oldest buffered diagnostic line.
///
/// # Arguments
/// * `buf` - Buffer to write the line into
/// * `len` - Length of the buffer
///
/// # Returns
/// * Number of bytes written (not including null terminator)
/// * -1 if the buffer is unusable or no line is available
#[no_mangle]
pub extern "C" fn arti_next_diagnostic(buf: *mut c_char, len: c_int) -> c_int {
    if buf.is_null() || len <= 0 {
        return -1;
    }
    let Some(line) = pop() else {
        return -1;
    };

    let bytes = line.as_bytes();
    let copy_len = std::cmp::min(bytes.len(), (len - 1) as usize);
    unsafe {
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), buf as *mut u8, copy_len);
        *buf.add(copy_len) = 0;
    }
    copy_len as c_int
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The bridge is process-global, so tests that flip it cannot run
    /// concurrently with each other.
    static TEST_LOCK: Mutex<()> = Mutex::new(());

    /// Messages shaped like the ones Arti emits on the bridge path. Every one
    /// of these carries something that must not reach the host log.
    const SENSITIVE_MESSAGES: &[&str] = &[
        "Launching pluggable transport obfs4 at 127.0.0.1:39050",
        "Bridge 192.0.2.4:80 8FB9F4319E89E5C6223052AA525A192AFBC85D55 is unusable",
        "Adding bridge obfs4 1.2.3.4:9001 cert=AAAAB3NzaC1yc2EAAAADAQABAAABgQ iat-mode=0",
        "connecting to relay at [2001:db8::1]:443",
        "snowflake broker https://snowflake-broker.torproject.net/ returned 1 answer",
        "guard $8FB9F4319E89E5C6 marked as unreachable",
        "peer user@example.com requested exit",
    ];

    #[test]
    fn sanitized_messages_redact_in_place_and_keep_the_tail() {
        assert_eq!(
            sanitize_message("Launching pluggable transport obfs4 at 127.0.0.1:39050"),
            "Launching pluggable transport [x] at [x]"
        );
        // The phase Arti reports comes after the value it is stuck on, so
        // truncating at the identifier would discard the useful half.
        assert_eq!(
            sanitize_message("Stuck at 192.0.2.4:80 Establishing a channel to guard"),
            "Stuck at [x] Establishing a channel to guard"
        );
        assert_eq!(
            sanitize_message("Bootstrapping complete."),
            "Bootstrapping complete."
        );
    }

    #[test]
    fn consecutive_identifiers_collapse_to_one_marker() {
        assert_eq!(
            sanitize_message("bridge 1.2.3.4:9001 ABCD1234 cert=xyz= is down"),
            "bridge [x] is down"
        );
    }

    #[test]
    fn an_overlong_word_is_redacted_even_when_it_is_all_letters() {
        let onion = "a".repeat(MAX_WORD_LEN + 1);
        assert_eq!(sanitize_message(&format!("dialing {onion} now")), "dialing [x] now");
    }

    #[test]
    fn sanitized_messages_never_leak_an_identifier() {
        for message in SENSITIVE_MESSAGES {
            let sanitized = sanitize_message(message);
            for token in sanitized.split_whitespace() {
                assert!(
                    token == "..." || token == REDACTED || is_plain_word(token),
                    "token {token:?} survived sanitizing {message:?}"
                );
            }
            // Independent check: with the redaction markers removed, no
            // character that appears in an address, fingerprint, URL, or
            // bridge parameter may survive.
            let bare = sanitized.replace(REDACTED, "");
            assert!(
                !bare.contains(|c: char| c.is_ascii_digit()
                    || matches!(c, '/' | '=' | '@' | '$' | '[' | ']' | '_')),
                "sanitized {sanitized:?} still carries identifier characters"
            );
        }
    }

    #[test]
    fn an_identifier_in_the_first_token_is_redacted() {
        assert_eq!(sanitize_message("127.0.0.1:39050 refused"), "[x] refused");
        assert_eq!(sanitize_message(""), "");
    }

    #[test]
    fn long_messages_are_bounded() {
        let message = "word ".repeat(200);
        let sanitized = sanitize_message(&message);
        assert!(sanitized.len() <= MAX_MESSAGE_BYTES + 4);
        assert_eq!(sanitized.split_whitespace().count(), MAX_MESSAGE_TOKENS + 1);
    }

    #[test]
    fn the_ring_buffer_drops_oldest_lines_and_drains_in_order() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        set_enabled(true);
        for index in 0..MAX_BUFFERED_LINES + 10 {
            push(format!("line {index}"));
        }
        assert_eq!(pop().as_deref(), Some("line 10"));
        set_enabled(false);
        assert_eq!(pop(), None);
    }

    /// Enabling has to survive callsite interest being cached as
    /// uninteresting while the bridge was off, which is the one way this can
    /// fail silently on device.
    #[test]
    fn enabling_captures_and_sanitizes_a_live_event() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        install();
        set_enabled(false);
        tracing::info!("Launching pluggable transport obfs4 at 127.0.0.1:39050");
        set_enabled(true);
        tracing::info!("Launching pluggable transport obfs4 at 127.0.0.1:39050");

        // Other tests bootstrap Arti in parallel, so pick out this callsite
        // rather than assuming the buffer holds nothing else.
        let mut found = None;
        while let Some(line) = pop() {
            if line.starts_with(module_path!()) {
                found = Some(line);
                break;
            }
        }
        set_enabled(false);
        assert_eq!(
            found.as_deref(),
            Some(
                format!(
                    "{} INFO: Launching pluggable transport [x] at [x]",
                    module_path!()
                )
                .as_str()
            )
        );
    }

    #[test]
    fn events_are_dropped_while_diagnostics_are_disabled() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        set_enabled(false);
        install();
        tracing::error!("Launching pluggable transport");
        assert_eq!(pop(), None);
    }
}
