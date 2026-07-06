# frozen_string_literal: true

require 'rubygems/package'

module Ruby4Lich5
  # Reads facts out of a downloaded +.gem+ package that {RubygemsClient}
  # cannot answer on its own -- whether it declares native extensions, and
  # whether it bundles a precompiled binary for a specific Ruby ABI.
  #
  # Must be given a path to an actual downloaded package (see
  # {RubygemsClient#download_gem}), not an installed gem's name. Verified
  # directly: +Gem::Specification.find_all_by_name+ returns empty +files+ and
  # +extensions+ for installed gems regardless of what's actually packaged;
  # only +Gem::Package.new(path).spec+ against the raw +.gem+ reflects reality.
  class GemInspector
    # @param gem_path [String] path to a downloaded +.gem+ file
    def initialize(gem_path)
      @spec = Gem::Package.new(gem_path).spec
    end

    # @return [Boolean] true when this package declares no native extensions
    #   at all -- meaningful only when +gem_path+ is the +"ruby"+ (source)
    #   platform package. A precompiled platform package legitimately has no
    #   extensions either, since there's nothing left to build; that is not
    #   the same thing as being a pure gem, so callers must not use this
    #   method against a non-"ruby" platform package to answer "is this pure?"
    # @return [Boolean]
    def extensions?
      !@spec.extensions.empty?
    end

    # @param ruby_abi [String] a Ruby ABI series, e.g. +"4.0"+
    # @return [Boolean] true when this package bundles a precompiled binary
    #   for the given ABI under the +lib/<gem_name>/<ruby_abi>/+ convention
    #   (the fat-gem pattern, e.g. Nokogiri's own +lib/nokogiri/4.0/+)
    def abi_present?(ruby_abi)
      pattern = %r{^lib/#{Regexp.escape(@spec.name)}/#{Regexp.escape(ruby_abi)}/}
      @spec.files.any? { |f| f.match?(pattern) }
    end

    # @return [Boolean] true when the package includes its own +spec/+ or
    #   +test/+ directory plus a +Rakefile+ -- the signal used for
    #   best-effort bundled-test-suite reuse (docs/DECISIONS.md Phase 2 SS5).
    #   Deliberately scoped to what's in the package we already fetched, not
    #   the gem's upstream git repo (which might have tests excluded from
    #   the packaged gem) -- that would mean a second fetch path and a
    #   "which URL/tag is authoritative" question for what's explicitly a
    #   nice-to-have, not a requirement.
    def runnable_test_suite?
      has_test_dir = @spec.files.any? { |f| f.start_with?('spec/', 'test/') }
      has_test_dir && @spec.files.include?('Rakefile')
    end
  end
end
