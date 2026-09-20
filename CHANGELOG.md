# Changelog

Versions are what `/plugin update` installs and what the gemspec ships, so
every entry here names what changed for someone who already had the previous
one. Measurements are from replaying real transcripts; where a number moved,
both numbers are given, because a threshold with one number behind it is how
this project got its longest-lived bug.

## 2.0.0

Requires Claude Code **>= 2.1.274** with `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1`
for the new layer. An older host ignores the `modules` key and keeps every
command hook, so the plugin below is unchanged on it.

### A second pass, at the compaction, that reaches the tool *call*

Everything this plugin did until now rewrote one result on its way in. That
left the larger half untouched, and the README has said so since 1.6.0: tool
calls are **6.49MB against 4.35MB of output** over a week of transcripts, and
`PostToolUse` arrives after the call was already sent. There was no hook that
ran earlier, so the call side was not a rung anyone had skipped — it was out of
reach.

`session.compact` is the one moment the host hands the whole transcript back
and accepts a rewrite. `hooks/compaction.js` registers it and asks `bin/compact`
what may go, pairing each `tool_use` to its `tool_result` by id and answering
three questions per pair:

- **superseded** — the identical call (same tool, byte-identical input) was made
  again later in this same transcript, so the older pair is answered in full
  further down. Call and result are dropped together.
- **spilled** — the result carries a vault locator and the file is still there,
  so the locator line alone replaces the preview around it.
- **repeated** — these exact bytes are kept elsewhere in the window, so this
  copy becomes a one-line note.

**A failure is never dropped**, however many times it was retried, so "zero lost
failures" still holds word for word. A superseded *success* can be dropped, and
that is the contract that changed: the model may have to run that tool again.
Hence the major version.

### It is not the classifier it was modelled on

The demo behind this asks a paid model, per pair, whether a call is still
relevant — a judgement, billed per compaction, with the conversation text and
tool inputs sent to a third party. None of that is here. The three questions
above are decidable from the transcript and the filesystem, offline, for free,
and each has one answer rather than a probability. **No key, no opt-in, no byte
leaves the machine.**

### The call side goes to the vault — which is where the bytes actually were

The three rules above free 248.5kB across 126 transcripts. Measuring both
halves of every pair, instead of only the half a hook had ever been able to
reach, says why that is so small:

```text
all tool bytes 25.15MB   call inputs 14.57MB   results 10.58MB

tool      calls        input       output    share
Bash      10519       9.89MB       6.62MB    65.7%
Read       1497       0.14MB       3.31MB    13.7%
Write       847       2.95MB       0.14MB    12.3%
Edit       1283       1.35MB       0.24MB     6.3%
```

**`Bash` inputs alone are 9.89MB — 39% of every tool byte**, over 10519 calls at
a ~940B average. Those are heredocs, `python3 -c` scripts and long pipelines:
the agent writes a program, runs it once, and the program sits in the window for
the rest of the session. No compressor here has ever seen one, because
compressors read output. `Write` is the same shape inverted — 2.95MB of input
against 0.14MB of result.

So a fourth rule, and it is the vault's own bargain pointed at the call for the
first time: a payload field (`command`, `content`, `new_string`) over
`LEAN_OUTPUT_CALL_FLOOR` (500B) is written to the vault, and the call keeps its
first 200B and a locator. Nothing is destroyed — which is what makes it
applicable to a call at all, since unlike a result a command cannot be
reconstructed by re-running anything. Only the payload field is touched; the
tool's name, its id and every other input field are what the call *says it
did*, and a compaction that edits those is lying about the history.

A call in a pair that is being dropped is not spilled, an errored pair is never
a candidate, and a disk that refuses leaves the call whole.

### `lean compaction` says how much of that the rules actually reach

A pass that removes things needs a number for how much it removes, and this one
now prints it from your own transcripts rather than from an argument:

```text
126 transcripts, 42859 messages, 14471 complete tool pairs
14084 old enough and safe to touch, holding 21.1MB

  does this pair stay?
  superseded       99 pairs    0.7%
  spilled         232 pairs    1.6%
  repeated        926 pairs    6.6%
  left whole    12827 pairs   91.1%

  does this call keep its body?
  elided         5269 pairs   37.4%

freed: 9.5MB of 21.1MB (45%)
residue: 10.1MB of result text in 12827 pairs no rule reached
```

**45%, against 1.2% before the fourth rule.** The two families answer different
questions — "does this pair stay" and "does this call keep its body" — and one
pair can be kept whole while its call is emptied, so the headline is in bytes:
counting pairs would double-count the overlap and undercount the win.

