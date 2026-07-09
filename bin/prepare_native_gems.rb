#!/usr/bin/env ruby
# frozen_string_literal: true

# CLI entry point for the Ruby decision layer: resolve+classify+normalize+
# patch one gem request, writing the resulting build plan as JSON for the
# surrounding CI workflow's PowerShell to read and act on (the actual native
# compile stays PowerShell/MSYS2 -- see NativeGemPreparer's own doc comment
# for why). Deliberately dependency-free beyond stdlib (json, plus whatever
# NativeGemPreparer itself needs, all stdlib) so it can run with whichever
# Ruby the workflow already has on hand -- no bundler, no gem install step
# of its own required.
#
# Usage:
#   ruby bin/prepare_native_gems.rb <gem_name> <version> <platform> <ruby_abi> <source_root> <output_json_path>
#
# Exit status is a real contract the surrounding workflow's retry loop reads,
# not an incidental detail -- that loop exists for CI-transient-network
# concerns (rubygems.org resolution/download), and blindly retrying on any
# nonzero status treats a deterministic failure exactly like a network blip:
#
#   0 -- success, output_json_path written.
#   1 -- possibly transient, worth retrying: ResolutionError (wraps real
#        Timeout::Error/network failures from rubygems.org, see
#        ClosureResolver's own rescue), a bad ARGV invocation, or any
#        unrecognized exception (propagates its full Ruby backtrace --
#        Ruby's own uncaught-exception status is already 1, so this needs no
#        special handling here; an unrecognized failure deserves
#        investigation, not a shortened message that might hide what
#        actually went wrong, and retrying it once is a reasonable default
#        until it's understood well enough to earn its own named class).
#   2 -- deterministic, do not retry: IncompleteClosureError,
#        UnbuildableGemError, NormalizationError, PatchError,
#        GenerationError. All five operate purely on inputs already
#        resolved and downloaded to local disk -- retrying re-runs the
#        exact same check against the exact same bytes and gets the exact
#        same answer, just three times slower. IncompleteClosureError in
#        particular is a topological-sort-time consistency check over the
#        already-resolved node set (see ClosureResolver#topological_sort),
#        not a network call, even though it's raised by the same class as
#        ResolutionError -- the two are siblings, not related by
#        inheritance, and must not be rescued together.

require 'json'
require_relative '../lib/ruby4lich5/native_gem_preparer'
require_relative '../lib/ruby4lich5/closure_resolver'
require_relative '../lib/ruby4lich5/patch_generator'

ARG_NAMES = %i[gem_name version platform ruby_abi source_root output_json_path].freeze

if ARGV.size != ARG_NAMES.size
  warn "Usage: #{$PROGRAM_NAME} #{ARG_NAMES.map { |n| "<#{n}>" }.join(' ')}"
  exit 1
end

gem_name, version, platform, ruby_abi, source_root, output_json_path = ARGV

begin
  preparer = Ruby4Lich5::NativeGemPreparer.new
  plan = preparer.prepare(gem_name, version, platform: platform, ruby_abi: ruby_abi, source_root: source_root)
rescue Ruby4Lich5::ClosureResolver::ResolutionError => e
  warn "ERROR: #{e.class}: #{e.message}"
  exit 1
rescue Ruby4Lich5::ClosureResolver::IncompleteClosureError,
       Ruby4Lich5::BuildPlanner::UnbuildableGemError,
       Ruby4Lich5::GemspecNormalizer::NormalizationError,
       Ruby4Lich5::PatchApplier::PatchError,
       Ruby4Lich5::PatchGenerator::GenerationError => e
  warn "ERROR: #{e.class}: #{e.message}"
  exit 2
end

File.write(output_json_path, JSON.pretty_generate(plan))
puts "Wrote build plan for #{plan.size} gem(s) to #{output_json_path}"
