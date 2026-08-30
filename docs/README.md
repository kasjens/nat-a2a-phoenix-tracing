# Notes on NeMo Agent Toolkit 1.8.0

Things we learned building this demo that were not obvious from the documentation, and that cost
real time to work out. Written down so the next person does not pay for them twice.

Everything here is against **`nvidia-nat` 1.8.0**, which was the latest release in August 2026. Line
numbers refer to files under `.venv/Lib/site-packages/` in this repo's virtualenv. They will drift
in later versions; the symptoms and the reasoning should survive longer than the line numbers.

| Document | What is in it |
|---|---|
| [agents-and-config.md](agents-and-config.md) | Composing agents, function groups, why `a2a_client` cannot be used by a `react_agent`, tool budgets, getting a callee to search twice before giving up, what an A2A error response throws away |
| [tracing.md](tracing.md) | What Phoenix does and does not show, getting LLM spans and token counts at all, span naming, and assembling one tree across a process boundary |
| [models.md](models.md) | Which models can actually drive a ReAct agent, and how the ones that cannot fail |
| [windows-and-tooling.md](windows-and-tooling.md) | Encoding, PowerShell, and the non-nat things that broke the setup |

## How to read these

Claims are marked so you can tell what to trust:

- **Measured** — we ran it and observed the result, usually against a wiped Phoenix volume.
- **Read from source** — traced through the installed package, with the file and line. Reliable, but
  not the same as having watched it happen.

Where we reasoned to a conclusion without testing it, that is said explicitly rather than implied.

## The short version

If you only read one thing:

1. `nat validate` passing does not mean a config runs. It checks schema, not wiring.
2. Your choice of model is load-bearing, not a detail. Most of the catalog cannot drive a ReAct
   agent at all.
3. Out of the box, Phoenix shows you structure, latency and inputs/outputs on this path — not LLM
   spans, prompts or token counts. `framework_wrappers`, the argument documented as wiring the
   profiler up, is read by nothing in 1.8.0.
4. Agents compose cleanly *inside one process*. Across a process boundary the trace comes apart, and
   putting it back together is not a configuration change.
5. Both are fixable, and the second one is not fixed the way you would guess. nat's own mechanism
   for cross-process traces is to replay the callee's intermediate steps into the caller's stream,
   not to propagate a span id to the callee. See [tracing.md](tracing.md).
