# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Documentation: split `CONTRIBUTING.md` out of `README.md` so the README focuses on what the bridge does and how to run it. Architecture diagrams, local development setup, stack list, and the contribution conventions live in `CONTRIBUTING.md`. Redundant License section dropped from the README; the badge and `LICENSE` file remain authoritative.

## [1.11.2] - 2026-04-25

### Fixed

- CI `version-bump-check` job now also exempts pushes whose every non-merge commit in the diff range was authored by dependabot. The original actor check fired only on dependabot's PR-branch runs, not on the merge-to-main run (where `github.actor` becomes the merger).

### Changed

- Dependencies: rubocop family (rubocop, rubocop-minitest, rubocop-performance, rubocop-thread_safety) bumped via dependabot.
- Dependencies: minitest bumped from 5.27.0 to 6.0.5 via dependabot.
- Dependencies: npm frontend group bumped via dependabot.

## [1.11.1] - 2026-04-25

### Added

- `SECURITY.md` describing the private-disclosure channel, supported versions, and in-scope and out-of-scope categories.
- `CHANGELOG.md` (this file), seeded retroactively from `VERSION` bump commits.
- `.github/dependabot.yml` covering bundler, npm, github-actions, and docker ecosystems with grouped patch and minor updates.
- `.github/assets/screenshots/` directory with a README documenting the expected screenshot filenames and capture conventions. Screenshots themselves land as a follow-up.
- CI: `build-and-push` now pushes a matching `v<version>` git tag and creates a GitHub Release whose body is sourced from this changelog.
- CI: new `version-bump-check` job enforces the `VERSION` bump rule on GitHub, with carve-outs for dependabot authorship and docs-only diffs.

### Changed

- `.githooks/pre-push` no longer blocks docs-only pushes (changes limited to `*.md` or `LICENSE`).
- `README.md` Contributing section documents the changelog-bump convention and the new docs-only and dependabot exemptions.
- `CLAUDE.md` light public-tone pass for the open-source launch.

## [1.11.0] - 2026-04-24

### Added

- Settings: validate snowflake IDs on save and rebuild the app when configuration changes.

## [1.10.7] - 2026-04-23

### Changed

- Discord: surface HTTP 400 field errors in the raised exception message so failures are diagnosable from the journal.

## [1.10.6] - 2026-04-23

### Changed

- Views: break the Full-resync blurb into a three-stage stepper.

## [1.10.5] - 2026-04-23

### Changed

- Docker: split final-stage `COPY` so the icon layer caches across builds.

## [1.10.4] - 2026-04-23

### Changed

- Views: extract the empty-state partial and DRY up status-pill sizing.

## [1.10.3] - 2026-04-23

### Changed

- Guide: ship only the 1024x1024 bot icon.

## [1.10.2] - 2026-04-23

### Fixed

- Guide: ship the bot-icon PNGs and wire the probe card to POST.

## [1.10.1] - 2026-04-23

### Changed

- Guide: revise the bot-setup walkthrough and retire the old markdown mirror.

## [1.10.0] - 2026-04-23

### Added

- Interactive Discord bot-setup walkthrough at `/guide/bot-setup`, with live tracking of missing config and a generated invite URL.

## [1.9.4] - 2026-04-23

### Changed

- Login: drop the Tailscale mention from the intro paragraph.

## [1.9.3] - 2026-04-23

### Changed

- Actions panel: reorder Safe and Routine sections by logical flow.

## [1.9.2] - 2026-04-23

### Added

- Settings: confirm auto-provisioning with a result summary.

## [1.9.1] - 2026-04-23

### Fixed

- Settings: keep the Save button visible after an auto-provision failure.

## [1.9.0] - 2026-04-23

### Added

- Settings: auto-provision system channels under a second category.

## [1.8.2] - 2026-04-23

### Changed

- Documentation: record read-receipt and counter-sync quirks in `CLAUDE.md`.

## [1.8.1] - 2026-04-23

### Removed

- Dashboard: drop the Reddit unread counter tile (the underlying counters are only available on initial sync).

## [1.8.0] - 2026-04-23

### Added

- Matrix: send read markers (`m.fully_read` plus `m.read` plus `m.read.private`) so Reddit's unread count clears.

## [1.7.1] - 2026-04-23

### Added

- Auth: enrich the Current State tile with a Reddit identity chip.

## [1.7.0] - 2026-04-23

### Added

- Settings: float the Save button behind a dirty-state dock.

## [1.6.5] - 2026-04-23

### Changed

