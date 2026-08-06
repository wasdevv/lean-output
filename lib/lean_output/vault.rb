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
  # Measured over 8745 real results: spilling everything unclaimed above 800B
  # with a 400B preview takes 9.69MB to 3.36MB, **-65%**, against -22% for the
  # hard ceiling and -6% for the compressors. The model would have to read back
  # 77% of everything spilled before that win is gone, and the whole point of a
  # pointer is that it reads back the one it needs.
  module Vault
    PREVIEW = 400
    # Files per session, so a long day cannot fill the disk. Old entries are
    # dropped oldest-first; a pointer into a pruned file is a dead pointer, so
    # the number is generous rather than tidy.
    KEEP = 400

    NOTICE = "\n[lean-output] %<size>s, %<lines>d lines — the ends are above, the middle is on disk, " \
             "nothing was lost. Full output: %<path>s\n" \
             "Read that path (with offset/limit if it is long) or grep it, rather than re-running the command.\n"

    def self.spill(session, label, output, policy)
      threshold = policy[:spill]
      return nil unless threshold && output.bytesize > threshold

      path = write(session, label, output) or return nil
      preview(output) + format(NOTICE, size: Text.human(output.bytesize), lines: output.count("\n") + 1, path: path)
    end

    # Head and tail rather than head alone: the head says what this is, and for
    # a command the verdict is the last line. Falls back to the whole text when
    # it already fits, which only happens if PREVIEW is raised above `spill`.
    def self.preview(output)
      Text.clip(output, PREVIEW) || output
    end
    private_class_method :preview

    # Returns nil on any filesystem trouble, and nil means the result passes
    # through whole — the failure mode of this rung is the behaviour that
    # existed before it, which is the same promise Session makes.
    def self.write(session, label, output)
      dir = File.join(Session.dir, 'vault', session.id)
      FileUtils.mkdir_p(dir)
      path = File.join(dir, format('%04d-%s.txt', session.seq, slug(label)))
      File.write(path, output)
      prune(dir)
      path
    rescue StandardError
      nil
    end
    private_class_method :write

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
