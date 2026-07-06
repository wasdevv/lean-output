module LeanOutput
  module Compressors
    class Rspec
      COMMAND = %r{(^|[\s/])rspec(\s|$)}
      SUMMARY = /^\d+ examples?, \d+ failures?.*$/
      GEM_FRAME = %r{/gems/|/rubies/|/ruby/\d}
      SUPPORT_FRAME = %r{\./spec/support/}
      MAX_MESSAGE_LINES = 6

      def self.applicable?(command, output)
        command.match?(COMMAND) && Text.plain(output).match?(SUMMARY)
      end

      def self.compress(output)
        plain = Text.plain(output)
        summary = plain[SUMMARY] or return nil
        finished = plain[/^Finished in .+$/]&.sub(/ \(files took.*\)/, "")
        reruns = plain.scan(/^rspec (\S+) # .*$/).flatten

        out = +"RSpec: #{summary}"
        out << " — #{finished}" if finished

        parse_failures(plain).each_with_index do |failure, i|
          out << "\n\n#{i + 1}) #{failure[:description]}"
          out << "  (rspec #{reruns[i]})" if reruns[i]
          out << "\n   Failure/Error: #{failure[:error]}" if failure[:error]
          failure[:message].each { |line| out << "\n   #{line}" }
          out << "\n   at #{failure[:frame]}" if failure[:frame]
        end

        out << "\n"
      end

      def self.parse_failures(plain)
        section = plain[/^Failures:\n(.*?)(?=^(?:Failed examples:|Pending:|Top \d+ slowest|Finished in ))/m, 1]
        return [] unless section

        section.split(/^ {2}(?=\d+\) )/)
               .reject { |entry| entry.strip.empty? }
               .map { |entry| parse_entry(entry) }
      end

      def self.parse_entry(entry)
        lines = entry.lines.map(&:chomp)
        description = lines.shift.to_s.sub(/^\s*\d+\) /, "").strip
        error = nil
        message = []
        frame = nil
        in_diff = false

        lines.each do |line|
          stripped = line.strip
          next if stripped.empty?

          if stripped.start_with?("# ")
            path = stripped.delete_prefix("# ").sub(/:in .*/, "")
            frame ||= path unless path.match?(GEM_FRAME) || path.match?(SUPPORT_FRAME)
            next
          end

          if stripped.start_with?("Failure/Error:")
            error = stripped.delete_prefix("Failure/Error:").strip
            next
          end

          in_diff ||= stripped == "Diff:"
          next if in_diff
          next if stripped == "(compared using ==)"

          message << stripped if message.size < MAX_MESSAGE_LINES
        end

        { description: description, error: error, message: message, frame: frame }
      end
    end
  end
end
