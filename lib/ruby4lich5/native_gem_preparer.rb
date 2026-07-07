# frozen_string_literal: true

require_relative 'build_planner'
require_relative 'gemspec_normalizer'
require_relative 'patch_applier'

module Ruby4Lich5
  # The Ruby decision layer's actual entry point for one build request:
  # resolve the closure, classify each gem, and -- for every gem this build
  # must compile itself (+:native_self_contained+) -- normalize its gemspec
  # and apply whatever curated patches exist for it, if any.
  #
  # Every native-self-contained gem goes through exactly this same sequence,
  # deliberately no per-gem special-casing here: {GemspecNormalizer} always
  # runs (the same transform for every one of them), {PatchApplier} always
  # runs and simply returns an empty result for a gem with no
  # +patches/<gem_name>/+ directory at all. Patching "falls out" for gems
  # that don't need it rather than being conditionally skipped.
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
    def initialize(
      build_planner: BuildPlanner.new,
      gemspec_normalizer: GemspecNormalizer.new,
      patch_applier: PatchApplier.new
    )
      @build_planner = build_planner
      @gemspec_normalizer = gemspec_normalizer
      @patch_applier = patch_applier
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
    #   platform_asset:, msys2_packages:, patches_applied:}+ entry per gem
    #   in the plan, in the same dependency order {BuildPlanner#plan_for}
    #   returns. +patches_applied+ is +[]+ for anything not
    #   +:native_self_contained+.
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

      plan.map { |entry| prepare_one(entry, platform: platform, source_root: source_root) }
    end

    private

    # @return [Hash]
    def prepare_one(entry, platform:, source_root:)
      classification = entry.fetch(:classification)
      name = entry.fetch(:name)
      gem_root = File.join(source_root, name)

      patches_applied = classification.self_contained? ? prepare_self_contained(name, gem_root, platform) : []

      {
        name: name,
        version: entry.fetch(:version),
        state: classification.state,
        reason: classification.reason,
        platform_asset: classification.platform_asset,
        msys2_packages: classification.msys2_packages,
        patches_applied: patches_applied
      }
    end

    # @return [Array<Hash>] {PatchApplier#apply_all}'s return value verbatim
    def prepare_self_contained(name, gem_root, platform)
      @gemspec_normalizer.normalize(name, gem_root, platform: platform)
      @patch_applier.apply_all(name, gem_root)
    end
  end
end
