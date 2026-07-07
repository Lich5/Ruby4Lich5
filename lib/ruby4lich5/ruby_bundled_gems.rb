# frozen_string_literal: true

module Ruby4Lich5
  # Gems known to ship already compiled and present in the target
  # RubyInstaller distribution itself (Ruby's "default" gems, plus the
  # further set of "bundled" gems Ruby ships but doesn't auto-require) --
  # needing no build or vendoring at all when they turn up as a real
  # dependency-closure member.
  #
  # Deliberately a narrow, name-only check, not requirement-aware: a gem
  # here is treated as already satisfied regardless of which exact version
  # a real dependency closure happened to resolve to. First discovered
  # reactively (2026-07-07): the real +gtk3+ closure resolves
  # +cairo -> red-colors -> json+ (red-colors only requires +json >= 0+,
  # trivially satisfied) and +gio2 -> fiddle+ (at exactly the same version
  # RubyInstaller bundles) -- both would have been built/vendored from
  # scratch for no reason, since +Classifier+ had no concept of "already
  # present in the target Ruby install" at all, only "can we get or build
  # this."
  #
  # Rather than keep discovering these one CI failure at a time, this list
  # is the *complete* set for RubyInstaller 4.0.5-1 specifically -- read
  # directly out of the real archive
  # (github.com/oneclick/rubyinstaller2/releases/download/RubyInstaller-4.0.5-1/
  # rubyinstaller-4.0.5-1-x64.7z), not approximated from ruby-lang.org docs:
  # every +.gemspec+ under +lib/ruby/gems/4.0.0/specifications/+, both the
  # "default" subdirectory (auto-required, e.g. json/openssl/psych) and the
  # plain (non-default, "bundled but not auto-required," e.g. rake/fiddle/
  # rexml/matrix) top level. +set+ is confirmed genuinely absent from both --
  # it was never at risk the way json/fiddle were.
  #
  # Most of these are pure Ruby and would already classify correctly as
  # +:pure+ without this list existing at all (no native extension means no
  # build decision to get wrong); they're included anyway so the list stays
  # a complete, honest mirror of "what's actually in the archive" rather
  # than a hand-picked subset someone has to remember to extend later.
  #
  # This is tied to one specific RubyInstaller version and will drift as
  # that version bumps -- re-derive from the real archive rather than hand-
  # edit forward from memory when it does.
  #
  # The general fix -- carrying real requirement ranges through
  # {ClosureResolver} instead of just the resolved exact version, and
  # checking them against a real per-RubyInstaller-version bundled-gems
  # registry instead of one frozen constant -- is deferred, same as
  # {VendoringRoleClassifier}'s documented manifest-filtering gap. This is
  # the narrow, immediate unblock.
  module RubyBundledGems
    # "Default" gems -- specifications/default/*.gemspec. Auto-required;
    # +require "openssl"+ etc. just works with no explicit +gem install+.
    #
    # @return [Array<String>]
    DEFAULT_GEMS = %w[
      bundler date delegate did_you_mean digest english erb error_highlight
      etc fcntl fileutils find forwardable io-console io-nonblock io-wait
      ipaddr json net-http net-protocol open-uri open3 openssl optparse pp
      prettyprint prism psych resolv ruby2_keywords securerandom shellwords
      singleton stringio strscan syntax_suggest tempfile time timeout tmpdir
      tsort un uri weakref win32-registry yaml zlib
    ].freeze

    # "Bundled" (non-default) gems -- specifications/*.gemspec, not under
    # default/. Present and already compiled, but not auto-required --
    # exactly the shape +fiddle+ turned out to be (gio2 requires it
    # explicitly, and it's already sitting in the install either way).
    #
    # @return [Array<String>]
    OTHER_BUNDLED_GEMS = %w[
      abbrev base64 benchmark bigdecimal csv debug drb fiddle getoptlong irb
      logger matrix minitest mutex_m net-ftp net-imap net-pop net-smtp nkf
      observer ostruct power_assert prime pstore racc rake rbs rdoc readline
      reline repl_type_completor resolv-replace rexml rinda rss test-unit
      typeprof win32ole
    ].freeze

    # @return [Array<String>]
    BUNDLED_GEMS = (DEFAULT_GEMS + OTHER_BUNDLED_GEMS).freeze

    # @param gem_name [String]
    # @return [Boolean] true when this gem should be treated as already
    #   present in the target Ruby install, regardless of version
    def self.bundled?(gem_name)
      BUNDLED_GEMS.include?(gem_name)
    end
  end
end
