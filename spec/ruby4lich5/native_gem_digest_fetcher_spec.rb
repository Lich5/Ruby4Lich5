# frozen_string_literal: true

require 'ruby4lich5/native_gem_digest_fetcher'

FakeGhStatus = Struct.new(:success?)

RSpec.describe Ruby4Lich5::NativeGemDigestFetcher do
  def success(stdout)
    [stdout, FakeGhStatus.new(true)]
  end

  def failure(stdout)
    [stdout, FakeGhStatus.new(false)]
  end

  describe '#call' do
    it 'returns the matching asset digest from a real-shaped gh api response' do
      body = { 'assets' => [
        { 'name' => 'R4L5-sqlite3-2.9.5-x64-mingw-ucrt.gem', 'digest' => "sha256:#{'a' * 64}" },
        { 'name' => 'runtime-gems-manifest.txt', 'digest' => "sha256:#{'b' * 64}" }
      ] }.to_json
      runner = ->(_cmd) { success(body) }
      fetcher = described_class.new(repo: 'Lich5/Ruby4Lich5', platform: 'x64-mingw-ucrt', runner: runner)

      expect(fetcher.call('sqlite3', '2.9.5')).to eq("sha256:#{'a' * 64}")
    end

    it 'raises when gh api itself fails' do
      runner = ->(_cmd) { failure('gh: release not found') }
      fetcher = described_class.new(repo: 'Lich5/Ruby4Lich5', platform: 'x64-mingw-ucrt', runner: runner)

      expect { fetcher.call('sqlite3', '2.9.5') }.to raise_error(described_class::FetchError, /gh api failed/)
    end

    it 'raises when no matching asset is present' do
      runner = ->(_cmd) { success({ 'assets' => [] }.to_json) }
      fetcher = described_class.new(repo: 'Lich5/Ruby4Lich5', platform: 'x64-mingw-ucrt', runner: runner)

      expect { fetcher.call('sqlite3', '2.9.5') }.to raise_error(described_class::FetchError, /no .* asset found/)
    end

    it 'raises when the matching asset has a malformed digest' do
      body = { 'assets' => [{ 'name' => 'R4L5-sqlite3-2.9.5-x64-mingw-ucrt.gem', 'digest' => 'not-a-digest' }] }.to_json
      runner = ->(_cmd) { success(body) }
      fetcher = described_class.new(repo: 'Lich5/Ruby4Lich5', platform: 'x64-mingw-ucrt', runner: runner)

      expect { fetcher.call('sqlite3', '2.9.5') }.to raise_error(described_class::FetchError, /malformed digest/)
    end

    it 'raises when gh api returns unparseable JSON' do
      runner = ->(_cmd) { success('not json') }
      fetcher = described_class.new(repo: 'Lich5/Ruby4Lich5', platform: 'x64-mingw-ucrt', runner: runner)

      expect { fetcher.call('sqlite3', '2.9.5') }.to raise_error(described_class::FetchError, /unparseable JSON/)
    end

    it 'raises rather than a raw NoMethodError when gh api returns valid JSON that is not an object' do
      runner = ->(_cmd) { success('[]') }
      fetcher = described_class.new(repo: 'Lich5/Ruby4Lich5', platform: 'x64-mingw-ucrt', runner: runner)

      expect { fetcher.call('sqlite3', '2.9.5') }.to raise_error(described_class::FetchError, /unexpected JSON shape/)
    end

    it 'raises rather than a raw NoMethodError when "assets" is present but not an array' do
      runner = ->(_cmd) { success({ 'assets' => 'not-an-array' }.to_json) }
      fetcher = described_class.new(repo: 'Lich5/Ruby4Lich5', platform: 'x64-mingw-ucrt', runner: runner)

      expect { fetcher.call('sqlite3', '2.9.5') }.to raise_error(described_class::FetchError, /unexpected JSON shape/)
    end

    it 'validates the gem name against SafeToken before ever shelling out' do
      runner = double('runner')
      expect(runner).not_to receive(:call)
      fetcher = described_class.new(repo: 'Lich5/Ruby4Lich5', platform: 'x64-mingw-ucrt', runner: runner)

      expect { fetcher.call('sqlite3; rm -rf /', '2.9.5') }.to raise_error(ArgumentError)
    end
  end
end
