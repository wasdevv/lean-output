# Changelog

Versions are what `/plugin update` installs and what the gemspec ships, so
every entry here names what changed for someone who already had the previous
one. Measurements are from replaying real transcripts; where a number moved,
both numbers are given, because a threshold with one number behind it is how
this project got its longest-lived bug.

## 1.8.1

### `/lean input` — the half of the bill no rung reaches

Every number in this project measures tool *output*. The *input* — the command
in a Bash call, the file body in a `Write`, both strings in an `Edit` — is
written by the model into its own turn and paid under the same arithmetic, once
per turn that remains. Measured over a real corpus: **13.16MB of input against
10.64MB of output. The asking side is 55% of what tool calls cost**, and `Write`
alone is 3.47MB against effectively zero output.

None of it is reachable from a `PostToolUse` hook, and that is not a gap to
close later: the tokens are spent when the model emits the block. So this
command reports and never rewrites.

It earns its place on the second half. Of Bash input, **67% is heredocs**, and
of the heredocs over 1kB, **60% is the second and later paste of a script
already in the window** — 2.14MB, 16% of every byte spent asking, across 133
families. The largest is a 2kB Python script pasted **128 times** in one
session. `/lean input` names them, with what each would not have cost had the
script been written to a file once and run by path.

That fix is a convention, not a rung — and this is how you check whether it
worked.

### `lean rescan` reported failure and did nothing

A formatter removed the lazy `require 'fileutils'` inside `ScanCache.clear`.
`FileUtils` was then undefined, the `NameError` fell into the rescue, and the
command returned `false` forever. Rewritten without the dependency, with a test
that asserts the happy path actually happened.



### The re-run meter was comparing two different populations

`/lean` prints two rates side by side — how often a rewritten result was
followed by the same command again, against the same figure for results it left
alone — and they exist as a pair because neither means anything alone. The pair
was not comparable:

- the rewritten rate was `reruns / rewrites`;
- the control was `reruns_base / (calls - rewrites)`, and `calls` counts every
  result the hook ever saw — every `Read`, every 200-byte `echo`, everything
  with no notion of being re-run.

And a command was identified by `Ledger.label`, which shortens it to 80
characters, so a family of long commands differing only at the end was one
command to the counter.

On a real cache the meter read **40.5% after a rewrite against 18.6% after a
passthrough**. Re-measured over the same transcripts with exact commands and
one population: **1.5% against 0.3%**. Both sides now count what entered the
watch list, keyed by a digest of the whole command.

Three comments in `Mode`, `Session` and `Scoreboard` cited the old numbers to
justify a threshold. They now say the evidence was withdrawn rather than
reading as settled.

## 1.8.0

### Two more runners, both with captured fixtures

`node --test` and `python -m unittest -v`. Both ship with their platform, which
is why these two and not the eight other names `analyze` can flag: a compressor
for a foreign tool needs that tool's real output, and the eight remaining ones
wait for a machine that has them. `/lean fixture <file> <name>` is the path
when you are on one.

- **node --test**: TAP with a YAML block under every case, passing or not, and
  a stack where six of seven frames are `node:internal/test_runner`. Failing
  run **-52%**, green run **-84%**, every failure, message, `expected`/`actual`
  and user `file:line` kept.
- **python -m unittest -v**: one line per case — five hundred tests is five
  hundred `... ok` — plus four lines of rules and a `Traceback` header per
  failure. Failing run **-50%**, green run **-89%**. Traceback frames come out
  in the same `file:line` shape the rest of the plugin emits.

### A half-installed plugin does nothing instead of shouting

The `/plugin update` that installed 1.7.0 left a cache directory with `bin`,
`hooks` and `spec` and **no `lib`**. The manifest said 1.7.0, the hooks pointed
at `bin/compress`, and it exited 1 with a stack trace on stderr before every
tool result. This file promises the opposite — any error is passthrough, exit
0, empty stdout — and the promise had a hole exactly there, because the
requires sat outside the rescue that makes it. Fixed.

## 1.7.0

### The hook costs a third of what it did

**71ms → 23ms per tool call**, output checked byte-identical by md5 on a real
compressing payload. Three separate versions of the same mistake — paying on
every tool call for something only another command needed:

- launched without RubyGems (`ruby -e ""` is 45ms, `--disable=gems` is 8ms),
  with a `rescue LoadError` that brings RubyGems back for the install where a
  default gem was replaced by a real one;
