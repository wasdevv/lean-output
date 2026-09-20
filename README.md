# lean-output

**A Claude Code plugin that keeps long tool output out of your context window — it spills the big results to disk and hands the model a pointer, withholds what the context already holds, and compresses RSpec, RuboCop, Brakeman, `git diff`, cargo and `grep` on the way past. Fewer tokens, zero lost failures.**

The compressors came first and are not the largest part of the win. Replayed over a corpus of 12008 real tool results, 10.54MB, the split is **43%** compressors, **31%** the vault's pointer and **26%** the ledger's — pointers 57% together. What follows is in ladder order — cheapest rung first, compressors last.

That split used to read 93% pointer against 1.6% compressors, and the number moved because the spill floor did: at 500B the vault took 1307 results in this corpus, at the measured floor of 16kB it takes 18. Both numbers are real; a pointer that gets followed is not a saving, and the floor is where it stopped being one.

Test suites are chatty. A single failing RSpec run ships progress dots, seeds, profiling tables, SimpleCov reports and gem backtraces into your context window — thousands of tokens the model doesn't need. lean-output rewrites those outputs on the fly via a `PostToolUse` hook, keeping **every failure, message and `file:line`** and dropping everything else.

Real capture from a live Claude Code session on **pipeline_hq**, a Rails 8 CRM — one failing spec in a 103-example suite went from **3.2kB to 346B**:

```text
BEFORE — what rspec printed (3.2kB)             AFTER — what the model received (346B)

Exit code 1                                     Exit code 1
                                                RSpec: 103 examples, 1 failure — Finished in 1.89 seconds
Randomized with seed 58159
F...........................................   1) LeanOutput e2e fixture fails on purpose  (rspec ./spec/lean_output_e2e_tmp_spec.rb:4)
                                                   Failure/Error: expect(User.new(email_address: "a@b.com").email_address).to eq("wrong@b.com")
Failures:                                          expected: "wrong@b.com"
  1) ...expectation + gem/support traces...        got: "a@b.com"
                                                   at ./spec/lean_output_e2e_tmp_spec.rb:5
Top 10 slowest examples (0.72675 seconds...
Top 8 slowest example groups ...                [lean-output] 3.2kB → 346B (-90%)
Coverage report generated for RSpec ...
103 examples, 1 failure
Failed examples: ...
```

**-90% of the bytes, 100% of the signal** — the model still pointed at the exact failing `file:line`.

## The cheapest rewrite is the one that never happens

A compressor answers *"what is the shortest text that still carries this signal"*. That is a good question, and it is the last one. Two cheaper ones come first:

1. **Does this output need to reach the model at all?**
2. **Does the model already have these bytes?**

Both are the same test, and neither is a compression problem. `git status` run four times in a session sends the same kilobytes four times; a file Read at the start of a task and Read again at the end sends it twice. No compressor can win against not sending it. So before any of them runs, the result's digest is checked against what this session has already shown the model, and a repeat comes back as a pointer instead:

```text
[lean-output] byte-identical to Read app/services/agents/claude_code.rb from 6 tool calls back — 8.3kB, 214 lines withheld
  # frozen_string_literal: true
  module Agents
```

This is the only rung that reaches `Read`, which no compressor here can touch — a source file is all signal, there is no noise to strip, only the fact that it was already sent.

The reference carries the head of what it withheld on purpose. The risk is not that the pointer is wrong — an identical digest cannot lie about the bytes — but that the occurrence it points at was summarised away by a context compaction, leaving the model holding a pointer into nothing. Two lines is enough to recognise the file, and cheap against the kilobytes withheld.

**A pointer only ever claims what is actually there, and there are three of those.** The earlier occurrence either reached the model whole (`214 lines withheld` — the bytes are up there in the window), or it went to the vault (`full text at /home/…/vault/…` — a file holds what the model did not get), or a compressor claimed it and the model was given a summary. That third case has no raw text anywhere: nothing was withheld that a reader could go and fetch, and no file was written. It used to be answered by declining, which sent the result back down the ladder for the same compressor to distil the same failures a second time. The summary itself is in the window though, so the pointer points at that:

```text
[lean-output] byte-identical to `bundle exec rspec` from 1 tool call back — its 966B summary is already above, not repeated
```

Measured on `spec/fixtures/rspec_failures.txt` end to end through `bin/compress`: the first run delivers 966 B of distilled failures and every repeat delivers 125 B, against 4.6 kB raw. That is **841 B per repeated run of a failing suite**, paid at every level — the vault never takes these, because a compressor claimed them. No head is quoted in this one: the head would be two lines of raw output the model never saw, which costs bytes to show it something new. And the reference has to beat the summary it replaces, not the raw output behind it — a pointer that wins against 4.6 kB while losing to the 966 B it actually stands in for is a rung that costs context to save context, and `bin/bench` fails the build on it.

