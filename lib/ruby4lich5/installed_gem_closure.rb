# frozen_string_literal: true

module Ruby4Lich5
  # Walks the gem specs actually *installed* on this machine, starting from a
  # requested top-level name list, and returns the full closure with
  # runtime-dependency edges intact.
  #
  # The equivalent logic already exists inline in
  # +ruby4-bundled-gems-suite.yml+'s "Build runtime bundle" step -- it
  # computes these exact edges to decide which +.gem+ files to stage, then
  # discards them immediately afterward, keeping only a flat filename list.
  # This class is that same walk, extracted so a caller (the gem manifest
  # generator) can keep the edges instead of losing them.
  class InstalledGemClosure
    # Raised when a requested name has no matching installed spec at all --
    # a real gap (something the caller asked for was never actually
    # installed), distinct from a default gem being silently pruned.
    class MissingSpecError < StandardError; end

    # @param requested_names [Array<String>] top-level gem names to resolve
    #   from, already split (e.g. the +runtime-gems+ workflow input)
    # @param excluded_names [Array<String>] names to drop from the closure
    #   entirely wherever encountered, before their own dependencies are
    #   walked -- matches the existing inline script's +RUNTIME_GEM_EXCLUDES+
    #   semantics
    # @param find_specs [#call] +->(name) { [Gem::Specification, ...] }+,
    #   defaults to a real +Gem::Specification.find_all_by_name+ call against
    #   whatever's actually installed; specs should inject a stub so they
    #   never depend on the running process's own installed gems
    def initialize(requested_names:, excluded_names: [], find_specs: method(:default_find_specs))
      @requested_names = requested_names
      @excluded_names = Set.new(excluded_names)
      @find_specs = find_specs
    end

    # @return [Array<Hash>] +{name:, version:, runtime_dependency_names:}+
    #   entries, topologically sorted (dependencies before dependents).
    #   Default gems are silently pruned (matching the existing script's
    #   behavior -- Ruby itself already provides them, nothing to record or
    #   recurse into). A name with no installed spec at all is a real error,
    #   not silently skipped.
    # @raise [MissingSpecError]
    def resolve
      selected = {}
      queue = @requested_names.dup

      until queue.empty?
        name = queue.shift
        next if name.nil? || name.to_s.strip.empty? || @excluded_names.include?(name) || selected.key?(name)

        spec = installed_spec_for(name)
        next if spec.default_gem? || @excluded_names.include?(spec.name) || selected.key?(spec.name)

        runtime_dependency_names = spec.runtime_dependencies.map { |dep| dep.name }
        selected[spec.name] = { name: spec.name, version: spec.version.to_s,
                                 runtime_dependency_names: runtime_dependency_names }
        queue.concat(runtime_dependency_names)
      end

      topological_sort(selected)
    end

    private

    # @param name [String]
    # @return [Gem::Specification] the highest-version non-default installed
    #   spec for +name+, or the highest-version spec of any kind if every
    #   installed copy happens to be a default gem
    # @raise [MissingSpecError] if nothing installed matches +name+ at all
    def installed_spec_for(name)
      specs = @find_specs.call(name)
      spec = specs.reject(&:default_gem?).max_by(&:version) || specs.max_by(&:version)
      raise MissingSpecError, "requested gem #{name.inspect} is not installed" if spec.nil?

      spec
    end

    # Post-order depth-first traversal, same shape as
    # {ClosureResolver#topological_sort} -- every dependency appears before
    # anything that depends on it. A dependency name absent from +selected+
    # here is expected and benign (it was pruned as a default gem, or
    # excluded), unlike {ClosureResolver}'s own version of this method,
    # where an absent dependency is always an error -- this class resolves
    # against real installed state, where "present but intentionally not
    # tracked" is a normal outcome, not a sign of an incomplete resolution.
    #
    # @param selected [Hash{String => Hash}] name => node, as built by
    #   {#resolve}
    # @return [Array<Hash>]
    def topological_sort(selected)
      visited = {}
      ordered = []

      visit = lambda do |name|
        next if visited[name]

        visited[name] = true
        node = selected[name]
        next if node.nil?

        node.fetch(:runtime_dependency_names).each { |dep_name| visit.call(dep_name) }
        ordered << node
      end

      selected.each_key { |name| visit.call(name) }
      ordered
    end

    # @param name [String]
    # @return [Array<Gem::Specification>]
    def default_find_specs(name)
      Gem::Specification.find_all_by_name(name)
    end
  end
end
