# frozen_string_literal: true

require 'ruby4lich5/patch_applier'
require 'tmpdir'
require 'fileutils'

RSpec.describe Ruby4Lich5::PatchApplier do
  def write_patch(patches_root, gem_name, patch_name, content)
    dir = File.join(patches_root, gem_name)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "#{patch_name}.rb"), content)
  end

  def write_source(source_dir, relative_path, content)
    path = File.join(source_dir, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  around do |example|
    Dir.mktmpdir('ruby4lich5-patch-applier-spec') do |root|
      @patches_root = File.join(root, 'patches')
      @source_dir = File.join(root, 'source')
      FileUtils.mkdir_p(@patches_root)
      FileUtils.mkdir_p(@source_dir)
      example.run
    end
  end

  subject(:applier) { described_class.new(patches_root: @patches_root) }

  describe '#apply_all' do
    context 'when the gem has no patches directory at all' do
      it 'returns an empty array' do
        expect(applier.apply_all('unpatched-gem', @source_dir)).to eq([])
      end
    end

    context 'with an unsafe gem_name' do
      it 'rejects nil' do
        expect { applier.apply_all(nil, @source_dir) }.to raise_error(ArgumentError, /must not be nil or empty/)
      end

      it 'rejects an empty string' do
        expect { applier.apply_all('', @source_dir) }.to raise_error(ArgumentError, /must not be nil or empty/)
      end

      it 'rejects a path-traversal attempt rather than scanning outside patches_root' do
        expect { applier.apply_all('../lib/ruby4lich5', @source_dir) }
          .to raise_error(ArgumentError, /disallowed characters/)
      end
    end

    context 'when a patch declares a file outside source_dir' do
      before do
        write_patch(@patches_root, 'widget', '01-escape', <<~RUBY)
          { file: '../../escape.c', marker: 'MARK', steps: [] }
        RUBY
      end

      it 'raises PatchError instead of resolving/writing outside source_dir' do
        expect { applier.apply_all('widget', @source_dir) }
          .to raise_error(described_class::PatchError, /resolves outside source_dir/)
      end
    end

    context 'with a single-step patch' do
      before do
        write_patch(@patches_root, 'widget', '01-fix', <<~RUBY)
          {
            file: 'lib/widget.c',
            marker: 'PATCHED_MARKER',
            steps: [
              { old: 'int old_behavior(void) { return 1; }',
                new: 'int old_behavior(void) { return 2; } /* PATCHED_MARKER */',
                count: 1 }
            ]
          }
        RUBY
        write_source(@source_dir, 'lib/widget.c', "int old_behavior(void) { return 1; }\n")
      end

      it 'applies the patch and reports :applied' do
        result = applier.apply_all('widget', @source_dir)

        expect(result).to eq([{ patch: '01-fix', status: :applied }])
        expect(File.read(File.join(@source_dir, 'lib/widget.c'))).to include('PATCHED_MARKER')
      end

      it 'is idempotent -- a second run reports :already_applied and does not re-patch' do
        applier.apply_all('widget', @source_dir)

        result = applier.apply_all('widget', @source_dir)

        expect(result).to eq([{ patch: '01-fix', status: :already_applied }])
      end
    end

    context 'when an anchor occurs the wrong number of times' do
      before do
        write_patch(@patches_root, 'widget', '01-fix', <<~RUBY)
          { file: 'lib/widget.c', marker: 'MARK', steps: [{ old: 'TARGET', new: 'REPLACED', count: 1 }] }
        RUBY
        write_source(@source_dir, 'lib/widget.c', "TARGET\nTARGET\n")
      end

      it 'raises PatchError naming the step index and the expected/actual counts' do
        expect { applier.apply_all('widget', @source_dir) }
          .to raise_error(described_class::PatchError, /step 0.*expected 1.*found 2/)
      end
    end

    context 'when the patch targets a file that does not exist' do
      before do
        write_patch(@patches_root, 'widget', '01-fix', <<~RUBY)
          { file: 'lib/missing.c', marker: 'MARK', steps: [] }
        RUBY
      end

      it 'raises PatchError naming the missing file' do
        expect { applier.apply_all('widget', @source_dir) }
          .to raise_error(described_class::PatchError, /target file not found/)
      end
    end

    context 'with multiple patches for the same gem' do
      before do
        write_patch(@patches_root, 'widget', '01-first', <<~RUBY)
          { file: 'lib/widget.c', marker: 'FIRST_MARK', steps: [{ old: 'A', new: 'A /* FIRST_MARK */', count: 1 }] }
        RUBY
        write_patch(@patches_root, 'widget', '02-second', <<~RUBY)
          { file: 'lib/widget.c', marker: 'SECOND_MARK', steps: [{ old: 'B', new: 'B /* SECOND_MARK */', count: 1 }] }
        RUBY
        write_source(@source_dir, 'lib/widget.c', "A\nB\n")
      end

      it 'applies every patch found, in filename order' do
        result = applier.apply_all('widget', @source_dir)

        expect(result).to eq(
          [
            { patch: '01-first', status: :applied },
            { patch: '02-second', status: :applied }
          ]
        )
      end
    end

    context 'with an optional cleanup step' do
      before do
        write_patch(@patches_root, 'widget', '01-fix', <<~'RUBY')
          {
            file: 'lib/widget.c',
            marker: 'MARK',
            steps: [{ old: 'REMOVE_ME', new: '', count: 1 }],
            cleanup: ->(content) { content.gsub(/\n\n\n+/, "\n\n") + '/* MARK */' }
          }
        RUBY
        write_source(@source_dir, 'lib/widget.c', "before\nREMOVE_ME\n\n\n\nafter\n")
      end

      it 'runs cleanup after all steps have applied' do
        applier.apply_all('widget', @source_dir)

        content = File.read(File.join(@source_dir, 'lib/widget.c'))
        expect(content).to include('/* MARK */')
        expect(content).not_to match(/\n\n\n/)
      end
    end
  end

  describe 'the real curated patches' do
    subject(:applier) { described_class.new } # default patches_root -- the real committed patches/

    context 'glib2 property-retention-fix' do
      let(:before_source) do
        <<~C
          static VALUE
          rg_s_set_property(GObject *object, guint property_id, const GValue *value, GParamSpec *pspec)
          {
              rb_funcall(GOBJ2RVAL(object), ruby_setter, 1, GVAL2RVAL(value));
          }
        C
      end

      it 'applies against realistic source and roots the value via G_CHILD_SET' do
        Dir.mktmpdir do |source_dir|
          write_source(source_dir, 'ext/glib2/rbgobj_object.c', before_source)

          result = applier.apply_all('glib2', source_dir)

          expect(result).to eq([{ patch: 'property-retention-fix', status: :applied }])
          patched = File.read(File.join(source_dir, 'ext/glib2/rbgobj_object.c'))
          expect(patched).to include('G_CHILD_SET(rb_object')
          expect(patched).not_to include('rb_funcall(GOBJ2RVAL(object), ruby_setter, 1, GVAL2RVAL(value));')
        end
      end

      it 'is idempotent against already-patched source' do
        Dir.mktmpdir do |source_dir|
          write_source(source_dir, 'ext/glib2/rbgobj_object.c', before_source)
          applier.apply_all('glib2', source_dir)

          result = applier.apply_all('glib2', source_dir)

          expect(result).to eq([{ patch: 'property-retention-fix', status: :already_applied }])
        end
      end
    end

    context 'gobject-introspection gc-compact-safety-fix' do
      let(:before_source) do
        <<~C
          static const gchar *boxed_class_converters_name = "@@boxed_class_converters";
          static const gchar *object_class_converters_name = "@@object_class_converters";

          typedef struct {
              GType type;
              VALUE rb_converters;
              VALUE rb_converter;
          } BoxedInstance2RObjData;

          static void
          boxed_class_converter_free(gpointer user_data)
          {
              BoxedInstance2RObjData *data = user_data;
              rb_ary_delete(data->rb_converters, data->rb_converter);
              g_free(data);
          }

          static VALUE
          rg_s_register_boxed_class_converter(G_GNUC_UNUSED VALUE klass, VALUE rb_gtype)
          {
              RGConvertTable table;
              BoxedInstance2RObjData *data;
              VALUE boxed_class_converters;

              data->rb_converter = rb_block_proc();
              boxed_class_converters = rb_cv_get(klass, boxed_class_converters_name);
              rb_ary_push(boxed_class_converters, data->rb_converter);
              table.user_data = data;
          }

          typedef struct {
              GType type;
              VALUE rb_converters;
              VALUE rb_converter;
          } ObjectInstance2RObjData;

          static void
          object_class_converter_free(gpointer user_data)
          {
              ObjectInstance2RObjData *data = user_data;
              rb_ary_delete(data->rb_converters, data->rb_converter);
              g_free(data);
          }

          static VALUE
          rg_s_register_object_class_converter(G_GNUC_UNUSED VALUE klass, VALUE rb_gtype)
          {
              RGConvertTable table;
              ObjectInstance2RObjData *data;
              VALUE object_class_converters;

              data->rb_converter = rb_block_proc();
              object_class_converters = rb_cv_get(klass, object_class_converters_name);
              rb_ary_push(object_class_converters, data->rb_converter);
              table.user_data = data;
          }

          void
          Init_something(void)
          {
              rb_cv_set(RG_TARGET_NAMESPACE, boxed_class_converters_name, rb_ary_new());
              rb_cv_set(RG_TARGET_NAMESPACE, object_class_converters_name, rb_ary_new());
          }
        C
      end

      it 'applies all eight steps against realistic source' do
        Dir.mktmpdir do |source_dir|
          write_source(source_dir, 'ext/gobject-introspection/rb-gi-loader.c', before_source)

          result = applier.apply_all('gobject-introspection', source_dir)

          expect(result).to eq([{ patch: 'gc-compact-safety-fix', status: :applied }])
          patched = File.read(File.join(source_dir, 'ext/gobject-introspection/rb-gi-loader.c'))
          expect(patched).not_to include('boxed_class_converters_name')
          expect(patched).not_to include('object_class_converters_name')
          expect(patched).not_to include('VALUE rb_converters;')
          expect(patched).not_to include('rb_ary_delete(data->rb_converters')
          expect(patched.scan('rb_gc_register_address(&data->rb_converter)').size).to eq(2)
          expect(patched.scan('rb_gc_unregister_address(&data->rb_converter)').size).to eq(2)
        end
      end

      it 'is idempotent against already-patched source' do
        Dir.mktmpdir do |source_dir|
          write_source(source_dir, 'ext/gobject-introspection/rb-gi-loader.c', before_source)
          applier.apply_all('gobject-introspection', source_dir)

          result = applier.apply_all('gobject-introspection', source_dir)

          expect(result).to eq([{ patch: 'gc-compact-safety-fix', status: :already_applied }])
        end
      end
    end
  end
end
