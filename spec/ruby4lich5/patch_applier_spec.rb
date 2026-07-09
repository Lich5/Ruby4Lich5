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

    context 'with a whole-file-creation patch (content: instead of steps:)' do
      before do
        write_patch(@patches_root, 'widget', '01-vendor-plugin', <<~RUBY)
          {
            file: 'lib/rubygems_plugin.rb',
            marker: 'VENDORED_PLUGIN_MARKER',
            content: "# VENDORED_PLUGIN_MARKER\\nputs 'hello'\\n"
          }
        RUBY
      end

      it 'creates the file when it does not exist yet' do
        result = applier.apply_all('widget', @source_dir)

        expect(result).to eq([{ patch: '01-vendor-plugin', status: :applied }])
        expect(File.read(File.join(@source_dir, 'lib/rubygems_plugin.rb'))).to include('VENDORED_PLUGIN_MARKER')
      end

      it 'creates any missing intermediate directories' do
        applier.apply_all('widget', @source_dir)

        expect(File.directory?(File.join(@source_dir, 'lib'))).to be(true)
      end

      it 'is idempotent -- a second run reports :already_applied and does not overwrite' do
        applier.apply_all('widget', @source_dir)
        target = File.join(@source_dir, 'lib/rubygems_plugin.rb')
        File.write(target, "#{File.read(target)}# hand-edited, should survive\n")

        result = applier.apply_all('widget', @source_dir)

        expect(result).to eq([{ patch: '01-vendor-plugin', status: :already_applied }])
        expect(File.read(target)).to include('hand-edited, should survive')
      end

      it 'overwrites stale content that lacks the marker' do
        write_source(@source_dir, 'lib/rubygems_plugin.rb', "# an old, pre-marker version\n")

        result = applier.apply_all('widget', @source_dir)

        expect(result).to eq([{ patch: '01-vendor-plugin', status: :applied }])
        expect(File.read(File.join(@source_dir, 'lib/rubygems_plugin.rb'))).to include('VENDORED_PLUGIN_MARKER')
      end
    end

    context 'when a definition supplies both steps: and content:' do
      before do
        write_patch(@patches_root, 'widget', '01-ambiguous', <<~RUBY)
          { file: 'lib/widget.c', marker: 'MARK', steps: [], content: 'x' }
        RUBY
      end

      it 'raises PatchError rather than guessing which mode was intended' do
        expect { applier.apply_all('widget', @source_dir) }
          .to raise_error(described_class::PatchError, /exactly one of steps: or content:/)
      end
    end

    context 'when a definition supplies neither steps: nor content:' do
      before do
        write_patch(@patches_root, 'widget', '01-empty', <<~RUBY)
          { file: 'lib/widget.c', marker: 'MARK' }
        RUBY
      end

      it 'raises PatchError rather than guessing which mode was intended' do
        expect { applier.apply_all('widget', @source_dir) }
          .to raise_error(described_class::PatchError, /exactly one of steps: or content:/)
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

    context "when a step's replacement text contains a literal backslash-digit sequence" do
      before do
        write_patch(@patches_root, 'widget', '01-fix', <<~'RUBY')
          {
            file: 'lib/widget.c',
            marker: 'MARK',
            steps: [{ old: 'TARGET', new: 'line one\1line two /* MARK */', count: 1 }]
          }
        RUBY
        write_source(@source_dir, 'lib/widget.c', "TARGET\n")
      end

      it 'inserts the replacement literally instead of treating \\1 as a backreference' do
        applier.apply_all('widget', @source_dir)

        content = File.read(File.join(@source_dir, 'lib/widget.c'))
        expect(content).to include('line one\1line two')
      end
    end
  end

  describe 'the real curated patches' do
    subject(:applier) { described_class.new } # default patches_root -- the real committed patches/

    context 'glib2 (dll-path-and-require-abi + property-retention-fix, both apply together)' do
      let(:before_c_source) do
        <<~C
          static VALUE
          rg_s_set_property(GObject *object, guint property_id, const GValue *value, GParamSpec *pspec)
          {
              rb_funcall(GOBJ2RVAL(object), ruby_setter, 1, GVAL2RVAL(value));
          }
        C
      end
      let(:before_rb_source) do
        <<~RUBY
          def prepend_dll_path(path)
            path = Pathname(path) unless path.is_a?(Pathname)
            return unless path.exist?

            begin
              require "ruby_installer/runtime"
            rescue LoadError
            else
              RubyInstaller::Runtime.add_dll_directory(path.to_s)
            end
            prepend_path_to_environment_variable(path, "PATH")
          end

          require "glib2.so"

          module GLib
        RUBY
      end

      def write_glib2_source(source_dir, before_c_source, before_rb_source)
        write_source(source_dir, 'ext/glib2/rbgobj_object.c', before_c_source)
        write_source(source_dir, 'lib/glib2.rb', before_rb_source)
      end

      it 'applies both patches against realistic source' do
        Dir.mktmpdir do |source_dir|
          write_glib2_source(source_dir, before_c_source, before_rb_source)

          result = applier.apply_all('glib2', source_dir)

          expect(result).to contain_exactly(
            { patch: 'dll-path-and-require-abi', status: :applied },
            { patch: 'property-retention-fix', status: :applied }
          )
          patched_c = File.read(File.join(source_dir, 'ext/glib2/rbgobj_object.c'))
          expect(patched_c).to include('G_CHILD_SET(rb_object')
          expect(patched_c).not_to include('rb_funcall(GOBJ2RVAL(object), ruby_setter, 1, GVAL2RVAL(value));')
          patched_rb = File.read(File.join(source_dir, 'lib/glib2.rb'))
          expect(patched_rb).to include('GLib.prepend_dll_path(vendor_dir + "bin")')
          # rubocop:disable Lint/InterpolationCheck -- asserting the literal
          # text landed uninterpolated; see the patch definition's own comment.
          expect(patched_rb).to include('require "glib2/#{major}.#{minor}/glib2.so"')
          # rubocop:enable Lint/InterpolationCheck
          expect(patched_rb).not_to include('require "glib2.so"')
        end
      end

      it 'is idempotent against already-patched source' do
        Dir.mktmpdir do |source_dir|
          write_glib2_source(source_dir, before_c_source, before_rb_source)
          applier.apply_all('glib2', source_dir)

          result = applier.apply_all('glib2', source_dir)

          expect(result).to contain_exactly(
            { patch: 'dll-path-and-require-abi', status: :already_applied },
            { patch: 'property-retention-fix', status: :already_applied }
          )
        end
      end
    end

    context 'cairo dll-path-and-require-abi' do
      let(:before_source) do
        <<~RUBY
          require "cairo/color"
          require "cairo/paper"
          require "cairo.so"
          require "cairo/constants"

          module Cairo
        RUBY
      end

      it 'applies against realistic source' do
        Dir.mktmpdir do |source_dir|
          write_source(source_dir, 'lib/cairo.rb', before_source)

          result = applier.apply_all('cairo', source_dir)

          expect(result).to eq([{ patch: 'dll-path-and-require-abi', status: :applied }])
          patched = File.read(File.join(source_dir, 'lib/cairo.rb'))
          expect(patched).to include('RubyInstaller::Runtime.add_dll_directory(vendor_bin.to_s)')
          # rubocop:disable Lint/InterpolationCheck -- asserting the literal
          # text landed uninterpolated; see the patch definition's own comment.
          expect(patched).to include('require "cairo/#{major}.#{minor}/cairo.so"')
          # rubocop:enable Lint/InterpolationCheck
          expect(patched).not_to include('require "cairo.so"')
        end
      end

      it 'is idempotent against already-patched source' do
        Dir.mktmpdir do |source_dir|
          write_source(source_dir, 'lib/cairo.rb', before_source)
          applier.apply_all('cairo', source_dir)

          result = applier.apply_all('cairo', source_dir)

          expect(result).to eq([{ patch: 'dll-path-and-require-abi', status: :already_applied }])
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

      let(:before_rb_source) do
        <<~RUBY
          require "glib2"

          module GObjectIntrospection
          end

          require "gobject_introspection.so"
        RUBY
      end

      def write_gi_source(source_dir, before_source, before_rb_source)
        write_source(source_dir, 'ext/gobject-introspection/rb-gi-loader.c', before_source)
        write_source(source_dir, 'lib/gobject-introspection.rb', before_rb_source)
      end

      it 'applies all three patches against realistic source' do
        Dir.mktmpdir do |source_dir|
          write_gi_source(source_dir, before_source, before_rb_source)

          result = applier.apply_all('gobject-introspection', source_dir)

          expect(result).to contain_exactly(
            { patch: 'dll-path-and-require-abi', status: :applied },
            { patch: 'gc-compact-safety-fix', status: :applied },
            { patch: 'vendor-rubygems-plugin', status: :applied }
          )
          patched = File.read(File.join(source_dir, 'ext/gobject-introspection/rb-gi-loader.c'))
          expect(patched).not_to include('boxed_class_converters_name')
          expect(patched).not_to include('object_class_converters_name')
          expect(patched).not_to include('VALUE rb_converters;')
          expect(patched).not_to include('rb_ary_delete(data->rb_converters')
          expect(patched.scan('rb_gc_register_address(&data->rb_converter)').size).to eq(2)
          expect(patched.scan('rb_gc_unregister_address(&data->rb_converter)').size).to eq(2)
          patched_rb = File.read(File.join(source_dir, 'lib/gobject-introspection.rb'))
          expect(patched_rb).to include('GLib.prepend_dll_path(vendor_dir + "bin")')
          expect(patched_rb).to include('vendor_dir + "lib" + "girepository-1.0"')
          expect(patched_rb).to include('ENV["GI_TYPELIB_PATH"]')
          expect(patched_rb).to include('ENV["FONTCONFIG_PATH"]')
          expect(patched_rb).to include('ENV["FONTCONFIG_FILE"]')
          expect(patched_rb).not_to include('require "gobject_introspection.so"')
          plugin = File.read(File.join(source_dir, 'lib/rubygems_plugin.rb'))
          expect(plugin).to include('GDK_PIXBUF_MODULE_FILE')
        end
      end

      it 'is idempotent against already-patched source' do
        Dir.mktmpdir do |source_dir|
          write_gi_source(source_dir, before_source, before_rb_source)
          applier.apply_all('gobject-introspection', source_dir)

          result = applier.apply_all('gobject-introspection', source_dir)

          expect(result).to contain_exactly(
            { patch: 'dll-path-and-require-abi', status: :already_applied },
            { patch: 'gc-compact-safety-fix', status: :already_applied },
            { patch: 'vendor-rubygems-plugin', status: :already_applied }
          )
        end
      end
    end

    shared_examples 'a loader dll-path-and-require-abi patch' do |gem_name|
      let(:before_source) do
        <<~RUBY
          module #{gem_name.split('-').map(&:capitalize).join}
            class Loader < GObjectIntrospection::Loader
              def load
                require_extension
                require_libraries
              end

              def require_extension
                require "#{gem_name}.so"
              end
            end
          end
        RUBY
      end

      it 'applies against realistic source' do
        Dir.mktmpdir do |source_dir|
          write_source(source_dir, "lib/#{gem_name}/loader.rb", before_source)

          result = applier.apply_all(gem_name, source_dir)

          expect(result).to eq([{ patch: 'dll-path-and-require-abi', status: :applied }])
          patched = File.read(File.join(source_dir, "lib/#{gem_name}/loader.rb"))
          expect(patched).to include('GLib.prepend_dll_path(vendor_dir + "bin")')
          expect(patched).to include(%(require "#{gem_name}/\#{major}.\#{minor}/#{gem_name}.so"))
          expect(patched).not_to include(%(require "#{gem_name}.so"))
        end
      end

      it 'is idempotent against already-patched source' do
        Dir.mktmpdir do |source_dir|
          write_source(source_dir, "lib/#{gem_name}/loader.rb", before_source)
          applier.apply_all(gem_name, source_dir)

          result = applier.apply_all(gem_name, source_dir)

          expect(result).to eq([{ patch: 'dll-path-and-require-abi', status: :already_applied }])
        end
      end
    end

    context 'gio2 dll-path-and-require-abi' do
      include_examples 'a loader dll-path-and-require-abi patch', 'gio2'
    end

    context 'pango dll-path-and-require-abi' do
      include_examples 'a loader dll-path-and-require-abi patch', 'pango'
    end

    context 'gtk3 dll-path-and-require-abi' do
      include_examples 'a loader dll-path-and-require-abi patch', 'gtk3'
    end

    context 'cairo-gobject require-abi' do
      let(:before_source) do
        <<~RUBY
          require "cairo"
          require "glib2"

          require "cairo_gobject.so"
        RUBY
      end

      it 'applies against realistic source' do
        Dir.mktmpdir do |source_dir|
          write_source(source_dir, 'lib/cairo-gobject.rb', before_source)

          result = applier.apply_all('cairo-gobject', source_dir)

          expect(result).to eq([{ patch: 'require-abi', status: :applied }])
          patched = File.read(File.join(source_dir, 'lib/cairo-gobject.rb'))
          expect(patched).to include('major, minor, _ = RUBY_VERSION.split(/\./)')
          # rubocop:disable Lint/InterpolationCheck -- asserting the literal
          # text landed uninterpolated; see the patch definition's own comment.
          expect(patched).to include('require "cairo-gobject/#{major}.#{minor}/cairo_gobject.so"')
          # rubocop:enable Lint/InterpolationCheck
          expect(patched).not_to include('require "cairo_gobject.so"')
        end
      end

      it 'is idempotent against already-patched source' do
        Dir.mktmpdir do |source_dir|
          write_source(source_dir, 'lib/cairo-gobject.rb', before_source)
          applier.apply_all('cairo-gobject', source_dir)

          result = applier.apply_all('cairo-gobject', source_dir)

          expect(result).to eq([{ patch: 'require-abi', status: :already_applied }])
        end
      end
    end
  end

  describe '#patches_exist_for?' do
    it 'is false when the gem has no patches directory at all' do
      expect(applier.patches_exist_for?('unpatched-gem')).to be false
    end

    it 'is false when the gem has a patches directory but no .rb files in it' do
      dir = File.join(@patches_root, 'empty-dir-gem')
      FileUtils.mkdir_p(dir)

      expect(applier.patches_exist_for?('empty-dir-gem')).to be false
    end

    it 'is true when at least one patch file exists' do
      write_patch(@patches_root, 'patched-gem', 'some-fix', "{ file: 'lib/x.rb', marker: 'm', content: 'x' }")

      expect(applier.patches_exist_for?('patched-gem')).to be true
    end

    it 'rejects an unsafe gem_name the same way #apply_all does' do
      expect { applier.patches_exist_for?('../lib/ruby4lich5') }.to raise_error(ArgumentError, /disallowed characters/)
    end
  end
end
