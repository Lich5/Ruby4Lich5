# frozen_string_literal: true

require 'digest'
require_relative 'installed_gem_closure'
require_relative 'gem_unit_grouper'

module Ruby4Lich5
  # Builds the gem recovery manifest Lich's self-heal reads, per
  # docs/DECISIONS.md Phase 13 SS2/SS3 and docs/r4l5-gem-recovery-manifest.md
  # (lich-5, the schema this feeds).
  #
  # Root-declaration policy, locked 2026-07-10 (not derived from the
  # dependency graph, stated explicitly so the same drift the hand-built
  # predecessor manifest had -- concurrent-ruby getting a standalone unit,
  # tzinfo not, purely by omission -- can't recur silently):
  #   ordinary root      -> unit id equals the root's own name
  #   declared group      -> explicit unit id (today: only the GTK3 stack,
  #                          {GTK3_STACK} -> +"gtk3-runtime"+)
  #   unit package list    -> the complete, self-contained runtime closure
  #                          reachable from that root, independent of id
  class GemManifestGenerator
    # Raised when a pure gem's locally-staged digest doesn't match what
    # RubyGems.org currently reports for that exact name+version, or when
    # RubyGems.org's own digest is missing/malformed -- a real, deterministic
    # problem, never papered over (docs/DECISIONS.md Phase 13 SS3).
    class DigestValidationError < StandardError; end

    DIGEST_PATTERN = /\Asha256:[0-9a-f]{64}\z/
    private_constant :DIGEST_PATTERN

    # The one declared grouping exception -- every other top-level requested
    # name gets its own standalone-by-default unit. Order matters here only
    # for install_order *within* this group; membership in the closure
    # (matrix, red-colors) is discovered, the ten names themselves are not.
    #
    # @return [Array<String>]
    GTK3_STACK = %w[glib2 gobject-introspection gio2 cairo cairo-gobject pango
                    gdk_pixbuf2 atk gdk3 gtk3].freeze

    SCHEMA_VERSION = 1
    private_constant :SCHEMA_VERSION

    # @param native_names [Array<String>] top-level requested names that are
    #   native gems (individually released), e.g. the +native-runtime-gems+
    #   workflow input, split -- must be a superset of {GTK3_STACK}
    # @param pure_names [Array<String>] top-level requested names that are
    #   pure gems, e.g. the +runtime-gems+ workflow input, split, minus
    #   +native_names+
    # @param excluded_names [Array<String>] passed straight through to
    #   {InstalledGemClosure}
    # @param ruby_abi [String] e.g. +"4.0"+
    # @param platform [String] e.g. +"x64-mingw-ucrt"+
    # @param repo [String] +"owner/repo"+, for constructing release URLs
    # @param bundle_asset [Hash] +{tag:, filename:, sha256:}+ for the
    #   already-published gem-bundle zip this run just verified. +tag+ is
    #   this specific run's own release tag (the live tag, a draft still
    #   sharing the live tag name, or a "-candidate" tag) -- never assumed
    #   to be the live tag, since a manifest generated from a candidate's
    #   own staging set must say so explicitly (real bug, found in review
    #   2026-07-10: hardcoding the live tag here let a candidate-produced
    #   manifest's package list and its own artifact URL describe two
    #   different sets of bytes -- the live zip's, not the candidate's).
    # @param pkg_dir [String] local directory containing every staged +.gem+
    #   file, native and pure alike, by their staged (non-R4L5-prefixed)
    #   filename
    # @param native_digest_lookup [#call] +->(name, version) { "sha256:..." }+
    #   -- fetches the already-published, already-verified digest for a
    #   native gem's own individual release (Phase 12/13 SS2). Real
    #   implementation is a caller concern (a +gh api+ call); this class
    #   only declares the shape it needs.
    # @param rubygems_client [RubygemsClient] used to cross-validate a pure
    #   gem's locally-computed digest against RubyGems.org's own reported
    #   value at generation time (Phase 13 SS3)
    # @param closure_resolver [InstalledGemClosure, nil] injected for specs;
    #   defaults to a real one built from the given names/excludes
    def initialize(native_names:, pure_names:, ruby_abi:, platform:, repo:, bundle_asset:, pkg_dir:,
                   native_digest_lookup:, rubygems_client:, excluded_names: [], closure_resolver: nil)
      raise ArgumentError, 'native_names must include the full GTK3_STACK' unless (GTK3_STACK - native_names).empty?

      @native_names = native_names
      @pure_names = pure_names
      @ruby_abi = ruby_abi
      @platform = platform
      @repo = repo
      @bundle_asset = bundle_asset
      @pkg_dir = pkg_dir
      @native_digest_lookup = native_digest_lookup
      @rubygems_client = rubygems_client
      @closure_resolver = closure_resolver || InstalledGemClosure.new(
        requested_names: native_names + pure_names, excluded_names: excluded_names
      )
    end

    # @return [Hash] the full manifest document, ready for +JSON.generate+
    # @raise [DigestValidationError]
    def generate
      closure_nodes = @closure_resolver.resolve
      grouped = GemUnitGrouper.new(closure_nodes: closure_nodes, roots: roots).units
      by_name = closure_nodes.each_with_object({}) { |node, index| index[node.fetch(:name)] = node }

      units = grouped.map { |group| build_unit(group, by_name) }

      { 'schema'  => SCHEMA_VERSION,
        'targets' => [{ 'ruby_abi' => @ruby_abi, 'platform' => @platform, 'units' => units }] }
    end

    private

    # @return [Array<GemUnitGrouper::Root>]
    def roots
      ordinary = (@native_names + @pure_names - GTK3_STACK).map do |name|
        GemUnitGrouper::Root.new(id: name, start_names: [name])
      end
      [GemUnitGrouper::Root.new(id: 'gtk3-runtime', start_names: GTK3_STACK)] + ordinary
    end

    # @param group [Hash] one {GemUnitGrouper#units} entry
    # @param by_name [Hash{String => Hash}] closure nodes by name
    # @return [Hash] one manifest "units" entry
    def build_unit(group, by_name)
      members = group.fetch(:members)
      packages = members.map { |name| build_package(by_name.fetch(name)) }

      { 'id'            => group.fetch(:id),
        'members'       => members,
        'artifact'      => artifact_for(members, by_name),
        'packages'      => packages,
        'install_order' => group.fetch(:install_order) }
    end

    # @param members [Array<String>]
    # @param by_name [Hash{String => Hash}] closure nodes by name
    # @return [Hash] the manifest "artifact" block -- an individual gem
    #   release for a single native member (the only case where one exists),
    #   the shared gem-bundle zip otherwise
    def artifact_for(members, by_name)
      return bundle_artifact unless members.length == 1 && native?(members.first)

      name = members.first
      version = by_name.fetch(name).fetch(:version)
      filename = "R4L5-#{name}-#{version}-#{@platform}.gem"
      { 'url'      => "https://github.com/#{@repo}/releases/download/R4L5-#{name}-#{version}-#{@platform}/#{filename}",
        'filename' => filename,
        'sha256'   => @native_digest_lookup.call(name, version),
        'archive'  => 'gem' }
    end

    # @return [Hash]
    def bundle_artifact
      tag = @bundle_asset.fetch(:tag)
      { 'url'      => "https://github.com/#{@repo}/releases/download/#{tag}/#{@bundle_asset.fetch(:filename)}",
        'filename' => @bundle_asset.fetch(:filename),
        'sha256'   => @bundle_asset.fetch(:sha256),
        'archive'  => 'zip' }
    end

    # @param node [Hash] one closure entry, +{name:, version:, ...}+
    # @return [Hash] one manifest "packages" entry
    def build_package(node)
      name = node.fetch(:name)
      version = node.fetch(:version)

      if native?(name)
        filename = "#{name}-#{version}-#{@platform}.gem"
        digest = @native_digest_lookup.call(name, version)
      else
        filename = "#{name}-#{version}.gem"
        digest = pure_digest_for(name, version, filename)
      end

      { 'name' => name, 'version' => version, 'filename' => filename, 'sha256' => digest }
    end

    # @param name [String]
    # @return [Boolean]
    def native?(name)
      @native_names.include?(name)
    end

    # Computes the real digest of the staged file, then validates it against
    # RubyGems.org's own reported digest for this exact name+version --
    # compute, then validate, per docs/DECISIONS.md Phase 13 SS3. Never
    # copies RubyGems.org's value directly into the manifest without this
    # check: the staged file is what's actually shipped, and only a real
    # local hash proves it matches what it claims to be.
    #
    # @param name [String]
    # @param version [String]
    # @param filename [String]
    # @return [String] +"sha256:<64 lowercase hex>"+
    # @raise [DigestValidationError]
    def pure_digest_for(name, version, filename)
      path = File.join(@pkg_dir, filename)
      raise DigestValidationError, "staged pure gem file not found: #{path}" unless File.exist?(path)

      local_digest = "sha256:#{Digest::SHA256.file(path).hexdigest}"
      remote_digest = rubygems_digest_for(name, version)

      if remote_digest.nil?
        raise DigestValidationError, "RubyGems.org has no published version #{version} for #{name} " \
                                      '(or no digest reported for it) -- refusing to trust an unverifiable staged file'
      end
      unless remote_digest == local_digest
        raise DigestValidationError, "#{name} #{version}: staged file hashes to #{local_digest}, but " \
                                      "RubyGems.org reports #{remote_digest} -- refusing to ship an unverified pure gem"
      end

      local_digest
    end

    # @param name [String]
    # @param version [String]
    # @return [String, nil] +"sha256:<64 lowercase hex>"+, or +nil+ if
    #   RubyGems.org has no matching, well-formed digest for this exact
    #   name+version (the +ruby+ platform specifically -- pure gems have no
    #   other platform)
    def rubygems_digest_for(name, version)
      entry = @rubygems_client.versions(name).find { |v| v['number'] == version && v['platform'] == 'ruby' }
      return nil if entry.nil?

      sha = entry['sha']
      return nil if sha.nil? || sha.to_s.strip.empty?

      candidate = "sha256:#{sha.downcase}"
      DIGEST_PATTERN.match?(candidate) ? candidate : nil
    end
  end
end
