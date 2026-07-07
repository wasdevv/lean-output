# lean-output

**A Claude Code plugin that compresses RSpec and RuboCop outputs before they reach the model — fewer tokens, zero lost failures.**

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

## Benchmark

Measured on real outputs captured from a Rails 8 app (`bin/bench`):

| Scenario | Chars | Tokens¹ | Reduction |
|---|---|---|---|
| rspec — 3 failures | 4610 → 914 | 1153 → 228 | **-80%** |
| rspec — 3 failures (ANSI) | 6233 → 917 | 1558 → 228 | **-85%** |
| rspec — all passing | 2558 → 97 | 640 → 23 | **-96%** |
| rubocop — 13 offenses | 2122 → 631 | 531 → 157 | **-70%** |
| rubocop — offenses (ANSI) | 2671 → 631 | 668 → 157 | **-76%** |
| rubocop — clean run | 80 | 20 | passthrough² |

¹ estimate (chars / 4); run `ANTHROPIC_API_KEY=... bin/bench` for exact counts via the `count_tokens` API.
² Untouched: small outputs are never rewritten.

The benchmark also enforces a **zero-loss guarantee**: it fails if any failure/offense `file:line` from the original output is missing from the compressed version.

## Install

```
/plugin marketplace add wasdevv/lean-output
/plugin install lean-output@lean-output
```

Requires Ruby ≥ 3.0 on your PATH. The hook runs on pure stdlib — no gems, no Bundler, no measurable startup cost.

## How it works

Hooks on `PostToolUse` **and** `PostToolUseFailure` intercept every Bash tool result — the failure event matters most, since a failing suite exits nonzero and never reaches `PostToolUse`. A detector matches the command (`rspec` / `rubocop`) **and** sniffs the output for the tool's summary line — both must agree, otherwise nothing happens. When a compressor applies:

- **RSpec** — keeps the summary, every failure (description, `Failure/Error` source, expectation/exception message, first project frame, rerun location). Drops dots, seeds, profiling, coverage noise, gem/support frames and diff blocks.
- **RuboCop** — keeps the summary and every offense location, grouped by file and deduped by cop/message (`3:1, 7:2, 9:5 Layout/TrailingWhitespace: ...`). Drops code excerpts, carets and progress output.

## Fail-safe by design

Compression is only worth it if it can never hurt you:

- **Passthrough on any doubt** — unrecognized format, output under 40 lines, missing summary (truncated output), `--format json` already in use, ambiguous chained commands: the original output stays untouched.
- **Failures are sacred** — every failing example and its `file:line` survives compression, always.
- **Errors can't break your session** — any exception inside the hook exits 0 silently.
- **Kill-switch** — `LEAN_OUTPUT_DISABLE=1` turns it off without uninstalling.
- Only rewrites when it saves at least 30%; a footer (`[lean-output] 4.5kB → 0.9kB (-80%)`) always tells the model — and you — that compression happened.

## Development

```sh
bundle install
bundle exec rspec   # golden tests over real captured fixtures — no mocks
bin/bench           # savings table + zero-loss check
```

Set `LEAN_OUTPUT_DEBUG=/some/file` to log every payload and compress/passthrough decision.

Troubleshooting: if the hook never fires, check that your project is trusted and that `.claude/settings*.json` files are valid — Claude Code silently disables hooks for untrusted projects and skips settings files that fail validation.

---

## Em português

**Plugin de Claude Code que comprime saídas de RSpec e RuboCop antes de chegarem ao modelo — menos tokens, nenhuma falha perdida.**

Saídas de suite de teste são verbosas: dots de progresso, seed, tabelas de profiling, relatório do SimpleCov, backtraces de gems. O lean-output reescreve essas saídas via hooks `PostToolUse`/`PostToolUseFailure`, preservando **toda falha, mensagem e `file:line`** e descartando o resto. Em sessão real no pipeline_hq (CRM Rails 8): suite de 103 exemplos com 1 falha foi de **3.2kB para 346B (-90%)** — e o modelo ainda apontou o `file:line` exato da falha. No benchmark: **80–96%** em RSpec e **70–76%** em RuboCop (tabela acima).

Instalação:

```
/plugin marketplace add wasdevv/lean-output
/plugin install lean-output@lean-output
```

Princípios: em qualquer dúvida, passthrough (a saída original fica intacta); falhas e `file:line` nunca são perdidos (o `bin/bench` falha se isso acontecer); qualquer erro no hook sai silenciosamente sem quebrar a sessão; `LEAN_OUTPUT_DISABLE=1` desliga tudo.

Contribuições são bem-vindas — especialmente novos compressores do ecossistema Ruby/Rails (Minitest, Brakeman, `rails db:migrate`...).

## License

MIT
