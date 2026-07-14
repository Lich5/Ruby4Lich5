# frozen_string_literal: true

require 'ruby4lich5/native_gem_preparer'
require 'tmpdir'
require 'fileutils'

RSpec.describe Ruby4Lich5::NativeGemPreparer do
  let(:build_planner) { instance_double(Ruby4Lich5::BuildPlanner) }
  let(:gemspec_normalizer) { instance_double(Ruby4Lich5::GemspecNormalizer) }
  let(:patch_applier) { instance_double(Ruby4Lich5::PatchApplier) }
  let(:patch_generator) { instance_double(Ruby4Lich5::PatchGenerator) }
  let(:vendoring_role_classifier) { instance_double(Ruby4Lich5::VendoringRoleClassifier) }
  subject(:preparer) do
    described_class.new(
      build_planner: build_planner, gemspec_normalizer: gemspec_normalizer, patch_applier: patch_applier,
      patch_generator: patch_generator, vendoring_role_classifier: vendoring_role_classifier
    )
  end

  def classification(state, gem_name: 'widget', gem_version: '1.0.0', platform_asset: nil, msys2_packages: nil)
    msys2_packages ||= %w[mingw-w64-ucrt-x86_64-widget] if state == :native_self_contained
    Ruby4Lich5::Classification.new(
      state: state,
      gem_name: gem_name,
      gem_version: gem_version,
      reason: "classified as #{state}",
      platform_asset: platform_asset,
      msys2_packages: msys2_packages
    )
  end

  # A real, loadable gemspec at source_root/<name>/<name>.gemspec --
  # NativeGemPreparer#declared_extensions reads this for real via
  # Gem::Specification.load, so a stubbed/fake path can't stand in for it
  # the way the other collaborators (all injected doubles) can.
  def write_gemspec(name, extensions: ['ext/widget/extconf.rb'])
    gem_dir = File.join(@source_root, name)
    FileUtils.mkdir_p(gem_dir)
    File.write(File.join(gem_dir, "#{name}.gemspec"), <<~RUBY)
      Gem::Specification.new do |s|
        s.name = #{name.inspect}
        s.version = "1.0.0"
        s.summary = "fixture"
        s.authors = ["fixture"]
        s.extensions = #{extensions.inspect}
      end
    RUBY
  end

  around do |example|
    Dir.mktmpdir('ruby4lich5-native-gem-preparer-spec') { |dir| @source_root = dir and example.run }
  end

  # Stubbed as no-op spies by default so `not_to have_received` can verify
  # zero invocations even in contexts that never expect a call at all --
  # instance_double requires a method to be stubbed before it can be spied
  # on, even to assert it was *not* called.
  before do
    allow(gemspec_normalizer).to receive(:normalize)
    allow(patch_applier).to receive(:apply_all)
    # Default: a patch already exists, so maybe_generate_patch's guard short-circuits
    # and patch_generator is never touched -- keeps every context that doesn't care
    # about generation from needing to know it exists at all.
    allow(patch_applier).to receive(:patches_exist_for?).and_return(true)
    allow(patch_generator).to receive(:generate)
    allow(vendoring_role_classifier).to receive(:classify).and_return({})
  end

  describe '#prepare' do
    it 'calls BuildPlanner#plan_for with the given request' do
      allow(build_planner).to receive(:plan_for)
        .with('widget', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0').and_return([])

      preparer.prepare('widget', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0', source_root: @source_root)

      expect(build_planner).to have_received(:plan_for)
    end

    context 'with a :pure entry' do
      before do
        allow(build_planner).to receive(:plan_for).and_return(
          [{ name: 'widget', version: '1.0.0', classification: classification(:pure) }]
        )
      end

      it 'neither normalizes nor patches, and reports empty patches_applied' do
        result = preparer.prepare('widget', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0', source_root: @source_root)

        expect(gemspec_normalizer).not_to have_received(:normalize)
        expect(patch_applier).not_to have_received(:apply_all)
        expect(result).to eq(
          [{
            name: 'widget', version: '1.0.0', state: :pure, reason: 'classified as pure',
            platform_asset: nil, msys2_packages: nil, vendoring_role: nil, patches_applied: []
          }]
        )
      end
    end

    context 'with a :native_pass_through entry' do
      before do
        allow(build_planner).to receive(:plan_for).and_return(
          [{
            name: 'widget', version: '1.0.0',
            classification: classification(:native_pass_through, platform_asset: 'widget-1.0.0-x64-mingw-ucrt.gem')
          }]
        )
      end

      it 'neither normalizes nor patches, and reports empty patches_applied' do
        result = preparer.prepare('widget', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0', source_root: @source_root)

        expect(gemspec_normalizer).not_to have_received(:normalize)
        expect(patch_applier).not_to have_received(:apply_all)
        expect(result.first).to include(state: :native_pass_through, platform_asset: 'widget-1.0.0-x64-mingw-ucrt.gem')
      end
    end

    # 'gtk3' here, not the generic 'widget' placeholder used elsewhere in this
    # file -- real gap, found live 2026-07-14 (this project's first real
    # dispatch of the "resolve once" cutover): the normalize/patch treatment
    # below only applies to the fixed Ruby-GNOME/GTK3 stack now (see
    # NativeGemPreparer::GTK3_STACK's own doc comment), not to every
    # :native_self_contained entry in general, so these tests need a real
    # stack member to still exercise that treatment at all.
    context 'with a :native_self_contained entry (a real GTK3-stack member)' do
      before do
        write_gemspec('gtk3')
        allow(build_planner).to receive(:plan_for).and_return(
          [{ name: 'gtk3', version: '1.0.0', classification: classification(:native_self_contained, gem_name: 'gtk3') }]
        )
        allow(patch_applier).to receive(:apply_all).and_return([{ patch: 'some-fix', status: :applied }])
      end

      it 'normalizes the gemspec at source_root/<name>, using the gem-name-scoped platform' do
        preparer.prepare('gtk3', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0', source_root: @source_root)

        expect(gemspec_normalizer)
          .to have_received(:normalize).with('gtk3', File.join(@source_root, 'gtk3'), platform: 'x64-mingw-ucrt')
      end

      it 'applies curated patches at the same source_root/<name> path' do
        preparer.prepare('gtk3', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0', source_root: @source_root)

        expect(patch_applier).to have_received(:apply_all).with('gtk3', File.join(@source_root, 'gtk3'))
      end

      it 'normalizes before patching, not the other way around' do
        order = []
        allow(gemspec_normalizer).to receive(:normalize) { order << :normalize }
        allow(patch_applier).to receive(:apply_all) do
          order << :patch
          []
        end

        preparer.prepare('gtk3', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0', source_root: @source_root)

        expect(order).to eq(%i[normalize patch])
      end

      it "reports PatchApplier's own result verbatim as patches_applied" do
        result = preparer.prepare('gtk3', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0', source_root: @source_root)

        expect(result.first.fetch(:patches_applied)).to eq([{ patch: 'some-fix', status: :applied }])
      end

      it 'includes msys2_packages in the result, for the surrounding workflow to install' do
        result = preparer.prepare('gtk3', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0', source_root: @source_root)

        expect(result.first.fetch(:msys2_packages)).to eq(%w[mingw-w64-ucrt-x86_64-widget])
      end
    end

    context 'when the gemspec is missing entirely for a :native_self_contained gem (a real GTK3-stack member)' do
      before do
        allow(build_planner).to receive(:plan_for).and_return(
          [{ name: 'gtk3', version: '1.0.0', classification: classification(:native_self_contained, gem_name: 'gtk3') }]
        )
      end

      it 'raises NormalizationError naming the missing gemspec, rather than reaching PatchApplier at all' do
        expect { preparer.prepare('gtk3', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0', source_root: @source_root) }
          .to raise_error(Ruby4Lich5::GemspecNormalizer::NormalizationError, /gtk3\.gemspec/)
      end
    end

    context 'auto-generating a missing patch (item 7a), for a real GTK3-stack member' do
      let(:plan) do
        [{ name: 'gtk3', version: '1.0.0', classification: classification(:native_self_contained, gem_name: 'gtk3'), runtime_dependency_names: [] }]
      end

      before do
        write_gemspec('gtk3')
        allow(build_planner).to receive(:plan_for).and_return(plan)
      end

      context 'when the gem already has at least one patch' do
        before { allow(patch_applier).to receive(:patches_exist_for?).with('gtk3').and_return(true) }

        it 'never calls the generator at all -- an existing patch, hand-written or generated, is never touched' do
          preparer.prepare('gtk3', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0', source_root: @source_root)

          expect(patch_generator).not_to have_received(:generate)
        end
      end

      context 'when the gem has no patch at all yet' do
        before { allow(patch_applier).to receive(:patches_exist_for?).with('gtk3').and_return(false) }

        it 'calls the generator before PatchApplier runs, at the gem-name-scoped source path' do
          order = []
          allow(patch_generator).to receive(:generate) { order << :generate }
          allow(patch_applier).to receive(:apply_all) { order << :apply }

          preparer.prepare('gtk3', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0', source_root: @source_root)

          expect(patch_generator)
            .to have_received(:generate).with('gtk3', File.join(@source_root, 'gtk3'), depends_on_glib2: false)
          expect(order).to eq(%i[generate apply])
        end

        it 'passes depends_on_glib2: true when glib2 is reachable in the plan' do
          write_gemspec('glib2')
          plan_with_glib2 = [
            { name: 'glib2', version: '1.0.0', classification: classification(:native_self_contained, gem_name: 'glib2'), runtime_dependency_names: [] },
            {
              name: 'gtk3', version: '1.0.0', classification: classification(:native_self_contained, gem_name: 'gtk3'),
              runtime_dependency_names: ['glib2']
            }
          ]
          allow(build_planner).to receive(:plan_for).and_return(plan_with_glib2)
          allow(patch_applier).to receive(:patches_exist_for?).with('glib2').and_return(true)

          preparer.prepare('gtk3', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0', source_root: @source_root)

          expect(patch_generator)
            .to have_received(:generate).with('gtk3', File.join(@source_root, 'gtk3'), depends_on_glib2: true)
        end

        it 'treats NoAnchorFound as success for the one verified-safe exemption -- ' \
           "ruby-gnome's own dependency-check/Rakefile task, confirmed real against atk/gdk3/gdk_pixbuf2's " \
           'actual gemspecs, confirmed to compile nothing' do
          write_gemspec('gtk3', extensions: ['dependency-check/Rakefile'])
          allow(patch_generator).to receive(:generate).and_raise(Ruby4Lich5::PatchGenerator::NoAnchorFound, 'no anchor')

          expect { preparer.prepare('gtk3', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0', source_root: @source_root) }
            .not_to raise_error
        end

        it 'still lets PatchApplier run afterward even when generation found nothing to do' do
          write_gemspec('gtk3', extensions: ['dependency-check/Rakefile'])
          allow(patch_generator).to receive(:generate).and_raise(Ruby4Lich5::PatchGenerator::NoAnchorFound, 'no anchor')

          preparer.prepare('gtk3', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0', source_root: @source_root)

          expect(patch_applier).to have_received(:apply_all).with('gtk3', File.join(@source_root, 'gtk3'))
        end

        it 'still recognizes the exemption even though normalize would, for real, have already stripped ' \
           "s.extensions from the gemspec on disk by the time PatchGenerator runs -- proves extensions are " \
           'read before normalize, not after' do
          write_gemspec('gtk3', extensions: ['dependency-check/Rakefile'])
          allow(gemspec_normalizer).to receive(:normalize) do |name, gem_root, **|
            File.write(File.join(gem_root, "#{name}.gemspec"), "Gem::Specification.new { |s| s.name = 'gtk3'; s.version = '1.0.0' }\n")
          end
          allow(patch_generator).to receive(:generate).and_raise(Ruby4Lich5::PatchGenerator::NoAnchorFound, 'no anchor')

          expect { preparer.prepare('gtk3', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0', source_root: @source_root) }
            .not_to raise_error
        end

        it 'propagates NoAnchorFound when the declared extension is extconf.rb -- ' \
           'an unrecognized anchor syntax is not proof there is nothing to require' do
          write_gemspec('gtk3', extensions: ['ext/gtk3/extconf.rb'])
          allow(patch_generator).to receive(:generate).and_raise(Ruby4Lich5::PatchGenerator::NoAnchorFound, 'no anchor')

          expect { preparer.prepare('gtk3', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0', source_root: @source_root) }
            .to raise_error(Ruby4Lich5::PatchGenerator::NoAnchorFound, 'no anchor')
        end

        it 'propagates NoAnchorFound for any other declared builder too, not just extconf.rb -- fails closed ' \
           'on unknown mechanisms (configure, CMake, Cargo, mkrf_conf.rb, etc.) rather than guessing which ' \
           'filenames imply compilation, real gap found 2026-07-08' do
          write_gemspec('gtk3', extensions: ['ext/gtk3/configure'])
          allow(patch_generator).to receive(:generate).and_raise(Ruby4Lich5::PatchGenerator::NoAnchorFound, 'no anchor')

          expect { preparer.prepare('gtk3', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0', source_root: @source_root) }
            .to raise_error(Ruby4Lich5::PatchGenerator::NoAnchorFound, 'no anchor')
        end

        it 'propagates AmbiguousAnchor -- genuinely unclear which anchor is real, a human needs to look' do
          allow(patch_generator).to receive(:generate).and_raise(Ruby4Lich5::PatchGenerator::AmbiguousAnchor, 'ambiguous')

          expect { preparer.prepare('gtk3', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0', source_root: @source_root) }
            .to raise_error(Ruby4Lich5::PatchGenerator::AmbiguousAnchor, 'ambiguous')
        end
      end
    end

    context 'vendoring role' do
      # 'ox' (on the repack-only allowlist), not the generic 'widget'
      # placeholder -- vendoring_role assignment is orthogonal to patch
      # eligibility, but 'widget' is neither a GTK3-stack member nor on
      # REPACK_ONLY_GEMS, so it now raises UnconfiguredNativeGemError
      # (real gap, found in review 2026-07-13) rather than reaching the
      # point these tests care about at all.
      let(:plan) do
        [{ name: 'ox', version: '1.0.0', classification: classification(:native_self_contained, gem_name: 'ox') }]
      end

      before do
        allow(build_planner).to receive(:plan_for).and_return(plan)
      end

      it 'classifies the raw plan_for result once, before any entry is flattened for output' do
        preparer.prepare('ox', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0', source_root: @source_root)

        expect(vendoring_role_classifier).to have_received(:classify).with(plan).once
      end

      it "includes VendoringRoleClassifier's role for a gem it names" do
        allow(vendoring_role_classifier).to receive(:classify).and_return({ 'ox' => :vendoring_root })

        result = preparer.prepare('ox', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0', source_root: @source_root)

        expect(result.first.fetch(:vendoring_role)).to eq(:vendoring_root)
      end

      it 'reports nil for a gem VendoringRoleClassifier omitted (not self-contained, or empty plan)' do
        allow(vendoring_role_classifier).to receive(:classify).and_return({})

        result = preparer.prepare('ox', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0', source_root: @source_root)

        expect(result.first.fetch(:vendoring_role)).to be_nil
      end
    end

    context 'with a mixed closure -- some entries need preparation, some do not' do
      before do
        write_gemspec('gtk3')
        allow(build_planner).to receive(:plan_for).and_return(
          [
            { name: 'leaf-pure', version: '1.0.0', classification: classification(:pure, gem_name: 'leaf-pure') },
            {
              name: 'gtk3', version: '1.0.0',
              classification: classification(:native_self_contained, gem_name: 'gtk3')
            }
          ]
        )
        allow(patch_applier).to receive(:apply_all).and_return([])
      end

      it 'only prepares the self-contained entry, preserving BuildPlanner order' do
        result = preparer.prepare('gtk3', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0', source_root: @source_root)

        expect(result.map { |r| r.fetch(:name) }).to eq(%w[leaf-pure gtk3])
        expect(gemspec_normalizer)
          .to have_received(:normalize).once.with('gtk3', File.join(@source_root, 'gtk3'), platform: anything)
      end
    end

    context "when BuildPlanner itself raises" do
      it 'propagates ResolutionError rather than swallowing it' do
        allow(build_planner).to receive(:plan_for).and_raise(Ruby4Lich5::ClosureResolver::ResolutionError, 'boom')

        expect { preparer.prepare('widget', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0', source_root: @source_root) }
          .to raise_error(Ruby4Lich5::ClosureResolver::ResolutionError, 'boom')
      end

      it 'propagates UnbuildableGemError rather than swallowing it' do
        allow(build_planner).to receive(:plan_for)
          .and_raise(Ruby4Lich5::BuildPlanner::UnbuildableGemError, 'no system lib')

        expect { preparer.prepare('widget', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0', source_root: @source_root) }
          .to raise_error(Ruby4Lich5::BuildPlanner::UnbuildableGemError, 'no system lib')
      end
    end
  end

  # The locked-input counterpart to #prepare -- a caller holding an
  # already-resolved plan (e.g. the GTK subset of a real ResolutionLock's
  # own closure, translated into this shape) can normalize/patch it
  # without BuildPlanner ever being called at all.
  describe '#prepare_from_plan' do
    it 'never calls BuildPlanner#plan_for -- the whole point of a locked-input mode' do
      allow(build_planner).to receive(:plan_for)
      plan = [{ name: 'widget', version: '1.0.0', classification: classification(:pure), runtime_dependency_names: [] }]

      preparer.prepare_from_plan(plan, platform: 'x64-mingw-ucrt', source_root: @source_root)

      expect(build_planner).not_to have_received(:plan_for)
    end

    context 'with a :native_self_contained entry (a real GTK3-stack member)' do
      let(:plan) do
        [{ name: 'gtk3', version: '1.0.0', classification: classification(:native_self_contained, gem_name: 'gtk3'), runtime_dependency_names: [] }]
      end

      before do
        write_gemspec('gtk3')
        allow(patch_applier).to receive(:apply_all).and_return([{ patch: 'some-fix', status: :applied }])
      end

      it 'normalizes and patches exactly as #prepare would for the same entry shape' do
        result = preparer.prepare_from_plan(plan, platform: 'x64-mingw-ucrt', source_root: @source_root)

        expect(gemspec_normalizer)
          .to have_received(:normalize).with('gtk3', File.join(@source_root, 'gtk3'), platform: 'x64-mingw-ucrt')
        expect(patch_applier).to have_received(:apply_all).with('gtk3', File.join(@source_root, 'gtk3'))
        expect(result.first.fetch(:patches_applied)).to eq([{ patch: 'some-fix', status: :applied }])
      end
    end

    # Real, previously-latent gap, found live 2026-07-14 (this project's
    # first real dispatch of the "resolve once" cutover): an earlier version
    # of this class ran the exact same normalize/patch treatment for *every*
    # :native_self_contained closure member, including ox -- a real gem with
    # its own C extension that doesn't use Ruby-GNOME's bare `require "*.so"`
    # loading convention the auto-patch-generator's template anchors
    # against, so it raised PatchGenerator::NoAnchorFound, unrescued (its one
    # documented exemption is a different, narrower extensions shape -- see
    # the "auto-generating a missing patch" context above). ox has never
    # actually needed this treatment: it is compiled via ordinary
    # `gem install` and repacked entirely by the surrounding workflow's own
    # mechanism, never patched.
    context 'with a :native_self_contained entry outside the GTK3 stack (e.g. ox)' do
      let(:plan) do
        [{
          name: 'ox', version: '2.14.0', runtime_dependency_names: [],
          classification: classification(:native_self_contained, gem_name: 'ox', gem_version: '2.14.0')
        }]
      end

      it 'does not raise even when no gemspec exists on disk for it at all -- the real ox failure this closes' do
        expect { preparer.prepare_from_plan(plan, platform: 'x64-mingw-ucrt', source_root: @source_root) }
          .not_to raise_error
      end

      it 'never normalizes, generates, or applies a patch for it' do
        preparer.prepare_from_plan(plan, platform: 'x64-mingw-ucrt', source_root: @source_root)

        expect(gemspec_normalizer).not_to have_received(:normalize)
        expect(patch_generator).not_to have_received(:generate)
        expect(patch_applier).not_to have_received(:apply_all)
      end

      it 'reports empty patches_applied, but every other field intact' do
        allow(vendoring_role_classifier).to receive(:classify).and_return({ 'ox' => nil })

        result = preparer.prepare_from_plan(plan, platform: 'x64-mingw-ucrt', source_root: @source_root)

        expect(result).to eq(
          [{
            name: 'ox', version: '2.14.0', state: :native_self_contained, reason: 'classified as native_self_contained',
            platform_asset: nil, msys2_packages: %w[mingw-w64-ucrt-x86_64-widget], vendoring_role: nil, patches_applied: []
          }]
        )
      end

      it 'still patches a real GTK3-stack member elsewhere in the same plan' do
        write_gemspec('gtk3')
        allow(patch_applier).to receive(:apply_all).and_return([])
        mixed_plan = plan + [{
          name: 'gtk3', version: '1.0.0', runtime_dependency_names: [],
          classification: classification(:native_self_contained, gem_name: 'gtk3')
        }]

        preparer.prepare_from_plan(mixed_plan, platform: 'x64-mingw-ucrt', source_root: @source_root)

        expect(gemspec_normalizer).to have_received(:normalize).once.with('gtk3', File.join(@source_root, 'gtk3'), platform: anything)
      end
    end

    # P2, found in review 2026-07-13: the original ox fix treated "not in
    # GTK3_STACK" alone as proof a native_self_contained gem is safe to
    # skip -- proven for ox/curses specifically, never generalized. A
    # future self-contained gem this project hasn't yet examined must fail
    # closed, not silently repack, until a human explicitly adds it to
    # REPACK_ONLY_GEMS after actually confirming it needs no patching.
    context 'with a :native_self_contained entry that is neither a GTK3-stack member nor on the repack-only allowlist' do
      let(:plan) do
        [{
          name: 'some-new-gem', version: '1.0.0', runtime_dependency_names: [],
          classification: classification(:native_self_contained, gem_name: 'some-new-gem')
        }]
      end

      it 'raises UnconfiguredNativeGemError naming the gem, rather than silently skipping patching' do
        expect { preparer.prepare_from_plan(plan, platform: 'x64-mingw-ucrt', source_root: @source_root) }
          .to raise_error(Ruby4Lich5::NativeGemPreparer::UnconfiguredNativeGemError, /some-new-gem/)
      end

      it 'never normalizes or patches it before raising' do
        expect { preparer.prepare_from_plan(plan, platform: 'x64-mingw-ucrt', source_root: @source_root) }
          .to raise_error(Ruby4Lich5::NativeGemPreparer::UnconfiguredNativeGemError)

        expect(gemspec_normalizer).not_to have_received(:normalize)
        expect(patch_applier).not_to have_received(:apply_all)
      end

      # P2, found in review 2026-07-13: the check above used to live only
      # inside #prepare_one, discovered entry by entry during the plan's
      # own #map. A plan ordered [gtk3, some-new-gem] would normalize/patch
      # gtk3 -- a real filesystem mutation -- before ever reaching
      # some-new-gem and raising. Preflighted now, alongside the existing
      # unbuildable check, so the whole plan is validated before any entry
      # is touched.
      it 'never mutates an earlier GTK3-stack entry when a later entry in the same plan is unconfigured' do
        write_gemspec('gtk3')
        mixed_plan = [
          { name: 'gtk3', version: '1.0.0', runtime_dependency_names: [], classification: classification(:native_self_contained, gem_name: 'gtk3') },
          plan.first
        ]

        expect { preparer.prepare_from_plan(mixed_plan, platform: 'x64-mingw-ucrt', source_root: @source_root) }
          .to raise_error(Ruby4Lich5::NativeGemPreparer::UnconfiguredNativeGemError, /some-new-gem/)

        expect(gemspec_normalizer).not_to have_received(:normalize)
        expect(patch_generator).not_to have_received(:generate)
        expect(patch_applier).not_to have_received(:apply_all)
      end
    end

    it 'classifies vendoring roles from the given plan, same as #prepare' do
      plan = [{ name: 'widget', version: '1.0.0', classification: classification(:pure), runtime_dependency_names: [] }]
      allow(vendoring_role_classifier).to receive(:classify).with(plan).and_return({ 'widget' => :vendoring_root })

      result = preparer.prepare_from_plan(plan, platform: 'x64-mingw-ucrt', source_root: @source_root)

      expect(result.first.fetch(:vendoring_role)).to eq(:vendoring_root)
    end

    # Real gap, found in review: #prepare gets an UnbuildableGemError check
    # for free from BuildPlanner#plan_for itself (it raises before ever
    # returning a plan containing one) -- but a plan built elsewhere (a
    # lock's own closure, which #prepare_from_plan never asks
    # BuildPlanner to re-derive) was never passed through that same check.
    # Without this, a caller could silently normalize/patch a gem this
    # project already knows cannot be built.
    it 'raises UnbuildableGemError if any entry classifies as native_needs_system_lib' do
      plan = [
        {
          name: 'widget', version: '1.0.0',
          classification: Ruby4Lich5::Classification.new(
            state: :native_needs_system_lib, gem_name: 'widget', gem_version: '1.0.0', reason: 'no known way to vendor libfoo'
          ),
          runtime_dependency_names: []
        }
      ]

      expect { preparer.prepare_from_plan(plan, platform: 'x64-mingw-ucrt', source_root: @source_root) }
        .to raise_error(Ruby4Lich5::BuildPlanner::UnbuildableGemError, /widget 1\.0\.0.*no known way to vendor libfoo/)
    end

    it 'never normalizes or patches anything when the plan is rejected for an unbuildable entry' do
      write_gemspec('widget')
      plan = [
        {
          name: 'widget', version: '1.0.0',
          classification: Ruby4Lich5::Classification.new(
            state: :native_needs_system_lib, gem_name: 'widget', gem_version: '1.0.0', reason: 'no known way to vendor libfoo'
          ),
          runtime_dependency_names: []
        }
      ]

      expect { preparer.prepare_from_plan(plan, platform: 'x64-mingw-ucrt', source_root: @source_root) }
        .to raise_error(Ruby4Lich5::BuildPlanner::UnbuildableGemError)
      expect(gemspec_normalizer).not_to have_received(:normalize)
      expect(patch_applier).not_to have_received(:apply_all)
    end
  end
end
