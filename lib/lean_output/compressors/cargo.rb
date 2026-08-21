# frozen_string_literal: true

module LeanOutput
  module Compressors
    class Cargo
      extend Spannable

      COMMAND      = Shell.word('cargo\s+(?:build|check|clippy|test|run)')
      RUN_COMMAND  = Shell.word('cargo\s+run')
      JSON_FORMAT  = /--message-format[= ]json/
      # libtest output. Panic sites are reported as "panicked at file:line:col",
      # never as rustc art, so this compressor cannot rebuild them.
      TEST_HARNESS = /^(running \d+ tests?$|test result:)/

      # A cargo diagnostic begins with "error[E...]:" or "warning:" (or bare "error:")
      DIAG_HEADER  = /^(error(?:\[([A-Z0-9]+)\])?|warning):\s+(.+)$/
      # Location line: " --> file:line:col"  (leading spaces vary with line-number width)
      LOCATION     = /^\s+--> (.+:\d+:\d+)$/
      # Any location line (for external note references that have no col)
      ANY_LOCATION = /^\s+--> (.+)/
      # Art pipe line prefix
      ART_PIPE     = /^\s*\|/
      # Pure separator pipe (nothing or only whitespace after |)
      PURE_PIPE    = /^\s*\|\s*$/
      # Source echo: "  N | <source>" — one or more digits, optional spaces, pipe, space
      SOURCE_ECHO  = /^\s*\d+\s*\|\s/
      # Suggestion diff lines outside art: " N - old" or " N + new"
      SUGGESTION   = /^\s*\d+\s*[-+]\s/
      # Caret/dash/tilde art: "  |   ^^^^^ label"  or "  |   --- ^^^^^ label"
      # Captures the first run of symbols and everything after.
      CARET_LINE   = /^\s*\|\s+([-^~]+)(.*)/
      # = note: / = help: lines (inside art block)
      NOTE_HELP    = /^\s*=\s*(note|help):\s*(.+)/
      # Standalone help:/note: line (outside art)
      HELP_LINE    = /^(help|note):\s*(.+)/
      # Plain text label inside art pipe: "  |      some label text"
      # (not a source echo, not carets — just a continuation label)
      ART_TEXT     = /^\s*\|\s{2,}([^|\s].+)/
      # Warning footer: "warning: `crate` ... generated N warnings ..."
      WARNING_SUMMARY = /^warning:.*generated \d+ warnings/
      # Compilation failure summary (bare "error:" with no code bracket)
      COMPILE_ERROR   = /^error: could not compile/
      # Noise footer lines to drop entirely
      FOOTER_NOISE = /^(Some errors have detailed explanations:|For more information about an error)/
      # Progress lines
      PROGRESS     = /^\s*(Compiling|Downloading|Updating|Finished|Running|Blocking)\s/
      # Same verbs, but only where cargo puts them. Cargo right-aligns its
      # status column, so the verb always carries leading space; rspec's
      # "Finished in 0.5 seconds" starts at column zero. Without that
      # distinction a `cargo build && rspec` buffer would have one span
      # swallow the other and the whole chain would fall back to passthrough.
      STATUS       = /^\s+(Compiling|Downloading|Updating|Finished|Running|Blocking)\s/

      CORE = Regexp.union(DIAG_HEADER, ANY_LOCATION, ART_PIPE, SOURCE_ECHO, SUGGESTION,
                          NOTE_HELP, HELP_LINE, STATUS, WARNING_SUMMARY, COMPILE_ERROR,
                          FOOTER_NOISE)

      # Only rustc diagnostic output is safe to rewrite. Anything that also
      # carries libtest results or program stdout gets left alone: this
      # compressor rebuilds diagnostics from art, and would silently drop
      # everything else in the buffer.
      def self.command_match?(command)
        command.match?(COMMAND) && !command.match?(JSON_FORMAT)
      end

      def self.output_match?(output)
        plain = Text.plain(output)
        plain.match?(DIAG_HEADER) && plain.match?(ANY_LOCATION) && !plain.match?(TEST_HARNESS)
      end

      def self.applicable?(command, output)
        return false unless command_match?(command)
        return false unless output_match?(output)
        # A successful `cargo run` is followed by the program's own output.
        return false if command.match?(RUN_COMMAND) && !Text.plain(output).match?(COMPILE_ERROR)

        true
      end

      def self.discards = 'source echoes, rustc suggestions'

      # The counts come from the parsed diagnostics rather than a second scan of
      # the text. They used to be two hand-written line counts, each re-deriving
      # the exclusions `parse_diagnostics` already applies — and the two could
      # disagree with the body they introduce, which is the one thing a summary
      # line must never do.
      def self.summary(plain)
        return nil unless plain.match?(DIAG_HEADER)

        diagnostics = parse_diagnostics(plain)
        counts = diagnostics.group_by { |diag| diag[:kind] }
        parts = %i[error warning].filter_map { |kind| tally(kind, counts[kind]&.size) }

        ["Cargo: #{parts.join(', ')}#{failure(plain)}",
         *diagnostics.map { |diag| format_diagnostic(diag) }].join("\n\n") + "\n"
      end

      def self.tally(kind, count)
        "#{count} #{kind}#{'s' unless count == 1}" if count&.positive?
      end
      private_class_method :tally

      # Which crate failed, when a workspace builds several. The name was always
      # meant to be here — `COMPILE_ERROR` matches only as far as "compile", so
      # the old code searched for the crate inside a string that stopped one
      # word before it and printed the bare verdict every time.
      def self.failure(plain)
        line = plain.each_line.find { |l| l.match?(COMPILE_ERROR) } or return ''
        crate = line[/could not compile `([^`]+)`/, 1]

        " — could not compile#{crate ? " `#{crate}`" : ''}"
      end
      private_class_method :failure

      # Lines that carry nothing a rebuilt diagnostic would print: progress,
      # footers, the two summary lines `summary` already counted, and the source
      # echo and suggestion diffs this compressor exists to drop.
      DISCARD = Regexp.union(PROGRESS, FOOTER_NOISE, WARNING_SUMMARY, COMPILE_ERROR,
                             SOURCE_ECHO, SUGGESTION, PURE_PIPE)

      # A diagnostic runs from its own header to the next one, so slicing on the
      # header answers "which diagnostic is this line part of" once, for the
      # whole buffer. That question was previously carried in three mutable
      # variables threaded through fourteen branches — `current`, `in_art` and a
      # pending note — and every one of them existed only to answer it.
      def self.parse_diagnostics(plain)
        lines = plain.each_line.map(&:chomp).reject { |line| line.match?(DISCARD) }
        lines.slice_before { |line| line.match?(DIAG_HEADER) }
             .select { |block| block.first.match?(DIAG_HEADER) }
             .map { |block| parse_block(block) }
      end

      def self.parse_block(block)
        header = block.first.match(DIAG_HEADER)
        diag = { kind: header[1].start_with?('error') ? :error : :warning,
                 code: header[2], message: header[3], location: nil, labels: [], notes: [] }
        # A standalone `help:`/`note:` may be followed by its own location line,
        # which belongs to the note rather than to the diagnostic. It is the one
        # piece of state a single diagnostic genuinely has.
        pending = nil

        block.drop(1).each do |line|
          pending = absorb(diag, line, pending)
        end
        diag[:notes] << pending if pending
        diag
      end
      private_class_method :parse_block

      # Returns the note still waiting for a location. Only the three arms that
      # return change it — every other line leaves it alone, which is the rule
      # the flat loop got wrong: a suggestion marker between a `help:` and the
      # end of its block used to drop the note on the floor.
      def self.absorb(diag, line, pending)
        case line
        when /\A\s*\z/
          diag[:notes] << pending if pending
          return nil
        when ANY_LOCATION then return locate(diag, Regexp.last_match(1), pending)
        when HELP_LINE then return "#{Regexp.last_match(1)}: #{Regexp.last_match(2)}"
        when NOTE_HELP then diag[:notes] << "#{Regexp.last_match(1)}: #{Regexp.last_match(2)}"
        when CARET_LINE then caret_label(diag, Regexp.last_match(2))
        when ART_TEXT then label(diag, Regexp.last_match(1).strip)
        end
        pending
      end
      private_class_method :absorb

      # A location right after a standalone note belongs to the note — that is
      # what "defined here" is pointing at, not where the error is.
      def self.locate(diag, location, pending)
        if pending
          diag[:notes] << "#{pending} (#{location})"
        else
          diag[:location] ||= location
        end
        nil
      end
      private_class_method :locate

      # Whatever follows the caret run is the label rustc drew the carets for,
      # `help:` prefix and all. Reclassifying that as a note would move it away
      # from the span it points at, which is the only thing making it legible.
      def self.caret_label(diag, tail)
        text = tail.strip.sub(/\A[-^~+]+\s*/, '').strip
        diag[:labels] << text unless text.empty?
      end
      private_class_method :caret_label

      # Suggestion insertion markers are runs of symbols with no words in them.
      def self.label(diag, text)
        return if text.empty? || text.match?(/\A[-^~+|]+\z/)

        if (note = text.match(/\A(help|note):\s*(.+)/))
          diag[:notes] << "#{note[1]}: #{note[2]}"
        else
          diag[:labels] << text
        end
      end
      private_class_method :label

      def self.format_diagnostic(diag)
        kind   = diag[:kind] == :error ? 'error' : 'warning'
        header = diag[:code] ? "#{kind}[#{diag[:code]}]" : kind
        out    = +"#{header}: #{diag[:message]}"
        out << "\n  --> #{diag[:location]}" if diag[:location]
        diag[:labels].each { |label| out << "\n  | #{label}" }
        diag[:notes].each  { |note|  out << "\n  = #{note}" }
        out
      end
    end
  end
end
