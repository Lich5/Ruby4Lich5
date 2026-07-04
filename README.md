# Ruby4Lich5

The installer factory for [Lich5](https://github.com/elanthia-online/lich-5). Ruby4Lich5
exists to produce a Windows installer (`Ruby4Lich5.exe`) that bakes together a specific
Ruby version, the latest Lich, and a curated set of precompiled (binary) gems — so
consumers get a fast, single-app install with no build tools required, while power users
can still opt in to a full MSYS2/RIDK toolchain afterward.

## Status

Phase 1 (foundational decisions) is complete as of 2026-07 — see `docs/DECISIONS.md`.
Phase 2 (the generalized front door) has not started; nothing beyond the inherited seed
workflow exists yet. This README is deliberately a living document, not a spec frozen
in stone.

## What this factory does

- Produces a `.exe` installer for Windows that bakes in:
  - the latest released version of Lich
  - a specific, pinned Ruby version
  - precompiled/binary gems (cuts installer size and install time vs. compiling on the
    user's machine)
- Supports installing RIDK (MSYS2 toolchain) as an opt-in, post-install step — without
  shipping MSYS2 in the base installer
- Maintains a growing, curated list of precompiled binary gems available to the Lich
  ecosystem, versioned per platform (each gem internally bundles every currently-
  supported Ruby ABI, dispatched at load time — see `docs/DECISIONS.md` §2)
- Publishes releases publicly from a single repo — no cross-repo write credential is
  needed to publish; consumers read via plain, public, unauthenticated requests

## Architecture: three components

```
  FRONT DOOR              GEMS SERVER               INSTALLER ASSEMBLY
  (per-gem, on demand)    (accumulating repo of      (periodic snapshot)
                           released gems + manifest)
  name a gem (+version)                              current curated set
    -> fetch RubyGems           release assets              + Ruby
    -> classify                 + curation manifest         + Lich
    -> build binary/pass-through (this same repo)            -> installer
    -> resolve + build closure
    -> smoke
    -> publish
```

- **Front door** — dispatch with a gem name (+ version). Fetch from RubyGems, classify
  (pure / native-self-contained / native-needs-system-lib), build the binary gem (or pass
  through pure gems), resolve and build the gem's full dependency closure, smoke test,
  and publish. This generalizes the fixed monolithic GTK3-suite build the prototype
  proved into "build any named gem."
- **Gems server** — holds released gems (as GitHub Release assets, no separate index)
  plus a curation manifest of the pinned set (`gem x platform -> version/tag/checksum`).
  Non-central, ours to own, and lives in this same repo (see `docs/DECISIONS.md` §1-3).
- **Installer assembly** — periodically gathers the current curated set + Ruby + Lich
  files and builds the installer. Most of the time this reuses a cached, previously-baked
  Ruby+gems working directory rather than rebuilding it (see `docs/DECISIONS.md` §6).

## What the prototype already proved

The `lich5-gtk3-gems` prototype (and the resulting test installer built from
`lich-5`) validated six load-bearing assumptions this factory builds on:

1. We can patch a problematic upstream gem we don't own (the glib2 GC/property patch).
2. We can compile binary (native) gems and distribute them.
3. A build-on-the-user's-machine installer is the wrong call (slow, two-app, freeze) —
   replaced by the **baked** model (compiled ahead of time, shipped ready to run).
4. We don't have to ship MSYS2/build tools for the runtime to work — binary gems vendor
   their own DLLs; non-DevKit Ruby is enough.
5. We can bifurcate consumer vs. power-user/developer and serve both (opt-in RIDK).
6. We can produce either a Lich-bundled installer or a standalone one.

The compile -> DLL-vendor -> smoke *engine* exists (inherited into
`.github/workflows/ruby4-bundled-gems-suite.yml`, not yet generalized). What's still
missing is the front door and the gems server themselves.

## Platform scope

Windows first, deliberately. The eventual plan includes Linux (various distros) and
macOS install scripts and binary gems, but only after the front door, factory, Ruby
build, gem matrix, gems package, and releases are solid for Windows. Nothing here should
be designed Windows-only in a way that forecloses that: the gem/index schema is
`Ruby ABI x platform` from the start, so Linux/macOS become additional matrix cells
later rather than a redesign.

## Related repositories

- **`elanthia-online/lich-5`** — true upstream Lich. The customer-facing project this
  factory serves. The finished installer-assembly CI is expected to eventually live
  here (or be consumed from here), once the design settles.
- **`Lich5/lich-5`** — a plain synced-from-upstream repo (not a linked GitHub fork, by
  design — see below), used as a disposable CI sandbox for iterating on installer-
  assembly workflow design without cluttering upstream's history. Tracks
  `elanthia-online/lich-5` via a plain `upstream` remote, synced manually. When the CI
  design is settled, the finished workflow(s) get PR'd to `elanthia-online/lich-5` as a
  small number of clean commits (a fresh branch off current upstream with the finished
  files copied in — not the sandbox's iteration history). This repo is then archived and
  made private.
  - It is deliberately *not* a GitHub-linked fork: forks default "Compare & pull request"
    to targeting the parent as the base repo, which risks a sandbox PR accidentally
    opening against upstream. A plain repo with a manual `upstream` remote avoids that
    failure mode entirely.
- **`Lich5/lich5-gtk3-gems`** — the prototype gem-build engine this factory generalizes
  from. Expected to be superseded once the front door exists.
- **`Lich5/lich-5-installer-prototype-202606`** — the original `Lich5/lich-5` fork,
  renamed, archived, and made private once the plain sandbox repo above replaced it.
  Holds the installer-prototype CI history (including `Ruby4Lich5-installer.iss`, the
  actual Inno Setup script) for reference, not for further work.

## Org home

Currently under the `Lich5` org. Expected to transition to `elanthia-online` around
January 2027, timed to the anticipated release/testing of Ruby 4.1.0.

## Roadmap phases (see [`docs/ROADMAP-woven-plan.md`](docs/ROADMAP-woven-plan.md) / [`docs/GEM-FACTORY-vision.md`](docs/GEM-FACTORY-vision.md))

0. Urgent/time-bound fixes (e.g. Actions Node-version migrations) — handled as they come.
1. **Foundational decisions** (gate everything else — see Phase 1 decisions below).
2. Front door: generalize the fixed suite build into "build any named gem."
3. Gems server / index: durable publish mechanism, retiring the hand-made test
   prerelease.
4. Installer assembly rework: consume the curated index instead of ad hoc bundles.
5. Hardening/polish (code signing, deeper smoke tests, DLL-noise cleanup).
6. Multi-version variants (Ruby 4.1.x) — additive if the Phase 1 matrix index is
   designed right the first time.
7. Docs/governance (load-order contract, build/release runbook, ADRs).

## Phase 1 decisions (resolved — see [`docs/DECISIONS.md`](docs/DECISIONS.md) for the full record)

- **Gems-server flavor:** release-asset store only. No RubyGems-compatible static index.
- **Index schema:** `gem x platform`, no Ruby ABI in tag or asset naming — each gem is a
  fat gem bundling every supported ABI internally (the Nokogiri pattern), dispatched at
  load time by the gem's own code.
- **Repo topology:** one repo. Ruby4Lich5 is both the front door and the gems server.
- **Curation, pinning, and authorization:** manual dispatch only, EO-Admin-gated
  (mirrors `elanthia-online/lich-5`'s own PR-review pattern, minus Release Please — gem
  versions are upstream-supplied, not commit-derived). Installer versioning is owned by
  Ruby4Lich5 itself, not by `lich-5`. Authorization needs a small refinement: scope
  Ruby4Lich5's write access to a Lich5-org team mirroring EO's Admin team, rather than
  relying on the Lich5 org's current write-by-default for all members.
- **Release flow with `elanthia-online/lich-5`:** EO publishes 4 archive artifacts
  (tarball/zip x repo/app) and retires its existing embedded installer-build job.
  Ruby4Lich5 consumes the app archive, publishes its own gem/bundle/installer releases,
  and opens a PR (not a direct cross-repo asset upload) adding version/checksum/link
  metadata back onto the EO release. Fully human-coordinated, no automated hand-off.
- **Build caching:** the assembled Ruby+gems working directory (not Ruby alone) is
  cached as one unit and reused for Lich-app-only releases — the common case.
- **Test vs. production installers:** disposable, manifest-untouched one-off builds for
  EO/power-user gem evaluation, using the installer's existing Ruby-only component type.
  Promotion to production always goes through the same approval chain.
- **Automation philosophy:** automation may only fire on an authorized admin's own
  directly-controlled action, never on a lower-privileged or external signal.

## License

BSD 3-Clause, matching `lich-5` and the wider Lich5/Elanthia Online ecosystem.
