# frozen_string_literal: true

require 'rubygems'
require_relative 'build_planner'
require_relative 'gemspec_normalizer'
require_relative 'patch_applier'
require_relative 'patch_generator'
require_relative 'vendoring_role_classifier'
require_relative 'glib2_reachability'
require_relative 'safe_token'

module Ruby4Lich5
  # The Ruby decision layer's actual entry point for one build request:
  # resolve the closure, classify each gem, and -- for every gem this build
  # must compile itself (+:native_self_contained+) -- normalize its gemspec,
  # auto-generate the common vendor-dir + ABI-require patch if it has none
  # at all yet (item 7a, {PatchGenerator}), and apply whatever curated
  # patches exist for it, hand-written or generated.
  #
  # Every native-self-contained gem goes through exactly this same sequence,
  # deliberately no per-gem special-casing here: {GemspecNormalizer} always
  # runs (the same transform for every one of them), patch generation only
  # ever fires for a gem with zero existing patches (never touches a gem
  # that already has any, hand-written or previously generated), and
  # {PatchApplier} always runs last and simply returns an empty result for a
  # gem that still has no +patches/<gem_name>/+ directory at all after that
  # (a real, expected outcome for a gem with no compiled extension of its
  # own -- see {#maybe_generate_patch}). Patching "falls out" for gems that
  # don't need it rather than being conditionally skipped.
  #
  # +:pure+ and +:native_pass_through+ gems need neither -- a pure gem has no
  # native extension to normalize, and a pass-through gem is fetched as an
  # already-published platform binary, never locally compiled at all.
  #
  # Deliberately stops at "resolve, classify, normalize, patch" -- same
  # boundary {BuildPlanner} already draws for its own scope. The actual
  # native compile (MSYS2, gcc, DLL-closure-walking) stays exactly where it
  # already is, PowerShell invoked by the surrounding workflow once this
  # returns its plan -- see docs/DECISIONS.md's "Ruby drives decisions,
  # PowerShell drives OS-level mechanics" split.
  class NativeGemPreparer
    # @param build_planner [BuildPlanner]
    # @param gemspec_normalizer [GemspecNormalizer]
    # @param patch_applier [PatchApplier]
    # @param patch_generator [PatchGenerator]
    # @param vendoring_role_classifier [VendoringRoleClassifier]
    def initialize(
      build_planner: BuildPlanner.new,
      gemspec_normalizer: GemspecNormalizer.new,
      patch_applier: PatchApplier.new,
      patch_generator: PatchGenerator.new,
      vendoring_role_classifier: VendoringRoleClassifier.new
    )
      @build_planner = build_planner
      @gemspec_normalizer = gemspec_normalizer
      @patch_applier = patch_applier
      @patch_generator = patch_generator
      @vendoring_role_classifier = vendoring_role_classifier
    end

    # @param gem_name [String]
    # @param version [String] exact version to prepare, e.g. +"3.5.6"+
    # @param platform [String] target RubyGems platform tag
    # @param ruby_abi [String] target Ruby ABI series, e.g. +"4.0"+
    # @param source_root [String] directory containing one already-extracted
    #   subdirectory per gem in the closure, named +<gem_name>+ -- the
    #   surrounding workflow's job to have downloaded and extracted before
    #   calling this; this class only prepares what's already there
    # @return [Array<Hash>] one +{name:, version:, state:, reason:,
    #   platform_asset:, msys2_packages:, vendoring_role:, patches_applied:}+
    #   entry per gem in the plan, in the same dependency order
    #   {BuildPlanner#plan_for} returns. +patches_applied+ is +[]+ for
    #   anything not +:native_self_contained+. +vendoring_role+ is +nil+ for
    #   the same non-self-contained entries -- see {VendoringRoleClassifier}
    #   for +:vendoring_root+ vs. +:vendoring_dependent+.
    # @raise [ClosureResolver::ResolutionError] if the requested gem+version
    #   can't be resolved at all
    # @raise [BuildPlanner::UnbuildableGemError] if any gem in the closure
    #   classifies as +:native_needs_system_lib+
    # @raise [GemspecNormalizer::NormalizationError] if a self-contained
    #   gem's gemspec is missing or malformed in a way normalization can't
    #   work around
    # @raise [PatchApplier::PatchError] if a self-contained gem's curated
    #   patch doesn't apply cleanly against its actual extracted source
    def prepare(gem_name, version, platform:, ruby_abi:, source_root:)
      plan = @build_planner.plan_for(gem_name, version, platform: platform, ruby_abi: ruby_abi)
      vendoring_roles = @vendoring_role_classifier.classify(plan)

      plan.map { |entry| prepare_one(entry, platform: platform, source_root: source_root, vendoring_roles: vendoring_roles, plan: plan) }
    end

    # RubyGems' own extension declarations end up runnable through several
    # real, quite different builders -- extconf.rb (mkmf), configure,
    # Rakefile/mkrf_conf.rb, and, for newer gems, CMakeLists.txt or
    # Cargo.toml (Rust). Guessing which filenames "mean compiled" and which
    # don't is exactly the wrong shape for a check whose only job is
    # deciding whether it's safe to silently skip generating a patch --
    # enumerating known-safe builder names fails *open* for every filename
    # not yet on the list, including ones that don't exist yet. Only this
    # one exact, independently verified task -- ruby-gnome's own
    # dependency-check convention, confirmed real against atk/gdk3/
    # gdk_pixbuf2's actual gemspecs 2026-07-08, confirmed to compile nothing
    # -- is exempted. Every other declared extension, known builder or not,
    # fails closed.
    DEPENDENCY_CHECK_TASK = 'dependency-check/Rakefile'
    private_constant :DEPENDENCY_CHECK_TASK

    private

    # @return [Hash]
    def prepare_one(entry, platform:, source_root:, vendoring_roles:, plan:)
      classification = entry.fetch(:classification)
      name = entry.fetch(:name)
      gem_root = File.join(source_root, name)

      patches_applied = classification.self_contained? ? prepare_self_contained(name, gem_root, platform, plan) : []

      {
        name: name,
        version: entry.fetch(:version),
        state: classification.state,
        reason: classification.reason,
        platform_asset: classification.platform_asset,
        msys2_packages: classification.msys2_packages,
        vendoring_role: vendoring_roles[name],
        patches_applied: patches_applied
      }
    end

    # @return [Array<Hash>] {PatchApplier#apply_all}'s return value verbatim
    def prepare_self_contained(name, gem_root, platform, plan)
      # Captured before normalize -- GemspecNormalizer strips the gemspec's
      # own s.extensions = ... line as part of its own job (a binary gem
      # ships a precompiled .so, not source to extconf against), so this
      # has to run first or there would be nothing left to read.
      extensions = declared_extensions(name, gem_root)

      @gemspec_normalizer.normalize(name, gem_root, platform: platform)
      maybe_generate_patch(name, gem_root, plan, extensions: extensions)
      @patch_applier.apply_all(name, gem_root)
    end

    # Auto-generates the vendor-dir + ABI-require patch (item 7a) for a gem
    # that has no curated patch at all yet -- never for one that already has
    # any, hand-written or previously generated, so a bespoke addition
    # layered on top of the template (gobject-introspection's typelib/
    # fontconfig setup) or a narrower shape that doesn't need the full
    # template (cairo-gobject's require-abi-only) never gets silently
    # clobbered.
    #
    # PatchGenerator::NoAnchorFound is treated as success only for the one
    # verified-safe extensions shape (see DEPENDENCY_CHECK_TASK). Without
    # that check, "our regex didn't recognize this gem's anchor syntax" and
    # "this gem genuinely has nothing to require" are indistinguishable, and
    # the former would silently ship a gem missing its DLL-path patch --
    # exactly the failure mode 7a was scoped to fail loudly on, not paper
    # over. AmbiguousAnchor (more than one candidate, genuinely unclear)
    # always propagates regardless.
    def maybe_generate_patch(name, gem_root, plan, extensions:)
      return if @patch_applier.patches_exist_for?(name)

      @patch_generator.generate(name, gem_root, depends_on_glib2: Glib2Reachability.reachable?(name, plan))
    rescue PatchGenerator::NoAnchorFound
      raise unless extensions == [DEPENDENCY_CHECK_TASK]
    end

    # @return [Array<String>] this gem's own +extensions+ exactly as its
    #   gemspec declares them, forward-slash-normalized and sorted --
    #   deliberately read straight from the gemspec file rather than
    #   inferred from filenames on disk, so a builder this class has never
    #   heard of (a new RubyGems extension mechanism, or one simply not yet
    #   in {DEPENDENCY_CHECK_TASK}'s exemption) is never silently treated as
    #   "safe."
    # @raise [ArgumentError] if +name+ is missing or contains unsafe characters
    # @raise [GemspecNormalizer::NormalizationError] if the gemspec can't be
    #   loaded at all
    def declared_extensions(name, gem_root)
      SafeToken.validate!(name, 'gem name')
      path = File.join(gem_root, "#{name}.gemspec")
      spec = Gem::Specification.load(path)

      unless spec
        raise GemspecNormalizer::NormalizationError, "could not load extension declarations from #{path}"
      end

      spec.extensions.map { |entry| entry.tr('\\', '/') }.sort
    end
  end
end
