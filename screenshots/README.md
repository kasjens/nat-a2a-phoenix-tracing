# Rehearsal screenshots

One capture per beat of [demo-script.md](../demo-script.md), from a single rehearsal against a wiped
Phoenix. Every image is a real run — nothing is mocked up or re-staged. Captured headless at 2x with
`puppeteer-core` driving the same services the demo uses.

The run these came from: **12 spans, one root, answer 2014, 11.9 seconds.**

## Scene 1 — the model on its own

Scene 1 now runs in the **same chat UI** as the rest of the demo, pointed at `configs/model-only.yml`
— a bare `chat_completion` workflow with no tools, on `:8002`, served to a second UI instance on
`:3001`. Two browser tabs rather than a cut to a different website, so the only visible difference
between Scene 1 and Scene 3 is whether the agent can look anything up.

| File | What it shows |
|---|---|
| [01a-model-only-ui.png](01a-model-only-ui.png) | The model-only chat, headed **Model only** — "No tools. It answers from memory." |
| [01b-question-typed.png](01b-question-typed.png) | The question, before sending. |
| [01c-drift-and-a-503.png](01c-drift-and-a-503.png) | The same question three times in one thread: **2017**, then **2013** — and a third ask that came back as the endpoint's error message. Both halves of stage reality in one image. |
| [01d-answers-summary.png](01d-answers-summary.png) | A separate five-ask run rendered as a card: `2015, 2013, 2015, 2013, \boxed{2019}`, with 2014 set apart as the answer the model never gave. |
| [scene1-model-alone.txt](scene1-model-alone.txt) | That run as raw text. |

**Why `01c` includes a failure.** The apology message is the NIM endpoint's free-tier concurrency
cap (`ResourceExhausted: Worker local total request limit reached (16/16)`), not a fault in the
demo. It hit roughly one ask in six during rehearsal even at 45-second spacing, and it is the reason
Scene 1 asks the question several times: the repetition is both the point of the scene and the cover
for a bad response. The fix on stage is **Regenerate response**.

`01d` is a *rendering of real API output*, not a screenshot of anything — the playground needs a
login and cannot be captured headlessly. The five answers are genuine calls at temperature 1.0.

Note `01c` and `01d` are both **Shape A** (it varies). Rehearsals also produced Shape B — `2017` four
times out of five, confidently wrong and consistent — and, about once in thirteen asks, Shape C: the
model simply gets it right. All three need different opening lines and all three are in the script.

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
