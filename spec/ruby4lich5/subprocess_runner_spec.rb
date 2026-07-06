# frozen_string_literal: true

require 'ruby4lich5/subprocess_runner'
require 'tmpdir'

RSpec.describe Ruby4Lich5::SubprocessRunner do
  describe '.run' do
    context 'when the command finishes within the timeout' do
      it 'returns success and captured output' do
        Dir.mktmpdir do |dir|
          result = described_class.run('echo', 'hello', chdir: dir, timeout_seconds: 5)

          expect(result).to eq(success: true, output: "hello\n")
        end
      end
    end

    context 'when the command exits non-zero' do
      it 'returns success: false' do
        Dir.mktmpdir do |dir|
          result = described_class.run('sh', '-c', 'exit 1', chdir: dir, timeout_seconds: 5)

          expect(result.fetch(:success)).to be false
        end
      end
    end

    context 'when the command hangs past the timeout' do
      it 'terminates the process and returns a timed-out failure, without blocking for the full hang duration' do
        Dir.mktmpdir do |dir|
          start = Time.now
          result = described_class.run('sleep', '30', chdir: dir, timeout_seconds: 0.3)
          elapsed = Time.now - start

          expect(result.fetch(:success)).to be false
          expect(result.fetch(:output)).to match(/timed out after 0\.3s/)
          expect(elapsed).to be < 10
        end
      end
    end

    context 'when the command ignores SIGTERM' do
      it 'escalates to SIGKILL rather than hanging forever' do
        Dir.mktmpdir do |dir|
          start = Time.now
          result = described_class.run('sh', '-c', 'trap "" TERM; sleep 30', chdir: dir, timeout_seconds: 0.3)
          elapsed = Time.now - start

          expect(result.fetch(:success)).to be false
          expect(elapsed).to be < 10
        end
      end
    end

    context 'regression: the direct child exits, but a backgrounded grandchild keeps stdout/stderr open' do
      it 'does not report success while blocking for as long as the grandchild happens to run' do
        # sh itself exits immediately (the & backgrounds the sleep), but the
        # grandchild inherits the pipe and keeps it open -- gating the
        # timeout on the direct child's exit alone (rather than on the pipe
        # actually closing) let this block for the grandchild's full
        # lifetime while still reporting success: true.
        Dir.mktmpdir do |dir|
          start = Time.now
          result = described_class.run('sh', '-c', 'sleep 30 &', chdir: dir, timeout_seconds: 0.3)
          elapsed = Time.now - start

          expect(result.fetch(:success)).to be false
          expect(result.fetch(:output)).to match(/timed out after 0\.3s/)
          expect(elapsed).to be < 10
        end
      end
    end
  end
end
