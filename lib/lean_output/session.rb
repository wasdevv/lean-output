# frozen_string_literal: true

require 'json'
require 'digest'
require 'fileutils'

module LeanOutput
  # What the plugin remembers between hook invocations, in one file per session.
  #
  # A hook is a fresh process per tool call, so anything spanning calls — the
  # active level, what the model has already been shown, what has been saved so
  # far — has nowhere to live but disk. One file rather than three: it is read
  # and rewritten on every call, and three files would be three round trips to
  # say the same thing.
  #
  # Nothing here raises. A session that cannot be read is an empty one, and a
  # save that cannot be written is dropped — the worst case is that the ledger
  # forgets and a repeated output is sent twice, which is exactly the behaviour
  # before this file existed.
  class Session
    # Bumped because field 3 of a `seen` entry changed meaning rather than
    # shape: it used to hold the original size and now holds the delivered one.
    # Nothing would raise on an older file — it would simply read every entry as
    # "delivered whole", which is exactly the claim this release exists to stop
    # making. A version the reader rejects is the only way to tell the two apart,
    # and the file is a cache, so the cost of discarding it is one session
    # without dedup.
    VERSION = 2
    # Entries are pruned to the most recent N. The window in Ledger already
    # decides what is too old to reference; this is only so the file cannot grow
    # without bound in a session that runs for hours.
    MAX_SEEN = 300

    attr_reader :id, :data

    def self.load(payload)
      id = identify(payload)
      new(id, read(path(id)))
    end

    # A hook is one process per tool call, and a model that fires four tool
    # calls in one turn gets four of them at once against the same session
    # file. `save` is atomic, so nothing corrupts — but read-modify-write is
    # not, and the loser's ledger entries and gain counters vanish, which reads
    # as "dedup missed one" and can never be reproduced.
    #
    # The lock spans the whole read-modify-write rather than the write, since
    # the write was never the part that raced. Non-blocking with a fallback to
    # proceeding unlocked: a hook that cannot take the lock still has a result
    # to deliver, and the worst case without it is exactly today's behaviour.
    def self.with_lock(id)
      FileUtils.mkdir_p(dir)
      File.open(File.join(dir, "#{id}.lock"), File::RDWR | File::CREAT, 0o644) do |handle|
        handle.flock(File::LOCK_EX)
        return yield
      end
    rescue StandardError
      yield
    end

    def self.identify(payload)
      raw = payload['session_id'] || payload['sessionId']
      clean = raw.to_s.gsub(/[^A-Za-z0-9_-]/, '')[0, 64]
      return clean unless clean.empty?

      # No session id (an older host, or a direct caller) still gets isolation
      # per working directory, which is the next best proxy for "one agent".
      cwd = payload['cwd'].to_s
      cwd.empty? ? 'global' : "cwd-#{Digest::SHA256.hexdigest(cwd)[0, 16]}"
    end

    def self.dir
      ENV['LEAN_OUTPUT_STATE_DIR'] ||
        File.join(ENV['XDG_CACHE_HOME'] || File.join(Dir.home, '.cache'), 'lean-output')
    end

    def self.path(id)
      File.join(dir, "#{id}.json")
    end

    # How long a finished session's state is worth keeping. `MAX_SEEN` bounds
    # one file and `Vault` bounds its own directories, so this was the last
    # thing here that only grew: measured on a real cache, 53 session files
    # going back four weeks, none of them reachable — a session id never comes
    # back, so the moment its host process ends the file is dead weight that
    # nothing will ever read again.
    #
    # Two weeks rather than two days because the file is small and the only
    # thing a wrong guess costs on this side is disk, while deleting a session
    # that is merely idle costs its whole ledger.
    KEEP_DAYS = 14

    # Runs off the back of a save, which is the only moment this code is
    # reliably alive, and never raises: a hook that cannot tidy up still has a
    # result to deliver.
    def self.evict
      cutoff = Time.now.utc - (KEEP_DAYS * 86_400)
      Dir.glob(File.join(dir, '*.json')).each do |file|
        File.delete(file) if File.mtime(file) < cutoff
      end
    rescue StandardError
      nil
    end

    def self.read(file)
      parsed = JSON.parse(File.read(file))
      parsed.is_a?(Hash) && parsed['v'] == VERSION ? parsed : blank
    rescue StandardError
      blank
    end

    def self.blank
      { 'v' => VERSION, 'seq' => 0, 'bytes' => 0, 'seen' => {}, 'watch' => [],
        'said' => {}, 'gain' => gain_blank }
    end

    def self.gain_blank
      { 'calls' => 0, 'before' => 0, 'after' => 0, 'hits' => 0, 'hit_bytes' => 0,
        'rewrites' => 0, 'reruns' => 0, 'reruns_base' => 0 }
    end

    def initialize(id, data)
      @id = id
      @data = data
    end

    def seq
      data['seq'].to_i
    end

    def bytes
      data['bytes'].to_i
    end

    # Every result the hook sees advances the clock, whether or not it was
    # rewritten. The ledger measures its window in these bytes, so a result that
    # passed through still has to count: it occupied the context all the same.
    def advance(size)
      data['seq'] = seq + 1
      data['bytes'] = bytes + size.to_i
    end

    # [seq, bytes-at-the-time, label, delivered size, vault path] — positional to
    # keep the file small, since it is rewritten on every single tool call.
    #
    # `size` is what the model received, not what arrived at the hook. Those are
    # the same number only for a passthrough, and the difference is exactly what
    # tells a later reference whether the bytes are in the window. It held the
    # original size until 1.2.0 and nothing ever read it — a later occurrence
    # has the original in hand and can measure it.
    def lookup(digest)
      entry = data['seen'][digest]
      return nil unless entry.is_a?(Array) && entry.size >= 4

      { seq: entry[0], bytes: entry[1], label: entry[2], size: entry[3], path: entry[4] }
    end

    # An entry records the *best* the model has been given of these bytes, not
    # the most recent, and both carried fields are that same idea. A repeat is
    # answered with a reference, so it delivers a couple of hundred bytes and
    # writes no file — but the occurrence it points at is still in the window,
    # and taking the smaller number would make the third occurrence conclude the
    # model never had the result and re-send it. Measured on `git status` four
    # times: 2 references instead of 3, alternating full sends with pointers.
    #
    # The digest guarantees the bytes are identical, so an older delivery and an
    # older file are both still the right answer for this content.
    def remember(digest, label, size, path = nil)
      previous = lookup(digest)
      data['seen'][digest] = [seq, bytes, label,
                              [size.to_i, previous ? previous[:size].to_i : 0].max,
                              path || previous&.dig(:path)]
      prune
    end

    # Rung 2, turned on the plugin's own prose.
    #
    # "middle withheld — …, full text at …, (Read or grep it)" is 86 bytes of
    # explanation that never varies, and at the default level it is said once
    # per spill: measured over 32 real sessions, 3824 times, 321 kB of one
    # sentence. The ledger's whole argument is that bytes the context already
    # holds cost the same as bytes it never needed, and nothing exempts the
    # bytes this plugin writes itself.
    #
    # The window is the ledger's, for the same reason the ledger has one: a
    # compaction can take the earlier explanation away, and prose the model can
    # no longer see is prose that has to be said again. Between those, the terse
    # form carries the identical path — what shortens is the sentence around it,
    # never the locator, because a pointer that cannot be resolved is the one
    # failure this plugin must not ship.
    def explain?(topic, window: Ledger.window_bytes)
      said = data['said'] ||= {}
      return false if said[topic] && bytes - said[topic].to_i <= window

      said[topic] = bytes
      true
    end

    def credit(before, after, hit: false)
      gain = data['gain'] ||= self.class.gain_blank
      gain['calls'] += 1
      gain['before'] += before
      gain['after'] += after
      return unless hit

      gain['hits'] += 1
      gain['hit_bytes'] += before - after
    end

    def gain
      data['gain'] || self.class.gain_blank
    end

    # Whether a rewrite cost the model something it needed, measured the only
    # way a hook can see: it asked for the same thing again, straight away.
    #
    # Both arms are counted, and that is the entire design. Re-running a command
    # within three calls is background behaviour — over 8680 real results it
    # happens after 15.0% of the results this plugin would rewrite and after
    # 14.9% of the ones it leaves alone. A detector watching only the first
    # number would have found 89 "misses" in a corpus where the plugin was
    # provably inert and could not have caused one.
    #
    # So this records a rate against its own control and stops. Demoting a
    # compressor on the strength of a signal with no measured lift would be
    # acting confidently on noise, which is the failure this file exists to
    # avoid, not commit. The threshold gets written when the two arms separate.
    #
    # They still have not. Read back off 32 real sessions and 4039 tool calls:
    # 18.9% after a rewrite against 20.7% after a passthrough — z ≈ 1.4, and the
    # point estimate leans the reassuring way, with the model re-running *less*
    # after a rewrite than after being left alone. Two independent corpora now
    # say the same thing, which is the answer this detector was built to get.
    WATCH_CALLS = 3

    def observe(label, rewritten:)
      watch = data['watch'] ||= []
      earlier = watch.find { |entry| entry[1] == label && seq - entry[0].to_i <= WATCH_CALLS }

      bump(earlier[2] ? 'reruns' : 'reruns_base') if earlier
      bump('rewrites') if rewritten

      data['watch'] = (watch << [seq, label, rewritten]).last(WATCH_CALLS)
    end

    def bump(counter)
      gain[counter] = gain[counter].to_i + 1
    end
    private :bump

    def save
      file = self.class.path(id)
      FileUtils.mkdir_p(File.dirname(file))
      temp = "#{file}.#{Process.pid}.tmp"
      File.write(temp, JSON.generate(data))
      File.rename(temp, file)
      self.class.evict
      true
    rescue StandardError
      false
    end

    def prune
      seen = data['seen']
      return if seen.size <= MAX_SEEN

      keep = seen.sort_by { |_, entry| -entry[0].to_i }.first(MAX_SEEN)
      data['seen'] = keep.to_h
    end
    private :prune
  end
end
