# frozen_string_literal: true

# glib2 -- vendored-DLL path + ABI-qualified require.
#
# The gem vendors its own DLLs under vendor/local/bin (fat-gem pattern, one
# binary per supported Ruby ABI under lib/<abi>/), so a bare `require
# "glib2.so"` would either miss the vendored DLLs entirely or load whichever
# ABI's .so happens to be first on the load path. GLib.prepend_dll_path is
# already defined by glib2 itself (this patch only adds a call to it, not the
# method); RubyInstaller::Runtime.add_dll_directory is what actually makes
# Windows' DLL search see vendor/local/bin.
# Ported from patch-ruby-gnome-macos.sh (2026-07), which patches an
# already-installed gem in place; here the same anchor + exact-count
# assertion applies to freshly extracted build source instead.
{
  file: 'lib/glib2.rb',
  marker: 'GLib.prepend_dll_path(vendor_dir + "bin")',
  steps: [
    {
      old: 'require "glib2.so"',
      new: [
        'base_dir = Pathname.new(__FILE__).dirname.dirname.expand_path',
        'vendor_dir = base_dir + "vendor" + "local"',
        'GLib.prepend_dll_path(vendor_dir + "bin")',
        'major, minor, _ = RUBY_VERSION.split(/\./)',
        # rubocop:disable Lint/InterpolationCheck -- deliberately literal: this
        # text is written into the patched glib2.rb, interpolated by *it* at
        # load time, not by this patch definition now.
        'require "glib2/#{major}.#{minor}/glib2.so"'
        # rubocop:enable Lint/InterpolationCheck
      ].join("\n"),
      count: 1
    }
  ]
}
