# frozen_string_literal: true

module Ruby4Lich5
  # Shared input-safety validation for values that end up interpolated into
  # filesystem paths or URLs -- gem names, platform tags, and similar tokens.
  # Used by both {RubygemsClient} (asset filenames, API URLs) and
  # {PatchApplier} (patch-directory lookup), centralized so the same rule
  # can't quietly drift between call sites -- the exact failure mode
  # {RubygemsClient#asset_filename} was extracted to prevent for filename
  # construction, applied here to input validation instead.
  module SafeToken
    # Characters permitted in a gem name, platform tag, or similar token.
    # Deliberately an allowlist, not a denylist of traversal patterns like
    # +../+ -- excluding +/+ entirely makes path traversal structurally
    # impossible in any path built from this value, rather than trying to
    # enumerate every way to spell it.
    #
    # The leading negative lookahead specifically rejects "." and ".." --
    # both individually allowed characters, but reserved filesystem segments
    # that File.join treats specially (current dir / parent dir) when they
    # make up the *entire* value, not just a substring. Verified directly:
    # File.join("/repo/patches", "..") resolves to "/repo/patches"'s parent,
    # escaping patches_root exactly the way a +/+-containing value would,
    # even though the plain allowlist above never excluded a bare +.+ or +..+.
    PATTERN = /\A(?!\.{1,2}\z)[a-zA-Z0-9._-]+\z/
    private_constant :PATTERN

    # @param value [Object] candidate token. Deliberately rejects anything
    #   that isn't already a String, rather than coercing via +#to_s+ and
    #   validating the coerced result: a caller that goes on to use the
    #   original, un-coerced value afterward (e.g. comparing a Symbol against
    #   a String literal) would silently get wrong behavior even though
    #   validation "passed." Failing loudly on the type mismatch here is
    #   simpler than making every caller remember to use a normalized return
    #   value instead of its own local variable.
    # @param label [String] used only in the raised error message
    # @raise [ArgumentError] if +value+ is nil, not a String, blank, or
    #   contains any character outside {PATTERN}
    def self.validate!(value, label)
      raise ArgumentError, "#{label} must not be nil or empty" if value.nil?
      raise ArgumentError, "#{label} must be a String, got #{value.class}: #{value.inspect}" unless value.is_a?(String)
      raise ArgumentError, "#{label} must not be nil or empty" if value.strip.empty?
      raise ArgumentError, "#{label} contains disallowed characters: #{value.inspect}" unless PATTERN.match?(value)
    end
  end
end
