//! attop i18n — user-facing PROSE as a swappable string table (the user's
//! "i18n support"). Same global-active pattern as theme.zig: resolved once
//! at startup, read by the (pure) renders. Only translatable prose lives
//! here — shell commands, identifiers (pid/eBPF/cwd), and the `atty` brand
//! stay literal in the renders (you don't localize `sudo systemctl …`).
//! Templated lines keep their comptime std.fmt skeleton in code and pull
//! the words from here as {s} args (a runtime string can't be a format).

const std = @import("std");

pub const Strings = struct {
    // Screen title suffixes ("Guard" + suffix). The short nav titles stay
    // literal — they pair with the footer keybindings.
    suffix_dashboard: []const u8,
    suffix_security: []const u8,
    suffix_sessions: []const u8,
    suffix_health: []const u8,
    suffix_help: []const u8,

    // Help screen section labels
    help_keys: []const u8,
    help_display: []const u8,
    help_language: []const u8,
    help_needs_daemon: []const u8,

    // Home
    protected: []const u8,
    unguarded: []const u8,
    today: []const u8,
    word_commands: []const u8,
    word_threats_blocked: []const u8,
    terminals_active_one: []const u8, // "{d} <this>"
    terminals_active_many: []const u8,
    metrics_off: []const u8, // Home: instances==0 → don't show 0s as if real

    // Shared daemon states
    not_running: []const u8, // "atty-guard not running"
    not_reachable: []const u8, // "atty-guard not reachable"

    // Guard
    not_listed_rung: []const u8,
    word_kernel: []const u8,
    word_switch: []const u8,

    // Fleet
    no_sessions: []const u8,
    fleet_terminals_one: []const u8, // "{d} <this>" (the fleet total)
    fleet_terminals_many: []const u8,

    // Setup statuses
    st_installed: []const u8,
    st_not_installed: []const u8,
    st_wired: []const u8,
    st_not_wired: []const u8,
    st_running: []const u8,
    st_not_reachable: []const u8,
    st_attached: []const u8,
    st_off: []const u8,
    st_unknown: []const u8,
    daemon_down: []const u8, // "unknown (daemon down)"
    st_warn_only: []const u8,
    st_in_session: []const u8,
    st_not_under_atty: []const u8,
    st_no_sessions: []const u8,
    session_reporting_one: []const u8, // "{d} <this>"
    session_reporting_many: []const u8,

    // Fix lines — full messages. Embedded commands/identifiers (sudo …,
    // metrics_exporter, atty) are positioned, NOT translated (standard
    // message-catalog practice).
    fix_start_daemon: []const u8,
    fix_daemon_unreachable: []const u8,
    fix_raise_profile: []const u8,
    fix_ebpf_install: []const u8,
    fix_enable_metrics: []const u8,
    fix_install_atty: []const u8,
    fix_wire_shell: []const u8,
    fix_run_atty: []const u8,
    fleet_enable_hint: []const u8,
};

pub const en = Strings{
    .suffix_dashboard = " \u{2014} dashboard",
    .suffix_security = " \u{2014} security profile",
    .suffix_sessions = " \u{2014} atty sessions",
    .suffix_health = " \u{2014} health check",
    .suffix_help = " \u{2014} help",
    .help_keys = "Keys",
    .help_display = "Display",
    .help_language = "Language",
    .help_needs_daemon = "Live data needs the atty-guard daemon running.",
    .protected = "Protected",
    .unguarded = "Unguarded",
    .today = "Today",
    .word_commands = "commands",
    .word_threats_blocked = "threats blocked",
    .terminals_active_one = "terminal active",
    .terminals_active_many = "terminals active",
    .metrics_off = "no metrics — enable metrics_exporter or start a session",
    .not_running = "atty-guard not running",
    .not_reachable = "atty-guard not reachable",
    .not_listed_rung = "not a listed rung",
    .word_kernel = "kernel",
    .word_switch = "switch",
    .no_sessions = "no atty sessions reporting",
    .fleet_terminals_one = "terminal",
    .fleet_terminals_many = "terminals",
    .st_installed = "installed",
    .st_not_installed = "not installed",
    .st_wired = "wired",
    .st_not_wired = "not wired",
    .st_running = "running",
    .st_not_reachable = "not reachable",
    .st_attached = "attached",
    .st_off = "off",
    .st_unknown = "unknown",
    .daemon_down = "unknown (daemon down)",
    .st_warn_only = "prompt (warn-only)",
    .st_in_session = "in an atty session",
    .st_not_under_atty = "not under atty",
    .st_no_sessions = "no sessions",
    .session_reporting_one = "session reporting",
    .session_reporting_many = "sessions reporting",
    .fix_start_daemon = "start it:  sudo systemctl start atty-guard",
    .fix_daemon_unreachable = "is it running?  sudo systemctl start atty-guard",
    .fix_raise_profile = "raise it in the Guard panel ([g])",
    .fix_ebpf_install = "install: sudo make install-guard GUARD_FEATURES=...,ebpf",
    .fix_enable_metrics = "enable the metrics_exporter module",
    .fix_install_atty = "install: curl -fsSL https://bin.atty.sh | sh",
    .fix_wire_shell = "wire it: ", // render appends eval "$(atty init <shell>)"
    .fix_run_atty = "run: atty",
    .fleet_enable_hint = "(enable the metrics_exporter module — see docs/dashboard.md)",
};

