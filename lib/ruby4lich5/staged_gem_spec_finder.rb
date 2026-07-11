# frozen_string_literal: true

require 'rubygems/package'

module Ruby4Lich5
  # A +find_specs+ callable for {InstalledGemClosure} that reads gemspecs
  # directly from staged +.gem+ files on disk, rather than querying a live
  # Ruby's own installed-gem registry.
  #
  # Real gap this closes, found in review 2026-07-10: the publish job that
  # runs the gem manifest generator downloads only +dist/pkg+ (the staged
  # +.gem+ files themselves) -- it never restores the actual installed-gem
  # environment the build job assembled and then discarded when its runner
  # terminated. {InstalledGemClosure}'s default
  # +Gem::Specification.find_all_by_name+ would find nothing there (or,
  # worse, resolve to whatever happens to be incidentally installed on that
  # generic runner). Every +.gem+ file already carries its own embedded
  # gemspec (including real runtime dependencies) -- reading it directly
  # needs nothing "installed" at all, just the file on disk. Same technique
  # already established in this project for cairo's synthesized gemspec
  # (docs/DECISIONS.md Phase 8, +Gem::Package.new(path).spec+).
  class StagedGemSpecFinder
    # @param pkg_dir [String] directory containing every staged +.gem+ file
    def initialize(pkg_dir:)
      @pkg_dir = pkg_dir
    end

    # @param name [String]
    # @return [Array<Gem::Specification>] every staged spec matching +name+
    #   (ordinarily zero or one -- more than one would mean two differently-
    #   versioned copies of the same gem were staged, a real anomaly
    #   {InstalledGemClosure} already handles by picking the highest version)
    def call(name)
      specs_by_name.fetch(name, [])
    end

    private

    # @return [Hash{String => Array<Gem::Specification>}]
    def specs_by_name
      @specs_by_name ||= Dir.glob(File.join(@pkg_dir, '*.gem')).each_with_object(Hash.new { |h, k| h[k] = [] }) do |path, index|
        spec = Gem::Package.new(path).spec
        index[spec.name] << spec
      end
    end
  end
end
