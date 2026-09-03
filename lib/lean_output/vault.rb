# frozen_string_literal: true

require 'digest'
require 'fileutils'

module LeanOutput
  # The rung that stops answering "what is the shortest text that carries this
  # signal" and answers "does this have to be in the context window at all".
  #
  # Every other rung here spends its budget arguing about which bytes are
  # redundant. This one declines the argument: the result goes to a file, the
  # model gets its two ends and the exact path, and the middle is one `Read`
  # away if it turns out to matter. Nothing is destroyed, so it is the only
  # aggressive rung that owes no fidelity premium — the cost is a possible
  # extra tool call, not a possible wrong answer.
  #
  # Measured over 8901 real results: spilling everything unclaimed above 800B
  # takes 9.82MB to 3.03MB, **-69%**, against -22% for the hard ceiling and -6%
  # for the compressors. The model would have to read back 77% of everything
  # spilled before that win is gone, and the whole point of a pointer is that
  # it reads back the one it needs.
  module Vault
    # Enough to recognise the result and to answer from, without becoming the
    # cost itself. The number takes after Ledger::HEAD_LINES, which already
    # settled that two lines identify an output — this is that, plus a line of
    # tail, because a command puts its verdict at the bottom.
    #
    # 150B was right when the floor was 500B and this was said 3824 times: every
    # byte of preview was paid thousands of times over, so the number was driven
    # down until the head stopped being a line.
    #
    # The floor is 16kB now and the corpus produces 32 spills, which inverts the
    # question. The preview is no longer a bulk cost to minimise; it is the only
    # thing standing between a pointer and a round trip, and a round trip is
    # measured at 925,898 tokens on average — the prefix that turn re-reads plus
    # the content arriving anyway, one turn later, for the rest of the session.
    #
    # Priced across those 32 spills: 400B costs 348k tokens, 1000B costs 1.18M,
    # 2000B costs 2.58M. So 1000B pays for itself by preventing **1.3 of the 21
    # read-backs — 6%**. That is the bar, and it is written here so it can be
    # checked rather than assumed.
    #
    # This is the one number in this file that is a bet rather than a
    # measurement. The cost is certain and the benefit is not: nothing in the
    # transcripts can say whether a larger head and tail would have answered the
    # question, because they were all written at 150B. Re-running the
    # notice-to-Read pairing after a few weeks is what settles it — if the
    # read-back rate has not moved off 65%, this should go back down.
    PREVIEW = 1_000
    # A quarter of every pointer used to be filesystem path — 0.36MB of the
    # 3.32MB residual, said 2920 times. The session id contributed 36 of those
    # bytes and the slug up to 40, neither of which the model reads: it reads
    # the preview to recognise the result and hands the path to `Read` whole.
    #
    # Hashed rather than truncated, because truncation assumes the entropy is at
    # the front and Session.id has two shapes: a host UUID, and a `cwd-<digest>`
    # fallback where the first four characters are the same for every session
    # there will ever be. 8 hex characters is 32 bits against the SESSIONS
    # directories kept, so a collision is not a real event; if one happened, two
    # sessions would share a directory and the sequence numbers would still keep
    # the files apart.
    SESSION_CHARS = 8
    SLUG_CHARS = 16
    # Files per session, so a long day cannot fill the disk. Old entries are
    # dropped oldest-first; a pointer into a pruned file is a dead pointer, so
    # the number is generous rather than tidy.
    KEEP = 400
    # Session directories kept, for the same reason KEEP bounds the files inside
    # one. KEEP alone bounds a session to 400 files and leaves the number of
    # sessions unbounded, which is the shape of leak that reads as working for
    # months and then as a full disk.
    SESSIONS = 20

    # Written once and then paid for on every spill, which is why it is one
    # line and not the paragraph it started as: at 317B it was 23% of
    # everything this level still sends, 2804 copies of the same instruction.
    # It has to state that something was withheld, how much, and where it is —
    # a model not told it holds a fragment answers as if it read the whole
    # thing — and nothing beyond that survives being said 2804 times.
    # "Read or grep it" was true and it was not advice. Measured over the
    # transcripts: of 1060 read-backs, **1054 read the whole file and 6 used
    # offset or limit**. A whole-file read hands the entire result back to the
    # context and spends a turn doing it — the two costs this rung exists to
    # avoid — so the pointer was being followed in the one way that makes it
    # worthless.
    #
    # The model was not being careless. It had a path, a size and a line count,
    # and no reason to think a slice would do; the notice named the tool and
    # not the shape of the call. Naming the range costs bytes on every spill
    # and is the cheapest thing here that touches the read-back rate, which the
    # sweep prices as worth more than every compressor combined.
    NOTICE = "\n[lean-output] middle withheld — %<size>s, %<lines>d lines, full text at %<path>s " \
             "(grep it, or Read with offset/limit — a whole-file Read spends what the pointer saved)\n"
    # Said once per window, after the sentence above has established what a
    # lean-output path is and what to do with it. Same three facts — something
    # was withheld, how much, and exactly where — with the explaining of them
    # dropped.
    #
    # `full text at <path>` survives verbatim, and that is deliberate rather
    # than incidental: it is the shape all three rungs use to hand out a path,
    # here, at the ceiling, and in the ledger's reference. A terse form that
    # invented its own would save fifteen more bytes and make every consumer —
    # the model skimming, a grep, this repo's own specs — carry two patterns for
    # one fact. One shape everywhere is worth more than the fifteen bytes.
    TERSE = "\n[lean-output] withheld %<size>s, %<lines>d lines, full text at %<path>s (grep or Read a range)\n"

    # [pointer text, path], because a caller that hands out a pointer has to be
    # able to say so later — the ledger cannot claim the model holds bytes it
    # only ever got a path to.
    def self.spill(session, label, output, policy)
      threshold = policy[:spill]
      return nil unless threshold && output.bytesize > threshold

      path = store(session, label, output) or return nil
      shape = session.explain?('vault') ? NOTICE : TERSE
      notice = format(shape, size: Text.human(output.bytesize), lines: output.count("\n") + 1, path: path)
      [preview(output) + notice, path]
    end

    # Head and tail rather than head alone: the head says what this is, and for
    # a command the verdict is the last line. Falls back to the whole text when
    # it already fits, which only happens if PREVIEW is raised above `spill`.
    #
    # A wider tail than the default costs nothing — the 150B are fixed, this
    # only moves them — and a tail is only worth carrying if it holds a whole
    # line. Over the corpus it does in 53% of spills at the default 25% and 66%
    # at 40%, against a head that still keeps its two identifying lines.
    TAIL = 0.4

    def self.preview(output)
      Text.clip(output, PREVIEW, tail: TAIL) || output
    end
    private_class_method :preview

    def self.root
      File.join(Session.dir, 'vault')
    end

    # Newest first, so the first entry is the session you are in. A spill from
    # a parallel hook can remove a directory between the glob and the stat, and
    # a listing is never worth raising over.
    def self.sessions
      Dir.glob(File.join(root, '*')).select { |path| File.directory?(path) }
                                    .sort_by { |path| -File.mtime(path).to_f }
    rescue StandardError
      []
    end

    # Returns nil on any filesystem trouble, and nil means the result passes
    # through whole — the failure mode of this rung is the behaviour that
    # existed before it, which is the same promise Session makes.
    #
    # Public because the ceiling stores without spilling: it has its own text
    # to send and only needs somewhere for the original to survive.
    def self.store(session, label, output)
      dir = File.join(root, Digest::SHA256.hexdigest(session.id)[0, SESSION_CHARS])
      FileUtils.mkdir_p(dir)
      path = File.join(dir, format('%04d-%s.txt', session.seq, slug(label)))
      File.write(path, output)
      prune(dir)
      FileUtils.rm_rf(evictable)
      path
    rescue StandardError
      nil
    end

    # A session directory past the keep count is only evictable if it has also
    # gone quiet. Counting alone was a bound on disk that was not a bound on
    # correctness: `sessions` is ordered by mtime, so the 21st busiest session
    # is deleted while it is still running, and every pointer it has handed out
    # becomes a path to nothing — silently, since a pointer is only checked
    # when the model follows it.
    #
    # Twenty concurrent sessions is not a hypothetical here. Swarm runs up to
    # four agents per task plus the host, each its own session, each writing
    # into this directory.
    #
    # The window is the ledger's, in time rather than bytes, because that is
    # the promise being kept: a reference may point at anything still inside
    # it, so nothing inside it may be deleted.
    QUIET_HOURS = 6

    def self.evictable
      stale = sessions.drop(SESSIONS)
      cutoff = Time.now.utc - (QUIET_HOURS * 3600)
      stale.reject { |path| File.mtime(path) > cutoff }
    rescue StandardError
      []
    end
    private_class_method :evictable

    # The name is for a human reading `ls`, and for the model recognising its
    # own pointer; the sequence number in front is what makes it unique.
    def self.slug(label)
      cleaned = label.to_s.gsub(/[^A-Za-z0-9]+/, '-').gsub(/\A-|-\z/, '')
      cleaned.empty? ? 'result' : cleaned[0, SLUG_CHARS]
    end
    private_class_method :slug

    # Ordered by the sequence number, read as a number. Sorting the names as
    # strings was right only while every name was the same width: it inverts
    # past seq 9999, and it inverts immediately for any directory holding two
    # widths at once, where the prune deletes the file it just wrote and leaves
    # the old ones un-reclaimable. A number has neither problem and needs no
    # migration.
    def self.prune(dir)
      files = Dir.glob(File.join(dir, '*.txt')).sort_by { |file| File.basename(file)[/\A\d+/].to_i }
      return if files.size <= KEEP

      FileUtils.rm_f(files.first(files.size - KEEP))
    end
    private_class_method :prune
  end
end
