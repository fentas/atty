//! Security profiles + the per-exec routing policy.
//!
//! A profile is a user-chosen posture; the `smart` profile routes each
//! in-scope exec to the lightest *sufficient* mechanism. This module is
//! the pure decision core — `RoutingPolicy::decide` maps an
//! `ExecContext` to a `Mechanism`. The kernel/daemon *effectors* that
//! carry out a `Mechanism` are phased in separately (see
//! `docs/security-profiles.md`); `decide` is intentionally a total,
//! branch-only, allocation-free function so it's cheap on the per-exec
//! path and exhaustively unit-testable.

// Phase-1 decision core: the kernel/daemon effectors that consume
// `Mechanism` / `RoutingPolicy` land in later phases (see the design
// note), so the routing types are exercised only by the unit tests for
// now. Allow until the dispatch is wired rather than scatter per-item
// attributes.
#![allow(dead_code)]

use serde::Deserialize;

/// User-chosen posture. Presets over the underlying knobs; see the design
/// note for the guarantee each one actually provides (detection vs
/// prevention — never conflated).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum SecurityProfile {
    /// Proxy pre-Enter only. The typed-command tripwire. No background
    /// action; the historical behavior.
    #[default]
    Prompt,
    /// WATCH-scoped async classify → log/warn. Detection only.
    Audit,
    /// WATCH-scoped async classify → fast-kill. Reactive (kills after the
    /// exec started), not prevention.
    Session,
    /// In-kernel Tier-1 match → sync EPERM. Prevents known shapes only.
    Strict,
    /// WATCH-scoped SIGSTOP-post-exec → full classify → CONT/KILL,
    /// fail-closed. Sync prevention with full classification; accepts
    /// operational risk (may freeze/kill legitimate processes).
    Lockdown,
    /// Per-exec routing to the lightest sufficient mechanism.
    Smart,
}

impl SecurityProfile {
    /// Whether the proxy should mark its shell `WATCH` so the session
    /// subtree is scoped in. Only `prompt` opts out (it does nothing
    /// beyond the prompt path).
    pub fn marks_watch_scope(self) -> bool {
        !matches!(self, Self::Prompt)
    }
}

/// Tier-1 (fast, regex/atom) verdict on a command. Tier-2 (the SLM) is
/// the async/freeze escalation, not represented here — it's *what the
/// heavier mechanisms run*, not an input to routing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tier1Verdict {
    /// High-confidence benign.
    Safe,
    /// No signal either way — the ambiguous bucket.
    Unknown,
    /// Weak signal(s); worth a closer look.
    Suspicious,
    /// Matched a known-bad atom. Actionable on its own.
    KnownBad,
}

/// Coarse system-load signal — a routing input so `smart` backs off
/// under build storms rather than melting the box. Sourced later from
/// classify-queue depth / run-queue (Phase 5 decides).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LoadPressure {
    Normal,
    High,
}

/// What to do about one exec. The effectors that carry these out are
/// phased in (see the design note); `decide` only chooses.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mechanism {
    /// Let it run; take no extra action.
    Allow,
    /// Classify asynchronously and only log/surface — never block.
    WarnAsync,
    /// Classify asynchronously; SIGKILL if malicious. Reactive.
    ClassifyAsyncThenKill,
    /// Refuse synchronously in the LSM hook (Tier-1 already decided).
    BlockInKernel,
    /// SIGSTOP post-exec, full classify, then CONT/KILL. Fail-closed.
    FreezeAndFrisk,
}

/// Per-exec facts the policy routes on. Filled by the caller from the
/// exec event + the session state.
#[derive(Debug, Clone, Copy)]
pub struct ExecContext {
    pub tier1: Tier1Verdict,
    /// The binary is a general-purpose interpreter (node/python/sh/…) —
    /// the high-risk shape for staged payloads.
    pub is_interpreter: bool,
    /// The exec's parent is the interactive shell itself (i.e. the user
    /// likely typed it) vs. a program that spawned it (more suspicious).
    pub parent_is_interactive_shell: bool,
    /// The exec is inside the marked atty-session subtree. Out-of-scope
    /// execs are never acted on regardless of profile.
    pub in_watch_scope: bool,
    pub load: LoadPressure,
}

/// The configured posture + the consent knobs the policy needs.
#[derive(Debug, Clone, Copy)]
pub struct RoutingPolicy {
    pub profile: SecurityProfile,
    /// Whether `smart` may escalate to `FreezeAndFrisk` (lockdown-grade).
    /// `smart` never silently exceeds the operator's consented ceiling:
    /// without this it tops out at `ClassifyAsyncThenKill`.
    pub smart_can_freeze: bool,
}

