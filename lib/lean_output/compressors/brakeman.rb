# frozen_string_literal: true

module LeanOutput
  module Compressors
    class Brakeman
      extend Spannable

      COMMAND = Shell.word('brakeman')
      SUMMARY = /^Security Warnings: \d+$/

      # The report is a run of "== Section ==" headers and "Field: value" pairs.
      # Naming the fields rather than accepting any "Word: value" keeps the span
      # from swallowing a neighbouring tool that happens to print a colon.
      FIELD = /^(Application Path|Rails Version|Brakeman Version|Scan Date|Duration|Checks Run|
                 Controllers|Models|Templates|Errors|Security Warnings|Ignored Warnings|
                 Confidence|Category|Check|Message|Code|File|Line|RenderPath|Location|Method|Class): /x
      CORE = Regexp.union(/^== .+ ==$/, FIELD, /^No warnings found$/)

      # Brakeman narrates its startup — a version banner and two dozen
      # "Processing ..." lines — entirely above the first section header, so the
      # noisiest part of the output is only reachable by growing backwards.
      STARTUP = Regexp.union(/^Brakeman v/, /^Scanning /, /^\S.*\.\.\.$/)

      def self.back_claim
        STARTUP
      end

      def self.command_match?(command)
        command.match?(COMMAND)
      end

      def self.output_match?(output)
        Text.plain(output).match?(SUMMARY)
      end

      def self.applicable?(command, output)
        command_match?(command) && output_match?(output)
      end

      def self.discards = 'scan configuration, the checks list'

      def self.summary(plain)
        count = plain[/^Security Warnings: (\d+)$/, 1] or return nil
        errors = plain[/^Errors: (\d+)$/, 1].to_i

        head = "Brakeman: #{count} security warnings#{", #{errors} errors" if errors.positive?}"
        files = parse_warnings(plain).group_by { |warning| warning[:file] }
                                     .map { |file, warnings| format_file(file, warnings) }

        "#{[head, *files].join("\n\n")}\n"
      end

      # Grouped by file and ordered by line, because that is the order someone
      # fixes them in — brakeman itself reports by check.
      def self.format_file(file, warnings)
        lines = warnings.sort_by { |warning| warning[:line] }.map do |warning|
          "  #{warning[:line]} [#{warning[:confidence]}] #{warning[:category]}: " \
            "#{warning[:message]}#{" — #{warning[:code]}" if warning[:code]}"
        end

        [file, *lines].join("\n")
      end
      private_class_method :format_file

      def self.parse_warnings(plain)
        section = plain[/^== Warnings ==\n(.*)/m, 1].to_s
        section.split(/\n{2,}/).filter_map do |block|
          fields = block.scan(/^(\w+): (.*)$/).to_h
          next unless fields['File'] && fields['Line']

          { file: fields['File'], line: fields['Line'].to_i,
            confidence: fields['Confidence'], category: fields['Category'],
            message: fields['Message'], code: fields['Code'] }
        end
      end
    end
  end
end
