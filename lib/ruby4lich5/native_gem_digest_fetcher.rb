# frozen_string_literal: true

require 'open3'
require 'json'
require_relative 'safe_token'

module Ruby4Lich5
  # Fetches the already-published, already-verified digest for a native
  # gem's own individual R4L5-<gem>-<version>-<platform> release (Phase
  # 12/13 SS2 -- that digest was computed and verified at publish time, this
  # class only reads it back, never recomputes it).
  class NativeGemDigestFetcher
    class FetchError < StandardError; end

    DIGEST_PATTERN = /\Asha256:[0-9a-f]{64}\z/
    private_constant :DIGEST_PATTERN

    # @param repo [String] +"owner/repo"+
    # @param platform [String] e.g. +"x64-mingw-ucrt"+
    # @param runner [#call] +->(cmd_array) { [stdout, status] }+, defaults to
    #   a real +gh api+ call via Open3; specs should inject a stub
    def initialize(repo:, platform:, runner: method(:default_runner))
      @repo = repo
      @platform = platform
      @runner = runner
    end

    # @param name [String]
    # @param version [String]
    # @return [String] +"sha256:<64 lowercase hex>"+
    # @raise [FetchError]
    def call(name, version)
      SafeToken.validate!(name, 'gem name')
      SafeToken.validate!(version, 'gem version')

      tag = "R4L5-#{name}-#{version}-#{@platform}"
      filename = "#{tag}.gem"
      stdout, status = @runner.call(['gh', 'api', "repos/#{@repo}/releases/tags/#{tag}"])
      raise FetchError, "gh api failed for #{tag}: #{stdout}" unless status.success?

      parsed = begin
        JSON.parse(stdout)
      rescue JSON::ParserError => e
        raise FetchError, "gh api returned unparseable JSON for #{tag}: #{e.message}"
      end
      raise FetchError, "gh api returned unexpected JSON shape for #{tag} (expected an object): #{parsed.class}" unless parsed.is_a?(Hash)

      assets = parsed.fetch('assets', [])
      raise FetchError, "gh api returned unexpected JSON shape for #{tag} (expected assets to be an array): #{assets.class}" unless assets.is_a?(Array)

      asset = assets.find { |a| a.is_a?(Hash) && a['name'] == filename }
      raise FetchError, "no #{filename} asset found on release #{tag}" if asset.nil?

      digest = asset['digest']
      raise FetchError, "release #{tag}'s #{filename} has a missing or malformed digest: #{digest.inspect}" unless DIGEST_PATTERN.match?(digest.to_s)

      digest
    end

    private

    # @param cmd [Array<String>]
    # @return [Array(String, Process::Status)]
    def default_runner(cmd)
      Open3.capture2e(*cmd)
    end
  end
end