The residue is the honest size of what none of this answers: 10.1MB of result
text in pairs that were never repeated, never spilled and never superseded.
That is the *obsolete*, and it needs a judgement this plugin does not make.

The denominator is `decide`'s own candidate list rather than a second definition
of one, so the measurement cannot drift away from the rules it measures.

Two things the breakdown settles. `repeated` leads because the ingress ledger
already ate the easy duplicates — these are what survives it. And `superseded`
is small because `Bash` is 73% of all pairs and the agent almost never repeats
a command byte for byte; loosening the key to the file path alone moves `Read`
from 25 pairs to 104, which is half a percent for a correctness risk, so it was
left exact.

### Auto-compaction on `turn.complete`, off unless asked

`LEAN_OUTPUT_COMPACT_AT=<percent>` compacts when the context passes that mark,
reading `$.session.usage()` and calling `$.session.compact()` — which the host
only permits from this event. A guard taken before the first await keeps two
turns completing together from starting two compactions.

It is **off by default, on the strength of the number above**. Compacting
earlier than the host would buys an 8.9% pruning and pays the host's full
summarisation sooner, and nothing here can show that trade is worth making for
everyone. Turn it on if your sessions are long enough that you disagree.

### The policy is Ruby; the module is a pipe

`LeanOutput::Compaction` is ordinary library code under the same suite as
everything else — 19 examples covering supersession, orphans, duplicate ids,
the pinned window, evicted vault files and byte-for-byte preservation of user
and assistant text. `hooks/compaction.js` holds no policy at all: it shells out,
and on any surprise — no plugin root, a non-zero exit, empty stdout, unparseable
JSON, an empty message list, or a rewrite that removed nothing — it calls
`next(e)` and the host compacts exactly as it would without the plugin.

The first message and the six most recent are pinned. A call without its
result, a result without its call, and a `tool_use_id` used twice are never
candidates: a result must never outlive its call, and the cheapest way to hold
that is to never touch a pair we cannot see both halves of.

## 1.10.0

### The plugin now knows when a compaction happened, instead of guessing

Two rungs here make a claim about the context window rather than about disk.
The ledger answers a repeat with `byte-identical to … from 4 tool calls back —
298B withheld`, which is only true while those bytes are still above it. The
vault says its long notice once and then switches to the terse one, on the same
premise. Both were guarded by `WINDOW_BYTES`, a 250kB estimate of how much tool
output goes by before a compaction has probably happened — the comment on it
has said "lower it if you work in sessions that compact often" since 1.1.0,
which is an estimate asking the reader to calibrate it by feel.

A compaction replaces everything above it with a summary, and the host fires
`PreCompact` before it does. The plugin now listens: `bin/compress` handles the
event by writing the session's byte counter down as a floor, and the two rungs
refuse anything from before it. No matcher, so `/compact` and an automatic
compaction are treated the same — the window is equally gone either way.

The estimate stays as the outer bound for everything the host does not announce.
What changed is that the one case it exists to approximate is no longer
approximated.

**A spill is deliberately exempt.** Its pointer carries a vault path rather than
a claim about the window, so past the cut it degrades to exactly what a first
occurrence would have delivered: a pointer that still resolves to the full text
on disk. The two references that survive on "it is already above" are the two
that are withdrawn.

The hook returns nothing on this event. Writing to stdout from `PreCompact` is
how a hook steers or blocks the summary, and this one has no opinion about the
summary.

## 1.9.0

### A repeat of a compressed result stops re-sending the summary

The ledger had two answers for "what did the model actually get last time":
the raw bytes, or a vault file. A compressed result is neither — the model got
a distillation, nothing went to disk — so it was answered by declining, which
sent the result back down the ladder for the same compressor to produce the
same summary a second time. That is the shape of every repeated test run.

The third state now has a name and a pointer of its own, worded for what is
actually true: no lines were withheld that anyone can fetch, and no file
exists, but the summary itself is still in the window.

```text
[lean-output] byte-identical to `bundle exec rspec` from 1 tool call back — its 966B summary is already above, not repeated
```

Measured end to end through `bin/compress` on `spec/fixtures/rspec_failures.txt`
with an isolated state dir: **4.6 kB raw → 966 B on the first run → 125 B on
every repeat**, stable across a chain of them and across processes. **841 B per
repeated run**, at every level — the vault never takes these, because a
compressor claimed them.

