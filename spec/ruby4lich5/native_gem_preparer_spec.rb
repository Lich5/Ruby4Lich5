# frozen_string_literal: true

require 'ruby4lich5/native_gem_preparer'

RSpec.describe Ruby4Lich5::NativeGemPreparer do
  let(:build_planner) { instance_double(Ruby4Lich5::BuildPlanner) }
  let(:gemspec_normalizer) { instance_double(Ruby4Lich5::GemspecNormalizer) }
  let(:patch_applier) { instance_double(Ruby4Lich5::PatchApplier) }
  subject(:preparer) do
    described_class.new(build_planner: build_planner, gemspec_normalizer: gemspec_normalizer, patch_applier: patch_applier)
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

  # Stubbed as no-op spies by default so `not_to have_received` can verify
  # zero invocations even in contexts that never expect a call at all --
  # instance_double requires a method to be stubbed before it can be spied
  # on, even to assert it was *not* called.
  before do
    allow(gemspec_normalizer).to receive(:normalize)
    allow(patch_applier).to receive(:apply_all)
  end

  describe '#prepare' do
    it 'calls BuildPlanner#plan_for with the given request' do
      allow(build_planner).to receive(:plan_for)
        .with('widget', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0').and_return([])

      preparer.prepare('widget', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0', source_root: '/src')

      expect(build_planner).to have_received(:plan_for)
    end

    context 'with a :pure entry' do
      before do
        allow(build_planner).to receive(:plan_for).and_return(
          [{ name: 'widget', version: '1.0.0', classification: classification(:pure) }]
        )
      end

      it 'neither normalizes nor patches, and reports empty patches_applied' do
        result = preparer.prepare('widget', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0', source_root: '/src')

        expect(gemspec_normalizer).not_to have_received(:normalize)
        expect(patch_applier).not_to have_received(:apply_all)
        expect(result).to eq(
          [{
            name: 'widget', version: '1.0.0', state: :pure, reason: 'classified as pure',
            platform_asset: nil, msys2_packages: nil, patches_applied: []
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
        result = preparer.prepare('widget', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0', source_root: '/src')

        expect(gemspec_normalizer).not_to have_received(:normalize)
        expect(patch_applier).not_to have_received(:apply_all)
        expect(result.first).to include(state: :native_pass_through, platform_asset: 'widget-1.0.0-x64-mingw-ucrt.gem')
      end
    end

    context 'with a :native_self_contained entry' do
      before do
        allow(build_planner).to receive(:plan_for).and_return(
          [{ name: 'widget', version: '1.0.0', classification: classification(:native_self_contained) }]
        )
        allow(patch_applier).to receive(:apply_all).and_return([{ patch: 'some-fix', status: :applied }])
      end

      it 'normalizes the gemspec at source_root/<name>, using the gem-name-scoped platform' do
        preparer.prepare('widget', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0', source_root: '/src')

        expect(gemspec_normalizer).to have_received(:normalize).with('widget', '/src/widget', platform: 'x64-mingw-ucrt')
      end

      it 'applies curated patches at the same source_root/<name> path' do
        preparer.prepare('widget', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0', source_root: '/src')

        expect(patch_applier).to have_received(:apply_all).with('widget', '/src/widget')
      end

      it 'normalizes before patching, not the other way around' do
        order = []
        allow(gemspec_normalizer).to receive(:normalize) { order << :normalize }
        allow(patch_applier).to receive(:apply_all) do
          order << :patch
          []
        end

        preparer.prepare('widget', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0', source_root: '/src')

        expect(order).to eq(%i[normalize patch])
      end

      it "reports PatchApplier's own result verbatim as patches_applied" do
        result = preparer.prepare('widget', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0', source_root: '/src')

        expect(result.first.fetch(:patches_applied)).to eq([{ patch: 'some-fix', status: :applied }])
      end

      it 'includes msys2_packages in the result, for the surrounding workflow to install' do
        result = preparer.prepare('widget', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0', source_root: '/src')

        expect(result.first.fetch(:msys2_packages)).to eq(%w[mingw-w64-ucrt-x86_64-widget])
      end
    end

    context 'with a mixed closure -- some entries need preparation, some do not' do
      before do
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
        result = preparer.prepare('widget', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0', source_root: '/src')

        expect(result.map { |r| r.fetch(:name) }).to eq(%w[leaf-pure widget])
        expect(gemspec_normalizer).to have_received(:normalize).once.with('widget', '/src/widget', platform: anything)
      end
    end

    context "when BuildPlanner itself raises" do
      it 'propagates ResolutionError rather than swallowing it' do
        allow(build_planner).to receive(:plan_for).and_raise(Ruby4Lich5::ClosureResolver::ResolutionError, 'boom')

        expect { preparer.prepare('widget', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0', source_root: '/src') }
          .to raise_error(Ruby4Lich5::ClosureResolver::ResolutionError, 'boom')
      end

      it 'propagates UnbuildableGemError rather than swallowing it' do
        allow(build_planner).to receive(:plan_for)
          .and_raise(Ruby4Lich5::BuildPlanner::UnbuildableGemError, 'no system lib')

        expect { preparer.prepare('widget', '1.0.0', platform: 'x64-mingw-ucrt', ruby_abi: '4.0', source_root: '/src') }
          .to raise_error(Ruby4Lich5::BuildPlanner::UnbuildableGemError, 'no system lib')
      end
    end
  end
end
