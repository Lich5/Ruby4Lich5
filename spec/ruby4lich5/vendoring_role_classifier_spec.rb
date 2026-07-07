# frozen_string_literal: true

require 'ruby4lich5/vendoring_role_classifier'
require 'ruby4lich5/classification'

RSpec.describe Ruby4Lich5::VendoringRoleClassifier do
  subject(:classifier) { described_class.new }

  def self_contained(name, deps = [])
    {
      name: name,
      version: '1.0.0',
      runtime_dependency_names: deps,
      classification: Ruby4Lich5::Classification.new(
        state: :native_self_contained, gem_name: name, gem_version: '1.0.0',
        reason: 'builds from MSYS2 packages', msys2_packages: ['mingw-w64-ucrt-x86_64-something']
      )
    }
  end

  def pure(name, deps = [])
    {
      name: name,
      version: '1.0.0',
      runtime_dependency_names: deps,
      classification: Ruby4Lich5::Classification.new(
        state: :pure, gem_name: name, gem_version: '1.0.0', reason: 'no native extensions'
      )
    }
  end

  describe '#classify' do
    context 'with the real GTK3 stack shape (verified directly against rubygems.org)' do
      it 'identifies glib2 and cairo as the only vendoring roots, everything else as dependent' do
        # Real runtime_dependency_names as published, restricted to the
        # native members of the closure (fiddle/rake/red-colors/pkg-config
        # etc. are :pure and irrelevant to vendoring role).
        plan = [
          self_contained('glib2'),
          self_contained('cairo'),
          self_contained('gobject-introspection', ['glib2']),
          self_contained('cairo-gobject', %w[cairo glib2]),
          self_contained('gio2', ['gobject-introspection']),
          self_contained('pango', %w[cairo-gobject gobject-introspection]),
          self_contained('atk', ['glib2']),
          self_contained('gdk_pixbuf2', ['gio2']),
          self_contained('gdk3', %w[cairo-gobject gdk_pixbuf2 pango]),
          self_contained('gtk3', %w[atk gdk3])
        ]

        roles = classifier.classify(plan)

        expect(roles.select { |_, role| role == :vendoring_root }.keys).to contain_exactly('glib2', 'cairo')
        expect(roles.select { |_, role| role == :vendoring_dependent }.keys).to contain_exactly(
          'gobject-introspection', 'cairo-gobject', 'gio2', 'pango', 'atk', 'gdk_pixbuf2', 'gdk3', 'gtk3'
        )
      end
    end

    context 'with a known-simple, already-curated gem (curses -- real shape: zero runtime deps)' do
      it 'is trivially a vendoring root, having nothing else in the closure to depend on' do
        plan = [self_contained('curses')]

        roles = classifier.classify(plan)

        expect(roles).to eq({ 'curses' => :vendoring_root })
      end
    end

    context 'with a real native-depends-on-native chain never exercised before (mini_racer -> libv8-node)' do
      it 'identifies libv8-node as root and mini_racer as dependent' do
        # Real shape verified directly against rubygems.org: mini_racer
        # depends on libv8-node; libv8-node has no runtime deps of its own.
        # Picked specifically because it's a genuine native-on-native pair
        # from outside the GTK stack, not a synthetic example.
        plan = [
          self_contained('libv8-node'),
          self_contained('mini_racer', ['libv8-node'])
        ]

        roles = classifier.classify(plan)

        expect(roles).to eq({ 'libv8-node' => :vendoring_root, 'mini_racer' => :vendoring_dependent })
      end
    end

    context 'when the plan includes non-native entries' do
      it 'omits :pure and :native_pass_through entries entirely, assigning them no role' do
        plan = [
          pure('bigdecimal'),
          self_contained('widget', ['bigdecimal'])
        ]

        roles = classifier.classify(plan)

        expect(roles).to eq({ 'widget' => :vendoring_root })
      end
    end

    context 'with an empty plan' do
      it 'returns an empty role map' do
        expect(classifier.classify([])).to eq({})
      end
    end

    context 'when a self-contained runtime dependency is absent from the plan (manifest-satisfied and filtered out by BuildPlanner upstream)' do
      it 'documents the current, narrower contract: roles mean "among gems in this plan," ' \
         'not "within the full runtime closure" -- a dependent looks like a root if its ' \
         'self-contained dependency was already filtered out before classify saw it' do
        # 'upstream' is deliberately NOT included in this plan, simulating
        # BuildPlanner#plan_for skipping a manifest-satisfied gem before
        # classification -- confirmed real (2026-07-07 review) but not
        # reachable via the current real pipeline, since neither
        # NativeGemPreparer nor bin/prepare_native_gems.rb ever passes a
        # populated CurationManifest. See the class-level comment for what
        # would need to change before this stops being true.
        plan = [self_contained('downstream', ['upstream'])]

        roles = classifier.classify(plan)

        expect(roles).to eq({ 'downstream' => :vendoring_root })
      end
    end
  end
end
