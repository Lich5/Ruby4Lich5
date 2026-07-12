# frozen_string_literal: true

module Ruby4Lich5
  # Assembles a {CuratedGemRegistry}-shaped Hash from already-resolved
  # {BuildPlanner#plan_for} results -- deliberately takes already-resolved
  # data in, does no network I/O of its own, same separation this project
  # already uses elsewhere (e.g. {GemManifestGenerator} takes an injected
  # digest lookup rather than talking to RubygemsClient directly). The live
  # resolution (real `BuildPlanner#plan_for` calls, real network) is
  # `bin/derive_curated_gems_seed.rb`'s job; this class is the pure,
  # deterministic part, unit-testable with fake plan data and no real gem
  # downloads.
  class CuratedGemsSeedBuilder
    # Raised when the same gem name appears in two different roots'
    # closures with a different technical classification -- a real
    # inconsistency (the same name+version should classify identically
    # regardless of which root pulled it in), not something to silently
    # resolve by picking whichever root happened to be processed last.
    class ConflictError < StandardError; end

    # @return [Integer] must match {CuratedGemRegistry::SCHEMA_VERSION}
    SCHEMA_VERSION = 2
    private_constant :SCHEMA_VERSION

    # @param root_plans [Hash{String => Array<Hash>}] root gem name =>
    #   that root's +BuildPlanner#plan_for+ result (+{name:, version:,
    #   classification:, runtime_dependency_names:}+ entries)
    # @param default_root_names [Array<String>] which of +root_plans+'
    #   keys get +bundle_default: true+ -- every other gem, including every
    #   transitive closure member, gets +bundle_default: false+ (Phase 17
    #   SS3: `bundle_default` is a policy fact about *requested roots*, not
    #   about whether a gem happens to be reachable at all)
    # @param platform [String]
    # @param ruby_abi [String]
    # @param msys2_packages [Array<String>] the package set recorded for
    #   every +:native_self_contained+ member -- today's real recipe is
    #   uniform across all of them (matches
    #   +bin/derive_curated_gems_seed.rb+'s own
    #   +LEGACY_UNIFORM_GTK3_CURSES_PACKAGES+ constant -- the static toolchain
    #   set, {Msys2Bootstrap::PACKAGES}, and the stale
    #   +mingw-w64-ucrt-x86_64-sqlite3+ pin are both already excluded by the
    #   caller before this class ever sees the list, not subtracted here);
    #   per-gem package lists are future curation work, not invented here
    #   without evidence, matching {KnownNativeGems}'s own original design
    #   note
    def initialize(root_plans:, default_root_names:, platform:, ruby_abi:, msys2_packages:)
      @root_plans = root_plans
      @default_root_names = default_root_names
      @platform = platform
      @ruby_abi = ruby_abi
      @msys2_packages = msys2_packages
    end

    # @return [Hash] +{"schema" => 2, "gems" => {...}}+, ready for
    #   +JSON.pretty_generate+ -- String keys throughout, matching
    #   {CuratedGemRegistry}'s own real-file shape. Gem entries are always
    #   sorted by name -- real bug, found in review 2026-07-13: two
    #   logically-identical +root_plans+ Hashes differing only in insertion
    #   order (Ruby +Hash+ iterates in insertion order) produced Ruby
    #   objects that were +==+ but serialized to *different*
    #   +JSON.pretty_generate+ byte sequences, since JSON serialization
    #   follows Hash iteration order. That would have broken exact
    #   reproducibility for {CuratedGemRegistry#content_digest} and the
    #   future resolution lock (Phase 17 section 8), both of which depend
    #   on the same logical input always producing byte-identical output.
    # @raise [ConflictError]
    def build
      gems = {}

      @root_plans.each_value do |plan|
        plan.each do |entry|
          next if entry.fetch(:classification).ruby_bundled?

          merge_entry!(gems, entry)
        end
      end

      { 'schema' => SCHEMA_VERSION, 'gems' => gems.sort_by { |name, _entry| name }.to_h }
    end

    private

    # @raise [ConflictError]
    def merge_entry!(gems, entry)
      name = entry.fetch(:name)
      target = target_for(entry.fetch(:classification))
      bundle_default = @default_root_names.include?(name)

      existing = gems[name]
      if existing
        merge_conflicting_entry!(existing, name, target, bundle_default: bundle_default)
      else
        gems[name] = { 'approval' => 'approved', 'bundle_default' => bundle_default,
                        'targets' => { @platform => { @ruby_abi => target } } }
      end
    end

    # @raise [ConflictError] if +existing+'s already-recorded target for
    #   this exact platform/ABI disagrees with +target+ -- the same gem
    #   reached via two different roots' closures classified two different
    #   ways, a real problem to surface loudly rather than silently keep
    #   whichever one happened to be seen first
    def merge_conflicting_entry!(existing, name, target, bundle_default:)
      recorded = existing.dig('targets', @platform, @ruby_abi)
      if recorded != target
        raise ConflictError,
              "#{name}: conflicting classification between root closures -- #{recorded.inspect} vs #{target.inspect}"
      end

      existing['bundle_default'] ||= bundle_default
    end

    # @return [Hash]
    def target_for(classification)
      target = { 'expected_classification' => classification.state.to_s }
      target['msys2_packages'] = @msys2_packages if classification.self_contained?
      target
    end
  end
end
