# Tracing one agent handing work to another

A planner agent delegates a lookup to a researcher agent, the researcher searches Wikipedia, and
the answer comes back up the chain. Everything exports to a local Phoenix instance, where the whole
handoff shows up as one tree you can follow end to end.

The two agents run as **separate services talking over the A2A protocol**, which is where the single
tree normally falls apart. On stock nat 1.8.0 that hop produces two unlinked traces with nothing
saying one caused the other. The shims in `plugin/` reduce that to one tree in which the remote
agent's whole reasoning chain — its prompts, its searches, its token counts — is nested under the
call that caused it.

A single-process variant (`configs/chain.yml`) is also here, and is the more reliable fallback.

Verified against `nvidia-nat` 1.8.0 (August 2026), which is the latest release. All five config files
pass `nat validate` and have been run end to end.

## What you need

- Python 3.11 or newer
- Docker, for Phoenix
- An API key from [build.nvidia.com](https://build.nvidia.com), free tier is enough
- Node 18+ and npm, **only** if you want the browser UI. The setup scripts fetch and configure it
  when node is present, and skip it with a warning when it is not. See [docs/ui.md](docs/ui.md).

No GPU. The model runs on NVIDIA's hosted NIM endpoint. Be aware that the free endpoint has a
concurrency cap and returns a 503 under load; [docs/models.md](docs/models.md) has the details and
what it looks like when it happens.

## Quick start

```bash
cp .env.example .env     # Windows: copy .env.example .env
# put your key in .env
```

**Ubuntu, Debian, WSL2, macOS**

```bash
bash scripts/setup.sh
```

**Windows**

```powershell
powershell -ExecutionPolicy Bypass -File scripts\setup.ps1
```

Either script checks Python and Docker, creates `.venv`, installs
`nvidia-nat[phoenix,langchain,a2a]==1.8.0` and the local `plugin/` package, fetches and configures
the two browser UI instances if node is available, starts Phoenix, and validates every config. It is safe to re-run. Missing pieces produce a warning rather than a stop,
so one pass shows you everything that needs fixing.

## Run

Activate the venv first: `source .venv/bin/activate` on Linux and macOS,
`.\.venv\Scripts\Activate.ps1` on Windows — in **each** terminal.

### The demo: two agents, two processes, one trace

Terminal 1, the researcher, served as an A2A agent on port 9002:

```bash
nat start a2a --config_file configs/researcher.yml
```

Check the agent card is up:

```bash
curl -s http://localhost:9002/.well-known/agent-card.json     # bash
irm http://localhost:9002/.well-known/agent-card.json         # PowerShell
```

Terminal 2, the planner:

```bash
nat run --config_file configs/planner.yml \
  --input "In which year did Computerworld publish its final print issue? Ask the researcher."
```

Open http://localhost:6006, project `a2a-demo`, and click the trace. One trace, one root, with the
remote agent's entire reasoning chain nested inside the call that caused it:

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

That is a real run. Click any `[LLM]` row and read **Input** and **Output** for the actual prompt and
completion — including the remote agent's, which happened in another process.

Ask the model this question on its own and it gives you a different year almost every time: in
testing, 2013, then 2015, then 2014, then 2013. One of those is right and it cannot tell you which,
because it is not looking anything up. The chain answers **2014**, because the researcher goes and
reads it.

Pick something the model is unreliable about, so the handoff visibly earns its keep instead of merely
happening. Do not pick something it can answer from memory: the planner will simply answer it itself,
and you get a short trace with no handoff in it at all.

Read **down** the tree for the request path, and each span's **Output** back **up** for the response
path. The answer condenses at every handoff: `wiki_search` returns raw Wikipedia documents,
`researcher` returns a sentence, `planner` returns the short answer the user asked for.

To see it in words rather than by nesting, open a span's **Attributes** tab: `nat.function.name` is
the agent the span belongs to, `nat.function.parent_name` is the agent that called it.

The presenter script is in [demo-script.md](demo-script.md), including a **reliability section worth
reading before you demo this live** — the two-process path has a known intermittent failure.

### Driving it from a browser instead of the terminal

`configs/planner-ui.yml` is the same planner served over the fastapi front end, so a chat UI can
drive it. Pair it with [NVIDIA's NeMo Agent Toolkit UI](https://github.com/NVIDIA/NeMo-Agent-Toolkit-UI):

```bash
nat start a2a --config_file configs/researcher.yml        # terminal 1, must be up first
nat start fastapi --config_file configs/planner-ui.yml    # terminal 2
```

`scripts/setup.sh` clones and configures it for you, into `./ui` (the planner, on `:3000`) and
`./ui-model-only` (the bare model, on `:3001`). Both are gitignored. Start them with `npm run dev`
from their directories.

The setup sets `NEXT_PUBLIC_NAT_ENABLE_INTERMEDIATE_STEPS=true` on the planner instance, which is
what renders the agent's reasoning steps inline.

That setting does more than it sounds like. Because the step relay replays the *remote* agent's steps
into the caller's stream, and the UI subscribes to that same stream, the researcher's own reasoning —
its search, its conclusion — appears in the planner's chat window, live, before you open Phoenix at
all. See [docs/ui.md](docs/ui.md).

`configs/model-only.yml` serves the bare model with no tools on `:8002`, for showing what the model
does *without* help in the same interface. One UI instance talks to exactly one backend, so that
needs a second UI instance — [docs/ui.md](docs/ui.md) has the four settings to change.

Two things that will bite you, both written up in
[docs/agents-and-config.md](docs/agents-and-config.md): the planner resolves the researcher's agent
card at **startup**, so the researcher has to be listening first; and the front end defaults to port
8000, which is often already taken. Either failure is reported as
`'FastApiFrontEndPlugin' object has no attribute '_dask_client'`, which is not the real error — scroll
up to the first `ERROR:` line.

### To see what it looks like without the fix

Both halves can be switched off, which is the clearest way to see what nat gives you out of the box:

```bash
NAT_DEMO_NO_TRACE_PROPAGATION=1 NAT_DEMO_NO_STEP_RELAY=1 \
  nat start a2a --config_file configs/researcher.yml      # and the same on the planner
```

You get two separate traces at the same timestamp with nothing linking them. See
[What breaks over A2A](#what-breaks-over-a2a).

### The simpler variant: both agents in one process

`configs/chain.yml` puts both agents in a single process. It needs one terminal instead of two, is
noticeably more reliable, and traces as one tree for a different reason — everything shares a span
stack, so no relay is involved:

```bash
nat run --config_file configs/chain.yml \
  --input "In which year did Computerworld publish its final print issue? Ask the researcher."
```

```
planner
  <workflow>
    researcher
      wiki_search
      wiki_search
```

This is the fallback if the A2A version misbehaves on stage, and the better starting point if you are
reading the repo rather than presenting it.

## What to look at

### The handoff, traced end to end

The tree above. One agent calls another across a process boundary, and you can follow the request
down and the answer back up without leaving the trace. This is what tracing gives you that logging
does not: not more detail, structure. A log file has the same events in it, flat, in time order, in
two different files on two different machines.

One caveat about what is *stock* and what this repo adds. **Out of the box there are no LLM
spans and no token counts.** Every span nat emits on this path is `spanKind: chain` with a null token
count. nat *has* an `LLM` span kind and maps `LLM_START` to it, but the component that emits those
events, `LangchainProfilerHandler`, is only attached in
`nat/plugins/langchain/control_flow/sequential_executor.py`, and the `react_agent` path never
attaches it. The `framework_wrappers` argument that is documented as wiring this up is read by
nothing in 1.8.0.

`plugin/nat_demo_shims/llm_spans.py` attaches it, and with it loaded you do get `spanKind: LLM`
spans carrying the prompt, the completion and token counts — which is what makes the *reasoning*
chain readable rather than just the call graph. `NAT_DEMO_NO_LLM_SPANS=1` turns it off if you want
to show the stock behaviour.

## What breaks over A2A

Everything below is what nat 1.8.0 does *without* the shims in `plugin/`, and it is the reason this
repo started. Reproduce any of it by setting `NAT_DEMO_NO_TRACE_PROPAGATION=1` and
`NAT_DEMO_NO_STEP_RELAY=1` on both processes.

### The gap at the process boundary

Run act two above and look at the trace list.
You will see two separate root traces at the same timestamp, one for the planner and one for the
researcher, with no parent-child link between them. Nothing in Phoenix tells you the researcher's
two minutes of work were caused by the planner's request.

This is not a misconfiguration, and the reason is more specific than "NAT has no trace
propagation". NAT 1.8.0 has the *receiving* half already:

- `nat/runtime/session.py:643` parses a W3C `traceparent` header and sets `workflow_trace_id`
- `nat/runtime/runner.py:185` is `existing_trace_id or uuid.uuid4().int`, so a workflow **inherits**
  an incoming trace ID rather than always minting a fresh one
- there is even a set of cross-workflow headers: `workflow-trace-id`, `workflow-parent-id`,
  `workflow-parent-name`

What is missing is the two ends that would actually use it across an A2A hop:

- **No inject on the client.** `nat/plugins/a2a/client/client_base.py:87` builds a bare
  `httpx.AsyncClient(timeout=...)` and never adds a `traceparent` header.
- **No extract on the server.** `set_metadata_from_http_request()` runs only for a Starlette
  `Request` (`session.py:496`), but the A2A adapter calls `session()` with no HTTP request at all
  (`nat/plugins/a2a/server/agent_executor_adapter.py:107`), so the parsing above never runs on this
  path.

So the plumbing exists at the runtime layer and is simply not wired up in the A2A transport. Verified
against 1.8.0, which is the latest release.

This is worth being precise about, because "nat has no trace propagation" is the sort of claim
people check. Most of the surprise here is that everything in the stack says OpenTelemetry on the
box, so you assume the context flows.

**Can you fix it?** Mostly, yes, and `plugin/` does. It injects a `traceparent` on the A2A client
and reads it back on the server, which is the two-line gap described above. Measured against a wiped
Phoenix volume:

| | traces | root spans | remote tree nested | LLM spans |
|---|---|---|---|---|
| stock 1.8.0 | 2 | 2 | no | 0 |
| `traceparent` shim | **1** | 2 | no | 0 |
| + `llm_spans` + step relay | **1** | **1** | **yes** | **6** |

Measured on a real two-process run against a live model, not a simulation.

The `traceparent` shim links the hop and puts both agents in one trace. It does not nest them, and
that part is not another header: nat resolves parentage through an in-process dictionary, so a parent
id minted in the other process is a miss in the researcher's `_span_stack`.

The obvious conclusion — that nesting needs a change inside `span_exporter` — turns out to be wrong.
nat has a second mechanism for exactly this, `push_intermediate_steps`, documented as replaying
"steps from a remote workflow ... into the current workflow's observability stream so the full tree
is visible", with a worked example in `nat/experimental/relay_telemetry_bridge.py`. It is wired up
for the `/generate/full` HTTP path and for NeMo Relay, and not for A2A.

`plugin/nat_demo_shims/a2a_step_relay.py` wires it up: the researcher attaches its steps to the A2A
response, and the planner re-parents them onto its own open call span and replays them. The
researcher's whole tree — its `wiki_search` calls, and its LLM spans if `llm_spans.py` is loaded —
is then drawn underneath the planner's `researcher` span, in one trace:

```
<workflow>                                  <- one root
  nemotron               [LLM]  1406 tokens
  researcher__call       [TOOL]
    researcher__call     [CHAIN]
      react_agent        [CHAIN]            <- the remote agent's root, replayed
        <workflow>
          nemotron       [LLM]   740 tokens
          wiki_search    [TOOL]
          nemotron       [LLM]  3117 tokens
  nemotron               [LLM]  1472 tokens
```

Publication is negotiated rather than assumed: the caller sends `x-nat-relay-steps: 1` to declare it
will collect the callee's telemetry, and only then does the callee skip exporting its own. Without
that handshake both publish and the same work appears twice — measured as 2 roots and 18 spans where
one tree of 9 was intended. A useful side effect is that the remote agent then needs **no route to
your collector at all**; its telemetry travels home in the response it was already sending.

This also inverts who controls the exposure, which matters more than it first appears. A2A is built
around opaque agents. Telemetry that silently harvests a remote agent's prompts fights that premise
as soon as the two agents belong to different organisations; steps returned *in the response* are
something the callee grants rather than something the caller takes.

`NAT_DEMO_NO_TRACE_PROPAGATION=1` and `NAT_DEMO_NO_STEP_RELAY=1` turn the two halves off
independently, which is how you show the stock behaviour. Both are read at import time, so set them
before starting either process.

### Looping with no error

This one is not specific to A2A — it happens in `chain.yml` too — but it is worth knowing about.

Ask for something Wikipedia does not have. A conference with no article is a reliable choice:
searching for "Computerworld Cloud & AI Festival 2026" returns South by Southwest, Tata, Mozilla and
Xiaomi, so the agent gets plausible-looking results that answer nothing.

```bash
nat run --config_file configs/chain.yml \
  --input "What is the Computerworld Cloud & AI Festival 2026? Ask the researcher."
```

The researcher's ReAct loop re-queries with rephrased arguments until `max_tool_calls` stops it.
Every span is green. No errors, no timeouts, a plausible final answer. The failure is only visible
as repeated sibling spans under one parent, which is exactly what a log line per tool call hides:
several successes.

With `llm_spans.py` loaded you *can* now make the cost argument on screen: each wasted round is an
`[LLM]` span with its own token count, so the price of the loop is visible rather than merely
assertable. On stock 1.8.0 it is not — there are no token counts on this path at all.

## Notes on nat 1.8.0

Building this turned up a lot that is not in the toolkit's documentation: configs that pass
`nat validate` and then fail at runtime, models that cannot drive a ReAct agent at all, and a
tracing story with sharper edges than it first appears. It is written up in [`docs/`](docs/):

- [agents-and-config.md](docs/agents-and-config.md) — composing agents, function groups, tool budgets,
  getting an agent to search twice before giving up, and what an A2A error response throws away
- [tracing.md](docs/tracing.md) — what Phoenix does and does not show, and why
- [ui.md](docs/ui.md) — the browser UI, and why it shows the remote agent's reasoning
- [models.md](docs/models.md) — 83 models surveyed, 9 that actually work
- [windows-and-tooling.md](docs/windows-and-tooling.md) — encoding, PowerShell, Wikipedia, Docker

## Why `plugin/` exists

Two things in the stock 1.8.0 install stop this demo from running at all. Three more are optional,
and are what turn a trace you can look at into a reasoning chain you can follow end to end. All five
are in `plugin/`, installed editable by the setup scripts.

**`a2a_client` cannot be used by a `react_agent`.** nat registers it with
`register_per_user_function_group`, and per-user groups are deliberately skipped during eager
construction (`workflow_builder.py:1455`) to be built later by `PerUserWorkflowBuilder`. A
`react_agent` workflow is shared, so it is built eagerly and its `get_tools()` call cannot see the
group, which surfaces as the fairly unhelpful::

    ValueError: Function `researcher` not found in list of functions

nat has a clearer error for the real problem, "Shared Workflow depends on per-user function_group"
(`workflow_builder.py:1608`), but you never reach it, because `tool_names` is typed
`list[FunctionRef | FunctionGroupRef]` and a plain YAML string always resolves to `FunctionRef`.
There is no YAML-level fix. `plugin/` re-registers the same implementation as a *shared* group named
`a2a_client_shared`, and rejects `auth_provider` rather than sharing one user's credentials.

**`wiki_search` fails every time.** It goes through langchain's `WikipediaLoader`, which uses the
`wikipedia` package (1.4.0, last released 2014) and sends no descriptive User-Agent. Wikimedia now
enforces its UA policy and answers with `HTTP 403` and a plain-text body
(https://phabricator.wikimedia.org/T400119), which the library tries to parse as JSON::

    json.decoder.JSONDecodeError: Expecting value: line 1 column 1 (char 0)

`plugin/` calls `wikipedia.set_user_agent()` once at import. Set `WIKIPEDIA_USER_AGENT` to identify
yourself properly.

The remaining three are optional. Each can be disabled on its own, so you can show the stock
behaviour and then turn the fix on.

**LLM spans, prompts and token counts** (`llm_spans.py`). Attaches nat's `LangchainProfilerHandler`
to every langchain callback manager, which is what `framework_wrappers` was apparently meant to do
and never did. Without it every span is `spanKind: chain` with no prompt and no tokens, so you can
see that the planner delegated but not why. Applies to `chain.yml` as much as to act two.
`NAT_DEMO_NO_LLM_SPANS=1` turns it off.

**Trace context across the A2A hop** (`trace_propagation.py`). Injects a `traceparent` on the client
and reads it back on the server, which puts both agents in one trace. Act two only.
`NAT_DEMO_NO_TRACE_PROPAGATION=1` turns it off.

**Relaying the remote agent's steps** (`a2a_step_relay.py`). The researcher returns its intermediate
steps on the A2A response; the planner re-parents them onto its own call span and replays them
through `push_intermediate_steps`. This is what actually produces one tree rather than one trace with
two roots, and it is the piece that makes the remote agent's reasoning visible in the caller's trace.
Act two only. `NAT_DEMO_NO_STEP_RELAY=1` turns it off.

## Files

| File | What it is |
|---|---|
| `configs/researcher.yml` | **The demo, agent B.** `front_end: a2a` on :9002, `wiki_search` tool |
| `configs/planner.yml` | **The demo, agent A.** `a2a_client_shared` function group pointed at :9002 |
| `configs/chain.yml` | The simpler variant, and the fallback. Both agents in one process |
| `configs/planner-ui.yml` | The planner served over HTTP, for driving it from a browser UI |
| `configs/model-only.yml` | Scene 1: the bare model, no tools, so the cold open runs in the same UI |
| `plugin/` | Five shims: two the demo cannot run without on 1.8.0, three optional. See below |
| `docs/` | What we learned about nat 1.8.0 the hard way, with file:line receipts |
| `screenshots/` | A full rehearsal, one capture per scene of the demo script |
| `demo-script.md` | Presenter script for the conference demo |
| `docker-compose.yml` | Phoenix, UI and OTLP collector on 6006 |
| `scripts/setup.sh` | Setup for Ubuntu, Debian, WSL2, macOS |
| `scripts/setup.ps1` | Setup for Windows PowerShell |
| `.env.example` | Template for `NVIDIA_API_KEY` |

## Notes for presenting

The full presenter script is in [demo-script.md](demo-script.md), and it has a **reliability section
you should read before committing to the live two-process version**. The essentials:

- Send one warm-up request first. The first call to a NIM endpoint can take a long time while the
  model spins up, and it reads as a broken demo.
- A run takes 12 seconds to two minutes depending on how many searches the researcher needs. Talk
  over it rather than watching it.
- Wipe Phoenix before you present: `docker compose down -v && docker compose up -d`. Plain
  `docker compose down` keeps the volume.
- Bake the "without the fix" trace *before* you go on, with the two `NAT_DEMO_NO_*` variables set, so
  the broken pair is already in the trace list and you never run the demo twice on stage.
- The demo is driven from the NeMo Agent Toolkit UI. With
  `NEXT_PUBLIC_NAT_ENABLE_INTERMEDIATE_STEPS=true` the chat window shows the *remote* agent's
  reasoning inline, because the step relay replays it into the caller's stream — so the chain is
  visible before you ever open Phoenix.
- Ask the model your question a few times beforehand so you know what it is doing that day. Its
  unaided answer is not stable, and the opening depends on knowing that.
- Keep the rehearsal trace in Phoenix as a fallback, and `configs/chain.yml` ready as a more reliable
  substitute.
- The researcher binds to `127.0.0.1`, and that is not cosmetic. The agent card advertises whatever
  `host` is set to and the A2A client dials that address, so `0.0.0.0` makes the planner fail with
  `503 All connection attempts failed` on Windows.
- **The failure mode to rehearse:** measured over nine runs, seven answered correctly and two failed
  with the planner printing its tool call instead of making it — an answer in ~1.4 seconds that looks
  like `{ "action": "researcher__call", ... }`. The tell in every failure is *speed*: a real run takes
  12 seconds or more and the researcher's terminal visibly works.
