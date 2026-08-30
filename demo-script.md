# Demo script: following one agent's work into another

For Computerworld Cloud & AI Festival 2026.

**What this demo is:** an AI agent that cannot answer a question on its own hands the job to a second
agent, running as a separate service on an open protocol — and afterwards you can read the whole
thing as one story: who asked whom, what each one was thinking, what it went and read, and what it
cost.

**What this demo is not:** a developer session. Nobody needs to read YAML. There is one moment where
you show something not working, and it is clearly signposted.

Running time is about seven minutes, plus questions.

> **Read [Reliability](#reliability-read-this-before-you-commit) before you commit to this demo.**
> The two-process version is meaningfully less reliable than the single-process one, and you need to
> know your fallback before you are standing up.

---

## Before you go on

1. `bash scripts/setup.sh`, or `scripts\setup.ps1` on Windows. It should end with three green `ok`
   lines for the config files.
2. **Three windows.** Terminal A (the researcher, left), terminal B (the planner, middle), Phoenix
   in a browser (right). Plus the model playground in a browser tab for the cold open:
   https://build.nvidia.com/nvidia/nemotron-3-nano-omni-30b-a3b-reasoning/playground
3. Wipe Phoenix: `docker compose down -v && docker compose up -d`.
4. **Bake the "before" trace.** With Phoenix clean, run the pair *once* with the fix switched off.
   This leaves the two disconnected traces you will point at in Scene 4, so you never have to run it
   twice on stage.

   Terminal A:
   ```bash
   NAT_DEMO_NO_TRACE_PROPAGATION=1 NAT_DEMO_NO_STEP_RELAY=1 \
     nat start a2a --config_file configs/researcher.yml
   ```
   Terminal B:
   ```bash
   NAT_DEMO_NO_TRACE_PROPAGATION=1 NAT_DEMO_NO_STEP_RELAY=1 \
     nat run --config_file configs/planner.yml \
     --input "In which year did Computerworld publish its final print issue? Ask the researcher."
   ```
   Then **stop terminal A** and restart it without the environment variables — that is the researcher
   you will use on stage:
   ```bash
   nat start a2a --config_file configs/researcher.yml
   ```
   Check it is listening: `curl -s http://localhost:9002/.well-known/agent-card.json`

5. **Do a full practice run** of the real thing, and leave that trace in Phoenix. It is your safety
   net for Scene 5 if the live run misbehaves. Do not wipe again after this.
6. Browser zoom at 125 percent or more. The tree is what everyone needs to read.
7. Ask the playground the question a few times so you know what spread you are getting today.

**The one number to know:** the live run takes one to two minutes. Scene 3 is written to be talked
through. Do not stand and watch it.

Activate the venv in both terminals: `source .venv/bin/activate`, or `.\.venv\Scripts\Activate.ps1`
on Windows.

---

## Scene 1. The problem

**Duration:** 45 seconds
**On screen:** the model playground.

Type in:

> In which year did Computerworld publish its final print issue?

Read the answer out. Then **hit regenerate twice more** and read those too.

You will get a different year most times. In rehearsal this model gave 2013, then 2015, then 2014,
then 2013 again. Do not promise a specific wrong year in advance; the point is the spread, and the
spread is reliable even though any single answer is not.

> Three times, three answers.
>
> One of those is right, by the way. It does not know which one. It is not looking anything up,
> because it cannot. It is doing what you would do if someone asked you a date at a party and you
> did not want to seem ignorant.
>
> And notice it never once said "I am not sure". Every one of those was delivered with exactly the
> same confidence.
>
> That is the problem worth solving. Not that the model is stupid. That you cannot tell from the
> answer whether it knew or guessed.

**If it gives the same year three times**, say: "it is consistent today, but it is still guessing,
and it will not tell you that." Move on. Do not fight it.

The right answer is 2014. Do not reveal it yet.

---

## Scene 2. Two agents, two services

**Duration:** 60 seconds
**On screen:** terminal A, showing the researcher already running.

> So let's give it help. Two agents.
>
> The first one talks to the user and takes the question. Call it the planner.
>
> The second one has exactly one skill: it can search Wikipedia. Call it the researcher.

Point at terminal A.

> And here is the part that makes this realistic rather than a toy. The researcher is not a function
> inside the first program. It is its own service, running on its own, listening on a port. It could
> be on another machine, in another data centre, run by another team, or bought from another
> company.
>
> They talk over an open protocol called A2A — agent to agent. The planner does not know or care
> what the researcher is written in.

Optionally show the agent card for five seconds:

```bash
curl -s http://localhost:9002/.well-known/agent-card.json
```

> That is the researcher advertising what it can do. That is all the planner gets.
>
> Which is exactly the arrangement everyone is heading for, and exactly the arrangement where
> "what happened?" gets hard to answer.

Do not read YAML aloud. Nobody came for it.

---

## Scene 3. Run it

**Duration:** 90 seconds, most of it talking
**On screen:** terminal B.

Start the run *first*, then talk:

```bash
nat run --config_file configs/planner.yml \
  --input "In which year did Computerworld publish its final print issue? Ask the researcher."
```

While it runs:

> Same question. This time the planner has somewhere to go with it.
>
> It is deciding right now that this is a question of fact, that it should not answer from memory,
> and that there is a researcher out there for exactly this. Then it makes a network call and waits,
> the way you wait for a colleague.

If you need more time, this is the honest bit worth saying:

> This takes a minute or two, and it is worth being straight about why. Every step is a real call to
> a real model. There are several of them, and they are not free and not instant. Anyone who shows
> you an agent doing this in two seconds has either cached it or cut it.

When it finishes:

> **2014.** Which is right.
>
> Same model, same question. The difference is that this time somebody looked it up.

**If the answer comes back "not found" or wrong**, do not pretend otherwise. Say:

> And that is an agent for you — it did not find it that time. Let me show you *why*, which is
> actually the more useful thing.

Then go to Phoenix anyway. The trace is the demo; a failed run still traces perfectly, and reading a
failure is a stronger point than reading a success. See [Reliability](#reliability-read-this-before-you-commit).

---

## Scene 4. What you get out of the box

**Duration:** 45 seconds
**On screen:** Phoenix, trace list.

Open http://localhost:6006 and click the **a2a-demo** project. Do not open a trace yet.

> Before the good news, the bad news, because it is the reason this repo exists.
>
> I ran this same pair before we started, with one thing switched off. Those two rows are the
> result.

Point at the two older traces sitting next to each other.

> Two separate records. One for the planner, one for the researcher. Same moment in time, and
> nothing whatsoever connecting them.
>
> Nobody did anything wrong. That is just what you get when two agents talk over a network. Each one
> writes down its own half, and no one writes down that one caused the other.
>
> Which means when something goes wrong at three in the morning, you have two piles of evidence and
> no thread between them.

If you are short of time, cut this scene entirely and go straight to Scene 5. It is the engineering
point, not the human one.

---

## Scene 5. The whole chain, as one story

**Duration:** 2 minutes and 30 seconds
**On screen:** Phoenix, your live trace.

This is the heart of the demo. Slow down.

Click the newest trace — the one from the run you just did.

> And here is the same two agents, with that gap closed.
>
> One record. Not two.

Point at the tree, top to bottom:

```
planner                                     <- 11.8s total
  <workflow>
    nemotron...            [LLM]   1122 tokens
    researcher__call       [TOOL]                8.3s
      researcher__call
        researcher                          <- a different process, on :9002
          <workflow>
            nemotron...    [LLM]    597 tokens
            wiki_search    [TOOL]
            nemotron...    [LLM]   2070 tokens
    nemotron...            [LLM]   1283 tokens
```

That is a real run, not a mock-up. Yours will differ in the numbers and in how many searches the
researcher needed.

There are a couple of bookkeeping rows in there — `<workflow>`, and `researcher__call` appearing
twice. Read straight past them. They are the toolkit's own plumbing and pointing at them costs you a
minute.

> The planner at the top. That is the agent that took your question.
>
> Indented under it, `researcher__call` — that is the moment it picked up the phone.
>
> And *inside that*, the researcher. Its own reasoning, its own Wikipedia search, its own conclusion.
>
> That is a different process. On a different port. It could be in a different country. And it is
> sitting inside the planner's record as one nested story, because we taught the two of them to pass
> the thread along.

Now the reasoning. Click one of the `nemotron` rows under the researcher and open **Input**:

> This is what the researcher was actually thinking. Not a summary — the real prompt and the real
> reply. You can read the moment it decided which search to run.

Then click the `wiki_search` row:

> And this is what it went and read. The actual article text it based the answer on.

Then click back up to the planner's own rows:

> Same for the planner, one level up. You can read it deciding to delegate rather than answer.

Land the point:

> This is the part I want you to take away. When an agent gets something wrong in production, "the
> AI made a mistake" is not a finding you can act on. This is.
>
> You can see which agent was asked, what it was thinking, what it went and read, what it handed
> back, and how long each step took. Across a network, between two services that know almost nothing
> about each other.
>
> Not a log file. The shape of the thing.

**The cost line**, if the audience is commercial — point at the token numbers:

> And every one of those steps is counted. That question cost about seven thousand tokens across
> four model calls. Multiply by however many of these you are planning to run.

---

## Scene 6. Close

**Duration:** 30 seconds

> Three things.
>
> One. A model on its own answers from memory, gives you a different answer each time, and cannot
> tell you it is guessing. Giving it somewhere to look things up is the whole difference.
>
> Two. The moment your agents are separate services — which is where everyone is heading — "what
> happened" stops being obvious. Out of the box you get two disconnected records. You have to
> deliberately pass the thread across, and you have to do it before something goes wrong, not after.
>
> Three. None of this was exotic. Two agents, one search tool, an open protocol, and an open source
> tracing tool running in a container on this laptop.

Stop. No outro.

---

## Reliability: read this before you commit

The two-process version is less reliable than the single-process one. Here are the actual numbers
rather than a shrug.

**Tracing: solid.** Every run produced one trace, one root, the researcher nested inside the planner,
with reasoning and token counts present. That part did not fail once.

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

**Ignore the bookkeeping rows.** `<workflow>`, and `researcher__call` appearing at two levels. If
someone asks: "that's the toolkit's own plumbing."

**The searches vary.** Some runs the researcher finds it first try, some take two or three. Count
what is on screen rather than promising a number.

**Two terminals is a real risk.** Start the researcher well before you go on and check the agent card
responds. If the planner reports `503 All connection attempts failed`, the researcher is not up, or
it bound to the wrong address — the config binds `127.0.0.1` deliberately.

**If someone asks whether the remote agent has to trust you with its prompts.** Good question, and
the answer is a genuine design point: it does not. The remote agent chooses what to put in its
response. It is handing you its reasoning, not having it taken. And it never needs access to your
monitoring system — its telemetry travels home inside the answer it was already sending.

---

## The question, exactly

```
In which year did Computerworld publish its final print issue? Ask the researcher.
```

Model alone: a different year most times you ask. Rehearsal gave 2013, 2015, 2014, 2013.
Two agents: **2014** when it works, and either way you can read exactly what happened.

The model is not reliably wrong, it is reliably *unreliable*. That is the honest framing, and it is
the stronger one, because nobody can accuse you of picking a question the model happens to fail.
