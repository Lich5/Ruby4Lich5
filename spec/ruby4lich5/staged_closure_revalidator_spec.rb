# frozen_string_literal: true

require 'ruby4lich5/staged_closure_revalidator'
require 'ruby4lich5/resolution_lock'
require 'ruby4lich5/classification'

RSpec.describe Ruby4Lich5::StagedClosureRevalidator do
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

  def lock(closure:, requested_roots: nil)
    requested_roots ||= { closure.first.fetch(:name) => closure.first.fetch(:version) }
    Ruby4Lich5::ResolutionLock.new(
      ruby_installer_version: '4.0.5-1', platform: 'x64-mingw-ucrt', requested_roots: requested_roots, closure: closure,
      registry_commit_sha: 'a' * 40, registry_content_digest: "sha256:#{'b' * 64}"
    )
  end

  describe '#revalidate!' do
    it 'passes when the non-ruby_bundled member is staged at the exact locked version, ruby_bundled is unused' do
      closure = [closure_entry('root-gem', '1.0.0', state: :pure)]
      revalidator = described_class.new(
        lock: lock(closure: closure), staged_member_versions: { 'root-gem' => '1.0.0' }, default_gem_versions: {}
      )

      expect { revalidator.revalidate! }.not_to raise_error
    end

    it 'raises when a non-ruby_bundled member is locked but not staged at all' do
      closure = [closure_entry('root-gem', '1.0.0', state: :pure)]
      revalidator = described_class.new(lock: lock(closure: closure), staged_member_versions: {}, default_gem_versions: {})

      expect { revalidator.revalidate! }
        .to raise_error(described_class::RevalidationFailure, /"root-gem": locked "1\.0\.0" but not staged/)
    end

    it 'raises when a non-ruby_bundled member is staged at a different version than locked' do
      closure = [closure_entry('root-gem', '1.0.0', state: :pure)]
      revalidator = described_class.new(
        lock: lock(closure: closure), staged_member_versions: { 'root-gem' => '2.0.0' }, default_gem_versions: {}
      )

      expect { revalidator.revalidate! }
        .to raise_error(described_class::RevalidationFailure, /"root-gem": locked "1\.0\.0", staged "2\.0\.0"/)
    end

    it 'raises when something is staged that is not in the resolved closure at all' do
      closure = [closure_entry('root-gem', '1.0.0', state: :pure)]
      revalidator = described_class.new(
        lock: lock(closure: closure), staged_member_versions: { 'root-gem' => '1.0.0', 'extra-gem' => '3.0.0' },
        default_gem_versions: {}
      )

      expect { revalidator.revalidate! }
        .to raise_error(described_class::RevalidationFailure,
                        /"extra-gem": staged but not present in the resolved closure's non-ruby_bundled members/)
    end

    it 'never compares a ruby_bundled member against staged files at all' do
      closure = [closure_entry('json', '2.7.1', state: :ruby_bundled)]
      revalidator = described_class.new(
        lock: lock(closure: closure), staged_member_versions: {}, default_gem_versions: { 'json' => '2.7.1' }
      )

      expect { revalidator.revalidate! }.not_to raise_error
    end

    it 'raises when a ruby_bundled member is not present as a default gem in the bootstrapped Ruby at all' do
      closure = [closure_entry('json', '2.7.1', state: :ruby_bundled)]
      revalidator = described_class.new(lock: lock(closure: closure), staged_member_versions: {}, default_gem_versions: {})

      expect { revalidator.revalidate! }
        .to raise_error(described_class::RevalidationFailure,
                        /"json": locked as a ruby_bundled default gem, but not present as a default gem in the bootstrapped Ruby/)
    end

    it "raises when a ruby_bundled member's actual bootstrapped version does not satisfy its own recorded requirement" do
      # The locked json version (2.7.1) genuinely satisfies its own edge
      # (>= 2.0) -- ResolutionLock's own construction already guarantees
      # that internal self-consistency (a lock that failed it could never
      # be built at all). What this class exists to catch is real drift
      # *between* the lock and reality: the bootstrapped Ruby this run
      # actually got shipped with an older json (1.8.0) that no longer
      # satisfies the same requirement the lock recorded.
      closure = [
        closure_entry('json', '2.7.1', state: :ruby_bundled),
        closure_entry('root-gem', '1.0.0', state: :pure, deps: [['json', '>= 2.0']])
      ]
      revalidator = described_class.new(
        lock: lock(closure: closure, requested_roots: { 'root-gem' => '1.0.0' }),
        staged_member_versions: { 'root-gem' => '1.0.0' }, default_gem_versions: { 'json' => '1.8.0' }
      )

      expect { revalidator.revalidate! }
        .to raise_error(described_class::RevalidationFailure,
                        /"json": bootstrapped default-gem version "1\.8\.0" does not satisfy the recorded requirement \(>= 2\.0\)/)
    end

    it 'checks every requirement recorded against a ruby_bundled member from every root that names it, not just one' do
      # Real gap, found in review: the previous version used the same
      # default_gem_versions value (2.7.1) that satisfied *both* roots'
      # requirements, which a buggy implementation checking only the
      # first-found requirement would also have passed -- proving nothing
      # about "every" requirement actually being checked. json's own
      # *locked* version (2.7.1) still satisfies both edges, as it must
      # (ResolutionLock's own construction already guarantees that
      # internal consistency); what's real drift here is the bootstrapped
      # Ruby's *actual* json (3.1.0) -- satisfies root-a's >= 2.0, but
      # violates root-b's < 3.0, so this only fails if both edges are
      # genuinely checked, not just whichever was found first.
      closure = [
        closure_entry('json', '2.7.1', state: :ruby_bundled),
        closure_entry('root-a', '1.0.0', state: :pure, deps: [['json', '>= 2.0']]),
        closure_entry('root-b', '1.0.0', state: :pure, deps: [['json', '< 3.0']])
      ]
      revalidator = described_class.new(
        lock: lock(closure: closure, requested_roots: { 'root-a' => '1.0.0', 'root-b' => '1.0.0' }),
        staged_member_versions: { 'root-a' => '1.0.0', 'root-b' => '1.0.0' }, default_gem_versions: { 'json' => '3.1.0' }
      )

      expect { revalidator.revalidate! }
        .to raise_error(described_class::RevalidationFailure,
                        /"json": bootstrapped default-gem version "3\.1\.0" does not satisfy the recorded requirement \(< 3\.0\)/)
    end

    it 'collects every violation, not just the first' do
      closure = [
        closure_entry('json', '2.7.1', state: :ruby_bundled),
        closure_entry('root-gem', '1.0.0', state: :pure, deps: [['json', '>= 2.0']])
      ]
      revalidator = described_class.new(
        lock: lock(closure: closure, requested_roots: { 'root-gem' => '1.0.0' }),
        staged_member_versions: {}, default_gem_versions: { 'json' => '1.8.0' }
      )

      expect { revalidator.revalidate! }.to raise_error(described_class::RevalidationFailure) { |error|
        expect(error.message).to include('"root-gem": locked "1.0.0" but not staged')
        expect(error.message).to include('"json": bootstrapped default-gem version "1.8.0" does not satisfy')
      }
    end
  end

  describe 'inventory validation, found in review' do
    # Real gap: both inventories were previously trusted as-is. A nil
    # default_gem_versions leaked a raw NoMethodError, and a malformed
    # version string leaked a raw ArgumentError from Gem::Version deep
    # inside Gem::Requirement#satisfied_by? -- both confirmed live, both
    # past this class's own promised RevalidationFailure boundary.
    let(:bundled_closure) { [closure_entry('json', '2.7.1', state: :ruby_bundled)] }

    it 'raises RevalidationFailure for a nil default_gem_versions, not a raw NoMethodError' do
      expect { described_class.new(lock: lock(closure: bundled_closure), staged_member_versions: {}, default_gem_versions: nil) }
        .to raise_error(described_class::RevalidationFailure, /default_gem_versions must be a Hash, got NilClass/)
    end

    it 'raises RevalidationFailure for a nil staged_member_versions, not a raw NoMethodError' do
      closure = [closure_entry('root-gem', '1.0.0', state: :pure)]

      expect { described_class.new(lock: lock(closure: closure), staged_member_versions: nil, default_gem_versions: {}) }
        .to raise_error(described_class::RevalidationFailure, /staged_member_versions must be a Hash, got NilClass/)
    end

    it 'raises RevalidationFailure for a non-Hash inventory (e.g. an Array), not a raw NoMethodError' do
      expect { described_class.new(lock: lock(closure: bundled_closure), staged_member_versions: {}, default_gem_versions: []) }
        .to raise_error(described_class::RevalidationFailure, /default_gem_versions must be a Hash, got Array/)
    end

    it 'raises RevalidationFailure for a malformed version string, not a raw ArgumentError from Gem::Version' do
      expect {
        described_class.new(lock: lock(closure: bundled_closure), staged_member_versions: {}, default_gem_versions: { 'json' => 'not-a-version' })
      }.to raise_error(described_class::RevalidationFailure, /default_gem_versions\["json"\] must be a valid, non-blank RubyGems version, got "not-a-version"/)
    end

    it 'raises RevalidationFailure for a blank version string' do
      expect {
        described_class.new(lock: lock(closure: bundled_closure), staged_member_versions: {}, default_gem_versions: { 'json' => '' })
      }.to raise_error(described_class::RevalidationFailure, /default_gem_versions\["json"\] must be a valid, non-blank RubyGems version/)
    end

    it 'raises RevalidationFailure for an unsafe inventory name (path traversal)' do
      expect {
        described_class.new(lock: lock(closure: bundled_closure), staged_member_versions: {}, default_gem_versions: { '../etc/passwd' => '1.0.0' })
      }.to raise_error(described_class::RevalidationFailure, /disallowed characters/)
    end
  end

  describe 'never resolves again during staging, per review' do
    it "this class's own source file never requires or references ClosureResolver or RubygemsClient in real code" do
      # Real gap in an earlier version of this test, found in review: it
      # only rejected require lines. A future direct
      # Ruby4Lich5::ClosureResolver.new(...) call inside a method body
      # needs no local require at all if some other already-loaded
      # application file required it first -- Ruby's own require is
      # process-global, not file-scoped -- so a require-only check would
      # have stayed green even with a live re-resolve wired directly into
      # this class. Checks two separate things now: require lines
      # (snake_case file paths -- 'closure_resolver'/'rubygems_client')
      # *and* actual code lines for the bare PascalCase class names
      # (ClosureResolver/RubygemsClient) a direct reference would use --
      # comments excluded from the second check (full-line comments only;
      # confirmed this file has no code-with-trailing-comment lines to
      # worry about) -- the file's own doc comment deliberately avoids
      # naming either class by class name (see review round two, same
      # reasoning: a comment naming them could itself trip a naive
      # bare-text version of this exact check), but excluding comments
      # here keeps this test robust even if a future doc comment there
      # ever does need to name them directly.
      source = File.read(File.expand_path('../../lib/ruby4lich5/staged_closure_revalidator.rb', __dir__))
      require_lines = source.lines.grep(/^\s*require(_relative)?\s/)
      code_lines = source.lines.reject { |line| line.strip.start_with?('#') }

      expect(require_lines.join).not_to match(/closure_resolver|rubygems_client/i)
      expect(code_lines.join).not_to match(/\bClosureResolver\b|\bRubygemsClient\b/)
    end
  end
end
