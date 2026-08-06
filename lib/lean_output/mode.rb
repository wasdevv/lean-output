# frozen_string_literal: true

require 'json'
require 'digest'
require 'fileutils'

module LeanOutput
  # How hard to compress, resolved fresh on every hook invocation.
  #
  # A hook is a new process per tool call, so a level the user switches
  # mid-session has nowhere to live but disk. That mechanism is lifted from
  # ponytail, which writes a flag file from a slash command and reads it back in
  # every later hook.
  #
  # The precedence inverts ponytail's in one place, and the inversion is the
  # point: there, an absent flag means off, because the skill is opt-in per
  # session. Here it means `full` — the plugin was installed to compress, and
  # silence is consent.
  module Mode
    LEVELS = %w[off safe full ultra].freeze
    DEFAULT = 'full'

    # Each level is a floor and two ceilings, not a different algorithm.
    #
    # `min_bytes` is where a Bash result becomes worth looking at; `ratio` is
    # how much a rewrite has to save to be swapped in; `lossless_ratio` is the
    # same for a rewrite that discards nothing and therefore owes no risk
    # premium.
    #
    # ultra's 200B floor is not a guess: measured over 6725 real Bash results,
    # a 400B floor reaches 89% of the compressible bytes and a 200B floor 97%.
    # The 8 points cost ~145 extra rewrites whose average saving is under 200B,
    # which is where the footer starts eating the win — worth it on demand, not
    # by default.
    POLICY = {
      'off' => nil,
      'safe' => { min_bytes: 400, ratio: 0.85, lossless_only: true },
      'full' => { min_bytes: 400, ratio: 0.70, lossless_ratio: 0.85 },
      'ultra' => { min_bytes: 200, ratio: 0.85, lossless_ratio: 0.95 }
    }.freeze

    DESCRIPTION = {
      'off' => 'every result reaches the model untouched.',
      'safe' => 'only rewrites that discard nothing, plus the ledger.',
      'full' => 'compressors and the ledger, at the measured floors.',
      'ultra' => 'a lower floor and a thinner margin — more rewrites, smaller wins each.'
    }.freeze

    CONFIG_FILE = 'config.json'

    # A context window is not equally expensive throughout a session, so the
    # level is allowed to climb one step once the session is deep enough that
    # the next result is plausibly pushing something out.
    #
    # It only ever climbs. The obvious design was the symmetric one — gentle
    # early, harder later — and the corpus says it would have switched the
    # plugin off for most of what it exists to handle: measured over 94 real
    # sessions, **55% of all tool-output bytes arrive while the session is still
    # under 100kB deep**, and 86% of sessions never reach 250kB at all. Being
    # gentle early is being gentle almost always.
    #
    # 250kB is where the last 18% of bytes live, and it is the same window the
    # ledger already measures references in, so the two numbers stay comparable.
    DEEP_BYTES = 250_000

    # `safe` exists because `lossless?` was already a first-class idea in this
    # codebase — grep regroups and keeps every line, everything else throws a
    # backtrace or a banner away on purpose. So "only rewrites that discard
    # nothing" is a guarantee the code can actually make, not a vibe. It is the
    # level for the afternoon you suspect the compressor ate the line you
    # needed and want the savings that carry no such risk.
    def self.policy(level, depth: nil)
      POLICY[deepen(normalize(level) || DEFAULT, depth)]
    end

    # `depth` is nil whenever the level was chosen rather than defaulted, and
    # that is the whole guard: `lean safe` is someone saying they suspect a
    # compressor ate the line they needed, and a session that got long is not an
    # argument against them. Only an absence of a decision may be moved.
    #
    # No hysteresis, because none is possible: depth is cumulative bytes of tool
    # output, which never decreases, so the step can never oscillate.
    def self.deepen(level, depth)
      return level unless depth.to_i >= DEEP_BYTES

      LEVELS[[LEVELS.index(level) + 1, LEVELS.size - 1].min]
    end

    def self.normalize(level)
      value = level.to_s.strip.downcase
      LEVELS.include?(value) ? value : nil
    end

    # Stop at the first source that answers — the kill switch is absolute, an
    # explicit env beats a flag the user forgot they set, the flag beats the
    # configured default, and the default beats nothing.
    def self.resolve(cwd = nil)
      source(cwd).first
    end

    # [level, :chosen | :default]. The second half is what lets depth move a
    # level without ever overriding one the user asked for.
    def self.source(cwd = nil)
      return ['off', :chosen] if ENV['LEAN_OUTPUT_DISABLE'] == '1'

      chosen = normalize(ENV['LEAN_OUTPUT_MODE']) ||
               normalize(flag(cwd)) ||
               normalize(configured_default)

      chosen ? [chosen, :chosen] : [DEFAULT, :default]
    end

    # The level the user switched to mid-session, in a file because a hook is a
    # fresh process every time. Keyed by working directory rather than by
    # session id: the switch is typed into a shell command, and a shell command
    # knows where it is but not which conversation it belongs to.
    def self.flag(cwd)
      File.read(flag_path(cwd)).strip
    rescue StandardError
      nil
    end

    def self.write(cwd, level)
      normalized = normalize(level) or return nil
      path = flag_path(cwd)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, normalized)
      normalized
    rescue StandardError
      nil
    end

    def self.flag_path(cwd)
      key = Digest::SHA256.hexdigest(cwd.to_s)[0, 16]
      File.join(Session.dir, "mode-#{key}.flag")
    end

    def self.configured_default
      JSON.parse(File.read(config_path))['defaultMode']
    rescue StandardError
      nil
    end

    def self.config_path
      File.join(ENV['LEAN_OUTPUT_CONFIG_DIR'] || default_config_dir, CONFIG_FILE)
    end

    def self.default_config_dir
      File.join(ENV['XDG_CONFIG_HOME'] || File.join(Dir.home, '.config'), 'lean-output')
    end
    private_class_method :default_config_dir
  end
end
