# frozen_string_literal: true

require 'ruby4lich5/bundled_test_runner'
require 'ruby4lich5/gem_inspector'
require 'rbconfig'
require 'tmpdir'

RSpec.describe Ruby4Lich5::BundledTestRunner do
  let(:gem_inspector) { instance_double(Ruby4Lich5::GemInspector) }
  # A real, absolute, executable path -- always available in any Ruby
  # process, so specs don't need a fabricated fake to satisfy
  # ExecutablePath's validation.
  let(:real_rake_exe) { RbConfig.ruby }

  describe '#attempt' do
    context 'when the package has no runnable test suite' do
      it 'returns :not_attempted without invoking run_command' do
        allow(gem_inspector).to receive(:runnable_test_suite?).and_return(false)
        run_command = ->(*_args) { raise 'should not be called' }
        runner = described_class.new(run_command: run_command)

        expect(runner.attempt(gem_inspector, '/some/install/dir', rake_exe: real_rake_exe)).to eq(:not_attempted)
      end

      it 'returns :not_attempted even when rake_exe is invalid, since it was never going to be used' do
        # A best-effort, purely-informational runner must not raise for a
        # rake_exe problem it was never actually going to exercise -- the
        # common case (a gem with no bundled tests) shouldn't care whether
        # rake_exe happens to be valid.
        allow(gem_inspector).to receive(:runnable_test_suite?).and_return(false)
        run_command = ->(*_args) { raise 'should not be called' }
        runner = described_class.new(run_command: run_command)

        expect(runner.attempt(gem_inspector, '/some/install/dir', rake_exe: 'not-an-absolute-path'))
          .to eq(:not_attempted)
      end
    end

    context 'when the bundled suite runs and passes' do
      it 'returns :passed' do
        allow(gem_inspector).to receive(:runnable_test_suite?).and_return(true)
        runner = described_class.new(run_command: ->(*_args) { { success: true } })

        expect(runner.attempt(gem_inspector, '/some/install/dir', rake_exe: real_rake_exe)).to eq(:passed)
      end
    end

    context 'when the bundled suite runs and fails' do
      it 'returns :failed' do
        allow(gem_inspector).to receive(:runnable_test_suite?).and_return(true)
        runner = described_class.new(run_command: ->(*_args) { { success: false } })

        expect(runner.attempt(gem_inspector, '/some/install/dir', rake_exe: real_rake_exe)).to eq(:failed)
      end
    end

    context 'when attempting the suite raises for any reason' do
      it 'returns :not_attempted rather than propagating the error' do
        allow(gem_inspector).to receive(:runnable_test_suite?).and_return(true)
        runner = described_class.new(run_command: ->(*_args) { raise Errno::ENOENT, 'rake not found' })

        expect(runner.attempt(gem_inspector, '/some/install/dir', rake_exe: real_rake_exe)).to eq(:not_attempted)
      end
    end

    context 'regression: the specific baked-tree rake must be invoked, not one resolved via PATH' do
      it 'passes rake_exe and install_dir through to run_command exactly' do
        allow(gem_inspector).to receive(:runnable_test_suite?).and_return(true)
        received_args = nil
        runner = described_class.new(run_command: lambda { |*args|
          received_args = args
          { success: true }
        })

        runner.attempt(gem_inspector, '/some/install/dir', rake_exe: real_rake_exe)

        expect(received_args).to eq([real_rake_exe, '/some/install/dir'])
      end

      it 'raises ArgumentError for a bare command name instead of silently reintroducing PATH resolution' do
        # Documenting rake_exe as "an absolute path" didn't stop a caller
        # from passing "rake" anyway; this proves the boundary is actually
        # enforced now, not just described.
        allow(gem_inspector).to receive(:runnable_test_suite?).and_return(true)
        run_command = ->(*_args) { raise 'run_command should not be called when rake_exe is invalid' }
        runner = described_class.new(run_command: run_command)

        expect { runner.attempt(gem_inspector, '/some/install/dir', rake_exe: 'rake') }
          .to raise_error(ArgumentError, /must be an absolute path/)
      end

      it 'does not swallow the ArgumentError into :not_attempted' do
        # attempt's rescue exists for the bundled suite crashing, not for a
        # caller's own bad rake_exe -- those need to stay distinguishable,
        # not collapse into the same result.
        allow(gem_inspector).to receive(:runnable_test_suite?).and_return(true)
        runner = described_class.new(run_command: ->(*_args) { { success: true } })

        expect { runner.attempt(gem_inspector, '/some/install/dir', rake_exe: 'rake') }
          .to raise_error(ArgumentError)
      end
    end

    context 'regression: a hung bundled suite must not block indefinitely' do
      it 'returns :failed, via the real default subprocess, rather than hanging' do
        # Exercises the actual default_run_command -> SubprocessRunner
        # wiring (not a stub), proving the timeout is really enforced end
        # to end.
        allow(gem_inspector).to receive(:runnable_test_suite?).and_return(true)
        runner = described_class.new(timeout_seconds: 0.3)

        Dir.mktmpdir do |dir|
          hung_script = File.join(dir, 'hung_rake')
          File.write(hung_script, "#!/bin/sh\nsleep 30\n")
          File.chmod(0o755, hung_script)

          start = Time.now
          result = runner.attempt(gem_inspector, dir, rake_exe: hung_script)
          elapsed = Time.now - start

          expect(result).to eq(:failed)
          expect(elapsed).to be < 10
        end
      end
    end
  end
end
