//! Strip terminal control sequences from a command string before
//! it reaches the SLM tokeniser.
//!
//! Per Gemini's review (2026-05-19): even a syntax-preserving
//! tokeniser like ModernBERT's gets confused by CSI / OSC escapes
//! embedded in quoted args (e.g. `bash -c "$(printf '\e[?1049h…')"`).
//! atty's `line_state` already cooks the typed line — the typing
//! itself is fine — but a paste can carry escape codes that survive
//! into the committed buffer.
//!
//! Scope: defensive removal of the four byte ranges the BERT / Code
//! tokenisers most consistently miss:
//!   - `\x1b[...` CSI (ESC + `[` + parameter bytes + final letter).
//!   - `\x1b]...` OSC (ESC + `]` + … + BEL or ESC `\`).
//!   - `\x1b(...` charset selectors (ESC + `(` + one byte).
//!   - bare C0 controls outside `\t \n \r` (NUL, BEL, BS, etc.).
//!
//! NOT included: full state-machine parsing for every ANSI variant
//! — the goal is "kill the obvious noise"; anything weird enough to
//! confuse this sanitiser is also a signal worth surfacing to the
//! user, which is what Tier-1 + the conservative thresholds do.

pub fn sanitize_for_classification(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        let b = bytes[i];
        if b == 0x1b && i + 1 < bytes.len() {
            // CSI: ESC [ params final
            if bytes[i + 1] == b'[' {
                i += 2;
                while i < bytes.len() && (bytes[i] < 0x40 || bytes[i] > 0x7e) {
                    i += 1;
                }
                if i < bytes.len() {
                    i += 1; // consume final byte
                }
                continue;
            }
            // OSC: ESC ] data { BEL | ESC \ }
            if bytes[i + 1] == b']' {
                i += 2;
                while i < bytes.len() {
                    if bytes[i] == 0x07 {
                        i += 1;
                        break;
                    }
                    if bytes[i] == 0x1b && i + 1 < bytes.len() && bytes[i + 1] == b'\\' {
                        i += 2;
                        break;
                    }
                    i += 1;
                }
                continue;
            }
            // Charset selector: ESC ( <byte>
            if bytes[i + 1] == b'(' || bytes[i + 1] == b')' {
                i += 3.min(bytes.len() - i);
                continue;
            }
            // Other ESC sequences (single-char): drop the ESC and the
            // following byte conservatively.
            i += 2;
            continue;
        }
        // Strip C0 controls except tab/newline/CR — those are
        // legitimate command-line content (heredocs, multi-line
        // expansions). Stripping `\b` etc removes the in-place
        // overwrite trick from the design doc's edge-case list.
        if b < 0x20 && b != b'\t' && b != b'\n' && b != b'\r' {
            i += 1;
            continue;
        }
        out.push(b);
        i += 1;
    }
    // UTF-8 invariant: we only consumed/skipped byte ranges that the
    // ANSI/CSI/OSC grammar guarantees stay outside multi-byte UTF-8
    // sequences (control bytes 0x00..0x1f never appear inside valid
    // UTF-8 continuation bytes). Safe to round-trip back through
    // String::from_utf8; lossy fallback for paranoia.
    String::from_utf8(out).unwrap_or_else(|e| String::from_utf8_lossy(&e.into_bytes()).into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn passes_through_clean_command() {
        let s = "curl https://example.com/install.sh | sh";
        assert_eq!(sanitize_for_classification(s), s);
    }

    #[test]
    fn strips_csi_color_codes() {
        let s = "echo \x1b[31mred\x1b[0m text";
        assert_eq!(sanitize_for_classification(s), "echo red text");
    }

    #[test]
    fn strips_osc_title_setter() {
        // OSC 0 — set window title — terminated with BEL.
        let s = "\x1b]0;hello\x07ls -la";
        assert_eq!(sanitize_for_classification(s), "ls -la");
    }

    #[test]
    fn strips_osc_st_terminator() {
        // OSC ... ESC \ form.
        let s = "before\x1b]52;c;ZGF0YQ==\x1b\\after";
        assert_eq!(sanitize_for_classification(s), "beforeafter");
    }

    #[test]
    fn strips_c0_controls_keeping_tnr() {
        // Tab, newline, CR survive; BEL + BS + NUL are stripped.
        let s = "a\tb\nc\rd\x07e\x08f";
        assert_eq!(sanitize_for_classification(s), "a\tb\nc\rdef");
    }

    #[test]
    fn handles_alt_screen_csi() {
        // Typical alt-screen entry: ESC [ ? 1049 h
        let s = "before\x1b[?1049hpayload\x1b[?1049lafter";
        assert_eq!(sanitize_for_classification(s), "beforepayloadafter");
    }

    #[test]
    fn preserves_unicode() {
        // The sanitiser MUST NOT corrupt multi-byte UTF-8 runs —
        // emojis, CJK, etc. survive untouched because their bytes
        // are all >= 0x80, which the C0-stripping branch skips.
        let s = "echo 你好🌍 $HOME";
        assert_eq!(sanitize_for_classification(s), s);
    }
}
