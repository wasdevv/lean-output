# frozen_string_literal: true

require 'json'

module LeanOutput
  # Per-transcript memo for the two commands that read every transcript.
  #
  # `analyze` and `readback` walk `~/.claude/projects` whole — on a real cache
  # that is ten minutes a run, and both of them run inside `calibrate`. A
  # measurement that costs twenty minutes is a measurement taken once and then
  # trusted for a year, which is the failure this plugin has already had: the
  # spill floor was right when it was taken and nobody re-ran the sweep that
  # would have said it had drifted.
  #
  # Keyed by size and mtime rather than content, because a transcript is
  # append-only while its session is alive and immutable afterwards, and
  # hashing the file would cost the read the cache exists to avoid.
  #
  # Every failure mode is a miss. A corrupt entry, an unreadable cache
  # directory, a version bump — all of them recompute, which is the answer the
  # caller wanted anyway, only slower.
  module ScanCache
    VERSION = 1

    def self.fetch(kind, file)
      stamp = signature(file)
      cached = read(kind, file, stamp)
      return cached if cached

      yield.tap { |value| write(kind, file, stamp, value) }
    end

    def self.signature(file)
      stat = File.stat(file)
      "#{VERSION}-#{stat.size}-#{stat.mtime.to_i}"
    rescue StandardError
      nil
    end
    private_class_method :signature

    def self.read(kind, file, stamp)
      return nil unless stamp

      parsed = JSON.parse(File.read(path(kind, file)))
      parsed['stamp'] == stamp ? parsed['rows'] : nil
    rescue StandardError
      nil
    end
    private_class_method :read

    def self.write(kind, file, stamp, value)
      return unless stamp

      Session.mkdir_p(dir)
      File.write(path(kind, file), JSON.generate({ 'stamp' => stamp, 'rows' => value }))
    rescue StandardError
      nil
    end
    private_class_method :write

    def self.dir
      File.join(Session.dir, 'scan')
    end

    def self.path(kind, file)
      File.join(dir, "#{kind}-#{Digest::SHA256.hexdigest(file)[0, 16]}.json")
    end
    private_class_method :path

    # The cache is derived, so throwing it away is always safe and is the first
    # thing to try when a number looks wrong.
    # Deleted file by file rather than with `FileUtils.rm_rf`, and not because
    # rm_rf is wrong: requiring FileUtils here costs 6.9ms on a path the hook
    # loads, and the lazy `require` that avoided that was silently removed by a
    # formatter — leaving `FileUtils` undefined, the NameError swallowed by the
    # rescue below, and `lean rescan` reporting failure while doing nothing.
    # This directory is flat, so the loop is the whole job and depends on
    # nothing that can be taken away.
    def self.clear
      return true unless File.directory?(dir)

      Dir.glob(File.join(dir, '*')).each { |file| File.delete(file) }
      Dir.rmdir(dir)
      true
    rescue StandardError
      false
    end
  end
end
