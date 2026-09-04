# frozen_string_literal: true

module LeanOutput
  module Compressors
    # `python -m unittest -v` prints one line per case and then a block per
    # failure. The per-case lines are the bulk on any real suite — five hundred
    # tests is five hundred `... ok` — and each failure block spends four lines
    # on rules and a `Traceback` header before saying anything.
    #
    # Kept: every FAIL and ERROR with its message, the `File "...", line N`
    # that says where, and the verdict at the bottom in the runner's own words.
    # Dropped: the passing lines, the `====`/`----` rules, and the `Traceback
    # (most recent call last):` header that carries no information the frames
    # below it do not.
    #
    # Fixtures captured from `python3 -m unittest -v`, not written from memory.
    class Unittest
      extend Spannable

      COMMAND = /(?:\A|\s)(?:python[\d.]*|py)\b[^|;&]*-m\s+unittest\b|(?:\A|\s)unittest\b/
      # One case, verbose form. The status is the last word.
      CASE = /^\S+ \([\w.]+\)(?: \.\.\.|\s*\.\.\.) /
      # The header of a failure block: `FAIL: name (module.Class)`.
      BLOCK = /^(?:FAIL|ERROR): \S+/
      CORE = Regexp.union(CASE, BLOCK)
      RULE = /^(?:={10,}|-{10,})$/
      TRACE_HEADER = /^Traceback \(most recent call last\):$/
      FRAME = /^\s+File "(.+)", line (\d+), in (\S+)$/
      # `Ran N tests in Xs`, then `OK` or `FAILED (...)`. The verdict, in the
      # runner's own words rather than recounted here.
      RAN = /^Ran \d+ tests? in /
      VERDICT = /^(?:OK|FAILED)\b/

      def self.lossless? = false

      def self.discards = 'passing cases, traceback headers, separator rules'

      def self.command_match?(command)
        command.match?(COMMAND)
      end

      # A verbose case line plus the runner's own tail. `Ran N tests` is the
      # thing no other tool prints, and requiring it keeps this off a buffer
      # that merely happens to contain `... ok`.
      def self.output_match?(output)
        plain = Text.plain(output)
        plain.match?(RAN) && (plain.match?(CASE) || plain.match?(BLOCK))
      end

      def self.applicable?(command, output)
        command_match?(command) && output_match?(output)
      end

      # Spanned explicitly rather than grown, because what this compressor owns
      # has an unambiguous end: the runner's verdict line. Growing towards it
      # through a claim meant listing every shape a traceback body can take —
      # frames, messages, diff lines, blanks — and a claim broad enough to
      # cross all of them is broad enough to swallow whatever ran next on the
      # same shell line.
      def self.region(plain)
        lines = plain.lines
        first = lines.index { |line| line.match?(CORE) } or return nil
        last = lines.rindex { |line| line.match?(VERDICT) } || lines.rindex { |line| line.match?(RAN) }
        return nil unless last && last >= first

        start = lines[0...first].sum(&:length)
        start...(start + lines[first..last].sum(&:length))
      end

      def self.summary(span)
        lines = span.lines
        kept = keep(lines)
        tail = lines.select { |line| line.match?(RAN) || line.match?(VERDICT) }.map(&:rstrip)
        return nil if kept.empty? && tail.empty?

        (kept + tail).join("\n")
      end

      # Walked in order rather than filtered per line, because a failure block
      # is a header, a rule, a traceback and a message, and only the header
      # says which of them belong together.
      def self.keep(lines)
        lines.each_with_object([]) do |line, out|
          next out << line.rstrip if line.match?(BLOCK)
          next if line.match?(RULE) || line.match?(TRACE_HEADER) || line.match?(CASE)
          next if line.match?(RAN) || line.match?(VERDICT) || line.strip.empty?

          out << frame(line)
        end.compact
      end
      private_class_method :keep

      # A frame becomes the `file:line` shape every other compressor here emits,
      # so one grep finds a location whatever tool produced it. Anything else
      # inside a block is the message, and the message is the point.
      def self.frame(line)
        match = FRAME.match(line)
        return "  at #{match[1]}:#{match[2]} in #{match[3]}" if match

        "  #{line.strip}"
      end
      private_class_method :frame
    end
  end
end