/// Proof locale (German). Kept short to fit the responsive widths.
pub const de = Strings{
    .suffix_dashboard = " \u{2014} Dashboard",
    .suffix_security = " \u{2014} Sicherheitsprofil",
    .suffix_sessions = " \u{2014} atty-Sitzungen",
    .suffix_health = " \u{2014} Statusprüfung",
    .suffix_help = " \u{2014} Hilfe",
    .help_keys = "Tasten",
    .help_display = "Anzeige",
    .help_language = "Sprache",
    .help_needs_daemon = "Live-Daten brauchen den laufenden atty-guard-Daemon.",
    .protected = "Geschützt",
    .unguarded = "Ungeschützt",
    .today = "Heute",
    .word_commands = "Befehle",
    .word_threats_blocked = "Bedrohungen geblockt",
    .terminals_active_one = "Terminal aktiv",
    .terminals_active_many = "Terminals aktiv",
    .metrics_off = "keine Metriken — metrics_exporter aktivieren oder Sitzung starten",
    .not_running = "atty-guard läuft nicht",
    .not_reachable = "atty-guard nicht erreichbar",
    .not_listed_rung = "keine gelistete Stufe",
    .word_kernel = "Kernel",
    .word_switch = "Wechsel",
    .no_sessions = "keine atty-Sitzungen gemeldet",
    .fleet_terminals_one = "Terminal",
    .fleet_terminals_many = "Terminals",
    .st_installed = "installiert",
    .st_not_installed = "nicht installiert",
    .st_wired = "verdrahtet",
    .st_not_wired = "nicht verdrahtet",
    .st_running = "läuft",
    .st_not_reachable = "nicht erreichbar",
    .st_attached = "aktiv",
    .st_off = "aus",
    .st_unknown = "unbekannt",
    .daemon_down = "unbekannt (Daemon aus)",
    .st_warn_only = "prompt (nur Warnung)",
    .st_in_session = "in einer atty-Sitzung",
    .st_not_under_atty = "nicht unter atty",
    .st_no_sessions = "keine Sitzungen",
    .session_reporting_one = "Sitzung gemeldet",
    .session_reporting_many = "Sitzungen gemeldet",
    .fix_start_daemon = "starten:  sudo systemctl start atty-guard",
    .fix_daemon_unreachable = "läuft er?  sudo systemctl start atty-guard",
    .fix_raise_profile = "im Guard-Panel anheben ([g])",
    .fix_ebpf_install = "installieren: sudo make install-guard GUARD_FEATURES=...,ebpf",
    .fix_enable_metrics = "Modul metrics_exporter aktivieren",
    .fix_install_atty = "installieren: curl -fsSL https://bin.atty.sh | sh",
    .fix_wire_shell = "einrichten: ", // render appends eval "$(atty init <shell>)"
    .fix_run_atty = "ausführen: atty",
    .fleet_enable_hint = "(Modul metrics_exporter aktivieren — siehe docs/dashboard.md)",
};

/// The active string table — set once at startup (see `resolve`).
pub var active: Strings = en;

/// Resolve the locale: `$ATTOP_LANG` override; else `$LC_ALL` then `$LANG`
/// (LC_ALL wins, per POSIX) prefix (e.g. "de_DE.UTF-8" → "de"); else English.
pub fn resolve() Strings {
    if (std.c.getenv("ATTOP_LANG")) |p| {
        // Accept a bare code or a full locale ("de" or "de_DE.UTF-8").
        if (byLang(langPrefix(std.mem.span(p)))) |s| return s;
    }
    const envs = [_][*:0]const u8{ "LC_ALL", "LANG" };
    for (envs) |e| {
        if (std.c.getenv(e)) |p| {
            if (byLang(langPrefix(std.mem.span(p)))) |s| return s;
        }
    }
    return en;
}

/// The language part of a POSIX locale: "de_DE.UTF-8" → "de", "C" → "C".
pub fn langPrefix(locale: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, locale, "_.@") orelse locale.len;
    return locale[0..end];
}

/// Table by language code (the 2-letter prefix), or null if unsupported.
pub fn byLang(code: []const u8) ?Strings {
    if (std.mem.eql(u8, code, "en")) return en;
    if (std.mem.eql(u8, code, "de")) return de;
    return null;
}

test {
    _ = @import("i18n_tests.zig");
}
