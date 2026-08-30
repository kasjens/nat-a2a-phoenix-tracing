# Demo script: following one agent's work into another

For Computerworld Cloud & AI Festival 2026.

**What this demo is:** an AI agent that cannot answer a question on its own hands the job to a second
agent, running as a separate service on an open protocol — and afterwards you can read the whole
thing as one story: who asked whom, what each one was thinking, what it went and read, and what it
cost.

**What this demo is not:** a developer session. Nobody needs to read YAML, and the whole thing is
driven from a chat window. There is one moment where you show something not working, and it is
clearly signposted.

Running time is about seven minutes, plus questions.

> **Read [Reliability](#reliability-read-this-before-you-commit) before you commit to this demo.**
> The two-process version is meaningfully less reliable than the single-process one, and you need to
> know your fallback before you are standing up.

---

## Before you go on

1. `bash scripts/setup.sh`, or `scripts\setup.ps1` on Windows. It should end with green `ok` lines
   for the config files.
2. **Install the UI once.** The chat front end is a separate NVIDIA project:
   ```bash
   git clone https://github.com/NVIDIA/NeMo-Agent-Toolkit-UI.git ui && cd ui && npm ci
   ```
   In its `.env` set `NAT_BACKEND_URL=http://127.0.0.1:8001` and
   `NEXT_PUBLIC_NAT_ENABLE_INTERMEDIATE_STEPS=true`. The second one is not optional — it is what
   makes Scene 3 work.
3. **Check the ports are free** before anything else: `ss -ltn | grep -E ':(8001|9002|3000|6006)'`
   should print nothing. The fastapi front end defaults to 8000, which OnlyOffice and plenty else
   will have taken — this repo uses 8001 for that reason.
4. **Start the three services, in this order.** The planner resolves the researcher's agent card at
   startup, so the researcher must be listening first or the planner will not boot.
   ```bash
   nat start a2a --config_file configs/researcher.yml           # terminal A, wait for it
   nat start fastapi --config_file configs/planner-ui.yml       # terminal B
   cd ui && npm run dev                                          # terminal C
   ```
   Confirm: `curl -s http://localhost:9002/.well-known/agent-card.json` and
   `curl -s http://localhost:8001/health`.
5. Wipe Phoenix: `docker compose down -v && docker compose up -d`.
6. **Bake the "before" trace.** With Phoenix clean, run the pair once from the CLI with the fix
   switched off. This leaves the two disconnected traces you point at in Scene 4, so you never run
   the demo twice on stage. It does not disturb the services you just started:
   ```bash
   NAT_DEMO_NO_TRACE_PROPAGATION=1 NAT_DEMO_NO_STEP_RELAY=1 \
     nat run --config_file configs/planner.yml \
     --input "In which year did Computerworld publish its final print issue? Ask the researcher."
   ```
7. **Do a full practice run through the UI** and leave that trace in Phoenix as your safety net. Do
   not wipe after this.
8. **Two windows on screen:** the chat UI (left), Phoenix (right). Browser zoom 125 percent or more.
9. Ask the model the question a few times beforehand so you know what it is doing today — see
   Scene 1, because what it does changes the opening line you use.

Screenshots of a complete rehearsal — one per scene, with notes on what each is meant to show — are
in [screenshots/](screenshots/). Worth a look before your first run so you know what you are aiming
at.

**The one number to know:** the live run takes 12 seconds to about a minute. Scene 3 is written to be
talked through, but it may well finish before you do.

Activate the venv in terminals A and B: `source .venv/bin/activate`, or
`.\.venv\Scripts\Activate.ps1` on Windows.

---

## Scene 1. The problem

**Duration:** 45 seconds
**On screen:** the model playground,
https://build.nvidia.com/nvidia/nemotron-3-nano-omni-30b-a3b-reasoning/playground

Type in:

> In which year did Computerworld publish its final print issue?

Read the answer out, then **hit regenerate three or four times** and read those too.

**You will get one of three shapes, and they need different lines.** Rehearse all three; you will
not know which you have until you are on stage. The right answer is 2014 in every case — do not
reveal it yet.

**Shape A — it varies.** Different years across the regenerations. Earlier rehearsals gave 2013,
2015, 2014, 2013.

> Four times, four answers.
>
> One of those is right. It does not know which one. It is not looking anything up, because it
> cannot. It is doing what you would do if someone asked you a date at a party and you did not want
> to seem ignorant.

**Shape B — it is consistent, and wrong.** This is what the most recent rehearsal gave: 2017, 2017,
2012, 2017, 2017.

> Four times, the same answer. Which is a problem, because it is wrong.
>
> That is worse than being unsure, and it is worse than being wrong occasionally. It is *reliably*
> wrong, delivered with total confidence, and there is nothing in that answer to tell you so.

**Shape C — it gets it right.** Rare but real: roughly 1 ask in 13 during rehearsal returned 2014.
If it comes up in the cold open, do not pretend it did not. Regenerate once or twice more — it will
almost certainly drift — and use the drift:

> And there it is. Same question, thirty seconds apart, a different answer.
>
> Which is the whole problem in one screen. It was right the first time and it is wrong now, and
> nothing about how it said either one tells you which was which.

If it stubbornly repeats 2014, stop fighting it and reframe — the demo still works, because being
right once is not the same as being reliable:

> Today it knows this one. That is luck, not a method, and you cannot tell the difference from the
> outside. Watch what happens when the agent is made to actually check.

Then, for any shape:

> Notice it never once said "I am not sure". That is the problem worth solving. Not that the model
> is stupid. That you cannot tell from the answer whether it knew or guessed.

Do not labour it. Forty-five seconds and move.

---

## Scene 2. Two agents, two services

**Duration:** 60 seconds
**On screen:** a browser tab at http://localhost:9002/.well-known/agent-card.json

> So let's give it help. Two agents.
>
> The first one talks to the user and takes the question. Call it the planner.
>
> The second one has exactly one skill: it can search Wikipedia. Call it the researcher.

Point at the agent card on screen.

> And here is what makes this realistic rather than a toy. The researcher is not a function inside
> the first program. It is its own service, on its own port. This is all the planner knows about it:
> a name, a description, and one skill called Wiki Search.
>
> It could be on another machine, in another data centre, run by another team, or bought from
> another company. They talk over an open protocol called A2A — agent to agent. The planner does not
> know or care what the researcher is written in.
>
> Which is where everyone is heading, and exactly where "what happened?" gets hard to answer.

Do not read the JSON aloud. Point at `name`, `description`, and `skills`, and move on.

---

## Scene 3. Ask it

**Duration:** 2 minutes
**On screen:** the chat UI at http://localhost:3000

Type the question into the chat box and send it:

```
In which year did Computerworld publish its final print issue? Ask the researcher.
```

An **Intermediate Steps** panel appears immediately and fills in while it works. Let it.

> Same question. This time the planner has somewhere to go with it.
>
> It has decided this is a question of fact, that it should not answer from memory, and that there
> is a researcher out there for exactly this. It has made a network call and it is waiting, the way
> you wait for a colleague.

When the answer lands:

> **2014.** Which is right.
>
> Same model, same question. The difference is that this time somebody looked it up.

Now the part worth slowing down for. **Expand the second `Function Start` step.** Inside it you will
find, nested: an LLM call, `Tool: wiki_search`, `Function Start: wiki_search`,
`Function Complete: wiki_search`, and another LLM call.

> Now look at what is inside that call.
>
> That is not the planner. That is the *researcher* — a different process, on a different port —
> and we are reading its private reasoning here in the caller's chat window. Its decision to search,
> the search itself, and what it concluded.

**Expand one of the `nvidia/nemotron...` rows** to show `Input` and `Output: Final Answer: 2014`.

> Its actual prompt. Its actual answer. From the other service.
>
> That is not something you normally get. Out of the box the remote agent's reasoning stays on the
> remote agent, and all you see is a result appearing from somewhere.

---

## Scene 4. What that normally looks like

**Duration:** 45 seconds
**On screen:** Phoenix at http://localhost:6006, the **a2a-demo** project, **Traces** tab.

> I said that is not what you normally get. Here is what you normally get.
>
> I ran this same pair before we started, with one feature switched off.

Point at the two older rows — one named `planner`, one named `researcher`.

> Two separate records. One for the planner, one for the researcher. Same moment in time, both
> perfectly correct, and nothing whatsoever connecting them.
>
> Nobody did anything wrong. That is just what happens when two agents talk over a network. Each
> writes down its own half, and nobody writes down that one caused the other.
>
> So at three in the morning you have two piles of evidence and no thread between them.

If you are short of time, cut this scene. It is the engineering point, not the human one.

---

## Scene 5. The record afterwards

**Duration:** 2 minutes
**On screen:** Phoenix, your live trace.

Click the newest trace, the one from the run you just did.

> You already saw the reasoning in the chat window, live. This is the same thing afterwards, as a
> record — which is what you actually need when something has gone wrong and the chat window is long
> gone.
>
> One trace. Not two.

The panel lists every step in the run: the planner, its model calls, `researcher__call`, the
**researcher**, and the researcher's own `wiki_search`. A couple of rows are bookkeeping —
`<workflow>`, and the call span appearing twice. Read straight past them.

> Every step of both agents, in one record.

**Do not say "look how it's nested" here.** Phoenix's span list in this panel draws flat — every row
sits at the same indentation whatever its depth. You already showed the shape in the chat window in
Scene 3; in Phoenix you make the point two other, stronger ways.

**First, the root count.** This trace has exactly one root. The pair you looked at in Scene 4 had
two.

> One record with one beginning, instead of two records with two. That is the difference.

**Then click the `researcher` span.** Its Input is the question the planner asked it, its Output is
`2014`, and its latency is its own.

> This is a different process. It could be a different company. Its work is in here because the two
> of them pass the thread along.

**Open the Attributes tab and filter for `parent`.** One row: `nat.function.parent_name` =
`researcher__call`.

> And if you would rather read it than infer it — every step records which agent handed it the work.
> That is the audit trail, in words.

Land the point:

> When an agent gets something wrong in production, "the AI made a mistake" is not a finding you can
> act on. This is.
>
> Which agent was asked, what it was thinking, what it went and read, what it handed back, how long
> each step took. Across a network, between two services that know almost nothing about each other.
>
> Not a log file. The shape of the thing.

**The cost line**, if the audience is commercial — the `[LLM]` rows carry token counts:

> And every step is counted. That question cost about seven thousand tokens across four model calls.
> Multiply by however many of these you plan to run.

---

## Scene 6. Close

**Duration:** 30 seconds

> Three things.
>
> One. A model on its own answers from memory, and it cannot tell you it is doing that — whether it
> gives you a different answer each time or the same wrong one with total confidence. Giving it
> somewhere to look things up is the whole difference.
>
> Two. The moment your agents are separate services — which is where everyone is heading — "what
> happened" stops being obvious. Out of the box you get two disconnected records. You have to
> deliberately pass the thread across, and you have to do it before something goes wrong, not after.
>
> Three. None of this was exotic. Two agents, one search tool, an open protocol, a chat window, and
> an open source tracing tool running in a container on this laptop.

Stop. No outro.

---

## Reliability: read this before you commit

The two-process version is less reliable than the single-process one. Here are the actual numbers
rather than a shrug.

**Tracing: solid.** Every run produced one trace, one root, the researcher nested inside the planner,
with reasoning and token counts present. That part did not fail once — including through the UI,
which reaches the planner by a different route than the CLI.

**One caveat about that route.** The A2A client exposes several functions and the model picks freely;
a rehearsal through the UI picked `send_message` where every CLI run had picked `call`. If you are
running a modified version of this repo, make sure the step relay covers all of them — the failure is
silent and looks like a complete trace with the remote agent's subtree missing. Fixed here, written
up in [docs/tracing.md](docs/tracing.md).

**Answer quality: roughly 4 runs in 5.** The researcher used to run a single search, miss, and answer
"not available" — 3 of 5 runs. Its own instructions were the cause, and `configs/researcher.yml` now
requires a second, differently-worded search before it may conclude anything. After that change,
measured over nine consecutive runs:

- **7 answered 2014 correctly**, in 12 to 30 seconds
- **2 failed**, both the same way: the planner printed its tool call as the final answer instead of
  making it, in about 1.4 seconds

So plan on roughly four runs in five working, and plan for the fifth.

**Two intermittent failure modes remain, and neither is fixed by config.** Both come from the model,
not the plumbing, and both produce a *fast, confident, wrong* answer rather than a crash — which is
the worst shape a failure can take on stage.

| What you see | What happened |
|---|---|
| An instant answer (~1.4s), researcher's terminal silent, output looks like `{ "action": "researcher__call", ... }` | The planner printed its tool call instead of making it. Trace has 3 spans and no `researcher__call`. **This is the common one — 2 of 9 runs.** |
| A confident wrong year, researcher's terminal shows an error | The researcher died with `ReActAgentParsingFailedError` (empty completion — see [docs/models.md](docs/models.md)), so the planner fell back on its own memory. |

**The tell in both cases is speed.** A real run takes 12 seconds or more and the researcher's
terminal visibly works. If you get an answer in under three seconds, something went wrong regardless
of how plausible the answer looks. Glance at terminal A before you celebrate.

Both are recoverable. Say "that is an agent for you — and this is exactly why you want the receipt",
then open the trace. A trace with no `researcher__call` in it is a perfectly good illustration of why
you trace things.

What to do:

1. **Rehearse immediately before.** Same laptop, same network, same question.
2. **Keep a good trace in Phoenix** from that rehearsal and do not wipe after it. If the live run
   disappoints, open the rehearsal trace instead. The trace is the demo; the live run is only how you
   got one.
3. **Have the single-process version ready.** `configs/chain.yml` is more reliable and tells most of
   the same story — you lose only the "separate service, over a network" framing:
   ```bash
   nat run --config_file configs/chain.yml \
     --input "In which year did Computerworld publish its final print issue? Ask the researcher."
   ```
4. **Rehearse the failure line.** A wrong answer is recoverable if you own it and pivot to the trace.
   It is only fatal if you look surprised.

If a wrong answer on stage would be unacceptable for your audience, run `configs/chain.yml` and
describe the A2A version rather than performing it.

---

## Practical notes

**Do not say "it always works".** It is an agent. Say what it did today.

**You can show token counts now.** Earlier versions of this repo could not — the toolkit emits no
LLM spans on this path out of the box, and the shims in `plugin/` are what put the prompts and the
numbers on screen. If someone asks whether that is standard, the honest answer is "not yet; this repo
adds it, and the write-up is in `docs/`."

**Ignore the bookkeeping rows.** `<workflow>`, and the call span appearing at two levels. If someone
asks: "that's the toolkit's own plumbing."

**The searches vary.** Some runs the researcher finds it first try, some take two or three. Count
what is on screen rather than promising a number.

**Three services is a real risk.** Start them in order — researcher, planner, UI — and check both
health endpoints before you go on. Things that will bite you:

- The planner resolves the researcher's agent card **at startup**, so the researcher must be up
  first, or the planner will not boot.
- Port 8001 must be free. The fastapi default is 8000 and is often taken.
- Both of those failures are reported as
  `'FastApiFrontEndPlugin' object has no attribute '_dask_client'`, which is not the real error.
  Scroll up to the first `ERROR:` line.
- If the planner reports `503 All connection attempts failed`, the researcher bound to the wrong
  address — the config binds `127.0.0.1` deliberately.

**The mic button is next to the send arrow.** In the chat UI they sit together at the right of the
input box. Clicking the wrong one prompts for microphone access in front of the room. Send is the
paper plane, on the far right.

**If someone asks whether the remote agent has to trust you with its prompts.** Good question, and
the answer is a genuine design point: it does not. The remote agent chooses what to put in its
response. It is handing you its reasoning, not having it taken. And it never needs access to your
monitoring system — its telemetry travels home inside the answer it was already sending.

---

## The question, exactly

```
In which year did Computerworld publish its final print issue? Ask the researcher.
```

Model alone, across rehearsals: `2013, 2015, 2014, 2013` one day; `2017, 2017, 2012, 2017, 2017`
another; `2015, 2013, 2015, 2013, 2019` a third. Sometimes it varies, sometimes it is consistently
wrong, and about once in thirteen asks it is simply right. Check which you have on the day — Scene 1
gives you a line for each of the three.

Two agents: **2014** when it works, and either way you can read exactly what happened.

Whichever shape you get, the honest framing is the same and it is the stronger one: the model cannot
tell you whether it knew or guessed. Nobody can accuse you of picking a question it happens to fail,
because the problem is not the wrong answer — it is the missing "I am not sure".
