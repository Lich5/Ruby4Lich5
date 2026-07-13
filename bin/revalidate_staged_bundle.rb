#!/usr/bin/env ruby
# frozen_string_literal: true

# F2's final hard gate before packaging/manifest/publishing (docs/DECISIONS.md
# Phase 17 SS8 step 7, extended for the "resolve once" cutover) -- proves
# that what actually got staged/bootstrapped matches an already-resolved
# ResolutionLock (bin/resolve_bundle_lock.rb's own output) exactly. See
# StagedClosureRevalidator's own doc comment for the split-by-member-type
# rule this enforces.
#
# Takes the lock plus one real pre-stage baseline snapshot as input -- no
# separate staged-inventory or bundled-gem-inventory JSON handoff needed
# for either of those two. Both are computed by introspecting
# Gem::Specification directly, which is only meaningful because this
# script must itself run under the exact same bootstrapped target Ruby
# every other locked-input CLI in this cutover runs under (see the
# fail-fast assertion below) -- the whole point is checking *reality*, not
# re-stating whatever the install manifest already claimed.
#
# <pre_stage_baseline_json_path> is a real Gem::Specification snapshot
# (name => highest installed version) taken on this same Ruby *before* any
# lock-driven install ran -- see StagedClosureRevalidator's own doc
# comment for why this closes a real gap the lock-known-names checks alone
# cannot: an unpinned live install pulling in an undeclared transitive
# dependency wouldn't be "lock-known" at all, so only a real before/after
# comparison can catch it.
#
# **Must run under a real, bootstrapped, target-platform Ruby** -- unlike
# bin/resolve_bundle_lock.rb's own platform guard (which exists because
# RubyGems' resolver needs it), this one exists because the entire check
# is "what does Gem::Specification actually report on this Ruby" --
# running under the wrong Ruby would silently validate the wrong
# environment's own gem inventory instead of the one that matters.
#
# Usage:
#   ruby bin/revalidate_staged_bundle.rb <lock_json_path> <platform> \
#     <pre_stage_baseline_json_path>
#
# Exit status:
#   0 -- revalidation passed.
#   1 -- a bad ARGV invocation, or any unrecognized exception.
#   2 -- deterministic, do not retry: a platform-environment assertion
#        failure, ResolutionLock::ValidationError (a malformed lock), or
#        StagedClosureRevalidator::RevalidationFailure (real drift
#        between the lock and what is actually staged/bootstrapped).

require 'json'
require_relative '../lib/ruby4lich5/resolution_lock'
require_relative '../lib/ruby4lich5/staged_closure_revalidator'

ARG_NAMES = %i[lock_json_path platform pre_stage_baseline_json_path].freeze

if ARGV.size != ARG_NAMES.size
  warn "Usage: #{$PROGRAM_NAME} #{ARG_NAMES.map { |n| "<#{n}>" }.join(' ')}"
  exit 1
end

lock_json_path, platform, pre_stage_baseline_json_path = ARGV

unless Gem::Platform.local.to_s == platform
  warn "FATAL: this process is not a genuine bootstrapped #{platform.inspect} Ruby -- Gem::Platform.local is " \
       "#{Gem::Platform.local.to_s.inspect}. Revalidation must run under the exact Ruby the bundle was staged " \
       'into; introspecting any other Ruby\'s own gem inventory would validate the wrong environment.'
  exit 2
end

begin
  lock = Ruby4Lich5::ResolutionLock.from_h(JSON.parse(File.read(lock_json_path)))
  pre_stage_baseline_versions = JSON.parse(File.read(pre_stage_baseline_json_path))

  # @return [String, nil] the highest installed version RubyGems itself
  #   reports for +name+, right now, on this Ruby -- +nil+ if nothing by
  #   that name is installed at all
  def highest_installed_version(name)
    spec = Gem::Specification.find_all_by_name(name).max_by(&:version)
    spec&.version&.to_s
  end

  non_bundled_members = lock.closure.reject { |entry| entry.fetch(:classification).ruby_bundled? }
  staged_member_versions = non_bundled_members.each_with_object({}) do |entry, versions|
    name = entry.fetch(:name)
    actual = highest_installed_version(name)
    versions[name] = actual if actual
  end

  # Every installed specification, unfiltered -- deliberately not just
  # Gem::Specification#default_gem?-flagged ones. A :ruby_bundled
  # classification means RubyBundledGems.bundled?, the union of RubyGems'
  # own "default" gems and "bundled but not default" gems (rake, fiddle,
  # matrix, rexml, etc.) -- see StagedClosureRevalidator's own doc
  # comment for the real gap this closes.
  target_bundled_gem_versions = Gem::Specification.group_by(&:name).each_with_object({}) do |(name, specs), versions|
    versions[name] = specs.max_by(&:version).version.to_s
  end

  Ruby4Lich5::StagedClosureRevalidator.new(
    lock: lock, staged_member_versions: staged_member_versions, target_bundled_gem_versions: target_bundled_gem_versions,
    pre_stage_baseline_versions: pre_stage_baseline_versions
  ).revalidate!
rescue JSON::ParserError, Ruby4Lich5::ResolutionLock::ValidationError => e
  warn "ERROR: #{e.class}: #{e.message}"
  exit 2
rescue Ruby4Lich5::StagedClosureRevalidator::RevalidationFailure => e
  warn "ERROR: #{e.class}: #{e.message}"
  exit 2
rescue StandardError => e
  warn "ERROR: #{e.class}: #{e.message}"
  exit 1
end

puts "Staged closure revalidation passed for #{lock.closure.size} locked member(s)."
