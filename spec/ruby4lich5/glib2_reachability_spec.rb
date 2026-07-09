# frozen_string_literal: true

require 'ruby4lich5/glib2_reachability'

RSpec.describe Ruby4Lich5::Glib2Reachability do
  def entry(name, deps = [])
    { name: name, runtime_dependency_names: deps }
  end

  describe '.reachable?' do
    context 'with the real GTK3 stack shape (same fixture as VendoringRoleClassifier\'s own spec)' do
      let(:plan) do
        [
          entry('glib2'),
          entry('cairo'),
          entry('gobject-introspection', ['glib2']),
          entry('cairo-gobject', %w[cairo glib2]),
          entry('gio2', ['gobject-introspection']),
          entry('pango', %w[cairo-gobject gobject-introspection]),
          entry('atk', ['glib2']),
          entry('gdk_pixbuf2', ['gio2']),
          entry('gdk3', %w[cairo-gobject gdk_pixbuf2 pango]),
          entry('gtk3', %w[atk gdk3])
        ]
      end

      it 'is true for glib2 itself, even though it never appears in its own dependency list' do
        expect(described_class.reachable?('glib2', plan)).to be true
      end

      it 'is true for a direct dependent' do
        expect(described_class.reachable?('gobject-introspection', plan)).to be true
      end

      it 'is true several hops away (gtk3 -> gdk3 -> ... -> glib2)' do
        expect(described_class.reachable?('gtk3', plan)).to be true
      end

      it 'is false for cairo -- a genuine root with no glib2 anywhere in its own real closure' do
        expect(described_class.reachable?('cairo', plan)).to be false
      end
    end

    context 'a gem entirely outside the GTK/GNOME family' do
      it 'is false when glib2 is not in the plan at all' do
        plan = [entry('libv8-node'), entry('mini_racer', ['libv8-node'])]

        expect(described_class.reachable?('mini_racer', plan)).to be false
      end

      it 'is still true if an unrelated gem happens to genuinely depend on glib2 -- not a GTK-specific check' do
        plan = [entry('glib2'), entry('some-other-gem', ['glib2'])]

        expect(described_class.reachable?('some-other-gem', plan)).to be true
      end
    end

    context 'edge cases' do
      it 'is false for a gem with no dependencies and no glib2 in the plan' do
        expect(described_class.reachable?('curses', [entry('curses')])).to be false
      end

      it 'is false against an empty plan' do
        expect(described_class.reachable?('anything', [])).to be false
      end

      it 'does not loop forever on a cyclic dependency graph' do
        plan = [entry('a', ['b']), entry('b', ['a'])]

        expect(described_class.reachable?('a', plan)).to be false
      end
    end
  end
end
