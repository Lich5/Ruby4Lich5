#!/usr/bin/env ruby
# frozen_string_literal: true

# The locked-input counterpart to bin/prepare_native_gems.rb, for F2's
# "resolve once" cutover (docs/DECISIONS.md, extended) -- normalizes and
# patches every native_self_contained member of an already-resolved
# ResolutionLock (bin/resolve_bundle_lock.rb's own output), never calling
# BuildPlanner#plan_for itself. See NativeGemPreparer#prepare_from_plan's
# own doc comment for the full "no live re-resolve" contract.
#
# Deliberately operates over the lock's *whole* merged closure, not one
# root's own subtree -- NativeGemPreparer#prepare_one already skips
# normalize/patch for anything that isn't native_self_contained, so a
# single pass here correctly covers every self-contained member across
# every requested root at once (the real GTK3 stack, plus anything else
# -- e.g. ox/curses -- that classifies the same way), rather than the old
# design's two separate mechanisms (bin/prepare_native_gems.rb for gtk3
# specifically, a hardcoded ox/curses repack loop elsewhere).
#
# Output JSON shape matches bin/prepare_native_gems.rb's own exactly
# (NativeGemPreparer#prepare_from_plan returns the identical per-entry
# shape #prepare does) -- ruby4-bundled-gems-suite.yml's own "Build GTK3
# binary gem suite" step, which only ever reads that plan for the fixed
# 10-gem GTK3 build list, needs zero changes to keep consuming this.
#
# Usage:
#   ruby bin/prepare_native_gems_from_lock.rb <lock_json_path> <platform> <source_root> <output_json_path>
#
# Exit status:
#   0 -- success, output_json_path written.
#   1 -- a bad ARGV invocation, malformed lock JSON, or any unrecognized
#        exception.
#   2 -- deterministic, do not retry: BuildPlanner::UnbuildableGemError,
#        GemspecNormalizer::NormalizationError, PatchApplier::PatchError,
#        PatchGenerator::GenerationError, or ResolutionLock::ValidationError
#        (a malformed lock file). All operate purely on inputs already
#        resolved and downloaded to local disk.

require 'json'
require_relative '../lib/ruby4lich5/native_gem_preparer'
require_relative '../lib/ruby4lich5/patch_generator'
require_relative '../lib/ruby4lich5/resolution_lock'

ARG_NAMES = %i[lock_json_path platform source_root output_json_path].freeze

if ARGV.size != ARG_NAMES.size
  warn "Usage: #{$PROGRAM_NAME} #{ARG_NAMES.map { |n| "<#{n}>" }.join(' ')}"
  exit 1
end

lock_json_path, platform, source_root, output_json_path = ARGV

begin
  lock = Ruby4Lich5::ResolutionLock.from_h(JSON.parse(File.read(lock_json_path)))

  # NativeGemPreparer#prepare_from_plan's own doc comment names this
  # translation as the caller's responsibility: a lock's closure entry
  # carries runtime_dependencies (the richer {name:, requirement:} shape)
  # but not runtime_dependency_names (bare strings), which
  # VendoringRoleClassifier#classify needs for every entry, not just
  # native_self_contained ones. Confirmed live, before fixing: passing
  # lock.closure straight through raised KeyError: key not found:
  # :runtime_dependency_names deep inside VendoringRoleClassifier.
  plan_shaped_closure = lock.closure.map do |entry|
    entry.merge(runtime_dependency_names: entry.fetch(:runtime_dependencies).map { |dep| dep.fetch(:name) })
  end

  preparer = Ruby4Lich5::NativeGemPreparer.new
  plan = preparer.prepare_from_plan(plan_shaped_closure, platform: platform, source_root: source_root)

  # Inside the protected region -- real gap, found in audit 2026-07-13: a
  # write failure here (bad output directory, permissions, full disk)
  # previously escaped every rescue clause below, leaking a raw exception
  # instead of this CLI's own documented exit-1 error format.
  File.write(output_json_path, JSON.pretty_generate(plan))
  puts "Wrote build plan for #{plan.size} gem(s) to #{output_json_path}"
rescue JSON::ParserError, Ruby4Lich5::ResolutionLock::ValidationError => e
  warn "ERROR: #{e.class}: #{e.message}"
  exit 2
rescue Ruby4Lich5::BuildPlanner::UnbuildableGemError,
       Ruby4Lich5::GemspecNormalizer::NormalizationError,
       Ruby4Lich5::PatchApplier::PatchError,
       Ruby4Lich5::PatchGenerator::GenerationError => e
  warn "ERROR: #{e.class}: #{e.message}"
  exit 2
rescue StandardError => e
  warn "ERROR: #{e.class}: #{e.message}"
  exit 1
end
