# frozen_string_literal: true

# pango -- vendored-DLL path + ABI-qualified require, same shape as
# glib2/cairo/gobject-introspection/gio2's equivalent patches, anchor inside
# loader.rb's require_extension method.
# Ported from patch-ruby-gnome-macos.sh (2026-07), which patches an
# already-installed gem in place; here the same anchor + exact-count
# assertion applies to freshly extracted build source instead.
{
  file: 'lib/pango/loader.rb',
  marker: 'GLib.prepend_dll_path(vendor_dir + "bin")',
  steps: [
    {
      old: '      require "pango.so"',
      new: [
        '      base_dir = Pathname.new(__FILE__).dirname.dirname.dirname.expand_path',
        '      vendor_dir = base_dir + "vendor" + "local"',
        '      GLib.prepend_dll_path(vendor_dir + "bin")',
        '      major, minor, _ = RUBY_VERSION.split(/\./)',
        # rubocop:disable Lint/InterpolationCheck -- deliberately literal: this
        # text is written into the patched loader.rb, interpolated by *it* at
        # load time, not by this patch definition now.
        '      require "pango/#{major}.#{minor}/pango.so"'
        # rubocop:enable Lint/InterpolationCheck
      ].join("\n"),
      count: 1
    }
  ]
}
