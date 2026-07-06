# frozen_string_literal: true

module Ruby4Lich5
  # Shared validation for executable paths handed to a subprocess --
  # +ruby_exe+, +rake_exe+, and similar. Rejects anything that isn't an
  # absolute, existing, executable file, so a caller can't silently
  # reintroduce PATH resolution (passing +"ruby"+ or +"rake"+ as a bare
  # command name) after {SmokeRunner} and {BundledTestRunner} were
  # specifically fixed to invoke a *particular* Ruby -- the one belonging to
  # the baked tree under test -- not whichever one happens to be first on
  # PATH. Documenting the parameter as "an absolute path" in a YARD comment
  # doesn't stop a caller from passing a bare command name; only checking it
  # here does.
  module ExecutablePath
    # @param path [Object] candidate executable path. Rejects anything that
    #   isn't already a String outright -- verified directly that
    #   +File.absolute_path?+ raises a bare +TypeError+ on non-String input
    #   (e.g. an Integer or Symbol), the same failure mode {SafeToken} had
    #   to be fixed for; checking the type here keeps the promised
    #   +ArgumentError+ contract instead of leaking that.
    # @param label [String] used only in the raised error message
    # @raise [ArgumentError] if +path+ is nil, not a String, blank, not
    #   absolute, doesn't exist, or isn't executable
    def self.validate!(path, label)
      raise ArgumentError, "#{label} must not be nil or empty" if path.nil?
      raise ArgumentError, "#{label} must be a String, got #{path.class}: #{path.inspect}" unless path.is_a?(String)
      raise ArgumentError, "#{label} must not be nil or empty" if path.strip.empty?
      raise ArgumentError, "#{label} must be an absolute path, got #{path.inspect}" unless File.absolute_path?(path)
      raise ArgumentError, "#{label} does not exist: #{path.inspect}" unless File.exist?(path)
      raise ArgumentError, "#{label} is not executable: #{path.inspect}" unless File.executable?(path)
    end
  end
end
