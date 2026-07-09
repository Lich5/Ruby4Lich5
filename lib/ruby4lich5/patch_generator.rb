# frozen_string_literal: true

require 'fileutils'
require 'pp'
require_relative 'safe_token'

module Ruby4Lich5
  # Derives the vendor-dir + ABI-require patch that all of glib2, cairo,
  # gobject-introspection, gio2, pango, and gtk3 currently need as
  # hand-written +patches/<gem_name>/dll-path-and-require-abi.rb+ files --
  # confirmed, by reading all 6, to reduce to one template with exactly one
  # binary branch (does this gem's own resolved dependency closure include
  # glib2, or not -- cairo is the only one of the 6 on the fallback side).
  #
  # Produces the same +{file:, marker:, steps:}+ shape {PatchApplier}
  # already knows how to apply -- no new patch-application mechanism, this
  # is an automated producer of a patch file, not a different way to apply
  # one. Writing the definition Hash through Ruby's own string handling
  # (rather than hand-assembling source text) and serializing it with
  # +Hash#inspect+ at the very end sidesteps the interpolation-escaping the
  # hand-written patches manage manually (their own +Lint/InterpolationCheck+
  # rubocop-disable comments) -- +inspect+ always produces a double-quoted,
  # backslash-escaped literal, never ambiguous with real interpolation.
  #
  # Deliberately narrow: finds exactly one bare +require "*.so"+ anchor
  # under the gem's own +lib/+ tree and fails loudly if it finds zero or
  # more than one, rather than guessing. A gem that doesn't fit this exact
  # shape is expected to fail here -- per the original 7a scoping, that's
  # the correct outcome (a human lands at "here's the specific anchor
  # that's missing," not a silently-wrong generated patch), not a gap to
  # design around.
  class PatchGenerator
    # Raised when the gem's source doesn't have exactly one bare
    # +require "*.so"+ anchor under +lib/+ -- zero, or more than one, both
    # fail loudly rather than guessing which one (if any) is the real one.
    class GenerationError < StandardError; end

    # Raised specifically when zero anchors were found -- a real, expected
    # outcome for a gem with no compiled extension of its own at all (e.g. a
    # +GObjectIntrospection::Loader+-based gem like +atk+/+gdk3+/
    # +gdk_pixbuf2+, confirmed directly against their real source: no
    # +ext/+, no +.c+ files, nothing to require). Distinct from
    # {AmbiguousAnchor} so a caller wiring generation into the real pipeline
    # can treat "nothing to generate" as success, not failure, without
    # resorting to message string-matching.
    class NoAnchorFound < GenerationError; end

    # Raised when more than one bare +require "*.so"+ anchor was found --
    # genuinely ambiguous, always a real failure a human needs to look at.
    class AmbiguousAnchor < GenerationError; end

    # Matches either quote style -- confirmed real single-quoted requires
    # aren't in any of the 6 known gems, but nothing about RuboCop's default
    # string-literal style guarantees a future gem's anchor is double-quoted.
    # Missing one here must not silently present as "no anchor, no patch
    # needed" (see {NoAnchorFound}'s own contract) for a gem that actually
    # has an anchor in the other quote style.
    SO_ANCHOR = /\A(?<indent>[ \t]*)require\s+(?<quote>['"])(?<so_name>[A-Za-z0-9_]+)\.so\k<quote>\s*\z/
    private_constant :SO_ANCHOR

    # @param patches_root [String] same convention as {PatchApplier} --
    #   directory containing one subdirectory per gem name
    def initialize(patches_root: File.expand_path('../../patches', __dir__))
      @patches_root = patches_root
    end

    # @param gem_name [String]
    # @param gem_root [String] the gem's extracted source root
    # @param depends_on_glib2 [Boolean] whether this gem's own resolved
    #   runtime-dependency closure includes glib2 (transitively) -- ClosureResolver
    #   already resolves this graph before classification runs, so a caller
    #   derives it from the plan rather than this class re-resolving anything
    # @return [String] the absolute path the patch file was written to
    # @raise [NoAnchorFound] if +gem_root+'s +lib/+ tree has no bare
    #   +require "*.so"+ anchor at all
    # @raise [AmbiguousAnchor] if it has more than one
    def generate(gem_name, gem_root, depends_on_glib2:)
      SafeToken.validate!(gem_name, 'gem name')

      definition = definition_for(gem_name, gem_root, depends_on_glib2: depends_on_glib2)
      write(gem_name, definition)
    end

    # @return [Hash] the +{file:, marker:, steps:}+ definition, without
    #   writing anything -- separated from {#generate} so the derivation
    #   logic is testable without touching the filesystem
    # @raise [GenerationError] see {#generate}
    def definition_for(gem_name, gem_root, depends_on_glib2:)
      relative_file, indent, quote, so_name = find_anchor(gem_root)
      depth = relative_file.count('/') + 1
      # Preserves the real anchor's own quote character -- PatchApplier
      # matches this "old" value literally against the actual gem source, so
      # it must read exactly as that line reads, not as this generator
      # happens to prefer writing new code.
      old = "#{indent}require #{quote}#{so_name}.so#{quote}"
      new = depends_on_glib2 ? glib2_branch(gem_name, so_name, indent, depth) : fallback_branch(gem_name, so_name, indent, depth)

      {
        file: relative_file,
        marker: depends_on_glib2 ? 'GLib.prepend_dll_path(vendor_dir + "bin")' : 'RubyInstaller::Runtime.add_dll_directory(vendor_bin.to_s)',
        steps: [{ old: old, new: new, count: 1 }]
      }
    end

    private

    # @return [Array(String, String, String, String)]
    #   +[relative_file, indent, quote, so_name]+
    # @raise [GenerationError]
    def find_anchor(gem_root)
      absolute_root = File.expand_path(gem_root)
      # Every anchor line in every file, not just the first per file -- two
      # bare require "*.so" lines in one file are exactly as ambiguous as
      # two across separate files, and must fail the same way.
      matches = Dir.glob(File.join(absolute_root, 'lib', '**', '*.rb')).sort.flat_map do |path|
        relative = Pathname.new(path).relative_path_from(Pathname.new(absolute_root)).to_s
        # Explicit UTF-8, then scrub -- Ruby parses .rb source as UTF-8
        # regardless of runtime locale, but File.readlines with no encoding:
        # tags the string with Encoding.default_external. On a runner where
        # that's US-ASCII (real, reproduced 2026-07-08 against cairo's own
        # lib/cairo/colors.rb, which has genuine non-ASCII bytes in color-name
        # comments), matching any regex against the untagged string raises
        # ArgumentError before SO_ANCHOR even gets a chance to not match.
        File.readlines(path, encoding: 'UTF-8').each_with_index.filter_map do |line, index|
          m = SO_ANCHOR.match(line.chomp.scrub)
          [relative, m[:indent], m[:quote], m[:so_name], index] if m
        end
      end

      case matches.size
      when 0
        raise NoAnchorFound, "No bare require \"*.so\" anchor found under #{gem_root}/lib"
      when 1
        matches.first.first(4)
      else
        locations = matches.map { |relative, _, _, _, index| "#{relative}:#{index + 1}" }.join(', ')
        raise AmbiguousAnchor, "Ambiguous: found #{matches.size} bare require \"*.so\" anchors (#{locations}) -- expected exactly one"
      end
    end

    # @return [String] the runtime value for the "new" replacement -- glib2
    #   itself and every real glib2-dependent (gio2, pango, gtk3,
    #   gobject-introspection) use this same shape, glib2 defining the
    #   method it then calls on itself
    def glib2_branch(gem_name, so_name, indent, depth)
      [
        "#{indent}base_dir = Pathname.new(__FILE__).#{(['dirname'] * depth).join('.')}.expand_path",
        "#{indent}vendor_dir = base_dir + \"vendor\" + \"local\"",
        "#{indent}GLib.prepend_dll_path(vendor_dir + \"bin\")",
        "#{indent}major, minor, _ = RUBY_VERSION.split(/\\./)",
        "#{indent}require \"#{gem_name}/\#{major}.\#{minor}/#{so_name}.so\""
      ].join("\n")
    end

    # @return [String] the runtime value for the "new" replacement -- for a
    #   gem with no glib2-provided prepend_dll_path to piggyback on (cairo,
    #   the only one of the 6 real gems that needs this), calling
    #   RubyInstaller::Runtime.add_dll_directory directly, with a PATH-env
    #   fallback for non-RubyInstaller Rubies where that library isn't
    #   available. mingw/mswin-gated since a fallback-branch gem may also
    #   ship non-Windows platforms with no vendored DLL directory to add.
    def fallback_branch(gem_name, so_name, indent, depth)
      [
        "#{indent}if RUBY_PLATFORM =~ /mingw|mswin/",
        "#{indent}  require \"pathname\"",
        "#{indent}  base_dir = Pathname.new(__FILE__).#{(['dirname'] * depth).join('.')}.expand_path",
        "#{indent}  vendor_bin = base_dir + \"vendor\" + \"local\" + \"bin\"",
        "#{indent}  if vendor_bin.exist?",
        "#{indent}    begin",
        "#{indent}      require \"ruby_installer/runtime\"",
        "#{indent}      RubyInstaller::Runtime.add_dll_directory(vendor_bin.to_s)",
        "#{indent}    rescue LoadError",
        "#{indent}      ENV[\"PATH\"] = \"\#{vendor_bin};\#{ENV[\"PATH\"]}\"",
        "#{indent}    end",
        "#{indent}  end",
        "#{indent}end",
        "#{indent}major, minor, _ = RUBY_VERSION.split(/\\./)",
        "#{indent}require \"#{gem_name}/\#{major}.\#{minor}/#{so_name}.so\""
      ].join("\n")
    end

    # @return [String] the absolute path written to
    def write(gem_name, definition)
      out_dir = File.join(@patches_root, gem_name)
      FileUtils.mkdir_p(out_dir)
      out_path = File.join(out_dir, 'dll-path-and-require-abi.rb')

      header = "# frozen_string_literal: true\n\n" \
               "# #{gem_name} -- vendored-DLL path + ABI-qualified require.\n" \
               "# Generated by Ruby4Lich5::PatchGenerator, not hand-written -- review before\n" \
               "# committing, same as any other curated patch.\n\n"
      File.write(out_path, header + PP.pp(definition, +'').chomp + "\n")
      out_path
    end
  end
end
