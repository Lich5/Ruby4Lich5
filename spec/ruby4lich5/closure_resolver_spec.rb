# frozen_string_literal: true

require 'ruby4lich5/closure_resolver'
require 'rubygems/resolver'
require 'net/http'

RSpec.describe Ruby4Lich5::ClosureResolver do
  # Input shape for the injected `resolve:` callable -- dep_names may be
  # bare Strings (an unconstrained dependency, Gem::Requirement.default,
  # i.e. ">= 0") or [name, requirement_string] pairs when a test cares about
  # the actual constraint.
  def input_node(name, version, deps = [])
    runtime_dependencies = deps.map do |dep|
      dep_name, requirement_string = dep.is_a?(Array) ? dep : [dep, nil]
      { name: dep_name, requirement: Gem::Requirement.new(requirement_string || Gem::Requirement.default) }
    end
    { name: name, version: version, runtime_dependencies: runtime_dependencies }
  end

  # #resolve_closure's real output shape: runtime_dependencies (the richer
  # {name:, requirement:} pairs) plus runtime_dependency_names (derived from
  # it, kept for existing callers) -- both always present together.
  def output_node(name, version, deps = [])
    input_node(name, version, deps).merge(runtime_dependency_names: deps.map { |dep| dep.is_a?(Array) ? dep.first : dep })
  end

  describe '#resolve_closure' do
    context 'with a single gem and no dependencies' do
      it 'returns just that gem' do
        resolve = ->(_name, _version) { [input_node('ascii_charts', '0.9.1')] }
        resolver = described_class.new(resolve: resolve)

        expect(resolver.resolve_closure('ascii_charts', '0.9.1'))
          .to eq([output_node('ascii_charts', '0.9.1')])
      end
    end

    context 'with a simple dependency chain' do
      it 'orders every dependency before the gem that depends on it' do
        # terminal-table -> unicode-display_width, the real shape verified
        # directly against rubygems.org before writing this.
        resolve = lambda do |_name, _version|
          [
            input_node('terminal-table', '3.0.2', ['unicode-display_width']),
            input_node('unicode-display_width', '2.6.0')
          ]
        end
        resolver = described_class.new(resolve: resolve)

        result = resolver.resolve_closure('terminal-table', '3.0.2')

        expect(result).to eq(
          [
            output_node('unicode-display_width', '2.6.0'),
            output_node('terminal-table', '3.0.2', ['unicode-display_width'])
          ]
        )
      end
    end

    context 'with a real Gem::Requirement on an edge' do
      it 'survives the round trip into runtime_dependencies, unchanged, while runtime_dependency_names stays name-only' do
        # Real gap, found in review: an earlier version discarded
        # Gem::Dependency#requirement entirely, keeping only .map(&:name) --
        # a locked Phase 17 SS8 design requirement (the future resolution
        # lock needs the actual constraint, not just which names exist).
        resolve = lambda do |_name, _version|
          [
            input_node('root-gem', '1.0.0', [['dep-gem', '>= 2.6']]),
            input_node('dep-gem', '2.7.0')
          ]
        end
        resolver = described_class.new(resolve: resolve)

        result = resolver.resolve_closure('root-gem', '1.0.0')
        root_entry = result.find { |entry| entry[:name] == 'root-gem' }

        expect(root_entry[:runtime_dependencies]).to eq([{ name: 'dep-gem', requirement: Gem::Requirement.new('>= 2.6') }])
        expect(root_entry[:runtime_dependency_names]).to eq(['dep-gem'])
      end
    end

    context 'with a diamond dependency (two gems sharing one common dependency)' do
      it 'includes the shared dependency exactly once, before both of its dependents' do
        # cairo -> red-colors, and (in the real GTK3 suite) cairo-gobject
        # also -> red-colors -- the actual shape that motivated needing a
        # real topological sort instead of trusting incidental output order.
        resolve = lambda do |_name, _version|
          [
            input_node('cairo', '1.18.5', %w[red-colors pkg-config]),
            input_node('cairo-gobject', '4.3.6', %w[cairo red-colors]),
            input_node('red-colors', '0.4.0'),
            input_node('pkg-config', '1.5.6')
          ]
        end
        resolver = described_class.new(resolve: resolve)

        result = resolver.resolve_closure('cairo-gobject', '4.3.6').map { |n| n[:name] }

        expect(result.tally['red-colors']).to eq(1)
        expect(result.index('red-colors')).to be < result.index('cairo')
        expect(result.index('red-colors')).to be < result.index('cairo-gobject')
        expect(result.index('cairo')).to be < result.index('cairo-gobject')
        expect(result.last).to eq('cairo-gobject')
      end
    end

    context 'when the resolved set references a dependency name not included in it' do
      it 'raises IncompleteClosureError naming both the missing dependency and what needed it' do
        # An incomplete closure isn't benign: silently dropping the missing
        # name would hand back a build plan that's missing something it
        # actually needs, surfacing later as a confusing failure far from
        # its real cause instead of here, where the gap is actually known.
        resolve = lambda do |_name, _version|
          [input_node('widget', '1.0.0', ['not-in-the-resolved-set'])]
        end
        resolver = described_class.new(resolve: resolve)

        expect { resolver.resolve_closure('widget', '1.0.0') }
          .to raise_error(described_class::IncompleteClosureError, /widget depends on not-in-the-resolved-set/)
      end
    end
  end

  describe '#resolve_closure using the real default_resolve' do
    # These stub Gem::Resolver itself rather than injecting a fake `resolve:`
    # callable, so they exercise default_resolve's actual rescue chain
    # instead of bypassing it.
    let(:fake_gem_resolver) { instance_double(Gem::Resolver) }

    before do
      allow(Gem::Resolver).to receive(:new).and_return(fake_gem_resolver)
    end

    it 'excludes development dependencies and preserves a runtime dependency real Gem::Requirement' do
      # Real gap, found in review: the previous default_resolve test
      # coverage only ever stubbed fake_gem_resolver.resolve to raise
      # (the error-wrapping paths below), never to succeed -- so
      # default_resolve's own extraction logic (dep.type == :runtime
      # filtering, dep.requirement preservation) was only ever exercised
      # indirectly through the injected `resolve:` callable, which bypasses
      # default_resolve entirely. Uses a real Gem::Specification (not a
      # hand-rolled double) so add_runtime_dependency/
      # add_development_dependency produce real Gem::Dependency objects
      # with real #type/#requirement values, the exact same objects
      # default_resolve's own spec.dependencies would return in production.
      root_spec = Gem::Specification.new('root-gem', '1.0.0') do |s|
        s.add_runtime_dependency('dep-gem', '>= 2.6')
        s.add_development_dependency('rspec', '~> 3.0')
      end
      dep_spec = Gem::Specification.new('dep-gem', '2.7.0')
      # A real Gem::Resolver#resolve returns the full closure, root and
      # dependency alike -- dep-gem must be present too, or
      # #topological_sort's own completeness check (a real, separate
      # concern -- an incomplete closure isn't benign) raises instead.
      activation_requests = [root_spec, dep_spec].map { |spec| instance_double(Gem::Resolver::ActivationRequest, spec: spec) }
      allow(fake_gem_resolver).to receive(:resolve).and_return(activation_requests)
      resolver = described_class.new

      result = resolver.resolve_closure('root-gem', '1.0.0')
      root_entry = result.find { |entry| entry[:name] == 'root-gem' }

      expect(root_entry[:runtime_dependencies]).to eq([{ name: 'dep-gem', requirement: Gem::Requirement.new('>= 2.6') }])
      expect(root_entry[:runtime_dependency_names]).to eq(['dep-gem'])
    end

    it 'wraps a Net::OpenTimeout as ResolutionError naming the configured timeout' do
      allow(fake_gem_resolver).to receive(:resolve).and_raise(Net::OpenTimeout, 'timed out')
      resolver = described_class.new(timeout_seconds: 5)

      expect { resolver.resolve_closure('some_gem', '1.0.0') }
        .to raise_error(described_class::ResolutionError, /could not resolve some_gem 1\.0\.0: timed out after 5s/)
    end

    it 'wraps a non-Gem network error (e.g. SocketError) with class and message context' do
      allow(fake_gem_resolver).to receive(:resolve).and_raise(SocketError, 'getaddrinfo failed')
      resolver = described_class.new

      expect { resolver.resolve_closure('some_gem', '1.0.0') }
        .to raise_error(described_class::ResolutionError, /SocketError: getaddrinfo failed/)
    end

    it 'aborts a resolve that overruns timeout_seconds even when resolver.resolve itself never raises' do
      allow(fake_gem_resolver).to receive(:resolve) { sleep 5 }
      resolver = described_class.new(timeout_seconds: 0.2)

      start = Time.now
      expect { resolver.resolve_closure('some_gem', '1.0.0') }
        .to raise_error(described_class::ResolutionError, /timed out after 0\.2s/)
      expect(Time.now - start).to be < 5
    end
  end
end
