# frozen_string_literal: true

require 'ruby4lich5/known_native_gems'

RSpec.describe Ruby4Lich5::KnownNativeGems do
  describe '.known?' do
    it 'is true for a gem in the curated list' do
      expect(described_class.known?('gtk3')).to be(true)
    end

    it 'is false for a gem not in the curated list' do
      expect(described_class.known?('some-unheard-of-gem')).to be(false)
    end
  end

  describe '.packages_for' do
    it 'returns the MSYS2 package list for a known gem' do
      expect(described_class.packages_for('gtk3')).to eq(described_class::MSYS2_PACKAGES)
    end

    it 'returns nil for a gem not in the curated list' do
      expect(described_class.packages_for('some-unheard-of-gem')).to be_nil
    end
  end
end
