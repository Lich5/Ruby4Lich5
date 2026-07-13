# frozen_string_literal: true

require 'ruby4lich5/classification'

# Shared {ResolutionLock}-shaped fixture builders -- found duplicated
# byte-for-byte (`#classification`) or functionally identical
# (`#closure_entry`, cosmetic keyword-order drift only) across
# resolution_lock_spec.rb, registry_policy_gate_spec.rb, and
# staged_closure_revalidator_spec.rb, real DRY gap found in review.
# `include`d explicitly per spec file, not auto-loaded via spec_helper --
# only the specs that actually build closure/classification fixtures need
# this, matching this project's existing preference for explicit requires
# over implicit global config.
module ClosureFixtures
  # @param state [Symbol] one of Ruby4Lich5::Classification::STATES
  # @return [Ruby4Lich5::Classification]
  def classification(state, **overrides)
    Ruby4Lich5::Classification.new(state: state, gem_name: 'unused', gem_version: '1.0.0', reason: 'test', **overrides)
  end

  # @param name [String]
  # @param version [String]
  # @param state [Symbol] one of Ruby4Lich5::Classification::STATES
  # @param deps [Array<Array(String, String)>] +[dependency_name,
  #   requirement_string]+ pairs; a bare dependency name defaults its
  #   requirement to +">= 0"+ (unconstrained)
  # @return [Hash] a {ResolutionLock}-shaped +{name:, version:,
  #   runtime_dependencies:, classification:}+ closure entry
  def closure_entry(name, version, state: :pure, deps: [], **classification_overrides)
    {
      name: name, version: version,
      runtime_dependencies: deps.map { |dep_name, req| { name: dep_name, requirement: Gem::Requirement.new(req || '>= 0') } },
      # Real gap, found in audit 2026-07-13: this used to always build the
      # classification with a placeholder gem_name/gem_version ("unused"/
      # "1.0.0"), regardless of this entry's own real name/version --
      # harmless while nothing ever checked the two agreed, but exactly
      # the shape ResolutionLock.deserialize_closure_entry's own identity
      # invariant now enforces. Defaults to matching this entry's own
      # name/version; classification_overrides can still force a mismatch
      # for a test that specifically wants one.
      classification: classification(state, gem_name: name, gem_version: version, **classification_overrides)
    }
  end
end
