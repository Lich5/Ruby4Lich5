# frozen_string_literal: true

require 'ruby4lich5/smoke_runner'
require 'tmpdir'
require 'rbconfig'

RSpec.describe Ruby4Lich5::SmokeRunner do
  # A real, absolute, executable path -- always available in any Ruby
  # process, so specs don't need a fabricated fake to satisfy
  # ExecutablePath's validation.
  let(:real_ruby_exe) { RbConfig.ruby }

  describe '#smoke' do
    context 'when the requires succeed' do
      it 'writes a Gemfile listing every plan entry and returns the captured output' do
        captured_ruby_exe = nil
        captured_script = nil
        captured_dir = nil
        run_ruby = lambda do |ruby_exe, script, working_dir|
          captured_ruby_exe = ruby_exe
          captured_script = script
          captured_dir = working_dir
          { success: true, output: 'load OK' }
        end
        runner = described_class.new(run_ruby: run_ruby)
        plan = [{ name: 'sqlite3', version: '1.7.3' }, { name: 'sequel', version: '5.87.0' }]

        Dir.mktmpdir do |working_dir|
          result = runner.smoke(plan, working_dir, ruby_exe: real_ruby_exe)

          expect(result).to eq('load OK')
          expect(captured_ruby_exe).to eq(real_ruby_exe)
          expect(captured_dir).to eq(working_dir)
          expect(captured_script).to include("require 'bundler/setup'").and include('Bundler.require')
          gemfile = File.read(File.join(working_dir, 'Gemfile'))
          expect(gemfile).to include('gem "sqlite3", "1.7.3"')
          expect(gemfile).to include('gem "sequel", "5.87.0"')
        end
      end
    end

    context 'when gtk3 is in the plan' do
      it 'appends the Gtk.init exception to the smoke script' do
        captured_script = nil
        run_ruby = lambda do |_ruby_exe, script, _working_dir|
          captured_script = script
          { success: true, output: '' }
        end
        runner = described_class.new(run_ruby: run_ruby)

        Dir.mktmpdir do |working_dir|
          runner.smoke([{ name: 'gtk3', version: '4.3.7' }], working_dir, ruby_exe: real_ruby_exe)
        end

        expect(captured_script).to include('Gtk.init')
      end
    end

    context 'when gtk3 is not in the plan' do
      it 'does not add the Gtk.init check' do
        captured_script = nil
        run_ruby = lambda do |_ruby_exe, script, _working_dir|
          captured_script = script
          { success: true, output: '' }
        end
        runner = described_class.new(run_ruby: run_ruby)

        Dir.mktmpdir do |working_dir|
          runner.smoke([{ name: 'sqlite3', version: '1.7.3' }], working_dir, ruby_exe: real_ruby_exe)
        end

        expect(captured_script).not_to include('Gtk.init')
      end
    end

    context 'when the requires fail' do
      it 'raises SmokeError naming the working directory and captured output' do
        run_ruby = ->(_ruby_exe, _script, _working_dir) { { success: false, output: 'LoadError: cannot load such file' } }
        runner = described_class.new(run_ruby: run_ruby)

        Dir.mktmpdir do |working_dir|
          expect { runner.smoke([{ name: 'sqlite3', version: '1.7.3' }], working_dir, ruby_exe: real_ruby_exe) }
            .to raise_error(described_class::SmokeError, /#{Regexp.escape(working_dir)}.*LoadError/)
        end
      end
    end

    context 'regression: the specific baked-tree Ruby must be invoked, not one resolved via PATH' do
      it 'passes ruby_exe through to run_ruby unchanged' do
        received_args = nil
        run_ruby = lambda do |*args|
          received_args = args
          { success: true, output: '' }
        end
        runner = described_class.new(run_ruby: run_ruby)

        Dir.mktmpdir do |working_dir|
          runner.smoke([{ name: 'sqlite3', version: '1.7.3' }], working_dir, ruby_exe: real_ruby_exe)
        end

        expect(received_args.first).to eq(real_ruby_exe)
      end

      it 'raises ArgumentError for a bare command name instead of silently reintroducing PATH resolution' do
        # A previous version of this class ran the bare string 'ruby' via
        # Open3, which resolves via PATH -- silently testing whatever Ruby a
        # CI runner or developer's shell happens to have first, not
        # necessarily the baked tree at all. Documenting ruby_exe as "an
        # absolute path" didn't stop a caller from passing "ruby" anyway;
        # this proves the boundary is actually enforced now, not just
        # described.
        run_ruby = ->(*_args) { raise 'run_ruby should not be called when ruby_exe is invalid' }
        runner = described_class.new(run_ruby: run_ruby)

        Dir.mktmpdir do |working_dir|
          expect { runner.smoke([{ name: 'sqlite3', version: '1.7.3' }], working_dir, ruby_exe: 'ruby') }
            .to raise_error(ArgumentError, /must be an absolute path/)
        end
      end
    end

    context 'regression: a hung requires script must not block indefinitely' do
      it 'raises SmokeError with timeout context, via the real default subprocess, rather than hanging' do
        # Exercises the actual default_run_ruby -> SubprocessRunner wiring
        # (not a stub), proving the timeout is really enforced end to end.
        runner = described_class.new(timeout_seconds: 0.3)
        allow(runner).to receive(:smoke_script).and_return('sleep 30')

        Dir.mktmpdir do |working_dir|
          start = Time.now
          expect { runner.smoke([{ name: 'sqlite3', version: '1.7.3' }], working_dir, ruby_exe: real_ruby_exe) }
            .to raise_error(described_class::SmokeError, /timed out after 0\.3s/)
          expect(Time.now - start).to be < 10
        end
      end
    end
  end
end
