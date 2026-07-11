# frozen_string_literal: true

module Ruby4Lich5
  # Shared validation for the one digest shape this project trusts anywhere
  # a SHA-256 is recorded or compared: +"sha256:<64 lowercase hex>"+. Single
  # source of truth for {GemManifestGenerator} and {NativeGemDigestFetcher},
  # which each independently defined the identical pattern before this
  # existed (real duplication, found in review 2026-07-11) -- same reasoning
  # as {SafeToken} centralizing input-safety validation.
  module DigestFormat
    # @return [Regexp]
    PATTERN = /\Asha256:[0-9a-f]{64}\z/
    private_constant :PATTERN

    # @param value [Object]
    # @return [Boolean] true only for a String matching {PATTERN} exactly
    def self.valid?(value)
      value.is_a?(String) && PATTERN.match?(value)
    end
  end
end