impl RoutingPolicy {
    /// Choose the mechanism for one exec. Total, branch-only,
    /// allocation-free.
    pub fn decide(&self, ctx: &ExecContext) -> Mechanism {
        use Mechanism::*;
        use SecurityProfile::*;
        use Tier1Verdict::*;

        // Only the marked session subtree is ever acted on. (Under
        // `prompt` nothing is marked, so this is also its blanket Allow.)
        if !ctx.in_watch_scope {
            return Allow;
        }

        match self.profile {
            Prompt => Allow,
            Audit => match ctx.tier1 {
                Safe => Allow,
                _ => WarnAsync,
            },
            Session => match ctx.tier1 {
                Safe => Allow,
                _ => ClassifyAsyncThenKill,
            },
            Strict => match ctx.tier1 {
                KnownBad => BlockInKernel,
                _ => Allow, // strict prevents only known shapes, synchronously
            },
            Lockdown => match ctx.tier1 {
                Safe => Allow,
                KnownBad => BlockInKernel, // Tier-1 already knows — block free, no freeze
                Suspicious | Unknown => FreezeAndFrisk,
            },
            Smart => self.decide_smart(ctx),
        }
    }

    /// `smart`: lightest sufficient mechanism. Known-bad blocked for free
    /// in-kernel; clearly-safe allowed; the SLM/freeze cost paid *only*
    /// for the genuinely-ambiguous high-risk shape, and degraded under
    /// load.
    fn decide_smart(&self, ctx: &ExecContext) -> Mechanism {
        use Mechanism::*;
        use Tier1Verdict::*;

        match ctx.tier1 {
            KnownBad => BlockInKernel, // sync, free, TOCTOU-safe
            Safe => Allow,             // cheapest
            Suspicious | Unknown => {
                // Only pay for the risky shape: an interpreter spawned by
                // something other than the interactive shell (i.e. by a
                // program — the staged-payload pattern). Anything else is
                // low-risk; don't tax it.
                let risky = ctx.is_interpreter && !ctx.parent_is_interactive_shell;
                if !risky {
                    Allow
                } else {
                    match ctx.load {
                        // Back off under build storms: observe, don't gate.
                        LoadPressure::High => WarnAsync,
                        LoadPressure::Normal => {
                            if self.smart_can_freeze {
                                FreezeAndFrisk
                            } else {
                                ClassifyAsyncThenKill
                            }
                        }
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ctx(tier1: Tier1Verdict) -> ExecContext {
        // Default: the risky shape (interpreter from a non-shell parent),
        // in scope, normal load. Individual tests tweak fields.
        ExecContext {
            tier1,
            is_interpreter: true,
            parent_is_interactive_shell: false,
            in_watch_scope: true,
            load: LoadPressure::Normal,
        }
    }

    fn policy(profile: SecurityProfile, smart_can_freeze: bool) -> RoutingPolicy {
        RoutingPolicy { profile, smart_can_freeze }
    }

    #[test]
    fn only_prompt_skips_watch_scope() {
        assert_eq!(SecurityProfile::default(), SecurityProfile::Prompt);
        assert!(!SecurityProfile::Prompt.marks_watch_scope());
        for p in [
            SecurityProfile::Audit,
            SecurityProfile::Session,
            SecurityProfile::Strict,
            SecurityProfile::Lockdown,
            SecurityProfile::Smart,
        ] {
            assert!(p.marks_watch_scope());
        }
    }

    #[test]
    fn out_of_scope_is_always_allowed() {
        let mut c = ctx(Tier1Verdict::KnownBad);
        c.in_watch_scope = false;
        for prof in [
            SecurityProfile::Audit,
            SecurityProfile::Session,
            SecurityProfile::Strict,
            SecurityProfile::Lockdown,
            SecurityProfile::Smart,
        ] {
            assert_eq!(policy(prof, true).decide(&c), Mechanism::Allow, "{prof:?}");
        }
    }

    #[test]
    fn prompt_never_acts_in_background() {
        for v in [Tier1Verdict::Safe, Tier1Verdict::Unknown, Tier1Verdict::KnownBad] {
            assert_eq!(policy(SecurityProfile::Prompt, true).decide(&ctx(v)), Mechanism::Allow);
        }
    }

    #[test]
    fn audit_warns_but_never_blocks_or_kills() {
        let p = policy(SecurityProfile::Audit, true);
        assert_eq!(p.decide(&ctx(Tier1Verdict::Safe)), Mechanism::Allow);
        assert_eq!(p.decide(&ctx(Tier1Verdict::Unknown)), Mechanism::WarnAsync);
        assert_eq!(p.decide(&ctx(Tier1Verdict::KnownBad)), Mechanism::WarnAsync);
    }

    #[test]
    fn session_kills_async_for_anything_not_clearly_safe() {
        let p = policy(SecurityProfile::Session, true);
        assert_eq!(p.decide(&ctx(Tier1Verdict::Safe)), Mechanism::Allow);
        assert_eq!(p.decide(&ctx(Tier1Verdict::Suspicious)), Mechanism::ClassifyAsyncThenKill);
        assert_eq!(p.decide(&ctx(Tier1Verdict::KnownBad)), Mechanism::ClassifyAsyncThenKill);
    }

    #[test]
    fn strict_blocks_only_known_bad_synchronously() {
        let p = policy(SecurityProfile::Strict, true);
        assert_eq!(p.decide(&ctx(Tier1Verdict::KnownBad)), Mechanism::BlockInKernel);
        // Strict has no SLM/async path — ambiguous is allowed (its honest limit).
        assert_eq!(p.decide(&ctx(Tier1Verdict::Suspicious)), Mechanism::Allow);
        assert_eq!(p.decide(&ctx(Tier1Verdict::Unknown)), Mechanism::Allow);
        assert_eq!(p.decide(&ctx(Tier1Verdict::Safe)), Mechanism::Allow);
    }

    #[test]
    fn lockdown_freezes_ambiguous_blocks_known_allows_safe() {
        let p = policy(SecurityProfile::Lockdown, true);
        assert_eq!(p.decide(&ctx(Tier1Verdict::Safe)), Mechanism::Allow);
        assert_eq!(p.decide(&ctx(Tier1Verdict::KnownBad)), Mechanism::BlockInKernel);
        assert_eq!(p.decide(&ctx(Tier1Verdict::Suspicious)), Mechanism::FreezeAndFrisk);
        assert_eq!(p.decide(&ctx(Tier1Verdict::Unknown)), Mechanism::FreezeAndFrisk);
    }

    // ── smart routing — the use-case matrix ────────────────────────────

    #[test]
    fn smart_blocks_known_bad_for_free() {
        // py → node → exploit where the leaf trips a known atom: blocked
        // in-kernel, no SLM, no freeze.
        assert_eq!(
            policy(SecurityProfile::Smart, true).decide(&ctx(Tier1Verdict::KnownBad)),
            Mechanism::BlockInKernel
        );
    }

    #[test]
    fn smart_allows_clearly_safe() {
        assert_eq!(
            policy(SecurityProfile::Smart, true).decide(&ctx(Tier1Verdict::Safe)),
            Mechanism::Allow
        );
    }

    #[test]
    fn smart_does_not_tax_low_risk_shapes() {
        // Ambiguous but NOT the risky shape (e.g. a normal tool, or an
        // interpreter the user typed at the prompt): don't pay.
        let mut typed = ctx(Tier1Verdict::Unknown);
        typed.parent_is_interactive_shell = true; // user typed it
        assert_eq!(policy(SecurityProfile::Smart, true).decide(&typed), Mechanism::Allow);

        let mut not_interp = ctx(Tier1Verdict::Suspicious);
        not_interp.is_interpreter = false;
        assert_eq!(policy(SecurityProfile::Smart, true).decide(&not_interp), Mechanism::Allow);
    }

    #[test]
    fn smart_escalates_risky_ambiguous_by_load_and_consent() {
        // Risky shape + ambiguous + normal load:
        //  - with lockdown consent → freeze-and-frisk
        //  - without → reactive async kill (never silently exceeds the
        //    operator's ceiling)
        let risky = ctx(Tier1Verdict::Unknown);
        assert_eq!(
            policy(SecurityProfile::Smart, true).decide(&risky),
            Mechanism::FreezeAndFrisk
        );
        assert_eq!(
            policy(SecurityProfile::Smart, false).decide(&risky),
            Mechanism::ClassifyAsyncThenKill
        );

        // Under build-storm load, back off to observe-only regardless of
        // consent.
        let mut busy = risky;
        busy.load = LoadPressure::High;
        assert_eq!(policy(SecurityProfile::Smart, true).decide(&busy), Mechanism::WarnAsync);
        assert_eq!(policy(SecurityProfile::Smart, false).decide(&busy), Mechanism::WarnAsync);
    }
}
