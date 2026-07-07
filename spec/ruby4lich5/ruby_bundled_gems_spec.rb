# frozen_string_literal: true

require 'ruby4lich5/ruby_bundled_gems'

RSpec.describe Ruby4Lich5::RubyBundledGems do
  describe '.bundled?' do
    it 'is true for json -- confirmed bundled in RubyInstaller 4.0.5-1 as a default gem' do
      expect(described_class.bundled?('json')).to be(true)
    end

    it 'is true for fiddle -- confirmed bundled in RubyInstaller 4.0.5-1 at the same version the real gtk3 closure resolves to' do
      expect(described_class.bundled?('fiddle')).to be(true)
    end

    it 'is true for rexml -- present as a non-default bundled gem, not just the default set' do
      expect(described_class.bundled?('rexml')).to be(true)
    end

    it 'is false for set -- confirmed genuinely absent from both the default and bundled specifications in the real archive' do
      expect(described_class.bundled?('set')).to be(false)
    end

    it 'is false for a gem not in the curated list' do
      expect(described_class.bundled?('some-unheard-of-gem')).to be(false)
    end

    it 'has no duplicate names between DEFAULT_GEMS and OTHER_BUNDLED_GEMS' do
      expect(described_class::BUNDLED_GEMS.tally.select { |_, count| count > 1 }).to be_empty
    end
  end
end
