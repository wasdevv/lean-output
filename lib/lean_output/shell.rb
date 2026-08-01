# frozen_string_literal: true

module LeanOutput
  # Where one word of a command line ends. Whitespace is the obvious boundary,
  # but `bash -c "rspec && rubocop"` fences its tools with quotes, and a wrapper
  # like that is one of the commonest ways a check suite is invoked — measured
  # over a real transcript corpus it accounted for half the buffers the gem was
  # refusing to read.
  #
  # Widening the boundary widens only the *candidates*: a compressor still has
  # to recognise the output before it claims anything, so a command that merely
  # mentions a tool name in passing gets nowhere.
  module Shell
    BEFORE = %r{(?:^|[\s/'"`;&|(])}
    AFTER = /(?:$|['"`;&|)\s])/

    def self.word(name)
      /#{BEFORE}#{name}#{AFTER}/
    end
  end
end
