# frozen_string_literal: true

module Ruby4Lich5
  # Determines whether glib2 is reachable from a gem's own runtime-dependency
  # closure, in a {BuildPlanner#plan_for} plan -- the decision
  # {PatchGenerator}'s glib2-vs-fallback branch needs (does an upstream gem
  # already provide a DLL-path helper this gem can call, or does it need to
  # do it itself).
  #
  # Deliberately its own thing, not folded into {VendoringRoleClassifier}:
  # that class answers "does this gem need its own vendor/local/bin
  # populated," a build-order question about the whole closure; this answers
  # "does GLib.prepend_dll_path already exist and get called by the time
  # this gem's own require-time code runs," a single-target reachability
  # question a totally different, non-GTK gem could ask too (see glib2 case
  # below) without needing to know anything about vendoring roots at all.
  #
  # glib2 itself is the one real special case: it never appears in its own
  # +runtime_dependency_names+ (nothing depends on itself), but its own real
  # patch calls +GLib.prepend_dll_path+ regardless, since it defines that
  # method and calls it on itself -- {.reachable?} returns +true+ for
  # +'glib2'+ directly rather than only via graph search, matching that.
  module Glib2Reachability
    GLIB2 = 'glib2'
    private_constant :GLIB2

    # @param gem_name [String]
    # @param plan [Array<Hash>] a {BuildPlanner#plan_for} result -- each
    #   entry must carry +:name+ and +:runtime_dependency_names+
    # @return [Boolean]
    def self.reachable?(gem_name, plan)
      return true if gem_name == GLIB2

      deps_by_name = plan.each_with_object({}) { |entry, h| h[entry.fetch(:name)] = entry.fetch(:runtime_dependency_names) }

      visited = {}
      queue = (deps_by_name[gem_name] || []).dup
      until queue.empty?
        current = queue.shift
        next if visited[current]

        visited[current] = true
        return true if current == GLIB2

        queue.concat(deps_by_name[current] || [])
      end

      false
    end
  end
end
