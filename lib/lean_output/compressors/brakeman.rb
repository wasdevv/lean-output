module LeanOutput
  module Compressors
    class Brakeman
      COMMAND = %r{(^|[\s/])brakeman(\s|$)}
      SUMMARY = /^Security Warnings: \d+$/

      def self.applicable?(command, output)
        command.match?(COMMAND) && Text.plain(output).match?(SUMMARY)
      end

      def self.compress(output)
        plain = Text.plain(output)
        count = plain[/^Security Warnings: (\d+)$/, 1] or return nil
        errors = plain[/^Errors: (\d+)$/, 1].to_i

        out = +"Brakeman: #{count} security warnings"
        out << ", #{errors} errors" if errors.positive?

        parse_warnings(plain).group_by { |w| w[:file] }.each do |file, warnings|
          out << "\n\n#{file}"
          warnings.sort_by { |w| w[:line] }.each do |w|
            out << "\n  #{w[:line]} [#{w[:confidence]}] #{w[:category]}: #{w[:message]}"
            out << " — #{w[:code]}" if w[:code]
          end
        end

        out << "\n"
      end

      def self.parse_warnings(plain)
        section = plain[/^== Warnings ==\n(.*)/m, 1].to_s
        section.split(/\n{2,}/).filter_map do |block|
          fields = block.scan(/^(\w+): (.*)$/).to_h
          next unless fields["File"] && fields["Line"]

          { file: fields["File"], line: fields["Line"].to_i,
            confidence: fields["Confidence"], category: fields["Category"],
            message: fields["Message"], code: fields["Code"] }
        end
      end
    end
  end
end
