#!/usr/bin/env ruby
# frozen_string_literal: true

# CLI entry point for F2's "resolve once" cutover (docs/DECISIONS.md Phase
# 17 SS8, extended) -- the real ruby4-bundled-gems-suite.yml's own
# ruby-gnome-version/runtime-gems dispatch inputs drive exactly one
# resolve pass here, producing both a persisted ResolutionLock and the
# derived MSYS2 package list artifact from that single pass. Every later
# build/stage step in that workflow consumes the persisted lock
# (ResolutionLock.from_h) instead of re-resolving -- see
# NativeGemPreparer#prepare_from_plan and StagedClosureRevalidator, both
# already structurally incapable of a live re-resolve.
#
# Not F1's bin/derive_dynamic_msys2_packages.rb replaced -- that CLI
# stays exactly as it is, fixed-default, proven on a real Windows runner
# (msys2-package-list-diagnostic.yml). This script exists because the
# real shipping workflow's roots are NOT fixed defaults: ruby-gnome-version
# and runtime-gems are real, human-overridable dispatch inputs that must
# drive resolution, not DefaultRootSelection's own hardcoded constants.
# Both scripts share every underlying library class; only root selection
# differs (DefaultRootSelection.resolve_versions's own gtk3_version:/
# runtime_gems: overrides, added for exactly this caller).
#
# cairo-version and native-runtime-gems are deliberately not inputs here
# at all -- retired per the same structural fix DefaultRootSelection
# already established (cairo is never an independent root; native
# handling is derived from the lock's own classifications downstream, not
# a separate hand-maintained list).
#
# **Must run under a real, bootstrapped, target-platform Ruby** -- same
# fail-fast Gem::Platform.local/Gem.platforms assertion as F1's CLI, same
# reasoning (see that script's own header comment for the full mechanism
# note).
#
# Usage:
#   ruby bin/resolve_bundle_lock.rb <registry_path> <registry_commit_sha> <ruby_installer_version> <ruby_gnome_version> <runtime_gems_csv> <lock_output_path> <package_list_output_path>
#
# runtime_gems_csv is comma-separated (matching how the workflow's own
# space-separated dispatch input is normalized before reaching this
# script -- PowerShell's job, not this CLI's, to reformat).
#
# Exit status matches bin/derive_dynamic_msys2_packages.rb's own
# established contract exactly:
#   0 -- success, both output paths written.
#   1 -- possibly transient, worth retrying: ResolutionError (wraps real
#        network failures from rubygems.org), a bad ARGV invocation, or
#        any unrecognized exception.
#   2 -- deterministic, do not retry: a platform-environment assertion
#        failure, IncompleteClosureError, UnbuildableGemError,
#        ClosureMerger::ConflictError, ResolutionLock::ValidationError,
#        RegistryPolicyGate::GateFailure, CuratedGemRegistry::ValidationError,
#        Msys2PackageListArtifact::ValidationError, or
#        DefaultRootSelection::ReservedRootError (runtime_gems_csv named
#        'cairo' explicitly -- never a valid independent root). All
#        operate purely on inputs already resolved (or on a real, fixed
#        environment problem) -- retrying re-runs the exact same check
#        and gets the exact same answer.

require 'json'
require_relative '../lib/ruby4lich5/build_planner'
require_relative '../lib/ruby4lich5/closure_merger'
require_relative '../lib/ruby4lich5/curated_gem_registry'
require_relative '../lib/ruby4lich5/default_root_selection'
require_relative '../lib/ruby4lich5/msys2_bootstrap'
require_relative '../lib/ruby4lich5/msys2_package_list_artifact'
require_relative '../lib/ruby4lich5/registry_policy_gate'
require_relative '../lib/ruby4lich5/resolution_lock'
require_relative '../lib/ruby4lich5/rubygems_client'

ARG_NAMES = %i[
  registry_path registry_commit_sha ruby_installer_version ruby_gnome_version runtime_gems_csv
  lock_output_path package_list_output_path
].freeze

if ARGV.size != ARG_NAMES.size
  warn "Usage: #{$PROGRAM_NAME} #{ARG_NAMES.map { |n| "<#{n}>" }.join(' ')}"
  exit 1
end

registry_path, registry_commit_sha, ruby_installer_version, ruby_gnome_version, runtime_gems_csv,
  lock_output_path, package_list_output_path = ARGV

# Same fail-fast environment assertion as bin/derive_dynamic_msys2_packages.rb
# -- see that script's own header comment for the full mechanism note
# (Gem::Platform.local is the one check that can't be spoofed by a
# Gem.platforms mutation on a host Ruby; Gem.platforms is retained as a
# secondary consistency check).
unless Gem::Platform.local.to_s == Ruby4Lich5::DefaultRootSelection::PLATFORM &&
       Gem.platforms.map(&:to_s).include?(Ruby4Lich5::DefaultRootSelection::PLATFORM)
  warn "FATAL: this process is not a genuine bootstrapped #{Ruby4Lich5::DefaultRootSelection::PLATFORM.inspect} " \
       "Ruby -- Gem::Platform.local is #{Gem::Platform.local.to_s.inspect}, Gem.platforms is " \
       "#{Gem.platforms.map(&:to_s).inspect}. Must run under a real bootstrapped target Ruby, not a host Ruby " \
       '(mutating Gem.platforms manually is not a valid substitute -- Gem::Platform.local cannot be overridden ' \
       'the same way, which is exactly why it is checked here).'
  exit 2
