# frozen_string_literal: true

require 'ruby4lich5/digest_format'

RSpec.describe Ruby4Lich5::DigestFormat do
  describe '.valid?' do
    it 'accepts a well-formed sha256 digest' do
      expect(described_class.valid?("sha256:#{'a' * 64}")).to be(true)
    end

    it 'rejects a digest with the wrong hex length' do
      expect(described_class.valid?("sha256:#{'a' * 63}")).to be(false)
    end

    it 'rejects uppercase hex' do
      expect(described_class.valid?("sha256:#{'A' * 64}")).to be(false)
    end

    it 'rejects a missing sha256: prefix' do
      expect(described_class.valid?('a' * 64)).to be(false)
    end

    it 'rejects nil without raising' do
      expect(described_class.valid?(nil)).to be(false)
    end

    it 'rejects a non-string without raising' do
      expect(described_class.valid?(12_345)).to be(false)
    end
  end
end
