# Rehearsal screenshots

One capture per beat of [demo-script.md](../demo-script.md), from a single rehearsal against a wiped
Phoenix. Every image is a real run — nothing is mocked up or re-staged. Captured headless at 2x with
`puppeteer-core` driving the same services the demo uses.

The run these came from: **12 spans, one root, answer 2014, 11.9 seconds.**

## Scene 1 — the model on its own

| File | What it shows |
|---|---|
| [01-model-alone.png](01-model-alone.png) | Five unaided asks: `2015, 2013, 2015, 2013, \boxed{2019}`. The correct answer, 2014, is set apart below the rule and marked as one the model never gave. |
| [scene1-model-alone.txt](scene1-model-alone.txt) | The same run as raw text. |

The image is a **rendering of real API output**, not a screenshot of the playground — the playground
at build.nvidia.com needs a login, so it cannot be captured headlessly. The five answers are genuine
calls to the NIM endpoint at temperature 1.0. On stage this beat is a browser tab; the numbers are
what matter.

An earlier version of the text file put "Wikipedia says 2014" on the line directly beneath the asks,
where it read like a sixth answer from the model. It is not, and both files now keep the correct
answer visually separate.

Note this is the **Shape A** opening from the script (it varies). Rehearsals also produced Shape B —
`2017` four times out of five, confidently wrong and consistent — and, once in about thirteen asks,
Shape C: the model simply gets it right. All three need different opening lines and all three are in
the script. Check which you have on the day.

## Scene 2 — two agents, two services

| File | What it shows |
|---|---|
| [02-agent-card.png](02-agent-card.png) | The researcher's A2A agent card on `:9002`: name, description, one skill (`Wiki Search`), protocol 0.3.0. Everything the planner knows about it. |

## Scene 3 — ask it, in the chat UI

| File | What it shows |
|---|---|
| [03a-ui-empty.png](03a-ui-empty.png) | The chat UI before anything happens. |
| [03b-question-typed.png](03b-question-typed.png) | The question in the box, before sending. |
| [03c-steps-streaming.png](03c-steps-streaming.png) | Intermediate Steps filling in while it works. |
| [03d-answer.png](03d-answer.png) | **2014**, with its steps above it. |
| [03e-steps-expanded.png](03e-steps-expanded.png) | Steps expanded — the nested shape of the call. |
| [03f-planner-decides.png](03f-planner-decides.png) | The planner's own reasoning: *"Thought: I need to query the researcher... Action: researcher__call"*. |
| [03g-remote-reasoning.png](03g-remote-reasoning.png) | **The one that matters.** The *researcher's* reasoning, in the planner's chat window: *"I'll search Wikipedia for 'Computerworld'... Action: wiki_search"*, then the search itself. A different process's deliberation, rendered in the caller's UI. |
| [03h-remote-final-answer.png](03h-remote-final-answer.png) | The remote agent's conclusion. |

`03g` is the beat the older, terminal-based script did not have. It works because the step relay
replays the remote agent's steps into the caller's event stream, which is the same stream the UI
renders — so the chain is visible before Phoenix is opened at all.

It also shows the config fix working: the researcher searched the article title `Computerworld`
rather than the user's question, which is what `configs/researcher.yml` now instructs.

## Scene 4 — what that normally looks like

| File | What it shows |
|---|---|
| [04a-phoenix-projects.png](04a-phoenix-projects.png) | The `a2a-demo` project. |
| [04b-root-spans.png](04b-root-spans.png) | **The contrast in one frame.** Filtered to `parent_id is None`, so every row is a root: the live run's single `planner`, plus the stock run's **two** roots — `planner` and an orphaned `researcher`. |
| [04c-orphan-researcher-trace.png](04c-orphan-researcher-trace.png) | The orphan opened up. It did real work — 15 seconds, three `wiki_search` calls, answered 2014 — and nothing in it says the planner caused any of it. |

The stock rows come from a run with `NAT_DEMO_NO_TRACE_PROPAGATION=1 NAT_DEMO_NO_STEP_RELAY=1`,
baked before the demo so the contrast costs no stage time.

## Scene 5 — the record afterwards

| File | What it shows |
|---|---|
| [05a-trace-tree.png](05a-trace-tree.png) | The whole run as one trace, 11.9s: `planner`, `<workflow>`, the LLM calls, `researcher__call`, **`researcher`**, and its own `wiki_search` calls. |
| [05b-researcher-nested.png](05b-researcher-nested.png) | The remote agent's span selected — 7.1s, its own Input (the question the planner asked it) and Output `2014`. |
| [05c-attributes.png](05c-attributes.png) | **`nat.function.parent_name` = `researcher__call`** — the handoff stated in words rather than implied by position. |

**One thing to know before you present this.** Phoenix's span list in the trace panel renders
**flat**: every row sits at the same indentation regardless of depth (measured — all twelve nodes at
the same `left` offset). So you cannot point at indentation here and say "look, it's nested". The
nesting is real, but in Phoenix you evidence it two other ways:

- **`04b-root-spans.png`** — filtered to roots, the live run contributes exactly **one**, where the
  stock run contributes two. One root means one tree.
- **`05c-attributes.png`** — `parent_name` names the calling function outright.

The place the hierarchy *is* drawn visually is the chat UI, in `03e`/`03g`, where the remote agent's
steps are plainly nested inside the planner's call. That is the better screen for the shape; Phoenix
is the better screen for the record and the attribution.

## Reproducing

Services must be running (researcher `:9002`, planner `:8001`, UI `:3000`, Phoenix `:6006`) — see
[demo-script.md](../demo-script.md) for the order, which matters. Then wipe Phoenix, bake the stock
trace, and run the capture script in the session scratchpad. The script is not committed: it is
throwaway glue, and it hard-codes selectors that will drift with the next Phoenix release.
