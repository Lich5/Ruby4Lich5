# frozen_string_literal: true

require 'ruby4lich5/classifier'

RSpec.describe Ruby4Lich5::Classifier do
  # A stand-in for RubygemsClient that returns a distinguishable path per
  # requested platform, and a fake inspector, keyed on that same path, that
  # answers extensions?/abi_present? however each context needs -- this keeps
  # the Classifier spec focused on its own orchestration logic (which path did
  # it take, in what order) rather than re-testing RubygemsClient or
  # GemInspector, which each have their own specs.
  let(:rubygems_client) { instance_double(Ruby4Lich5::RubygemsClient) }

  def fake_inspector_class(behaviors)
    Class.new do
      define_method(:initialize) { |path| @path = path }
      define_method(:extensions?) { behaviors.fetch(@path).fetch(:extensions?) }
      define_method(:abi_present?) { |_abi| behaviors.fetch(@path).fetch(:abi_present?) }
    end
  end

  def download_path(name, version, platform)
    "#{name}-#{version}-#{platform}.gem"
  end

  describe '#classify' do
    context 'when the gem ships as a Ruby default gem (RubyBundledGems)' do
      it 'returns a :ruby_bundled classification without ever touching rubygems_client' do
        expect(rubygems_client).not_to receive(:download_gem)
        expect(rubygems_client).not_to receive(:versions)
        classifier = described_class.new(rubygems_client: rubygems_client, gem_inspector_class: Class.new)

        result = classifier.classify(name: 'json', version: '2.20.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0')

        expect(result.ruby_bundled?).to be(true)
        expect(result.reason).to match(/already present/)
      end
    end

    context 'when the gem has no native extensions' do
      it 'returns a :pure classification without checking upstream platform builds' do
        ruby_path = download_path('ascii_charts', '1.0.0', 'ruby')
        allow(rubygems_client).to receive(:download_gem)
          .with('ascii_charts', '1.0.0', platform: 'ruby').and_return(ruby_path)
        expect(rubygems_client).not_to receive(:versions)
        inspector_class = fake_inspector_class(ruby_path => { extensions?: false, abi_present?: false })
        classifier = described_class.new(rubygems_client: rubygems_client, gem_inspector_class: inspector_class)

        result = classifier.classify(name: 'ascii_charts', version: '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0')

        expect(result.pure?).to be(true)
      end
    end

    context 'when upstream precompiles the exact version, platform, and ABI requested' do
      it 'returns a :native_pass_through classification with the upstream asset name' do
        ruby_path = download_path('sqlite3', '1.7.3', 'ruby')
        platform_path = download_path('sqlite3', '1.7.3', 'x64-mingw-ucrt')
        allow(rubygems_client).to receive(:download_gem)
          .with('sqlite3', '1.7.3', platform: 'ruby').and_return(ruby_path)
        allow(rubygems_client).to receive(:download_gem)
          .with('sqlite3', '1.7.3', platform: 'x64-mingw-ucrt').and_return(platform_path)
        allow(rubygems_client).to receive(:versions).with('sqlite3').and_return(
          [{ 'number' => '1.7.3', 'platform' => 'x64-mingw-ucrt' }]
        )
        allow(rubygems_client).to receive(:asset_filename)
          .with('sqlite3', '1.7.3', 'x64-mingw-ucrt').and_return('sqlite3-1.7.3-x64-mingw-ucrt.gem')
        inspector_class = fake_inspector_class(
          ruby_path     => { extensions?: true, abi_present?: false },
          platform_path => { extensions?: true, abi_present?: true }
        )
        classifier = described_class.new(rubygems_client: rubygems_client, gem_inspector_class: inspector_class)

        result = classifier.classify(name: 'sqlite3', version: '1.7.3', platform: 'x64-mingw-ucrt', ruby_abi: '4.0')

        expect(result.pass_through?).to be(true)
        expect(result.platform_asset).to eq('sqlite3-1.7.3-x64-mingw-ucrt.gem')
      end
    end

    context 'when upstream has no build at all for the requested platform' do
      it 'falls through to a curated known-gem self-build classification' do
        ruby_path = download_path('gtk3', '4.3.7', 'ruby')
        allow(rubygems_client).to receive(:download_gem)
          .with('gtk3', '4.3.7', platform: 'ruby').and_return(ruby_path)
        allow(rubygems_client).to receive(:versions).with('gtk3').and_return(
          [{ 'number' => '4.3.7', 'platform' => 'x86-mingw32' }]
        )
        inspector_class = fake_inspector_class(ruby_path => { extensions?: true, abi_present?: false })
        classifier = described_class.new(rubygems_client: rubygems_client, gem_inspector_class: inspector_class)

        result = classifier.classify(name: 'gtk3', version: '4.3.7', platform: 'x64-mingw-ucrt', ruby_abi: '4.0')

        expect(result.self_contained?).to be(true)
        expect(result.msys2_packages).to eq(Ruby4Lich5::KnownNativeGems::MSYS2_PACKAGES)
      end
    end

    context 'when upstream has a build for the platform but not the requested ABI' do
      it 'does not substitute a different version, and falls through to self-build' do
        ruby_path = download_path('sqlite3', '1.7.3', 'ruby')
        platform_path = download_path('sqlite3', '1.7.3', 'x64-mingw-ucrt')
        allow(rubygems_client).to receive(:download_gem)
          .with('sqlite3', '1.7.3', platform: 'ruby').and_return(ruby_path)
        allow(rubygems_client).to receive(:download_gem)
          .with('sqlite3', '1.7.3', platform: 'x64-mingw-ucrt').and_return(platform_path)
        allow(rubygems_client).to receive(:versions).with('sqlite3').and_return(
          [{ 'number' => '1.7.3', 'platform' => 'x64-mingw-ucrt' }]
        )
        allow(rubygems_client).to receive(:asset_filename)
          .with('sqlite3', '1.7.3', 'x64-mingw-ucrt').and_return('sqlite3-1.7.3-x64-mingw-ucrt.gem')
        inspector_class = fake_inspector_class(
          ruby_path     => { extensions?: true, abi_present?: false },
          platform_path => { extensions?: true, abi_present?: false }
        )
        classifier = described_class.new(rubygems_client: rubygems_client, gem_inspector_class: inspector_class)

        result = classifier.classify(name: 'sqlite3', version: '1.7.3', platform: 'x64-mingw-ucrt', ruby_abi: '4.1')

        expect(result.gem_version).to eq('1.7.3')
        expect(result.self_contained?).to be(true)
      end
    end

    context 'when the gem is native, has no upstream platform build, and is not curated' do
      it 'returns a :native_needs_system_lib classification that explains why' do
        ruby_path = download_path('mystery-gem', '0.1.0', 'ruby')
        allow(rubygems_client).to receive(:download_gem)
          .with('mystery-gem', '0.1.0', platform: 'ruby').and_return(ruby_path)
        allow(rubygems_client).to receive(:versions).with('mystery-gem').and_return([])
        inspector_class = fake_inspector_class(ruby_path => { extensions?: true, abi_present?: false })
        classifier = described_class.new(rubygems_client: rubygems_client, gem_inspector_class: inspector_class)

        result = classifier.classify(name: 'mystery-gem', version: '0.1.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0')

        expect(result.needs_system_lib?).to be(true)
        expect(result.reason).to include('not in the curated buildable-gems list')
      end
    end
  end
end
