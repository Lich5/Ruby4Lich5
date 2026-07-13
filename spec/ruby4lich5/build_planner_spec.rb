# frozen_string_literal: true

require 'ruby4lich5/build_planner'

RSpec.describe Ruby4Lich5::BuildPlanner do
  let(:closure_resolver) { instance_double(Ruby4Lich5::ClosureResolver) }
  let(:classifier) { instance_double(Ruby4Lich5::Classifier) }
  let(:manifest) { instance_double(Ruby4Lich5::CurationManifest) }
  let(:planner) { described_class.new(closure_resolver: closure_resolver, classifier: classifier, manifest: manifest) }

  def pure_classification(name, version)
    Ruby4Lich5::Classification.new(state: :pure, gem_name: name, gem_version: version, reason: 'no native extensions')
  end

  def unbuildable_classification(name, version)
    Ruby4Lich5::Classification.new(
      state: :native_needs_system_lib, gem_name: name, gem_version: version, reason: 'no known way to vendor libfoo'
    )
  end

  # Matches the real Ruby4Lich5::ClosureResolver#resolve_closure output
  # shape from PR C onward -- runtime_dependencies (real Gem::Requirement
  # per edge) alongside the existing name-only field. BuildPlanner#plan_for
  # now carries both through (PR F1); a stub node missing
  # runtime_dependencies would raise a real KeyError against the actual
  # implementation, not a theoretical concern.
  def node(name, version, deps = [])
    { name: name, version: version,
      runtime_dependencies: deps.map { |dep_name| { name: dep_name, requirement: Gem::Requirement.default } },
      runtime_dependency_names: deps }
  end

  describe '#plan_for' do
    context 'when the whole closure is already satisfied by the curation manifest' do
      it 'returns an empty plan without classifying anything' do
        allow(closure_resolver).to receive(:resolve_closure).with('sqlite3', '1.7.3')
                                                            .and_return([node('sqlite3', '1.7.3')])
        allow(manifest).to receive(:satisfied?).with('sqlite3', '1.7.3', 'x64-mingw-ucrt').and_return(true)
        expect(classifier).not_to receive(:classify)

        result = planner.plan_for('sqlite3', '1.7.3', platform: 'x64-mingw-ucrt', ruby_abi: '4.0')

        expect(result).to eq([])
      end
    end

    context 'with a dependency chain where only the leaf needs building' do
      it 'omits the satisfied dependent and plans only the unsatisfied leaf' do
        closure = [
          node('unicode-display_width', '2.6.0'),
          node('terminal-table', '3.0.2', ['unicode-display_width'])
        ]
        allow(closure_resolver).to receive(:resolve_closure).with('terminal-table', '3.0.2').and_return(closure)
        allow(manifest).to receive(:satisfied?).with('unicode-display_width', '2.6.0', 'x64-mingw-ucrt')
                                               .and_return(false)
        allow(manifest).to receive(:satisfied?).with('terminal-table', '3.0.2', 'x64-mingw-ucrt').and_return(true)
        allow(classifier).to receive(:classify)
          .with(name: 'unicode-display_width', version: '2.6.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0')
          .and_return(pure_classification('unicode-display_width', '2.6.0'))

        result = planner.plan_for('terminal-table', '3.0.2', platform: 'x64-mingw-ucrt', ruby_abi: '4.0')

        expect(result.map { |entry| entry[:name] }).to eq(['unicode-display_width'])
        expect(result.first[:runtime_dependency_names]).to eq([])
        expect(result.first[:runtime_dependencies]).to eq([])
        expect(classifier).not_to have_received(:classify).with(hash_including(name: 'terminal-table'))
      end
    end

    context 'when a gem in the closure classifies as native-needs-system-lib' do
      it 'raises UnbuildableGemError naming the gem and reason, failing the whole request' do
        closure = [node('gtk3', '4.3.7')]
        allow(closure_resolver).to receive(:resolve_closure).with('gtk3', '4.3.7').and_return(closure)
        allow(manifest).to receive(:satisfied?).with('gtk3', '4.3.7', 'x64-mingw-ucrt').and_return(false)
        allow(classifier).to receive(:classify)
          .with(name: 'gtk3', version: '4.3.7', platform: 'x64-mingw-ucrt', ruby_abi: '4.0')
          .and_return(unbuildable_classification('gtk3', '4.3.7'))

        expect { planner.plan_for('gtk3', '4.3.7', platform: 'x64-mingw-ucrt', ruby_abi: '4.0') }
          .to raise_error(described_class::UnbuildableGemError, /gtk3 4\.3\.7.*no known way to vendor libfoo/)
      end
    end

    context 'when every gem in the closure needs building' do
      it 'returns them all, in dependency order, each carrying its own classification' do
        closure = [
          node('unicode-display_width', '2.6.0'),
          node('terminal-table', '3.0.2', ['unicode-display_width'])
        ]
        allow(closure_resolver).to receive(:resolve_closure).with('terminal-table', '3.0.2').and_return(closure)
        allow(manifest).to receive(:satisfied?).and_return(false)
        allow(classifier).to receive(:classify)
          .with(name: 'unicode-display_width', version: '2.6.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0')
          .and_return(pure_classification('unicode-display_width', '2.6.0'))
        allow(classifier).to receive(:classify)
          .with(name: 'terminal-table', version: '3.0.2', platform: 'x64-mingw-ucrt', ruby_abi: '4.0')
          .and_return(pure_classification('terminal-table', '3.0.2'))

        result = planner.plan_for('terminal-table', '3.0.2', platform: 'x64-mingw-ucrt', ruby_abi: '4.0')

        expect(result.map { |entry| entry[:name] }).to eq(%w[unicode-display_width terminal-table])
        expect(result.map { |entry| entry[:classification].pure? }).to all(be(true))
        expect(result.map { |entry| entry[:runtime_dependency_names] }).to eq([[], ['unicode-display_width']])
        expect(result.last[:runtime_dependencies]).to eq([{ name: 'unicode-display_width', requirement: Gem::Requirement.default }])
      end
    end
  end
end
