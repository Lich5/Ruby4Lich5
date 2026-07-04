# Phase 1 Decisions

Record of the foundational decisions from `ROADMAP-woven-plan.md` Phase 1, worked out
collaboratively in 2026-07. These gate Phase 2 (front door) and beyond — see the roadmap
for how they fit into the overall build order.

## 1. Gems-server flavor: release-asset store only

No RubyGems-compatible static index (no GitHub Pages compact index). Gems are published
as GitHub Release assets on Ruby4Lich5 itself.

This was validated against a concrete future requirement: an in-game
`;lich5-update --gem=<name>` command that fetches and installs the latest matching gem
during an active Lich session. A static index would have made sense if that command
needed to speak RubyGems' own `gem install --source` protocol — but it's a bespoke Lich
command we fully control, so it doesn't need to. GitHub Releases already give a stable,
predictable download URL per tag; no compact-index infrastructure is needed.

## 2. Index schema: `gem × platform`, no ABI in the naming

Neither the release tag nor the asset filename needs to encode the Ruby ABI. Each
published gem is a **fat gem**: one package per platform, bundling precompiled binaries
for every currently-supported Ruby ABI under `lib/<gem>/<abi>/`, with a
`RUBY_VERSION`-based `require_relative` dispatch at load time — the pattern Nokogiri
already uses in production (verified directly: the installed `nokogiri-1.19.2-arm64-darwin`
gem has `lib/nokogiri/{3.2,3.3,3.4,4.0}/nokogiri.bundle`, selected by
`lib/nokogiri/extension.rb` parsing `RUBY_VERSION`).

Consequence: one release/tag per gem-version (e.g. `gtk3-v3.5.6`), with per-platform
assets (e.g. `gtk3-3.5.6-x64mingw-ucrt.gem`). The curation manifest is
`gem × platform -> {version/tag, asset, checksum}` — no ABI key.

**Build-discipline consequence:** whenever the supported-ABI set changes (adding Ruby
4.1, eventually dropping 4.0), every currently-tracked gem must be rebuilt to re-embed
*all* still-supported ABIs' binaries together, not just the new one — otherwise a user
on an older, still-supported ABI silently loses the gem the moment "latest" moves.

**Resolution mechanism** (for finding "latest," e.g. for the in-game update command):
reuse the pattern already proven in `elanthia-online/lich-5`'s own
`lib/common/update/` — try `/releases/latest` first, fall back to enumerating releases
and comparing via `Gem::Version` when there's more than one concurrent release lineage
in a repo (exactly our situation: one lineage per gem, not one for the whole repo). The
curation manifest exists specifically so this never has to enumerate/paginate the full
releases list — one fetch gets the current pin.

## 3. Repo topology: one repo, not three

Ruby4Lich5 is both the front door *and* the gems server — not a separate repo. Same-repo
means the front door's own default Actions token can publish releases with no cross-repo
write credential needed. The read side (installer-assembly, or a future in-game update)
is a public, unauthenticated fetch regardless of topology, so splitting the repos would
only have added cross-repo auth plumbing for no benefit.

Installer-assembly's long-term home is `elanthia-online/lich-5`'s own existing release
CI (see §5) — that's a *read* relationship (it consumes Ruby4Lich5's releases), not
something that changes this topology call.

## 4. Curation, pinning, and authorization

**Trigger:** manual dispatch only. No nightly builds, no auto-rebuild the moment an
upstream gem publishes — a human looks at what changed before a rebuild happens. Matches
the front door's "on demand" design from the vision doc.

**Mechanism to mirror:** `elanthia-online/lich-5`'s `prepare-stable-release.yaml`
structurally (guard → checkpoint/backup tag → open a PR for human review → separate
workflow finalizes on merge → real GitHub Release stays draft until a human publishes)
— **minus the Release Please step itself**. Release Please's job is deriving a semver
bump from *our own* Conventional Commits; gem versions aren't something we compute, they're
upstream-supplied inputs we choose to pin. The PR's diff is the curation-manifest change
itself (gem X: version A → B, asset, checksum) — arguably a more meaningful review
artifact than a generated changelog would be here.

