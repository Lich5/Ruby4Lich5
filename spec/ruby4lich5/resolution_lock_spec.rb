# frozen_string_literal: true

require 'ruby4lich5/resolution_lock'
require_relative '../support/closure_fixtures'

RSpec.describe Ruby4Lich5::ResolutionLock do
  include ClosureFixtures

  let(:valid_commit_sha) { 'a' * 40 }
  let(:valid_digest) { "sha256:#{'b' * 64}" }
  let(:valid_closure) do
    [
      closure_entry('dep-gem', '2.7.0'),
      closure_entry('root-gem', '1.0.0', deps: [['dep-gem', '>= 2.6']])
    ]
  end

  def build(overrides = {})
    described_class.new(
      **{
        ruby_installer_version: '4.0.5-1', platform: 'x64-mingw-ucrt',
        requested_roots: { 'root-gem' => '1.0.0' }, closure: valid_closure,
        registry_commit_sha: valid_commit_sha, registry_content_digest: valid_digest
      }.merge(overrides)
    )
  end

  describe '#ruby_abi' do
    it 'derives the ABI series from ruby_installer_version, mirroring ruby4-bundled-gems-suite.yml\'s own convention' do
      lock = build(ruby_installer_version: '4.0.5-1')

      expect(lock.ruby_abi).to eq('4.0')
    end

    it 'handles a multi-digit series correctly, not just single digits' do
      lock = build(ruby_installer_version: '10.22.5-1')

      expect(lock.ruby_abi).to eq('10.22')
    end
  end

  describe '#to_h' do
    it 'serializes every field into the locked schema shape' do
      result = build.to_h

      expect(result).to eq(
        {
          'schema'                 => 1,
          'ruby_installer_version' => '4.0.5-1',
          'platform'               => 'x64-mingw-ucrt',
          'requested_roots'        => { 'root-gem' => '1.0.0' },
          'closure'                => [
            { 'name' => 'dep-gem', 'version' => '2.7.0', 'runtime_dependencies' => [], 'classification' => 'pure' },
            { 'name' => 'root-gem', 'version' => '1.0.0',
              'runtime_dependencies' => [{ 'name' => 'dep-gem', 'requirement' => '>= 2.6' }],
              'classification' => 'pure' }
          ],
          'registry'               => { 'commit_sha' => valid_commit_sha, 'content_digest' => valid_digest }
        }
      )
    end

    it 'preserves closure order exactly as given -- trusts, does not re-verify, topological order' do
      reversed = valid_closure.reverse
      result = build(closure: reversed, requested_roots: { 'root-gem' => '1.0.0' }).to_h

      expect(result['closure'].map { |e| e['name'] }).to eq(%w[root-gem dep-gem])
    end

    it 'round-trips a real Gem::Requirement into its String form, not an inspected object' do
      closure = [
        closure_entry('dep-gem', '2.7.0'),
        closure_entry('root-gem', '1.0.0', deps: [['dep-gem', '~> 2.6']])
      ]

      result = build(closure: closure).to_h

      expect(result['closure'].last['runtime_dependencies']).to eq([{ 'name' => 'dep-gem', 'requirement' => '~> 2.6' }])
    end

    it 'serializes a native_self_contained classification with its own state string' do
      closure = [closure_entry('root-gem', '1.0.0', state: :native_self_contained, msys2_packages: ['mingw-w64-ucrt-x86_64-example'])]

      result = build(closure: closure, requested_roots: { 'root-gem' => '1.0.0' }).to_h

      expect(result['closure'].first['classification']).to eq('native_self_contained')
    end
  end

  describe 'validation' do
    it 'accepts a fully valid lock without raising' do
      expect { build }.not_to raise_error
    end

    it 'rejects a blank ruby_installer_version' do
      expect { build(ruby_installer_version: '') }
        .to raise_error(described_class::ValidationError, /ruby_installer_version must look like N\.N\.N-N/)
    end

    it 'rejects a nil ruby_installer_version' do
      expect { build(ruby_installer_version: nil) }
        .to raise_error(described_class::ValidationError, /ruby_installer_version must look like N\.N\.N-N/)
    end

    it 'rejects an unsafe platform token' do
      expect { build(platform: '../etc/passwd') }
        .to raise_error(described_class::ValidationError, /disallowed characters/)
    end

    it 'rejects a registry_commit_sha that is not a full 40-character hex SHA' do
      expect { build(registry_commit_sha: 'abc123') }
        .to raise_error(described_class::ValidationError, /registry_commit_sha must be a full 40-character/)
    end

    it 'rejects an uppercase registry_commit_sha' do
      expect { build(registry_commit_sha: 'A' * 40) }
        .to raise_error(described_class::ValidationError, /registry_commit_sha must be a full 40-character/)
    end

    it 'rejects a malformed registry_content_digest' do
      expect { build(registry_content_digest: 'not-a-digest') }
        .to raise_error(described_class::ValidationError, /registry_content_digest must be a well-formed/)
    end

    it 'rejects an empty requested_roots' do
      expect { build(requested_roots: {}) }
        .to raise_error(described_class::ValidationError, /requested_roots must be a non-empty Hash/)
    end

    it "rejects a requested root whose version is not a real RubyGems version" do
      expect { build(requested_roots: { 'root-gem' => 'not-a-version' }) }
        .to raise_error(described_class::ValidationError, /version must be a valid RubyGems version/)
    end

    it 'rejects an unsafe requested root name' do
      expect { build(requested_roots: { '../etc/passwd' => '1.0.0' }) }
        .to raise_error(described_class::ValidationError, /disallowed characters/)
    end

    it 'rejects an empty closure' do
      # Real bug, found in review: this used to also pass
      # requested_roots: {}, so validation raised on the empty roots check
      # first and the closure-emptiness check itself was never actually
      # exercised. A valid, non-empty requested_roots is kept here so the
      # failure genuinely comes from the empty closure.
      expect { build(closure: []) }
        .to raise_error(described_class::ValidationError, /closure must be a non-empty Array/)
    end

    it 'rejects a closure with duplicate member names' do
      closure = [closure_entry('root-gem', '1.0.0'), closure_entry('root-gem', '1.0.0')]

      expect { build(closure: closure) }
        .to raise_error(described_class::ValidationError, /closure has duplicate member names: \["root-gem"\]/)
    end

    it "rejects a closure member whose classification is not a real Classification" do
      closure = [{ name: 'root-gem', version: '1.0.0', runtime_dependencies: [], classification: 'pure' }]

      expect { build(closure: closure) }
        .to raise_error(described_class::ValidationError, /classification must be a real Classification/)
    end

    it "rejects a closure member whose dependency requirement is not a real Gem::Requirement" do
      closure = [
        closure_entry('dep-gem', '2.7.0'),
        { name: 'root-gem', version: '1.0.0',
          runtime_dependencies: [{ name: 'dep-gem', requirement: '>= 2.6' }],
          classification: classification(:pure) }
      ]

      expect { build(closure: closure) }
        .to raise_error(described_class::ValidationError, /requirement must be a real Gem::Requirement/)
    end

    it "rejects a requested root missing from its own resolved closure -- real bug, mismatched data assembled into one lock" do
      closure = [closure_entry('some-other-gem', '1.0.0')]

      expect { build(closure: closure, requested_roots: { 'root-gem' => '1.0.0' }) }
        .to raise_error(described_class::ValidationError,
                        /requested root\(s\) do not match their own resolved closure: "root-gem": requested "1\.0\.0", closure has nil/)
    end

    it "rejects a requested root whose closure node was resolved at a different version -- real gap, name-only match previously accepted this" do
      closure = [closure_entry('root-gem', '1.0.0')]

      expect { build(closure: closure, requested_roots: { 'root-gem' => '2.0.0' }) }
        .to raise_error(described_class::ValidationError,
                        /"root-gem": requested "2\.0\.0", closure has "1\.0\.0"/)
    end

    it "rejects a closure member's dependency that references a name absent from the closure entirely" do
      closure = [closure_entry('root-gem', '1.0.0', deps: [['not-in-closure', '>= 1.0']])]

      expect { build(closure: closure) }
        .to raise_error(described_class::ValidationError,
                        /root-gem.* depends on "not-in-closure", which is not present anywhere in the resolved closure/)
    end

    it "rejects a closure member's dependency whose resolved version does not satisfy its own recorded requirement" do
      # Real gap, found in review: a locked dep-gem 1.0.0 against a
      # declared >= 5.0 edge previously passed validation silently --
      # confirmed live before this fix existed.
      closure = [
        closure_entry('dep-gem', '1.0.0'),
        closure_entry('root-gem', '1.0.0', deps: [['dep-gem', '>= 5.0']])
      ]

      expect { build(closure: closure) }
        .to raise_error(described_class::ValidationError,
                        /root-gem.*dep-gem.*"1\.0\.0" does not satisfy its own recorded requirement \(>= 5\.0\)/)
    end

    it 'accepts a dependency whose resolved version does satisfy its own recorded requirement' do
      closure = [
        closure_entry('dep-gem', '2.7.0'),
        closure_entry('root-gem', '1.0.0', deps: [['dep-gem', '>= 2.6']])
      ]

      expect { build(closure: closure) }.not_to raise_error
    end

    it 'rejects a closure containing a non-Hash entry with ValidationError, not a raw NoMethodError' do
      # Real bug, found in review: closure: [nil] previously reached
      # entry.fetch(:name) directly and leaked a raw NoMethodError instead
      # of this class's own promised ValidationError boundary.
      expect { build(closure: [nil]) }
        .to raise_error(described_class::ValidationError, /every closure member must be an object, got NilClass/)
    end

    it 'rejects a closure entry missing a required key with ValidationError, not a raw KeyError' do
      closure = [{ name: 'root-gem', version: '1.0.0', classification: classification(:pure) }]

      expect { build(closure: closure) }
        .to raise_error(described_class::ValidationError, /missing required key\(s\): \[:runtime_dependencies\]/)
    end

    it 'rejects a malformed dependency entry (not a Hash) with ValidationError, not a raw NoMethodError' do
      closure = [{ name: 'root-gem', version: '1.0.0', runtime_dependencies: ['not-a-hash'], classification: classification(:pure) }]

      expect { build(closure: closure) }
        .to raise_error(described_class::ValidationError, /malformed dependency entry/)
    end

    it 'rejects a malformed ruby_installer_version -- a bare series is too coarse, not just any non-blank String' do
      expect { build(ruby_installer_version: '4.0') }
        .to raise_error(described_class::ValidationError, /ruby_installer_version must look like N\.N\.N-N/)
    end
  end

  describe 'immutability' do
    it "does not reflect a later mutation of the caller's own requested_roots Hash" do
      roots = { 'root-gem' => '1.0.0' }
      lock = build(requested_roots: roots)
      before = lock.to_h['requested_roots'].dup

      roots['root-gem'] = '9.9.9'

      expect(lock.to_h['requested_roots']).to eq(before)
    end

    it "does not reflect a later mutation of the caller's own closure Array" do
      closure = valid_closure.dup
      lock = build(closure: closure, requested_roots: { 'root-gem' => '1.0.0' })
      before = lock.to_h['closure']

      closure << closure_entry('injected-gem', '1.0.0')

      expect(lock.to_h['closure']).to eq(before)
    end

    it 'raises FrozenError if a caller tries to mutate the returned requested_roots Hash directly' do
      lock = build

      expect { lock.requested_roots['root-gem'] = '9.9.9' }.to raise_error(FrozenError)
    end

    describe 'the four scalar String fields, found in a follow-up CodeRabbit review pass' do
      # Real gap, found in review: only requested_roots/closure went
      # through deep_freeze in the first round -- ruby_installer_version,
      # platform, registry_commit_sha, and registry_content_digest were
      # still stored as the caller's own live String objects. Confirmed
      # live: mutating the caller's original platform String after
      # construction changed what the lock's own #platform reader
      # reported, and mutating the returned registry_commit_sha reader
      # directly succeeded despite the class's own immutable-record
      # contract. Dynamically built with String.new, not frozen literals,
      # for the same reason as the Classification-member regression tests
      # above.
      it 'reports frozen? true for all four scalar fields' do
        lock = build(
          ruby_installer_version: String.new('4.0.5-1'), platform: String.new('x64-mingw-ucrt'),
          registry_commit_sha: String.new(valid_commit_sha), registry_content_digest: String.new(valid_digest)
        )

        expect(lock.ruby_installer_version).to be_frozen
        expect(lock.platform).to be_frozen
        expect(lock.registry_commit_sha).to be_frozen
        expect(lock.registry_content_digest).to be_frozen
      end

      it "does not reflect a later mutation of the caller's own original platform String" do
        platform = String.new('x64-mingw-ucrt')
        lock = build(platform: platform)

        platform << '-MUTATED'

        expect(lock.platform).to eq('x64-mingw-ucrt')
      end

      it 'raises FrozenError mutating the returned registry_commit_sha directly' do
        lock = build(registry_commit_sha: String.new(valid_commit_sha))

        expect { lock.registry_commit_sha << '-x' }.to raise_error(FrozenError)
      end

      it "does not freeze the caller's own original platform/registry_commit_sha Strings in place" do
        platform = String.new('x64-mingw-ucrt')
        commit_sha = String.new(valid_commit_sha)

        build(platform: platform, registry_commit_sha: commit_sha)

        expect(platform).not_to be_frozen
        expect(commit_sha).not_to be_frozen
      end

      it 'a post-construction mutation of any original scalar String changes neither the readers nor #to_h, and leaves every original unfrozen' do
        ruby_installer_version = String.new('4.0.5-1')
        platform = String.new('x64-mingw-ucrt')
        commit_sha = String.new(valid_commit_sha)
        content_digest = String.new(valid_digest)

        lock = build(
          ruby_installer_version: ruby_installer_version, platform: platform,
          registry_commit_sha: commit_sha, registry_content_digest: content_digest
        )

        ruby_installer_version << '-MUTATED'
        platform << '-MUTATED'
        commit_sha << '-MUTATED'
        content_digest << '-MUTATED'

        expect(lock.ruby_installer_version).to eq('4.0.5-1')
        expect(lock.platform).to eq('x64-mingw-ucrt')
        expect(lock.registry_commit_sha).to eq(valid_commit_sha)
        expect(lock.registry_content_digest).to eq(valid_digest)

        result = lock.to_h
        expect(result['ruby_installer_version']).to eq('4.0.5-1')
        expect(result['platform']).to eq('x64-mingw-ucrt')
        expect(result['registry']).to eq({ 'commit_sha' => valid_commit_sha, 'content_digest' => valid_digest })

        expect(ruby_installer_version).not_to be_frozen
        expect(platform).not_to be_frozen
        expect(commit_sha).not_to be_frozen
        expect(content_digest).not_to be_frozen
      end
    end

    it 'raises FrozenError if a caller tries to mutate a returned closure entry directly' do
      lock = build

      expect { lock.closure.first[:version] = '9.9.9' }.to raise_error(FrozenError)
    end

    describe "nested mutability inside Gem::Requirement/Classification, found in CodeRabbit review" do
      # Real gap in the first freeze fix: #dup.freeze on a Gem::Requirement
      # or Classification only froze the *outer* object -- their own
      # internal mutable state (Gem::Requirement#requirements, an Array
      # #requirements returns the same live reference to every call;
      # Classification#msys2_packages) stayed live and mutable even though
      # the outer object already reported frozen? == true. Confirmed live
      # before this fix: mutating requirement.requirements directly changed
      # what an already-"frozen" Gem::Requirement reported afterward.
      it "raises FrozenError mutating a returned closure entry's requirement.requirements directly" do
        lock = build
        requirement = lock.closure.last[:runtime_dependencies].first[:requirement]

        expect { requirement.requirements << ['>=', Gem::Version.new('99.0')] }.to raise_error(FrozenError)
      end

      it "raises FrozenError mutating a returned closure entry's classification.msys2_packages directly" do
        closure = [closure_entry('root-gem', '1.0.0', state: :native_self_contained, msys2_packages: ['mingw-w64-ucrt-x86_64-example'])]
        lock = build(closure: closure, requested_roots: { 'root-gem' => '1.0.0' })
        packages = lock.closure.first[:classification].msys2_packages

        expect { packages << 'injected-package' }.to raise_error(FrozenError)
      end

      it "does not freeze the caller's own original Gem::Requirement object in place" do
        original_requirement = Gem::Requirement.new('>= 1.0')
        closure = [closure_entry('solo-gem', '1.0.0').tap { |e| e[:runtime_dependencies] = [{ name: 'solo-gem', requirement: original_requirement }] }]

        build(closure: closure, requested_roots: { 'solo-gem' => '1.0.0' })

        expect(original_requirement).not_to be_frozen
      end

      it "does not freeze the caller's own original Classification object in place" do
        original_classification = classification(:native_self_contained, msys2_packages: ['mingw-w64-ucrt-x86_64-example'])
        closure = [{ name: 'root-gem', version: '1.0.0', runtime_dependencies: [], classification: original_classification }]

        build(closure: closure, requested_roots: { 'root-gem' => '1.0.0' })

        expect(original_classification).not_to be_frozen
        expect(original_classification.msys2_packages).not_to be_frozen
      end

      describe "every Classification member, not just msys2_packages, found in CodeRabbit review round three" do
        # Real gap: the Classification rebuild only ran msys2_packages
        # through deep_freeze -- gem_name, gem_version, reason, and
        # platform_asset were passed through unchanged, the caller's own
        # live String objects. Confirmed live, twice: mutating the
        # caller's original gem_name after construction changed what the
        # lock's own returned classification reported, and
        # reason.<< succeeded directly through the returned reader despite
        # the outer Classification already reporting frozen? == true.
        # Dynamically built with String.new, not frozen literals -- a
        # literal String under this project's own frozen_string_literal:
        # true pragma would already be frozen regardless of this fix,
        # proving nothing about it.
        let(:mutable_gem_name) { String.new('root-gem') }
        let(:mutable_reason) { String.new('a test reason') }
        let(:mutable_platform_asset) { String.new('root-gem-1.0.0-x64-mingw-ucrt.gem') }

        it 'gem_name/gem_version/reason/platform_asset all report frozen? on the returned classification' do
          original = Ruby4Lich5::Classification.new(
            state: :native_pass_through, gem_name: mutable_gem_name, gem_version: String.new('1.0.0'),
            reason: mutable_reason, platform_asset: mutable_platform_asset
          )
          closure = [{ name: 'root-gem', version: '1.0.0', runtime_dependencies: [], classification: original }]
          lock = build(closure: closure, requested_roots: { 'root-gem' => '1.0.0' })
          returned = lock.closure.first[:classification]

          expect(returned.gem_name).to be_frozen
          expect(returned.gem_version).to be_frozen
          expect(returned.reason).to be_frozen
          expect(returned.platform_asset).to be_frozen
        end

        it "does not reflect a later mutation of the caller's own original gem_name String" do
          original = Ruby4Lich5::Classification.new(state: :pure, gem_name: mutable_gem_name, gem_version: '1.0.0', reason: mutable_reason)
          closure = [{ name: 'root-gem', version: '1.0.0', runtime_dependencies: [], classification: original }]
          lock = build(closure: closure, requested_roots: { 'root-gem' => '1.0.0' })

          mutable_gem_name << '-MUTATED'

          expect(lock.closure.first[:classification].gem_name).to eq('root-gem')
        end

        it "raises FrozenError mutating the returned classification's reason directly" do
          original = Ruby4Lich5::Classification.new(state: :pure, gem_name: 'root-gem', gem_version: '1.0.0', reason: mutable_reason)
          closure = [{ name: 'root-gem', version: '1.0.0', runtime_dependencies: [], classification: original }]
          lock = build(closure: closure, requested_roots: { 'root-gem' => '1.0.0' })

          expect { lock.closure.first[:classification].reason << '-MUTATED' }.to raise_error(FrozenError)
        end

        it "does not freeze the caller's own original gem_name/reason Strings in place" do
          original = Ruby4Lich5::Classification.new(state: :pure, gem_name: mutable_gem_name, gem_version: '1.0.0', reason: mutable_reason)
          closure = [{ name: 'root-gem', version: '1.0.0', runtime_dependencies: [], classification: original }]

          build(closure: closure, requested_roots: { 'root-gem' => '1.0.0' })

          expect(mutable_gem_name).not_to be_frozen
          expect(mutable_reason).not_to be_frozen
        end
      end
    end
  end
end
