# frozen_string_literal: true

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
    # cost itself: at 400B the previews were 31% of everything this level still
    # sent. The number takes after Ledger::HEAD_LINES, which already settled
    # that two lines identify an output — this is that, plus a line of tail,
    # because a command puts its verdict at the bottom.
    #
    # It is the knob with the steepest curve left: 400B holds the corpus at
    # -65%, 250B at -69%, 150B at -72%. Everything below that is either under
    # the spill floor or compressed signal.
    PREVIEW = 250
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
    NOTICE = "\n[lean-output] middle withheld — %<size>s, %<lines>d lines, full text at %<path>s (Read or grep it)\n"

    def self.spill(session, label, output, policy)
      threshold = policy[:spill]
      return nil unless threshold && output.bytesize > threshold

      path = store(session, label, output) or return nil
      preview(output) + format(NOTICE, size: Text.human(output.bytesize), lines: output.count("\n") + 1, path: path)
    end

    # Head and tail rather than head alone: the head says what this is, and for
    # a command the verdict is the last line. Falls back to the whole text when
    # it already fits, which only happens if PREVIEW is raised above `spill`.
    def self.preview(output)
      Text.clip(output, PREVIEW) || output
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
      dir = File.join(root, session.id)
      FileUtils.mkdir_p(dir)
      path = File.join(dir, format('%04d-%s.txt', session.seq, slug(label)))
      File.write(path, output)
      prune(dir)
      FileUtils.rm_rf(sessions.drop(SESSIONS))
      path
    rescue StandardError
      nil
    end

    # The name is for a human reading `ls`, and for the model recognising its
    # own pointer; the sequence number in front is what makes it unique.
    def self.slug(label)
      cleaned = label.to_s.gsub(/[^A-Za-z0-9]+/, '-').gsub(/\A-|-\z/, '')
      cleaned.empty? ? 'result' : cleaned[0, 40]
    end
    private_class_method :slug

    def self.prune(dir)
      files = Dir.glob(File.join(dir, '*.txt')).sort
      return if files.size <= KEEP

      FileUtils.rm_f(files.first(files.size - KEEP))
    end
    private_class_method :prune
  end
end
