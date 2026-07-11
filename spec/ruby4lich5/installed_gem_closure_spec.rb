# frozen_string_literal: true

require 'ruby4lich5/installed_gem_closure'

RSpec.describe Ruby4Lich5::InstalledGemClosure do
  # @param name [String]
  # @param version [String]
  # @param deps [Array<String>] runtime dependency names
  # @param default [Boolean] whether #default_gem? should report true
  # @return [Gem::Specification]
  def fake_spec(name, version, deps = [], default: false)
    spec = Gem::Specification.new(name, version) do |s|
      deps.each { |dep| s.add_dependency(dep, '>= 0') }
    end
    allow(spec).to receive(:default_gem?).and_return(default)
    spec
  end

  # @param specs_by_name [Hash{String => Array<Gem::Specification>}]
  # @return [#call] a stand-in for Gem::Specification.find_all_by_name
  def find_specs_from(specs_by_name)
    ->(name) { specs_by_name.fetch(name, []) }
  end

  describe '#resolve' do
    it 'returns just the requested gem when it has no dependencies' do
      find_specs = find_specs_from('ascii_charts' => [fake_spec('ascii_charts', '0.9.1')])
      closure = described_class.new(requested_names: ['ascii_charts'], find_specs: find_specs)

      expect(closure.resolve).to eq(
        [{ name: 'ascii_charts', version: '0.9.1', runtime_dependency_names: [] }]
      )
    end

    it 'orders every dependency before the gem that depends on it' do
      find_specs = find_specs_from(
        'terminal-table'        => [fake_spec('terminal-table', '4.0.0', ['unicode-display_width'])],
        'unicode-display_width' => [fake_spec('unicode-display_width', '3.2.0')]
      )
      closure = described_class.new(requested_names: ['terminal-table'], find_specs: find_specs)

      expect(closure.resolve.map { |node| node[:name] }).to eq(%w[unicode-display_width terminal-table])
    end

    it 'includes a dependency shared by two requested gems exactly once' do
      # cairo -> red-colors, cairo-gobject -> red-colors -- the real diamond
      # shape in the GTK3 stack.
      find_specs = find_specs_from(
        'cairo'         => [fake_spec('cairo', '1.18.5', ['red-colors'])],
        'cairo-gobject' => [fake_spec('cairo-gobject', '4.3.6', ['red-colors'])],
        'red-colors'    => [fake_spec('red-colors', '0.4.0')]
      )
      closure = described_class.new(requested_names: %w[cairo cairo-gobject], find_specs: find_specs)

      names = closure.resolve.map { |node| node[:name] }
      expect(names).to include('red-colors', 'cairo', 'cairo-gobject')
      expect(names.count('red-colors')).to eq(1)
      expect(names.index('red-colors')).to be < names.index('cairo')
      expect(names.index('red-colors')).to be < names.index('cairo-gobject')
    end

    it 'prunes a default gem and does not recurse into its own dependencies' do
      # json is a real default gem in this project's target Ruby -- if it
      # declared a dependency, that dependency should never appear either,
      # matching the existing inline script's behavior exactly.
      find_specs = find_specs_from(
        'gio2'   => [fake_spec('gio2', '4.3.6', ['fiddle'])],
        'fiddle' => [fake_spec('fiddle', '1.1.8', ['some-fiddle-only-dep'], default: true)]
      )
      closure = described_class.new(requested_names: ['gio2'], find_specs: find_specs)

      names = closure.resolve.map { |node| node[:name] }
      expect(names).to eq(['gio2'])
      expect(names).not_to include('fiddle', 'some-fiddle-only-dep')
    end

    it 'drops an explicitly excluded name and its own subtree' do
      find_specs = find_specs_from(
        'sequel'     => [fake_spec('sequel', '5.106.0', ['bigdecimal'])],
        'bigdecimal' => [fake_spec('bigdecimal', '4.1.2', ['some-bigdecimal-only-dep'])]
      )
      closure = described_class.new(requested_names: ['sequel'], excluded_names: ['bigdecimal'], find_specs: find_specs)

      names = closure.resolve.map { |node| node[:name] }
      expect(names).to eq(['sequel'])
      expect(names).not_to include('bigdecimal', 'some-bigdecimal-only-dep')
    end

    it 'raises naming the gem when a requested name has no installed spec at all' do
      closure = described_class.new(requested_names: ['nonexistent'], find_specs: find_specs_from({}))

      expect { closure.resolve }.to raise_error(described_class::MissingSpecError, /nonexistent/)
    end

    it 'picks the highest non-default version when multiple installed copies exist' do
      find_specs = find_specs_from(
        'concurrent-ruby' => [
          fake_spec('concurrent-ruby', '1.3.7'),
          fake_spec('concurrent-ruby', '1.2.0')
        ]
      )
      closure = described_class.new(requested_names: ['concurrent-ruby'], find_specs: find_specs)

      expect(closure.resolve).to eq(
        [{ name: 'concurrent-ruby', version: '1.3.7', runtime_dependency_names: [] }]
      )
    end

    it 'requesting the same name twice does not duplicate it in the result' do
      find_specs = find_specs_from('os' => [fake_spec('os', '1.1.4')])
      closure = described_class.new(requested_names: %w[os os], find_specs: find_specs)

      expect(closure.resolve.map { |node| node[:name] }).to eq(['os'])
    end
  end
end
