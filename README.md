# lean-output

**A Claude Code plugin that compresses RSpec, RuboCop, Brakeman, `git diff`, cargo and `grep` outputs before they reach the model — fewer tokens, zero lost failures.**

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

**How far back a reference may point is measured in tool-output bytes that have gone by, not in tool calls** — forty Reads of a 200-line file and forty `git status` runs push very different amounts of history out of the window. The default is 250 kB, roughly 60k tokens; `bin/bench` prints the sensitivity curve and `LEAN_OUTPUT_WINDOW` overrides it.

## Levels

`/lean` shows the current level and what it has saved; `/lean safe` switches. The level is written per working directory and read fresh on every tool call, so nothing needs restarting.

| Level | What it does |
|---|---|
| `off` | Every result reaches the model untouched. Same as `LEAN_OUTPUT_DISABLE=1`, but scoped to this directory. |
| `safe` | Only rewrites that discard nothing, plus the ledger. For the afternoon you suspect a compressor ate the line you needed. |
| `full` | Compressors and the ledger, at the measured floors. |
| `ultra` | A lower byte floor and a thinner margin — more rewrites, smaller wins each. |
| `volatile` | Default. `ultra` plus the vault: anything over 800 B that no compressor claimed goes to a file and comes back as its two ends and a path. **-69%** on a real corpus. |

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

The case is the shape of the corpus, not the shape of an output: over 8901 real results the largest 10% of calls hold **50.1%** of all the bytes, and the median result is 1261 B. A compressor works the part of the distribution where there is nothing to win. Measured end to end on that corpus, `full` and `ultra` land at **-6%** and `volatile` at **-69%**. The model would have to read back **77%** of everything spilled before that win is gone.

Only what no compressor claimed is offered to it. A compressed result is distilled signal — putting *that* behind a pointer would move the failures someone is about to read one tool call further away, while the bytes it replaced are already gone.

Behind the vault sits a hard 4 kB ceiling, and it is the one place here that cuts. It applies only to a rewrite that came out enormous anyway — raw output that big was spilled a rung earlier — which means it fires almost exclusively on compressed results, exactly the ones the vault declined. So it stores the original before it cuts: what left the context window is still on disk, at every rung without exception.

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
| git show — vendored deps | 62600 → 9738 | 15642 → 2425 | **-84%** |
| git show — no generated | 4886 | 1215 | passthrough² |
| cargo — 4 errors | 1513 → 879 | 378 → 218 | **-42%** |
| cargo — 4 errors (ANSI) | 2390 → 879 | 598 → 218 | **-63%** |
| cargo — 7 warnings | 1698 → 1070 | 425 → 267 | **-37%** |
| cargo — warnings (ANSI) | 2575 → 1070 | 644 → 267 | **-58%** |
| cargo — clean build | 120 | 30 | passthrough² |
| grep -rn — repeated paths | 3585 → 2578 | 896 → 644 | **-28%** |
| mcp query — 40 rows | 8450 → 2548 | 2113 → 636 | **-70%** |
| mcp query — enveloped | 9205 → 2548 | 2301 → 636 | **-72%** |
| chain — rspec+rubocop+brakeman | 9775 → 2233 | 2444 → 554 | **-77%** |
| chain — cargo+rspec | 6124 → 1799 | 1531 → 448 | **-71%** |
| chain — one segment, two tools | 6733 → 1600 | 1683 → 399 | **-76%** |
| chain — hidden by quoting | 6733 → 1600 | 1683 → 399 | **-76%** |
| chain — rspec + plain diff | 9497 → 5880 | 2368 → 1462 | **-38%** |
| rspec after a migration | 4737 → 1095 | 1184 → 272 | **-77%** |

¹ estimate (chars / 4); run `ANTHROPIC_API_KEY=... bin/bench` for exact counts via the `count_tokens` API.
² Untouched: small outputs are never rewritten.

Cargo compresses less than the Ruby tools, and that is the correct outcome: rustc diagnostics are mostly signal already. What goes away is the ASCII art — the echoed source line, the caret runs, the suggestion diffs — while every `file:line:col` and every `note:`/`help:` stays. On colored output the win doubles, because escape sequences are a third of the bytes.

