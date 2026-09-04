# frozen_string_literal: true


module LeanOutput
  # What the hook costs, which nothing here has ever measured.
  #
  # Every number in this repo is about bytes the plugin removes. None is about
  # the time it spends removing them — and it spends that time on every single
  # tool call, in front of the user, forever. A rung that saves 3% of the
  # context and adds 200ms to every call is not obviously a good trade, and
  # until now there was no way to find out which one this is.
  #
  # Off unless `LEAN_OUTPUT_PROFILE=1`, because the measurement writes a file on
  # a path whose whole design is "fail safe and get out of the way". Appended
  # per call rather than aggregated, so the reader sees the tail: a mean hides
  # the slow call, and the slow call is the one the user feels.
  module Profile
    MAX = 5_000

    def self.on?
      ENV['LEAN_OUTPUT_PROFILE'] == '1'
    end

    # Never raises, for the same reason nothing else on this path does: a hook
    # that cannot write its own timing still has a result to deliver.
    def self.record(seconds)
      return unless on?

      Session.mkdir_p(File.dirname(path))
      File.write(path, "#{(seconds * 1000).round(2)}\n", mode: 'a')
      trim
    rescue StandardError
      nil
    end

    def self.samples
      File.readlines(path).filter_map { |line| Float(line, exception: false) }
    rescue StandardError
      []
    end

    def self.report
      times = samples.sort
      return 'no timings yet — set LEAN_OUTPUT_PROFILE=1 and run a few tool calls' if times.empty?

      format("hook latency over %d calls: median %.1fms · p90 %.1fms · p99 %.1fms · max %.1fms\n" \
             'that cost is paid on every tool call, whether or not anything was rewritten',
             times.size, at(times, 0.5), at(times, 0.9), at(times, 0.99), times.last)
    end

    def self.at(times, quantile)
      times[[(times.size * quantile).floor, times.size - 1].min]
    end
    private_class_method :at

    # Bounded like everything else that appends here, and by rewriting rather
    # than by locking: two hooks racing lose a sample, and a lost sample from a
    # distribution of thousands changes nothing worth a lock on the hot path.
    def self.trim
      lines = File.readlines(path)
      File.write(path, lines.last(MAX).join) if lines.size > MAX * 2
    rescue StandardError
      nil
    end
    private_class_method :trim

    def self.path
      File.join(Session.dir, 'profile.log')
    end

    def self.clear
      File.delete(path)
      true
    rescue StandardError
      false
    end
  end
end
