# frozen_string_literal: true

require 'ruby4lich5/gemspec_normalizer'
require 'tmpdir'
require 'fileutils'

RSpec.describe Ruby4Lich5::GemspecNormalizer do
  subject(:normalizer) { described_class.new }

  # source_dir here is the gem's own root -- matching PatchApplier#apply_all's
  # convention, not a parent directory containing multiple gems.
  def write_gemspec(gem_root, gem_name, content)
    FileUtils.mkdir_p(gem_root)
    File.write(File.join(gem_root, "#{gem_name}.gemspec"), content)
  end

  around do |example|
    Dir.mktmpdir('ruby4lich5-gemspec-normalizer-spec') { |dir| @gem_root = dir and example.run }
  end

  def gemspec_content
    File.read(File.join(@gem_root, 'widget.gemspec'))
  end

  describe '#normalize' do
    context 'with an unsafe gem_name or platform' do
      it 'rejects a nil gem_name' do
        expect { normalizer.normalize(nil, @gem_root, platform: 'x64-mingw-ucrt') }
          .to raise_error(ArgumentError, /must not be nil or empty/)
      end

      it 'rejects a path-traversal gem_name rather than scanning outside source_dir' do
        expect { normalizer.normalize('../escape', @gem_root, platform: 'x64-mingw-ucrt') }
          .to raise_error(ArgumentError, /disallowed characters/)
      end

      it 'rejects an unsafe platform' do
        write_gemspec(@gem_root, 'widget', "Gem::Specification.new do |s|\nend\n")

        expect { normalizer.normalize('widget', @gem_root, platform: '../escape') }
          .to raise_error(ArgumentError, /disallowed characters/)
      end
    end

    context 'when the gemspec does not exist' do
      it 'raises NormalizationError' do
        expect { normalizer.normalize('widget', @gem_root, platform: 'x64-mingw-ucrt') }
          .to raise_error(described_class::NormalizationError, /gemspec not found/)
      end
    end

    context 'with a realistic monorepo-style gemspec (double-quoted dependency form)' do
      let(:before_source) do
        <<~RUBY
          Gem::Specification.new do |s|
            s.name          = "widget"
            s.version       = ruby_widget_version
            s.extensions    = ["ext/\#{s.name}/extconf.rb"]
            s.require_paths = ["lib"]
            s.files = ["widget.gemspec"]
            s.files += Dir.glob("lib/**/*.rb")

            s.add_runtime_dependency("pkg-config", ">= 1.3.5")
            s.add_runtime_dependency("native-package-installer", ">= 1.0.3")
          end
        RUBY
      end

      before { write_gemspec(@gem_root, 'widget', before_source) }

      it 'strips extensions and both build-only dependencies' do
        normalizer.normalize('widget', @gem_root, platform: 'x64-mingw-ucrt')

        expect(gemspec_content).not_to include('s.extensions')
        expect(gemspec_content).not_to include('pkg-config')
        expect(gemspec_content).not_to include('native-package-installer')
      end

      it 'adds s.platform right after s.version' do
        normalizer.normalize('widget', @gem_root, platform: 'x64-mingw-ucrt')

        expect(gemspec_content).to match(/s\.version\s*=.*\n\s*s\.platform\s*= Gem::Platform\.new\("x64-mingw-ucrt"\)/)
      end

      it 'adds the binary file globs before the trailing end' do
        normalizer.normalize('widget', @gem_root, platform: 'x64-mingw-ucrt')

        expect(gemspec_content).to include('s.files += Dir.glob("lib/**/*.so")')
        expect(gemspec_content).to include('s.files += Dir.glob("vendor/**/*")')
      end

      it 'produces syntactically valid Ruby' do
        normalizer.normalize('widget', @gem_root, platform: 'x64-mingw-ucrt')

        expect { RubyVM::InstructionSequence.compile(gemspec_content) }.not_to raise_error
      end

      it 'is idempotent -- a second run produces byte-identical output' do
        normalizer.normalize('widget', @gem_root, platform: 'x64-mingw-ucrt')
        once = gemspec_content

        normalizer.normalize('widget', @gem_root, platform: 'x64-mingw-ucrt')

        expect(gemspec_content).to eq(once)
      end
    end

    context 'with the serialized %q<> dependency form (real cairo.gemspec shape via spec.to_ruby)' do
      before do
        write_gemspec(@gem_root, 'widget', <<~RUBY)
          Gem::Specification.new do |s|
            s.name = "widget".freeze
            s.version = "1.0.0".freeze
            s.extensions = ["ext/widget/extconf.rb".freeze]

            s.add_runtime_dependency(%q<pkg-config>.freeze, [">= 1.2.2".freeze])
            s.add_runtime_dependency(%q<red-colors>.freeze, [">= 0".freeze])
          end
        RUBY
      end

      it 'strips the serialized form too, not just the double-quoted one' do
        normalizer.normalize('widget', @gem_root, platform: 'x64-mingw-ucrt')

        expect(gemspec_content).not_to include('pkg-config')
        expect(gemspec_content).to include('red-colors') # unrelated dependency must survive
      end
    end

    context 'when s.platform is already present' do
      before do
        write_gemspec(@gem_root, 'widget', <<~RUBY)
          Gem::Specification.new do |s|
            s.version = "1.0.0"
            s.platform = Gem::Platform.new("x64-mingw-ucrt")
            s.files += Dir.glob("lib/**/*.so")
            s.files += Dir.glob("vendor/**/*")
          end
        RUBY
      end

      it 'does not add a second s.platform line' do
        normalizer.normalize('widget', @gem_root, platform: 'x64-mingw-ucrt')

        expect(gemspec_content.scan('s.platform').size).to eq(1)
      end

      it 'does not add duplicate file globs' do
        normalizer.normalize('widget', @gem_root, platform: 'x64-mingw-ucrt')

        expect(gemspec_content.scan('Dir.glob("lib/**/*.so")').size).to eq(1)
      end
    end

    context 'when s.platform is already present but set to a different platform (e.g. Gem::Platform::RUBY from a synthesized to_ruby spec)' do
      before do
        write_gemspec(@gem_root, 'widget', <<~RUBY)
          Gem::Specification.new do |s|
            s.version = "1.0.0"
            s.platform = "ruby"
          end
        RUBY
      end

      it 'replaces the stale platform with the requested target rather than leaving it untouched' do
        normalizer.normalize('widget', @gem_root, platform: 'x64-mingw-ucrt')

        expect(gemspec_content.scan('s.platform').size).to eq(1)
        expect(gemspec_content).to include('s.platform      = Gem::Platform.new("x64-mingw-ucrt")')
        expect(gemspec_content).not_to include('"ruby"')
      end
    end

    context 'when only one of the two binary file globs is already present' do
      before do
        write_gemspec(@gem_root, 'widget', <<~RUBY)
          Gem::Specification.new do |s|
            s.version = "1.0.0"
            s.files += Dir.glob("lib/**/*.so")
          end
        RUBY
      end

      it 'still adds the missing vendor glob independently' do
        normalizer.normalize('widget', @gem_root, platform: 'x64-mingw-ucrt')

        expect(gemspec_content.scan('Dir.glob("lib/**/*.so")').size).to eq(1)
        expect(gemspec_content).to include('s.files += Dir.glob("vendor/**/*")')
      end
    end

    context 'when s.platform is missing and there is no s.version line to insert after' do
      before do
        write_gemspec(@gem_root, 'widget', "Gem::Specification.new do |s|\n  s.name = \"widget\"\nend\n")
      end

      it 'raises NormalizationError rather than silently skipping the platform step' do
        expect { normalizer.normalize('widget', @gem_root, platform: 'x64-mingw-ucrt') }
          .to raise_error(described_class::NormalizationError, /no s\.version/)
      end
    end

    context 'with an earlier, unindented end closing an unrelated top-level block' do
      before do
        write_gemspec(@gem_root, 'widget', <<~RUBY)
          if RUBY_VERSION >= "2.0"
          FOO = 1
          end

          Gem::Specification.new do |s|
            s.version = "1.0.0"
          end
        RUBY
      end

      it 'inserts the file globs before the outermost end, not the earlier one' do
        normalizer.normalize('widget', @gem_root, platform: 'x64-mingw-ucrt')

        lines = gemspec_content.lines
        globs_index = lines.index { |line| line.include?('Dir.glob("lib/**/*.so")') }
        outer_end_index = lines.rindex { |line| line.strip == 'end' }
        inner_end_index = lines.index { |line| line.strip == 'end' }

        expect(globs_index).to be < outer_end_index
        expect(globs_index).to be > inner_end_index
      end

      it 'still produces syntactically valid Ruby' do
        normalizer.normalize('widget', @gem_root, platform: 'x64-mingw-ucrt')

        expect { RubyVM::InstructionSequence.compile(gemspec_content) }.not_to raise_error
      end
    end

    context 'when the file globs are missing and there is no trailing end to insert before' do
      before do
        write_gemspec(@gem_root, 'widget', "Gem::Specification.new do |s|\n  s.version = \"1.0.0\"\nend # trailing comment\n")
      end

      it 'raises NormalizationError rather than silently skipping the file-globs step' do
        expect { normalizer.normalize('widget', @gem_root, platform: 'x64-mingw-ucrt') }
          .to raise_error(described_class::NormalizationError, /no trailing end/)
      end
    end
  end
end
