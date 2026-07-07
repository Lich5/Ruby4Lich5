# frozen_string_literal: true

module Ruby4Lich5
  # Determines, for every +:native_self_contained+ entry in a
  # {BuildPlanner#plan_for} plan, whether it's a build's DLL-vendoring
  # *root* or a *dependent* -- the piece of build-order knowledge that used
  # to live only as an implicit, hand-maintained fact in
  # +ruby4-bundled-gems-suite.yml+ (glib2/cairo hardcoded as the two gems
  # that get a real DLL closure walk + vendor copy + rebuild; everything
  # else just gets a single build).
  #
  # A gem is a *root* when none of its own resolved runtime dependencies are
  # themselves +:native_self_contained+ -- there's nothing upstream of it in
  # this closure that could already have added a DLL search directory for
  # it to piggyback on, so it needs its own real vendored copy. A gem is a
  # *dependent* when at least one of its runtime dependencies is also
  # +:native_self_contained+ -- by the time its own require-time
  # +prepend_dll_path+/+add_dll_directory+ call runs, that dependency has
  # already been required first and already added a directory to the
  # process-wide DLL search path (Windows' +AddDllDirectory+ is per-process,
  # not per-module), so its own vendor directory can stay empty without
  # anything actually breaking.
  #
  # Deliberately says nothing about gem-specific vendored *assets* beyond
  # DLLs (gobject-introspection's typelibs/fontconfig/gdk-pixbuf loaders,
  # say) -- those aren't a DLL-closure concern at all and stay exactly what
  # they've always been: bespoke, per-gem, hand-built steps layered on top.
  #
  # Known, deliberate scope limit (flagged in review, 2026-07-07, confirmed
  # real): {#classify} only sees {BuildPlanner#plan_for}'s *filtered* plan,
  # which already omits any gem the curation manifest reports as satisfied
  # -- so a root's own dependency could theoretically be a
  # +:native_self_contained+ gem that's satisfied (already built/published)
  # and therefore invisible here, causing its dependent to be misclassified
  # as +:vendoring_root+ instead of +:vendoring_dependent+. Not reachable
  # today: neither {NativeGemPreparer} nor +bin/prepare_native_gems.rb+
  # passes a populated +CurationManifest+, so +plan_for+ never actually
  # omits anything in the real pipeline as it exists now. Roles from this
  # class mean "among gems being built in *this* plan," not "within the
  # full historical/satisfied runtime closure" -- resolve this properly
  # (feed classification data for satisfied gems too, or extend
  # +CurationManifest+ to carry it) before wiring a real curation manifest
  # in, not before.
  class VendoringRoleClassifier
    # @return [Array<Symbol>]
    ROLES = %i[vendoring_root vendoring_dependent].freeze

    # @param plan [Array<Hash>] a {BuildPlanner#plan_for} result -- each
    #   entry must carry +:name+, +:classification+, and
    #   +:runtime_dependency_names+
    # @return [Hash{String => Symbol}] gem name => role (one of {ROLES}),
    #   one entry per +:native_self_contained+ gem in +plan+. Gems
    #   classified +:pure+ or +:native_pass_through+ don't need vendoring at
    #   all and are omitted entirely, not assigned a role.
    def classify(plan)
      self_contained_names = plan.each_with_object({}) do |entry, names|
        names[entry.fetch(:name)] = true if entry.fetch(:classification).self_contained?
      end

      plan.each_with_object({}) do |entry, roles|
        next unless entry.fetch(:classification).self_contained?

        depends_on_another_root_candidate = entry.fetch(:runtime_dependency_names).any? { |dep| self_contained_names[dep] }
        roles[entry.fetch(:name)] = depends_on_another_root_candidate ? :vendoring_dependent : :vendoring_root
      end
    end
  end
end
