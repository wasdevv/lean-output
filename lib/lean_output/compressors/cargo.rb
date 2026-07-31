# frozen_string_literal: true

module LeanOutput
  module Compressors
    class Cargo
      COMMAND      = /(^|[\s&;|])cargo\s+(build|check|clippy|test|run)(\s|$)/
      RUN_COMMAND  = /(^|[\s&;|])cargo\s+run(\s|$)/
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

      def self.compress(output)
        plain = Text.plain(output)
        return nil unless plain.match?(DIAG_HEADER)

        # Count only real diagnostics — exclude the summary/footer lines
        error_count = plain.each_line.count do |l|
          l.match?(DIAG_HEADER) && l.start_with?('error') &&
            !l.match?(COMPILE_ERROR)
        end
        warning_count = plain.each_line.count do |l|
          l.match?(DIAG_HEADER) && l.start_with?('warning') &&
            !l.match?(WARNING_SUMMARY)
        end
        compile_error = plain[COMPILE_ERROR]

        parts = []
        parts << "#{error_count} error#{error_count == 1 ? '' : 's'}" if error_count.positive?
        parts << "#{warning_count} warning#{warning_count == 1 ? '' : 's'}" if warning_count.positive?
        summary = "Cargo: #{parts.join(', ')}"
        if compile_error
          crate = compile_error[/could not compile `([^`]+)`/, 1]
          summary << " — could not compile#{crate ? " `#{crate}`" : ''}"
        end

        out = +summary
        parse_diagnostics(plain).each do |diag|
          out << "\n\n"
          out << format_diagnostic(diag)
        end
        out << "\n"
      end

      def self.parse_diagnostics(plain)
        diagnostics = []
        current = nil
        in_art = false
        pending_ext_note = nil

        plain.each_line do |raw|
          line = raw.chomp

          # Skip noise and footer lines
          next if line.match?(PROGRESS)
          next if line.match?(FOOTER_NOISE)
          next if line.match?(WARNING_SUMMARY)
          next if line.match?(COMPILE_ERROR)

          # Blank line: ends the current art block.
          # Flush any pending standalone help:/note: that had no following location.
          if line.strip.empty?
            if pending_ext_note && current
              current[:notes] << pending_ext_note
              pending_ext_note = nil
            end
            in_art = false
            next
          end

          # Diagnostic header — starts a new diagnostic entry
          if (m = line.match(DIAG_HEADER))
            current = { kind: m[1].start_with?('error') ? :error : :warning,
                        code: m[2],
                        message: m[3],
                        location: nil,
                        labels: [],
                        notes: [] }
            diagnostics << current
            in_art = false
            pending_ext_note = nil
            next
          end

          next unless current

          # Location line " --> file:line:col" or " --> file:line" (external refs)
          if (m = line.match(ANY_LOCATION))
            if pending_ext_note
              current[:notes] << "#{pending_ext_note} (#{m[1]})"
              pending_ext_note = nil
            else
              current[:location] ||= m[1]
              in_art = true
            end
            next
          end

          # Standalone help:/note: lines — appear either inside or outside art blocks.
          # These may be followed by a location (external ref) or an art block.
          if !line.match?(ART_PIPE) && (m = line.match(HELP_LINE))
            pending_ext_note = "#{m[1]}: #{m[2]}"
            in_art = false
            next
          end

          # ---- Art block / pipe-prefixed line processing ----
          next unless line.match?(ART_PIPE) || in_art

          next if line.match?(PURE_PIPE)

          # Source echo: "  N | code" — discard
          next if line.match?(SOURCE_ECHO)

          # Suggestion diff inside art: "  N - old" / "  N + new"
          next if line.match?(SUGGESTION)

          # = note: / = help: inside art
          if (m = line.match(NOTE_HELP))
            current[:notes] << "#{m[1]}: #{m[2]}"
            next
          end

          # Caret/dash/tilde line: keep the label after the symbols
          if (m = line.match(CARET_LINE))
            # Strip any additional caret/dash/tilde runs that precede the label
            label = m[2].strip.gsub(/\A[-^~+]+\s*/, '').strip
            current[:labels] << label unless label.empty?
            next
          end

          # Plain text label inside pipe: "  |      arguments to this method are incorrect"
          # Excludes lines that are just carets/pluses (suggestion insertion markers).
          next unless (m = line.match(ART_TEXT))

          text = m[1].strip
          next if text == '|'
          # Pure symbol lines (e.g. "++++++++++++") are suggestion markers — discard
          next if text.match?(/\A[-^~+|]+\z/)

          # Inline help:/note: label
          if (hm = text.match(/\A(help|note):\s*(.+)/))
            current[:notes] << "#{hm[1]}: #{hm[2]}"
          else
            current[:labels] << text
          end
        end

        diagnostics
      end

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
