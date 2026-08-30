# Demo script: one agent handing work to another

For Computerworld Cloud & AI Festival 2026.

**What this demo is:** an AI agent that cannot answer a question on its own, hands the job to a
second agent that can, and a record afterwards that proves exactly what happened.

**What this demo is not:** a developer session. Nobody needs to read YAML, and nothing here is
broken on purpose. Every screen you show works.

Running time is about five minutes, plus whatever you spend on questions.

---

## Before you go on

1. `bash scripts/setup.sh`, or `scripts\setup.ps1` on Windows. It should end with three green
   `ok` lines for the config files.
2. Phoenix is up at http://localhost:6006 and the `a2a-demo` project is **empty**. Wipe it with
   `docker compose down -v && docker compose up -d`. A clean list means the trace the audience sees
   is unmistakably the one you just created.
3. Do one full practice run and then wipe again. The first call to the model endpoint is slow while
   it warms up, and you do not want to discover that on stage.
4. Two windows, side by side: terminal on the left, Phoenix on the right. Do not alt-tab.
5. Browser zoom at 125 percent or more. The tree is the thing everyone needs to read.
6. Have the model playground open in a third tab for the cold open:
   https://build.nvidia.com/nvidia/nemotron-3-nano-omni-30b-a3b-reasoning/playground
7. Ask it the question a few times during rehearsal so you know what spread you are getting today.

**The one number to know:** the run takes roughly two minutes. That is not dead air if you use it,
and Scene 3 is written to be talked through. Do not stand and watch it.

---

## Scene 1. The problem

**Duration:** 45 seconds
**On screen:** the model playground on build.nvidia.com.

Type into the playground:

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

**If it happens to give the same year three times**, say: "it is consistent today, but it is still
guessing, and it will not tell you that." Then move on. Do not fight it.

The right answer is 2014. Do not reveal that yet.

Do not labour this. Forty-five seconds and move.

---

## Scene 2. Two agents

**Duration:** 45 seconds
**On screen:** terminal, config file open but not scrolled through.

> So let's give it help. Two agents.
>
> The first one talks to the user. It is the one that takes the question. Call it the planner.
>
> The second one has exactly one skill: it can search Wikipedia. Call it the researcher.
>
> The planner cannot search. The researcher does not talk to the user. When a question needs a
> fact, the planner hands the job over, waits, and uses what comes back.

If you show the config at all, show it for five seconds and point at two words: `planner` and
`researcher`.

> That is the entire setup. Two agents and one instruction each.

Do not read the file aloud. Nobody in the room came for YAML.

---

## Scene 3. Run it

**Duration:** 90 seconds, most of it talking
**On screen:** terminal.

Start the run *first*, then talk:

```bash
nat run --config_file configs/chain.yml \
  --input "In which year did Computerworld publish its final print issue? Ask the researcher."
```

While it runs:

> Same question. This time the planner has somewhere to go with it.
>
> It is deciding right now that this is a question of fact, that it should not answer from memory,
> and that it has a researcher for exactly this. Then it waits, the way you wait for a colleague.

If you need more time, this is the honest bit worth saying out loud:

> This takes a couple of minutes, and it is worth being straight about why. Every step is a real
> call to a real model. There are several of them, and they are not free and not instant. Anyone
> who shows you an agent doing something like this in two seconds has either cached it or cut it.

When it finishes:

> **2014.** Which is right.
>
> Same model, same question. The difference is that this time somebody looked it up.

---

## Scene 4. Proving what happened

**Duration:** 90 seconds
**On screen:** Phoenix, right hand side.

This is the heart of the demo. Slow down.

Open http://localhost:6006, click the **a2a-demo** project, click the single trace in the list.

> Here is the receipt.
>
> Everything those two agents just did was recorded, and this is it.

Point at the tree, top to bottom:

```
planner
  researcher
    wiki_search
    wiki_search
```

On screen there is one extra row, `<workflow>`, sitting between `planner` and `researcher`. Read
straight past it. It is the toolkit's own bookkeeping, it has no content of its own, and it is not
part of the story you are telling.

> The planner, at the top. That is the agent that took your question.
>
> Underneath it, indented, the researcher. That indentation is the handoff. The researcher is inside
> the planner's work because the planner is what caused it to run.
>
> And underneath the researcher, two Wikipedia searches. The first one missed. The second one found
> the article. Then it stopped, because it had what it needed.

Now click the spans one at a time, from the bottom up, and read the **Output** box:

> Read it backwards and you can watch the answer being made.
>
> The search returns a wall of Wikipedia text. The researcher reads it and comes back with a
> sentence. The planner takes that sentence and gives the user the year they asked for.
>
> Nobody wrote that summary. Each agent handed the next one a little less raw material and a little
> more answer.

Land the point:

> This is the part I actually want you to take away. When an agent gets something wrong in
> production, "the AI made a mistake" is not a finding you can act on. This is. You can see which
> agent was asked, what it went and read, what it handed back, and how long each step took.
>
> Not a log file. The shape of the thing.

If you have time, one span's **Attributes** tab shows `nat.function.parent_name` — literally which
agent handed work to which. Only open this if someone asks how the tool knows; it is detail, not
story.

---

## Scene 5. Close

**Duration:** 30 seconds

> Three things.
>
> One. A model on its own answers from memory, gives you a different answer each time, and cannot
> tell you it is guessing. Giving it somewhere to look things up is the whole difference.
>
> Two. The moment you have more than one agent, "what happened" stops being obvious. You need the
> record, and you need it turned on before something goes wrong, not after.
>
> Three. None of this was exotic. Two agents, one search tool, and an open source tracing tool
> running in a container on this laptop.

Stop. No outro.

---

## Practical notes

**Do not say "it always works".** It is an agent. Say what it did today.

**Do not promise costs or token counts on screen.** The tool does not show them on this path, and
someone will look. If cost comes up, answer it in words and move on.

**Ignore the extra `<workflow>` row.** Phoenix shows one bookkeeping row between `planner` and
`researcher`. It is the toolkit's own wrapper, it has no interesting content, and pointing at it
invites a question that costs you a minute. If someone asks: "that's the toolkit's own bookkeeping."

**The searches vary.** Some runs the researcher finds it first try, some runs it takes two or three.
Count what is on the screen rather than promising a number in advance.

**If the run fails on stage.** Say "that is an agent for you", and open the trace from your practice
run, which is still in Phoenix if you did not wipe. The trace is the demo. The live run is only how
you got one.

**If someone asks about splitting the agents across machines.** They can, and the repo has configs
for it, but the tracing story gets more complicated and it is not a stage answer. Offer to show them
afterwards.

---

## The question, exactly

```
In which year did Computerworld publish its final print issue? Ask the researcher.
```

Model alone: a different year most times you ask. Rehearsal gave 2013, 2015, 2014, 2013.
Two agents: **2014**, every time, and you can prove why.

The model is not reliably wrong, it is reliably *unreliable*. That is the honest framing, and it is
also the stronger one, because nobody can accuse you of picking a question the model happens to fail.
