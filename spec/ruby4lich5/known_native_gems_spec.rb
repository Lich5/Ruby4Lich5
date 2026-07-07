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

    it 'is true for all 10 native members of the real GTK3 stack build, not just the original 7' do
      # gio2/gdk3/gdk_pixbuf2 were missing until a live end-to-end BuildPlanner
      # run surfaced the gap (2026-07-06) -- regression coverage so the list
      # doesn't quietly drift out of sync with the real workflow again.
      %w[glib2 gobject-introspection gio2 cairo cairo-gobject pango gdk_pixbuf2 atk gdk3 gtk3].each do |gem_name|
        expect(described_class.known?(gem_name)).to be(true), "expected #{gem_name} to be known"
      end
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
