# Agent harness

The harness runs a level as a sandboxed agent session. The agent receives a
generated `RULES.md` and a `play` command. The supervisor owns the pack files,
reference solution, scoring, and attempt budgets.

## Public examples

From the repository root:

```bash
python tools/benchmark/harness/sweep.py \
    --packs-dir packs --out tmp/run \
    --agent baseline

python tools/benchmark/harness/report.py \
    tmp/run/results.json -o tmp/run/report.pdf
```

For a hosted agent, configure its credentials locally and select `--agent` and
`--model` explicitly. A single public example can be run with:

```bash
python tools/benchmark/harness/supervisor.py \
    --pack carrot_quest --level fw_001 --packs-dir packs \
    --sandbox tmp/sbx --result tmp/sbx.json \
    --agent claude --model haiku --max-attempts 3
```

Generated transcripts, sandboxes, and reports are local artifacts. Review an
explicit export before sharing it; anonymous gameplay labels do not sanitize
the source identifiers or content in a saved transcript.

## Agent interface

```text
./play state
./play move '<json>'
./play history
./play give_up
```

`play` exits with 0 normally, 3 when the run is over, and 2 on a transport error.
Schema-invalid and state-illegal actions have separate counters and limits.
Rejected actions do not consume accepted-action budgets. An accepted action
can consume a turn even when it leaves the board unchanged.

## Isolation

The default `bwrap` isolation exposes system dependencies and the sandbox but
does not mount pack or solution files. The supervisor checks that the pack
cannot be reached from inside the sandbox before a scored run. Docker isolation
is also supported; see `harness.yaml` for its resource and network settings.
`none` is a debugging mode with no filesystem boundary, so its scores are
unverified.

The supervisor refuses to evaluate a pack that declares an unsupported system.
Keep credentials and local provider configuration outside release artifacts.

## Budgets and outcomes

`max_attempts` limits gameplay attempts. With `full_attempts`, each attempt has
the level's declared allowance; otherwise attempts share a reference-based
budget. `timeout: 0` imposes no wall-clock limit. Timed-out sessions are recorded
as incomplete rather than interpreted as puzzle difficulty.

`narrate` requests a short explanation before commands. It changes the agent
protocol and is recorded with the run. `thinking_tokens` configures the
selected CLI when supported; separate reasoning streams may not appear in a
transcript.

Scoring compares accepted actions with validated references and records
attempts, losses, rejection categories, and resource usage separately. A
reference path is not necessarily a proven optimum.

## Tests

The unit tests under `tests/` cover protocol parsing, rules, scoring, agent
configuration, and the play client. Corpus-specific regression inventories
belong alongside their separately supplied packs.