- Tests: align operational-log pagination tests with the 10-per-page default.

## [1.6.4] - 2026-04-23

### Changed

- Events: cap the operational log ring buffer at 250 rows.

## [1.6.3] - 2026-04-23

### Fixed

- Events: default operational log page size to 10.

## [1.6.2] - 2026-04-23

### Removed

- Discord: drop the HTTP interactions endpoint and the public-key setting.

## [1.6.1] - 2026-04-23

### Fixed

- Web: drop the dead setup-guide link on `/settings`.

## [1.6.0] - 2026-04-23

### Changed

- Dashboard: rebalance the bridge-thread and matrix-auth tiles.

## [1.5.0] - 2026-04-23

### Added

- Events: paginate the operational log.

## [1.4.5] - 2026-04-23

### Fixed

- Actions panel: fold the pause control into the sync-loop card.

## [1.4.4] - 2026-04-23

### Changed

- Docker: move the user-setup `RUN` back to the end of the final stage.

## [1.4.3] - 2026-04-23

### Fixed

- Web: drop the max-width on the rooms-section note so descriptions fill the header width.

## [1.4.2] - 2026-04-23

### Changed

- Replace em dashes with hyphens in user-facing text.

## [1.4.1] - 2026-04-23

### Fixed

- Web: widen the rooms-section note so archived and hidden descriptions stop wrapping early.

## [1.4.0] - 2026-04-23

### Added

- Actions: let the operator pause and resume the sync loop.

## [1.3.1] - 2026-04-23

### Fixed

- Web: redirect after every POST so a reload stops re-submitting the form.

## [1.3.0] - 2026-04-23

### Added

- Dashboard: break the rooms tile down by active, archived, and hidden.

## [1.2.3] - 2026-04-23

### Fixed

- Docker: drop the bundle cache mount that collided with cleanup.

## [1.2.2] - 2026-04-23

### Fixed

- Docker: un-exclude build-time inputs from `.dockerignore`.

## [1.2.1] - 2026-04-23

### Changed

- Repackage release. No functional changes.

## [1.2.0] - 2026-04-23

### Added

- Layout: single-line navigation that fits all labels inline at wide widths and collapses to a burger panel below 1200px.

## [1.1.7] - 2026-04-23

### Fixed

- Layout: lift the primary nav out of the flex-wrap row so it never overflows.

## [1.1.6] - 2026-04-23

### Fixed

- Auth: unbreak the "how to grab" list by removing grid-on-li overlap.

## [1.1.5] - 2026-04-23

### Fixed

- Layout: drop the primary nav to its own scroll-strip row so it collapses cleanly at every width.

## [1.1.4] - 2026-04-23

### Changed

- Auth: rebuild the "how to grab" list as an explicit grid.

## [1.1.3] - 2026-04-23

### Changed

- Auth: reflow browser cookie paths as an aligned reference grid.

## [1.1.2] - 2026-04-23

### Changed

- Auth: split the `reddit_session` cookie steps per browser.

## [1.1.1] - 2026-04-23

### Fixed

- Auth: switch the JWT bookmarklet to `ClipboardItem(promise)` for iOS Safari.

## [1.1.0] - 2026-04-23

### Added

- Auth: no-DevTools token flows (single `reddit_session` field plus a JWT bookmarklet).

## [1.0.17] - 2026-04-22

### Fixed

- Supervisor: ride out transient network errors instead of paging.

## [1.0.16] - 2026-04-21

### Changed

- CI: disable provenance and SBOM attestations.

## [1.0.15] - 2026-04-21

### Changed

- Repackage release to repopulate the registry.

## [1.0.14] - 2026-04-21

### Changed

- Repository: prep for open-sourcing (LICENSE, scrub personal IDs).

## [1.0.13] - 2026-04-21

### Changed

- Gateway: silence socket-error warnings on routine connection drops.

## [1.0.12] - 2026-04-19

### Changed

- Gateway: silence routine reconnect logs.

## [1.0.11] - 2026-04-19

### Changed

- Journal: tighten the bridge-online line by dropping the SHA, ref, and Matrix user.

## [1.0.10] - 2026-04-19

### Changed

- CI: set `MINITEST_WORKERS=4` so forked tests use all four vCPUs.

## [1.0.9] - 2026-04-19

### Changed

- Tests: drop bcrypt cost to `MIN_COST` in `test_helper`.

## [1.0.8] - 2026-04-19

### Changed

- CI and tests: switch to `npm ci` and forked parallel minitest; revert build cache mode.

## [1.0.7] - 2026-04-19

