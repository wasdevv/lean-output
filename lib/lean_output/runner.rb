# frozen_string_literal: true

module LeanOutput
  # The hook's decision, as a ladder: stop at the first rung that holds.
  #
  # Rung 2 — does the model already have these bytes? — runs before rung 7, the
  # compressors, because the cheapest rewrite of a result is the one that was
  # never worth sending twice. The order is the whole idea; a compressor asked
  # to shorten text the context already holds is optimising the wrong axis.
  class Runner
    MIN_LINES = 40
    # An MCP result is often one long line, so a line count would never fire.
    MIN_BYTES = 2_000
    MCP_TOOL = /\Amcp__/
    # Read carries no noise a compressor could strip — a source file is all
    # signal — so it reaches the ladder for rung 2 only. It is also the largest
    # untouched surface the hook sees: measured over local transcripts, 28% of
    # Reads re-read a path already read in the same session.
    DEDUPED = %w[Read Bash].freeze
    # The trust boundary a ceiling must not cross. Every other rewrite in this
    # plugin can defend itself as redundancy removal; this one removed content,
    # and a model that does not know it is reading a fragment will answer as if
    # it read the whole thing. So the notice is not a footer, it is the feature:
    # it names the middle as the missing part, and names the two ways to get it.
    CLIPPED = "\n[lean-output] %s clipped to %s — the middle is gone, the ends are intact. " \
              'Do not assume you have seen everything: read the file with offset/limit, ' \
              "or re-run the command narrower, if the part you need was in between.\n"

    def self.call(payload)
      return nil unless payload.is_a?(Hash)
      return Cap.call(payload) if payload['hook_event_name'] == 'PreToolUse'

      tool = payload['tool_name'].to_s
      response = payload['tool_response']
      return nil if response.is_a?(Hash) && response['isImage']

      output = extract_output(response || payload['error']).to_s
      return nil if output.empty?

      session = Session.load(payload)
      level, origin = Mode.source(payload['cwd'])
      policy = Mode.policy(level, depth: (session.bytes if origin == :default))
      return nil unless policy

      climb(session, tool, payload, output, policy)
    end

    # Bookkeeping outlives the decision: a result that passed through still
    # occupied the context, so it still advances the window and still gets
    # remembered — otherwise the second occurrence would have nothing to point
    # at, which is the only way this mechanism can fail quietly.
    def self.climb(session, tool, payload, output, policy)
      rewritten, hit = decide(session, tool, payload, output, policy)

      session.advance(output.bytesize)
      if deduplicable?(tool, output, policy)
        session.remember(Ledger.digest(output), Ledger.label(tool, payload), output.bytesize)
      end
      session.credit(output.bytesize, (rewritten || output).bytesize, hit: hit)
      session.observe(Ledger.label(tool, payload), rewritten: !rewritten.nil?)
      session.save

      rewritten ? respond(payload, rewritten, output) : nil
    end
    private_class_method :climb

    def self.decide(session, tool, payload, output, policy)
      if deduplicable?(tool, output, policy)
        reference = Ledger.reference(session, output, Ledger.label(tool, payload))
        return [reference, true] if reference && reference.bytesize < output.bytesize * policy[:ratio]
      end

      [clip(compressed(tool, payload, output, policy) || output, output, policy), false]
    end
    private_class_method :decide

    def self.compressed(tool, payload, output, policy)
      compressed = rewrite(tool, payload, output, policy)
      return nil if compressed.nil? || compressed.equal?(output)

      ceiling = ceiling(tool, payload, output, policy)
      return nil unless ceiling && compressed.bytesize < output.bytesize * ceiling

      dropped = LeanOutput.discards(output, command: command_for(tool, payload))
      compressed + footer(output.bytesize, compressed.bytesize, dropped)
    end
    private_class_method :compressed

    # The last rung, and the only one that throws away bytes it cannot argue
    # were redundant. It runs after the compressors rather than instead of
    # them, so a result a compressor could fit under the ceiling losslessly is
    # never clipped for nothing.
    #
    # `text` may already be a rewrite, in which case it equals `output` in
    # neither size nor content — the notice quotes the size the model would
    # have received, because that is the number it needs to judge whether to
    # ask again.
    def self.clip(text, output, policy)
      clipped = Text.clip(text, policy[:cap]) or return text.equal?(output) ? nil : text

      clipped + format(CLIPPED, Text.human(text.bytesize), Text.human(policy[:cap]))
    end
    private_class_method :clip

    def self.deduplicable?(tool, output, policy)
      return false unless DEDUPED.include?(tool) || tool.match?(MCP_TOOL)

      output.bytesize >= policy[:min_bytes]
    end

    # An MCP tool carries no command, so the text alone has to identify itself.
    def self.rewrite(tool, payload, output, policy)
      case tool
      when 'Bash'
        command = payload.dig('tool_input', 'command').to_s
        return nil if command.empty?
        return nil if output.lines.size < MIN_LINES && output.bytesize < policy[:min_bytes]

        LeanOutput.compress(output, command: command)
      when MCP_TOOL
        return nil if output.bytesize < MIN_BYTES

        LeanOutput.compress(output)
      end
    end

    # nil rejects the rewrite outright, which is how `safe` refuses anything
    # that throws a byte away rather than merely asking it to save more.
    def self.command_for(tool, payload)
      payload.dig('tool_input', 'command') if tool == 'Bash'
    end
    private_class_method :command_for

    def self.ceiling(tool, payload, output, policy)
      command = command_for(tool, payload)
      return policy[:lossless_ratio] || policy[:ratio] if LeanOutput.lossless?(output, command: command)

      policy[:lossless_only] ? nil : policy[:ratio]
    end

    def self.respond(payload, text, output)
      exit_line = output[/\AExit code \d+/]
      text = "#{exit_line}\n#{text}" if exit_line

      # Mirror whatever extract_output read from, which on a failure event is
      # the bare `error` string rather than a tool_response.
      replacement = reshape(payload['tool_response'] || payload['error'], text) or return nil

      {
        'hookSpecificOutput' => {
          # A failing suite arrives via PostToolUseFailure; the response must
          # name the event that triggered it or it gets ignored.
          'hookEventName' => payload['hook_event_name'] || 'PostToolUse',
          'updatedToolOutput' => replacement
        }
      }
    end
    private_class_method :respond

    # The host validates the replacement against the tool's own output shape and
    # falls back to the original when it does not match — "PostToolUse hook
    # returned updatedToolOutput that does not match <tool>'s output shape;
    # using original output", written to a log nobody reads. A String where Bash
    # returns {stdout, stderr, …} is therefore not an error, it is a silent
    # no-op: every rewrite this plugin made between 0.1.0 and 0.8.0 was
    # discarded on arrival, and the standalone binary passed all the while
    # because it only ever checked its own JSON.
    #
    # So the shape is never constructed, only mirrored: whatever came in is
    # copied and the one field carrying the text is swapped. A shape we do not
    # recognise returns nil and the result passes through untouched, because
    # guessing at a schema is how this bug happened in the first place.
    def self.reshape(response, text)
      case response
      when String then text
      when Array then [{ 'type' => 'text', 'text' => text }]
      when Hash then reshape_hash(response, text)
      end
    end

    def self.reshape_hash(response, text)
      if response.key?('stdout')
        # stderr is folded into the text upstream by extract_output, so leaving
        # the original here would send those bytes twice.
        response.merge('stdout' => text, 'stderr' => '')
      elsif response['file'].is_a?(Hash) && response['file'].key?('content')
        response.merge('file' => response['file'].merge('content' => text))
      end
    end
    private_class_method :reshape_hash

    def self.extract_output(response)
      case response
      when String then response
      when Hash then from_hash(response)
      when Array then response.filter_map { |block| block['text'] if block.is_a?(Hash) }.join("\n")
      end
    end

    def self.from_hash(response)
      file = response['file']
      return file['content'].to_s if file.is_a?(Hash) && file.key?('content')

      [response['stdout'], response['stderr']].compact.reject(&:empty?).join("\n")
    end
    private_class_method :from_hash

    def self.footer(before, after, discards = [])
      saved = (100.0 * (before - after) / before).round
      gone = discards.empty? ? '' : " — dropped: #{discards.join(', ')}"
      "\n[lean-output] #{Text.human(before)} → #{Text.human(after)} (-#{saved}%)#{gone}\n"
    end
  end
end
