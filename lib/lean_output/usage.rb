# frozen_string_literal: true

require 'json'

module LeanOutput
  # Rung 1 of the ladder in the README — "does this output need to reach the
  # model at all" — as a diagnostic rather than as a rung.
  #
  # It is the cheapest question and the plugin has never implemented it,
  # because until the transcripts existed there was no way to answer it. There
  # is now: a result was *referenced* if something distinctive in it turns up
  # again later in the same session, in the model's own words or in the input
  # of a later tool call.
  #
  # It stayed a diagnostic on purpose. Measured across 5019 results, output
  # nothing ever refers to again is **4.8% of the token-turns**, and no command
  # shape exceeds 39% unreferenced — so a rung acting on this would be choosing
  # from a ceiling of 4.8% with hindsight it does not have at write time. What
  # is worth having is the other direction: this says where an agent is asking
  # for things it then ignores, which is a habit to change rather than a byte
  # to compress.
  #
  # **Referenced is not the same as used**, and the gap is the whole caveat. A
  # file read and understood, that decided the next move without ever being
  # quoted, counts here as unreferenced. So a high number is a question, never
  # a verdict.
  module Usage
    DEFAULT_ROOT = Corpus::DEFAULT_ROOT
    # Long enough that a match means something. Short tokens — a variable name,
    # a number — collide across unrelated results and would mark almost
    # everything as referenced, which is the failure mode that makes a
    # measurement like this useless rather than wrong.
    MIN_TOKEN = 8
    TOKEN = %r{[\w./-]{#{MIN_TOKEN},}}
    # Per result, so one enormous output cannot dominate the index.
    MAX_TOKENS = 200
    # Below this there is nothing to save either way.
    MIN_BYTES = 400

    Row = Struct.new(:command, :bytes, :referenced, keyword_init: true)

    def self.scan(root: DEFAULT_ROOT, since: nil, project: nil)
      Corpus.transcripts(root, since: since, project: project).flat_map do |file|
        ScanCache.fetch('usage', file) { from_session(file) }
                 .map { |row| Row.new(**row.transform_keys(&:to_sym)) }
      end
    end

    def self.from_session(file)
      records = read_records(file)
      return [] if records.size < 5

      index = index_of(records)
      rows = []
      calls = {}
      records.each_with_index do |record, position|
        Corpus.send(:harvest, record, calls) do |payload|
          row = weigh(payload, index, position)
          rows << row if row
        end
      end
      rows
    end
    private_class_method :from_session

    def self.weigh(payload, index, position)
      output = Runner.extract_output(payload['tool_response']).to_s
      return nil if output.bytesize < MIN_BYTES

      { 'command' => Corpus.label(payload), 'bytes' => output.bytesize,
        'referenced' => tokens(output).any? { |token| index[token]&.any? { |at| at > position } } }
    end
    private_class_method :weigh

    # Where each distinctive token turns up in the model's own output, which is
    # the only side of the conversation that can count as "referred to it".
    def self.index_of(records)
      index = Hash.new { |hash, key| hash[key] = [] }
      records.each_with_index do |record, position|
        Array(record.dig('message', 'content')).each do |block|
          next unless block.is_a?(Hash)

          text = case block['type']
                 when 'text' then block['text'].to_s
                 when 'tool_use' then JSON.generate(block['input'])
                 end
          next unless text

          tokens(text).each { |token| index[token] << position }
        end
      end
      index
    end
    private_class_method :index_of

    def self.tokens(text)
      text.scan(TOKEN).reject { |token| token.match?(/\A[\d.]+\z/) }.uniq.first(MAX_TOKENS).to_set
    end
    private_class_method :tokens

    def self.read_records(file)
      File.readlines(file).filter_map { |line| Corpus.send(:parse, line) }
    rescue StandardError
      []
    end
    private_class_method :read_records

    def self.report(rows, limit: 10)
      return 'no results big enough to judge — is the transcript root right?' if rows.empty?

      unreferenced = rows.reject(&:referenced)
      [format('%d results over %s; %d never referred to again (%.1f%% of the bytes)',
              rows.size, Text.human(MIN_BYTES), unreferenced.size,
              100.0 * unreferenced.sum(&:bytes) / rows.sum(&:bytes)),
       'referenced means something distinctive in it turned up later. Deciding without',
       'quoting counts as unreferenced here, so a high number is a question, not a verdict.',
       '',
       format('%-20s %7s %9s %12s', 'command', 'calls', 'never', 'MB never'),
       *ranked(unreferenced, rows, limit)].join("\n")
    end

    def self.ranked(unreferenced, rows, limit)
      totals = rows.group_by(&:command).transform_values(&:size)
      unreferenced.group_by(&:command)
                  .sort_by { |_, list| -list.sum(&:bytes) }.first(limit)
                  .map do |command, list|
                    format('%-20s %7d %8.0f%% %11.2fMB', command, totals[command],
                           100.0 * list.size / totals[command], list.sum(&:bytes) / 1024.0 / 1024)
                  end
    end
    private_class_method :ranked
  end
end