The last six rows are one shell line running several tools into one buffer — see [Chains](#chains).

### 2. Ledger

Simulated sessions, each one a sequence of tool calls against a single ledger. `References` is asserted, not reported — "it fired somewhere" is not a claim worth making.

| Simulated session | Calls | References | Bytes | Reduction |
|---|---|---|---|---|
| re-read the same file twice | 2 | 1 | 9220 → 4737 | **-49%** |
| re-read after working elsewhere | 4 | 1 | 14383 → 9901 | **-31%** |
| file changed by one byte in between | 2 | 0 | 9221 → 9221 | -0% |
| alternating between two files | 4 | 2 | 13464 → 6994 | **-48%** |
| same bytes under a different path | 2 | 1 | 9220 → 4739 | **-49%** |
| the agent runs `git status` four times | 4 | 3 | 19544 → 5456 | **-72%** |
| an MCP result the agent asks for twice | 2 | 1 | 16900 → 2657 | **-84%** |
| a long session with four repeats | 10 | 4 | 88757 → 78041 | **-12%** |
| beyond the recency window | 3 | 0 | 71820 → 71820 | -0% |

### 3. Levels over the same corpus

| Mode | Rewrites | Bytes | Reduction | Refs | Sessions |
|---|---|---|---|---|---|
| `off` | 0/25 | 167669 → 167669 | -0% | 0 | -0% |
| `safe` | 1/25 | 167669 → 166662 | -1% | 13 | -21% |
| `full` | 22/25 | 167669 → 45527 | **-73%** | 13 | **-23%** |
| `ultra` | 22/25 | 167669 → 45527 | **-73%** | 13 | **-23%** |

`safe` scores -1% on the compressor corpus and -21% on the session corpus, which is the honest shape of it: almost all of its win is the ledger, because withholding bytes the model already has discards nothing by construction.

`full` and `ultra` tie here, and the bench says so rather than hiding it. The two differ at the byte floor (200–400 B) and at the margin a lossy rewrite has to clear, and **no fixture lands in that band** — fixtures are chosen to be interesting, and an interesting output is a long one. A real session is where `ultra` pays, and `/lean` is what says whether it did.

### 4. Recency window

One synthetic session whose five repeats sit at growing distances, replayed once per candidate window.

| Window | References found | Repeats available | Bytes withheld |
|---|---|---|---|
| 5 kB | 0 | 5 | 0 |
| 10 kB | 1 | 5 | 4491 |
| 25 kB | 3 | 5 | 13473 |
| 50 kB | 3 | 5 | 13473 |
| 100 kB | 4 | 5 | 17964 |
| 250 kB | 5 | 5 | 22454 |
| 500 kB | 5 | 5 | 22454 |

The curve flattens by 250 kB, which is where the default sits: past that point a wider window buys no more references and only lengthens the reach of a pointer a compaction could strand.

### 5. What the receipt costs

22 rewrites carry **827 bytes** of footer against **122,142 bytes** saved — 0.68% of the win. Naming what each one discarded adds **1244 bytes** on top: 1.02% of the win, and 150% on top of the receipt itself. It also cost the headline rspec number a point, from -80% to -79%. That is the trade, priced: a summary that says only how much smaller it got asks to be trusted, one that names what is gone can be checked.

### Invariants

`bin/bench` fails the build on any of these:

1. **Zero loss, at every level** — every failure/offense `file:line`, every rustc `--> file:line:col`, every changed file path and every grep hit in the original must appear in the compressed output. The file and the line are checked *apart*, not as one glued string: moving the path up into a header is allowed, losing either half is not. Checked under `safe`, `full` and `ultra`, because a level that saves more by losing one is not a level, it is a different product. `volatile` is exempt by construction and is the exception that states the rule: it is a different product, which is why it announces every clip and why every clip stores the original first.
2. **Nothing unclaimed disappears** — text no compressor recognised must come back byte for byte, so a migration that ran before the suite, or a diff with nothing to collapse, survives intact.
3. **No vacuous passes** — a fixture that is supposed to contain failures must actually yield locations to the extractor. Without this, a broken extractor would make invariant 1 pass trivially.
4. **Negative corpus** — ten inputs that must come back *untouched*: libtest results, `--message-format=json`, `-f json`, nested and multiline JSON values, a grep hit list where no path repeats, output below the line threshold, a first-sighting Read, a Read too small to be worth a pointer, and a tool with no rung at all.
5. **The ledger references exactly what it should** — nine simulated sessions with an asserted reference count each. A reference must also be strictly smaller than what it replaces, and `off` must produce none.
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

Set `LEAN_OUTPUT_DEBUG=/some/file` to log every payload and compress/passthrough decision. `LEAN_OUTPUT_STATE_DIR` moves the ledger, `LEAN_OUTPUT_WINDOW` overrides how far back a reference may point, `LEAN_OUTPUT_MODE` pins the level above the per-directory flag.

Troubleshooting: if the hook never fires, check that your project is trusted and that `.claude/settings*.json` files are valid — Claude Code silently disables hooks for untrusted projects and skips settings files that fail validation.

---

## Em português

**Plugin de Claude Code que comprime saídas de RSpec, RuboCop, Brakeman, `git diff` e `cargo` antes de chegarem ao modelo — menos tokens, nenhuma falha perdida.**

Saídas de suite de teste são verbosas: dots de progresso, seed, tabelas de profiling, relatório do SimpleCov, backtraces de gems. O lean-output reescreve essas saídas via hooks `PostToolUse`/`PostToolUseFailure`, preservando **toda falha, mensagem e `file:line`** e descartando o resto. Em sessão real no pipeline_hq (CRM Rails 8): suite de 103 exemplos com 1 falha foi de **3.2kB para 346B (-90%)** — e o modelo ainda apontou o `file:line` exato da falha. No benchmark: **79–94%** em RSpec, **68–75%** em RuboCop e **78–94%** em Brakeman (tabela acima).

**A reescrita mais barata é a que não acontece.** Antes de qualquer compressor rodar, o resultado é conferido contra o que a sessão já mostrou ao modelo: `git status` rodado quatro vezes manda os mesmos bytes quatro vezes, e um arquivo lido no começo da task e relido no fim vai duas. Repetição volta como ponteiro (`byte-identical to Read app/… from 6 tool calls back — 8.3kB, 214 lines withheld`) mais as duas primeiras linhas, que existem pro caso de uma compactação de contexto ter apagado a ocorrência original. O match é por digest do resultado inteiro — um byte diferente e o arquivo vai completo de novo. **A janela de recência é medida em bytes de saída que passaram, não em número de chamadas** (padrão 250 kB): quarenta leituras de um arquivo de 200 linhas e quarenta `git status` empurram quantidades muito diferentes de histórico pra fora. Nas sessões simuladas do bench isso vale de **-12% a -84%**, e é a única coisa que alcança o `Read`, onde não há ruído pra nenhum compressor tirar.

**Níveis**: `/lean` mostra o nível atual e o quanto já economizou; `/lean safe` troca. `off` não toca em nada, `safe` só aceita reescrita que não descarta nada (mais o ledger), `full` roda os compressores nos pisos medidos, `ultra` baixa o piso e aceita ganho menor, e `volatile` — **o padrão** — liga o **vault**: o que passa de 800 B e nenhum compressor reclamou vai pra um arquivo e volta como as duas pontas mais o caminho exato, e o meio fica a um `Read` de distância. No corpus real: `full` e `ultra` dão -6%, `volatile` dá **-69%**. O padrão é o agressivo porque **um byte não é pago uma vez**: 94,7% da conta de tokens é cache read (o prefixo relido a cada turno) e uma sessão tem 225 turnos em média, então um resultado admitido na janela é pago uma vez por turno restante — 27% da conta inteira é tool output carregado. O nível é gravado por diretório de trabalho e lido a cada chamada — não precisa reiniciar nada.

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
