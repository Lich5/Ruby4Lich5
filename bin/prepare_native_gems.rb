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
# Exit status: 0 on success (output_json_path written). Non-zero on any
# failure, with a one-line "ERROR: ..." message on stderr for the known,
# named failure modes (bad resolution, unbuildable gem, bad gemspec, patch
# mismatch) -- anything else propagates its full Ruby backtrace, since an
# unrecognized failure deserves investigation, not a shortened message that
# might hide what actually went wrong.

require 'json'
require_relative '../lib/ruby4lich5/native_gem_preparer'
require_relative '../lib/ruby4lich5/closure_resolver'

ARG_NAMES = %i[gem_name version platform ruby_abi source_root output_json_path].freeze

if ARGV.size != ARG_NAMES.size
  warn "Usage: #{$PROGRAM_NAME} #{ARG_NAMES.map { |n| "<#{n}>" }.join(' ')}"
  exit 1
end

gem_name, version, platform, ruby_abi, source_root, output_json_path = ARGV

begin
  preparer = Ruby4Lich5::NativeGemPreparer.new
  plan = preparer.prepare(gem_name, version, platform: platform, ruby_abi: ruby_abi, source_root: source_root)
rescue Ruby4Lich5::ClosureResolver::ResolutionError,
       Ruby4Lich5::BuildPlanner::UnbuildableGemError,
       Ruby4Lich5::GemspecNormalizer::NormalizationError,
       Ruby4Lich5::PatchApplier::PatchError => e
  warn "ERROR: #{e.class}: #{e.message}"
  exit 1
end

File.write(output_json_path, JSON.pretty_generate(plan))
puts "Wrote build plan for #{plan.size} gem(s) to #{output_json_path}"