end

begin
  ruby_abi = Ruby4Lich5::ResolutionLock.ruby_abi_for(ruby_installer_version)

  # gtk3 filtered out here -- real gap, found in review, before this had
  # a real caller: the actual workflow's own runtime-gems dispatch input
  # includes 'gtk3' by default (it is genuinely a top-level Lich runtime
  # gem, installed later alongside every other one), but
  # DefaultRootSelection.resolve_versions's own gtk3_version: parameter is
  # the *only* correct source for gtk3's version -- passing 'gtk3' through
  # runtime_gems: too would resolve it a *second* time via
  # RubygemsClient#latest_version, and {'gtk3' => gtk3_version}.merge(...)
  # would let that second, wrong resolution silently overwrite the
  # intended pinned version. Confirmed live before fixing: an
  # unfiltered pass-through produced a requested_roots['gtk3'] that
  # matched rubygems.org's current latest release, not ruby_gnome_version.
  # An empty result is valid -- a real GTK3-only dispatch (a runtime-gems
  # input naming only "gtk3"). Real gap, found in audit 2026-07-13: this
  # used to reject that case outright; DefaultRootSelection.resolve_versions
  # already handles it correctly on its own (requested_roots collapses to
  # just {'gtk3' => gtk3_version}, still a valid non-empty ResolutionLock
  # -- see ResolutionLock#validate_requested_roots!).
  #
  # 'cairo' is deliberately NOT filtered out here the way 'gtk3' is --
  # DefaultRootSelection.resolve_versions itself now rejects it explicitly
  # (ReservedRootError, below) rather than this CLI silently dropping a
  # real user/dispatch mistake.
  runtime_gems = runtime_gems_csv.split(',').map(&:strip).reject(&:empty?).reject { |name| name == 'gtk3' }

  rubygems_client = Ruby4Lich5::RubygemsClient.new
  requested_roots = Ruby4Lich5::DefaultRootSelection.resolve_versions(
    rubygems_client: rubygems_client, gtk3_version: ruby_gnome_version, runtime_gems: runtime_gems
  )

  planner = Ruby4Lich5::BuildPlanner.new
  root_plans = requested_roots.to_h do |name, version|
    [name, planner.plan_for(
      name, version, platform: Ruby4Lich5::DefaultRootSelection::PLATFORM, ruby_abi: ruby_abi
    )]
  end

  closure = Ruby4Lich5::ClosureMerger.new.merge(root_plans)

  registry = Ruby4Lich5::CuratedGemRegistry.load_file(registry_path)

  lock = Ruby4Lich5::ResolutionLock.new(
    ruby_installer_version: ruby_installer_version, platform: Ruby4Lich5::DefaultRootSelection::PLATFORM,
    requested_roots: requested_roots, closure: closure,
    registry_commit_sha: registry_commit_sha, registry_content_digest: registry.content_digest
  )

  Ruby4Lich5::RegistryPolicyGate.new(registry: registry, registry_commit_sha: registry_commit_sha).check!(lock)

  gem_specific_packages = closure
                          .reject { |entry| entry.fetch(:classification).ruby_bundled? }
                          .flat_map { |entry| registry.self_build_packages_for(entry.fetch(:name), ruby_abi: ruby_abi) || [] }

  all_packages = (Ruby4Lich5::Msys2Bootstrap::PACKAGES + gem_specific_packages).uniq.sort

  artifact = Ruby4Lich5::Msys2PackageListArtifact.new(all_packages)

  # Both writes inside the protected region -- same reasoning as
  # bin/derive_dynamic_msys2_packages.rb's own fix: a real write failure
  # here (bad output directory, permissions, full disk) must be caught
  # and formatted per this CLI's own documented contract, not leak a raw
  # exception past every rescue clause below.
  File.write(lock_output_path, "#{JSON.pretty_generate(lock.to_h)}\n")
  File.binwrite(package_list_output_path, artifact.to_json_bytes)
  puts "Wrote resolution lock to #{lock_output_path}"
  puts "Wrote #{artifact.packages.size} package(s) to #{package_list_output_path}"
rescue Ruby4Lich5::ClosureResolver::ResolutionError, Ruby4Lich5::RubygemsClient::RequestError => e
  warn "ERROR: #{e.class}: #{e.message}"
  exit 1
rescue Ruby4Lich5::ClosureResolver::IncompleteClosureError,
       Ruby4Lich5::BuildPlanner::UnbuildableGemError,
       Ruby4Lich5::ClosureMerger::ConflictError,
       Ruby4Lich5::CuratedGemRegistry::ValidationError,
       Ruby4Lich5::ResolutionLock::ValidationError,
       Ruby4Lich5::RegistryPolicyGate::GateFailure,
       Ruby4Lich5::Msys2PackageListArtifact::ValidationError,
       Ruby4Lich5::DefaultRootSelection::ReservedRootError => e
  warn "ERROR: #{e.class}: #{e.message}"
  exit 2
rescue StandardError => e
  warn "ERROR: #{e.class}: #{e.message}"
  exit 1
end
