# Woven Roadmap — Installer + Gem Factory + Gems Server

Weaves the design discussion (`GEM-FACTORY-vision.md`), the installer audit
(`AUDIT-ruby4lich5-installer.md`), and the gem-factory audit
(`AUDIT-ruby4-bundled-gems-suite.md`) into one build order.

Tags: **[D]** discussion · **[IA]** installer audit · **[GA]** gem-factory audit.

## Sequencing principles

1. **The glib2 beta is releasable on demand — not a gate.** A beta cuts as a Release
   from the existing artifact any time, and re-cutting after a patch change is
   independent of the factory work. The only real constraint is keeping a stable,
   distinctly-named "cut-the-installer" workflow so a glib2 patch + re-cut stays
   isolated from the evolving factory workflows — not freezing other work.
2. **Decide before build.** The four [OPEN] decisions gate dependent work; making them
   first prevents building against a mechanism that then changes.
3. **Don't touch twice.** Explicitly: don't rework the installer-assembly to pull a
   release *until* the server flavor + topology are fixed; don't build the index flat
   (matrix from day one); don't hand-patch version literals in the monolithic factory
   if the per-gem redesign deletes them anyway.

## Phase 0 — Urgent (now)

- **[IA] Node-24 artifact fix** — `upload`/`download-artifact` are Node-20; force-migration
  **June 16**. Hard external deadline regardless of everything else; surgical change to the
  installer + factory workflows.
- **[D] Workflow naming for isolation** — keep a stable, distinctly-named installer/beta-cut
  workflow separate from the evolving factory workflows, so a glib2 patch + re-cut beta never
  entangles factory work. (The beta is releasable on demand; not a blocker.)

## Phase 1 — Foundational decisions (gate everything; the sleep-on-it set)

Decisions, not code — but they unblock Phases 2–4:
- **[D] Gems-server flavor** — (a) release-asset store / (b) static gem index / both.
  *Confirm against the existing Lich loader contract first.*
- **[D] Index schema** — Ruby ABI × platform matrix. Lock the layout before first publish.
- **[D] Repo topology / permanent home** — decides cross-repo auth (build plumbing once).
- **[D] Curation manifest + provenance** — pinning/update policy; checksums from the start.

## Phase 2 — Front door (per-gem factory)

Generalize today's fixed monolithic GTK build into "build any named gem":
- name (+version) → fetch RubyGems → **tri-state classify** → build binary/pass-through pure
  → resolve + build **closure** → smoke → publish (per Phase-1 flavor).
- Fold in the gem-audit items the redesign *touches anyway* (fix by design, not patch):
  - **[GA §2.4/2.5]** hardcoded version literals (cairo `1.18.4`, `=4.3.x`) + bump fragility
    — the per-gem model parameterizes these away.
  - **[GA §2.2]** two DLL mechanisms — consolidate while generalizing.
  - **[GA §2.1]** dead dependency-aware dedup in `extract-dll-dependencies.rb` — fix or delete.

## Phase 3 — Gems server / index

- Stand up the server repo (per Phase-1 topology).
- Publish mechanism = the **durable rail** that retires the hand-made test prerelease.
  - **[IA]** gem source today is `bundle-20260614-test`; replace with real published releases.
  - **[IA]** kills the brittle "newest release incl. prerelease" heuristic (selection by manifest).
- Curation manifest + checksums.

## Phase 4 — Installer assembly rework (consume the index)

- Repoint the installer workflow at the curated set from the gems server — **done once**
  against the final mechanism (avoids the touch-twice). **[IA]**
- **[GA §2.11]** redundant default/bundled gems (`set`/`rexml`/`matrix`; decide `webrick`)
  — curation excludes them; the index ships only what the base Ruby lacks.

## Phase 5 — Hardening / polish

- **[IA]** DevKit freeze → finish-page `postinstall nowait` visible console (RubyInstaller's pattern).
- **[IA]** Code-signing the installer.
- **[GA 1.2]** gio2 ~100-line DLL-noise corral (parked; now unblocked).
- **[IA]** `.lic`-from-master pinning decision.
- **[GA §2.12]** one-line note on the expected duplicate installs.
- **[GA §2.9]** deepen the smoke (real clean-environment check).

## Phase 6 — Multi-version variants (4.1.x)

- **[IA]** generalize the ABI guard. Additive, *because* the Phase-1 matrix index already
  accommodates ruby410 × platform — no index redo.

## Phase 7 — Docs / governance

- **[GA Part 3]** consumer load-order contract; build/release runbook; ADR.
- Keep `GEM-FACTORY-vision.md` current as [OPEN] decisions land.

## Cross-reference — every audit finding has a home

| Finding | Source | Phase |
|---|---|---|
| Node-24 artifact actions | IA | 0 |
| Gem source = test prerelease; "newest" heuristic | IA | 3 |
| ABI guard hardcoded 4.0 | IA | 6 |
| Installer unsigned | IA | 5 |
| `.lic` from master | IA | 5 |
| DevKit freeze | IA | 5 |
| `set`/`webrick` redundant | IA/GA §2.11 | 4 |
| Dead DLL dedup (§2.1) | GA | 2 |
| Two DLL mechanisms (§2.2) | GA | 2 |
| Version literals / bump fragility (§2.4/2.5) | GA | 2 |
| Duplicate installs note (§2.12) | GA | 5 |
| Smoke depth (§2.9) | GA | 5 |
| gio2 DLL-noise corral (1.2) | GA | 5 |
| Docs/governance (Part 3) | GA | 7 |
| Gem-server flavor / index schema / topology / curation | D | 1 |
| Front door (classify/build/publish) | D | 2 |
| Gems server | D | 3 |
| Installer assembly rework | D | 4 |

## The critical path (shortest line to the things that matter)

`Phase 0 (Node-24)` is the only hard-dated item. The glib2 beta cuts on demand from
the existing artifact and is **not** on the critical path. The spine is
`Phase 1 decisions` → `Phase 2 front door` → `Phase 3 server` → `Phase 4 assembly`;
Phases 5–7 are parallelizable polish once the spine stands.