**Installer versioning is owned by Ruby4Lich5, not by `lich-5`.** Verified directly: the
prototype's own version-resolution step and `elanthia-online/lich-5`'s live
`release-please-config.json` both currently derive the installer's version from Lich's
*own* tracked version (one Release Please package, `.`, manifest value `5.18.0`,
`extra-files` stamping that same value into `R4LGTK3.iss`). That conflates two things
that can now change independently: `lich-5`'s Release Please only ever sees `lich-5`'s
commit history, and has no visibility into a Ruby4Lich5-side gem rebuild or Ruby ABI
addition. Version identity for the installer has to be decided where the facts about its
contents actually live — Ruby4Lich5 — regardless of which org either repo sits in.

**Authorization:** must be an EO Admin (the same 5 people who hold `admin`-level access
on `elanthia-online/lich-5` via the "EO Admins" team: sandersch, ondreian, mrhoribu,
OSXLich-Doug, MahtraDR). EO Maintainers (a broader group, working mostly on scripts and
core Lich logic) are not part of this specific process. `Lich5` org's
`default_repository_permission` is currently `write`, meaning every Lich5-org member
(including two — AndreasWelch, Nisugi — who aren't EO members) has write access to
Ruby4Lich5 by default today. **Refinement needed:** a Lich5-org team mirroring EO Admins'
membership, with Ruby4Lich5's access scoped to that team (overriding the org-wide
default for this one repo) plus branch protection requiring that team's review.

**Promotion always requires the same approval chain**, no exceptions — including
promoting a beta-tested gem to production (see §7). No automation ever fires on a
signal from outside an authorized admin's direct control (see §8).

## 5. Release flow: `elanthia-online/lich-5` ↔ Ruby4Lich5

- `elanthia-online/lich-5` cuts a release (existing Release-Please pipeline). It
  publishes 4 archive artifacts: tarball + zip of the repo, tarball + zip of the app.
  A human reviews and publishes the draft release.
- **This retires an existing job.** `release-on-push-stable.yaml` currently has a live,
  shipping `build_installer` job that installs MSYS2 fresh and compiles gems at CI time
  — the "wrong call" model the vision doc says was already superseded — and it already
  attaches a working `Ruby4Lich5.exe` (confirmed: 202MB, present on the real `v5.18.0`
  release) to every stable release today. This job must be explicitly deleted as part of
  the cutover.
- A human then starts the Ruby4Lich5 workflow, which pulls the published app archive.
  Ruby4Lich5 completes its work and publishes multiple draft releases (gems, the bundle,
  the installer). A human (possibly a different person, working in unison/async) reviews
  and publishes them — installer first to complete the current cycle, gems and bundle
  releases following.
- Ruby4Lich5 then opens a **PR** (not a raw asset upload — see below) against
  `elanthia-online/lich-5` adding a small git-tracked file: version, checksum, and a
  link to the Ruby4Lich5 release asset. A human reviews and merges it.
  - **Why a PR and not a direct asset attach:** a PR operates on git-tracked files;
    attaching a binary to an existing Release is a separate mechanism entirely (a direct
    API/CLI upload, same as `release-on-push-stable.yaml` already does internally today
    for its own repo). Doing that cross-repo would require a credential able to modify
    `elanthia-online/lich-5`'s "authoritative" release with no human review in the loop
    — a materially bigger trust grant than anything else in this design, which is
    gated behind PR review or team approval everywhere else. A metadata/pointer PR keeps
    EO's review discipline intact; the tradeoff is the `.exe` itself lives only on
    Ruby4Lich5's own release, linked rather than physically attached to EO's page.
- No automated hand-off signal exists between these steps — the same small,
  overlapping group of admins coordinates in real time/async, at roughly one release a
  month, with "a quick message about who's up next" as the only hand-off. Deliberately
  not automated (see §8); acceptable given the low cadence and small, trusted group.
- End state: `elanthia-online/lich-5` remains the authoritative distribution point for
  the Lich app and bundle; Ruby4Lich5 remains authoritative for the installer and all
  gem/bundle work, linked from EO's release rather than duplicating it.

## 6. Build caching: the baked working directory

