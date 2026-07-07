# frozen_string_literal: true

# gobject-introspection -- vendored-DLL path + fontconfig setup + ABI-qualified
# require.
#
# Same GLib.prepend_dll_path shape as glib2's equivalent patch, plus pointing
# FONTCONFIG_PATH/FONTCONFIG_FILE at the vendored fontconfig config, since
# Windows has no system fontconfig for GTK/Pango's font rendering to fall
# back on.
#
# Deliberately does NOT port the original PowerShell's separate
# GObjectIntrospection.prepend_typelib_path(...) argument rewrite -- verified
# directly against the real 4.3.6 source that no such *call* exists anywhere
# in this gem (only the method definition does); that rewrite was already
# dead code, matching nothing, before this patch existed.
# Ported from patch-ruby-gnome-macos.sh (2026-07), which patches an
# already-installed gem in place; here the same anchor + exact-count
# assertion applies to freshly extracted build source instead.
{
  file: 'lib/gobject-introspection.rb',
  marker: 'GLib.prepend_dll_path(vendor_dir + "bin")',
  steps: [
    {
      old: 'require "gobject_introspection.so"',
      new: [
        'base_dir = Pathname.new(__FILE__).dirname.dirname.expand_path',
        'vendor_dir = base_dir + "vendor" + "local"',
        'GLib.prepend_dll_path(vendor_dir + "bin")',
        '',
        'fontconfig_path = vendor_dir + "etc" + "fonts"',
        'fonts_conf = fontconfig_path + "fonts.conf"',
        'if fontconfig_path.exist? && fonts_conf.exist?',
        '  ENV["FONTCONFIG_PATH"] = fontconfig_path.to_s',
        '  ENV["FONTCONFIG_FILE"] = fonts_conf.to_s',
        'end',
        '',
        'major, minor, _ = RUBY_VERSION.split(/\./)',
        # rubocop:disable Lint/InterpolationCheck -- deliberately literal: this
        # text is written into the patched gobject-introspection.rb,
        # interpolated by *it* at load time, not by this patch definition now.
        'require "gobject-introspection/#{major}.#{minor}/gobject_introspection.so"'
        # rubocop:enable Lint/InterpolationCheck
      ].join("\n"),
      count: 1
    }
  ]
}
