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

    # Real regression case, per review: an earlier F1 CLI resolved and
    # classified everything against a hardcoded '4.0' ABI constant while
    # only recording whatever ruby_installer_version the caller actually
    # supplied into the lock afterward -- a non-4.0 input (e.g. a real
    # future 4.1.x RubyInstaller release) would silently apply 4.0-series
    # registry/classification policy to a genuinely different Ruby. Not
    # just a hypothetical: ruby_abi is the value #plan_for/
    # #self_build_packages_for must actually be called with for this not
    # to happen, so a passing test here for a plausible non-4.0 release
    # series is the regression guard.
    it 'derives a genuinely non-4.0 series correctly, not just the one series this project ships today' do
      lock = build(ruby_installer_version: '4.1.2-1')

      expect(lock.ruby_abi).to eq('4.1')
    end
  end

  describe '.ruby_abi_for' do
    it 'derives the ABI series without requiring a constructed lock' do
      expect(described_class.ruby_abi_for('4.0.5-1')).to eq('4.0')
    end

    it 'derives a non-4.0 series the same way #ruby_abi does' do
      expect(described_class.ruby_abi_for('4.1.2-1')).to eq('4.1')
    end

    it 'raises ValidationError, not a raw exception, for a malformed installer version' do
      expect { described_class.ruby_abi_for('not-a-version') }
        .to raise_error(described_class::ValidationError, /must look like N\.N\.N-N/)
    end
  end

  describe '#to_h' do
    # closure_entry's own classification default (spec/support/closure_fixtures.rb):
    # gem_name/gem_version match the entry's own name/version (real
    # invariant, enforced by ResolutionLock.deserialize_closure_entry as of
    # 2026-07-13's audit fixes), reason: 'test', no platform_asset/
    # msys2_packages for :pure.
    def pure_classification_hash(name, version)
      { 'state' => 'pure', 'gem_name' => name, 'gem_version' => version, 'reason' => 'test',
        'platform_asset' => nil, 'msys2_packages' => nil }
    end

    it 'serializes every field into the locked schema shape, the full classification, not just state' do
      result = build.to_h

      expect(result).to eq(
        {
          'schema'                 => 1,
          'ruby_installer_version' => '4.0.5-1',
          'platform'               => 'x64-mingw-ucrt',
          'requested_roots'        => { 'root-gem' => '1.0.0' },
          'closure'                => [
            { 'name' => 'dep-gem', 'version' => '2.7.0', 'runtime_dependencies' => [], 'classification' => pure_classification_hash('dep-gem', '2.7.0') },
            { 'name' => 'root-gem', 'version' => '1.0.0',
              'runtime_dependencies' => [{ 'name' => 'dep-gem', 'requirement' => ['>= 2.6'] }],
              'classification' => pure_classification_hash('root-gem', '1.0.0') }
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

    it 'round-trips a real Gem::Requirement as its #as_list form, not an inspected object' do
      closure = [
        closure_entry('dep-gem', '2.7.0'),
        closure_entry('root-gem', '1.0.0', deps: [['dep-gem', '~> 2.6']])
      ]

      result = build(closure: closure).to_h

      expect(result['closure'].last['runtime_dependencies']).to eq([{ 'name' => 'dep-gem', 'requirement' => ['~> 2.6'] }])
    end

    # Real gap, found live while smoke-testing #from_h against a real
    # resolved lock, before this had a real caller: #to_s joins multiple
    # constraints into one comma-separated String (">= 1.1.1, < 4"), which
    # Gem::Requirement.new can't parse back -- BadRequirementError, the
    # whole joined string treated as one illformed constraint. #as_list
    # (an Array of individual constraint strings) is what actually
    # survives the round trip; a single-constraint requirement wouldn't
    # have caught this at all, so this test uses a real multi-constraint
    # one specifically.
    it 'round-trips a real multi-constraint Gem::Requirement -- the exact shape #to_s could not have survived' do
      closure = [
        closure_entry('dep-gem', '2.7.0'),
        closure_entry('root-gem', '1.0.0', deps: [['dep-gem', ['>= 1.1.1', '< 4']]])
      ]

      result = build(closure: closure).to_h
      reconstructed = described_class.from_h(result)

      expect(result['closure'].last['runtime_dependencies']).to eq([{ 'name' => 'dep-gem', 'requirement' => ['>= 1.1.1', '< 4'] }])
      requirement = reconstructed.closure.last.fetch(:runtime_dependencies).first.fetch(:requirement)
      expect(requirement).to eq(Gem::Requirement.new('>= 1.1.1', '< 4'))
    end

    it 'serializes a native_self_contained classification with its full field set, not just state' do
      closure = [closure_entry('root-gem', '1.0.0', state: :native_self_contained, msys2_packages: ['mingw-w64-ucrt-x86_64-example'])]

      result = build(closure: closure, requested_roots: { 'root-gem' => '1.0.0' }).to_h

      expect(result['closure'].first['classification']).to eq(
        { 'state' => 'native_self_contained', 'gem_name' => 'root-gem', 'gem_version' => '1.0.0', 'reason' => 'test',
          'platform_asset' => nil, 'msys2_packages' => ['mingw-w64-ucrt-x86_64-example'] }
      )
    end

    # Real gap, found in review, before this had a real caller: an earlier
    # version only serialized classification.state.to_s -- lossless for a
    # debug JSON dump nothing ever read back, but reconstructing a real
    # Classification from that alone would raise ArgumentError for any
    # state requiring platform_asset/msys2_packages (Classification's own
    # constructor enforces their presence per state). #from_h is the
    # actual "resolve once" cutover's whole reason to exist -- proving a
    # full round trip here, not just that #to_h alone looks right.
    describe '#from_h -- round trip' do
      it 'reconstructs an equivalent lock whose own #to_h matches the original exactly' do
        original = build(closure: valid_closure, requested_roots: { 'root-gem' => '1.0.0' })

        reconstructed = described_class.from_h(original.to_h)

        expect(reconstructed.to_h).to eq(original.to_h)
      end

      it 'reconstructs a real Gem::Requirement, not a String, for every runtime_dependencies edge' do
        closure = [
          closure_entry('dep-gem', '2.7.0'),
          closure_entry('root-gem', '1.0.0', deps: [['dep-gem', '~> 2.6']])
        ]
        original = build(closure: closure, requested_roots: { 'root-gem' => '1.0.0' })

        reconstructed = described_class.from_h(original.to_h)

        requirement = reconstructed.closure.last.fetch(:runtime_dependencies).first.fetch(:requirement)
        expect(requirement).to be_a(Gem::Requirement)
        expect(requirement).to eq(Gem::Requirement.new('~> 2.6'))
      end

      it 'reconstructs a real Classification, not a String, for every closure entry' do
        closure = [closure_entry('root-gem', '1.0.0', state: :native_self_contained, msys2_packages: ['mingw-w64-ucrt-x86_64-example'])]
        original = build(closure: closure, requested_roots: { 'root-gem' => '1.0.0' })

        reconstructed = described_class.from_h(original.to_h)

        classification = reconstructed.closure.first.fetch(:classification)
        expect(classification).to be_a(Ruby4Lich5::Classification)
        expect(classification.self_contained?).to be(true)
        expect(classification.msys2_packages).to eq(['mingw-w64-ucrt-x86_64-example'])
      end

      it 'reconstructs a native_pass_through classification without raising -- the exact shape the old lossy serialization would have broken' do
        closure = [
          closure_entry(
            'root-gem', '1.0.0', state: :native_pass_through, platform_asset: 'root-gem-1.0.0-x64-mingw-ucrt.gem'
          )
        ]
        original = build(closure: closure, requested_roots: { 'root-gem' => '1.0.0' })

        reconstructed = described_class.from_h(original.to_h)

        expect(reconstructed.closure.first.fetch(:classification).platform_asset).to eq('root-gem-1.0.0-x64-mingw-ucrt.gem')
      end

      it 'raises ValidationError for an unrecognized schema version' do
        data = build.to_h.merge('schema' => 99)

        expect { described_class.from_h(data) }
          .to raise_error(described_class::ValidationError, /unrecognized resolution lock schema version: 99/)
      end

      it 'raises ValidationError, not a raw KeyError, for data missing a required top-level key' do
        data = build.to_h.reject { |key, _| key == 'platform' }

        expect { described_class.from_h(data) }
          .to raise_error(described_class::ValidationError, /malformed resolution lock data/)
      end

      it 'raises ValidationError, not a raw KeyError, for a closure entry missing a classification field' do
        data = build.to_h
        data['closure'].first['classification'].delete('reason')

        expect { described_class.from_h(data) }
          .to raise_error(described_class::ValidationError, /malformed resolution lock data/)
      end

      context 'strict deserialization boundary, found in audit 2026-07-13' do
        it 'raises ValidationError, not a raw NoMethodError, for nil top-level data' do
          expect { described_class.from_h(nil) }
            .to raise_error(described_class::ValidationError, /resolution lock data must be an object, got NilClass/)
        end

        it 'raises ValidationError, not a raw NoMethodError, for a non-Hash top-level document (e.g. an Array)' do
          expect { described_class.from_h([1, 2, 3]) }
            .to raise_error(described_class::ValidationError, /resolution lock data must be an object, got Array/)
        end

        it 'raises ValidationError for a non-Hash registry' do
          data = build.to_h.merge('registry' => 'not-an-object')

          expect { described_class.from_h(data) }
            .to raise_error(described_class::ValidationError, /resolution lock 'registry' must be an object, got String/)
        end

        it 'raises ValidationError for a non-Array closure' do
          data = build.to_h.merge('closure' => 'not-an-array')

          expect { described_class.from_h(data) }
            .to raise_error(described_class::ValidationError, /resolution lock 'closure' must be an array, got String/)
        end

        it 'raises ValidationError for a non-Hash closure member' do
          data = build.to_h
          data['closure'][0] = nil

          expect { described_class.from_h(data) }
            .to raise_error(described_class::ValidationError, /closure member must be an object, got NilClass/)
        end

        it 'raises ValidationError for an unrecognized top-level field' do
          data = build.to_h.merge('unexpected_field' => 'surprise')

          expect { described_class.from_h(data) }
            .to raise_error(described_class::ValidationError, /resolution lock data has unrecognized field\(s\): \["unexpected_field"\]/)
        end

        it 'raises ValidationError for an unrecognized field inside a closure member' do
          data = build.to_h
          data['closure'].first['unexpected_field'] = 'surprise'

          expect { described_class.from_h(data) }
            .to raise_error(described_class::ValidationError, /closure member has unrecognized field\(s\): \["unexpected_field"\]/)
        end

        it "raises ValidationError when a classification's gem_name/gem_version disagree with its own enclosing entry" do
          # Reproduced live: a hand-edited (or otherwise corrupted) lock
          # document can carry a classification whose own recorded
          # identity names a completely different gem than the closure
          # entry it's attached to -- nothing before this fix ever
          # cross-checked the two agreed.
          data = build.to_h
          data['closure'].first['classification']['gem_name'] = 'different'

          expect { described_class.from_h(data) }
            .to raise_error(described_class::ValidationError, /classification identity \("different" "2\.7\.0"\) does not match its own enclosing entry \("dep-gem" "2\.7\.0"\)/)
        end

        it 'raises ValidationError, not a raw Gem::Requirement::BadRequirementError, for a malformed dependency requirement' do
          data = build.to_h
          data['closure'].last['runtime_dependencies'].first['requirement'] = ['not a real requirement']

          expect { described_class.from_h(data) }
            .to raise_error(described_class::ValidationError, /malformed resolution lock data/)
        end

        it 'raises ValidationError, not a raw ArgumentError, for a classification with an invalid state field combination' do
          # native_pass_through requires platform_asset present -- a
          # hand-edited lock naming that state with no asset previously
          # let Classification#initialize's own ArgumentError leak straight
          # through .from_h unrescued.
          data = build.to_h
          data['closure'].first['classification']['state'] = 'native_pass_through'

          expect { described_class.from_h(data) }
            .to raise_error(described_class::ValidationError, /malformed resolution lock data/)
        end
      end
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
