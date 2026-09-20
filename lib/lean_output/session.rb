# frozen_string_literal: true

require 'json'
require 'digest'

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
    #
    # Which left the obvious question unasked for eight versions: does the count
    # bind *before* the window does? The two are measured in different units — a
    # count of entries against 250kB of traffic gone by — so nothing guaranteed
    # they agree, and a cap that bit first would be silently throwing away hits
    # the ledger had already decided were fair game.
    #
    # It does not. Replaying every transcript on this machine against an
    # unbounded ledger, the deepest LRU position a hit was ever found at is
    # **151**, with p50 at 101 and p99 at 122. 300 is a shade over twice the
    # worst case, which is the headroom Sleator-Tarjan says an LRU cache wants:
    # LRU_M ≤ 2·OPT_{M/2}, so a cache at twice the observed reuse depth is
    # within a constant factor of knowing the future.
    #
    # The policy is LRU and not FIFO, which matters and is easy to miss: `prune`
    # sorts on the entry's `seq`, and `remember` rewrites `seq` on every repeat,
    # so a digest that keeps coming back keeps its place. FIFO here would evict
    # exactly the entries earning their keep.
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
      mkdir_p(dir)
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

    # `FileUtils.mkdir_p` in four words of Ruby, because requiring FileUtils to
    # get it costs 6.9ms and this process runs on every tool call — a fifth of
    # the whole hook, for one method. The recursive ops FileUtils really is good
    # at (rm_rf over a directory tree) are required where they are used, on
    # paths that run only when something is actually being evicted.
    def self.mkdir_p(path)
      return if File.directory?(path)

      mkdir_p(File.dirname(path))
      Dir.mkdir(path)
    rescue Errno::EEXIST
      nil
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
      { 'v' => VERSION, 'seq' => 0, 'bytes' => 0, 'floor' => 0, 'seen' => {}, 'watch' => [],
        'said' => {}, 'gain' => gain_blank, 'meter' => {} }
    end

    # `reruns` and `reruns_base` used to live here as two pooled totals. They
    # are gone, not moved: pooling them is what made them unreadable, and the
    # per-family cells in `meter` carry the same events with the confounder
    # kept. A file written before this release simply has two keys nothing
    # reads, which is why this needed no VERSION bump — that would have thrown
    # away every user's ledger to change a measurement.
    def self.gain_blank
      { 'calls' => 0, 'before' => 0, 'after' => 0, 'hits' => 0, 'hit_bytes' => 0, 'rewrites' => 0 }
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

    # Where the window was last cut, on the same byte clock as everything else
    # here. Zero until the host says otherwise, which reads as "nothing has been
    # taken away yet" — the right answer for a fresh session and for a state
    # file written before this key existed, so no VERSION bump.
    def floor
      data['floor'].to_i
    end

    # The host is about to replace everything above with a summary.
    #
    # Two of this plugin's claims are about the window and not about disk: the
    # ledger's "you already have these bytes" and `explain?`'s "the sentence
    # explaining this is already up there". Both were guarded by `WINDOW_BYTES`,
    # a 250kB guess at when a compaction has probably happened. A guess is what
    # you use when nobody tells you; PreCompact tells us.
    def compacted!
      data['floor'] = bytes
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
      # Past the cut the sentence is gone whether or not the window says so,
      # which is the case the byte guess above exists to approximate.
      return false if said[topic] && said[topic].to_i >= floor && bytes - said[topic].to_i <= window

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
    # within three calls is background behaviour — a detector watching only the
    # rewritten arm would find "misses" in a corpus where the plugin was
    # provably inert and could not have caused one.
    #
    # **The arms are compared inside a command family, never pooled.** That is
    # the correction this meter needed and it is not a refinement, it is the
    # difference between a number and a false alarm. Pooled over a real corpus
    # the two arms read 53.2% after a compressed result against 30.4% after a
    # passthrough — twenty-three points, which would condemn every compressor
    # here. All twenty-three are confounding: the rewritten arm is test and lint
    # runners, and an edit-test loop re-runs those for reasons no plugin
    # touches. Stratified so each family is its own control, over 35 families
    # seen in both arms: **40.5% against 41.2%, z = -0.49.**
    #
    # So a cell is per family, and the report sums only families that have a
    # sample in both arms — a family seen in one arm carries no comparison, and
    # summing it is exactly how the confound gets back in.
    #
    # Two keys, deliberately, because they answer different questions. The
    # look-back matches the *exact* label, since "the model asked for precisely
    # what it just got" is the signal. The cell is keyed by *family*, since the
    # thing being controlled for is what kind of command it was. Read back off
    # three independent corpora now, the arms have never separated; the
    # threshold gets written if they ever do, and it can now be believed.
    WATCH_CALLS = 3

    # Families kept. Bounded because this file is rewritten on every tool call
    # and a Bash label is a whole command, so one-off commands would fill it
    # forever.
    #
    # Pruned by sample size — LFU, where `seen` above is LRU — and the
    # difference is deliberate rather than an oversight. LRU is the right policy
    # for a *cache*, because the question it answers is "will this be asked for
    # again", and Sleator-Tarjan bounds how much it can cost you. This is not a
    # cache: nothing looks a family up, and the question is "which cells carry
    # the estimate". There the least-frequent cell is the least informative one
    # by definition, and evicting on recency would throw away the family with
    # 200 observations because a one-off ran more recently.
    MAX_METER = 40

    # [rewritten, rewritten-then-repeated, passthrough, passthrough-then-repeated]
    CELL = 4

    def observe(label, family, rewritten:)
      watch = data['watch'] ||= []
      earlier = watch.find { |entry| entry[1] == label && seq - entry[0].to_i <= WATCH_CALLS }

      cell = cell_for(family)
      cell[rewritten ? 0 : 2] += 1
      # Attributed to the arm the *earlier* call belonged to — it is the one
      # that may have cost the round trip. Same family by construction, since
      # the look-back already matched its exact label.
      cell[earlier[2] ? 1 : 3] += 1 if earlier
      bump('rewrites') if rewritten

      data['watch'] = (watch << [seq, label, rewritten]).last(WATCH_CALLS)
    end

    # Only families with a sample in both arms. Everything downstream sums these
    # and nothing sums the rest, which is the whole guarantee.
    def strata
      (data['meter'] || {}).values.select do |cell|
        cell.is_a?(Array) && cell.size == CELL && cell[0].to_i.positive? && cell[2].to_i.positive?
      end
    end

    def cell_for(family)
      meter = data['meter'] ||= {}
      cell = meter[family]
      return cell if cell.is_a?(Array) && cell.size == CELL

      prune_meter(meter)
      meter[family] = Array.new(CELL, 0)
    end
    private :cell_for

    def prune_meter(meter)
      return if meter.size < MAX_METER

      keep = meter.select { |_, cell| cell.is_a?(Array) && cell.size == CELL }
                  .sort_by { |_, cell| -(cell[0].to_i + cell[2].to_i) }.first(MAX_METER - 1)
      meter.replace(keep.to_h)
    end
    private :prune_meter

    def bump(counter)
      gain[counter] = gain[counter].to_i + 1
    end
    private :bump

    def save
      file = self.class.path(id)
      self.class.mkdir_p(File.dirname(file))
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