The factory's actual current build (`ruby4-bundled-gems-suite.yml`) installs MSYS2 only
as a transient build surface to compile native gems, then validates the result by
extracting a *fresh* RubyInstaller archive into a clean directory, stripping all
MSYS2/DevKit env vars, and running `gem install --local` of the whole bundle into it —
proving the gems load with zero MSYS2 present. Today that clean tree is built only to
smoke-test, then discarded; the actual "fetch Ruby + install the bundle" assembly
happens again later, in the installer-assembly step. Ruby4Lich5's own installer never
runs `gem install --local` on an end user's machine — Inno Setup's `[Files]` section
reads an already-assembled local directory at CI compile time and compresses it directly
into the `.exe`; the only runtime Ruby invocation is the optional, developer-only
`ridk.cmd install` for the DevKit task.

**Decision:** persist that clean-Ruby-plus-gems tree as its own release artifact instead
of discarding it — eliminating a redundant fetch-and-install cycle that currently happens
twice across two workflows. Ruby and gems are cached **together as one unit**, not
separately:

- Ruby alone is never cached — refetching a specific RubyInstaller archive is free and
  identical to grabbing the public download directly, so there's nothing to gain from a
  separate Ruby-only cache tier.
- The **assembled working directory** (a specific Ruby + all current bundle gems
  installed into it, no MSYS2) is the thing that's expensive to reproduce and worth
  retaining. It's published as its own Ruby4Lich5 release, tagged by Ruby version +
  platform, checked via a **single sha256 hash over the whole compressed archive** (not
  per-file — there's no scenario where knowing which file inside is stale helps; a
  mismatch means rebuild the whole tree).
- It is rebuilt **wholesale**, never patched incrementally, whenever *anything* in it
  changes — one gem, ten gems (e.g. a GTK3 suite bump), or the Ruby version itself all
  trigger the same "fetch fresh Ruby, `gem install --local` the current full bundle,
  publish a new working-directory artifact" cycle.
- **Fast path** (the common case — only the Lich app changed, no gem/Ruby work):
  the CI job downloads the cached working-directory archive, extracts it locally into
  the exact path Inno Setup's `[Files]` section expects, drops in the newly-fetched Lich
  app content, revalidates the single checksum, and compiles — no MSYS2, no
  RubyInstaller fetch, no `gem install --local` re-run. Doug estimates this is the
  common case, roughly 3-4 releases out of 5.
- **What gates fast-path vs. full-rebuild:** pure human judgment, for now — no automated
  drift-detection guard between the manifest's current pins and the cached artifact's
  tag. Revisit if this ever proves to be a real failure mode at scale; not solving for it
  preemptively given the low release cadence and small team.

## 7. Test vs. production installer builds

Power users / EO members need to beta-test critical gem changes (Sequel, SQLite3, GTK3,
Ox) against their *existing* Lich installation before a change is trusted enough to
promote to the production pin — motivated by a real past incident that required reactive
pin-version fixes. Production stays on the known-proven gem set until a beta-tested
change is explicitly promoted.

This doesn't need new build machinery — the existing `Ruby4Lich5-installer.iss` already
has a `"rubyonly": "Ruby Installation Only"` component type (no Lich files at all), and
the existing workflow already exposes per-gem version-override dispatch inputs
(`ruby-gnome-version`, `cairo-version`, etc.). A test-installer build is simply:

- An explicit, one-off dispatch overriding the specific gem(s) under evaluation while
  everything else defaults to the current production pin.
- **Disposable** — not part of the baked-tree caching system (§6), never persisted as a
  reusable artifact.
- **Never writes to the curation manifest.** The manifest reflects known-proven state
  only; a test build's candidate version has no manifest presence at all.
- Clearly labeled (distinct tag prefix, marked prerelease, explicit "for EO/power-user
  testing, not for distribution" in the release body) so it's never mistaken for a
  production artifact.
- Promotion to production, once a beta test passes, goes through the exact same
  admin-gated approval/PR-review chain as any other gem release (§4) — no lighter path,
  regardless of who signed off on the beta test itself (see §8).

## 8. Automation philosophy: controlled trigger, not "automated vs. manual"

The deciding factor for whether something may be automated is **whose action triggers
it**, not whether automation is involved at all. Automation firing on an event fully
within an authorized admin's direct control (their own commit, merge, or explicit
dispatch — e.g. Release Please) is fine. Automation reacting to a lower-privileged or
externally-sourced signal is not — even a purely informational one. Concretely: a
non-admin EO member marking "beta test passed" must never auto-trigger promotion; that
marker is a no-op for automation, always. It can inform a human admin's decision, but
must never be wired to fire one itself. Applies to every approval gate in this design,
not just gem promotion.
