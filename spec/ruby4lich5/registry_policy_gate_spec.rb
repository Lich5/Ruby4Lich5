# frozen_string_literal: true

require 'ruby4lich5/registry_policy_gate'
require 'ruby4lich5/resolution_lock'
require 'ruby4lich5/curated_gem_registry'
require 'ruby4lich5/classification'

RSpec.describe Ruby4Lich5::RegistryPolicyGate do
  let(:valid_commit_sha) { 'a' * 40 }
  let(:valid_digest) { "sha256:#{'b' * 64}" }

  def classification(state, **overrides)
    Ruby4Lich5::Classification.new(state: state, gem_name: 'unused', gem_version: '1.0.0', reason: 'test', **overrides)
  end

  def closure_entry(name, version, state: :pure, deps: [], **classification_overrides)
    {
      name: name, version: version,
      runtime_dependencies: deps.map { |dep_name, req| { name: dep_name, requirement: Gem::Requirement.new(req || '>= 0') } },
      classification: classification(state, **classification_overrides)
    }
  end

  # Defaults to the exact identity `lock` below defaults to, so most tests
  # describe the gate being given the right registry -- tests that need a
  # mismatch override commit_sha:/content_digest: explicitly.
  def registry(gems, content_digest: valid_digest)
    Ruby4Lich5::CuratedGemRegistry.new({ 'schema' => 2, 'gems' => gems }, content_digest: content_digest)
  end

  def registry_entry(classification_state, bundle_default: true, platform: 'x64-mingw-ucrt', ruby_abi: '4.0', **target_overrides)
    target = { 'expected_classification' => classification_state }
             .merge(target_overrides.transform_keys(&:to_s))
    { 'approval' => 'approved', 'bundle_default' => bundle_default, 'targets' => { platform => { ruby_abi => target } } }
  end

  def lock(closure:, requested_roots: nil, registry_commit_sha: valid_commit_sha, registry_content_digest: valid_digest)
    requested_roots ||= { closure.first.fetch(:name) => closure.first.fetch(:version) }
    Ruby4Lich5::ResolutionLock.new(
      ruby_installer_version: '4.0.5-1', platform: 'x64-mingw-ucrt', requested_roots: requested_roots, closure: closure,
      registry_commit_sha: registry_commit_sha, registry_content_digest: registry_content_digest
    )
  end

  def gate(registry_double, registry_commit_sha: valid_commit_sha)
    described_class.new(registry: registry_double, registry_commit_sha: registry_commit_sha)
  end

  describe '#check!' do
    it 'passes when every non-ruby_bundled member is approved and classified exactly as observed' do
      registry_double = registry({ 'root-gem' => registry_entry('pure') })

      expect { gate(registry_double).check!(lock(closure: [closure_entry('root-gem', '1.0.0', state: :pure)])) }.not_to raise_error
    end

    it 'skips ruby_bundled members entirely -- never checked against the registry, even though they have no entry at all' do
      registry_double = registry({})
      closure = [closure_entry('json', '2.7.1', state: :ruby_bundled)]

      expect { gate(registry_double).check!(lock(closure: closure)) }.not_to raise_error
    end

    it 'raises GateFailure naming an unknown gem -- no registry entry at all for this target' do
      registry_double = registry({})

      expect { gate(registry_double).check!(lock(closure: [closure_entry('root-gem', '1.0.0', state: :pure)])) }
        .to raise_error(described_class::GateFailure, /"root-gem": unknown -- no approved registry entry for x64-mingw-ucrt\/4\.0/)
    end

    it "raises GateFailure for a gem approved only for a different platform -- 'unknown' for this run's exact target" do
      registry_double = registry({ 'root-gem' => registry_entry('pure', platform: 'arm64-darwin') })

      expect { gate(registry_double).check!(lock(closure: [closure_entry('root-gem', '1.0.0', state: :pure)])) }
        .to raise_error(described_class::GateFailure, /"root-gem": unknown/)
    end

    it 'raises GateFailure naming classification drift -- observed no longer matches the registry expectation' do
      registry_double = registry({ 'root-gem' => registry_entry('native_self_contained', msys2_packages: ['mingw-w64-ucrt-x86_64-example']) })
      closure = [closure_entry('root-gem', '1.0.0', state: :native_pass_through, platform_asset: 'root-gem-1.0.0-x64-mingw-ucrt.gem')]

      expect { gate(registry_double).check!(lock(closure: closure)) }
        .to raise_error(described_class::GateFailure,
                        /"root-gem": classification drift -- registry expects "native_self_contained", this run observed "native_pass_through"/)
    end

    it 'collects every violation, not just the first' do
      registry_double = registry({ 'root-gem' => registry_entry('pure') })
      closure = [
        closure_entry('root-gem', '1.0.0', state: :native_self_contained, msys2_packages: ['pkg']),
        closure_entry('unknown-gem', '1.0.0', state: :pure)
      ]

      expect { gate(registry_double).check!(lock(closure: closure, requested_roots: { 'root-gem' => '1.0.0' })) }
        .to raise_error(described_class::GateFailure) { |error|
          expect(error.message).to include('"root-gem": classification drift')
          expect(error.message).to include('"unknown-gem": unknown')
        }
    end
  end

  describe 'registry identity binding, found in review' do
    # Real gap: nothing previously stopped evaluating a lock against a
    # *different* registry than the one it actually claims was in effect
    # -- confirmed live before this fix, a registry with a completely
    # different digest than the lock recorded was accepted silently.
    it "raises GateFailure when the registry's content_digest does not match the lock's, even though every gem would otherwise pass" do
      registry_double = registry({ 'root-gem' => registry_entry('pure') }, content_digest: "sha256:#{'c' * 64}")

      expect { gate(registry_double).check!(lock(closure: [closure_entry('root-gem', '1.0.0', state: :pure)])) }
        .to raise_error(described_class::GateFailure, /registry passed to this gate does not match the registry this lock was resolved against/)
    end

    it "raises GateFailure when the gate's registry_commit_sha does not match the lock's" do
      registry_double = registry({ 'root-gem' => registry_entry('pure') })

      expect { gate(registry_double, registry_commit_sha: 'f' * 40).check!(lock(closure: [closure_entry('root-gem', '1.0.0', state: :pure)])) }
        .to raise_error(described_class::GateFailure, /registry passed to this gate does not match the registry this lock was resolved against/)
    end

    it 'checks identity before evaluating any individual gem -- a mismatch fails even when the registry is otherwise empty and would have flagged every gem as unknown anyway' do
      registry_double = registry({}, content_digest: "sha256:#{'c' * 64}")

      expect { gate(registry_double).check!(lock(closure: [closure_entry('root-gem', '1.0.0', state: :pure)])) }
        .to raise_error(described_class::GateFailure, /registry passed to this gate does not match/)
    end
  end
end
