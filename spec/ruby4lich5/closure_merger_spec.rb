# frozen_string_literal: true

require 'ruby4lich5/closure_merger'
require_relative '../support/closure_fixtures'

RSpec.describe Ruby4Lich5::ClosureMerger do
  include ClosureFixtures

  describe '#merge' do
    it 'returns a single entry when only one root is given' do
      root_plans = { 'root-gem' => [closure_entry('root-gem', '1.0.0')] }

      result = described_class.new.merge(root_plans)

      expect(result.map { |e| e[:name] }).to eq(['root-gem'])
    end

    it 'deduplicates a gem reached from two different roots into a single entry' do
      shared = closure_entry('shared-dep', '2.0.0')
      root_plans = {
        'root-a' => [closure_entry('root-a', '1.0.0'), shared],
        'root-b' => [closure_entry('root-b', '1.0.0'), shared]
      }

      result = described_class.new.merge(root_plans)

      expect(result.map { |e| e[:name] }).to contain_exactly('root-a', 'root-b', 'shared-dep')
    end

    it 'raises ConflictError when the same gem name resolves to a different version across roots' do
      root_plans = {
        'root-a' => [closure_entry('shared-dep', '1.0.0')],
        'root-b' => [closure_entry('shared-dep', '2.0.0')]
      }

      expect { described_class.new.merge(root_plans) }
        .to raise_error(described_class::ConflictError, /shared-dep: conflicting version.*"1\.0\.0".*"2\.0\.0"/)
    end

    it 'raises ConflictError when the same gem name classifies differently across roots' do
      root_plans = {
        'root-a' => [closure_entry('shared-dep', '1.0.0', state: :pure)],
        'root-b' => [closure_entry('shared-dep', '1.0.0', state: :native_self_contained, msys2_packages: ['pkg'])]
      }

      expect { described_class.new.merge(root_plans) }
        .to raise_error(described_class::ConflictError, /shared-dep: conflicting classification.*:pure.*:native_self_contained/)
    end

    # Real gap, found in review: the classification-conflict check compared
    # only Classification#state, so two roots resolving the same
    # gem+version to the identical *state* but different msys2_packages
    # (or any other Classification field) silently merged -- an arbitrary
    # first-wins pick, discarding whichever root's own msys2_packages
    # value didn't happen to be merged first. Independent of the
    # state-mismatch case above: same state here, only the package list
    # differs.
    it 'raises ConflictError when the same gem name/version/state resolves to different msys2_packages across roots' do
      root_plans = {
        'root-a' => [closure_entry('shared-dep', '1.0.0', state: :native_self_contained, msys2_packages: ['pkg-a'])],
        'root-b' => [closure_entry('shared-dep', '1.0.0', state: :native_self_contained, msys2_packages: ['pkg-b'])]
      }

      expect { described_class.new.merge(root_plans) }
        .to raise_error(described_class::ConflictError, /shared-dep: conflicting classification/)
    end

    it 'preserves runtime_dependencies on every merged entry' do
      root_plans = { 'root-gem' => [closure_entry('root-gem', '1.0.0', deps: [['dep-gem', '>= 2.6']])] }

      result = described_class.new.merge(root_plans)

      expect(result.first[:runtime_dependencies]).to eq([{ name: 'dep-gem', requirement: Gem::Requirement.new('>= 2.6') }])
    end

    # Real gap, found in review: version/classification conflicts were
    # checked, but a same name/version/state entry reached from two roots
    # with genuinely different runtime_dependencies was silently accepted
    # as an arbitrary first-wins merge -- the second root's own real
    # dependency edges were discarded with no error, even though
    # ResolutionLock's own dependency-satisfaction check (and any later
    # revalidation built on it) trusts whatever a merged closure entry
    # claims.
    it 'raises ConflictError when the same name/version/state resolves to different runtime_dependencies across roots' do
      root_plans = {
        'root-a' => [closure_entry('shared-dep', '1.0.0', deps: [['dep-x', '>= 1.0']])],
        'root-b' => [closure_entry('shared-dep', '1.0.0', deps: [['dep-y', '>= 2.0']])]
      }

      expect { described_class.new.merge(root_plans) }
        .to raise_error(described_class::ConflictError, /shared-dep: conflicting runtime_dependencies/)
    end

    it 'does not raise when the same runtime_dependencies are merely listed in a different order' do
      root_plans = {
        'root-a' => [closure_entry('shared-dep', '1.0.0', deps: [['dep-x', '>= 1.0'], ['dep-y', '>= 2.0']])],
        'root-b' => [closure_entry('shared-dep', '1.0.0', deps: [['dep-y', '>= 2.0'], ['dep-x', '>= 1.0']])]
      }

      result = described_class.new.merge(root_plans)

      expect(result.map { |e| e[:name] }).to eq(['shared-dep'])
    end
  end
end
