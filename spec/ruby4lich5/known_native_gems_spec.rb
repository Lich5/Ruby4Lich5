# frozen_string_literal: true

require 'ruby4lich5/known_native_gems'

RSpec.describe Ruby4Lich5::KnownNativeGems do
  describe '.known? / .packages_for, backed by the real config/curated-gems.json' do
    it 'is true, with a non-empty package list, for all 10 native members of the real GTK3 stack build' do
      # gio2/gdk3/gdk_pixbuf2 were missing until a live end-to-end BuildPlanner
      # run surfaced the gap (2026-07-06) -- regression coverage so the list
      # doesn't quietly drift out of sync with the real workflow again.
      %w[glib2 gobject-introspection gio2 cairo cairo-gobject pango gdk_pixbuf2 atk gdk3 gtk3].each do |gem_name|
        expect(described_class.known?(gem_name)).to be(true), "expected #{gem_name} to be known"
        expect(described_class.packages_for(gem_name)).not_to be_empty
      end
    end

    it 'is true for ox and curses, the two native-runtime-gems that still self-build' do
      %w[ox curses].each do |gem_name|
        expect(described_class.known?(gem_name)).to be(true), "expected #{gem_name} to be known"
        expect(described_class.packages_for(gem_name)).not_to be_empty
      end
    end

    it 'is false for a gem never seen in any resolved closure' do
      expect(described_class.known?('some-unheard-of-gem')).to be(false)
      expect(described_class.packages_for('some-unheard-of-gem')).to be_nil
    end

    describe 'regression: sqlite3 and ffi are no longer self-build candidates' do
      # Real finding during the seed's derivation (2026-07-13): live
      # Classifier runs show sqlite3/ffi now ship precompiled x64-mingw-ucrt
      # builds matching Ruby 4.0's ABI -- native_pass_through, not
      # native_self_contained. The old hardcoded KNOWN_GEMS/MSYS2_PACKAGES
      # this class used to carry directly listed both as self-build
      # candidates; that was stale policy, not current fact, and the
      # registry-backed facade must reflect the real, current
      # classification -- known? and packages_for must both answer
      # "not a self-build candidate" (false / nil), not silently keep
      # treating them as buildable via MSYS2.
      it 'reports both as not known for self-build, with no package list' do
        %w[sqlite3 ffi].each do |gem_name|
          expect(described_class.known?(gem_name)).to be(false), "expected #{gem_name} to no longer be self-build known"
          expect(described_class.packages_for(gem_name)).to be_nil
        end
      end
    end
  end
end
