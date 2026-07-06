# frozen_string_literal: true

require 'ruby4lich5/closure_resolver'
require 'rubygems/resolver'
require 'net/http'

RSpec.describe Ruby4Lich5::ClosureResolver do
  def node(name, version, deps = [])
    { name: name, version: version, runtime_dependency_names: deps }
  end

  describe '#resolve_closure' do
    context 'with a single gem and no dependencies' do
      it 'returns just that gem' do
        resolve = ->(_name, _version) { [node('ascii_charts', '0.9.1')] }
        resolver = described_class.new(resolve: resolve)

        expect(resolver.resolve_closure('ascii_charts', '0.9.1'))
          .to eq([{ name: 'ascii_charts', version: '0.9.1' }])
      end
    end

    context 'with a simple dependency chain' do
      it 'orders every dependency before the gem that depends on it' do
        # terminal-table -> unicode-display_width, the real shape verified
        # directly against rubygems.org before writing this.
        resolve = lambda do |_name, _version|
          [
            node('terminal-table', '3.0.2', ['unicode-display_width']),
            node('unicode-display_width', '2.6.0')
          ]
        end
        resolver = described_class.new(resolve: resolve)

        result = resolver.resolve_closure('terminal-table', '3.0.2')

        expect(result).to eq(
          [
            { name: 'unicode-display_width', version: '2.6.0' },
            { name: 'terminal-table', version: '3.0.2' }
          ]
        )
      end
    end

    context 'with a diamond dependency (two gems sharing one common dependency)' do
      it 'includes the shared dependency exactly once, before both of its dependents' do
        # cairo -> red-colors, and (in the real GTK3 suite) cairo-gobject
        # also -> red-colors -- the actual shape that motivated needing a
        # real topological sort instead of trusting incidental output order.
        resolve = lambda do |_name, _version|
          [
            node('cairo', '1.18.5', %w[red-colors pkg-config]),
            node('cairo-gobject', '4.3.6', %w[cairo red-colors]),
            node('red-colors', '0.4.0'),
            node('pkg-config', '1.5.6')
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
          [node('widget', '1.0.0', ['not-in-the-resolved-set'])]
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