The ledger is a cache, and it is worth naming which one: the context window is internal memory, the vault is external memory, one result is a block, and *following a pointer* is the I/O operation — which is why this plugin prices a round trip in turns rather than bytes. The [external memory model](https://en.algorithmica.org/hpc/external-memory/model/) is the frame, and it settles two things here that were previously guesses.

`Session::MAX_SEEN` caps the ledger at 300 entries while the window is measured in 250 kB of traffic gone by. Two different units, nothing guaranteeing they agree, and a cap that bit first would silently discard hits the window had already allowed. Replaying every transcript on one machine against an *unbounded* ledger: **the deepest LRU position a hit was ever found at is 151, p50 at 101, p99 at 122.** 300 is a shade over twice the worst case, which is the headroom [Sleator–Tarjan](https://en.algorithmica.org/hpc/external-memory/policies/) says an LRU cache wants — `LRU_M ≤ 2·OPT_{M/2}`, so a cache at twice the observed reuse depth is within a constant factor of knowing the future. Zero hits are lost to the cap.

The policy is LRU and not FIFO, which is easy to miss: `prune` sorts on the entry's `seq` and `remember` rewrites `seq` on every repeat, so a digest that keeps coming back keeps its place. FIFO would evict exactly the entries earning their keep. The re-run meter beside it is pruned by *frequency* instead, and that inversion is deliberate — it is not a cache, nothing looks a family up, and the least-frequent cell is the least informative one by definition.

**How far back a reference may point is measured in tool-output bytes that have gone by, not in tool calls** — forty Reads of a 200-line file and forty `git status` runs push very different amounts of history out of the window. The default is 250 kB, roughly 60k tokens; `bin/bench` prints the sensitivity curve and `LEAN_OUTPUT_WINDOW` overrides it.

That ceiling is an estimate of one specific event: a context compaction, which replaces everything above it with a summary and so makes "you already have these bytes" false. Since 1.10.0 the plugin does not have to estimate it. It registers a `PreCompact` hook — no matcher, so `/compact` and automatic compaction alike — and writes the byte counter down as a floor; a reference to anything from before the floor is refused. The 250 kB ceiling stays as the outer bound for whatever the host does not announce.

**A spill is exempt from the floor, on purpose.** Its pointer carries a vault path rather than a claim about the window, so past the cut it degrades to what a first occurrence would have delivered anyway: a pointer that still resolves to the full text on disk. What is withdrawn is exactly the two references that live on *"it is already above"* — the verbatim one, and the one that declines to repeat a summary.

## Levels

`/lean` shows the current level and what it has saved; `/lean safe` switches. The level is written per working directory and read fresh on every tool call, so nothing needs restarting.

### What it costs

Every number in this README is about bytes removed. None was about the time spent removing them, and the hook is a process per tool call: measured with `/lean profile` on a normal laptop, **23ms end to end, of which 8ms is the Ruby interpreter starting and around 1ms is the work.** It is paid on every call whether or not anything is rewritten.

It was **71ms** three changes ago, and all three were the same mistake in different places — paying on every tool call for something only some other command needed.

| | |
|---|---|
| launching with RubyGems | 45ms of interpreter startup against 8ms without it |
| `fileutils`, for `mkdir_p` | 6.9ms, replaced by four lines that do the same thing |
| `tmpdir`, which pulls `fileutils` back in | required by the corpus replay, which the hook never runs |

Everything the hook requires is a default gem, so dropping RubyGems leaves the output byte-identical — checked by md5 on a real compressing payload — with a fallback that brings RubyGems back if some install has replaced one of them, because a LoadError in the hook would take the whole thing down. Against a result carried for hundreds of turns that is a good trade, and it is now a number you can check rather than an assumption — set `LEAN_OUTPUT_PROFILE=1` and run `/lean profile`.

### `/lean analyze` says which rung could reach the leftovers

The ranking answers *"which command left the most bytes behind"*, which is only half of what you need before writing a compressor: bytes below the ledger floor are not worth a rung, and bytes above the spill threshold are already offered to the vault and declined for reasons the vault sweep priced. So the report splits the residue at the two bounds that actually gate the ladder, read off the policy rather than repeated here, and with the same comparisons the runtime uses — `>= min_bytes` for the ledger, `> spill` for the vault:

```text
bytes still on the table, by which rung can reach them:
  under 200B       1471 calls      0.14MB left    4% of the residue
  200B–15.6kB      3358 calls      3.69MB left   96% of the residue
  over 15.6kB         7 calls      0.01MB left    0% of the residue
```

That is a real week of this machine's transcripts: 96% of everything left sits in the band only a compressor can reach. On its own that reads as a roadmap, which is why the last two columns exist.

And beside it, the reason the saving is what it is:

```text
64% of these commands trimmed their own output before the hook saw it (| head, | tail, -q):
7654 of 11930 calls, 40% of the bytes. A compressor handed a tail cannot do better than the tail.
```

This is the line that separates *"the compressors have nothing left"* from *"the compressors never got a look"*, and until it existed there was no way to tell those apart. A compressor is built for `bundle exec rspec` dumping 4.6 kB into the context. It never sees that when the agent writes `bundle exec rspec 2>&1 | tail -40` — what arrives is 500 bytes of tail, already distilled, and already missing the head where RSpec puts the failure descriptions. Measured over 90 days of one machine, **75% of Bash calls arrive self-trimmed, carrying 65% of the Bash bytes at a 563 B median against 949 B for the rest.** That is the single biggest reason a real corpus reports a fraction of what the bench does, and it is worth reading twice: on a full run the plugin beats `| tail -40` on both axes at once — smaller *and* keeping every `file:line`.

Above the bands sits the denominator this report never printed:

```text
4.02MB of this is tool output, the half a hook can rewrite. The tool *calls* that
produced it are 4.25MB (51% of the two) and no hook reaches them — they are
assistant messages, already sent.
```

A tool call is an assistant message: the command, the file content a `Write` carries, the strings an `Edit` replaces. It sits in the context for the rest of the session on exactly the same terms as the result, and **no PostToolUse hook rewrites it** — that event arrives after the call was sent. That is not a rung this plugin was missing, it is the half of the surface that was out of reach; counting the whole tool call surface over a week it is 6.49 MB against 4.35 MB of output, and `Bash` commands alone are 4.21 MB at a 943 B median. A saving quoted against output alone is quoted against a number a reader will assume is the whole thing.

Since 2.0.0 there is one moment it *is* reachable. A compaction is the host handing the whole transcript back and accepting a rewrite, and `session.compact` is where this plugin's second pass runs — the only one that can take a call out of the window. See [The compaction pass](#the-compaction-pass).

## The compaction pass

Needs Claude Code **>= 2.1.274** and `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1`. An older host ignores it and everything else here works as before.

At a compaction, each `tool_use` is paired to its `tool_result` by id and asked three questions:

| | what it means | what happens |
|---|---|---|
| **superseded** | the identical call — same tool, byte-identical input — was made again later in this transcript | call and result dropped together; the newer answer is still there, in full |
| **spilled** | the result carries a vault locator and the file is still on disk | the locator line replaces the preview around it |
| **repeated** | these exact bytes are kept elsewhere in the window | this copy becomes a one-line note |
| **bulky call** | the call's payload (`command`, `content`, `new_string`) is over 500B | the body goes to the vault; the call keeps its first 200B and a locator |

**A failure is never dropped**, however many times it was retried — "zero lost failures" holds word for word. A superseded *success* can be, and that is the one promise that changed in 2.0.0: the model may have to run that tool again. It is cheap when it happens (the call is repeatable by construction — it was repeated already, which is why the pair was a candidate) and it is the only rung here that removes a call rather than shortening a result.

The first message and the six most recent are pinned. A call still awaiting its result, a result whose call is missing, and a `tool_use_id` used twice are never candidates — a result must never outlive its call, and not touching a pair whose halves aren't both visible is the cheapest way to hold that.

**This is not the paid classifier it was modelled on.** The demo behind the idea asks a model, per pair, whether a call is still *relevant*: a judgement, billed per compaction, with your conversation text and tool inputs sent to a third party. None of that is here. The three questions above are decided from the transcript and the filesystem — offline, free, one answer each. **No key, no opt-in, no byte leaves the machine.**

### How much it reaches

`lean compaction` replays your own transcripts through the same rules and prints what they caught. On this machine, 126 transcripts:

```text
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

**Where the bytes were is not where this plugin used to look.** Measured across both halves of every pair: 25.15MB of tool bytes, of which **call inputs are 14.57MB against 10.58MB of results**, and `Bash` inputs alone are 9.89MB — 39% of everything, at a ~940B average. Heredocs, `python3 -c` scripts, long pipelines: written once, run once, resident forever. The three pair rules free 248.5kB of that. Adding the call rule takes it to 9.5MB.

The residue is what none of it answers: 10.1MB of result text in pairs never repeated, never spilled, never superseded — the *obsolete*, which needs a judgement this plugin does not make. `repeated` leads the three because the ingress ledger already removed the easy duplicates; these are what survived it.

`--since <days>` and `--project <name>` narrow it, same as `lean analyze`.

### Auto-compaction

`LEAN_OUTPUT_COMPACT_AT=<percent>` compacts once the context passes that mark. **Off unless set**, because of the number above: compacting earlier than the host would buys an 8.9% pruning and pays the host's full summarisation sooner. Long sessions may disagree; the knob is there.

The policy lives in `LeanOutput::Compaction`, under the same suite as everything else. `hooks/compaction.js` holds none of it: it shells out to `bin/compact`, and on any surprise — no plugin root, a non-zero exit, empty stdout, unparseable JSON, an empty message list, a rewrite that removed nothing — it calls `next(e)` and the host compacts exactly as it would without the plugin.

**`structure` is the share of those bytes a readable rewrite could actually bank** — bytes in whole lines that repeat, or in a leading run at least three lines share. Those are the two shapes every generic compressor takes, and the second is what the `grep` compressor already factors into a header. **`deflate` is the ceiling**, and deliberately not a collectable one: its output is not text a model can read. It earns its line in the negative direction — where deflate finds nothing, nothing that has to stay readable will either.

On this corpus the answer is **3% structure against a 54% deflate ceiling**, and the 3% is spread evenly rather than concentrated anywhere. That is what irreducible looks like: 46% of the residue is `cat`, `sed` and `Read` — prose and source code, where the only rung that can ever win is the one that declines to send it twice. The re-run meter was re-checked on the way, because a rewrite that costs the model a round trip is the one way this plugin can lose while its own numbers improve. Pooled by arm it looks alarming — 53.2% of compressed results are followed by a re-run of the same command within three calls, against 30.4% of passthroughs. That 23-point gap is entirely confounding: the compressed arm is test and lint runners, which are re-run because that is what an edit-test loop does. Stratified so every command family is its own control, across 35 families seen in both arms: **40.5% after a rewrite against 41.2% after a passthrough, -0.7 points, z = -0.49.** Third corpus, same answer.

**The meter inside the plugin now works the same way**, because it did not, and a pooled meter is a false alarm waiting to be acted on. `Session#observe` keeps a cell per command family — `[rewritten, rewritten-then-repeated, passthrough, passthrough-then-repeated]` — and `/lean` sums only the families that have a sample in *both* arms, merged across sessions first, since a family rewritten in one session and passed through in another is a comparison the pair can make and neither can alone:

```text
  re-run rate    0.0% after a rewrite, 50.0% after a passthrough (within 3 calls, across 1 command family)
```

The family count is printed because it is the sample size that decides whether the pair means anything. Two keys are carried, deliberately: the look-back matches the *exact* call, since "the model asked for precisely what it just got" is the signal, while the cell is keyed by *family*, since command kind is the thing being controlled for. The meter is capped at 40 families and pruned by sample size, which self-selects — a family with both arms is a family that recurred. The two pooled counters it replaces were deleted rather than kept beside it; there is one meter, and it is the one worth reading.

Six candidate features were measured against this corpus and all six came back under 2%: diffing a re-read against the previous one (1.8%, and 202 of 545 re-reads share no line at all), a digest that tolerates timestamps and hex ids (0.01 MB), factoring shared prefixes generically (0%), collapsing duplicate lines (3%, nowhere concentrated), hooking `Edit` and `Write` (their results are one-line confirmations, 0.17 MB), and widening the recency window (six calls). Nothing here recommends writing a compressor for `ls` or anything else — and now the tool says so with a number instead of leaving it to an afternoon of hand-written probes.

The labels the ranking groups by got the same treatment, because a ranking is only as good as its rows. Shell setup is stripped before the command is named — `cd X &&`, `cd X;`, a `cd` on its own line, `FOO=bar`, `env`, `timeout`, up to four of them stacked — and the family comes from the second word for thirty-odd runners rather than nine, so `go test`, `mix test`, `kubectl get` and `docker compose` stop hiding under a launcher. Only the first line of the real command is read, so a heredoc body cannot contribute a word to the label. On the corpus above this moved 371 calls and 0.20 MB out of a bucket called `cd` and into the commands that actually produced them.

### The floor is measured, and `/lean calibrate` is how it stays that way

Every threshold below cites a measurement, and until now the path from the measurement back to the constant was a person reading a table and editing this repo. That path was walked three times and got it wrong once — `Readback::POINTER` was the ledger's reference size standing in for the vault's spill, four times cheaper than the thing it priced, on both sides of the arithmetic every floor rests on. It also goes stale in silence: the spill floor was measured on one corpus, and the sentence at the top of this file claiming the pointer was 93% of the win was true at a 500B floor and is 31% at 16kB.

`/lean calibrate` runs the sweep against your own transcripts, takes the floor at the top of the curve, and writes it for this working directory — with the date and the number of spills behind it, printed by `/lean` every time. It calibrates `spill` and nothing else, because `spill` is the only constant the sweep measures. Under 30 spills it refuses and says so rather than fitting noise; `/lean uncalibrate` goes back to the default.

| Level | What it does |
|---|---|
| `off` | Every result reaches the model untouched. Same as `LEAN_OUTPUT_DISABLE=1`, but scoped to this directory. |
| `safe` | Only rewrites that discard nothing, plus the ledger. For the afternoon you suspect a compressor ate the line you needed. |
| `full` | Compressors and the ledger, at the measured floors. |
| `ultra` | A lower byte floor and a thinner margin — more rewrites, smaller wins each. |
| `volatile` | Default. `ultra` plus the vault: anything over 16 kB that no compressor claimed goes to a file and comes back as its two ends and a path. **-13%** at delivery on a real corpus — a small number on purpose, see [why](#and-a-followed-pointer-costs-a-turn-which-is-the-expensive-unit). |

#### Why the default is the aggressive one

A byte is not paid once. Measured over 118 sessions of real transcripts, **94.7%** of the token bill is cache reads — the accumulated prefix re-read on every turn — and a session averages **225 turns**. So a result admitted to the window is paid roughly once per turn remaining in that session. The 11.96 MB of tool output those sessions admitted cost 5.20 billion byte-turns, ~1300M tokens, **~27% of the entire bill**.

Against a multiplier of 225, the 5.4% a compressor wins on a large result is rounding error and the 99.3% the vault wins by declining to carry it is the whole product. `full` was the right default while the ceiling could still destroy something; it no longer can, because the clip rung stores the original before it cuts.

### The vault

A compressor asks *"what is the shortest text that still carries this signal"*. The vault declines the question. The result goes to a file, the model gets its two ends and the exact path, and the middle is one `Read` away:

```text
line 1 of the output
line 2 of the output
…
line 4000 of the output
[lean-output] middle withheld — 181.1kB, 4000 lines, full text at /home/…/vault/<session>/0042-grep.txt (Read or grep it)
```

This is the only aggressive rung that owes no fidelity premium, because **nothing is destroyed**. The cost is a possible extra tool call, not a possible wrong answer — and the model pays it only for the result it actually needs.

The case is the shape of the corpus, not the shape of an output: over 8901 real results the largest 10% of calls hold **50.1%** of all the bytes, and the median result is 1261 B. A compressor works the part of the distribution where there is nothing to win.

#### How often the pointer is followed, which is the number that sets the floor

This used to read "the model would have to read back 77% of everything spilled before the win is gone", offered as a comfortable margin. It was never measured. Counted across 152 transcripts by pairing each notice with a later `Read` of the path it named:

**the model reads back 80% of everything spilled** — and the rate holds between 69% and 85% across 36 separate sessions over nine days. It is the behaviour, not an outlier, and it sits above the margin this file called safe.

A followed pointer costs the pointer *plus* the bytes, so spilling is `N` against `280 + rN` and only wins above `280 / (1 - r)` — about 1.4 kB at the measured rate. That is already enough to rule out the 500 B the floor sat at for four versions:

| spilled | count | read back | net |
|---|---|---|---|
| 500 B – 1.5 kB | 797 | 76.2% | **−64,819 B** |
| 1.5 – 4 kB | 347 | 85.9% | +16,198 B |
| 4 – 16 kB | 182 | 90.7% | +72,330 B |
| > 16 kB | 31 | 64.5% | **+767,715 B** |

59% of spills were a net loss, and **31 results carry 97% of the win**. The vault is emphatically worth having — it is just worth having on large results, which is what it was always claimed to be for and not what it was set to do.

#### And a followed pointer costs a turn, which is the expensive unit

Counting bytes is still one-sided. Two more numbers from the same pairing:

- **90.6%** of read-backs happen within **one tool call** of the notice, median gap 1;
- **99.2%** of them read the whole file, not a slice.

So the dominant pattern is not "fetched later, if it turns out to matter". It is: pointer, then immediately the same bytes anyway, with an extra assistant turn wedged in between. And [the argument for the aggressive default](#why-the-default-is-the-aggressive-one) is precisely that a turn is not free — it re-reads the whole accumulated prefix. Measured over 32,199 assistant turns in these transcripts, **the median turn re-reads 121,849 tokens**.

At the 1.5 kB floor a round trip bought 1752 bytes, about 438 tokens, against a turn that re-reads six figures. Both sides of that are then measured **per spill** rather than assumed — walking each transcript in order gives, for all 1375 spills, how many assistant turns the session still had left to carry the result (median **231**, mean 445) and, for each read-back, the prefix that turn actually re-read (median **167,658** tokens). A first pass guessed 112 turns and 121,849 tokens and was wrong in both directions.

A spill is therefore worth `(N − 280)/4 × remaining` when the pointer is the last word, and costs `280/4 × remaining + prefix` when it is not:

| floor | spills | round trips | net token-turns |
|---|---|---|---|
| 500 B | 1375 | 1106 | **−226.8M** |
| 1.5 kB | 567 | 489 | **−26.2M** |
| 3 kB | 281 | 247 | +18.2M |
| 6 kB | 133 | 114 | +34.6M |
| **16 kB** | **32** | **21** | **+44.7M** |
| 24 kB | 19 | 10 | +43.5M |
| 40 kB | 14 | 6 | +43.3M |

**500 B — the floor for four versions — was costing a quarter of a billion token-turns**, and 1.5 kB was still negative. Three checks say 16 kB is the answer rather than an artefact: the fine sweep is flat from 12 kB to 40 kB with its peak here; dropping the three largest spills leaves the optimum where it is (+26.5M); and moving the pointer's own cost between 200 B and 400 B does not move it either.

What survives is **32 spills of 1375**, carrying 97% of the byte win at 21 round trips instead of 1106.

#### What that costs on the number this repo used to quote

`bin/lean analyze` reports **-74% at 500 B, -62% at 1.5 kB, and -13% at 16 kB.** That is not a footnote, it is the headline moving by sixty points, and it is worth being blunt about why: the delivery-side number was never the objective. It counts bytes withheld at the moment of handover and charges nothing for fetching them back or for the turn spent doing it. Optimising it is what put the floor at 500 B, where the rung was losing on 59% of its own firings.

The vault is now what it always claimed to be — the rung for results that are genuinely enormous — and it is a much smaller rung than the old number implied.

One assumption carries this, and it is worth naming since the other one is now gone. The 80% was observed *at the old floor*: the results below it are simply delivered from here, which needs no assumption, but the read-back rate for what still spills is taken to hold. The arithmetic itself is no longer a model — remaining turns and prefix size are measured per spill rather than averaged, which is what moved the first pass's answer. Re-running the pairing is how to check the rate.

#### What that does to the three constants around it

Moving the dominant rung invalidated the calibration of the ones beside it, all three of which were set when a spill was a common event rather than a rare one.

**The preview goes from 150 B to 1 kB.** 150 B was right when it was paid 3824 times; at 32 spills the preview stops being a bulk cost and becomes the only thing standing between a pointer and a round trip. Priced over the surviving spills, 1 kB costs 1.18M tokens in total and **pays for itself by preventing 1.3 of the 21 read-backs — 6%**. That bar is written in the code so it can be checked: this is the one number here that is a bet rather than a measurement, because nothing in the transcripts can say whether a bigger head and tail would have answered the question when every one of them was written at 150 B.

**The ceiling goes from 2 kB to 16 kB.** It was the same one-sided arithmetic in the rung where it costs most. All 17 clips in the corpus cut a compressed result between 2 kB and 8 kB, none above 16 kB, and 8 were read back — where a clip is *worse* than a spill, because the file holds the raw original the compressor had already discarded most of. It hands back more bytes than it removed, one turn later, and it is the only rung here that destroys anything. At 16 kB it fires on nothing this corpus contains and goes back to being the runaway guard its own comment claims it is.

**`min_bytes` becomes 200 everywhere**, down from 400 at `safe` and `full`. What that floor gates is the ledger, and the ledger is the one rung with no round trip to be conservative about — a reference is read in place, never fetched. The 200–400 B band it excluded holds 1187 results here, 159 of them repeats: ~1.53M token-turns those levels were declining for no reason either could state.

Making the pointer cheap is still worth doing — a 150 B preview instead of 250 B (the *same* results spill, so it is free), a path cut from 123 B to ~72 B by hashing the session id and capping the slug, and the explanation said once per window rather than once per spill. But the floor is not simply what a pointer costs, which is the mistake that put it at 500 B: it is what a pointer costs **divided by how often the pointer is the last word**. At a 20% miss rate a 280 B pointer needs 1.4 kB of content behind it before it pays, and every earlier number in this section was computed as though the miss rate were 100%.

Only what no compressor claimed is offered to it. A compressed result is distilled signal — putting *that* behind a pointer would move the failures someone is about to read one tool call further away, while the bytes it replaced are already gone.

Behind the vault sits a hard 2 kB ceiling, and it is the one place here that cuts. It applies only to a rewrite that came out enormous anyway — raw output that big was spilled a rung earlier — which means it fires almost exclusively on compressed results, exactly the ones the vault declined. So it stores the original before it cuts: what left the context window is still on disk, at every rung without exception.

`safe` is not a vibe: `lossless?` is already a first-class idea here — grep regroups and keeps every line, everything else throws a backtrace or a banner away on purpose — so "only rewrites that discard nothing" is a guarantee the code can actually make.

## Benchmark

Measured on real outputs captured from a Rails 8 app (`bin/bench`), in five sections. The first two enforce invariants that fail the build; the rest are measurements, so a number here can be checked rather than believed.

### 1. Compressors

| Scenario | Chars | Tokens¹ | Reduction |
|---|---|---|---|
| rspec — 3 failures | 4610 → 966 | 1153 → 240 | **-79%** |
| rspec — 3 failures (ANSI) | 6233 → 969 | 1558 → 241 | **-84%** |
| rspec — all passing | 2558 → 149 | 640 → 36 | **-94%** |
| rubocop — 13 offenses | 2122 → 681 | 531 → 169 | **-68%** |
| rubocop — offenses (ANSI) | 2671 → 681 | 668 → 169 | **-75%** |
| rubocop — clean run | 80 | 20 | passthrough² |
| brakeman — 5 warnings | 3041 → 681 | 760 → 167 | **-78%** |
| brakeman — warnings (ANSI) | 3811 → 681 | 953 → 167 | **-82%** |
| brakeman — clean scan | 1922 → 116 | 481 → 28 | **-94%** |
| git show — vendored deps | 62600 → 2100 | 15642 → 515 | **-97%**³ |
| git show — no generated | 4886 → 318 | 1215 → 79 | **-93%**³ |
| cargo — 4 errors | 1513 → 879 | 378 → 218 | **-42%** |
| cargo — 4 errors (ANSI) | 2390 → 879 | 598 → 218 | **-63%** |
| cargo — 7 warnings | 1698 → 1070 | 425 → 267 | **-37%** |
| cargo — warnings (ANSI) | 2575 → 1070 | 644 → 267 | **-58%** |
| cargo — clean build | 120 | 30 | passthrough² |
| grep -rn — repeated paths | 3585 → 2144 | 896 → 534 | **-40%** |
| chain — rspec+rubocop+brakeman | 9775 → 2187 | 2444 → 543 | **-78%** |
| chain — cargo+rspec | 6124 → 1799 | 1531 → 448 | **-71%** |
| chain — one segment, two tools | 6733 → 1600 | 1683 → 399 | **-76%** |
| chain — hidden by quoting | 6733 → 1600 | 1683 → 399 | **-76%** |
| chain — rspec + plain diff | 9497 → 2188 | 2368 → 544 | **-77%** |
| rspec after a migration | 4737 → 1095 | 1184 → 272 | **-77%** |

¹ estimate (chars / 4); run `ANTHROPIC_API_KEY=... bin/bench` for exact counts via the `count_tokens` API.
² Untouched: small outputs are never rewritten.
³ The pointer did this, not the rung the table is about. Every number here is measured end to end at the default level, where anything no compressor claims goes to the vault whole and comes back as its two ends and a path — so a row marked ³ is one the compressors (or, in the ledger table, the ledger) declined outright. The reduction is real and nothing was destroyed, but crediting it to rung 7 or rung 2 would be reading the wrong rung's receipt. It is also why the two rows with **0 references** still shrink by 93% and 99%.

Cargo compresses less than the Ruby tools, and that is the correct outcome: rustc diagnostics are mostly signal already. What goes away is the ASCII art — the echoed source line, the caret runs, the suggestion diffs — while every `file:line:col` and every `note:`/`help:` stays. On colored output the win doubles, because escape sequences are a third of the bytes.

The last six rows are one shell line running several tools into one buffer — see [Chains](#chains).

### 2. Ledger

Simulated sessions, each one a sequence of tool calls against a single ledger. `References` is asserted, not reported — "it fired somewhere" is not a claim worth making.

| Simulated session | Calls | References | Bytes | Reduction |
|---|---|---|---|---|
| re-read the same file twice | 2 | 1 | 9220 → 4737 | **-49%** |
| re-read after working elsewhere | 4 | 1 | 14383 → 9901 | **-31%** |
| file changed by one byte in between | 2 | 0 | 9221 → 9221 | **-0%** |
| alternating between two files | 4 | 2 | 13464 → 6994 | **-48%** |
| same bytes under a different path | 2 | 1 | 9220 → 4739 | **-49%** |
| the agent runs `git status` four times | 4 | 3 | 19544 → 5456 | **-72%** |
| the same suite fails twice | 2 | 1 | 9220 → 1091 | **-88%**⁴ |
| an MCP result the agent asks for twice | 2 | 1 | 16900 → 8559 | **-49%** |
| a long session with four repeats | 10 | 4 | 88757 → 16681 | **-81%** |
| beyond the recency window | 3 | 0 | 71820 → 10460 | **-85%**³ |

⁴ The compressor did the first 4.6 kB → 966 B; the reference did the repeat, 966 B → 125 B. This row is the only one where the pointer stands in for a summary rather than for raw bytes, and it is the shape every repeated test run has.

These numbers moved a long way in 1.9.0 and none of the movement is the ledger: they are measured end to end at the default level, and the spill floor going 500 B → 16 kB in 1.5.0 stopped the vault from taking the leftovers each session ends with. The reference counts, which are what this section asserts, are unchanged.

### 3. Levels over the same corpus

| Mode | Rewrites | Bytes | Reduction | Refs | Sessions |
|---|---|---|---|---|---|
| `off` | 0/23 | 150014 → 150014 | -0% | 0 | -0% |
| `safe` | 1/23 | 150014 → 149007 | -1% | 13 | -21% |
| `full` | 20/23 | 150014 → 40431 | **-73%** | 13 | -21% |
| `ultra` | 20/23 | 150014 → 40431 | **-73%** | 13 | -21% |
| `volatile` | 21/23 | 150014 → 24053 | **-84%** | 13 | **-96%** |

`safe` scores -1% on the compressor corpus and -21% on the session corpus, which is the honest shape of it: almost all of its win is the ledger, because withholding bytes the model already has discards nothing by construction.

`volatile` is the default and the only row where the session corpus collapses — **-96%** against `full`'s -21% — because it is the only level that stops arguing about which bytes are redundant and puts the whole result on disk. That gap is the entire case for the vault being the default rather than an opt-in.

`full` and `ultra` tie here, and the bench says so rather than hiding it. The two differ at the byte floor (200–400 B) and at the margin a lossy rewrite has to clear, and **no fixture lands in that band** — fixtures are chosen to be interesting, and an interesting output is a long one. A real session is where `ultra` pays, and `/lean` is what says whether it did.

### 4. Recency window

One synthetic session whose five repeats sit at growing distances, replayed once per candidate window.

| Window | References found | Repeats available | Bytes withheld |
|---|---|---|---|
| 5 kB | 0 | 5 | 0 |
| 10 kB | 1 | 5 | 4385 |
| 25 kB | 3 | 5 | 13155 |
| 50 kB | 3 | 5 | 13155 |
| 100 kB | 4 | 5 | 17540 |
| 250 kB | 5 | 5 | 21923 |
| 500 kB | 5 | 5 | 21923 |

The curve flattens by 250 kB, which is where the default sits: past that point a wider window buys no more references and only lengthens the reach of a pointer a compaction could strand.

### 5. What the receipt costs

21 rewrites carry **788 bytes** of footer against **125,961 bytes** saved — 0.63% of the win. Naming what each one discarded adds **1186 bytes** on top: 0.94% of the win, and 151% on top of the receipt itself. It also cost the headline rspec number a point, from -80% to -79%. That is the trade, priced: a summary that says only how much smaller it got asks to be trusted, one that names what is gone can be checked.

### Invariants

`bin/bench` fails the build on any of these:

1. **Zero loss, at every level** — every failure/offense `file:line`, every rustc `--> file:line:col`, every changed file path and every grep hit in the original must appear in the compressed output. The file and the line are checked *apart*, not as one glued string: moving the path up into a header is allowed, losing either half is not. Checked under `safe`, `full` and `ultra`, because a level that saves more by losing one is not a level, it is a different product. `volatile` is exempt by construction and is the exception that states the rule: it is a different product, which is why it announces every clip and why every clip stores the original first.
2. **Nothing unclaimed disappears** — text no compressor recognised must come back byte for byte, so a migration that ran before the suite, or a diff with nothing to collapse, survives intact.
3. **No vacuous passes** — a fixture that is supposed to contain failures must actually yield locations to the extractor. Without this, a broken extractor would make invariant 1 pass trivially.
4. **Negative corpus** — ten inputs that must come back *untouched*: libtest results, `--message-format=json`, `-f json`, nested and multiline JSON values, a grep hit list where no path repeats, output below the line threshold, a first-sighting Read, a Read too small to be worth a pointer, and a tool with no rung at all.
5. **The ledger references exactly what it should** — ten simulated sessions with an asserted reference count each, and `off` must produce none. A reference must also be strictly smaller than *what it replaces*, which is not always the raw output: where a compressor claimed the first occurrence, the alternative to the pointer is that summary, so the check is against the earlier delivery and not against the bytes that arrived.
6. **No silent loss** — a rewrite that discards something must name what.
7. **The window curve climbs** — a wider window can only ever reach further back, and can never find more references than there are repeats.

Diffs are where the numbers get absurd, because a single vendored dependency dwarfs everything a reviewer actually reads. The full commit the fixture above was sliced from (a CodeMirror 6 vendoring: 29 files, 233 hand-written insertions) goes from **651,833 B to 13,247 B — -97%**, roughly **163k tokens down to 3.3k**. Uncompressed it does not fit in a review at all.

## Install

```
/plugin marketplace add wasdevv/lean-output
/plugin install lean-output@lean-output
```

Requires Ruby ≥ 3.0 on your PATH. The hook runs on pure stdlib — no gems, no Bundler, no measurable startup cost.

## How it works

Hooks on `PostToolUse` **and** `PostToolUseFailure` intercept every Bash tool result — the failure event matters most, since a failing suite exits nonzero and never reaches `PostToolUse`. A detector matches the command (`rspec` / `rubocop` / `brakeman` / `git diff|show` / `cargo` / `grep|rg`) **and** sniffs the output for the tool's summary line — both must agree, otherwise nothing happens. When a compressor applies:

- **RSpec** — keeps the summary, every failure (description, `Failure/Error` source, expectation/exception message, first project frame, rerun location). Drops dots, seeds, profiling, coverage noise, gem/support frames and diff blocks.
- **RuboCop** — keeps the summary and every offense location, grouped by file and deduped by cop/message (`3:1, 7:2, 9:5 Layout/TrailingWhitespace: ...`). Drops code excerpts, carets and progress output.
- **Brakeman** — keeps the warning count and every warning (line, confidence, category, message, vulnerable code) grouped by file. Drops the progress log, the ~1kB "Checks Run" list and the report boilerplate.
- **git diff / git show** — passes every hand-written hunk through **byte for byte**, and collapses the body of generated files to one line (`[lean-output] generated file — +12/-3 lines, body collapsed`), keeping their `diff --git` header so nothing disappears silently. Collapsed: `vendor/`, `node_modules/`, `dist/`, `coverage/`, `app/assets/builds/`, lockfiles (`Gemfile.lock`, `Cargo.lock`, `package-lock.json`, `yarn.lock`, `go.sum`, …), `db/structure.sql`, `*.min.js|css` and source maps. **`db/schema.rb` is deliberately not collapsed** — it is how a Rails reviewer sees what a migration actually did.
- **grep / rg** — factors the repeated path out of a hit list: `app/services/agents/claude_code.rb:9:…` forty times becomes the path once, then `9: …` indented under it. Every line number and every matched line survives, and the `--` context separators and `grep: dir: Is a directory` notes stay where they were. Refuses a list where no path repeats, because a header per file would make the buffer *bigger*.
- **cargo** (`build`, `check`, `clippy`, `test`, `run`) — keeps the diagnostic count, and for each one the `error[CODE]`/`warning` header, its `--> file:line:col`, the caret labels (the text that explains *why*, e.g. `expected i32, found &str`) and every `note:`/`help:`. Drops the echoed source lines, the caret art itself, suggestion diffs and `Compiling`/`Finished` progress. Refuses to touch output that carries **libtest results** (`running N tests`, `test result:`) or a successful `cargo run`, because panic sites and program stdout are not rustc art and cannot be rebuilt.

## Chains

`bundle exec rspec && bundle exec rubocop && bin/brakeman -q` is one tool call and one buffer. So is `bin/rails db:migrate && bundle exec rspec`, where half the output belongs to no compressor at all.

Nothing here parses the command to work out where one tool stopped and the next began — quoting, wrapper scripts and `bash -c` make that a guess, and a wrong guess is silent data loss. Instead each compressor declares the lines only it writes, and from those claims a **span**: first recognised line to last, everything between included. It summarises that slice and nothing else; the rest of the buffer is spliced back untouched. Two spans that overlap is the one case with no honest answer — the tools disagree about who wrote those bytes — and it ends in passthrough.

The consequence is that a tool with nothing to say costs the buffer nothing. A `git diff` with no generated files to collapse used to force the whole chain to pass through; now it simply comes back verbatim beside a summarised rspec run.

Replayed over 301 real Bash results from local Claude Code transcripts: **-38% overall, and not one line outside a span went missing.** The whole-buffer rewrite this replaced scored -88% on the same corpus, but 138 of those results had silently deleted output the model never learned about.

The rule costs something, and it is worth naming. `rubocop --force-exclusion $(… | grep '\.rb$')` names grep in a subshell that only picks filenames and never writes to the buffer — but RuboCop's `file:line:col:` offenses have the exact shape of a grep hit, so both compressors claim, the spans overlap, and the buffer passes through. Measured over the corpus that is **one result in 249**. Letting the wider span win would recover it and would be right here, but it trades a rule for a heuristic, and the rule is what makes this predictable.

## What a rewrite has to be worth

A rewrite is only swapped in when it saves at least 30% — below that it isn't worth the risk of having thrown away the line the reader needed. Except that floor is really two charges in one: the footer has to pay for itself, *and* the saving has to be worth that risk.

Only the first applies to a compressor that discards nothing. Grep's regrouping keeps every line number and every matched line; there is no context to have lost. So a compressor declares whether it is lossless, and a lossless one clears **15%** instead of 30%. On the corpus, charging grep the full risk premium threw away 33 kB across 36 results that had discarded nothing to be suspicious of.

## Use it as a library

The hook is one caller. Anything that injects tool output into a prompt has the same problem and usually solves it with `byteslice`, which amputates whatever sits at the cut — typically the failure message the reader needed. `LeanOutput.compress` is the same engine behind a plain API:

```ruby
LeanOutput.compress(text, command: nil, budget: nil, footer: false) # => String
```

```ruby
gem "lean_output", github: "wasdevv/lean-output"
```

```ruby
# an agent orchestrator briefing a retry, instead of stdout.byteslice(0, 8_000)
LeanOutput.compress(stdout, command: "bundle exec rspec", budget: 8_000)
```

- **Always a String.** Passthrough returns the input itself; an unexpected error degrades to the input rather than raising. It drops in wherever you used to truncate.
- **`command` is optional.** Without it the text alone has to identify the tools, and each still only rewrites the span it recognises. Cargo never self-identifies — telling a rustc diagnostic from a successful `cargo run` followed by program stdout needs the subcommand.
- **`budget` is a byte ceiling spent on whole entries.** Compressed output is a summary plus blank-line-separated entries (one failure, one file's offenses, one diagnostic), so it keeps the summary and as many whole entries as fit, then says `[lean-output] 12 of 19 entries omitted (budget 8.0kB)`. For text no compressor understands it keeps both ends — the invocation and early errors at the head, the summary and exit status at the tail — and drops only the middle.
- **No line-count floor.** The hook's 40-line minimum and 30% minimum saving are policy in `Runner`; a caller asking for compression has already decided the text is too long.

Same thing from a shell, for callers that aren't Ruby:

```sh
bundle exec rspec 2>&1 | lean-output --command "bundle exec rspec" --budget 8000
```

Head to head on the fixture in this repo, against a 40-line tail — the shape most orchestrators reach for:

| | bytes | failure messages kept |
|---|---|---|
| original | 4610 | 3 of 3 |
| `lines.last(40)` | 1979 | **0 of 3** |
| `LeanOutput.compress` | 877 | 3 of 3 |

The tail keeps the profiling table and the coverage report and drops the entire `Failures:` section — the reader learns *which* specs failed, never *why*.

## Fail-safe by design

Compression is only worth it if it can never hurt you:

- **Passthrough on any doubt** — unrecognized format, output under 40 lines, missing summary (truncated output), `--format json` already in use, two compressors claiming the same bytes: the original output stays untouched.
- **Failures are sacred** — every failing example and its `file:line` survives compression, always.
- **Nothing is dropped in silence** — a compressor rewrites only the span it recognises; whatever else shared the buffer comes back byte for byte.
- **Errors can't break your session** — any exception inside the hook exits 0 silently.
- **Kill-switch** — `LEAN_OUTPUT_DISABLE=1` turns it off without uninstalling, and `/lean off` does the same for one directory.
- **A reference can't be wrong about the bytes** — the ledger matches on a digest of the whole result, so a file that changed by one byte is sent again in full.
- Only rewrites when it saves at least 30% — 15% when it discards nothing — and the footer names what went:

  ```text
  [lean-output] 4.5kB → 0.9kB (-80%) — dropped: passing examples, gem backtrace frames
  ```

  A receipt that says only how much smaller it got asks to be trusted; one that names what is gone lets you notice when it was the thing you needed. Section 5 of the benchmark prices that: 1.02% of the win.

## Development

```sh
bundle install
bundle exec rspec   # golden tests over real captured fixtures — no mocks
bin/bench           # five sections, seven build-failing invariants
```

`bin/bench` measures compressors, the ledger over simulated sessions, all four levels over the same corpus, the recency-window sensitivity curve, and what the footer costs. It runs against a throwaway state directory, so a benchmark can never reference bytes from your own session.

Set `LEAN_OUTPUT_DEBUG=/some/file` to log every payload and compress/passthrough decision — including the `PreCompact` event, which logs as a payload with no `tool_name` and no rewrite. `LEAN_OUTPUT_STATE_DIR` moves the ledger, `LEAN_OUTPUT_WINDOW` overrides how far back a reference may point, `LEAN_OUTPUT_MODE` pins the level above the per-directory flag, `LEAN_OUTPUT_COMPACT_AT` turns on auto-compaction at a context percentage, `LEAN_OUTPUT_CALL_FLOOR` moves the size above which a call's body goes to the vault.

Troubleshooting: if the hook never fires, check that your project is trusted and that `.claude/settings*.json` files are valid — Claude Code silently disables hooks for untrusted projects and skips settings files that fail validation.

---

## Em português

**Plugin de Claude Code que comprime saídas de RSpec, RuboCop, Brakeman, `git diff` e `cargo` antes de chegarem ao modelo — menos tokens, nenhuma falha perdida.**

Saídas de suite de teste são verbosas: dots de progresso, seed, tabelas de profiling, relatório do SimpleCov, backtraces de gems. O lean-output reescreve essas saídas via hooks `PostToolUse`/`PostToolUseFailure`, preservando **toda falha, mensagem e `file:line`** e descartando o resto. Em sessão real no pipeline_hq (CRM Rails 8): suite de 103 exemplos com 1 falha foi de **3.2kB para 346B (-90%)** — e o modelo ainda apontou o `file:line` exato da falha. No benchmark: **79–94%** em RSpec, **68–75%** em RuboCop e **78–94%** em Brakeman (tabela acima).

**A reescrita mais barata é a que não acontece.** Antes de qualquer compressor rodar, o resultado é conferido contra o que a sessão já mostrou ao modelo: `git status` rodado quatro vezes manda os mesmos bytes quatro vezes, e um arquivo lido no começo da task e relido no fim vai duas. Repetição volta como ponteiro (`byte-identical to Read app/… from 6 tool calls back — 8.3kB, 214 lines withheld`) mais as duas primeiras linhas, que existem pro caso de uma compactação de contexto ter apagado a ocorrência original. O match é por digest do resultado inteiro — um byte diferente e o arquivo vai completo de novo. **São três formas de ponteiro, e cada uma diz só o que é verdade**: o original inteiro está no contexto (`214 lines withheld`), está num arquivo do vault (`full text at …`), ou um compressor pegou o resultado e o que o modelo tem é o resumo (`its 966B summary is already above, not repeated`). O terceiro caso é a suíte que falha de novo: 4,6 kB viram 966 B na primeira rodada e 125 B em toda repetição, medido ponta a ponta. **A janela de recência é medida em bytes de saída que passaram, não em número de chamadas** (padrão 250 kB): quarenta leituras de um arquivo de 200 linhas e quarenta `git status` empurram quantidades muito diferentes de histórico pra fora. Nas sessões simuladas do bench isso vale de **-12% a -84%**, e é a única coisa que alcança o `Read`, onde não há ruído pra nenhum compressor tirar.

**Níveis**: `/lean` mostra o nível atual e o quanto já economizou; `/lean safe` troca. `off` não toca em nada, `safe` só aceita reescrita que não descarta nada (mais o ledger), `full` roda os compressores nos pisos medidos, `ultra` baixa o piso e aceita ganho menor, e `volatile` — **o padrão** — liga o **vault**: o que passa de 16 kB e nenhum compressor reclamou vai pra um arquivo e volta como as duas pontas mais o caminho exato, e o meio fica a um `Read` de distância. No corpus real: `full` e `ultra` dão -6%, `volatile` dá **-13%** na entrega — número pequeno de propósito: seguir um ponteiro custa um turno, e um turno relê 121.849 tokens de prefixo, então o vault só paga em resultado realmente enorme. O padrão é o agressivo porque **um byte não é pago uma vez**: 94,7% da conta de tokens é cache read (o prefixo relido a cada turno) e uma sessão tem 225 turnos em média, então um resultado admitido na janela é pago uma vez por turno restante — 27% da conta inteira é tool output carregado. O nível é gravado por diretório de trabalho e lido a cada chamada — não precisa reiniciar nada.

O compressor de diff é o que mais economiza, porque uma dependência vendorada sozinha é maior que tudo que um revisor de fato lê. Hunk escrito à mão passa **byte a byte**; corpo de arquivo gerado (`vendor/`, lockfile, `app/assets/builds/`, `*.min.js`, source map) vira uma linha que ainda mostra o caminho e o `+N/-M`. Num commit real de vendoring do CodeMirror 6: **651.833 B → 13.247 B (-97%)**, de ~163k para ~3,3k tokens. `db/schema.rb` fica de fora de propósito — é o arquivo que mostra o que a migration realmente fez.

Instalação:

```
/plugin marketplace add wasdevv/lean-output
/plugin install lean-output@lean-output
```

Para Rust, o compressor de `cargo` guarda o cabeçalho de cada diagnóstico, o `--> file:line:col`, os rótulos que explicam o erro e os `note:`/`help:` — joga fora a arte ASCII (linha de código ecoada, carets, sugestões) e as linhas de progresso. Ele se **recusa** a mexer em saída com resultado de libtest (`running N tests`, `test result:`) ou em `cargo run` que compilou: panic e stdout do programa não são arte do rustc e não podem ser reconstruídos.

Princípios: em qualquer dúvida, passthrough (a saída original fica intacta); falhas e `file:line` nunca são perdidos (o `bin/bench` falha se isso acontecer — em `safe`, `full` **e** `ultra`, porque nível que economiza mais perdendo alguma coisa não é nível, é outro produto); nada some calado — o rodapé nomeia o que foi descartado (`— dropped: passing examples, gem backtrace frames`), e isso custa 1,02% do ganho; qualquer erro no hook sai silenciosamente sem quebrar a sessão; `LEAN_OUTPUT_DISABLE=1` (ou `/lean off`) desliga tudo.

Contribuições são bem-vindas — especialmente novos compressores do ecossistema Ruby/Rails (Minitest, `rails db:migrate`, backtraces genéricos...).

## License

MIT
