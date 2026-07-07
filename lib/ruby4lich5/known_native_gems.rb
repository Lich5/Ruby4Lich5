# frozen_string_literal: true

module Ruby4Lich5
  # The curated allowlist of gems we know how to compile ourselves, and the
  # MSYS2 ucrt64 packages required to do it.
  #
  # This is deliberately a small, honest starting point rather than a
  # finely-decomposed per-gem dependency graph: the current, real build
  # (+ruby4-bundled-gems-suite.yml+) installs one shared MSYS2 package set for
  # the whole GTK3 stack rather than a package list per gem, so that's what's
  # recorded here -- the same set for every gem in {KNOWN_GEMS}. Decomposing
  # this further is future curation work, not something to invent now without
  # evidence.
  #
  # A gem name absent from {KNOWN_GEMS} is not "unsupported forever" -- it's
  # simply not yet curated, and {Classifier} treats that as
  # +:native_needs_system_lib+ (reject loudly) until someone adds it here with
  # a verified package list.
  module KnownNativeGems
    # MSYS2 ucrt64 packages confirmed in the current, working
    # +ruby4-bundled-gems-suite.yml+ build.
    #
    # @return [Array<String>]
    MSYS2_PACKAGES = %w[
      base-devel
      make
      mingw-w64-ucrt-x86_64-gcc
      mingw-w64-ucrt-x86_64-gcc-libs
      mingw-w64-ucrt-x86_64-binutils
      mingw-w64-ucrt-x86_64-make
      mingw-w64-ucrt-x86_64-pkgconf
      mingw-w64-ucrt-x86_64-libffi
      mingw-w64-ucrt-x86_64-sqlite3
      mingw-w64-ucrt-x86_64-gobject-introspection
      mingw-w64-ucrt-x86_64-gobject-introspection-runtime
      mingw-w64-ucrt-x86_64-gtk3
      mingw-w64-ucrt-x86_64-pdcurses
      mingw-w64-ucrt-x86_64-ncurses
    ].freeze

    # Gem names known to build successfully against {MSYS2_PACKAGES}. All 10
    # native members of the real, currently-working GTK3 stack build
    # (+ruby4-bundled-gems-suite.yml+'s "Install MSYS2 UCRT build surface"
    # step installs exactly {MSYS2_PACKAGES}, unchanged, for all 10) --
    # gio2/gdk3/gdk_pixbuf2 were missing here until a live end-to-end
    # {BuildPlanner#plan_for} run against the real gtk3 closure surfaced the
    # gap directly (2026-07-06): they're already proven buildable by the
    # real pipeline, this list had simply never been synced to match.
    #
    # @return [Array<String>]
    KNOWN_GEMS = %w[
      glib2
      gobject-introspection
      gio2
      cairo
      cairo-gobject
      pango
      gdk_pixbuf2
      atk
      gdk3
      gtk3
      sqlite3
      ffi
      ox
      curses
    ].freeze

    # @param gem_name [String]
    # @return [Boolean] true when this gem is curated for self-contained
    #   compilation
    def self.known?(gem_name)
      KNOWN_GEMS.include?(gem_name)
    end

    # @param gem_name [String]
    # @return [Array<String>, nil] the MSYS2 packages needed to build
    #   +gem_name+, or +nil+ if it isn't curated (see {.known?})
    def self.packages_for(gem_name)
      MSYS2_PACKAGES if known?(gem_name)
    end
  end
end
