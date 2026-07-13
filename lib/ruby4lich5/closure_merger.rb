# frozen_string_literal: true

module Ruby4Lich5
  # Merges multiple roots' own {BuildPlanner#plan_for} results into one
  # flat, deduplicated closure -- the shape {ResolutionLock} needs (one
  # entry per name, no duplicates; {ResolutionLock}'s own construction
  # rejects a closure containing the same name twice, so this merge has to
  # happen before a lock can be built from more than one root at all).
  #
  # Deliberately not {CuratedGemsSeedBuilder}: that class's own merge
  # produces a *registry-shaped* result (approval/bundle_default/targets,
  # no version), built for a genuinely different purpose (Phase 17 SS5's
  # locked "no version pinning" rule). This class's whole reason to exist
  # is the opposite -- {ResolutionLock} needs the exact resolved *version*
  # per member, which the registry schema deliberately never carries.
  class ClosureMerger
    # Raised when the same gem name appears in two different roots'
    # closures with a different resolved version or a different
    # classification -- a real inconsistency (the same name should
    # resolve identically regardless of which root pulled it in), not
    # something to silently resolve by keeping whichever root happened to
    # be processed first.
    class ConflictError < StandardError; end

    # @param root_plans [Hash{String => Array<Hash>}] root gem name =>
    #   that root's {BuildPlanner#plan_for} result
    # @return [Array<Hash>] one {name:, version:, classification:,
    #   runtime_dependencies:} entry per distinct gem name across every
    #   root's closure, order determined by first encounter (a caller
    #   needing a specific order, e.g. deterministic package-list
    #   ordering, sorts the result itself)
    # @raise [ConflictError]
    def merge(root_plans)
      merged = {}
      root_plans.each_value do |plan|
        plan.each { |entry| merge_entry!(merged, entry) }
      end
      merged.values
    end

    private

    def merge_entry!(merged, entry)
      name = entry.fetch(:name)
      existing = merged[name]

      if existing
        check_no_conflict!(existing, entry, name)
      else
        merged[name] = entry
      end
    end

    # @raise [ConflictError]
    def check_no_conflict!(existing, entry, name)
      existing_version = existing.fetch(:version)
      version = entry.fetch(:version)
      if existing_version != version
        raise ConflictError, "#{name}: conflicting version between root closures -- #{existing_version.inspect} vs #{version.inspect}"
      end

      # Compared as full Classification objects, not just .state -- real
      # gap, found in review: {Classification} is a Struct (gem_name,
      # gem_version, reason, platform_asset, msys2_packages alongside
      # state), and Struct#== already compares every member structurally.
      # An earlier version compared only .state, so two roots resolving
      # the same gem+version to the same state but different
      # msys2_packages (or a different platform_asset) would silently
      # merge, picking whichever root happened to be processed first --
      # the same "arbitrary first-wins" risk already fixed for
      # runtime_dependencies below, just not yet for classification's own
      # richer fields. Safe to compare in full: {Classifier#classify} is a
      # pure function of name/version/platform/ruby_abi (confirmed
      # directly against its own implementation), so two roots resolving
      # the identical gem+version must always produce an identical
      # Classification, including reason's exact text -- there is no
      # legitimate root-specific variance this stricter comparison could
      # false-positive on.
      existing_classification = existing.fetch(:classification)
      classification = entry.fetch(:classification)
      if existing_classification != classification
        raise ConflictError,
              "#{name}: conflicting classification between root closures -- " \
              "#{existing_classification.to_h.inspect} vs #{classification.to_h.inspect}"
      end

      check_no_dependency_conflict!(existing, entry, name)
    end

    # Real gap, found in review: an earlier version stopped checking after
    # version/classification agreed and silently kept whichever root's
    # entry happened to be merged first, discarding the other root's own
    # runtime_dependencies entirely. {ResolutionLock}'s own dependency-
    # satisfaction check (and any later revalidation built on it) trusts
    # the dependency edges a merged closure entry carries -- an
    # arbitrary first-wins pick could silently drop a real edge a second
    # root's own resolution actually found, the same class of "two
    # independent implementations quietly disagree" risk this whole
    # closure-merge step exists to prevent for version/classification.
    #
    # Compared order-insensitively (sorted by name, then requirement's own
    # String form) -- {ClosureResolver#resolve_closure} derives
    # +runtime_dependencies+ from the same gem+version's own real
    # gemspec data every time, so two roots resolving the identical
    # gem+version should see identical *content* regardless of enumeration
    # order; only an actual content difference should raise, not an
    # incidental ordering difference between two independent resolutions.
    #
    # @raise [ConflictError]
    def check_no_dependency_conflict!(existing, entry, name)
      existing_deps = normalize_dependencies(existing.fetch(:runtime_dependencies))
      deps = normalize_dependencies(entry.fetch(:runtime_dependencies))
      return if existing_deps == deps

      raise ConflictError,
            "#{name}: conflicting runtime_dependencies between root closures -- #{existing_deps.inspect} vs #{deps.inspect}"
    end

    # @return [Array<Array(String, String)>] +[name, requirement_string]+
    #   pairs, sorted by name -- a stable, comparable, human-readable form
    #   ({Gem::Requirement#to_s}, not +#inspect}+'s internal object shape)
    def normalize_dependencies(runtime_dependencies)
      runtime_dependencies.map { |dep| [dep.fetch(:name), dep.fetch(:requirement).to_s] }.sort
    end
  end
end
