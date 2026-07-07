# frozen_string_literal: true

# cairo-gobject -- ABI-qualified require only, no DLL-path prepend needed
# here (unlike glib2/cairo/gobject-introspection/gio2/pango/gtk3) -- it
# depends on cairo and glib2, which already vendor and prepend their own DLL
# paths when required.
# Ported from patch-ruby-gnome-macos.sh (2026-07), which patches an
# already-installed gem in place; here the same anchor + exact-count
# assertion applies to freshly extracted build source instead.
{
  file: 'lib/cairo-gobject.rb',
  marker: 'major, minor, _ = RUBY_VERSION.split(/\./)',
  steps: [
    {
      old: 'require "cairo_gobject.so"',
      new: [
        'major, minor, _ = RUBY_VERSION.split(/\./)',
        # rubocop:disable Lint/InterpolationCheck -- deliberately literal: this
        # text is written into the patched cairo-gobject.rb, interpolated by
        # *it* at load time, not by this patch definition now.
        'require "cairo-gobject/#{major}.#{minor}/cairo_gobject.so"'
        # rubocop:enable Lint/InterpolationCheck
      ].join("\n"),
      count: 1
    }
  ]
}
