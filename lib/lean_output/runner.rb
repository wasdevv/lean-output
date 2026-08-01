# frozen_string_literal: true

module LeanOutput
  class Runner
    MIN_LINES = 40
    # An MCP result is often one long line, so a line count would never fire.
    MIN_BYTES = 2_000
    # A line count alone misses dense output: JSON on one line, a stack trace in
    # long lines, a short failing suite. Measured over 6.7k real Bash results,
    # a 400B floor reaches 91% of the compressible bytes; below it the average
    # saving falls under ~200B, where the footer costs more than the rewrite.
    BASH_MIN_BYTES = 400
    MCP_TOOL = /\Amcp__/
    # Only replace the output when it saves at least 30% — below that the
    # rewrite isn't worth the risk of dropping context.
    MAX_RATIO = 0.7
    # That 30% is two charges in one: the footer has to pay for itself, and the
    # saving has to be worth the chance of having thrown away the line the
    # reader needed. A lossless rewrite owes only the first. Measured over the
    # corpus, charging grep the full premium threw away 33 kB of savings across
    # 36 results that had discarded nothing to be suspicious of.
    LOSSLESS_RATIO = 0.85

    def self.call(payload)
      return nil if ENV['LEAN_OUTPUT_DISABLE'] == '1'
      return nil unless payload.is_a?(Hash)

      tool = payload['tool_name'].to_s
      # Failed tool calls (PostToolUseFailure) carry the output in "error".
      output = extract_output(payload['tool_response'] || payload['error']).to_s

      compressed = rewrite(tool, payload, output)
      return nil if compressed.nil? || compressed.equal?(output)
      return nil unless compressed.bytesize < output.bytesize * ceiling(tool, payload, output)

      exit_line = output[/\AExit code \d+/]
      compressed = "#{exit_line}\n#{compressed}" if exit_line

      {
        'hookSpecificOutput' => {
          # A failing suite arrives via PostToolUseFailure; the response must
          # name the event that triggered it or it gets ignored.
          'hookEventName' => payload['hook_event_name'] || 'PostToolUse',
          'updatedToolOutput' => compressed + footer(output.bytesize, compressed.bytesize)
        }
      }
    end

    # An MCP tool carries no command, so the text alone has to identify itself.
    def self.rewrite(tool, payload, output)
      case tool
      when 'Bash'
        command = payload.dig('tool_input', 'command').to_s
        return nil if command.empty?
        return nil if output.lines.size < MIN_LINES && output.bytesize < BASH_MIN_BYTES

        LeanOutput.compress(output, command: command)
      when MCP_TOOL
        return nil if output.bytesize < MIN_BYTES

        LeanOutput.compress(output)
      end
    end

    def self.ceiling(tool, payload, output)
      command = payload.dig('tool_input', 'command') if tool == 'Bash'
      LeanOutput.lossless?(output, command: command) ? LOSSLESS_RATIO : MAX_RATIO
    end

    def self.extract_output(response)
      case response
      when String then response
      when Hash then [response['stdout'], response['stderr']].compact.reject(&:empty?).join("\n")
      when Array then response.filter_map { |block| block['text'] if block.is_a?(Hash) }.join("\n")
      end
    end

    def self.footer(before, after)
      saved = (100.0 * (before - after) / before).round
      "\n[lean-output] #{Text.human(before)} → #{Text.human(after)} (-#{saved}%)\n"
    end
  end
end
