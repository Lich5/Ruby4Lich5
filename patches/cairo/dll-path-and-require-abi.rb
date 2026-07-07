# frozen_string_literal: true

# cairo -- vendored-DLL path + ABI-qualified require.
#
# Same shape as glib2's equivalent patch, but cairo has no built-in
# GLib.prepend_dll_path-style helper of its own to call, so this inserts the
# RubyInstaller::Runtime.add_dll_directory call directly (with a PATH-env
# fallback for non-RubyInstaller Rubies where that library isn't available).
# Only applies on mingw/mswin -- cairo also ships non-Windows platforms where
# there's no vendored DLL directory to add.
# Ported from patch-ruby-gnome-macos.sh (2026-07), which patches an
# already-installed gem in place; here the same anchor + exact-count
# assertion applies to freshly extracted build source instead.
{
  file: 'lib/cairo.rb',
  marker: 'RubyInstaller::Runtime.add_dll_directory(vendor_bin.to_s)',
  steps: [
    {
      old: 'require "cairo.so"',
      new: [
        'if RUBY_PLATFORM =~ /mingw|mswin/',
        '  require "pathname"',
        '  base_dir = Pathname.new(__FILE__).dirname.dirname.expand_path',
        '  vendor_bin = base_dir + "vendor" + "local" + "bin"',
        '  if vendor_bin.exist?',
        '    begin',
        '      require "ruby_installer/runtime"',
        '      RubyInstaller::Runtime.add_dll_directory(vendor_bin.to_s)',
        '    rescue LoadError',
        # rubocop:disable Lint/InterpolationCheck -- same deliberate-literal
        # reasoning as the require line below.
        '      ENV["PATH"] = "#{vendor_bin};#{ENV["PATH"]}"',
        # rubocop:enable Lint/InterpolationCheck
        '    end',
        '  end',
        'end',
        'major, minor, _ = RUBY_VERSION.split(/\./)',
        # rubocop:disable Lint/InterpolationCheck -- deliberately literal: this
        # text is written into the patched cairo.rb, interpolated by *it* at
        # load time, not by this patch definition now.
        'require "cairo/#{major}.#{minor}/cairo.so"'
        # rubocop:enable Lint/InterpolationCheck
      ].join("\n"),
      count: 1
    }
  ]
}
