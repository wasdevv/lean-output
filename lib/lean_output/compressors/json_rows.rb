# frozen_string_literal: true

require 'json'

module LeanOutput
  module Compressors
    # A row set serialized as JSON repeats every key once per row: a 40-row,
    # 7-column result spells the same seven names 40 times. Emitting the names
    # once as a header and the values as rows drops that repetition without
    # dropping a single value.
    #
    # Reachable only from `Detector.by_output`, never from a shell command. JSON
    # printed by a CLI was asked for by a pipeline that will parse it, so
    # rewriting it breaks the caller; a tool result reaching this hook has no
    # consumer but the model, which reads a table as well as it reads JSON.
    class JsonRows
      extend Spannable

      MIN_ROWS = 5
      SEPARATOR = ' | '

      # An MCP result is one document, never a shell line with several commands
      # sharing a buffer, so the span is simply all of it.
      def self.region(plain)
        rows(plain) && (0...plain.length)
      end

      def self.command_match?(_command)
        false
      end

      def self.output_match?(output)
        !rows(output).nil?
      end

      def self.applicable?(command, output)
        command_match?(command) && output_match?(output)
      end

      def self.discards = 'repeated keys and JSON punctuation'

      def self.summary(plain)
        rows = rows(plain) or return nil
        columns = rows.first.keys

        lines = ["JSON rows: #{rows.size} rows, #{columns.size} columns", columns.join(SEPARATOR)]
        rows.each { |row| lines << columns.map { |column| cell(row[column]) }.join(SEPARATOR) }

        "#{lines.join("\n")}\n"
      end

      # Accepts a bare array or an object wrapping exactly one — two arrays and
      # there is no safe way to tell which one is the result set.
      def self.rows(output)
        parsed = JSON.parse(output)
        candidate =
          if parsed.is_a?(Hash)
            arrays = parsed.values.select { |value| value.is_a?(Array) }
            arrays.first if arrays.size == 1
          else
            parsed
          end

        candidate if tabular?(candidate)
      rescue JSON::ParserError
        nil
      end

      def self.tabular?(value)
        return false unless value.is_a?(Array) && value.size >= MIN_ROWS
        return false unless value.all?(Hash)

        columns = value.first.keys
        return false if columns.empty?

        value.all? do |row|
          row.size == columns.size && columns.all? { |column| row.key?(column) } && row.each_value.all? do |cell|
            scalar?(cell)
          end
        end
      end

      # A newline inside a value would split one row across two lines, so the
      # whole result falls back to passthrough rather than emitting a table
      # whose row count lies.
      def self.scalar?(value)
        case value
        when nil, true, false, Numeric then true
        when String then !value.include?("\n")
        else false
        end
      end

      def self.cell(value)
        value.nil? ? 'null' : value.to_s
      end

      private_class_method :rows, :tabular?, :scalar?, :cell
    end
  end
end
