module LeanOutput
  class Runner
    MIN_LINES = 40
    # Only replace the output when it saves at least 30% — below that the
    # rewrite isn't worth the risk of dropping context.
    MAX_RATIO = 0.7

    def self.call(payload)
      return nil if ENV["LEAN_OUTPUT_DISABLE"] == "1"
      return nil unless payload.is_a?(Hash)
      return nil unless payload["tool_name"] == "Bash"

      command = payload.dig("tool_input", "command").to_s
      output = extract_output(payload["tool_response"]).to_s
      return nil if command.empty? || output.lines.size < MIN_LINES

      compressor = Detector.for(command, output) or return nil
      compressed = compressor.compress(output) or return nil
      return nil unless compressed.bytesize < output.bytesize * MAX_RATIO

      {
        "hookSpecificOutput" => {
          "hookEventName" => "PostToolUse",
          "updatedToolOutput" => compressed + footer(output.bytesize, compressed.bytesize)
        }
      }
    end

    def self.extract_output(response)
      case response
      when String then response
      when Hash then [response["stdout"], response["stderr"]].compact.reject(&:empty?).join("\n")
      when Array then response.filter_map { |block| block["text"] if block.is_a?(Hash) }.join("\n")
      end
    end

    def self.footer(before, after)
      saved = (100.0 * (before - after) / before).round
      "\n[lean-output] #{human(before)} → #{human(after)} (-#{saved}%)\n"
    end

    def self.human(bytes)
      bytes >= 1024 ? format("%.1fkB", bytes / 1024.0) : "#{bytes}B"
    end
  end
end
