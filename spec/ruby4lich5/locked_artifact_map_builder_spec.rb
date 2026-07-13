# frozen_string_literal: true

require 'ruby4lich5/locked_artifact_map_builder'
require 'tmpdir'
require_relative '../support/closure_fixtures'

RSpec.describe Ruby4Lich5::LockedArtifactMapBuilder do
  include ClosureFixtures

  let(:rubygems_client) { instance_double(Ruby4Lich5::RubygemsClient) }
  subject(:builder) { described_class.new(rubygems_client: rubygems_client) }

  around do |example|
    Dir.mktmpdir('ruby4lich5-locked-artifact-map-builder-spec') { |dir| @tmp = dir and example.run }
  end

  # A real, on-disk .gem package -- this class reads via
  # Gem::Package.new(path).spec for real, so a stubbed/fake path can't
  # stand in for it the way rubygems_client (an injected double) can.
  # Gem::Package.build writes real warnings/status lines straight to
  # $stdout/$stderr regardless of any quiet option; redirected here so
  # spec output stays clean.
  def build_gem_file(name:, version:, platform:, filename: "#{name}.gem")
    spec = Gem::Specification.new do |s|
      s.name = name
      s.version = version
      s.platform = platform
      s.summary = 'fixture'
      s.authors = ['fixture']
      s.files = []
    end
    path = File.join(@tmp, filename)

    original_stdout = $stdout.dup
    original_stderr = $stderr.dup
    begin
      $stdout.reopen(File::NULL)
      $stderr.reopen(File::NULL)
      Gem::Package.build(spec, false, false, path)
    ensure
      $stdout.reopen(original_stdout)
      $stderr.reopen(original_stderr)
    end

    path
  end

  describe '#build' do
    it 'excludes ruby_bundled members entirely -- no artifact, never fetched, never verified' do
      # instance_double requires a method to be stubbed before it can be
      # spied on, even to assert it was never called.
      allow(rubygems_client).to receive(:download_gem)
      closure = [closure_entry('json', '2.7.1', state: :ruby_bundled)]

      result = builder.build(closure, platform: 'x64-mingw-ucrt', built_gem_paths: {})

      expect(result).to eq({})
      expect(rubygems_client).not_to have_received(:download_gem)
    end

    context 'with a :pure entry' do
      it "fetches at platform 'ruby', not the target platform" do
        path = build_gem_file(name: 'widget', version: '1.0.0', platform: 'ruby')
        allow(rubygems_client).to receive(:download_gem).with('widget', '1.0.0', platform: 'ruby').and_return(path)
        closure = [closure_entry('widget', '1.0.0', state: :pure)]

        result = builder.build(closure, platform: 'x64-mingw-ucrt', built_gem_paths: {})

        expect(result).to eq({ 'widget' => path })
      end
    end

    context 'with a :native_pass_through entry' do
      it 'fetches at the target platform, not ruby' do
        path = build_gem_file(name: 'widget', version: '1.0.0', platform: 'x64-mingw-ucrt')
        allow(rubygems_client).to receive(:download_gem)
          .with('widget', '1.0.0', platform: 'x64-mingw-ucrt').and_return(path)
        closure = [closure_entry('widget', '1.0.0', state: :native_pass_through, platform_asset: 'widget-1.0.0-x64-mingw-ucrt.gem')]

        result = builder.build(closure, platform: 'x64-mingw-ucrt', built_gem_paths: {})

        expect(result).to eq({ 'widget' => path })
      end
    end

    context 'with a :native_self_contained entry' do
      it 'never calls RubygemsClient at all -- the artifact must already exist locally' do
        allow(rubygems_client).to receive(:download_gem)
        path = build_gem_file(name: 'widget', version: '1.0.0', platform: 'x64-mingw-ucrt')
        closure = [closure_entry('widget', '1.0.0', state: :native_self_contained, msys2_packages: ['pkg'])]

        result = builder.build(closure, platform: 'x64-mingw-ucrt', built_gem_paths: { 'widget' => path })

        expect(result).to eq({ 'widget' => path })
        expect(rubygems_client).not_to have_received(:download_gem)
      end

      it 'raises VerificationError when no built artifact was provided for it' do
        closure = [closure_entry('widget', '1.0.0', state: :native_self_contained, msys2_packages: ['pkg'])]

        expect { builder.build(closure, platform: 'x64-mingw-ucrt', built_gem_paths: {}) }
          .to raise_error(described_class::VerificationError, /widget: locked as native_self_contained, but no built artifact/)
      end
    end

    # The central sealed-pipe guarantee: every artifact, from every
    # delivery role, gets the same verification -- not just the
    # highest-risk (self-contained/build) path. A corrupted or
    # wrong-content download for a pure/pass-through gem is exactly as
    # capable of silently shipping the wrong thing as a stale build-cache
    # entry.
    describe 'verification -- applies uniformly to every delivery role' do
      it 'raises VerificationError when the artifact name does not match the locked name' do
        path = build_gem_file(name: 'wrong-name', version: '1.0.0', platform: 'ruby')
        allow(rubygems_client).to receive(:download_gem).and_return(path)
        closure = [closure_entry('widget', '1.0.0', state: :pure)]

        expect { builder.build(closure, platform: 'x64-mingw-ucrt', built_gem_paths: {}) }
          .to raise_error(described_class::VerificationError, /name "wrong-name" \(expected "widget"\)/)
      end

      it 'raises VerificationError when the artifact version does not match the locked version' do
        path = build_gem_file(name: 'widget', version: '2.0.0', platform: 'ruby')
        allow(rubygems_client).to receive(:download_gem).and_return(path)
        closure = [closure_entry('widget', '1.0.0', state: :pure)]

        expect { builder.build(closure, platform: 'x64-mingw-ucrt', built_gem_paths: {}) }
          .to raise_error(described_class::VerificationError, /version "2\.0\.0" \(expected "1\.0\.0"\)/)
      end

      it 'raises VerificationError when a pure artifact is not actually the ruby platform' do
        path = build_gem_file(name: 'widget', version: '1.0.0', platform: 'x64-mingw-ucrt')
        allow(rubygems_client).to receive(:download_gem).and_return(path)
        closure = [closure_entry('widget', '1.0.0', state: :pure)]

        expect { builder.build(closure, platform: 'x64-mingw-ucrt', built_gem_paths: {}) }
          .to raise_error(described_class::VerificationError, /platform "x64-mingw-ucrt" \(expected "ruby"\)/)
      end

      it 'raises VerificationError when a self-contained artifact is not actually the target platform' do
        path = build_gem_file(name: 'widget', version: '1.0.0', platform: 'ruby')
        closure = [closure_entry('widget', '1.0.0', state: :native_self_contained, msys2_packages: ['pkg'])]

        expect { builder.build(closure, platform: 'x64-mingw-ucrt', built_gem_paths: { 'widget' => path }) }
          .to raise_error(described_class::VerificationError, /platform "ruby" \(expected "x64-mingw-ucrt"\)/)
      end

      it 'reports every mismatch at once, not just the first' do
        path = build_gem_file(name: 'wrong-name', version: '9.9.9', platform: 'x64-mingw-ucrt')
        allow(rubygems_client).to receive(:download_gem).and_return(path)
        closure = [closure_entry('widget', '1.0.0', state: :pure)]

        expect { builder.build(closure, platform: 'x64-mingw-ucrt', built_gem_paths: {}) }
          .to raise_error(described_class::VerificationError) { |error|
            expect(error.message).to include('name "wrong-name"')
            expect(error.message).to include('version "9.9.9"')
            expect(error.message).to include('platform "x64-mingw-ucrt" (expected "ruby")')
          }
      end

      it 'raises VerificationError, not a raw exception, when the artifact is not a real gem package at all' do
        garbage_path = File.join(@tmp, 'garbage.gem')
        File.write(garbage_path, 'not a real gem file')
        allow(rubygems_client).to receive(:download_gem).and_return(garbage_path)
        closure = [closure_entry('widget', '1.0.0', state: :pure)]

        expect { builder.build(closure, platform: 'x64-mingw-ucrt', built_gem_paths: {}) }
          .to raise_error(described_class::VerificationError, /widget: could not read a gem package's embedded spec/)
      end

      it 'raises VerificationError, not a raw exception, when the artifact path does not exist at all' do
        allow(rubygems_client).to receive(:download_gem).and_return('/nonexistent/path/widget.gem')
        closure = [closure_entry('widget', '1.0.0', state: :pure)]

        expect { builder.build(closure, platform: 'x64-mingw-ucrt', built_gem_paths: {}) }
          .to raise_error(described_class::VerificationError, /widget: could not read a gem package's embedded spec/)
      end
    end

    context 'with a mixed closure -- every delivery role at once' do
      it 'produces exactly one map entry per non-ruby_bundled member, keyed by name' do
        pure_path = build_gem_file(name: 'pure-gem', version: '1.0.0', platform: 'ruby', filename: 'pure.gem')
        pass_through_path = build_gem_file(name: 'pass-through-gem', version: '2.0.0', platform: 'x64-mingw-ucrt', filename: 'pt.gem')
        self_contained_path = build_gem_file(name: 'self-contained-gem', version: '3.0.0', platform: 'x64-mingw-ucrt', filename: 'sc.gem')

        allow(rubygems_client).to receive(:download_gem).with('pure-gem', '1.0.0', platform: 'ruby').and_return(pure_path)
        allow(rubygems_client).to receive(:download_gem)
          .with('pass-through-gem', '2.0.0', platform: 'x64-mingw-ucrt').and_return(pass_through_path)

        closure = [
          closure_entry('pure-gem', '1.0.0', state: :pure),
          closure_entry('pass-through-gem', '2.0.0', state: :native_pass_through, platform_asset: 'pass-through-gem-2.0.0-x64-mingw-ucrt.gem'),
          closure_entry('self-contained-gem', '3.0.0', state: :native_self_contained, msys2_packages: ['pkg']),
          closure_entry('json', '2.7.1', state: :ruby_bundled)
        ]

        result = builder.build(
          closure, platform: 'x64-mingw-ucrt', built_gem_paths: { 'self-contained-gem' => self_contained_path }
        )

        expect(result).to eq(
          {
            'pure-gem'           => pure_path,
            'pass-through-gem'   => pass_through_path,
            'self-contained-gem' => self_contained_path
          }
        )
      end
    end
  end
end
