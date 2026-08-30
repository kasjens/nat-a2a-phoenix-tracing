# Tracing one agent handing work to another

A planner agent delegates a lookup to a researcher agent, the researcher searches Wikipedia, and
the answer comes back up the chain. Everything exports to a local Phoenix instance, where the whole
handoff shows up as one tree you can follow end to end.

Then the same two agents are split across a network with the A2A protocol, and that single tree
falls apart. That contrast is the second half of the demo.

Verified against `nvidia-nat` 1.8.0 (August 2026), which is the latest release. All three config
files pass `nat validate` and have been run end to end.

## What you need

- Python 3.11 or newer
- Docker, for Phoenix
- An API key from [build.nvidia.com](https://build.nvidia.com), free tier is enough

No GPU. The model runs on NVIDIA's hosted NIM endpoint.

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
`nvidia-nat[phoenix,langchain,a2a]==1.8.0` and the local `plugin/` package, starts Phoenix, and
validates both configs. It is safe to re-run. Missing pieces produce a warning rather than a stop,
so one pass shows you everything that needs fixing.

## Run

One command, one process, two agents:

```bash
nat run --config_file configs/chain.yml \
  --input "In which year did Computerworld publish its final print issue? Ask the researcher."
```

Activate the venv first: `source .venv/bin/activate` on Linux and macOS,
`.\.venv\Scripts\Activate.ps1` on Windows.

Open http://localhost:6006, project `a2a-demo`, and click the trace. You get:

```
planner                 <- agent A, the root span
  <workflow>            <- nat's entry-function wrapper, not an agent
    researcher          <- agent B, named after its key in configs/chain.yml
      wiki_search
      wiki_search
```

Ask the model this on its own and it says **2015**, confidently and wrongly. The chain answers
**2014**, because the researcher actually looked it up. That is the point of the demo in one
question: pick something the model thinks it knows and gets wrong, so the handoff visibly earns its
keep instead of merely happening.

Read **down** the tree for the request path, and each span's **Output** back **up** for the
response path. The answer condenses at every handoff: `wiki_search` returns raw Wikipedia
documents, `researcher` returns a sentence, `planner` returns the short answer the user asked for.

To see who handed work to whom in words rather than by nesting, open a span's **Attributes** tab:
`nat.function.name` is the agent the span belongs to, and `nat.function.parent_name` is the agent
that called it.

Roughly three and a half minutes end to end, most of it the researcher's own loop.

### Act two: the same agents, over a network

Now split them across a process boundary and watch the chain break. Terminal 1, the researcher,
served as an A2A agent on port 9002:

```bash
nat start a2a --config_file configs/researcher.yml
```

Activate the venv in each terminal first: `source .venv/bin/activate` on Linux and macOS,
`.\.venv\Scripts\Activate.ps1` on Windows.

Check the agent card is up:

```bash
curl -s http://localhost:9002/.well-known/agent-card.json     # bash
irm http://localhost:9002/.well-known/agent-card.json         # PowerShell
```

Terminal 2, the planner:

```bash
nat run --config_file configs/planner.yml \
  --input "Which company makes the H100, and when was it announced? Use the researcher for facts."
```

Phoenix UI: http://localhost:6006, project `a2a-demo`.

## What to look at

**Beat 1 — the handoff, traced end to end.** `configs/chain.yml`, the tree above. One agent calls
another, and you can follow the request down and the answer back up without leaving the trace. This
is what tracing gives you that logging does not: not more detail, structure. A log file has the same
events in it, flat, in time order.

One caveat, because it is easy to promise more than Phoenix shows. **There are no LLM spans and no
token counts.** Every span nat emits on this path is `spanKind: chain` with a null token count. nat
*has* an `LLM` span kind and maps `LLM_START` to it, but the component that emits those events,
`LangchainProfilerHandler`, is only attached in
`nat/plugins/langchain/control_flow/sequential_executor.py`, and the `react_agent` path never
attaches it. Show nesting, latency and outputs. Do not promise prompts or cost.

**Beat 2 — the same handoff, over A2A, in pieces.** Run act two above and look at the trace list.

## The A2A beats

**Beat 2 — the gap at the process boundary.**
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
  `Request` (`session.py:497`), but the A2A adapter calls `session()` with no HTTP request at all
  (`nat/plugins/a2a/server/agent_executor_adapter.py:107`), so the parsing above never runs on this
  path.

So the plumbing exists at the runtime layer and is simply not wired up in the A2A transport. Verified
against 1.8.0, which is the latest release.

Say this out loud in the video. It is the most useful thing in the demo, it is current, and most
people assume OpenTelemetry underneath means it just works.

**Can you fix it?** Mostly, yes, and `plugin/` does. It injects a `traceparent` on the A2A client
and reads it back on the server, which is the two-line gap described above. Measured against a wiped
Phoenix volume:

| | traces | trace ids | root spans |
|---|---|---|---|
| stock 1.8.0 | 2 | 2 | 2 |
| with `plugin/` | **1** | **1** | 2 |

So the hop is linked and both agents land in one trace. What you still do not get is the researcher
nested under the planner's `researcher__call` span, and that part is not another header. nat resolves
parentage through an in-process dictionary: `span_exporter` looks the parent up in its local
`_span_stack` and, on a miss, logs "No parent span found" and drops the span. Handing it a parent id
minted in the other process would delete the researcher's root span rather than reparent it. Real
cross-process nesting needs a change inside `span_exporter`.

Set `NAT_DEMO_NO_TRACE_PROPAGATION=1` to turn the fix off and get the original two-trace behaviour,
which is what you want while recording beat 2.

**Beat 3 — looping inefficiency.**
Ask for something Wikipedia cannot answer:

```bash
nat run --config_file configs/planner.yml \
  --input "What was Aeven's revenue in 2026? Use the researcher."
```

The researcher's ReAct loop re-queries with rephrased arguments until `max_tool_calls` stops it.
Every span is green. No errors, no timeouts, a plausible final answer. The failure is only visible
as repeated sibling spans under one parent, which is exactly what a log line per tool call hides:
several successes.

Do not reach for "and every round cost tokens" here. As above, nat emits no token counts on this
path, so the cost argument is one you can make in words but cannot show on screen.

## Why `plugin/` exists

Two things in the stock 1.8.0 install stop this demo from running at all. Both fixes are small and
both are in `plugin/`, installed editable by the setup scripts.

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

## Files

| File | What it is |
|---|---|
| `configs/chain.yml` | **The main demo.** Both agents in one process, traced as one chain |
| `configs/researcher.yml` | Act two, agent B. `front_end: a2a` on :9002, `wiki_search` tool |
| `configs/planner.yml` | Act two, agent A. `a2a_client_shared` function group pointed at :9002 |
| `plugin/` | Two compatibility shims the demo cannot run without on 1.8.0. See below |
| `docker-compose.yml` | Phoenix, UI and OTLP collector on 6006 |
| `scripts/setup.sh` | Setup for Ubuntu, Debian, WSL2, macOS |
| `scripts/setup.ps1` | Setup for Windows PowerShell |
| `.env.example` | Template for `NVIDIA_API_KEY` |

## Notes for recording

- Send one warm-up request before you hit record. The first call to a NIM endpoint can take a long
  time while the model spins up, and it reads as a broken demo.
- A full beat 1 run takes roughly three and a half minutes end to end, most of it the researcher's
  own ReAct loop. Plan the edit around that, or start the run and cut away to the config files.
- The researcher binds to `127.0.0.1`, and that is not cosmetic. The agent card advertises whatever
  `host` is set to, and the A2A client dials that address, so `0.0.0.0` makes the planner fail with
  `503 All connection attempts failed` on Windows. Leaving it on localhost also drops nat's
  bind-without-auth warning, so nothing extra appears on camera.
- Phoenix keeps traces in the named volume, so `docker compose down` between takes is safe but
  `docker compose down -v` wipes them.
- If you want a clean project per take, change `project:` in both configs.
