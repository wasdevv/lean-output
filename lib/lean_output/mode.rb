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
    # 4000B clipped 6% of calls for -18.3% of the corpus, and left 2000B as the
    # next step conditional on the re-run meter staying flat. It stayed flat:
    # over 660 real results, 10.7% of rewrites were followed by a re-run within
    # three calls against 11.1% of passthroughs — the control is the higher of
    # the two, so the ceiling was not sending anyone back for what it cut.
    #
    # So the knob was turned, to 2000B, on the same one-sided accounting that
    # put the spill floor at 500B — and it is the same mistake, in the rung
    # where it costs most. Every clip in 152 transcripts, all 17 of them, cut a
    # compressed result between 2,048B and 8,192B. None was above 16kB.
    #
    # A followed clip is worse than a followed spill. The vault stores `output`,
    # so reading back a clipped result does not return the 8kB of distilled
    # failures that were cut — it returns the raw original the compressor had
    # already thrown most of away. 8 of the 17 were read back. The rung pays a
    # turn, re-delivers more bytes than it removed, and is the only one here
    # that destroys anything on the way.
    #
    # At 16kB it fires on nothing this corpus contains, which is the point: it
    # stops being a routine rewrite and goes back to being what its own comment
    # claims it is — the guard against a compressed result that came out
    # enormous anyway. It coincides with SPILL_BYTES because it is the same
    # arithmetic about the same round trip, not because the two are linked.
    CAP_BYTES = 16_000

    # Where an unclaimed result stops being worth carrying and starts being
    # worth pointing at.
    #
    # Every earlier number in this comment was measured on one side of the
    # ledger. "Spilling everything above 500B takes the corpus to -69%" counts
    # what the pointer withholds at delivery and stops there — as if the model
    # never follows it. It does. Counted across 152 transcripts by pairing each
    # notice with a later Read of the path it named, **the model reads back 80%
    # of everything spilled**, and that rate holds from 69% to 85% across 36
    # separate sessions over nine days. It is the behaviour, not an outlier.
    #
    # A followed pointer costs the pointer *plus* the bytes, so the arithmetic
    # is `N` against `280 + rN`, and spilling wins only above `280 / (1 - r)`.
    # At the measured rate that floor is ~1400B, and 500B was buying the
    # plugin's worst trades in bulk:
    #
    #   500B–1.5kB   797 spills   76.2% read back    -64,819 bytes
    #   1.5–4kB      347 spills   85.9% read back    +16,198
    #   4–16kB       182 spills   90.7% read back    +72,330
    #   >16kB         31 spills   64.5% read back   +767,715
    #
    # 59% of all spills were a net loss, and 31 results carry 97% of the win.
    # Sweeping the floor against the same data: 500 → +791,424 bytes, 1200 →
    # +854,226, 1500 → +856,243, 2000 → +855,821, 3000 → +843,171. The top is
    # flat from 1200 to 2000, so this is a plateau rather than a fitted point,
    # and 1500 sits in the middle of it.
    #
    # That fixed one side and left another. Counting bytes says a followed
    # pointer costs 280B; it also costs a *turn*, and this file's own argument
    # for the aggressive default is that a turn is the expensive unit. 90.6% of
    # read-backs happen within one tool call of the notice and 99.2% of them
    # read the whole file, so the dominant pattern is not "fetched later if
    # needed" — it is pointer, then immediately the same bytes anyway, with an
    # extra assistant turn in between that re-reads the entire prefix.
    #
    # Both sides of that are measured per spill rather than assumed. Walking
    # the transcripts in order gives, for each of 1375 spills, how many
    # assistant turns the session still had left to carry it — median 231, mean
    # 445 — and, for each read-back, the prefix that turn actually re-read:
    # median 167,658 tokens. A first pass guessed 112 turns and 121,849 tokens
    # and was wrong in both directions.
    #
    # So a spill is worth `(N - 280)/4 × remaining` when the pointer is the last
    # word, and costs `280/4 × remaining + prefix` when it is not. Swept:
    #
    #      500   -226.8M token-turns   1375 spills, 1106 round trips
    #     1500    -26.2M                567 spills,  489
    #     3000    +18.2M                281 spills,  247
    #     6000    +34.6M                133 spills,  114
    #    16000    +44.7M                 32 spills,   21
    #    24000    +43.5M                 19 spills,   10
    #    40000    +43.3M                 14 spills,    6
    #
    # 500B — the floor for four versions — was costing a quarter of a billion
    # token-turns, and 1.5kB was still negative. Three checks say 16kB is the
    # answer and not an artefact: the fine sweep is flat from 12kB to 40kB with
    # its peak here, dropping the three largest spills leaves the optimum where
    # it is (+26.5M), and moving the pointer's own cost between 200B and 400B
    # does not move it either.
    #
    # What survives is 32 spills of 1375 — and those 32 carry 97% of the byte
    # win at 21 round trips instead of 1106. The rung ends up doing what it
    # always claimed: taking the results that are genuinely enormous, and
    # leaving everything else alone.
    SPILL_BYTES = 16_000

    POLICY = {
      'off' => nil,
      # `min_bytes` is 200 everywhere now. It used to be 400 here and 200 at the
      # aggressive levels, on the reasoning that a conservative level should
      # rewrite less — but the thing this floor gates is the ledger, and the
      # ledger is the one rung with no round trip to be conservative about: a
      # reference is read in place, never fetched. Measured, a reference is 133B
      # at the median and 236B at its largest, and the `ratio` gate below
      # already refuses any that fails to beat the result it replaces.
      #
      # The 200..400B band it excluded holds 1187 results in this corpus, 159 of
      # them repeats — ~26.5kB, or ~1.53M token-turns, that `full` and `safe`
      # were declining to save for no reason either of them can state.
      'safe' => { min_bytes: 200, ratio: 0.85, lossless_only: true },
      'full' => { min_bytes: 200, ratio: 0.70, lossless_ratio: 0.85 },
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
    # The calibrated floor overrides the constant for this working directory
    # and nothing else does — no file, no override, and the constants below
    # stand exactly as they did. `spill` is the only key the sweep measures, so
    # it is the only key that can be replaced.
    def self.policy(level, cwd = nil)
      policy = POLICY[normalize(level) || DEFAULT]
      return policy unless policy&.key?(:spill)

      measured = Calibration.read(cwd) or return policy

      policy.merge(spill: measured['spill'])
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
