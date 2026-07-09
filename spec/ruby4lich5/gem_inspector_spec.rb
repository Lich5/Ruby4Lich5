# frozen_string_literal: true

require 'ruby4lich5/gem_inspector'
require 'rubygems/package'
require 'tmpdir'
require 'fileutils'

RSpec.describe Ruby4Lich5::GemInspector do
  # Builds a real, valid .gem package on disk so these specs exercise the
  # actual Gem::Package/Gem::Specification integration rather than a mock of
  # it -- exactly the assumption that turned out to be wrong during initial
  # design (Gem::Specification.find_all_by_name silently returns empty
  # files/extensions for installed gems; only the raw package tells the truth).
  #
  # @param name [String] gem name
  # @param extra_files [Array<String>] additional file paths, relative to the
  #   package root, to include and populate with placeholder content
  # @param extensions [Array<String>] paths to declare as native extensions
  # @return [String] path to the built .gem file
  def build_fixture_gem(name:, extra_files: [], extensions: [])
    Dir.mktmpdir('ruby4lich5-fixture-') do |dir|
      Dir.chdir(dir) do
        (extra_files + extensions).each do |path|
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, '')
        end

        spec = Gem::Specification.new(name, '1.0.0') do |s|
          s.summary = 'fixture gem for GemInspector specs'
          s.authors = ['Ruby4Lich5 specs']
          s.license = 'MIT'
          s.homepage = 'https://example.invalid'
          s.required_ruby_version = '>= 4.0'
          s.files = extra_files + extensions
          s.extensions = extensions
        end

        gem_path = silencing_stdout { Gem::Package.build(spec) }
        # FileUtils.mv returns an integer status, not the destination path --
        # capture the destination explicitly so it survives past mktmpdir's
        # own cleanup of the build directory.
        destination = File.join(Dir.mktmpdir('ruby4lich5-fixture-out-'), File.basename(gem_path))
        FileUtils.mv(gem_path, destination)
        destination
      end
    end
  end

  # Gem::Package.build writes build status straight to $stdout; keeps spec
  # output focused on actual test results.
  #
  # @yield the block to run with $stdout suppressed
  # @return [Object] the block's return value
  def silencing_stdout
    original = $stdout
    $stdout = File.open(File::NULL, 'w')
    yield
  ensure
    $stdout = original
  end

  describe '#extensions?' do
    context 'when the package declares no native extensions' do
      it 'returns false' do
        path = build_fixture_gem(name: 'purefixture', extra_files: ['lib/purefixture.rb'])

        expect(described_class.new(path).extensions?).to be(false)
      end
    end

    context 'when the package declares a native extension' do
      it 'returns true' do
        path = build_fixture_gem(name: 'nativefixture', extensions: ['ext/nativefixture/extconf.rb'])

        expect(described_class.new(path).extensions?).to be(true)
      end
    end
  end

  describe '#abi_present?' do
    context 'the nested convention, lib/<gem_name>/<abi>/ -- real shape, sqlite3 2.9.5' do
      it 'returns true' do
        path = build_fixture_gem(
          name: 'fatgemfixture',
          extra_files: ['lib/fatgemfixture/4.0/fatgemfixture_native.so', 'lib/fatgemfixture/3.4/fatgemfixture_native.so']
        )

        expect(described_class.new(path).abi_present?('4.0')).to be(true)
      end
    end

    context 'when the package does not bundle a binary for the requested ABI' do
      it 'returns false' do
        path = build_fixture_gem(
          name: 'fatgemfixture',
          extra_files: ['lib/fatgemfixture/3.4/fatgemfixture_native.so']
        )

        expect(described_class.new(path).abi_present?('4.1')).to be(false)
      end
    end

    context 'an ABI-named directory that holds only a pure-Ruby file, no compiled binary -- real false positive found 2026-07-08' do
      it 'returns false -- a lib/<abi>/ directory alone is not proof of a precompiled binary' do
        path = build_fixture_gem(
          name: 'fatgemfixture',
          extra_files: ['lib/fatgemfixture/4.0/compat.rb']
        )

        expect(described_class.new(path).abi_present?('4.0')).to be(false)
      end
    end

    context 'the flat convention, lib/<abi>/, gem name omitted -- real shape, ffi 1.17.4' do
      it 'returns true -- the real false negative found 2026-07-08: ffi genuinely bundles ' \
         'Ruby 4.0 support (confirmed by downloading and unpacking the real gem), but the ' \
         'nested-only pattern sent it down the native_self_contained path anyway' do
        path = build_fixture_gem(
          name: 'ffi',
          extra_files: ['lib/4.0/ffi_c.so', 'lib/3.4/ffi_c.so']
        )

        expect(described_class.new(path).abi_present?('4.0')).to be(true)
      end

      it 'still returns false for an ABI the flat convention does not bundle either' do
        path = build_fixture_gem(name: 'ffi', extra_files: ['lib/3.4/ffi_c.so'])

        expect(described_class.new(path).abi_present?('4.1')).to be(false)
      end
    end

    context 'both real conventions checked together, in the same suite, neither shadowing the other' do
      it 'recognizes a nested-convention gem even though a flat-convention gem also exists in the world' do
        nested_path = build_fixture_gem(name: 'sqlite3', extra_files: ['lib/sqlite3/4.0/sqlite3_native.so'])

        expect(described_class.new(nested_path).abi_present?('4.0')).to be(true)
      end

      it 'recognizes a flat-convention gem even though a nested-convention gem also exists in the world' do
        flat_path = build_fixture_gem(name: 'ffi', extra_files: ['lib/4.0/ffi_c.so'])

        expect(described_class.new(flat_path).abi_present?('4.0')).to be(true)
      end
    end
  end

  describe '#runnable_test_suite?' do
    context 'when the package has a spec/ directory and a Rakefile' do
      it 'returns true' do
        path = build_fixture_gem(
          name: 'testedfixture',
          extra_files: ['lib/testedfixture.rb', 'spec/testedfixture_spec.rb', 'Rakefile']
        )

        expect(described_class.new(path).runnable_test_suite?).to be(true)
      end
    end

    context 'when the package has a test/ directory and a Rakefile' do
      it 'returns true' do
        path = build_fixture_gem(
          name: 'testedfixture',
          extra_files: ['lib/testedfixture.rb', 'test/testedfixture_test.rb', 'Rakefile']
        )

        expect(described_class.new(path).runnable_test_suite?).to be(true)
      end
    end

    context 'when the package has tests but no Rakefile to run them with' do
      it 'returns false' do
        path = build_fixture_gem(
          name: 'untestedfixture',
          extra_files: ['lib/untestedfixture.rb', 'spec/untestedfixture_spec.rb']
        )

        expect(described_class.new(path).runnable_test_suite?).to be(false)
      end
    end

    context 'when the package has a Rakefile but no test directory' do
      it 'returns false' do
        path = build_fixture_gem(name: 'untestedfixture', extra_files: ['lib/untestedfixture.rb', 'Rakefile'])

        expect(described_class.new(path).runnable_test_suite?).to be(false)
      end
    end

    context 'when the package has neither' do
      it 'returns false' do
        path = build_fixture_gem(name: 'untestedfixture', extra_files: ['lib/untestedfixture.rb'])

        expect(described_class.new(path).runnable_test_suite?).to be(false)
      end
    end
  end
end