Two things keep it honest. The pointer competes with the summary it replaces
and not with the raw output behind it, so a reference that beats 4.6 kB while
losing to 966 B is refused — `bin/bench` now fails the build on that
comparison rather than on the raw one. And no head is quoted in this case: the
two lines would be raw output the model never saw.

### A rewrite the host rejects is booked as the passthrough it became

The host validates the replacement against the tool's output shape and
silently keeps the original when it does not match. `Runner` was writing the
ledger before finding that out, so a shape it cannot rebuild — a Bash response
carrying only `stderr` — recorded a summary the model was never shown. Harmless
while the ledger declined those; a pointer at text that does not exist once it
does not. The response is now built before the books are written, and a
rejected rewrite is remembered as delivered whole.

### `/lean analyze` says which rung could reach the leftovers

The ranking says where the bytes are; it never said whether anything could get
at them. The report now splits the residue at the two bounds that gate the
ladder — the ledger floor and the spill threshold — read off the policy and
compared exactly as the runtime compares them, so the report cannot promise a
reach the code does not have:

```text
bytes still on the table, by which rung can reach them:
  under 200B       1471 calls      0.14MB left    4% of the residue
  200B–15.6kB      3358 calls      3.69MB left   96% of the residue
  over 15.6kB         7 calls      0.01MB left    0% of the residue
```

Two more columns say whether those bytes are worth anything. `structure` is the
share sitting in whole lines that repeat or in a prefix at least three lines
share — the only shapes a rewrite that has to stay readable can bank. `deflate`
is the ceiling, and explicitly not a collectable one, since its output is not
text; it earns its line in the negative direction, because where deflate finds
nothing, nothing readable will either.

A week of real transcripts: 96% of the residue is in the compressor band, at
**3% structure against a 54% deflate ceiling**, spread evenly rather than
concentrated. **No new compressor ships with this release, and the report now
says why** — six candidates were measured against this corpus and all six came
back under 2%: diffing a re-read against the previous one (1.8%), a digest
tolerating timestamps and hex ids (0.01 MB), generic prefix factoring (0%),
duplicate-line collapsing (3%, nowhere concentrated), hooking `Edit` and
`Write` (one-line confirmations, 0.17 MB), and a wider recency window (six
calls). Two false alarms worth recording: `Read` looks like 30 MB if you sum
the raw JSON, but that is image base64 the plugin already refuses, and part of
the `grep` output in transcripts is already compressed, so the claimed count
understates the roster.

### `analyze` says whether the compressors ever got a look

```text
64% of these commands trimmed their own output before the hook saw it (| head, | tail, -q):
7654 of 11930 calls, 40% of the bytes. A compressor handed a tail cannot do better than the tail.
```

A compressor is built for `bundle exec rspec` dumping 4.6 kB into the context.
It never sees that when the agent writes `bundle exec rspec 2>&1 | tail -40` —
what arrives is 500 bytes of tail, already distilled, and already missing the
head where RSpec puts the failure descriptions. Measured over 90 days,
**75% of Bash calls arrive self-trimmed, carrying 65% of the Bash bytes at a
563 B median against 949 B for the rest.** It is the single biggest reason a
real corpus reports a fraction of the bench, and nothing in the tool said so —
`-8%` read as "the compressors are done" when a large part of it is "the
compressors were handed a fragment".

### Two constants stop being guesses

