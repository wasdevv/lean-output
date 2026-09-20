# frozen_string_literal: true

require 'json'

module LeanOutput
  # The second pass, and the only rung in this repo that reaches the tool
  # *call*.
  #
  # Everything else here rewrites one result on its way in. That leaves the
  # larger half untouched: measured over a week of transcripts, tool calls are
  # 6.49MB against 4.35MB of output, and `PostToolUse` arrives after the call
  # was already sent. A compaction is the one moment the host hands the whole
  # transcript back and accepts a rewrite, so it is the one moment a call can
  # be taken out of the window at all.
  #
  # What it is NOT is the classifier from the demo this was modelled on. That
  # one asks a paid model, per pair, whether a call is still *relevant* — a
  # judgement, priced per compaction, sending the conversation to a third
  # party. This asks three questions nobody has to be paid to answer:
  #
  #   superseded — the identical call was made again later, so the older pair
  #     is answered by the newer one, in full, further down the same transcript;
  #   spilled    — the result's full text is on disk, and the locator line
  #     alone resolves to it;
  #   repeated   — these exact bytes are already kept elsewhere.
  #
  # Each is decidable from the transcript and the filesystem, offline, for
  # free. A judgement call is not: when in doubt this keeps the pair, and when
  # the whole pass is in doubt the adapter falls back to the host's own
  # compaction.
  module Compaction
    # The newest messages are left alone: they are the turn in progress, and a
    # pair the model is still working through is not old enough for any of the
    # three questions to be safely answerable.
    PINNED_RECENT = 6

    # Both wordings the vault writes end in this. `Readback::NOTICE` matches the
    # whole sentence to *measure* spills; here only the locator matters, because
    # the locator is what survives the rewrite.
    LOCATOR = /^.*full text at (\S+).*$/

    SUPERSEDED = '[lean-output] the identical call was made again later in this ' \
                 'transcript — this older pair was dropped at compaction, its answer is below'
    REPEAT = '[lean-output] byte-identical to a result kept elsewhere in this transcript'

    # The fourth rule, and the one that reaches the bytes.
    #
    # Measured over 126 transcripts on one machine: 25.15MB of tool bytes, of
    # which **call inputs are 14.57MB against 10.58MB of results** — and `Bash`
    # inputs alone are 9.89MB, 39% of everything, at a ~940B average. Those are
    # heredocs, `python3 -c` scripts and long pipelines: the agent writes a
    # program, runs it once, and the program sits in the window for the rest of
    # the session. No compressor here has ever seen one, because compressors
    # read output.
    #
    # The three rules above free 248.5kB of that. This one frees 10.31MB.
    #
    # It is the vault's own bargain, pointed at the call for the first time:
    # the body goes to disk, the call keeps its head and a locator, and the
    # content is still fetchable. Nothing is destroyed — which is what makes it
    # applicable to a call at all, since unlike a result a command cannot be
    # reconstructed by running anything.
    CALL_FLOOR = 500
    # Enough to recognise the command — `python3 - <<'PY'`, `bundle exec rspec
    # spec/foo_spec.rb`, the first line of a heredoc — without carrying its body.
    CALL_HEAD = 200
    # The one field of each tool's input that holds the payload. Everything else
    # in an input is a path or a flag, and rewriting those would change what the
    # call says it did.
    PAYLOAD = %w[command content new_string].freeze
    CALL_NOTICE = "\n[lean-output] %<size>s of this call elided, full text at %<path>s (Read it)"

    def self.call_floor
      value = ENV['LEAN_OUTPUT_CALL_FLOOR'].to_i
      value.positive? ? value : CALL_FLOOR
    end

    Pair = Struct.new(:id, :use_at, :use, :result_at, :result)

    # Returns the rewritten messages, or nil when there is nothing to do. nil is
    # the caller's signal to let the host compact normally — this pass never
    # returns a partial or a best effort.
    def self.prune(messages, session = nil)
      return nil unless messages.is_a?(Array)

      free = free_range(messages) or return nil
      drop, shrink, _candidates, bulky = decide(pairs(messages), free)
      calls = spill(session, bulky)
      return nil if drop.empty? && shrink.empty? && calls.empty?

      rebuilt = apply(messages, drop, shrink, calls)
      # The host refuses an empty result — "a compaction leaves at least one".
      # Message 0 is pinned, so this cannot fire; it is here because the one
      # thing worse than declining is returning a transcript the host rejects.
      rebuilt.empty? ? nil : rebuilt
    end

    # The first message states the task and the last few are the live turn.
    # Both ends are pinned, so the pass only ever works on the middle.
    def self.free_range(messages)
      last = messages.size - PINNED_RECENT
      last > 1 ? (1...last) : nil
    end
    private_class_method :free_range

    # Only complete, unambiguous pairs become candidates. A call still awaiting
    # its result, a result whose call is missing, and a `tool_use_id` used twice
    # are all left exactly where they are: the invariant that matters most here
    # is that a result never outlives its call, and the cheapest way to hold it
    # is to never touch a pair we cannot see both halves of.
    def self.pairs(messages)
      uses = index(messages, 'toolUses')
      results = index(messages, 'toolResults')

      uses.filter_map do |id, (at, use)|
        next unless (found = results[id])

        Pair.new(id, at, use, found[0], found[1])
      end
    end
    private_class_method :pairs

    def self.index(messages, key)
      seen = {}
      duplicated = {}
      messages.each_with_index do |message, at|
        blocks = message.is_a?(Hash) ? message[key] : nil
        next unless blocks.is_a?(Array)

        blocks.each do |block|
          id = block.is_a?(Hash) ? block['tool_use_id'] : nil
          next unless id.is_a?(String)

          duplicated[id] = true if seen.key?(id)
          seen[id] = [at, block]
        end
      end
      seen.reject { |id, _| duplicated[id] }
    end
    private_class_method :index

    # Newest first, so both "made again later" and "kept elsewhere" are decided
    # against what has already been settled as staying. Walking forwards would
    # answer them against pairs this pass is about to remove.
    #
    # The third return value is for `survey` alone: the pairs this pass was
    # allowed to have an opinion about. Handing it back rather than letting the
    # measurement recompute it is the whole point — a survey with its own copy
    # of "what counts as a candidate" measures its copy, and the two drift the
    # first time a rule here moves.
    def self.decide(pairs, free)
      calls = {}
      bodies = {}
      drop = {}
      shrink = {}
      candidates = []
      bulky = {}

      pairs.sort_by(&:use_at).reverse_each do |pair|
        text = pair.result['text'].to_s
        key = call_key(pair.use)
        digest = Ledger.digest(text)

        # A pinned pair and a failure are both settled before anything is asked
        # of them, but they still register: a kept error is a perfectly good
        # answer for an older identical call to be superseded by, and its bytes
        # are a perfectly good reason not to repeat themselves.
        if !movable?(pair, free) || truthy?(pair.result['isError'])
          calls[key] = true
          bodies[digest] = true
          next
        end

        candidates << pair
        if calls[key]
          drop[pair.id] = SUPERSEDED
        else
          note = shorten(text, bodies[digest])
          shrink[pair.id] = note if note
          # Only for a pair that is staying. A dropped one takes its call with
          # it, and spilling a body that is about to leave the window writes a
          # file nothing will ever point at.
          found = payload(pair.use) and bulky[pair.id] = found
        end

        calls[key] = true
        bodies[digest] = true
      end

      [drop, shrink, candidates, bulky]
    end
    private_class_method :decide

    # [field, body] when the call carries a payload worth putting on disk, nil
    # otherwise. The floor is what the locator costs plus enough margin that a
    # spill is never a net loss: below it the notice is most of what it saved.
    def self.payload(use)
      input = use['input']
      return nil unless input.is_a?(Hash)

      field = PAYLOAD.find { |name| input[name].is_a?(String) && input[name].bytesize > call_floor }
      field ? [field, input[field]] : nil
    end
    private_class_method :payload

    # Writes each body to the vault and returns the replacement inputs. A store
    # that fails returns no path, and that call is simply left whole — the same
    # answer every other rung here gives when the disk refuses.
    #
    # The id leads the label so two calls in one compaction cannot collide:
    # `Vault.store` names the file from the session's seq, which does not move
    # while this runs.
    def self.spill(session, bulky)
      return {} unless session && bulky&.any?

      bulky.each_with_object({}) do |(id, (field, body)), calls|
        label = "#{id.to_s.delete_prefix('toolu_')[0, 8]} #{field}"
        path = Vault.store(session, label, body) or next

        notice = format(CALL_NOTICE, size: Text.human(body.bytesize), path: path)
        calls[id] = { field => Text.clip(body, CALL_HEAD, tail: 0.0).to_s + notice }
      end
    rescue StandardError
      {}
    end
    private_class_method :spill

    # Both halves have to be in the free range. A pair straddling the pinned
    # window would otherwise lose its call while its result sat in the part
    # this pass promised not to touch.
    def self.movable?(pair, free)
      free.cover?(pair.use_at) && free.cover?(pair.result_at)
    end
    private_class_method :movable?

    # The tool plus its exact input. Exact rather than per-tool identifying
    # keys — a second `Read` of the same path, a re-run of the same command, a
    # repeat of the same grep — because "the same call" is the claim being made
    # and anything looser starts guessing which arguments mattered.
    def self.call_key(use)
      [use['tool'].to_s, JSON.generate(use['input'])]
    rescue StandardError
      # An input that will not serialise is an input we cannot compare, and a
      # key nothing else can equal is the conservative answer.
      [use['tool'].to_s, use.object_id]
    end
    private_class_method :call_key

    # nil keeps the result whole. The two shortenings are ordered by how much
    # they promise: bytes kept elsewhere in the same window need no locator,
    # while a spill needs its path or the content is unreachable.
    def self.shorten(text, repeated)
      return REPEAT if repeated && REPEAT.bytesize < text.bytesize

      line = text[LOCATOR] or return nil
      path = text[LOCATOR, 1]
      # The vault evicts whole session directories. A locator that no longer
      # resolves is worse than the preview it would replace.
      return nil unless path && File.exist?(path)

      line.bytesize < text.bytesize ? line : nil
    end
    private_class_method :shorten

    def self.apply(messages, drop, shrink, calls)
      messages.filter_map do |message|
        next message unless message.is_a?(Hash)

        uses = recall(message['toolUses'], drop, calls)
        results = rewrite(message['toolResults'], drop, shrink)
        next message if uses.equal?(message['toolUses']) && results.equal?(message['toolResults'])

        rebuild(message, uses, results)
      end
    end
    private_class_method :apply

    # The call side: a dropped pair's call goes, a spilled call keeps its head
    # and its locator. This is the only place in the repo that rewrites a
    # `tool_use`, and it rewrites exactly one field of it — the payload the
    # vault now holds. The tool's name, its id and every other input field are
    # left alone, because those are what the call *says it did* and a compaction
    # that edits them is lying about the history.
    def self.recall(blocks, drop, calls)
      return blocks unless blocks.is_a?(Array)

      changed = false
      kept = blocks.filter_map do |block|
        id = block.is_a?(Hash) ? block['tool_use_id'] : nil
        if drop.key?(id)
          changed = true
          next
        end
        next block unless (replacement = calls[id])

        changed = true
        block.merge('input' => block['input'].merge(replacement))
      end
      changed ? kept : blocks
    end
    private_class_method :recall

    def self.rewrite(blocks, drop, shrink)
      return blocks unless blocks.is_a?(Array)

      changed = false
      kept = blocks.filter_map do |block|
        id = block.is_a?(Hash) ? block['tool_use_id'] : nil
        if drop.key?(id)
          changed = true
          next
        end
        next block unless (note = shrink[id])

        changed = true
        block.merge('text' => note)
      end
      changed ? kept : blocks
    end
    private_class_method :rewrite

    # A message whose blocks changed comes back as a new object without its
    # `handle`: the handle names the message the host already holds, and this
    # is no longer that message. A message nothing touched is returned as the
    # same object, which is how the host tells the two apart.
    def self.rebuild(message, uses, results)
      rebuilt = message.reject { |key, _| %w[handle toolUses toolResults].include?(key) }
      rebuilt['toolUses'] = uses if uses.is_a?(Array) && !uses.empty?
      rebuilt['toolResults'] = results if results.is_a?(Array) && !results.empty?
      # Nothing left to carry: no text, no call, no result. Dropping it is the
      # only way a removed pair actually leaves the window.
      return nil if rebuilt['text'].to_s.empty? && !rebuilt.key?('toolUses') && !rebuilt.key?('toolResults')

      rebuilt
    end
    private_class_method :rebuild

    def self.truthy?(value)
      !value.nil? && value != false
    end
    private_class_method :truthy?

    # --- what the three rules actually reach, on real transcripts ------------
    #
    # The rules answer "redundant or recoverable". A classifier answers "still
    # relevant", which is a strictly larger question and a paid one. Whether the
    # difference is worth buying is not a matter of opinion: it is the share of
    # old pairs these rules leave behind, and it is sitting in the transcripts
    # on this machine.
    #
    # Measured against `decide`'s own candidate list rather than a second
    # definition of one, so the denominator cannot drift away from the rules.

    Survey = Struct.new(:files, :messages, :pairs, :candidates, :superseded, :spilled,
                        :repeated, :elided, :freed, :bytes, :residue_bytes, keyword_init: true) do
      def caught = superseded + spilled + repeated
      def residue = candidates - caught
      # Bytes, not pairs. The two families of rule answer different questions —
      # "does this pair stay" and "does this call keep its body" — and one pair
      # can be kept whole while its call is emptied, so counting pairs would
      # double-count the overlap and undercount the win. What a compaction is
      # for is bytes.
      def reach = bytes.zero? ? 0.0 : 100.0 * freed / bytes
    end

    def self.survey(root: Corpus::DEFAULT_ROOT, since: nil, project: nil)
      totals = Survey.new(files: 0, messages: 0, pairs: 0, candidates: 0, superseded: 0,
                          spilled: 0, repeated: 0, elided: 0, freed: 0, bytes: 0, residue_bytes: 0)
      Corpus.transcripts(File.expand_path(root), since: since, project: project).each do |file|
        count(totals, from_transcript(file))
      end
      totals
    end

    def self.count(totals, messages)
      totals.files += 1
      totals.messages += messages.size
      free = free_range(messages) or return totals
      found = pairs(messages)
      totals.pairs += found.size
      drop, shrink, candidates, bulky = decide(found, free)
      totals.candidates += candidates.size
      bulky.each_value do |(_field, body)|
        totals.elided += 1
        totals.freed += body.bytesize - CALL_HEAD - CALL_NOTICE.bytesize
      end
      candidates.each { |pair| totals.bytes += pair.result['text'].to_s.bytesize + payload_size(pair.use) }

      candidates.each do |pair|
        text = pair.result['text'].to_s
        if drop.key?(pair.id)
          totals.superseded += 1
          # The call side counts here and nowhere else in this repo: a dropped
          # pair takes its `tool_use` with it, which is the half no PostToolUse
          # hook has ever reached.
          totals.freed += text.bytesize + JSON.generate(pair.use['input'] || {}).bytesize
        elsif (note = shrink[pair.id])
          note == REPEAT ? totals.repeated += 1 : totals.spilled += 1
          totals.freed += text.bytesize - note.bytesize
        else
          totals.residue_bytes += text.bytesize
        end
      end
      totals
    end
    private_class_method :count

    # A Claude Code transcript into the shape `session.compact` hands over. Only
    # the fields the rules read are built; anything this cannot recognise is
    # skipped, which understates the reach rather than inventing it.
    def self.payload_size(use)
      found = payload(use)
      found ? found[1].bytesize : 0
    end
    private_class_method :payload_size

    def self.from_transcript(file)
      messages = []
      File.foreach(file) do |line|
        record = begin
          JSON.parse(line)
        rescue StandardError
          nil
        end
        next unless record.is_a?(Hash) && %w[user assistant].include?(record['type'])

        message = message_from(record) and messages << message
      end
      messages
    rescue StandardError
      []
    end

    def self.message_from(record)
      content = record.dig('message', 'content')
      return { 'role' => record['type'], 'text' => content } if content.is_a?(String)
      return nil unless content.is_a?(Array)

      message = { 'role' => record['type'], 'text' => '' }
      texts = []
      content.each do |block|
        next unless block.is_a?(Hash)

        case block['type']
        when 'text' then texts << block['text'].to_s
        when 'tool_use'
          (message['toolUses'] ||= []) << { 'tool_use_id' => block['id'], 'tool' => block['name'],
                                            'input' => block['input'] || {} }
        when 'tool_result'
          (message['toolResults'] ||= []) << { 'tool_use_id' => block['tool_use_id'],
                                               'text' => block_text(block['content']),
                                               'isError' => truthy?(block['is_error']) }
        end
      end
      message['text'] = texts.join("\n")
      message
    end
    private_class_method :message_from

    def self.block_text(content)
      return content.to_s if content.is_a?(String)

      Array(content).filter_map { |part| part['text'] if part.is_a?(Hash) }.join("\n")
    end
    private_class_method :block_text

    def self.report(survey)
      return 'no transcripts found' if survey.files.zero?

      [format('%d transcripts, %d messages, %d complete tool pairs', survey.files, survey.messages,
              survey.pairs),
       format('%d old enough and safe to touch, holding %s', survey.candidates, Text.human(survey.bytes)),
       '',
       '  does this pair stay?',
       rule_row('superseded', survey.superseded, survey.candidates),
       rule_row('spilled', survey.spilled, survey.candidates),
       rule_row('repeated', survey.repeated, survey.candidates),
       rule_row('left whole', survey.residue, survey.candidates),
       '',
       '  does this call keep its body?',
       rule_row('elided', survey.elided, survey.candidates),
       '',
       format('freed: %s of %s (%.0f%%)', Text.human(survey.freed), Text.human(survey.bytes), survey.reach),
       format('residue: %s of result text in %d pairs no rule reached — the surface a ' \
              'relevance classifier would have to justify',
              Text.human(survey.residue_bytes), survey.residue)].join("\n")
    end

    def self.rule_row(name, count, total)
      share = total.zero? ? 0.0 : 100.0 * count / total
      format('  %-12s %6d pairs  %5.1f%%', name, count, share)
    end
    private_class_method :rule_row
  end
end
