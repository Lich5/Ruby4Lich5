# frozen_string_literal: true

# gio2 -- vendored-DLL path + ABI-qualified require, same shape as
# glib2/cairo/gobject-introspection's equivalent patches, but the anchor
# lives inside loader.rb's require_extension method (indented), not at the
# file's top level.
# Ported from patch-ruby-gnome-macos.sh (2026-07), which patches an
# already-installed gem in place; here the same anchor + exact-count
# assertion applies to freshly extracted build source instead.
{
  file: 'lib/gio2/loader.rb',
  marker: 'GLib.prepend_dll_path(vendor_dir + "bin")',
  steps: [
    {
      old: '      require "gio2.so"',
      new: [
        '      base_dir = Pathname.new(__FILE__).dirname.dirname.dirname.expand_path',
        '      vendor_dir = base_dir + "vendor" + "local"',
        '      GLib.prepend_dll_path(vendor_dir + "bin")',
        '      major, minor, _ = RUBY_VERSION.split(/\./)',
        # rubocop:disable Lint/InterpolationCheck -- deliberately literal: this
        # text is written into the patched loader.rb, interpolated by *it* at
        # load time, not by this patch definition now.
        '      require "gio2/#{major}.#{minor}/gio2.so"'
        # rubocop:enable Lint/InterpolationCheck
      ].join("\n"),
      count: 1
    }
  ]
}
