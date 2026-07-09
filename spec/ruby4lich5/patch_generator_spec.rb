# frozen_string_literal: true

require 'ruby4lich5/patch_generator'
require 'ruby4lich5/patch_applier'
require 'tmpdir'
require 'fileutils'

RSpec.describe Ruby4Lich5::PatchGenerator do
  def write_source(gem_root, relative_path, content)
    path = File.join(gem_root, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def silence_warnings
    original_verbose = $VERBOSE
    $VERBOSE = nil
    yield
  ensure
    $VERBOSE = original_verbose
  end

  around do |example|
    Dir.mktmpdir('ruby4lich5-patch-generator-spec') do |root|
      @gem_root = File.join(root, 'source')
      @patches_root = File.join(root, 'patches')
      FileUtils.mkdir_p(@gem_root)
      example.run
    end
  end

  subject(:generator) { described_class.new(patches_root: @patches_root) }

  describe '#definition_for' do
    context 'glib2 itself -- real shape, top-level lib/glib2.rb, defines the method it then calls' do
      before { write_source(@gem_root, 'lib/glib2.rb', "module GLib2\nend\n\nrequire \"glib2.so\"\n") }

      it 'matches the real hand-written patch exactly' do
        definition = generator.definition_for('glib2', @gem_root, depends_on_glib2: true)

        expect(definition).to eq(
          file: 'lib/glib2.rb',
          marker: 'GLib.prepend_dll_path(vendor_dir + "bin")',
          steps: [{
            old: 'require "glib2.so"',
            new: [
              'base_dir = Pathname.new(__FILE__).dirname.dirname.expand_path',
              'vendor_dir = base_dir + "vendor" + "local"',
              'GLib.prepend_dll_path(vendor_dir + "bin")',
              'major, minor, _ = RUBY_VERSION.split(/\./)',
              # rubocop:disable Lint/InterpolationCheck -- deliberately literal,
              # same reasoning as the real hand-written patches this mirrors.
              'require "glib2/#{major}.#{minor}/glib2.so"'
              # rubocop:enable Lint/InterpolationCheck
            ].join("\n"),
            count: 1
          }]
        )
      end
    end

    context 'a real glib2-dependent, nested lib/<name>/loader.rb -- gio2 shape' do
      before { write_source(@gem_root, 'lib/gio2/loader.rb', "module Gio2\n  def self.require_extension\n      require \"gio2.so\"\n  end\nend\n") }

      it 'matches the real hand-written patch exactly, including the deeper dirname chain and indentation' do
        definition = generator.definition_for('gio2', @gem_root, depends_on_glib2: true)

        expect(definition).to eq(
          file: 'lib/gio2/loader.rb',
          marker: 'GLib.prepend_dll_path(vendor_dir + "bin")',
          steps: [{
            old: '      require "gio2.so"',
            new: [
              '      base_dir = Pathname.new(__FILE__).dirname.dirname.dirname.expand_path',
              '      vendor_dir = base_dir + "vendor" + "local"',
              '      GLib.prepend_dll_path(vendor_dir + "bin")',
              '      major, minor, _ = RUBY_VERSION.split(/\./)',
              # rubocop:disable Lint/InterpolationCheck -- deliberately literal,
              # same reasoning as the real hand-written patches this mirrors.
              '      require "gio2/#{major}.#{minor}/gio2.so"'
              # rubocop:enable Lint/InterpolationCheck
            ].join("\n"),
            count: 1
          }]
        )
      end
    end

    context 'the fallback branch -- cairo shape, no glib2 in its own runtime-dependency closure' do
      before { write_source(@gem_root, 'lib/cairo.rb', "module Cairo\nend\n\nrequire \"cairo.so\"\n") }

      it 'matches the real hand-written patch exactly, including the mingw/mswin gate and PATH rescue' do
        definition = generator.definition_for('cairo', @gem_root, depends_on_glib2: false)

        expect(definition).to eq(
          file: 'lib/cairo.rb',
          marker: 'RubyInstaller::Runtime.add_dll_directory(vendor_bin.to_s)',
          steps: [{
            old: 'require "cairo.so"',
            new: [
              'if RUBY_PLATFORM =~ /mingw|mswin/',
              '  require "pathname"',
              '  base_dir = Pathname.new(__FILE__).dirname.dirname.expand_path',
              '  vendor_bin = base_dir + "vendor" + "local" + "bin"',
              '  if vendor_bin.exist?',
              '    begin',
              '      require "ruby_installer/runtime"',
              '      RubyInstaller::Runtime.add_dll_directory(vendor_bin.to_s)',
              '    rescue LoadError',
              # rubocop:disable Lint/InterpolationCheck -- deliberately literal,
              # same reasoning as the real hand-written patches this mirrors.
              '      ENV["PATH"] = "#{vendor_bin};#{ENV["PATH"]}"',
              # rubocop:enable Lint/InterpolationCheck
              '    end',
              '  end',
              'end',
              'major, minor, _ = RUBY_VERSION.split(/\./)',
              # rubocop:disable Lint/InterpolationCheck
              'require "cairo/#{major}.#{minor}/cairo.so"'
              # rubocop:enable Lint/InterpolationCheck
            ].join("\n"),
            count: 1
          }]
        )
      end
    end

    context 'the anchor .so name differs from the gem name -- gobject-introspection real shape (underscored)' do
      before do
        write_source(
          @gem_root, 'lib/gobject-introspection.rb',
          "module GObjectIntrospection\nend\n\nrequire \"gobject_introspection.so\"\nrequire \"gobject-introspection/version\"\n"
        )
      end

      it 'uses the real anchor text (underscored) for the require, but the gem name (hyphenated) for the directory' do
        definition = generator.definition_for('gobject-introspection', @gem_root, depends_on_glib2: true)

        expect(definition.fetch(:steps).first.fetch(:old)).to eq('require "gobject_introspection.so"')
        # rubocop:disable Lint/InterpolationCheck -- deliberately literal, same
        # reasoning as the real hand-written patches this mirrors.
        expect(definition.fetch(:steps).first.fetch(:new)).to end_with(
          'require "gobject-introspection/#{major}.#{minor}/gobject_introspection.so"'
        )
        # rubocop:enable Lint/InterpolationCheck
      end

      it 'does not match on the other, non-.so requires in the same file' do
        definition = generator.definition_for('gobject-introspection', @gem_root, depends_on_glib2: true)

        expect(definition.fetch(:steps).size).to eq(1)
      end
    end

    context 'no bare require "*.so" anchor exists anywhere under lib/' do
      before { write_source(@gem_root, 'lib/widget.rb', "module Widget\nend\n") }

      it 'raises GenerationError rather than guessing' do
        expect { generator.definition_for('widget', @gem_root, depends_on_glib2: false) }
          .to raise_error(described_class::GenerationError, /No bare require/)
      end
    end

    context 'more than one bare require "*.so" anchor exists -- genuinely ambiguous' do
      before do
        write_source(@gem_root, 'lib/a.rb', "require \"foo.so\"\n")
        write_source(@gem_root, 'lib/b.rb', "require \"bar.so\"\n")
      end

      it 'raises GenerationError naming both locations rather than silently picking one' do
        expect { generator.definition_for('widget', @gem_root, depends_on_glib2: false) }
          .to raise_error(described_class::GenerationError, /Ambiguous.*lib\/a\.rb:1.*lib\/b\.rb:1/)
      end
    end

    context 'two bare require "*.so" anchors in the SAME file -- also genuinely ambiguous' do
      before { write_source(@gem_root, 'lib/widget.rb', "require \"foo.so\"\nrequire \"bar.so\"\n") }

      it 'raises AmbiguousAnchor naming both locations rather than silently taking the first' do
        expect { generator.definition_for('widget', @gem_root, depends_on_glib2: false) }
          .to raise_error(described_class::AmbiguousAnchor, /Ambiguous.*lib\/widget\.rb:1.*lib\/widget\.rb:2/)
      end
    end

    context 'a single-quoted anchor -- no real gem uses this today, but nothing guarantees a future one won\'t' do
      before { write_source(@gem_root, 'lib/widget.rb', "require 'widget.so'\n") }

      it 'is recognized exactly like a double-quoted anchor, not silently treated as NoAnchorFound' do
        definition = generator.definition_for('widget', @gem_root, depends_on_glib2: false)

        expect(definition.fetch(:steps).first.fetch(:old)).to eq("require 'widget.so'")
      end
    end

    context 'a file with real non-ASCII bytes elsewhere in it -- cairo real shape, ' \
            'lib/cairo/colors.rb has genuine UTF-8 accented color-name comments' do
      before do
        # rubocop:disable Custom/AsciiOnlySource -- Intentional non-ASCII fixture, matching the
        # real accented bytes found in cairo's own lib/cairo/colors.rb, to reproduce the real
        # encoding crash this test guards against.
        write_source(@gem_root, 'lib/cairo/colors.rb', "module Cairo\n  # café, naïve, ’curly quote’\n  CAFE = 1\nend\n")
        # rubocop:enable Custom/AsciiOnlySource
        write_source(@gem_root, 'lib/cairo.rb', "module Cairo\nend\n\nrequire \"cairo.so\"\n")
      end

      it 'still finds the real anchor even when Encoding.default_external is US-ASCII -- ' \
         'real crash reproduced 2026-07-08 against the actual cairo gem on a minimally-configured locale' do
        original = Encoding.default_external
        silence_warnings { Encoding.default_external = Encoding::US_ASCII }

        begin
          definition = generator.definition_for('cairo', @gem_root, depends_on_glib2: false)
          expect(definition.fetch(:file)).to eq('lib/cairo.rb')
        ensure
          silence_warnings { Encoding.default_external = original }
        end
      end
    end

    context 'gem_root given as a relative path' do
      before { write_source(@gem_root, 'lib/widget.rb', "require \"widget.so\"\n") }

      it 'still produces a file path relative to gem_root, not prefixed with gem_root itself' do
        relative_gem_root = Pathname.new(@gem_root).relative_path_from(Pathname.new(Dir.pwd)).to_s
        definition = generator.definition_for('widget', relative_gem_root, depends_on_glib2: false)

        expect(definition.fetch(:file)).to eq('lib/widget.rb')
      end
    end
  end

  describe '#generate' do
    before { write_source(@gem_root, 'lib/gio2/loader.rb', "module Gio2\n  def self.require_extension\n      require \"gio2.so\"\n  end\nend\n") }

    it 'writes a file at patches_root/<gem_name>/dll-path-and-require-abi.rb' do
      path = generator.generate('gio2', @gem_root, depends_on_glib2: true)

      expect(path).to eq(File.join(@patches_root, 'gio2', 'dll-path-and-require-abi.rb'))
      expect(File.exist?(path)).to be true
    end

    it 'writes valid Ruby that evals back to the exact same definition, the same way PatchApplier loads it' do
      path = generator.generate('gio2', @gem_root, depends_on_glib2: true)

      expect(eval(File.read(path), binding, path)).to eq(generator.definition_for('gio2', @gem_root, depends_on_glib2: true))
    end

    it "hands off to the real, unmodified PatchApplier correctly -- no new patch-application mechanism" do
      generator.generate('gio2', @gem_root, depends_on_glib2: true)
      applier = Ruby4Lich5::PatchApplier.new(patches_root: @patches_root)

      result = applier.apply_all('gio2', @gem_root)

      expect(result).to eq([{ patch: 'dll-path-and-require-abi', status: :applied }])
      expect(File.read(File.join(@gem_root, 'lib/gio2/loader.rb'))).to include('GLib.prepend_dll_path(vendor_dir + "bin")')
    end
  end
end
