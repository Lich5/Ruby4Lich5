# frozen_string_literal: true

require 'ruby4lich5/curation_manifest'
require 'json'

RSpec.describe Ruby4Lich5::CurationManifest do
  describe '#satisfied?' do
    let(:manifest) do
      described_class.new(
        {
          'sqlite3' => { 'x64-mingw-ucrt' => { version: '1.7.3', tag: 'sqlite3-v1.7.3', asset: 'sqlite3-1.7.3-x64-mingw-ucrt.gem' } }
        }
      )
    end

    it 'is true when the exact version matches the current pin for that platform' do
      expect(manifest.satisfied?('sqlite3', '1.7.3', 'x64-mingw-ucrt')).to be(true)
    end

    context 'regression: a manifest loaded from real parsed JSON, not hand-built with Symbol keys' do
      it 'still correctly reports a match, rather than every gem looking unsatisfied' do
        # This is the manifest's actual intended real-world shape -- a
        # Ruby4Lich5 release asset, loaded via JSON.parse without
        # symbolize_names: true, which produces String keys at every level.
        raw_json = {
          'sqlite3' => { 'x64-mingw-ucrt' => { 'version' => '1.7.3', 'tag' => 'sqlite3-v1.7.3' } }
        }.to_json
        manifest_from_json = described_class.new(JSON.parse(raw_json))

        expect(manifest_from_json.satisfied?('sqlite3', '1.7.3', 'x64-mingw-ucrt')).to be(true)
      end
    end

    it 'is false when the version does not match the current pin' do
      expect(manifest.satisfied?('sqlite3', '1.7.2', 'x64-mingw-ucrt')).to be(false)
    end

    it 'is false for a platform with no entry at all' do
      expect(manifest.satisfied?('sqlite3', '1.7.3', 'arm64-darwin')).to be(false)
    end

    it 'is false for a gem with no entry at all' do
      expect(manifest.satisfied?('unknown-gem', '1.0.0', 'x64-mingw-ucrt')).to be(false)
    end

    it 'defaults to an empty manifest when constructed with no data' do
      expect(described_class.new.satisfied?('sqlite3', '1.7.3', 'x64-mingw-ucrt')).to be(false)
    end

    context 'regression: a platform entry that is null or otherwise not a Hash' do
      it 'treats it as unsatisfied instead of raising' do
        malformed = described_class.new('sqlite3' => { 'x64-mingw-ucrt' => nil, 'arm64-darwin' => 'not-a-hash' })

        expect(malformed.satisfied?('sqlite3', '1.7.3', 'x64-mingw-ucrt')).to be(false)
        expect(malformed.satisfied?('sqlite3', '1.7.3', 'arm64-darwin')).to be(false)
      end
    end

    context 'regression: a gem-level entry that is null' do
      it 'treats it as unsatisfied instead of raising' do
        malformed = described_class.new('sqlite3' => nil)

        expect(malformed.satisfied?('sqlite3', '1.7.3', 'x64-mingw-ucrt')).to be(false)
      end
    end
  end
end