- `fileutils`, required for `mkdir_p`, replaced by four lines — the recursive
  deletes it is genuinely good at are now required inside the methods that
  delete, which run only when something is being evicted;
- `tmpdir`, which pulls `fileutils` back in, moved into the corpus replay that
  the hook never runs.

`/lean profile` reports this for your machine; set `LEAN_OUTPUT_PROFILE=1`
first. Nothing had ever measured it.

### The floor can measure itself

`/lean calibrate` replays your own transcripts, takes the spill floor at the
top of the sweep and writes it for this working directory, with the date and
the sample size printed by `/lean` every time. Under 30 spills it refuses
rather than fitting noise. `/lean trend` shows every calibration, because one
measurement cannot tell drift from noise. `/lean uncalibrate` reverts.

It calibrates `spill` and nothing else — the only constant the sweep measures.

### A constant that was pricing the wrong rung

`Readback::POINTER = 280` was the *ledger's* reference size standing in for the
*vault's* spill, which delivers a 1000-byte preview plus a notice — a measured
median of 1096B. It sat on both sides of the arithmetic every floor rests on.
Now measured per spill from the transcript, which has the number. The decision
survived (the optimum is still 16kB); the margin it claimed did not.

### The pointer names the shape of the call

Of 1060 read-backs measured, **1054 read the whole file and 6 used offset or
limit** — a pointer followed that way hands back everything it withheld and
spends a turn doing it. The notice now names the range. `/lean readback` splits
its rate by which wording the pointer carried, so the change gets its own
population instead of disappearing under months of the old one.

### New commands

| | |
|---|---|
| `/lean compare` | every level replayed over the same corpus, side by side |
| `/lean why <file> [cmd]` | which gate declined a result, instead of "unclaimed" meaning six things |
| `/lean audit <path>` | replays the ladder against a stored original, and counts the `file:line`s that survived |
| `/lean unused` | where the agent asked for output it never referred to again |
| `/lean fixture <file> <name>` | captures real output into `spec/fixtures/` |
| `/lean profile` | what the hook itself costs |
| `/lean rescan` | throws away the per-transcript memo |

`analyze` takes `--since <days>` and `--project <name>`, and names tools it has
no compressor for (pytest, jest/vitest, go test, eslint, tsc, installers)
instead of ranking their output as unclaimable mass.

### Correctness

- **A running session is never evicted from the vault.** Ordered by mtime, the
  21st busiest session was deleted while still running, taking every pointer it
  had handed out. Eviction now needs the directory to have gone quiet, and the
  vault is bounded by bytes rather than by a file count — 400 spills of a
  megabyte was never a bound on disk.
- **Session state is evicted after 14 days.** Measured on a real cache: 53
  files going back four weeks, none of them reachable.
- **Read-modify-write of session state is locked.** Four tool calls in one turn
  are four processes against one file; the write was always atomic, the cycle
  was not, and the loser's ledger entries vanished.
- **`Detector` no longer bails on any `-f j` in the command.** `grep -f
  jargon.txt` and `cargo test --format junit` (which is XML) were disabling
  every compressor on the buffer.
- **`Corpus.label` strips `cd X;` and inline env assignments.** 1196 calls and
  1.00MB of a real corpus ranked under a bucket called `cd`, hiding `python3`,
  `git status` and `bundle exec rspec`.

### Library callers

`LeanOutput.compress(..., credit: "qa-gate")` bills a named caller, so bytes
saved outside the hook stop being invisible to `/lean`. Opt-in: a library call
has no session of its own, and inventing one would put its bytes in the running
conversation's ledger.

### Faster measurements

`analyze` and `readback` memoise per transcript, keyed by size and mtime.
331× on a second pass with identical results; `/lean rescan` clears it. The
memo is keyed by level too — without that, `compare` would have handed one
level the answer another computed.

### Not shipped, and why

Nine ideas were measured and dropped rather than built. They are written down
so nobody pays for the same experiment twice: a `Read` delta rung costs 0.73MB
to replace 0.43MB; the ledger's recency window is not binding (281 hits against
282 with no window at all); a per-shape spill floor beats the global one by 4.7%
with two spills deciding the row that carries the gain; ranking by token-turns
instead of bytes gives the same order.

## 1.6.0 and earlier

See the git log — this file starts here.
