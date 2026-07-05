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
    context 'when the package bundles a binary for the requested ABI' do
      it 'returns true' do
        path = build_fixture_gem(
          name: 'fatgemfixture',
          extra_files: ['lib/fatgemfixture/4.0/fatgemfixture.bundle', 'lib/fatgemfixture/3.4/fatgemfixture.bundle']
        )

        expect(described_class.new(path).abi_present?('4.0')).to be(true)
      end
    end

    context 'when the package does not bundle a binary for the requested ABI' do
      it 'returns false' do
        path = build_fixture_gem(
          name: 'fatgemfixture',
          extra_files: ['lib/fatgemfixture/3.4/fatgemfixture.bundle']
        )

        expect(described_class.new(path).abi_present?('4.1')).to be(false)
      end
    end
  end
end