The ledger is a cache — context window as internal memory, vault as external
memory, one result as a block, a followed pointer as the I/O operation — and
the [external memory model](https://en.algorithmica.org/hpc/external-memory/)
settles two things here that were previously asserted without evidence.

`MAX_SEEN` caps the ledger at 300 entries while the window is measured in
250 kB of traffic gone by. Different units, nothing guaranteeing they agree,
and a cap that bit first would silently discard hits the window had already
allowed. Replayed against an unbounded ledger over every transcript on one
machine: **the deepest LRU position a hit was ever found at is 151, p50 101,
p99 122, and zero hits are lost to the cap.** 300 is a shade over twice the
worst case — the headroom Sleator–Tarjan says an LRU cache wants
(`LRU_M ≤ 2·OPT_{M/2}`).

The policy is LRU rather than FIFO, which is easy to miss and load-bearing:
`prune` sorts on `seq` and `remember` rewrites `seq` on every repeat, so a
digest that keeps coming back keeps its place — FIFO would evict exactly the
entries earning their keep. `MAX_METER` next to it is pruned by *frequency*,
and the inversion is deliberate: it is not a cache, nothing looks a family up,
and the least-frequent cell is the least informative one.

No code changed. The vault was checked against the same theory and left alone:
it fires **35 times in 90 days** on this corpus, so a better eviction policy
there is worth 0.04 MB.

### A label bug that hid the roster's own home turf

`env -u NAME` takes a **value**, and the prefix peeler stopped dead on it:
`env -u BUNDLE_LOCKFILE BUNDLE_GEMFILE=… bundle exec rspec` ranked **289 calls
and 0.10 MB under a bucket named `BUNDLE_LOCKFILE`** — hiding the exact family
the compressors are built for. Fixing it moved `bundle exec` from 804 to 997
calls and `bin/rails runner` from 230 to 312. The peel now consumes a bare
variable name after an `env` flag, and only that: `env -i bundle exec rspec`
must keep its command, and a real command is never a bare all-caps word.

### `analyze` prints the denominator, which is bigger than the numerator

A tool call is an assistant message — the command, a `Write`'s content, an
`Edit`'s strings — and it occupies the context on the same terms as the result
it produced. **No hook rewrites it**: PostToolUse arrives after it was sent.
Measured over a week, tool calls are **6.49 MB against 4.35 MB of output**, and
`Bash` commands alone are 4.21 MB at a 943 B median. The report now says so, so
`-3%` reads as a share of the reachable half rather than as a failure against
the whole surface.

### Two label bugs the corpus handed over

A flag's value survived the syntax filter and landed in the family slot:
`git -C /home/was/projetos/swarm status` ranked under a bucket named
`git /home/was/projetos/swarm`, and `ruby -e '...'` put 108 calls under
`ruby '`. The family now comes from the first word that *looks* like a
subcommand rather than from the second word.

### The re-run meter, re-checked and still flat

A rewrite that costs a round trip is the one way this plugin loses while its own
numbers improve. Pooled by arm the corpus looks alarming — 53.2% of compressed
results are followed by a re-run within three calls against 30.4% of
passthroughs — and all 23 points are confounding: the compressed arm is test and
lint runners, re-run because that is what an edit-test loop does. Stratified so
each command family is its own control, over 35 families seen in both arms:
**40.5% after a rewrite against 41.2% after a passthrough, -0.7 points,
z = -0.49.** Third corpus, same answer.

**So the meter inside the plugin was stratified too**, because it was the pooled
kind and a pooled meter is a false alarm waiting to be acted on — its own
comment says the threshold gets written when the arms separate, and they would
have separated on nothing. `Session#observe` now keeps a cell per command
family, `[rewritten, rewritten-then-repeated, passthrough,
passthrough-then-repeated]`, and `/lean` sums only families with a sample in
both arms, merged across session files first:

```text
  re-run rate    0.0% after a rewrite, 50.0% after a passthrough (within 3 calls, across 1 command family)
```

Two keys, deliberately: the look-back still matches the **exact** call, since
"the model asked for precisely what it just got" is the signal, while the cell
is keyed by **family**, since command kind is the confounder. The family count
is printed because it is the sample size that decides whether the pair means
anything. The meter is capped at 40 families, pruned by sample size — which
self-selects, since a family with both arms is a family that recurred.

`gain.reruns` and `gain.reruns_base` are **deleted**, not kept beside it: one
meter, and it is the one worth reading. No `Session::VERSION` bump — an older
file just carries two keys nothing reads, and bumping would throw away every
user's ledger to change a measurement. The library path (`LeanOutput.compress`
with `credit:`) passes the same two keys; it was silently dropping its whole
billing when the signature changed, which the housekeeping spec caught.

`ScanCache::VERSION` goes to 4, because rows cached before this release carry
none of the new columns.

Labels got the same treatment, since a ranking is only as good as its rows.
Setup is peeled before the command is named (`cd X &&`, `cd X;`, a bare `cd`
line, `FOO=bar`, `env`, `timeout`, up to four stacked, bounded rather than
looping), the family comes from the second word for thirty-odd runners instead
of nine, and only the first line of the real command is read so a heredoc body
cannot name the row. On that same corpus this moved **371 calls and 0.20 MB out
of a bucket called `cd`** and into `cat`, `sed`, `python3`, `echo` and
`git status`, which are the commands that produced them.

### Also

- The README's ledger benchmark table was still quoting numbers from before the
  spill floor moved to 16 kB in 1.5.0. Re-measured from `bin/bench`; the
  asserted reference counts are unchanged, only the byte totals.

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