### Changed

- CI release: drop QEMU and switch the build cache to `mode=min`.

## [1.0.6] - 2026-04-19

### Changed

- Logomark: bar layout with a hairline rule and an ember version.

## [1.0.5] - 2026-04-19

### Changed

- Guides: align markdown tables and drop a trailing space in a code span.

## [1.0.4] - 2026-04-19

### Changed

- VS Code: route CSS through the tailwindcss language mode.

## [1.0.3] - 2026-04-19

### Changed

- Events: canonical width utilities on the events table headers.

## [1.0.2] - 2026-04-19

### Changed

- UI: canonicalize Tailwind utilities and logomark spacing; patch lint.

## [1.0.0] - 2026-04-19

### Added

- Initial release: bidirectional Reddit Chat to Discord bridge with per-conversation `#dm-*` channels, webhook-backed persona rewrites, message-request gating, archive and end-chat lifecycles, idempotent inbound and outbound dedup, auto Matrix JWT refresh, in-app admin web UI with first-run setup wizard, and Discord slash command surface.
- `VERSION` file plus `.githooks/pre-push` bump gate plus version surfacing in the UI logomark.

[Unreleased]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.11.2...HEAD
[1.11.2]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.11.1...v1.11.2
[1.11.1]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.11.0...v1.11.1
[1.11.0]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.10.7...v1.11.0
[1.10.7]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.10.6...v1.10.7
[1.10.6]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.10.5...v1.10.6
[1.10.5]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.10.4...v1.10.5
[1.10.4]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.10.3...v1.10.4
[1.10.3]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.10.2...v1.10.3
[1.10.2]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.10.1...v1.10.2
[1.10.1]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.10.0...v1.10.1
[1.10.0]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.9.4...v1.10.0
[1.9.4]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.9.3...v1.9.4
[1.9.3]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.9.2...v1.9.3
[1.9.2]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.9.1...v1.9.2
[1.9.1]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.9.0...v1.9.1
[1.9.0]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.8.2...v1.9.0
[1.8.2]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.8.1...v1.8.2
[1.8.1]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.8.0...v1.8.1
[1.8.0]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.7.1...v1.8.0
[1.7.1]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.7.0...v1.7.1
[1.7.0]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.6.5...v1.7.0
[1.6.5]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.6.4...v1.6.5
[1.6.4]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.6.3...v1.6.4
[1.6.3]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.6.2...v1.6.3
[1.6.2]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.6.1...v1.6.2
[1.6.1]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.6.0...v1.6.1
[1.6.0]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.5.0...v1.6.0
[1.5.0]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.4.5...v1.5.0
[1.4.5]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.4.4...v1.4.5
[1.4.4]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.4.3...v1.4.4
[1.4.3]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.4.2...v1.4.3
[1.4.2]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.4.1...v1.4.2
[1.4.1]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.4.0...v1.4.1
[1.4.0]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.3.1...v1.4.0
[1.3.1]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.3.0...v1.3.1
[1.3.0]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.2.3...v1.3.0
[1.2.3]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.2.2...v1.2.3
[1.2.2]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.2.1...v1.2.2
[1.2.1]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.1.7...v1.2.0
[1.1.7]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.1.6...v1.1.7
[1.1.6]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.1.5...v1.1.6
[1.1.5]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.1.4...v1.1.5
[1.1.4]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.1.3...v1.1.4
[1.1.3]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.1.2...v1.1.3
[1.1.2]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.1.1...v1.1.2
[1.1.1]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.0.17...v1.1.0
[1.0.17]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.0.16...v1.0.17
[1.0.16]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.0.15...v1.0.16
[1.0.15]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.0.14...v1.0.15
[1.0.14]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.0.13...v1.0.14
[1.0.13]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.0.12...v1.0.13
[1.0.12]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.0.11...v1.0.12
[1.0.11]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.0.10...v1.0.11
[1.0.10]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.0.9...v1.0.10
[1.0.9]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.0.8...v1.0.9
[1.0.8]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.0.7...v1.0.8
[1.0.7]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.0.6...v1.0.7
[1.0.6]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.0.5...v1.0.6
[1.0.5]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.0.4...v1.0.5
[1.0.4]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.0.3...v1.0.4
[1.0.3]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.0.2...v1.0.3
[1.0.2]: https://github.com/mmenanno/reddit_chat_bridge/compare/v1.0.0...v1.0.2
[1.0.0]: https://github.com/mmenanno/reddit_chat_bridge/releases/tag/v1.0.0
