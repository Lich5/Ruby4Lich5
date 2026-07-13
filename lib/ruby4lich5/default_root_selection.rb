# frozen_string_literal: true

require_relative 'rubygems_client'

module Ruby4Lich5
  # The one canonical source for "which roots, at which target, does a
  # default run select" -- matches +ruby4-bundled-gems-suite.yml+'s own
  # real defaults (+ruby-gnome-version+ plus the full +runtime-gems+
  # default list, 15 roots total), reused by both
  # +bin/derive_curated_gems_seed.rb+ (PR B) and
  # +bin/derive_dynamic_msys2_packages.rb+ (PR F1) rather than each
  # keeping its own copy -- real duplication risk this project has already
  # found and fixed twice this session (`SCHEMA_VERSION`, the
  # `classification`/`closure_entry` spec helpers).
  #
  # **Deliberately never resolves `cairo` as an independent root -- this
  # is the actual fix for the real `cairo-version`/closure mismatch gap
  # named in Phase 17 SS8, not a separate mechanism.** Checked directly:
  # only `gtk3` is ever a resolver root; `cairo` is always a *transitive
  # member* of gtk3's own resolved closure. The old, replaced design
  # independently fetched a `cairo-version` input with nothing enforcing
  # it agreed with what the gtk3 closure actually resolved. As long as
  # nothing here ever introduces a second, independent `cairo` root --
  # which this module's own return shape structurally cannot do, since it
  # only ever emits {GTK3_VERSION} plus {RUNTIME_GEMS} -- cairo's version
  # is simply whatever the real, resolved gtk3 closure contains. No
  # separate derivation step exists, or is needed, to "fix" this.
  module DefaultRootSelection
    # @return [String]
    PLATFORM = 'x64-mingw-ucrt'

    # @return [String]
    RUBY_ABI = '4.0'

    # @return [String] matches +ruby4-bundled-gems-suite.yml+'s own
    #   +ruby-gnome-version+ default -- the one real special-case root
    #   version source (Phase 17 SS8); every other root resolves via
    #   {RubygemsClient#latest_version}
    GTK3_VERSION = '4.3.6'

    # @return [Array<String>] every other +runtime-gems+ default root,
    #   matching +ruby4-bundled-gems-suite.yml+'s own real default list --
    #   confirmed against the real shipped `manifest/R4L5-gem-manifest.json`
    #   in PR B, not assumed
    RUNTIME_GEMS = %w[
      sqlite3 ox ascii_charts curses os redis sequel terminal-table kramdown tzinfo tzinfo-data
      concurrent-ruby ffi webrick
    ].freeze

    # @param rubygems_client [RubygemsClient]
    # @return [Hash{String => String}] +gtk3+ plus every {RUNTIME_GEMS}
    #   root, each resolved to its exact selected version -- the
    #   +requested_roots+ shape {ResolutionLock} and
    #   {Ruby4Lich5::CuratedGemsSeedBuilder} both expect
    def self.resolve_versions(rubygems_client:)
      { 'gtk3' => GTK3_VERSION }.merge(
        RUNTIME_GEMS.to_h { |name| [name, rubygems_client.latest_version(name)] }
      )
    end
  end
end
