# frozen_string_literal: true

# gobject-introspection -- vendors a rubygems_plugin.rb the real gem doesn't
# ship at all (verified directly: absent from the real 4.3.6 source, and
# absent from a real macOS install of the same version -- confirmed this
# isn't something upstream provides on any platform).
#
# RubyGems auto-requires any installed gem's lib/rubygems_plugin.rb the
# moment that gem's spec is activated -- before any consumer code actually
# does `require`. gobject-introspection is used as the trigger vehicle here
# specifically because it's a near-universal dependency of the whole GTK
# stack (gtk3, gdk3, pango, atk, gdk_pixbuf2 all depend on it, directly or
# transitively), guaranteeing this Windows-only setup runs early regardless
# of which specific GTK gem a consumer happens to require first.
#
# Windows-only (whole body is gated on Gem.win_platform?; a no-op everywhere
# else): points FONTCONFIG_FILE/FONTCONFIG_PATH at the vendored fontconfig
# config (Windows has no system fontconfig for GTK/Pango to fall back on --
# also set up in this gem's own dll-path-and-require-abi.rb patch, at
# require time rather than activation time; both firing is redundant in the
# ordinary case but deliberately preserved here to match the original
# reference exactly, not trimmed on a guess that the redundancy is harmless),
# and generates gdk-pixbuf's loaders.cache from a template -- the actual
# vendored install path is only known per-machine at install time, so it
# can't be baked in statically ahead of time.
#
# This whole body runs at gem *activation* time, before any consumer code
# has even required anything -- and gobject-introspection is a near-
# universal dependency, so an uncaught exception here would abort loading
# the entire GTK stack over what's ultimately a best-effort environment
# setup, not a hard requirement. The loaders.cache regeneration is the risky
# part (real file I/O against a vendored, machine-specific path: permissions,
# a read-only install location, or plain I/O trouble can all raise). Wrapped
# in a broad rescue so a failure here skips GDK_PIXBUF_MODULE_FILE setup
# instead of aborting activation -- confirmed via CodeRabbit review
# (2026-07-06), same reasoning as the existing `rescue nil` already used
# below for `find_by_name`.
# Ported from patch-ruby-gnome-macos.sh (2026-07).
{
  file: 'lib/rubygems_plugin.rb',
  marker: 'GDK_PIXBUF_MODULE_FILE',
  content: <<~'RUBY'
    if Gem.win_platform?
      gi_spec = Gem::Specification.find_by_name("gobject-introspection") rescue nil
      if gi_spec
        begin
          vendor_dir = File.join(gi_spec.gem_dir, "vendor", "local")
          fontconfig_file = File.join(vendor_dir, "etc", "fonts", "fonts.conf")
          if File.exist?(fontconfig_file)
            ENV["FONTCONFIG_FILE"] = fontconfig_file
            ENV["FONTCONFIG_PATH"] = File.dirname(fontconfig_file)
          end

          pixbuf_dir = File.join(vendor_dir, "lib", "gdk-pixbuf-2.0", "2.10.0")
          loaders_dir = File.join(pixbuf_dir, "loaders")
          cache_template = File.join(pixbuf_dir, "loaders.cache.in")
          cache_file = File.join(pixbuf_dir, "loaders.cache")
          if File.exist?(cache_template) && File.directory?(loaders_dir)
            template = File.read(cache_template)
            File.write(cache_file, template.gsub("@@MODULEDIR@@", loaders_dir.gsub("/", "\\")))
            ENV["GDK_PIXBUF_MODULE_FILE"] = cache_file if File.exist?(cache_file)
          end
        rescue StandardError
          nil
        end
      end
    end
  RUBY
}
