# frozen_string_literal: true

module Ruby4Lich5
  # Runs a subprocess with a bounded wall-clock timeout, killing it if it
  # overruns -- shared by SmokeRunner and BundledTestRunner's default
  # subprocess invocations, both of which run arbitrary third-party code
  # (a gem's own require chain, a gem's own Rakefile) that can hang
  # indefinitely (an interactive prompt, a deadlocked native extension, a
  # runaway test).
  #
  # Deliberately not built on Timeout.timeout wrapping Open3.capture2e:
  # killing the Ruby thread that's blocked on the subprocess wait does
  # nothing to the subprocess itself, which would keep running orphaned.
  # Instead this manages the child process handle directly.
  #
  # The timeout gate is the *reader* thread finishing (i.e. the output pipe
  # actually closing), not the direct child exiting -- verified directly
  # that a command like +sh -c 'sleep 2 &'+ exits immediately itself while
  # its backgrounded grandchild keeps the inherited pipe open, so gating on
  # the direct child's exit alone let a real run block for as long as that
  # grandchild happened to keep running, silently un-bounding what's
  # supposed to be a wall-clock-limited call. Spawned in its own process
  # group (+pgroup: true+) so escalation can signal the whole group,
  # including that grandchild, rather than leaving it to keep running
  # (and keep the pipe open) after the direct child is already dead.
  module SubprocessRunner
    # @return [Integer] seconds
    DEFAULT_TIMEOUT_SECONDS = 300

    # Seconds to wait for a graceful exit after SIGTERM before escalating to
    # SIGKILL.
    TERM_GRACE_SECONDS = 5
    private_constant :TERM_GRACE_SECONDS

    # @param cmd [Array<String>] passed through to Open3.popen2e
    # @param chdir [String]
    # @param timeout_seconds [Numeric]
    # @return [Hash] +{success:, output:}+ -- on timeout, +success+ is
    #   +false+ and +output+ has a trailing note identifying the timeout,
    #   appended to whatever the process had already written
    def self.run(*cmd, chdir:, timeout_seconds: DEFAULT_TIMEOUT_SECONDS)
      require 'open3'

      Open3.popen2e(*cmd, chdir: chdir, pgroup: true) do |stdin, stdout_and_stderr, wait_thr|
        stdin.close
        output = +''
        reader = Thread.new { output << stdout_and_stderr.read }

        if reader.join(timeout_seconds)
          { success: wait_thr.value.success?, output: output }
        else
          terminate(wait_thr.pid, reader)
          { success: false, output: "#{output}\n[timed out after #{timeout_seconds}s; process group terminated]" }
        end
      end
    end

    # Escalates TERM -> KILL against the whole process group, confirming
    # via the reader thread rather than assuming either signal actually
    # worked -- the only completion signal available for a grandchild,
    # since Ruby never spawned it directly and so can't Process.wait on it.
    # @return [void]
    def self.terminate(pgid, reader)
      Process.kill('TERM', -pgid)
      return if reader.join(TERM_GRACE_SECONDS)

      Process.kill('KILL', -pgid) # cannot be ignored, so this is bounded in practice
      reader.join
    rescue Errno::ESRCH
      # every process in the group already exited
      reader.join(TERM_GRACE_SECONDS)
    end
    private_class_method :terminate
  end
end
