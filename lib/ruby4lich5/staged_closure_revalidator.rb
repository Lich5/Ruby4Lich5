# frozen_string_literal: true

require_relative 'safe_token'

module Ruby4Lich5
  # The split revalidation from docs/DECISIONS.md Phase 17 SS8 step 7 --
  # proves that what actually got staged/bootstrapped matches a
  # {ResolutionLock} exactly, closing the loop the registry gate (step 3,
  # {RegistryPolicyGate}) only opens: the gate only means something if
  # what it approved is provably what shipped.
  #
  # Deliberately never requires or accepts either of this project's two
  # live-resolution classes -- the RubyGems.org closure resolver, or its
  # underlying HTTP client -- not by convention, but structurally: this
  # file has no `require` for either, and no method here accepts one as a
  # constructor argument. "Never resolve again during staging" (SS8's own
  # locked design) is therefore impossible to violate by accident, not
  # merely discouraged. See
  # +spec/ruby4lich5/staged_closure_revalidator_spec.rb+'s own source-level
  # test proving this file's real code never references either class --
  # deliberately not named by class here either, so this comment can't
  # itself trip a future, simpler version of that same check.
  #
  # Split by member type, the real gap SS8 step 7 was corrected for: a
  # single "staged closure exactly matches the lock" rule cannot hold for
  # +:ruby_bundled+ members, since the real build already deliberately
  # excludes default gems from staged output
  # (+ruby4-bundled-gems-suite.yml:1086+'s own `next if spec.default_gem?`).
  # - **Non-+ruby_bundled+ members**: exact lock/staged equality -- every
  #   name+version in the lock must appear staged on disk, and vice versa.
  # - **+ruby_bundled+ members**: never compared to staged files at all.
  #   Verified instead against the bootstrapped Ruby's actual default-gem
  #   versions -- present as a default gem, *and* that actual version
  #   satisfies every recorded `Gem::Requirement` edge naming it anywhere
  #   in the locked closure (proving presence alone isn't enough; the
  #   specific resolved constraint has to actually hold).
  class StagedClosureRevalidator
    # Raised when {#revalidate!} finds one or more violations -- every
    # violation found, not just the first.
    class RevalidationFailure < StandardError; end

    # @param lock [ResolutionLock]
    # @param staged_member_versions [Hash{String => String}] name =>
    #   version, exactly what's actually present on disk after
    #   build/staging -- the caller's own responsibility to produce; this
    #   class never inspects a real filesystem itself
    # @param default_gem_versions [Hash{String => String}] name =>
    #   version, what the bootstrapped Ruby's actual default gems report
    #   -- the caller's own responsibility to produce; this class never
    #   shells out to a real Ruby install itself
    # @raise [RevalidationFailure] if either inventory isn't a Hash, or any
    #   of its names or version strings are malformed -- real gap, found
    #   in review: both inventories were previously trusted as-is. A +nil+
    #   +default_gem_versions+ leaked a raw +NoMethodError+, and a
    #   malformed version string (e.g. +"not-a-version"+) leaked a raw
    #   +ArgumentError+ from +Gem::Version.new+ deep inside
    #   {Gem::Requirement#satisfied_by?} -- both confirmed live, both past
    #   this class's own promised +RevalidationFailure+ boundary.
    def initialize(lock:, staged_member_versions:, default_gem_versions:)
      @lock = lock
      @staged_member_versions = validate_inventory!(staged_member_versions, 'staged_member_versions')
      @default_gem_versions = validate_inventory!(default_gem_versions, 'default_gem_versions')
    end

    # @raise [RevalidationFailure]
    def revalidate!
      non_bundled, bundled = @lock.closure.partition { |entry| !entry.fetch(:classification).ruby_bundled? }

      violations = non_bundled_violations(non_bundled) + bundled.flat_map { |entry| bundled_violations(entry) }
      return if violations.empty?

      raise RevalidationFailure, "staged-closure revalidation failed:\n#{violations.join("\n")}"
    end

    private

    # @return [Array<String>]
    def non_bundled_violations(non_bundled_entries)
      locked_names = non_bundled_entries.map { |entry| entry.fetch(:name) }

      mismatched = non_bundled_entries.filter_map { |entry| non_bundled_entry_violation(entry) }
      extra = (@staged_member_versions.keys - locked_names).map do |name|
        "#{name.inspect}: staged but not present in the resolved closure's non-ruby_bundled members"
      end

      mismatched + extra
    end

    # @return [String, nil]
    def non_bundled_entry_violation(entry)
      name = entry.fetch(:name)
      locked_version = entry.fetch(:version)
      staged_version = @staged_member_versions[name]

      if staged_version.nil?
        "#{name.inspect}: locked #{locked_version.inspect} but not staged"
      elsif staged_version != locked_version
        "#{name.inspect}: locked #{locked_version.inspect}, staged #{staged_version.inspect}"
      end
    end

    # @return [Array<String>]
    def bundled_violations(entry)
      name = entry.fetch(:name)
      actual_version = @default_gem_versions[name]

      if actual_version.nil?
        return ["#{name.inspect}: locked as a ruby_bundled default gem, but not present as a default gem in the bootstrapped Ruby"]
      end

      requirements_naming(name).filter_map do |requirement|
        next if requirement.satisfied_by?(Gem::Version.new(actual_version))

        "#{name.inspect}: bootstrapped default-gem version #{actual_version.inspect} does not satisfy the recorded " \
        "requirement (#{requirement}) from the resolved closure"
      end
    end

    # @return [Array<Gem::Requirement>] every requirement any closure
    #   member's own runtime_dependencies edges records against
    #   +dependency_name+ -- a ruby_bundled member can legitimately be
    #   depended on by more than one other member, each with its own
    #   requirement; the actual bootstrapped version must satisfy all of
    #   them, not just whichever happened to be checked first
    def requirements_naming(dependency_name)
      @lock.closure.flat_map do |entry|
        entry.fetch(:runtime_dependencies)
             .select { |dep| dep.fetch(:name) == dependency_name }
             .map { |dep| dep.fetch(:requirement) }
      end
    end

    # @return [Hash] +inventory+ itself, once every name/version pair in it
    #   is confirmed well-formed
    # @raise [RevalidationFailure]
    def validate_inventory!(inventory, label)
      unless inventory.is_a?(Hash)
        raise RevalidationFailure, "#{label} must be a Hash, got #{inventory.class}: #{inventory.inspect}"
      end

      inventory.each do |name, version|
        validate_inventory_name!(name, label)
        validate_inventory_version!(version, name, label)
      end

      inventory
    end

    # @raise [RevalidationFailure]
    def validate_inventory_name!(name, label)
      SafeToken.validate!(name, "#{label} name")
    rescue ArgumentError => e
      # {SafeToken.validate!} raises ArgumentError -- this class's whole
      # contract is "every rejection is a RevalidationFailure," same
      # wrapper pattern {CuratedGemRegistry#safe_token!} already
      # established.
      raise RevalidationFailure, e.message
    end

    # @raise [RevalidationFailure]
    def validate_inventory_version!(version, name, label)
      return if version.is_a?(String) && !version.strip.empty? && Gem::Version.correct?(version)

      raise RevalidationFailure, "#{label}[#{name.inspect}] must be a valid, non-blank RubyGems version, got #{version.inspect}"
    end
  end
end
