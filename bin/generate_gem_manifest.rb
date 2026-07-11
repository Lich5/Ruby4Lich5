#!/usr/bin/env ruby
# frozen_string_literal: true

# CLI entry point: builds the gem recovery manifest (docs/DECISIONS.md Phase
# 13 SS2/SS3, docs/r4l5-gem-recovery-manifest.md on lich-5) from the closure
# actually staged in the runtime bundle, and writes it as JSON. Reads
# gemspecs directly from the staged .gem files (StagedGemSpecFinder), not
# from a live Ruby's installed-gem registry -- the job this runs in has no
# such registry (it downloads only the staged files, never restores the
# build job's own installed-gem environment, which no longer exists by the
# time this runs). Deliberately runs after the individual native-gem
# releases and the bundle zip have already been published in the same job --
# both digest sources (NativeGemDigestFetcher, the bundle's own known
# digest) read already-published, already-verified values, nothing here
# re-verifies them.
#
# <native_names_csv> need not include the GTK3 stack -- this script adds
# GemManifestGenerator::GTK3_STACK itself, so the one list lives in exactly
# one place (2026-07-10 review finding: it had drifted into a second,
# separately-hardcoded PowerShell copy; removed).
#
# <bundle_tag> is *this run's own* release tag (draft, live, or
# "-candidate") -- never assumed to be the live tag. Real bug, found in
# review 2026-07-10: hardcoding the live tag here meant a candidate run's
# manifest described its own dist/pkg's package list but pointed at a
# different run's (the live tag's) zip -- two different sets of bytes.
# Promoting a candidate to live is a separate, later step
# (bin/retarget_gem_manifest.rb), not something this script does.
#
# Usage:
#   ruby bin/generate_gem_manifest.rb <native_names_csv> <pure_names_csv> \
#     <ruby_abi> <platform> <repo> <bundle_tag> <bundle_filename> \
#     <bundle_sha256> <pkg_dir> <output_json_path>
#
# Exit status:
#   0 -- success, output_json_path written.
#   1 -- GemManifestGenerator::DigestValidationError (a real, deterministic
#        integrity problem -- a staged pure gem doesn't match RubyGems.org,
#        or RubyGems.org has nothing to check it against),
#        NativeGemDigestFetcher::FetchError (a native release's digest
#        couldn't be read back), InstalledGemClosure::MissingSpecError (a
#        declared native/pure name has no staged .gem file at all), or
#        StagedGemSpecFinder::CorruptGemError (a staged .gem file's own
#        embedded metadata couldn't be read at all) -- do not retry blindly;
#        all four mean something real needs investigation, not a transient
#        blip.
#   2 -- bad ARGV invocation.

require 'json'
require_relative '../lib/ruby4lich5/gem_manifest_generator'
require_relative '../lib/ruby4lich5/native_gem_digest_fetcher'
require_relative '../lib/ruby4lich5/rubygems_client'
require_relative '../lib/ruby4lich5/installed_gem_closure'
require_relative '../lib/ruby4lich5/staged_gem_spec_finder'

ARG_NAMES = %i[native_names_csv pure_names_csv ruby_abi platform repo bundle_tag bundle_filename bundle_sha256
               pkg_dir output_json_path].freeze

if ARGV.size != ARG_NAMES.size
  warn "Usage: #{$PROGRAM_NAME} #{ARG_NAMES.map { |n| "<#{n}>" }.join(' ')}"
  exit 2
end

native_names_csv, pure_names_csv, ruby_abi, platform, repo, bundle_tag, bundle_filename, bundle_sha256, pkg_dir,
  output_json_path = ARGV

native_names = (Ruby4Lich5::GemManifestGenerator::GTK3_STACK + native_names_csv.split(',').map(&:strip).reject(&:empty?)).uniq
# Filtered against the *fully constructed* native_names (GTK3_STACK included),
# not just the caller-supplied native_names_csv -- real gap, found in review
# 2026-07-11: the workflow's own PowerShell side only excludes
# NATIVE_RUNTIME_GEMS members from pure_names, since it has no knowledge of
# GTK3_STACK at all (that constant is deliberately Ruby-only). The real
# runtime-gems default input starts with the bare word "gtk3", which was
# landing in both lists -- GemManifestGenerator#roots already absorbed the
# duplication safely (its own `- GTK3_STACK` subtraction, plus
# InstalledGemClosure's existing request-dedup), so this was never an
# observable bug in generated output, but it left correctness depending on
# two unrelated safety nets instead of a clean boundary here.
pure_names = pure_names_csv.split(',').map(&:strip).reject(&:empty?) - native_names

digest_fetcher = Ruby4Lich5::NativeGemDigestFetcher.new(repo: repo, platform: platform)
closure_resolver = Ruby4Lich5::InstalledGemClosure.new(
  requested_names: native_names + pure_names, find_specs: Ruby4Lich5::StagedGemSpecFinder.new(pkg_dir: pkg_dir)
)

begin
  generator = Ruby4Lich5::GemManifestGenerator.new(
    native_names: native_names,
    pure_names: pure_names,
    ruby_abi: ruby_abi,
    platform: platform,
    repo: repo,
    bundle_asset: { tag: bundle_tag, filename: bundle_filename, sha256: bundle_sha256 },
    pkg_dir: pkg_dir,
    native_digest_lookup: digest_fetcher,
    rubygems_client: Ruby4Lich5::RubygemsClient.new,
    closure_resolver: closure_resolver
  )
  manifest = generator.generate
rescue Ruby4Lich5::GemManifestGenerator::DigestValidationError, Ruby4Lich5::NativeGemDigestFetcher::FetchError,
       Ruby4Lich5::InstalledGemClosure::MissingSpecError, Ruby4Lich5::StagedGemSpecFinder::CorruptGemError => e
  warn "ERROR: #{e.class}: #{e.message}"
  exit 1
end

File.write(output_json_path, JSON.pretty_generate(manifest))
unit_count = manifest['targets'].first['units'].size
puts "Wrote gem recovery manifest (#{unit_count} unit(s)) to #{output_json_path}"
