# Changelog

All notable changes to atty are documented here. This file is
maintained automatically by [release-please]; manual entries below
that point are merged into the relevant release on the next run.

[release-please]: https://github.com/googleapis/release-please

## [0.7.0](https://github.com/fentas/atty/compare/v0.6.0...v0.7.0) (2026-06-02)


### Features

* **atti:** lifecycle CLI for atty (install + doctor + version) ([#383](https://github.com/fentas/atty/issues/383)) ([e5feedd](https://github.com/fentas/atty/commit/e5feedd87e168ba26bdf55734866e34490b1a80a))


### Bug Fixes

* **docs:** use last URL segment as sidebar module label ([#385](https://github.com/fentas/atty/issues/385)) ([91c0a1e](https://github.com/fentas/atty/commit/91c0a1e88600e9604ad74dd0459194fd126222b4))
* **proxy:** suppress ghost re-engagement after mid-line insert post-recall ([#386](https://github.com/fentas/atty/issues/386)) ([83d33a7](https://github.com/fentas/atty/commit/83d33a714aa003b186fcc43d157100c5fd155eeb))


### Documentation

* split modules page for security_guard / mouse_links / mouse_urls ([#382](https://github.com/fentas/atty/issues/382)) ([7f3d947](https://github.com/fentas/atty/commit/7f3d9475ab96a1b1d878d3aceaa6c848195db680))
* split providers page into per-module pages + sidebar drawer ([#384](https://github.com/fentas/atty/issues/384)) ([5739855](https://github.com/fentas/atty/commit/573985547f8b6e230021a20eb5f89e8faab51f74))
* surface the full-suite install path + modules TOC ([#379](https://github.com/fentas/atty/issues/379)) ([bb5b2a6](https://github.com/fentas/atty/commit/bb5b2a6166a0118dc689f277e0266c4ad149e6fe))

## [0.6.0](https://github.com/fentas/atty/compare/v0.5.0...v0.6.0) (2026-06-01)


### Features

* **atty-guard,sandbox:** --ebpf-mode flag + 50-ebpf-loader scenario ([#337](https://github.com/fentas/atty/issues/337)) ([5009e3d](https://github.com/fentas/atty/commit/5009e3d45a7bfb2e51a5c2aadb3448fce7e3fafd))
* **atty-guard:** [#347](https://github.com/fentas/atty/issues/347) PR 1 — kernel-side warn-mode (no EPERM + warn_pids) ([#358](https://github.com/fentas/atty/issues/358)) ([69e46c7](https://github.com/fentas/atty/commit/69e46c7106fe4434782a0b5c673ad295de92af35))
* **atty-guard:** [#347](https://github.com/fentas/atty/issues/347) PR 2a — SubscribeWarnEvents RPC + broadcast infrastructure ([#359](https://github.com/fentas/atty/issues/359)) ([d32a565](https://github.com/fentas/atty/commit/d32a5658dd9015cf8a7e37dd4a5636fc96ab678b))
* **atty-guard:** [#347](https://github.com/fentas/atty/issues/347) PR 2b — ringbuf consumer thread + sandbox scenario 54 ([#360](https://github.com/fentas/atty/issues/360)) ([0acd596](https://github.com/fentas/atty/commit/0acd596b0fd61efcc28bcb87a7f036198384986c))
* **guard:** atom-fetcher caps + opt-in commit pinning ([#208](https://github.com/fentas/atty/issues/208)) ([98103d7](https://github.com/fentas/atty/commit/98103d771cd50be047cf972e9b7964749e559656))
* **llm:** Alt+R now opens a picker overlay listing all persisted dialogs ([#241](https://github.com/fentas/atty/issues/241)) ([47c5417](https://github.com/fentas/atty/commit/47c5417d9de586279ba0f578c1c64da421f9a9cf))
* **llm:** Alt+R recalls the most recent persisted dialog ([#240](https://github.com/fentas/atty/issues/240)) ([22ad943](https://github.com/fentas/atty/commit/22ad943f4cffb318f70617e73e12ba69143f50f7))
* **llm:** auto-defocus inline chat on dialog action=exec ([#170](https://github.com/fentas/atty/issues/170)) ([0df3727](https://github.com/fentas/atty/commit/0df3727bb5dc2f0db91ea70fa9a0220e66f626dc))
* **llm:** basic markdown → ANSI SGR renderer for chat panel ([#179](https://github.com/fentas/atty/issues/179)) ([e3b7cf7](https://github.com/fentas/atty/commit/e3b7cf70f14d0ba82bd314b9b16558d60cb19cdf))
* **llm:** bind Shift+Up/Shift+Down to chat_scroll_up/down ([#237](https://github.com/fentas/atty/issues/237)) ([165e6bf](https://github.com/fentas/atty/commit/165e6bfcabddd96e307ab12ae7ca63302fb5bb51))
* **llm:** chat panel footer + End-snaps-to-tail ([#182](https://github.com/fentas/atty/issues/182)) ([1acfded](https://github.com/fentas/atty/commit/1acfded335bd0bf94dddf61e936d34eb0162b1ef))
* **llm:** chat panel model indicator + Alt+M gate ([#174](https://github.com/fentas/atty/issues/174)) ([133e20e](https://github.com/fentas/atty/commit/133e20e7f6698898719ef61923af3de935bc4322))
* **llm:** chat panel UX — emoji width, word wrap, multi-line input, resize ([#175](https://github.com/fentas/atty/issues/175)) ([a7c4aa9](https://github.com/fentas/atty/commit/a7c4aa99fa3f9f670f9adefc3840f33e45e330d9))
* **llm:** chat surface defaults to dialog + Alt+T auto toggle + chrome polish ([#180](https://github.com/fentas/atty/issues/180)) ([c65381d](https://github.com/fentas/atty/commit/c65381d9908bced593a6a2f182ddd9c0fec2daa7))
* **llm:** Claude-code-style question UX in chat overlay ([#214](https://github.com/fentas/atty/issues/214)) ([7f0b25d](https://github.com/fentas/atty/commit/7f0b25d54da9495d75ed81d16ab2a447949f5016))
* **llm:** Claude-code-style question UX in chat overlay ([#224](https://github.com/fentas/atty/issues/224)) ([7f0b25d](https://github.com/fentas/atty/commit/7f0b25d54da9495d75ed81d16ab2a447949f5016))
* **llm:** collapse observation turns to a line-count stub in the inline panel ([#344](https://github.com/fentas/atty/issues/344)) ([d2bb481](https://github.com/fentas/atty/commit/d2bb481c3fb0357baf211368c2a1d38dad752fd0))
* **llm:** fenced-action protocol + lenient parser ([#177](https://github.com/fentas/atty/issues/177)) ([9502c19](https://github.com/fentas/atty/commit/9502c191de6068d843d0961b9c524c3fee74585c))
* **llm:** per-dialog NDJSON persistence — auto-save every turn ([#238](https://github.com/fentas/atty/issues/238)) ([9e9b4ff](https://github.com/fentas/atty/commit/9e9b4ffe38f7b42dd44112644012613645c7ac17))
* **llm:** per-mode + multi-provider via providers array ([#169](https://github.com/fentas/atty/issues/169)) ([afd887b](https://github.com/fentas/atty/commit/afd887bf086415f1d9f6a4a3602623e157dd308f))
* **llm:** per-row chat scroll windowing (closes [#213](https://github.com/fentas/atty/issues/213)) ([#242](https://github.com/fentas/atty/issues/242)) ([c25d44b](https://github.com/fentas/atty/commit/c25d44b1ebfd469d2bd7d34fa0c0c5a9cd9b5715))
* **llm:** render question pick-list in inline chat panel ([#308](https://github.com/fentas/atty/issues/308)) ([#324](https://github.com/fentas/atty/issues/324)) ([2b39922](https://github.com/fentas/atty/commit/2b3992236ac955dc422e4fcafeeba5b3d09c5cdb))
* **llm:** render SGR colors in full-size chat observation turns ([#311](https://github.com/fentas/atty/issues/311) Part B) ([3f67b5e](https://github.com/fentas/atty/commit/3f67b5e8aa95db336ad75d0dff273ce0cdfddfb1))
* **llm:** render SGR colors in full-size chat observation turns (partial [#311](https://github.com/fentas/atty/issues/311)) ([#325](https://github.com/fentas/atty/issues/325)) ([3f67b5e](https://github.com/fentas/atty/commit/3f67b5e8aa95db336ad75d0dff273ce0cdfddfb1))
* **llm:** show first user line in Alt+R recall picker ([#328](https://github.com/fentas/atty/issues/328)) ([1493064](https://github.com/fentas/atty/commit/1493064aacc756a85d7518ebb2d5875ffb7ae505))
* **llm:** subprocess provider — claude -p and friends ([#158](https://github.com/fentas/atty/issues/158)) ([74c2a05](https://github.com/fentas/atty/commit/74c2a05b2ca3879494af1e45460c40bbfe0bc5f9))
* **llm:** subprocess session continuation ([#166](https://github.com/fentas/atty/issues/166)) ([4d11401](https://github.com/fentas/atty/commit/4d11401d46324a3e99a06b963998d6f84bcc4195))
* **llm:** subprocess streaming output (stream-json) ([#165](https://github.com/fentas/atty/issues/165)) ([f6af0a8](https://github.com/fentas/atty/commit/f6af0a842dbe5de3a750510d63b21d1ff9334cf8))
* **llm:** subprocess wall-clock timeout enforcement ([#164](https://github.com/fentas/atty/issues/164)) ([3a12df9](https://github.com/fentas/atty/commit/3a12df9d3166963171c78346780dd0aca69d8cbf))
* **mouse:** [#304](https://github.com/fentas/atty/issues/304) PR 4a — SGR 1006 mouse-event parser ([#362](https://github.com/fentas/atty/issues/362)) ([067eb04](https://github.com/fentas/atty/commit/067eb04cb677cee1817946aeaceb9633e3d34027))
* **mouse:** [#304](https://github.com/fentas/atty/issues/304) PR 4b — onMouseClick dispatch hook + MouseAction ([#363](https://github.com/fentas/atty/issues/363)) ([8dd7b03](https://github.com/fentas/atty/commit/8dd7b03a12a51d54c4c02e2d21efb99355d88761))
* **mouse:** [#304](https://github.com/fentas/atty/issues/304) PR 4c — proxy stdin intercept + Mouse config subsystem ([#364](https://github.com/fentas/atty/issues/364)) ([def559c](https://github.com/fentas/atty/commit/def559c76f9d17b0ec900179292fc94d21bd84fc))
* **mouse:** [#304](https://github.com/fentas/atty/issues/304) PR 4d — emit DECSET SGR-1006 on startup, pop on exit ([#365](https://github.com/fentas/atty/issues/365)) ([df56882](https://github.com/fentas/atty/commit/df56882d68ffcdbb0c88648b90c1d32b456bce76))
* **mouse:** [#304](https://github.com/fentas/atty/issues/304) PR 4e — path-detector helper (pure, tested) ([#366](https://github.com/fentas/atty/issues/366)) ([54ed5bf](https://github.com/fentas/atty/commit/54ed5bfe3b94f8990c0250a620106aeb11c676b2))
* **mouse:** [#304](https://github.com/fentas/atty/issues/304) PR 4f — mouse_links module wiring ([#367](https://github.com/fentas/atty/issues/367)) ([9fef863](https://github.com/fentas/atty/commit/9fef8632dbb448d2622334e07c5dca3b50c3a7d5))
* **mouse:** [#304](https://github.com/fentas/atty/issues/304) PR 4g — mouse_urls module with whitelist trust gate ([#368](https://github.com/fentas/atty/issues/368)) ([86e0f12](https://github.com/fentas/atty/commit/86e0f12c2ecda3ff82bf8d9b6e24b67e7de9e4a2))
* **mouse:** [#304](https://github.com/fentas/atty/issues/304) PR 4h — ask_each banner + session-trust (final) ([#369](https://github.com/fentas/atty/issues/369)) ([f5c72eb](https://github.com/fentas/atty/commit/f5c72eb1874b15c8d870333d78e4880a0dc77e92))
* **sandbox:** 4 core scenarios — install, cross-UID, sudo atoms, auto-Block ([#335](https://github.com/fentas/atty/issues/335)) ([c41f678](https://github.com/fentas/atty/commit/c41f6784caf1457ed3f0fd2bca1850c01b96209c))
* **sandbox:** 62-onnx-fallback — fail-closed posture for explicit Tier-2 ONNX ([#342](https://github.com/fentas/atty/issues/342)) ([1ba9c21](https://github.com/fentas/atty/commit/1ba9c21b9ed0b0054553f74b94ebbc8682715bc7))
* **sandbox:** docker-based e2e scenario harness with smoke test ([#334](https://github.com/fentas/atty/issues/334)) ([9fb3742](https://github.com/fentas/atty/commit/9fb374244a3af5a5adcc32a6b181575613234def))
* **sandbox:** eBPF scenarios 51 + 52 + kernel-side image build ([#348](https://github.com/fentas/atty/issues/348)) ([fbbc407](https://github.com/fentas/atty/commit/fbbc407301e331a5da359ec1cf634f00c8efdd6e))
* **sandbox:** ONNX scenarios 60 + 61 + per-scenario image override ([#346](https://github.com/fentas/atty/issues/346)) ([81a8d05](https://github.com/fentas/atty/commit/81a8d058bf42b957e3c79cf27ac84e7593489afc))
* **sandbox:** real-incident replay scenarios 70 / 71 / 72 ([#355](https://github.com/fentas/atty/issues/355)) ([45eff39](https://github.com/fentas/atty/commit/45eff391b303a72941259b608d84e1753a2b669f))
* **sandbox:** scenario docker-config typo guard + securityfs probe split ([#343](https://github.com/fentas/atty/issues/343)) ([9fb81dd](https://github.com/fentas/atty/commit/9fb81ddf9a008fb0a8ff8b912ad1fbf008d2f98b))
* **security_guard:** [#209](https://github.com/fentas/atty/issues/209) — atom-fetcher drift detection + pin-init bootstrap ([#243](https://github.com/fentas/atty/issues/243)) ([79983a8](https://github.com/fentas/atty/commit/79983a81e8ebc1dc8fecb1b48e7051506cada53b))
* **security_guard:** [#347](https://github.com/fentas/atty/issues/347) PR 3 — Alt+Shift+W warn-event dump ([#370](https://github.com/fentas/atty/issues/370)) ([a7ecc3b](https://github.com/fentas/atty/commit/a7ecc3b046dfd5b4f3a26b990ef6fc8a85e5bd6b))
* **security_guard:** [#347](https://github.com/fentas/atty/issues/347) PR 3 — atty-side warn subscriber + status segment ([#361](https://github.com/fentas/atty/issues/361)) ([e37b1d0](https://github.com/fentas/atty/commit/e37b1d0aa961d8c7e03693a2b5f10174dcee4172))


* **operator-ux:** doctor sidecar checks + workflow doc + named-threat scenarios ([#139](https://github.com/fentas/atty/issues/139)) ([b67b9fd](https://github.com/fentas/atty/commit/b67b9fddac262f4ba460d4c3b9e77b882fec4110))
* **security_guard:** atty-guard --print-features probe ([#149](https://github.com/fentas/atty/issues/149)) ([9b4f6fe](https://github.com/fentas/atty/commit/9b4f6feba8f4c62f715fb064c286a04bebe08390))
* **security_guard:** atty-guard as system daemon under atty user ([#140](https://github.com/fentas/atty/issues/140)) ([02405c9](https://github.com/fentas/atty/commit/02405c93427f7e2424ae5929fe76b52577678715))
* **security_guard:** first-class eBPF install path ([#151](https://github.com/fentas/atty/issues/151)) ([6f54726](https://github.com/fentas/atty/commit/6f54726180f6d5b6b572b042f830a9090bd74173))
* **security_guard:** inline [a]/[B] prompt + session trust/block ([#142](https://github.com/fentas/atty/issues/142)) ([d8fa4ca](https://github.com/fentas/atty/commit/d8fa4ca5d90a6a0eaec677ef7a509e2018fb2b9a))
* **security_guard:** mediated CLI + per-user trust store ([#141](https://github.com/fentas/atty/issues/141)) ([4b0f69e](https://github.com/fentas/atty/commit/4b0f69ef2e96f5ae04f3b1ca6fe4fe3a6d71400a))
* **security_guard:** migrate trust cache to daemon-side ([#147](https://github.com/fentas/atty/issues/147)) ([e41080b](https://github.com/fentas/atty/commit/e41080b74d99ae0c92a33fbce3cec2e8b356cb66))
* **security_guard:** system-fetched atom corpus with permission gate ([#150](https://github.com/fentas/atty/issues/150)) ([300f36a](https://github.com/fentas/atty/commit/300f36af0f09437b391b1294cc00b14148b70af2))

### Bug Fixes

* Fix:  ([f87cbb1](https://github.com/fentas/atty/commit/f87cbb13ecd8d5fa75b83db68f83816f785d5658))
* **atty-guard:** audit batch 2 — Rust bugs (trust_store, threat-map, log redaction, atom OOM) ([#307](https://github.com/fentas/atty/issues/307)) ([a20c23b](https://github.com/fentas/atty/commit/a20c23b6372bc4546314ee9fff098a6e02482595))
* **atty-guard:** bound write_locks + sweep stale tmp files (closes [#251](https://github.com/fentas/atty/issues/251), [#252](https://github.com/fentas/atty/issues/252)) ([#321](https://github.com/fentas/atty/issues/321)) ([8b4e79f](https://github.com/fentas/atty/commit/8b4e79f9365feee21e6d4272841019f10b89dace))
* **atty-guard:** graceful SIGTERM/SIGINT/SIGHUP handling ([#276](https://github.com/fentas/atty/issues/276)) ([#314](https://github.com/fentas/atty/issues/314)) ([7b4fc7f](https://github.com/fentas/atty/commit/7b4fc7f1b9fb09efff30b3222df8f26ac9e6c0c4))
* **atty-guard:** harden sudo_target_uid against env injection ([#271](https://github.com/fentas/atty/issues/271)) ([#301](https://github.com/fentas/atty/issues/301)) ([cd2a90b](https://github.com/fentas/atty/commit/cd2a90bd4a54414d60beb06bb9821ae0ed3efeef))
* **atuin:** bounded record FIFO, threshold-only sync timing, joined final sync ([#027](https://github.com/fentas/atty/issues/027) [#028](https://github.com/fentas/atty/issues/028) [#030](https://github.com/fentas/atty/issues/030)) ([#261](https://github.com/fentas/atty/issues/261)) ([13e9093](https://github.com/fentas/atty/commit/13e90933388a556fec4b4bd203b00a6fcd240de9))
* audit batch 1 — Zig bugs ([#286](https://github.com/fentas/atty/issues/286), [#287](https://github.com/fentas/atty/issues/287), [#288](https://github.com/fentas/atty/issues/288)) ([32af600](https://github.com/fentas/atty/commit/32af60011d222a279c9f71e9b9172e917b0294de))
* audit batch 1 — Zig bugs (worker, proxy, history) ([#306](https://github.com/fentas/atty/issues/306)) ([32af600](https://github.com/fentas/atty/commit/32af60011d222a279c9f71e9b9172e917b0294de))
* audit batch 3 — security MEDs (live-tracking warn, LLM endpoint ANSI sanitize) ([#309](https://github.com/fentas/atty/issues/309)) ([30ca068](https://github.com/fentas/atty/commit/30ca068d9aecd65409a790de2ac5d9d384bc7c0c))
* **guard:** --config load failures now exit non-zero ([#231](https://github.com/fentas/atty/issues/231)) ([30541fd](https://github.com/fentas/atty/commit/30541fd9be9952e7d527c44d4e79f04b8e63527e))
* **guard:** --config load failures now exit non-zero (was fall-open) ([30541fd](https://github.com/fentas/atty/commit/30541fd9be9952e7d527c44d4e79f04b8e63527e))
* **guard:** authorize set_threat_level — non-root callers limited to own PIDs ([#188](https://github.com/fentas/atty/issues/188)) ([d1619f9](https://github.com/fentas/atty/commit/d1619f9196fa29d55c35c8f70f53956894efdd85)), closes [#187](https://github.com/fentas/atty/issues/187)
* **guard:** bounded thread pool + idle read timeout ([#193](https://github.com/fentas/atty/issues/193)) ([1c84f34](https://github.com/fentas/atty/commit/1c84f34f63d7bdd5cd9eacebf9885c107ed8b93f))
* **guard:** canonicalize socket path for lock so symlink aliases collide ([#218](https://github.com/fentas/atty/issues/218)) ([a91ae2c](https://github.com/fentas/atty/commit/a91ae2c619895643009b5de5d61751aeeeac1ace))
* **guard:** cap + prune OSV lookup cache ([#233](https://github.com/fentas/atty/issues/233)) ([a4996aa](https://github.com/fentas/atty/commit/a4996aaa66e64ad6c3c38bfe91bafb19930e63e3))
* **guard:** drop ProtectProc=invisible — incompatible with set_threat_level auth ([#206](https://github.com/fentas/atty/issues/206)) ([2fdba32](https://github.com/fentas/atty/commit/2fdba32547beab8ba6d62fee2e20889250ae7dbf))
* **guard:** honor [tier2] backend in config (cli &gt; config &gt; default) ([#232](https://github.com/fentas/atty/issues/232)) ([f87cbb1](https://github.com/fentas/atty/commit/f87cbb13ecd8d5fa75b83db68f83816f785d5658))
* **guard:** network.conf drop-in for osv-live + atoms-fetch ([#195](https://github.com/fentas/atty/issues/195)) ([fc369c3](https://github.com/fentas/atty/commit/fc369c3bc32f9e3c189aabb0a57f1d313157019d)), closes [#187](https://github.com/fentas/atty/issues/187)
* **guard:** post-merge review-fixups for PRs [#231](https://github.com/fentas/atty/issues/231) / [#232](https://github.com/fentas/atty/issues/232) ([#234](https://github.com/fentas/atty/issues/234)) ([af6ce63](https://github.com/fentas/atty/commit/af6ce63bf33b474f1fc9d21f4e1f12ac9bf82fd5))
* **guardrail:** re-check rules on mixed-chunk Enter ([#269](https://github.com/fentas/atty/issues/269)) ([#299](https://github.com/fentas/atty/issues/299)) ([2361eb1](https://github.com/fentas/atty/commit/2361eb193ff71ff0b92d55c36fd7eea1d5228209))
* **guard:** single-instance flock guard on socket startup ([#192](https://github.com/fentas/atty/issues/192)) ([5543bcc](https://github.com/fentas/atty/commit/5543bcc1f61a2bb5fbff224df58df4c249b83dc9))
* **line_state:** preserve cursor across mid-line delete syncFromCapture ([#239](https://github.com/fentas/atty/issues/239)) ([9da0845](https://github.com/fentas/atty/commit/9da0845872f84ed873eb9c6cc3106ba943ed20b4))
* **llm:** Alt+Shift+C opens an empty overlay instead of refusing ([#236](https://github.com/fentas/atty/issues/236)) ([3c821f1](https://github.com/fentas/atty/commit/3c821f19d59601c371e7b564bff2b097b8b4a569))
* **llm:** cap concurrent orphan HTTP fetches to bound resource leak ([#219](https://github.com/fentas/atty/issues/219)) ([4cc2c9a](https://github.com/fentas/atty/commit/4cc2c9a4f39fc37f8041b44c3930f193c1be5571))
* **llm:** chat panel UX — divider repaint on cycle + drop 3-row truncation ([#176](https://github.com/fentas/atty/issues/176)) ([6e1bd79](https://github.com/fentas/atty/commit/6e1bd79fb4910dcf367adb8ae82de43578b697b2))
* **llm:** chat shortcuts back into statusbar + bump response/turn byte caps ([#184](https://github.com/fentas/atty/issues/184)) ([6efe797](https://github.com/fentas/atty/commit/6efe797473b928fa30b01d0a14915699eddbfd1a))
* **llm:** clear cached chat cursor on exec completion ([#303](https://github.com/fentas/atty/issues/303)) ([#323](https://github.com/fentas/atty/issues/323)) ([c61264f](https://github.com/fentas/atty/commit/c61264fb559b00c2b8e1167bdd851fc63e406d6d))
* **llm:** conclusion banner wraps multi-line reason instead of right-drifting ([#178](https://github.com/fentas/atty/issues/178)) ([9ee294d](https://github.com/fentas/atty/commit/9ee294d9960e180beeedd43bc0da602593457cc6))
* **llm:** done-action reason truncated at parse + chat-mode render ([#212](https://github.com/fentas/atty/issues/212)) ([f9f2b00](https://github.com/fentas/atty/commit/f9f2b0076f4d85536419fdce0bd9a32c2e2bf788))
* **llm:** enforce HTTP timeout_ms via sub-thread + watchdog ([#190](https://github.com/fentas/atty/issues/190)) ([24286ea](https://github.com/fentas/atty/commit/24286eaf1fc8793056a45470fa6eece550b0a7f6)), closes [#187](https://github.com/fentas/atty/issues/187)
* **llm:** heap-allocate chat_overlay_buf for unbounded turn content ([#221](https://github.com/fentas/atty/issues/221)) ([cdb3128](https://github.com/fentas/atty/commit/cdb3128962d037b945b3a5bd7e2b61d8926b2e0b))
* **llm:** heap-allocate chat_overlay_buf so long-reason turns don't overflow ([cdb3128](https://github.com/fentas/atty/commit/cdb3128962d037b945b3a5bd7e2b61d8926b2e0b))
* **llm:** inline .done reason — reserve 2 cols for ✓ prefix in wrap budget ([#217](https://github.com/fentas/atty/issues/217)) ([6766465](https://github.com/fentas/atty/commit/6766465fa5a2cc062fd81cc4610c0214bc7b78ce))
* **llm:** inline `.done` reason — reserve 2 cols for ✓ prefix in wrap budget ([6766465](https://github.com/fentas/atty/commit/6766465fa5a2cc062fd81cc4610c0214bc7b78ce))
* **llm:** kill subprocess process group on timeout ([#194](https://github.com/fentas/atty/issues/194)) ([ea3d537](https://github.com/fentas/atty/commit/ea3d5379f2832a7af0b3b0613e0532653cc49582))
* **llm:** recall picker arrow keys + auto-close inline panel on Alt+R ([#318](https://github.com/fentas/atty/issues/318)) ([#322](https://github.com/fentas/atty/issues/322)) ([c1494be](https://github.com/fentas/atty/commit/c1494be4049409e4a95da5a5a51b13e21dc62f13))
* **llm:** seek to end of large persist file ([#191](https://github.com/fentas/atty/issues/191)) ([f6755ba](https://github.com/fentas/atty/commit/f6755ba27ff863b508d03fb2158f53034e45f4b0))
* **proxy:** drop shell-fired CPR replies that leak through DsrParser gate ([#235](https://github.com/fentas/atty/issues/235)) ([bc83b69](https://github.com/fentas/atty/commit/bc83b6908789fe6b1ddacfc4482245602b12f8d7))
* **proxy:** shell-alt-screen TUIs (k9s, vim, less) see Esc on first press ([#181](https://github.com/fentas/atty/issues/181)) ([a214dbc](https://github.com/fentas/atty/commit/a214dbca1eb5ad97b87dcd5af094727fd01e93c9))
* **proxy:** shell-alt-screen TUIs see Esc on the first press ([a214dbc](https://github.com/fentas/atty/commit/a214dbca1eb5ad97b87dcd5af094727fd01e93c9))
* **security_guard:** [#022](https://github.com/fentas/atty/issues/022) + [#023](https://github.com/fentas/atty/issues/023) — atoms list --fetched + drop stale libonnxruntime refs ([#250](https://github.com/fentas/atty/issues/250)) ([3f6ef37](https://github.com/fentas/atty/commit/3f6ef37f4d937f9c183b486a88dca0b7186bb24f))
* **security_guard:** [#024](https://github.com/fentas/atty/issues/024) + [#025](https://github.com/fentas/atty/issues/025) — serialize trust-store writes, retain cap-blocked hashes ([#248](https://github.com/fentas/atty/issues/248)) ([d013073](https://github.com/fentas/atty/commit/d013073c39443207e76623eda8f093535c3a7544))
* **security_guard:** clear daemon threat mark when local state clears ([#230](https://github.com/fentas/atty/issues/230)) ([52810e4](https://github.com/fentas/atty/commit/52810e472568730dd55a79eeedc43eaa95869367))
* **security_guard:** close UDS fd on classify timeout ([#272](https://github.com/fentas/atty/issues/272)) ([#302](https://github.com/fentas/atty/issues/302)) ([47ca882](https://github.com/fentas/atty/commit/47ca882be0c05169b3898c791f30bca0d82bf603))
* **security_guard:** decouple config parsing from tier2-onnx feature ([#032](https://github.com/fentas/atty/issues/032)) ([#266](https://github.com/fentas/atty/issues/266)) ([ad10374](https://github.com/fentas/atty/commit/ad10374f35a05cf808ac404578a7e8281656680f))
* **security_guard:** fail-closed on explicit ONNX backend load failure ([#026](https://github.com/fentas/atty/issues/026)) ([#260](https://github.com/fentas/atty/issues/260)) ([a91b390](https://github.com/fentas/atty/commit/a91b3909901d036ac72b277c2b51a3c442bfa357))
* **security_guard:** forward context to atty-guard daemon classify ([#189](https://github.com/fentas/atty/issues/189)) ([fd837c7](https://github.com/fentas/atty/commit/fd837c736e18e09dc05813f84d49c00871f62733))
* **security_guard:** OSV checks all installed packages, not just the first ([#029](https://github.com/fentas/atty/issues/029)) ([#262](https://github.com/fentas/atty/issues/262)) ([c2a0bc9](https://github.com/fentas/atty/commit/c2a0bc9d7a8bfe571389944fb5ed429352ac9864))
* **security_guard:** parse daemon ok/error envelopes for mutation RPCs ([#207](https://github.com/fentas/atty/issues/207)) ([4bede99](https://github.com/fentas/atty/commit/4bede9996d1c98ccb0fe13c2fa846c446bb7ac4b))
* **security_guard:** PID-threat verdict worst-wins escalation ([#268](https://github.com/fentas/atty/issues/268)) ([#273](https://github.com/fentas/atty/issues/273)) ([fb6c269](https://github.com/fentas/atty/commit/fb6c269daa6371bad81aa1a0ade9ffe432282e2f))
* **security_guard:** reject non-hex hashes in TrustCache add ([#270](https://github.com/fentas/atty/issues/270)) ([#300](https://github.com/fentas/atty/issues/300)) ([b2ac5b2](https://github.com/fentas/atty/commit/b2ac5b232b3a680b457c4f2006531d2fa84e55d3))
* **statusbar:** re-assert DECSTBM when inline TUIs clobber it ([#249](https://github.com/fentas/atty/issues/249)) ([#253](https://github.com/fentas/atty/issues/253)) ([ffc7100](https://github.com/fentas/atty/commit/ffc71004b257364c09d1aa28039833096628573b))
* TOCTOU defense in slaveIsHiddenInput + clear desyncs chat state ([#283](https://github.com/fentas/atty/issues/283), [#305](https://github.com/fentas/atty/issues/305)) ([#313](https://github.com/fentas/atty/issues/313)) ([5749511](https://github.com/fentas/atty/commit/574951132e770da2bb27886b1d5b53e9c29e0084))


### Performance

* **line_state:** bulk-append printable runs in applyInput ([#289](https://github.com/fentas/atty/issues/289)) ([#319](https://github.com/fentas/atty/issues/319)) ([4c3d758](https://github.com/fentas/atty/commit/4c3d7585e3f2a7b31b148acb2edfb032f714ab47))
* **llm/paint:** swap page_allocator for stack-backed FBA ([#285](https://github.com/fentas/atty/issues/285)) ([#316](https://github.com/fentas/atty/issues/316)) ([f47682a](https://github.com/fentas/atty/commit/f47682af6f74368e76d29ae9a8804edaff3efd22))
* **llm:** chat input fast-path — skip scrollback rewalk on typing ([#186](https://github.com/fentas/atty/issues/186)) ([b8d687a](https://github.com/fentas/atty/commit/b8d687a96fc1f298251a4a14fb34c6cdda04d0ba))
* **llm:** unify stream-json result + session_id walkers ([#172](https://github.com/fentas/atty/issues/172)) ([ee2d377](https://github.com/fentas/atty/commit/ee2d37762ed624803edd1d231a19db381576fa5a))


### Refactor

* **atty-guard:** extract dispatch arms into per-request handlers ([#280](https://github.com/fentas/atty/issues/280)) ([9ae6134](https://github.com/fentas/atty/commit/9ae61347271f7d66d60bdfbe4c4bdd54d15b5229))
* **atty-guard:** extract dispatch arms into per-request handlers (closes [#280](https://github.com/fentas/atty/issues/280)) ([#326](https://github.com/fentas/atty/issues/326)) ([9ae6134](https://github.com/fentas/atty/commit/9ae61347271f7d66d60bdfbe4c4bdd54d15b5229))
* **atty-guard:** split atom_fetcher into per-domain submodules (closes [#281](https://github.com/fentas/atty/issues/281)) ([#327](https://github.com/fentas/atty/issues/327)) ([114463a](https://github.com/fentas/atty/commit/114463a1fe5a93fac38215504493001101562004))
* **atty-guard:** split atom_fetcher.rs into per-domain modules ([#281](https://github.com/fentas/atty/issues/281)) ([114463a](https://github.com/fentas/atty/commit/114463a1fe5a93fac38215504493001101562004))
* **llm:** dynamic per-response buffers (lifts inline fixed-size reservation) ([#185](https://github.com/fentas/atty/issues/185)) ([e069eaa](https://github.com/fentas/atty/commit/e069eaa3f4124adfe9bb55a9c6601e05afbf73ba))
* **main:** extract inline shell snippets to src/snippets/ ([3f0356e](https://github.com/fentas/atty/commit/3f0356e27844b8c693f0edfdcbe02b8bc2fceec4))
* **main:** extract inline shell snippets to src/snippets/ files ([#315](https://github.com/fentas/atty/issues/315)) ([3f0356e](https://github.com/fentas/atty/commit/3f0356e27844b8c693f0edfdcbe02b8bc2fceec4))


### Documentation

* **atuin:** refresh provider/architecture/modules docs for FIFO + sync + delete ([#033](https://github.com/fentas/atty/issues/033)) ([#267](https://github.com/fentas/atty/issues/267)) ([7b6651c](https://github.com/fentas/atty/commit/7b6651c2c169e88bdc4b30562523b24e52d6cae6))
* audit batch — V-table refresh + paint skip semantics (closes [#298](https://github.com/fentas/atty/issues/298)) ([#320](https://github.com/fentas/atty/issues/320)) ([9506e1c](https://github.com/fentas/atty/commit/9506e1c98c4bb5c883e89ba17d725d0b898d9100))
* audit batch 5 — fix doc drift across atty + atty-guard ([#298](https://github.com/fentas/atty/issues/298)) ([e175050](https://github.com/fentas/atty/commit/e1750506389803570cbf1acbefdcb82e7545ee35))
* audit batch 5 — partial doc drift fixes ([#298](https://github.com/fentas/atty/issues/298)) ([#312](https://github.com/fentas/atty/issues/312)) ([e175050](https://github.com/fentas/atty/commit/e1750506389803570cbf1acbefdcb82e7545ee35))
* **getting-started:** git-clone install path, promote shell-rc, safer demo ([#352](https://github.com/fentas/atty/issues/352)) ([b23db11](https://github.com/fentas/atty/commit/b23db1136916e23c665d25bfa5bfdc9b6d205625))
* **guard-design:** sweep stale 'next step' + LOLBAS + atom-path claims ([#198](https://github.com/fentas/atty/issues/198)) ([6450623](https://github.com/fentas/atty/commit/6450623b1cf4ed0b6df8b6db812cf0ae1399b084))
* **guard:** correct status drift — V2-B / V2-C / V2-F / V2-I all shipped ([5269ccb](https://github.com/fentas/atty/commit/5269ccb221bc173acfba5cfb3a64690d8d1de231))
* **guard:** correct status drift — V2-B/C/F/I all shipped ([#220](https://github.com/fentas/atty/issues/220)) ([5269ccb](https://github.com/fentas/atty/commit/5269ccb221bc173acfba5cfb3a64690d8d1de231))
* **guard:** rewrite README security model section ([#196](https://github.com/fentas/atty/issues/196)) ([60e0f3d](https://github.com/fentas/atty/commit/60e0f3dd91fd7f5900d90136428febce0c93f834))
* **install:** threat-model paragraph for the atty group ([#298](https://github.com/fentas/atty/issues/298)) ([5dc6a9a](https://github.com/fentas/atty/commit/5dc6a9a1ab191af16935a1556f30259a8d94ba1f))
* **install:** threat-model paragraph for the atty group (partial [#298](https://github.com/fentas/atty/issues/298)) ([#317](https://github.com/fentas/atty/issues/317)) ([5dc6a9a](https://github.com/fentas/atty/commit/5dc6a9a1ab191af16935a1556f30259a8d94ba1f))
* **llm:** catch up on fenced-action protocol + new chat bindings ([#183](https://github.com/fentas/atty/issues/183)) ([9a706ab](https://github.com/fentas/atty/commit/9a706ab72e2bc5aa7be92056929b7372a3907192))
* **llm:** renderOverlayTurnContent arena comment matches impl ([#222](https://github.com/fentas/atty/issues/222)) ([b5594a6](https://github.com/fentas/atty/commit/b5594a6ecda4fc2215b3c14b425bb65e8680cf73))
* **modules:** correct atty-guard socket path + user-unit reference ([#197](https://github.com/fentas/atty/issues/197)) ([413131b](https://github.com/fentas/atty/commit/413131b021d2cf09cbb9c85c1debde27cb76bdc5)), closes [#187](https://github.com/fentas/atty/issues/187)
* **providers:** correct vi-mode hjkl mechanism — model desync, not uncertain flag ([4aa37d6](https://github.com/fentas/atty/commit/4aa37d67e637ee441727da02efc6257a63212250))
* **providers:** correct vi-mode hjkl mechanism ([#223](https://github.com/fentas/atty/issues/223)) ([4aa37d6](https://github.com/fentas/atty/commit/4aa37d67e637ee441727da02efc6257a63212250))
* **providers:** tab completion with OSC 133 ([#171](https://github.com/fentas/atty/issues/171)) ([67fa354](https://github.com/fentas/atty/commit/67fa354f46f5bdb00f7991c6118678b99aa9ad2c))
* **proxy:** state-machine diagram for run() phase order (partial [#298](https://github.com/fentas/atty/issues/298)) ([d597fb6](https://github.com/fentas/atty/commit/d597fb6eba349c3b1a12111d4a6451ae2a8fc28b))
* refresh stale Atuin defaults + atom-refresh help + OSC 133 roadmap ([#031](https://github.com/fentas/atty/issues/031)) ([#263](https://github.com/fentas/atty/issues/263)) ([cfb8f2b](https://github.com/fentas/atty/commit/cfb8f2ba9b42c2b286d9d52f2f6fbfb568051f35))
* refresh stale claims across READMEs + sandbox + integration ([#357](https://github.com/fentas/atty/issues/357)) ([09f63af](https://github.com/fentas/atty/commit/09f63af3296ef377c26fd996a882d954cb1c467b))
* **security_guard:** document UDS hot-path blocking contract ([#282](https://github.com/fentas/atty/issues/282)) ([#310](https://github.com/fentas/atty/issues/310)) ([378de4b](https://github.com/fentas/atty/commit/378de4b263d0beee542fc04c96126b1aa623573b))
* shared terminal_example component + LLM page demo ([#354](https://github.com/fentas/atty/issues/354)) ([6d1718d](https://github.com/fentas/atty/commit/6d1718d4d2dccde069c98f72d9d5728e9a43df48))
* sweep — mouse stack ([#304](https://github.com/fentas/atty/issues/304)) + warn-mode overlay ([#347](https://github.com/fentas/atty/issues/347)) ([#371](https://github.com/fentas/atty/issues/371)) ([a9acc91](https://github.com/fentas/atty/commit/a9acc9167127364a878ff1e7e185796aa9b99ee9))
* post-architecture-rewrite cleanup for CLAUDE and atty-guard README ([#152](https://github.com/fentas/atty/issues/152)) ([6ab578b](https://github.com/fentas/atty/commit/6ab578bf538081fe77ec4defaafab5d1c9a44f1a))
* **site:** adopt starship-style layout ([#154](https://github.com/fentas/atty/issues/154)) ([ce43146](https://github.com/fentas/atty/commit/ce431460ee36b587532fc62bd36cf3ed11905980))
* **site:** user-facing refactor + interactive playback demo ([#153](https://github.com/fentas/atty/issues/153)) ([cd8b128](https://github.com/fentas/atty/commit/cd8b12857d74efe0fe7f4774bd296ee3eb22253d))

## [0.5.0](https://github.com/fentas/atty/compare/v0.4.0...v0.5.0) (2026-05-19)


### Features

* **atty-guard:** configurable ONNX SLM via tract (SecureBERT 2 + Qwen2 5-Coder) ([#116](https://github.com/fentas/atty/issues/116)) ([090bc5e](https://github.com/fentas/atty/commit/090bc5e8a706877686ebeb0410c01392de139179))
* **atty-guard:** eBPF AF_ALG socket() tracepoint — copy.fail-class kernel-LPE detector ([654a520](https://github.com/fentas/atty/commit/654a520329424f3bd75dfde5781830bb582c9111))
* **atty-guard:** eBPF AF_ALG tracepoint — copy-fail-class kernel-LPE detector ([#117](https://github.com/fentas/atty/issues/117)) ([654a520](https://github.com/fentas/atty/commit/654a520329424f3bd75dfde5781830bb582c9111))
* **atty-guard:** Tier-2 backend trait + Heuristic impl (V2-C plumbing) ([#109](https://github.com/fentas/atty/issues/109)) ([81c03f7](https://github.com/fentas/atty/commit/81c03f74cefa69e59c6c8dfb84283234812ebc33))
* **atty-guard:** V2-A sidecar daemon — UDS + Tier-1 classifier + threat map ([#105](https://github.com/fentas/atty/issues/105)) ([cfba772](https://github.com/fentas/atty/commit/cfba7724aa130a17179b3235b8f19c18c4da5cab))
* **atty-guard:** V2-B eBPF skeleton — kernel sources + Rust loader API ([#110](https://github.com/fentas/atty/issues/110)) ([dcb48fa](https://github.com/fentas/atty/commit/dcb48fa9443d64a7fde6c6a7d229ffa0f0387fc0))
* **atty-guard:** V2-B impl — libbpf-rs LSM attach + BPF map write-through ([#113](https://github.com/fentas/atty/issues/113)) ([fdec184](https://github.com/fentas/atty/commit/fdec18412ef0da110fc41d3a355f22c4b2954809))
* **atty-guard:** V2-C — configurable ONNX SLM via tract (SecureBERT 2.0 + Qwen2.5-Coder) ([090bc5e](https://github.com/fentas/atty/commit/090bc5e8a706877686ebeb0410c01392de139179))
* **atty-guard:** V2-E packaging — hardened systemd-user unit + installer ([#108](https://github.com/fentas/atty/issues/108)) ([06cf4d8](https://github.com/fentas/atty/commit/06cf4d8525175c3ae44e0233742d6b7eda3bca6d))
* **atty-guard:** V2-F live OSV-dev lookup for npm Tier-1 misses ([#118](https://github.com/fentas/atty/issues/118)) ([c62d598](https://github.com/fentas/atty/commit/c62d59852963c76fb66016b9118a88f0f9ad57a4))
* **atty-guard:** V2-F live OSV.dev lookup for npm install &lt;pkg&gt; Tier-1 misses ([c62d598](https://github.com/fentas/atty/commit/c62d59852963c76fb66016b9118a88f0f9ad57a4))
* **atuin:** --intent flag wiring + LineState.committedIntent ([#47](https://github.com/fentas/atty/issues/47)) ([2d6e14a](https://github.com/fentas/atty/commit/2d6e14a45a972165caa48f9a82de5b9a9bf93621))
* **atuin:** tag LLM-authored commits via --author atty:llm ([#29](https://github.com/fentas/atty/issues/29)) ([5a4bf53](https://github.com/fentas/atty/commit/5a4bf53f1a2296d880455d7591e645537a839702))
* **build:** atty-guard in release bins + Makefile targets + cargo CI ([#132](https://github.com/fentas/atty/issues/132)) ([3daf257](https://github.com/fentas/atty/commit/3daf257ce07aef6e4d13f78a22ce99278955617a))
* **cursor_dsr:** DSR-6n reply interceptor + stdin filter ([#101](https://github.com/fentas/atty/issues/101)) ([0c53037](https://github.com/fentas/atty/commit/0c530374cccf4cf8be48553ce4fc26d4f4b75417))
* **cursor_tracker:** track column + OSC 133 anchors ([#100](https://github.com/fentas/atty/issues/100)) ([5e13cf8](https://github.com/fentas/atty/commit/5e13cf86cbfc9b45adc3651c4def9095938fbd27))
* **dispatch,llm:** modules register their own default_bindings ([#70](https://github.com/fentas/atty/issues/70)) ([245e7e8](https://github.com/fentas/atty/commit/245e7e85013de9b2af149b278b6515278f778fae))
* **guardrail:** author-aware Rule with AuthorMask + Behavior ([#27](https://github.com/fentas/atty/issues/27)) ([0257dbb](https://github.com/fentas/atty/commit/0257dbb6eb4f1c243959306bd9d2f7d95fe08697))
* **guardrail:** split rule types into rules.zig + add extra_rules merge ([#33](https://github.com/fentas/atty/issues/33)) ([be8db06](https://github.com/fentas/atty/commit/be8db0653926798599203a59e80cc6c6532980e3))
* **keymap,proxy:** Alt+H global keybindings cheat-sheet ([#67](https://github.com/fentas/atty/issues/67)) ([45bd3e1](https://github.com/fentas/atty/commit/45bd3e1cee707b6dbae5edb7019511a30f8fb757))
* **line-state:** author propagation ([#26](https://github.com/fentas/atty/issues/26)) ([e2dfacf](https://github.com/fentas/atty/commit/e2dfacf207587b1319034f12020d1f9b3b393908))
* **llm,keymap:** Ctrl+Up/Down jump focus between chat panel and shell ([#77](https://github.com/fentas/atty/issues/77)) ([244abb4](https://github.com/fentas/atty/commit/244abb43eb4f86fe15de9f218eb95f576126542b))
* **llm,proxy:** cursor restore lands on prompt-end col + DSR at key moments ([#102](https://github.com/fentas/atty/issues/102)) ([6757d5d](https://github.com/fentas/atty/commit/6757d5d44f61a239769a8a2c1cae298c7878af32))
* **llm,tests:** live-Ollama tests + chat UX fixes ([#65](https://github.com/fentas/atty/issues/65)) ([cecc609](https://github.com/fentas/atty/commit/cecc609c69b9d24f35e1645098835a1ff241ee2a))
* **llm/doctor:** conclusion turn-count summary + bash DEBUG-trap checks ([#45](https://github.com/fentas/atty/issues/45)) ([cac0c97](https://github.com/fentas/atty/commit/cac0c97256c977ba35678c091cc0e10ebd4a6fe7))
* **llm:** AI mode foundation + Alt+A single-prompt action ([#19](https://github.com/fentas/atty/issues/19)) ([9479354](https://github.com/fentas/atty/commit/94793540579d9c340bcf9565f400b63a980d6188))
* **llm:** Alt+M model cycling + Alt+H help overlay ([#20](https://github.com/fentas/atty/issues/20)) ([594f8fb](https://github.com/fentas/atty/commit/594f8fb29c57bd7219e99654b72fe33a849477d3))
* **llm:** chat persistence cleanup — explicit enable + default path + rotation ([#69](https://github.com/fentas/atty/issues/69)) ([a9da596](https://github.com/fentas/atty/commit/a9da596aab72bcef1ab5adb4c946cc9506a1b6c4))
* **llm:** chat scrollback — PageUp/PageDown for overlay + inline ([#94](https://github.com/fentas/atty/issues/94)) ([7f91bd0](https://github.com/fentas/atty/commit/7f91bd0c937aa904e73d06811584861955653286))
* **llm:** chat-overlay phase 2a — Alt+C alt-screen overlay (open/close + render) ([#56](https://github.com/fentas/atty/issues/56)) ([a8e43e8](https://github.com/fentas/atty/commit/a8e43e8b65763fc367958d8cff83cbd5134167bd))
* **llm:** chat-overlay phase 2b — chat input + LLM-driven open ([#59](https://github.com/fentas/atty/issues/59)) ([9f814fa](https://github.com/fentas/atty/commit/9f814fa94e51431bc1c8fb162ff2b5dca3d1a5c4))
* **llm:** color statusbar AI icon + highlight shortcut tokens ([#53](https://github.com/fentas/atty/issues/53)) ([d0ce656](https://github.com/fentas/atty/commit/d0ce6561674d40f292abeaeefa71c4228f563c5e))
* **llm:** conclusion banner + Alt+C re-show (chat-overlay phase 1) ([#48](https://github.com/fentas/atty/issues/48)) ([5fab7cd](https://github.com/fentas/atty/commit/5fab7cd1fa8af5ed1d580404c70e04ea6902b8a4))
* **llm:** Ctrl+D closes the chat panel and overlay ([#89](https://github.com/fentas/atty/issues/89)) ([3b4c64f](https://github.com/fentas/atty/commit/3b4c64ff3e60c0b33665d427731fbbeeb3323355))
* **llm:** dynamic system context (OS + cwd + git) for the model ([#74](https://github.com/fentas/atty/issues/74)) ([30b9011](https://github.com/fentas/atty/commit/30b901155ba400fbd1f907c4234bd01dc95d77ae))
* **llm:** Esc exits AI mode (binds to llm_exec_cancel) ([#34](https://github.com/fentas/atty/issues/34)) ([5146447](https://github.com/fentas/atty/commit/5146447eaa06a62f215d5a2f15a15655aa7edbe8))
* **llm:** exec dialog (Alt+S) — multi-turn LLM loop with OSC 133 capture ([#21](https://github.com/fentas/atty/issues/21)) ([b1f074b](https://github.com/fentas/atty/commit/b1f074be9e49cd80543f4863125e9bd169b08589))
* **llm:** file-backed chat history via Config.chat_persist_path ([#68](https://github.com/fentas/atty/issues/68)) ([701675e](https://github.com/fentas/atty/commit/701675ec85a5614cf6f0faa3e02ddc7e3b43983e))
* **llm:** full chat input editing — arrows, Home/End, Ctrl+A/E/U/K/W, mid-line insert ([#93](https://github.com/fentas/atty/issues/93)) ([6b769a3](https://github.com/fentas/atty/commit/6b769a3769d19270a131146bf149a62289530006))
* **llm:** handle .question action — latch prompt, accept free-form answer ([#38](https://github.com/fentas/atty/issues/38)) ([8a68b82](https://github.com/fentas/atty/commit/8a68b82006a32430800afad07992cb7366999de4))
* **llm:** inform single-mode prompt about atty's modes + chat overlay ([#60](https://github.com/fentas/atty/issues/60)) ([0707ea4](https://github.com/fentas/atty/commit/0707ea4d86e9dab8eb71a40c1faab87118ff3ad6))
* **llm:** inline chat panel (Alt+C) above the statusbar ([#64](https://github.com/fentas/atty/issues/64)) ([628f584](https://github.com/fentas/atty/commit/628f584ae2c1c00ad6a952614df2eaf32b2c7e91))
* **llm:** mode-toggle redesign for dialog/auto + bash ;C emitter ([#44](https://github.com/fentas/atty/issues/44)) ([6093a4c](https://github.com/fentas/atty/commit/6093a4c86e6d703b006037f82cfa5c9cdb129afc))
* **llm:** Model struct — name + per-model knobs as one unit ([#66](https://github.com/fentas/atty/issues/66)) ([3293685](https://github.com/fentas/atty/commit/3293685c3c386ce7521324a3e0c962603614d913))
* **llm:** multi-choice question UI via ghost_list pick ([#46](https://github.com/fentas/atty/issues/46)) ([7cae0e7](https://github.com/fentas/atty/commit/7cae0e758b46047d5d664527a64e7318b0bda868))
* **llm:** structured assistant-turn rendering in the chat overlay ([#95](https://github.com/fentas/atty/issues/95)) ([af00bee](https://github.com/fentas/atty/commit/af00bee064d6a6a9df223dc96a711ddf0a007f01))
* **llm:** wire auto-exec (Alt+Shift+S) ([#37](https://github.com/fentas/atty/issues/37)) ([4edb236](https://github.com/fentas/atty/commit/4edb2367e20f1bc98bdc2f7cee82816063a9dc9d))
* **module,llm:** ctx.shell_alt_screen_active + restyled conclusion banner ([#58](https://github.com/fentas/atty/issues/58)) ([7e93fee](https://github.com/fentas/atty/commit/7e93feeaa5e05411c3a1e77f6097a930e995ecb4))
* **osc133:** edge_offsets point at the leading ESC, not the terminator ([#36](https://github.com/fentas/atty/issues/36)) ([84a6847](https://github.com/fentas/atty/commit/84a684733ec1d19b341a14dbeefd405baf937318))
* **proxy,llm:** PTY ring buffer for back-pressure during overlay ([#61](https://github.com/fentas/atty/issues/61)) ([3286add](https://github.com/fentas/atty/commit/3286add51babfb20c2940856772c61d9f3ee8527))
* **proxy:** cursor-row tracker + scenario-fixtures harness + delete-history-after-uparrow fix ([#18](https://github.com/fentas/atty/issues/18)) ([086af92](https://github.com/fentas/atty/commit/086af92d1376c2462f450e38d8e9cfc339aab221))
* **proxy:** ghost_accept_word also stops at `/` (path-segment walk) ([#76](https://github.com/fentas/atty/issues/76)) ([0d25eea](https://github.com/fentas/atty/commit/0d25eeaeaf11ce6123dd439a77eff50e2fd4a029))
* **proxy:** subprocess-context tracking — cross-host history via atuin --cwd ([#16](https://github.com/fentas/atty/issues/16)) ([ffb1863](https://github.com/fentas/atty/commit/ffb186375e0c49cb8e6b83fc361249793b775f3f))
* **proxy:** suspend ghost overlay + history recording while in a subprocess ([#15](https://github.com/fentas/atty/issues/15)) ([c25e12a](https://github.com/fentas/atty/commit/c25e12a0aaa6abc663ebdfd000e0bab2d69361fe))
* **security_guard:** externalise flagged-npm list + Shai-Hulud seeds + scoped-pkg fix ([#114](https://github.com/fentas/atty/issues/114)) ([2666ade](https://github.com/fentas/atty/commit/2666ade357a17d1953f935ecdfaf9b962211f934))
* **security_guard:** flagged-URL matcher + design for semi-automatic updates ([#115](https://github.com/fentas/atty/issues/115)) ([9327f55](https://github.com/fentas/atty/commit/9327f55f6a5ee5f94e5e8ae030a0fa0be9191d50))
* **security_guard:** PID-tree threat marking + statusbar 🛡 indicator ([4cc5085](https://github.com/fentas/atty/commit/4cc508512f9141527b9e9d3f34602db07cbf0fee))
* **security_guard:** PID-tree threat marking + statusbar threat indicator ([#112](https://github.com/fentas/atty/issues/112)) ([4cc5085](https://github.com/fentas/atty/commit/4cc508512f9141527b9e9d3f34602db07cbf0fee))
* **security_guard:** Tier-1 pre-Enter pattern matcher (V1 MVP) ([#104](https://github.com/fentas/atty/issues/104)) ([993148a](https://github.com/fentas/atty/commit/993148a01d43eede23e11ff5f50ada04b0c37f04))
* **security_guard:** UDS client wires the atty-guard sidecar in ([#106](https://github.com/fentas/atty/issues/106)) ([18c8183](https://github.com/fentas/atty/commit/18c818351524def0050e5792e7559fcecaeff9e8))
* **security_guard:** V2-G AtomMatcher — Aho-Corasick over flagged_atoms-txt ([#119](https://github.com/fentas/atty/issues/119)) ([11c8fe3](https://github.com/fentas/atty/commit/11c8fe3aa68bc4bdbe71431a932d129a39dcebe3))
* **security_guard:** V2-H sliding-context-window for SLM + Tier-2 hint plumbing ([#120](https://github.com/fentas/atty/issues/120)) ([f3aab0a](https://github.com/fentas/atty/commit/f3aab0a5608b5aa2710421e5051265567a39a6a0))
* **security_guard:** V2-I baked-in atom fetcher (GTFOBins + cron) ([#121](https://github.com/fentas/atty/issues/121)) ([45509c3](https://github.com/fentas/atty/commit/45509c32be260038241ce278457fb3069816152b))
* **security_guard:** V2-I-2 — Sigma + LOLBAS atom sources ([#125](https://github.com/fentas/atty/issues/125)) ([3aac69e](https://github.com/fentas/atty/commit/3aac69e8901ef4d8b30b2286e8b9ebe30a14edbc))
* **security_guard:** V2-J — threat-level accumulator (multi-hit Tier-1 + SLM) ([#126](https://github.com/fentas/atty/issues/126)) ([a0fcf90](https://github.com/fentas/atty/commit/a0fcf9039ba1a649c9342e302b0d8794889c5c95))
* **security_guard:** V2-J-2 — opt-in auto-Block escalation + manual test runner ([#127](https://github.com/fentas/atty/issues/127)) ([ef60362](https://github.com/fentas/atty/commit/ef6036251359d1694d59258a10eab00f61a87738))
* **trace:** env-var-gated diagnostic logging at proxy boundaries ([#90](https://github.com/fentas/atty/issues/90)) ([c11128d](https://github.com/fentas/atty/commit/c11128d5f2d62ae19fb808ef11b7bbb3f206801a))


### Bug Fixes

* **csiu:** translate printable ASCII + drop modified VT-CSI (Windsurf integrated terminal) ([#124](https://github.com/fentas/atty/issues/124)) ([e2b7881](https://github.com/fentas/atty/commit/e2b7881cbe8eb20f91e1c637f867878884f126ba))
* **doctor:** capture DEBUG trap in outer scope (function-local hides it) ([#98](https://github.com/fentas/atty/issues/98)) ([f29d58f](https://github.com/fentas/atty/commit/f29d58f04afabceaa505472fb9e3c292a729c278))
* **e2e:** make delete_history_match_after_uparrow deterministic ([#24](https://github.com/fentas/atty/issues/24)) ([e2ce456](https://github.com/fentas/atty/commit/e2ce456e0b87a8d975a076de0ecbe2db58a202a7))
* **keymap:** csiUToLegacy drops release/repeat events (vim doubles) ([#129](https://github.com/fentas/atty/issues/129)) ([c8e414a](https://github.com/fentas/atty/commit/c8e414a7a5843ec1087de9aa8b3c49eb552a4f0d))
* **line_state,proxy:** Left arrow no longer 'deletes' chars via ghost overlay ([#73](https://github.com/fentas/atty/issues/73)) ([d675c01](https://github.com/fentas/atty/commit/d675c012d200ae06223feff04694c833a08fb3dc))
* **line_state:** ghost over-paint after Arrow-Up — Ctrl-A + cursor-motion CSI handling ([#122](https://github.com/fentas/atty/issues/122)) ([ebf7fac](https://github.com/fentas/atty/commit/ebf7face75274335922a21aeb301f692e0b10f76))
* **line_state:** syncFromCapture preserves cursor_pos on unchanged buffer ([#128](https://github.com/fentas/atty/issues/128)) ([7177491](https://github.com/fentas/atty/commit/7177491d399174d42cf29b5052fd295782d7741a))
* **llm:** chat close cursor + idle-state shortcut discoverability ([#78](https://github.com/fentas/atty/issues/78)) ([6044c4e](https://github.com/fentas/atty/commit/6044c4e7521aaed42b72848c3fb346125de12ecb))
* **llm:** decode \\uXXXX JSON escapes (was silently dropping shell metas) ([4c4cb86](https://github.com/fentas/atty/commit/4c4cb86da07b039f9e7352c5bcf1efd53a1d0cc5))
* **llm:** decode JSON unicode escapes — shell metas no longer dropped ([#91](https://github.com/fentas/atty/issues/91)) ([4c4cb86](https://github.com/fentas/atty/commit/4c4cb86da07b039f9e7352c5bcf1efd53a1d0cc5))
* **llm:** inline-chat paint CUP-restores cursor to shell row ([#79](https://github.com/fentas/atty/issues/79)) ([a7fbc74](https://github.com/fentas/atty/commit/a7fbc7481a82e5d0de3a76bf3cf4b2d48c341b8c))
* **llm:** kitty kbd Alt bindings + configurable Enter trigger ([#40](https://github.com/fentas/atty/issues/40)) ([f79a1bf](https://github.com/fentas/atty/commit/f79a1bfaf98dba21f708850562222fe9653caeaf))
* **llm:** move default_bindings INSIDE configure() — Alt+* keys were dead ([#72](https://github.com/fentas/atty/issues/72)) ([c29077e](https://github.com/fentas/atty/commit/c29077e842f4080567f28282f3928193321d3c21))
* **llm:** overlay layout robustness + rebind Alt+C→inline / Alt+Shift+C→overlay ([#63](https://github.com/fentas/atty/issues/63)) ([d8811e7](https://github.com/fentas/atty/commit/d8811e77cacaec5fc7195b4b574f4b7dd85d0f98))
* **llm:** surface DIALOG/AUTO mode hint whenever state machine engaged ([#92](https://github.com/fentas/atty/issues/92)) ([ce0dfc3](https://github.com/fentas/atty/commit/ce0dfc34b6387943f6d14321357655ff4b8b94f7))
* **osc133:** treat ;A as prompt-active so partial emitters get ghost text ([#17](https://github.com/fentas/atty/issues/17)) ([6e5abe7](https://github.com/fentas/atty/commit/6e5abe7aa40fa05ac7ee5a7f35ddd9642fa05159))
* **proxy:** gate ghost_accept on !cursor_moved so mid-line Right doesn't paste history ([#97](https://github.com/fentas/atty/issues/97)) ([4e74b38](https://github.com/fentas/atty/commit/4e74b38039384da2b2bb981b0888fff1a1da0dcd))
* **proxy:** reactivate statusbar when LLM chat overlay closes ([#96](https://github.com/fentas/atty/issues/96)) ([7d62a4c](https://github.com/fentas/atty/commit/7d62a4c9ecb5d026da911a32c3af06d0a713b2cc))
* **proxy:** refuse non-TTY stdio and harden SIGPIPE handling ([#51](https://github.com/fentas/atty/issues/51)) ([9183deb](https://github.com/fentas/atty/commit/9183deb254e51791cf1070813144543b104b4043))
* **proxy:** scroll shell content up when inline panel grows past cursor ([#103](https://github.com/fentas/atty/issues/103)) ([c2774a8](https://github.com/fentas/atty/commit/c2774a896963bd3931b15c1ef96b56b6e2c88366))
* **proxy:** suspend statusbar and give app full rows on alt-screen entry ([#14](https://github.com/fentas/atty/issues/14)) ([74cc7f4](https://github.com/fentas/atty/commit/74cc7f40f5d4a3a06e0bbc8ec1b018066a80aa99))


### Performance

* **proxy:** fast-path master-read for escape-free chunks ([#62](https://github.com/fentas/atty/issues/62)) ([eb02f56](https://github.com/fentas/atty/commit/eb02f567baa684024138bcee77983bbdaff35fcc))


### Refactor

* extract tests to sibling files across the codebase ([#82](https://github.com/fentas/atty/issues/82)) ([6010ed2](https://github.com/fentas/atty/commit/6010ed2cb6bee933afa18f0ea8d5d4f62d6b1666))
* **guardrail:** split Match union + match helpers into submodule folder ([#31](https://github.com/fentas/atty/issues/31)) ([aa1faae](https://github.com/fentas/atty/commit/aa1faae45ce0829fc5a8aef00e69edcc0b0ef52f))
* **history:** split pure format helpers into submodule folder ([#25](https://github.com/fentas/atty/issues/25)) ([d692dfc](https://github.com/fentas/atty/commit/d692dfc854778da375fc14b55eab8fbc2199cf74))
* **keymap:** split into submodule folder ([#22](https://github.com/fentas/atty/issues/22)) ([79c498b](https://github.com/fentas/atty/commit/79c498bdc65d0e7609387acea989457e234f02aa))
* **llm-tests:** split the bundled tests file along the new sibling boundaries ([#87](https://github.com/fentas/atty/issues/87)) ([9702d65](https://github.com/fentas/atty/commit/9702d6540f9b0a1be9a5324998311d82fe7dbbe6))
* **llm:** extract 1700 lines of inline tests to a sibling tests file ([#81](https://github.com/fentas/atty/issues/81)) ([458f21f](https://github.com/fentas/atty/commit/458f21f31a4c2d75221298c12f59110b69b2d717))
* **llm:** extract 1700 lines of inline tests to llm/tests.zig ([458f21f](https://github.com/fentas/atty/commit/458f21f31a4c2d75221298c12f59110b69b2d717))
* **llm:** extract Config struct into llm/types.zig ([#32](https://github.com/fentas/atty/issues/32)) ([49b2d2c](https://github.com/fentas/atty/commit/49b2d2c801f3e3537ea9d63e1dbf5a5671439276))
* **llm:** extract dialog teardown helpers (dialogReset + abortDialog) ([#55](https://github.com/fentas/atty/issues/55)) ([a1b34dc](https://github.com/fentas/atty/commit/a1b34dc98a44d84c66b63e04fd9ac6469206e72b))
* **llm:** extract dialog types + pure helpers to llm/dialog.zig ([#42](https://github.com/fentas/atty/issues/42)) ([2b00ddf](https://github.com/fentas/atty/commit/2b00ddfa3bc27dcc3727175007c9114550b62970))
* **llm:** extract env-var resolution helpers to llm/env.zig ([#49](https://github.com/fentas/atty/issues/49)) ([a0830fb](https://github.com/fentas/atty/commit/a0830fbfb0740f2e13167c8e75995c4add9189ee))
* **llm:** extract hooks + dialog state machine to a sibling factory ([#86](https://github.com/fentas/atty/issues/86)) ([e29a802](https://github.com/fentas/atty/commit/e29a802551aaefb168d8fdf2ef48fab77ab40bec))
* **llm:** extract paint surface to a sibling factory module ([#83](https://github.com/fentas/atty/issues/83)) ([011c39b](https://github.com/fentas/atty/commit/011c39b8db5fbe5344d28144c277c96123dc3c6c))
* **llm:** extract turn ring + capture + latch helpers ([#52](https://github.com/fentas/atty/issues/52)) ([567e675](https://github.com/fentas/atty/commit/567e675999c4c87ef7fcebb61e8d939211bfbe71))
* **llm:** extract worker thread + HTTP RPC + extract helpers to llm/worker.zig ([#43](https://github.com/fentas/atty/issues/43)) ([99b7308](https://github.com/fentas/atty/commit/99b730830561efba11b861f0efea53da0c107cde))
* **llm:** heap-promote captured_output + last_assistant_json off Runtime ([#35](https://github.com/fentas/atty/issues/35)) ([14ccaa3](https://github.com/fentas/atty/commit/14ccaa31aa9639190d5f8333a9518e386292ec0b))
* **llm:** split pure parse helpers into submodule folder ([#28](https://github.com/fentas/atty/issues/28)) ([9b583d3](https://github.com/fentas/atty/commit/9b583d3c8d6c648dfe41a0fc1a26b8abaaceb54b))
* **proxy:** split pure I/O helpers into submodule folder ([#30](https://github.com/fentas/atty/issues/30)) ([e0a928e](https://github.com/fentas/atty/commit/e0a928e0beec06c0d404f6fa69072b2dc2d2c073))
* **subprocess:** split into submodule folder ([#23](https://github.com/fentas/atty/issues/23)) ([a1823ae](https://github.com/fentas/atty/commit/a1823ae0abe594ad49b34e5062fd7add8ec2e83e))


### Documentation

* reflect recently-shipped features ([4d1c938](https://github.com/fentas/atty/commit/4d1c938f344ca98c8b83292b16e0551692168b07))
* reflect recently-shipped features ([#65](https://github.com/fentas/atty/issues/65)-[#70](https://github.com/fentas/atty/issues/70)) ([#71](https://github.com/fentas/atty/issues/71)) ([4d1c938](https://github.com/fentas/atty/commit/4d1c938f344ca98c8b83292b16e0551692168b07))
* refresh for Alt bindings + enter_action + atty doctor ([#41](https://github.com/fentas/atty/issues/41)) ([6af52ae](https://github.com/fentas/atty/commit/6af52ae3237382b3e5d3ef6167e3b5bf6d1e88a3))
* refresh for kitty Alt bindings + enter_action + atty doctor ([6af52ae](https://github.com/fentas/atty/commit/6af52ae3237382b3e5d3ef6167e3b5bf6d1e88a3))
* **roadmap:** defer PR M (atuin submodule split) ([5941f63](https://github.com/fentas/atty/commit/5941f63c0538fd5772eed43da70ff2d5f0ed1c74))
* **roadmap:** mark [#21](https://github.com/fentas/atty/issues/21) merged + add PR P (fix surviving e2e flake) ([ccf1597](https://github.com/fentas/atty/commit/ccf1597e08917830b38bd8bbd8a26322756a46e4))
* **roadmap:** mark PR [#26](https://github.com/fentas/atty/issues/26) (line-state author) merged ([fd1deb9](https://github.com/fentas/atty/commit/fd1deb930c333333920047224b3b9e2e7c076eef))
* **roadmap:** mark PR [#33](https://github.com/fentas/atty/issues/33) (guardrail rules.zig + extra_rules) merged ([55c5d01](https://github.com/fentas/atty/commit/55c5d01a586d1a452356d90f2b7801c50a70c738))
* **roadmap:** mark PR [#36](https://github.com/fentas/atty/issues/36) (osc133 edge offset) merged ([d6ed008](https://github.com/fentas/atty/commit/d6ed0083ff3b52d84bdca1b78af9d66efc65b218))
* **roadmap:** mark PR [#37](https://github.com/fentas/atty/issues/37) (auto-exec) merged ([4e455f5](https://github.com/fentas/atty/commit/4e455f5b076e0716a64450807f48cbbef71b6de1))
* **roadmap:** mark PRs [#27](https://github.com/fentas/atty/issues/27) / [#28](https://github.com/fentas/atty/issues/28) / [#29](https://github.com/fentas/atty/issues/29) / [#30](https://github.com/fentas/atty/issues/30) merged ([ae38de6](https://github.com/fentas/atty/commit/ae38de681d6c115ee8b6c1e5e6dd57a064d00af2))
* **roadmap:** mark PRs [#31](https://github.com/fentas/atty/issues/31) + [#32](https://github.com/fentas/atty/issues/32) merged; defer remaining refactor slices ([ee6b0d0](https://github.com/fentas/atty/commit/ee6b0d0f5387dd812f66b2c344465510e0ee1e99))
* **roadmap:** mark PRs [#34](https://github.com/fentas/atty/issues/34) (Esc) + [#35](https://github.com/fentas/atty/issues/35) (heap-promote) merged ([5af2cec](https://github.com/fentas/atty/commit/5af2cec0b93d8eb4c61acf5e46b8643d047f1b5f))
* rough outlines for chat-overlay phase 2 + security guard ([#54](https://github.com/fentas/atty/issues/54)) ([f49a415](https://github.com/fentas/atty/commit/f49a4154af0e1943394686aa5ea3755e1b2a544c))
* **security_guard:** mark V1+V2-A+V2-D shipped; sequence V2-B/C/E ([#107](https://github.com/fentas/atty/issues/107)) ([206f51c](https://github.com/fentas/atty/commit/206f51c8fb98a0d9ccb5b9244e5b72b177892c31))
* **security_guard:** surface module + atty-guard in CLAUDE + modules docs ([#111](https://github.com/fentas/atty/issues/111)) ([ed82289](https://github.com/fentas/atty/commit/ed82289e8e03d327e6afdc114994d51bd25b9882))
* **security_guard:** V1+V2-A+V2-D shipped; mark next steps ([206f51c](https://github.com/fentas/atty/commit/206f51c8fb98a0d9ccb5b9244e5b72b177892c31))
* **security:** three-component architecture (PTY + eBPF + SLM daemon) ([#75](https://github.com/fentas/atty/issues/75)) ([2c4214c](https://github.com/fentas/atty/commit/2c4214c30cd315c71504e4be8109981b819959f9))
* surface security_guard module + atty-guard sidecar in CLAUDE.md / modules.md ([ed82289](https://github.com/fentas/atty/commit/ed82289e8e03d327e6afdc114994d51bd25b9882))
* surface V2-J-2 auto-Block + atty-side REFUSED path ([#130](https://github.com/fentas/atty/issues/130)) ([7c1b570](https://github.com/fentas/atty/commit/7c1b57062e3d67464960b1cdc0c08f67b65918b3))
* widen home-page column — no TOC sidebar to share width with ([1935732](https://github.com/fentas/atty/commit/193573212a97417939008ad6ae0a8a7c53d287f4))
* widen home-page column to match doc-page total width ([#13](https://github.com/fentas/atty/issues/13)) ([1935732](https://github.com/fentas/atty/commit/193573212a97417939008ad6ae0a8a7c53d287f4))

## [0.4.0](https://github.com/fentas/atty/compare/v0.3.0...v0.4.0) (2026-05-13)


### Features

* **cli:** `atty init [shell]` prints shell-integration snippet for eval ([044c6e5](https://github.com/fentas/atty/commit/044c6e5218d712bd2bb1b14566cb94807539799d))
* **llm:** #: prompt → LLM command generation, async via worker thread ([9446414](https://github.com/fentas/atty/commit/9446414eccddd42df0fe1e13dee5325d925b03c0))
* **llm:** inject configurable env vars as model context ([79308c7](https://github.com/fentas/atty/commit/79308c7c70de9b5d5dbf331f6a5d2ff791bd0888))
* **llm:** live signals while typing `#: …` prefix (cursor + statusbar) + push prompts to history ([a62631b](https://github.com/fentas/atty/commit/a62631b0aff7858f513d0a3e6a335be0ca3416dd))
* **llm:** one-line explanation alongside the injected command ([3b2418b](https://github.com/fentas/atty/commit/3b2418bd434a22eb1691cb1f90fa3c721c200777))
* **llm:** support a static `api_base` in config — no env required ([47bc039](https://github.com/fentas/atty/commit/47bc039e485506b495bffea187497fa881a53c45))
* **llm:** transparent failure — surface every "nothing happened" reason as a hint ([56d9eab](https://github.com/fentas/atty/commit/56d9eab7051297fc64de09e2f3c1939ba519bd1d))
* phase 2 — LLM module + statusbar hint/error slots + atty init ([7ddd8f2](https://github.com/fentas/atty/commit/7ddd8f23d009980da31522bfdf6c7d5fe26e8f19))
* **proxy:** sync line_state with OSC 133 capture (Arrow Up + completion + paste) ([e8095c5](https://github.com/fentas/atty/commit/e8095c510b4583f63c39c12352520946581039f2))
* **statusbar:** add hint row above status text ([78398ae](https://github.com/fentas/atty/commit/78398aeef255f68c1a6dcbb471cb5592d350f32d))
* **statusbar:** blank padding row between hint and status + dedicated hint_style ([a029acb](https://github.com/fentas/atty/commit/a029acb6653889815e791aa89c1ad015545c41d6))
* **statusbar:** errors render as muted-red notifications in their own slot ([4c80c9b](https://github.com/fentas/atty/commit/4c80c9b0355d16b7ea55bc8eab6d10f6d7f14da2))


### Bug Fixes

* address copilot review round 1 on PR [#5](https://github.com/fentas/atty/issues/5) ([0816613](https://github.com/fentas/atty/commit/0816613a02d481a9f882ad1987ce2b2b6f3e18c6))
* address copilot review round 2 on PR [#5](https://github.com/fentas/atty/issues/5) ([aaa9e12](https://github.com/fentas/atty/commit/aaa9e12bf41ed80496fac82e0999921391d2cbe4))
* address copilot review round 2 on PR [#7](https://github.com/fentas/atty/issues/7) — capture UTF-8 bytes in OSC 133 input ([3f51566](https://github.com/fentas/atty/commit/3f515660877c31acd4b1fb9953af4314b47c5ea8))
* address copilot review round 3 on PR [#5](https://github.com/fentas/atty/issues/5) ([9a85d09](https://github.com/fentas/atty/commit/9a85d096cce08f09b8bfb7d6f3c7ffa0a36c3961))
* address copilot review round 4 on PR [#5](https://github.com/fentas/atty/issues/5) — stale comments on statusbar constructors ([591b801](https://github.com/fentas/atty/commit/591b801cc525f0f0cb9b8a8ae5de915f7be73d6d))
* address copilot review round 5 on PR [#5](https://github.com/fentas/atty/issues/5) ([159fb8d](https://github.com/fentas/atty/commit/159fb8df582f099b3cd5d72b61b7bd845f0725f6))
* address copilot review round 6 on PR [#5](https://github.com/fentas/atty/issues/5) ([f358726](https://github.com/fentas/atty/commit/f3587265cd475048d2688424b5a9f4b3bed1ff25))
* address copilot review round 7 on PR [#5](https://github.com/fentas/atty/issues/5) — stale comments after earlier rounds ([56144e5](https://github.com/fentas/atty/commit/56144e55dded9a528a68c74633ff905807ddfafc))
* **build:** make test / itest / e2e forward TARGET; Linux defaults to musl ([b607d5c](https://github.com/fentas/atty/commit/b607d5cf559bbd3fe3442a65d2d9177117445750))
* **cli:** `atty init` — drop ATTY export, pass shell through, add OSC 133 ([f8853e1](https://github.com/fentas/atty/commit/f8853e179b34756f8bdd583b6b68a8ea93a8360a))
* **dispatch:** isolate per-module errors in delete-history fan-out ([ea61e59](https://github.com/fentas/atty/commit/ea61e59b078963e90b19938ab54a03186d553b04))
* **dispatch:** isolate per-module errors in delete-history fan-out ([954c791](https://github.com/fentas/atty/commit/954c7910e1d0a6c7548e14d5f2ab6ad2a4b7ac22))
* **llm:** address copilot review round 2 ([09110dc](https://github.com/fentas/atty/commit/09110dc044cf1dc2accb11147ca61ae332958819))
* **llm:** address copilot review round 3 — tolerate whitespace in `"content":` key ([688a557](https://github.com/fentas/atty/commit/688a557a760543b95a8cc5f4ec76cdce97a6d419))
* **llm:** address copilot review round 4 — strip C1 control codepoints (security) ([58a0708](https://github.com/fentas/atty/commit/58a07085d97d66d5621b4fe52c5fceec14b15ff7))
* **llm:** address copilot review round 5 — non-blocking shutdown + URL slash normalisation ([da9b120](https://github.com/fentas/atty/commit/da9b120c713dd48d96b7720b94b9ed5f24a951b8))
* **llm:** address copilot review round 6 — normalise LLM_API_BASE trailing slash too ([7141c30](https://github.com/fentas/atty/commit/7141c30185f8ac643745b504432a9228d727bdd6))
* **llm:** bound \uXXXX skip in extractCommand; expand escape tests to cover \\f and malformed \\u ([99094b9](https://github.com/fentas/atty/commit/99094b9fcfce8d325c4c283eb811aaa00d4ac2e8))
* **llm:** copilot review round 1 — stale-response guard + security strip + body cap ([d63fb0d](https://github.com/fentas/atty/commit/d63fb0d4c66e873ccad0a03771d7b599e02f6425))
* **llm:** dead in_flight_notified field, misleading timeout_ms doc, escape-handler bug in extractCommand ([48007dd](https://github.com/fentas/atty/commit/48007dd1de65d419e6738e1b539df5742a346ce0))
* **llm:** drop io arg from std.http.Client.deinit (zig 0.16 API drift) ([1da54a2](https://github.com/fentas/atty/commit/1da54a206897ec7ce7e8b7f15190cb951412f070))
* **llm:** use usize for hex-skip counter; clarify \u test comment ([9ef15c5](https://github.com/fentas/atty/commit/9ef15c5258addbd98562ef56d3f1af73310b52c8))
* **proxy:** byte-stream CSI-u translation in hidden-input fast path ([abdeda1](https://github.com/fentas/atty/commit/abdeda1aff8a5d1c97ced584e8e6430d53d20db4))
* **proxy:** errno-gated write retry — don't spin on unrecoverable errors ([45471ac](https://github.com/fentas/atty/commit/45471ac3a7a9b54f514465e53e7e3036e602ac5d))
* **proxy:** redact hidden input — short-circuit input pipeline while ECHO is off ([a984322](https://github.com/fentas/atty/commit/a984322d8221c605e861b6a18e853ae616f31aa8))
* **proxy:** redact password input — don't track keystrokes while ECHO is off ([ea412d2](https://github.com/fentas/atty/commit/ea412d284ae3745482ccea60a95be9b3fc2b45e9))
* **proxy:** refine hidden-input gate so interactive shells stop tripping CSI-u redaction ([a7b387b](https://github.com/fentas/atty/commit/a7b387b6345aa47ba934cc3fd0c93eee34f94d91))
* **proxy:** refine hidden-input gate to ICANON && !ECHO — restore CSI-u translation in interactive shells ([08e8fe2](https://github.com/fentas/atty/commit/08e8fe2e59a9ab58f5c4510d00c7f856118424e4))
* **proxy:** translate CSI-u inside the hidden-input fast path ([99f5f93](https://github.com/fentas/atty/commit/99f5f93ffad44eedab05775f62af3ed34a1f627a))
* **proxy:** treat EAGAIN as error.WriteFailed in writeFully ([6281c62](https://github.com/fentas/atty/commit/6281c626204ea86f49c09d2e4e057b82ccd11c3c))


### Documentation

* phase-2 surface (LLM module, new hooks, statusbar slots, floating TOC) ([bb8090a](https://github.com/fentas/atty/commit/bb8090a2bdfb44abc34212c70a8f7bd6c322a613))
* sidebar TOC with scroll-spy — keep 78ch content width ([996f938](https://github.com/fentas/atty/commit/996f938a6b1729684502b2fd4879acf6530185fe))
* sidebar TOC with scroll-spy — keep 78ch content width, add TOC to architecture + providers ([c8439d1](https://github.com/fentas/atty/commit/c8439d1869eb5be6c3c4472acd8c2c5e98cc27f2))

## [0.3.0](https://github.com/fentas/atty/compare/v0.2.0...v0.3.0) (2026-05-13)


### Features

* **atuin:** delete_scope config — default .exact via fuzzy + ^…$ anchors ([166e534](https://github.com/fentas/atty/commit/166e5349769a5985c849869477af011f86bf6b83))
* **atuin:** provideGhostList + src/modules/_lib.zig shared helpers ([ad53afa](https://github.com/fentas/atty/commit/ad53afa56213c95b9e2577c746ce006b55069da5))
* **atuin:** record on Enter + manual sync via CLI ([b615bba](https://github.com/fentas/atty/commit/b615bba41cb1b21f1f8a192249637035853640c4))
* **config:** accept-ghost takes a list of keys + recover from uncertain ([2c00a82](https://github.com/fentas/atty/commit/2c00a82928831d74d4c36124d410ea2db88da2aa))
* **e2e:** per-scenario config + ghost_accept + statusbar_visible scenarios ([91245c2](https://github.com/fentas/atty/commit/91245c2b82d94aba47fd26a8b4cbe84338b36192))
* **get.sh:** symlink installed binary to source build dir ([ccde793](https://github.com/fentas/atty/commit/ccde793d1c8c18a50311c5d8e9f4e0c2f5bc7d4c))
* **ghost:** configurable overlay style via atty.ghost.Style ([43bf695](https://github.com/fentas/atty/commit/43bf695942e8b6aadc6a93913fd1020c35d3c170))
* **ghost:** multi-row pick list — provideGhostList + Ctrl+1..9 / Esc+1..9 ([774b71e](https://github.com/fentas/atty/commit/774b71ecacb1dba70ecea4674279d73349bc5599))
* **guardrail:** per-rule .mode — confirm / confirm_once / block / silent_block ([a690d18](https://github.com/fentas/atty/commit/a690d18e4a4aabbe7ddfb6dcb8a2ba66544462aa))
* **history:** add shell-native history module ([32f8eed](https://github.com/fentas/atty/commit/32f8eedfc7b67a0d68668c1188e81cc3bbdde782))
* **history:** Ctrl+Shift+D deletes matching line, status bar flashes ([5cb85e6](https://github.com/fentas/atty/commit/5cb85e61bf2e7165f0bd2c5274e3190f467bc1ba))
* **history:** shell-native history module ([6f0e816](https://github.com/fentas/atty/commit/6f0e816c3bba462cf6775725033fa34a9f30ee3b))
* **incognito:** Ctrl+Shift+I toggle + kitty kbd + status bar segment ([795170c](https://github.com/fentas/atty/commit/795170cbe495396984900d5730c996aa2710d2b0))
* **incognito:** muted-red style for the 🔒 segment ([d9d53f6](https://github.com/fentas/atty/commit/d9d53f61a9d8fc3633f33b79dd79449b16c7d759))
* **input-tracking:** DSR + 1-row grid emulator to recover line state from shell redraws ([3185e53](https://github.com/fentas/atty/commit/3185e53c07c864d2b546e40cabef975c0c9df5d1))
* **keymap:** Ctrl+Tab also accepts the ghost suggestion ([db435f6](https://github.com/fentas/atty/commit/db435f6f3a2c1e801a4df9bb2cfc9afa8824f079))
* **make:** add link/unlink targets for live dev binary ([94fe9c6](https://github.com/fentas/atty/commit/94fe9c6c52785d20c3b5038c39647bb199217ca9))
* **osc133:** auto-detected marker support, falls back to keystroke tracking ([9bc9e3b](https://github.com/fentas/atty/commit/9bc9e3b8c169228442056120df3ca97739df7ed4))
* **statusbar:** DECSTBM-reserved bottom row + module statusText hook ([4003649](https://github.com/fentas/atty/commit/4003649b4ee64ff050742379808858a610ef7544))
* **test:** add e2e framework with VT grid and visual snapshots ([f2f49b9](https://github.com/fentas/atty/commit/f2f49b912e32c573b9fe20df8da492d45512ab76))


### Bug Fixes

* **atuin:** implement deleteHistoryMatch — Ctrl+Shift+D now reaches atuin too ([b210d37](https://github.com/fentas/atty/commit/b210d377e20fef2de2ab3be549489164b8e0056e))
* **atuin:** newest match first, async sync, right-arrow accepts ghost ([fcaecda](https://github.com/fentas/atty/commit/fcaecdaf1360f222e0e8953a319b75fd60c3e8d6))
* **atuin:** suggestion_ttl_ms = 0 disables the timer; new default ([1341b42](https://github.com/fentas/atty/commit/1341b423b28c54b81616119c7133467da3edc041))
* **ghost_accept:** gather fresh suggestion, don't require ghost.visible ([6ed10c1](https://github.com/fentas/atty/commit/6ed10c1b29a018d4585234795564a2417236c3d4))
* **ghost_list:** dynamic activation, atuin-Ctrl+R style — no permanent dead space ([c1cdefb](https://github.com/fentas/atty/commit/c1cdefbaa52be0e2ded9b592da82abea9be09cdc))
* **ghost_list:** inflate statusbar reservation so shell pushes prompt above the list ([fe6d19e](https://github.com/fentas/atty/commit/fe6d19eae088f63ca29f80c67ffd152ce059e88d))
* **ghost_list:** paint with absolute CUP, anchored to bottom rows ([c56aee2](https://github.com/fentas/atty/commit/c56aee2bec132a7c9c072999bde5fdc23c0f1bc3))
* **ghost:** drop input-path renderGhost — was racing the shell echo ([eff5aa1](https://github.com/fentas/atty/commit/eff5aa11c94a4bb846e702900a08eea8112604f8))
* **guardrail:** banner never fired end-to-end + dispatchLineCommit ran past .swallow ([e72586a](https://github.com/fentas/atty/commit/e72586ac13d4afec2bae8d5dc232749a196a8536))
* **incognito:** three real bugs from manual testing ([d7bd349](https://github.com/fentas/atty/commit/d7bd3491241a9e91e64a57c4186b1fb1e1820c88))
* **input-tracking:** three race-condition fixes after live-test off-by-one ([77a127b](https://github.com/fentas/atty/commit/77a127b54cdae3d8dd4e1fa736b55eb96eb60295))
* **kitty:** re-enable disambiguate flag + intercept unmapped CSI-u ([e8d304b](https://github.com/fentas/atty/commit/e8d304bccf940377e6fe69e91d4402c5da966e71))
* **kitty:** translate CSI-u back to legacy bytes for Ctrl+letter, Esc, Tab, … ([90c4e5d](https://github.com/fentas/atty/commit/90c4e5db7120efbcda53a8d2277a9d8ad168b6d1))
* **statusbar:** activate parks cursor at (1,1), not in reserved area ([1808fbb](https://github.com/fentas/atty/commit/1808fbb8b8ecfabef7c268601cbd932091fe1507))
* **statusbar:** clear screen on activate for consistent fresh start ([accc89d](https://github.com/fentas/atty/commit/accc89d6fb1a05ce4321241e19935bd8614d1677))


### Refactor

* **config:** every subsystem is a struct (style guide commitment) ([74ae7af](https://github.com/fentas/atty/commit/74ae7af90c55efc9734a3542e9d7e1b2c8acde56))
* **config:** generalise key bindings as { bytes, action } pairs ([6ac581b](https://github.com/fentas/atty/commit/6ac581b14255c3b40ed06dc602135d1e01b26484))
* **config:** group statusbar fields into atty.StatusBar struct ([d0d0f15](https://github.com/fentas/atty/commit/d0d0f15b9307871dcbd45cdfd584d7eebfb375c2))
* **config:** split user config from defaults (dwm-style) ([734da31](https://github.com/fentas/atty/commit/734da31a047b45e89947fae64ee0c9d11a3ba992))
* **defaults:** swap atuin → history in the default tuple ([18be9bc](https://github.com/fentas/atty/commit/18be9bc2a6b387ff4a18ecf329e8e5faebc88aa5))
* **ghost_list:** sweep dead anchor/RenderMode plumbing + docs ([425bbbd](https://github.com/fentas/atty/commit/425bbbd1fcfba4a3f72bd6d802a73fd79eb91798))
* **keymap:** extract keymap.match() + tests, use from proxy ([f8926fb](https://github.com/fentas/atty/commit/f8926fb469ce593373cddc9e6784eaad4048b0ce))
* **main:** extract args.zig parser + tests (7 cases) ([8037b1e](https://github.com/fentas/atty/commit/8037b1e7a311ec220e08d82ff96d33cf76225388))
* **proxy:** extract status_text.zig — pure segment assembly + tests ([98c02db](https://github.com/fentas/atty/commit/98c02db538b9da01c6805dc5b5c15f226d3851cd))
* **proxy:** hoist keymap import + name kitty kbd push/pop bytes ([0e416a4](https://github.com/fentas/atty/commit/0e416a4d76f3cf51f11af201ce0c2af7738dfa6c))
* **style:** promote Style to a first-class atty.Style with presets ([d2898f7](https://github.com/fentas/atty/commit/d2898f7a3ad2e2029ed54be939a716cda555038b))


### Documentation

* add CLAUDE.md for fresh-agent orientation ([86d5f28](https://github.com/fentas/atty/commit/86d5f280e4b84aa6bf17f8cf2c3bad137d91a1bf))
* clarify gatherGhostText priority + atuin/history race window ([8347363](https://github.com/fentas/atty/commit/83473632844d616b2ec85d3b9d215e95c8668361))
* keymap, atuin record/sync, onLineCommit, e2e ([247a4f1](https://github.com/fentas/atty/commit/247a4f115b5358fbc1474dd2dd05e04be226290f))
* **osc133:** document the marker integration in architecture.md ([2e72d32](https://github.com/fentas/atty/commit/2e72d3239367291a8b6d2de3b9d1c4a17540d434))
* refresh Zig version references to 0.16 ([7aef0df](https://github.com/fentas/atty/commit/7aef0df0ee57551ec9cd4f4230ef942d0bba16ed))

## [0.2.0](https://github.com/fentas/atty/compare/v0.1.0...v0.2.0) (2026-05-13)


### Features

* **atuin:** delete_scope config — default .exact via fuzzy + ^…$ anchors ([166e534](https://github.com/fentas/atty/commit/166e5349769a5985c849869477af011f86bf6b83))
* **atuin:** provideGhostList + src/modules/_lib.zig shared helpers ([ad53afa](https://github.com/fentas/atty/commit/ad53afa56213c95b9e2577c746ce006b55069da5))
* **atuin:** record on Enter + manual sync via CLI ([b615bba](https://github.com/fentas/atty/commit/b615bba41cb1b21f1f8a192249637035853640c4))
* **config:** accept-ghost takes a list of keys + recover from uncertain ([2c00a82](https://github.com/fentas/atty/commit/2c00a82928831d74d4c36124d410ea2db88da2aa))
* **e2e:** per-scenario config + ghost_accept + statusbar_visible scenarios ([91245c2](https://github.com/fentas/atty/commit/91245c2b82d94aba47fd26a8b4cbe84338b36192))
* **get.sh:** symlink installed binary to source build dir ([ccde793](https://github.com/fentas/atty/commit/ccde793d1c8c18a50311c5d8e9f4e0c2f5bc7d4c))
* **ghost:** configurable overlay style via atty.ghost.Style ([43bf695](https://github.com/fentas/atty/commit/43bf695942e8b6aadc6a93913fd1020c35d3c170))
* **ghost:** multi-row pick list — provideGhostList + Ctrl+1..9 / Esc+1..9 ([774b71e](https://github.com/fentas/atty/commit/774b71ecacb1dba70ecea4674279d73349bc5599))
* **guardrail:** per-rule .mode — confirm / confirm_once / block / silent_block ([a690d18](https://github.com/fentas/atty/commit/a690d18e4a4aabbe7ddfb6dcb8a2ba66544462aa))
* **history:** add shell-native history module ([32f8eed](https://github.com/fentas/atty/commit/32f8eedfc7b67a0d68668c1188e81cc3bbdde782))
* **history:** Ctrl+Shift+D deletes matching line, status bar flashes ([5cb85e6](https://github.com/fentas/atty/commit/5cb85e61bf2e7165f0bd2c5274e3190f467bc1ba))
* **history:** shell-native history module ([6f0e816](https://github.com/fentas/atty/commit/6f0e816c3bba462cf6775725033fa34a9f30ee3b))
* **incognito:** Ctrl+Shift+I toggle + kitty kbd + status bar segment ([795170c](https://github.com/fentas/atty/commit/795170cbe495396984900d5730c996aa2710d2b0))
* **incognito:** muted-red style for the 🔒 segment ([d9d53f6](https://github.com/fentas/atty/commit/d9d53f61a9d8fc3633f33b79dd79449b16c7d759))
* **input-tracking:** DSR + 1-row grid emulator to recover line state from shell redraws ([3185e53](https://github.com/fentas/atty/commit/3185e53c07c864d2b546e40cabef975c0c9df5d1))
* **keymap:** Ctrl+Tab also accepts the ghost suggestion ([db435f6](https://github.com/fentas/atty/commit/db435f6f3a2c1e801a4df9bb2cfc9afa8824f079))
* **make:** add link/unlink targets for live dev binary ([94fe9c6](https://github.com/fentas/atty/commit/94fe9c6c52785d20c3b5038c39647bb199217ca9))
* **osc133:** auto-detected marker support, falls back to keystroke tracking ([9bc9e3b](https://github.com/fentas/atty/commit/9bc9e3b8c169228442056120df3ca97739df7ed4))
* **statusbar:** DECSTBM-reserved bottom row + module statusText hook ([4003649](https://github.com/fentas/atty/commit/4003649b4ee64ff050742379808858a610ef7544))
* **test:** add e2e framework with VT grid and visual snapshots ([f2f49b9](https://github.com/fentas/atty/commit/f2f49b912e32c573b9fe20df8da492d45512ab76))


### Bug Fixes

* **atuin:** implement deleteHistoryMatch — Ctrl+Shift+D now reaches atuin too ([b210d37](https://github.com/fentas/atty/commit/b210d377e20fef2de2ab3be549489164b8e0056e))
* **atuin:** newest match first, async sync, right-arrow accepts ghost ([fcaecda](https://github.com/fentas/atty/commit/fcaecdaf1360f222e0e8953a319b75fd60c3e8d6))
* **atuin:** suggestion_ttl_ms = 0 disables the timer; new default ([1341b42](https://github.com/fentas/atty/commit/1341b423b28c54b81616119c7133467da3edc041))
* **ghost_accept:** gather fresh suggestion, don't require ghost.visible ([6ed10c1](https://github.com/fentas/atty/commit/6ed10c1b29a018d4585234795564a2417236c3d4))
* **ghost_list:** dynamic activation, atuin-Ctrl+R style — no permanent dead space ([c1cdefb](https://github.com/fentas/atty/commit/c1cdefbaa52be0e2ded9b592da82abea9be09cdc))
* **ghost_list:** inflate statusbar reservation so shell pushes prompt above the list ([fe6d19e](https://github.com/fentas/atty/commit/fe6d19eae088f63ca29f80c67ffd152ce059e88d))
* **ghost_list:** paint with absolute CUP, anchored to bottom rows ([c56aee2](https://github.com/fentas/atty/commit/c56aee2bec132a7c9c072999bde5fdc23c0f1bc3))
* **ghost:** drop input-path renderGhost — was racing the shell echo ([eff5aa1](https://github.com/fentas/atty/commit/eff5aa11c94a4bb846e702900a08eea8112604f8))
* **guardrail:** banner never fired end-to-end + dispatchLineCommit ran past .swallow ([e72586a](https://github.com/fentas/atty/commit/e72586ac13d4afec2bae8d5dc232749a196a8536))
* **incognito:** three real bugs from manual testing ([d7bd349](https://github.com/fentas/atty/commit/d7bd3491241a9e91e64a57c4186b1fb1e1820c88))
* **input-tracking:** three race-condition fixes after live-test off-by-one ([77a127b](https://github.com/fentas/atty/commit/77a127b54cdae3d8dd4e1fa736b55eb96eb60295))
* **kitty:** re-enable disambiguate flag + intercept unmapped CSI-u ([e8d304b](https://github.com/fentas/atty/commit/e8d304bccf940377e6fe69e91d4402c5da966e71))
* **kitty:** translate CSI-u back to legacy bytes for Ctrl+letter, Esc, Tab, … ([90c4e5d](https://github.com/fentas/atty/commit/90c4e5db7120efbcda53a8d2277a9d8ad168b6d1))
* **statusbar:** activate parks cursor at (1,1), not in reserved area ([1808fbb](https://github.com/fentas/atty/commit/1808fbb8b8ecfabef7c268601cbd932091fe1507))
* **statusbar:** clear screen on activate for consistent fresh start ([accc89d](https://github.com/fentas/atty/commit/accc89d6fb1a05ce4321241e19935bd8614d1677))


### Refactor

* **config:** every subsystem is a struct (style guide commitment) ([74ae7af](https://github.com/fentas/atty/commit/74ae7af90c55efc9734a3542e9d7e1b2c8acde56))
* **config:** generalise key bindings as { bytes, action } pairs ([6ac581b](https://github.com/fentas/atty/commit/6ac581b14255c3b40ed06dc602135d1e01b26484))
* **config:** group statusbar fields into atty.StatusBar struct ([d0d0f15](https://github.com/fentas/atty/commit/d0d0f15b9307871dcbd45cdfd584d7eebfb375c2))
* **config:** split user config from defaults (dwm-style) ([734da31](https://github.com/fentas/atty/commit/734da31a047b45e89947fae64ee0c9d11a3ba992))
* **defaults:** swap atuin → history in the default tuple ([18be9bc](https://github.com/fentas/atty/commit/18be9bc2a6b387ff4a18ecf329e8e5faebc88aa5))
* **ghost_list:** sweep dead anchor/RenderMode plumbing + docs ([425bbbd](https://github.com/fentas/atty/commit/425bbbd1fcfba4a3f72bd6d802a73fd79eb91798))
* **keymap:** extract keymap.match() + tests, use from proxy ([f8926fb](https://github.com/fentas/atty/commit/f8926fb469ce593373cddc9e6784eaad4048b0ce))
* **main:** extract args.zig parser + tests (7 cases) ([8037b1e](https://github.com/fentas/atty/commit/8037b1e7a311ec220e08d82ff96d33cf76225388))
* **proxy:** extract status_text.zig — pure segment assembly + tests ([98c02db](https://github.com/fentas/atty/commit/98c02db538b9da01c6805dc5b5c15f226d3851cd))
* **proxy:** hoist keymap import + name kitty kbd push/pop bytes ([0e416a4](https://github.com/fentas/atty/commit/0e416a4d76f3cf51f11af201ce0c2af7738dfa6c))
* **style:** promote Style to a first-class atty.Style with presets ([d2898f7](https://github.com/fentas/atty/commit/d2898f7a3ad2e2029ed54be939a716cda555038b))


### Documentation

* add CLAUDE.md for fresh-agent orientation ([86d5f28](https://github.com/fentas/atty/commit/86d5f280e4b84aa6bf17f8cf2c3bad137d91a1bf))
* clarify gatherGhostText priority + atuin/history race window ([8347363](https://github.com/fentas/atty/commit/83473632844d616b2ec85d3b9d215e95c8668361))
* keymap, atuin record/sync, onLineCommit, e2e ([247a4f1](https://github.com/fentas/atty/commit/247a4f115b5358fbc1474dd2dd05e04be226290f))
* **osc133:** document the marker integration in architecture.md ([2e72d32](https://github.com/fentas/atty/commit/2e72d3239367291a8b6d2de3b9d1c4a17540d434))
* refresh Zig version references to 0.16 ([7aef0df](https://github.com/fentas/atty/commit/7aef0df0ee57551ec9cd4f4230ef942d0bba16ed))

## 0.1.0

Initial public scaffold.

### Features

- PTY proxy with low-level POSIX setup (`posix_openpt`/`grantpt`/`unlockpt`),
  termios raw-mode RAII guard, SIGWINCH/SIGCHLD propagation via
  self-pipe.
- Comptime-composed module framework (`Dispatcher(modules)`) with
  `onInput` / `onOutput` / `provideGhostText` / `onTick` hooks. Missing
  hooks are statically eliminated from the binary via `@hasDecl`.
- **Atuin** module: async worker thread + one-slot mailbox; subprocess
  backend via `atuin search`; socket backend stub; TTL-driven
  suggestion expiry.
- **Guardrail** module: substring/prefix rule engine; swallow-on-Enter
  + confirm-on-Enter UX; configurable rule list.
- Ghost-text overlay state machine (DECSC/DECRC + dim/italic SGR), with
  idempotent re-render to avoid flicker under tick refresh.
- Best-effort line-state tracking with `uncertain` flag for unmodelled
  input sequences.
- Single-file `src/config.zig` is the Suckless-style user-editable
  config. `-Dconfig=path` flag (or `make CONFIG=…`) for out-of-tree
  configs.

### Documentation

- README + GitHub Pages site at <https://atty.sh> with
  terminal-aesthetic Jekyll layout.
- `docs/architecture.md`, `docs/modules.md`, `docs/providers.md`.

### Build

- `build.zig` with `run`, `test`, `itest` targets; `-Doptimize` /
  `-Dtarget` / `-Dconfig`.
- Multi-stage `Dockerfile` (Debian builder → minimal runtime).
- `Makefile` for the developer UX (`build`, `test`, `install`,
  `docker`, `docker-binary`).
- `scripts/install.sh` one-shot Docker → `./dist/atty`.

### CI

- `ci.yml`: `zig fmt --check`, build, unit + integration tests,
  end-to-end smoke, docker-builder smoke, binary artifact upload.
- `pages.yml`: Jekyll → GitHub Pages on push to main.
