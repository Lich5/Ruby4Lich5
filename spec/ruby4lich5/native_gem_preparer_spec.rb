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

    context 'with a :native_self_contained entry' do
      before do
        write_gemspec('widget')
        allow(build_planner).to receive(:plan_for).and_return(
          [{ name: 'widget', version: '1.0.0', classification: classification(:native_self_contained) }]
        )
        allow(patch_applier).to receive(:apply_all).and_return([{ patch: 'some-fix', status: :applied }])
      end

      it 'normalizes the gemspec at source_root/<name>, using the gem-name-scoped platform' do
        preparer.prepare('widget', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0', source_root: @source_root)

        expect(gemspec_normalizer)
          .to have_received(:normalize).with('widget', File.join(@source_root, 'widget'), platform: 'x64-mingw-ucrt')
      end

      it 'applies curated patches at the same source_root/<name> path' do
        preparer.prepare('widget', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0', source_root: @source_root)

        expect(patch_applier).to have_received(:apply_all).with('widget', File.join(@source_root, 'widget'))
      end

      it 'normalizes before patching, not the other way around' do
        order = []
        allow(gemspec_normalizer).to receive(:normalize) { order << :normalize }
        allow(patch_applier).to receive(:apply_all) do
          order << :patch
          []
        end

        preparer.prepare('widget', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0', source_root: @source_root)

        expect(order).to eq(%i[normalize patch])
      end

      it "reports PatchApplier's own result verbatim as patches_applied" do
        result = preparer.prepare('widget', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0', source_root: @source_root)

        expect(result.first.fetch(:patches_applied)).to eq([{ patch: 'some-fix', status: :applied }])
      end

      it 'includes msys2_packages in the result, for the surrounding workflow to install' do
        result = preparer.prepare('widget', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0', source_root: @source_root)

        expect(result.first.fetch(:msys2_packages)).to eq(%w[mingw-w64-ucrt-x86_64-widget])
      end
    end

    context 'when the gemspec is missing entirely for a :native_self_contained gem' do
      before do
        allow(build_planner).to receive(:plan_for).and_return(
          [{ name: 'widget', version: '1.0.0', classification: classification(:native_self_contained) }]
        )
      end

      it 'raises NormalizationError naming the missing gemspec, rather than reaching PatchApplier at all' do
        expect { preparer.prepare('widget', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0', source_root: @source_root) }
          .to raise_error(Ruby4Lich5::GemspecNormalizer::NormalizationError, /widget\.gemspec/)
      end
    end

    context 'auto-generating a missing patch (item 7a)' do
      let(:plan) do
        [{ name: 'widget', version: '1.0.0', classification: classification(:native_self_contained), runtime_dependency_names: [] }]
      end

      before do
        write_gemspec('widget')
        allow(build_planner).to receive(:plan_for).and_return(plan)
      end

      context 'when the gem already has at least one patch' do
        before { allow(patch_applier).to receive(:patches_exist_for?).with('widget').and_return(true) }

        it 'never calls the generator at all -- an existing patch, hand-written or generated, is never touched' do
          preparer.prepare('widget', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0', source_root: @source_root)

          expect(patch_generator).not_to have_received(:generate)
        end
      end

      context 'when the gem has no patch at all yet' do
        before { allow(patch_applier).to receive(:patches_exist_for?).with('widget').and_return(false) }

        it 'calls the generator before PatchApplier runs, at the gem-name-scoped source path' do
          order = []
          allow(patch_generator).to receive(:generate) { order << :generate }
          allow(patch_applier).to receive(:apply_all) { order << :apply }

          preparer.prepare('widget', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0', source_root: @source_root)

          expect(patch_generator)
            .to have_received(:generate).with('widget', File.join(@source_root, 'widget'), depends_on_glib2: false)
          expect(order).to eq(%i[generate apply])
        end

        it 'passes depends_on_glib2: true when glib2 is reachable in the plan' do
          write_gemspec('glib2')
          plan_with_glib2 = [
            { name: 'glib2', version: '1.0.0', classification: classification(:native_self_contained, gem_name: 'glib2'), runtime_dependency_names: [] },
            {
              name: 'widget', version: '1.0.0', classification: classification(:native_self_contained),
              runtime_dependency_names: ['glib2']
            }
          ]
          allow(build_planner).to receive(:plan_for).and_return(plan_with_glib2)
          allow(patch_applier).to receive(:patches_exist_for?).with('glib2').and_return(true)

          preparer.prepare('widget', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0', source_root: @source_root)

          expect(patch_generator)
            .to have_received(:generate).with('widget', File.join(@source_root, 'widget'), depends_on_glib2: true)
        end

        it 'treats NoAnchorFound as success for the one verified-safe exemption -- ' \
           "ruby-gnome's own dependency-check/Rakefile task, confirmed real against atk/gdk3/gdk_pixbuf2's " \
           'actual gemspecs, confirmed to compile nothing' do
          write_gemspec('widget', extensions: ['dependency-check/Rakefile'])
          allow(patch_generator).to receive(:generate).and_raise(Ruby4Lich5::PatchGenerator::NoAnchorFound, 'no anchor')

          expect { preparer.prepare('widget', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0', source_root: @source_root) }
            .not_to raise_error
        end

        it 'still lets PatchApplier run afterward even when generation found nothing to do' do
          write_gemspec('widget', extensions: ['dependency-check/Rakefile'])
          allow(patch_generator).to receive(:generate).and_raise(Ruby4Lich5::PatchGenerator::NoAnchorFound, 'no anchor')

          preparer.prepare('widget', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0', source_root: @source_root)

          expect(patch_applier).to have_received(:apply_all).with('widget', File.join(@source_root, 'widget'))
        end

        it 'still recognizes the exemption even though normalize would, for real, have already stripped ' \
           "s.extensions from the gemspec on disk by the time PatchGenerator runs -- proves extensions are " \
           'read before normalize, not after' do
          write_gemspec('widget', extensions: ['dependency-check/Rakefile'])
          allow(gemspec_normalizer).to receive(:normalize) do |name, gem_root, **|
            File.write(File.join(gem_root, "#{name}.gemspec"), "Gem::Specification.new { |s| s.name = 'widget'; s.version = '1.0.0' }\n")
          end
          allow(patch_generator).to receive(:generate).and_raise(Ruby4Lich5::PatchGenerator::NoAnchorFound, 'no anchor')

          expect { preparer.prepare('widget', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0', source_root: @source_root) }
            .not_to raise_error
        end

        it 'propagates NoAnchorFound when the declared extension is extconf.rb -- ' \
           'an unrecognized anchor syntax is not proof there is nothing to require' do
          write_gemspec('widget', extensions: ['ext/widget/extconf.rb'])
          allow(patch_generator).to receive(:generate).and_raise(Ruby4Lich5::PatchGenerator::NoAnchorFound, 'no anchor')

          expect { preparer.prepare('widget', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0', source_root: @source_root) }
            .to raise_error(Ruby4Lich5::PatchGenerator::NoAnchorFound, 'no anchor')
        end

        it 'propagates NoAnchorFound for any other declared builder too, not just extconf.rb -- fails closed ' \
           'on unknown mechanisms (configure, CMake, Cargo, mkrf_conf.rb, etc.) rather than guessing which ' \
           'filenames imply compilation, real gap found 2026-07-08' do
          write_gemspec('widget', extensions: ['ext/widget/configure'])
          allow(patch_generator).to receive(:generate).and_raise(Ruby4Lich5::PatchGenerator::NoAnchorFound, 'no anchor')

          expect { preparer.prepare('widget', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0', source_root: @source_root) }
            .to raise_error(Ruby4Lich5::PatchGenerator::NoAnchorFound, 'no anchor')
        end

        it 'propagates AmbiguousAnchor -- genuinely unclear which anchor is real, a human needs to look' do
          allow(patch_generator).to receive(:generate).and_raise(Ruby4Lich5::PatchGenerator::AmbiguousAnchor, 'ambiguous')

          expect { preparer.prepare('widget', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0', source_root: @source_root) }
            .to raise_error(Ruby4Lich5::PatchGenerator::AmbiguousAnchor, 'ambiguous')
        end
      end
    end

    context 'vendoring role' do
      let(:plan) do
        [{ name: 'widget', version: '1.0.0', classification: classification(:native_self_contained) }]
      end

      before do
        write_gemspec('widget')
        allow(build_planner).to receive(:plan_for).and_return(plan)
      end

      it 'classifies the raw plan_for result once, before any entry is flattened for output' do
        preparer.prepare('widget', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0', source_root: @source_root)

        expect(vendoring_role_classifier).to have_received(:classify).with(plan).once
      end

      it "includes VendoringRoleClassifier's role for a gem it names" do
        allow(vendoring_role_classifier).to receive(:classify).and_return({ 'widget' => :vendoring_root })

        result = preparer.prepare('widget', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0', source_root: @source_root)

        expect(result.first.fetch(:vendoring_role)).to eq(:vendoring_root)
      end

      it 'reports nil for a gem VendoringRoleClassifier omitted (not self-contained, or empty plan)' do
        allow(vendoring_role_classifier).to receive(:classify).and_return({})

        result = preparer.prepare('widget', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0', source_root: @source_root)

        expect(result.first.fetch(:vendoring_role)).to be_nil
      end
    end

    context 'with a mixed closure -- some entries need preparation, some do not' do
      before do
        write_gemspec('widget')
        allow(build_planner).to receive(:plan_for).and_return(
          [
            { name: 'leaf-pure', version: '1.0.0', classification: classification(:pure, gem_name: 'leaf-pure') },
            {
              name: 'widget', version: '1.0.0',
              classification: classification(:native_self_contained, gem_name: 'widget')
            }
          ]
        )
        allow(patch_applier).to receive(:apply_all).and_return([])
      end

      it 'only prepares the self-contained entry, preserving BuildPlanner order' do
        result = preparer.prepare('widget', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0', source_root: @source_root)

        expect(result.map { |r| r.fetch(:name) }).to eq(%w[leaf-pure widget])
        expect(gemspec_normalizer)
          .to have_received(:normalize).once.with('widget', File.join(@source_root, 'widget'), platform: anything)
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
end
