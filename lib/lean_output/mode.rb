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
  # session. Here it means `volatile` — the plugin was installed to compress,
  # and silence is consent.
  module Mode
    LEVELS = %w[off safe full ultra volatile].freeze
    # `volatile`, not `full`, and the reason is that a byte is not paid once.
    #
    # Measured over 118 sessions of real transcripts: 94.7% of the token bill is
    # cache reads — the accumulated prefix re-read on every turn — and sessions
    # average 225 turns. So a result admitted to the window is paid roughly once
    # per turn remaining in that session. The 11.96MB of tool output those
    # sessions admitted cost 5.20 billion byte-turns, ~1300M tokens, ~27% of the
    # entire bill.
    #
    # That reframes every level below this one. The compressors win 5.4% of the
    # bytes of a large result; declining to carry it wins 99.3%. Against a
    # multiplier of 225 the first is rounding error. `full` was the right default
    # while the ceiling could destroy something — it no longer can, because the
    # clip rung stores the original before it cuts.
    DEFAULT = 'volatile'

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
    # `volatile`'s ceiling, and the one number in this file that buys more than
    # every compressor put together.
    #
    # The distribution is the argument: over 8694 real results, the largest 10%
    # of calls hold 50.1% of all the bytes, and the largest 1% hold 15.0%. A
    # compressor works the median result — 1261B — and can only ever win a
    # fraction of it. A ceiling works the tail, where the bytes actually are.
    #
    # 4000B clips 6% of calls for -18.3% of the corpus. 2000B would clip 16%
    # for -34.5%, and that is the knob to turn if the re-run meter stays flat;
    # the fidelity cost of a ceiling is not a guess here, it is the one thing
    # this plugin already measures against its own control.
    CAP_BYTES = 4_000

    # Where an unclaimed result stops being worth carrying and starts being
    # worth pointing at. Below it the pointer costs more than the bytes it
    # replaces; the notice alone is ~220B and the preview 400B.
    #
    # Measured over 8901 real results, spilling everything unclaimed above this
    # takes the corpus from 9.82MB to 3.03MB — **-69%**, against -22% for the
    # ceiling and -6% for the compressors. Raising it to 1500B gives back 6
    # points and to 3000B gives back 23, so the aggressive end is where the
    # whole difference lives.
    #
    # 800B while the pointer cost 463B; the floor was always a function of that
    # number, and a cheaper pointer is what moved it. With Vault::PREVIEW at
    # 150B and the path down to ~72B a pointer is ~260B, so at 500B it replaces
    # a result with something under half its size — the same margin every ratio
    # in this file already demands of a rewrite.
    #
    # Replayed over the corpus, 800 → 500 takes the residual from 2.87MB to
    # 2.58MB. Going on to 350 buys 0.09MB more and costs 800 extra spills, which
    # is where a pointer stops being cheaper than the bytes it replaces.
    SPILL_BYTES = 500

    POLICY = {
      'off' => nil,
      'safe' => { min_bytes: 400, ratio: 0.85, lossless_only: true },
      'full' => { min_bytes: 400, ratio: 0.70, lossless_ratio: 0.85 },
      'ultra' => { min_bytes: 200, ratio: 0.85, lossless_ratio: 0.95 },
      'volatile' => { min_bytes: 200, ratio: 0.85, lossless_ratio: 0.95, cap: CAP_BYTES, spill: SPILL_BYTES }
    }.freeze

    DESCRIPTION = {
      'off' => 'every result reaches the model untouched.',
      'safe' => 'only rewrites that discard nothing, plus the ledger.',
      'full' => 'compressors and the ledger, at the measured floors.',
      'ultra' => 'a lower floor and a thinner margin — more rewrites, smaller wins each.',
      'volatile' => "ultra plus the vault: anything over #{Text.human(SPILL_BYTES)} no compressor claimed " \
                    "goes to a file and comes back as its two ends and a path, with a #{Text.human(CAP_BYTES)} ceiling behind it."
    }.freeze

    CONFIG_FILE = 'config.json'

    # `safe` exists because `lossless?` was already a first-class idea in this
    # codebase — grep regroups and keeps every line, everything else throws a
    # backtrace or a banner away on purpose. So "only rewrites that discard
    # nothing" is a guarantee the code can actually make, not a vibe. It is the
    # level for the afternoon you suspect the compressor ate the line you
    # needed and want the savings that carry no such risk.
    def self.policy(level)
      POLICY[normalize(level) || DEFAULT]
    end

    def self.normalize(level)
      value = level.to_s.strip.downcase
      LEVELS.include?(value) ? value : nil
    end

    # Stop at the first source that answers — the kill switch is absolute, an
    # explicit env beats a flag the user forgot they set, the flag beats the
    # configured default, and the default beats nothing.
    def self.resolve(cwd = nil)
      return 'off' if ENV['LEAN_OUTPUT_DISABLE'] == '1'

      normalize(ENV['LEAN_OUTPUT_MODE']) ||
        normalize(flag(cwd)) ||
        normalize(configured_default) ||
        DEFAULT
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
