# Tracing and observability

What Phoenix actually shows you when nat is driving, which is not quite what you would assume.

## There are no LLM spans and no token counts

This is the one most likely to embarrass you in front of an audience.

On the `react_agent` path, **every span nat emits is `spanKind: chain` with a null token count**.
Measured across a whole project: 85 spans, all `chain`, every `tokenCountTotal` null or zero, and
`Total Cost $0` on every trace.

So you cannot:

- click an LLM span and show the prompt and completion
- show tokens per reasoning turn
- make a cost argument by pointing at the screen

nat is not missing the concept. `SpanKind.LLM` exists (`nat/data_models/span.py:35`) and
`LLM_START` maps to it (`nat/data_models/span.py:52`). The component that emits those events,
`LangchainProfilerHandler`, is only attached in one place:

```
nat/plugins/langchain/control_flow/sequential_executor.py:147
    profiler_config = {'callbacks': [LangchainProfilerHandler()]}
```

The `react_agent` path never attaches it. `react_agent` does declare
`framework_wrappers=[LLMFrameworkEnum.LANGCHAIN]`, but we could not find anything that consumes that
to install the handler.

**Measured** for the absence of spans and tokens. **Read from source** for the cause.

What you *can* show: nesting, latency per step, and each span's input and output.

---

## What you can show

For a two-agent chain in one process:

```
planner              -> 2014
  <workflow>         -> 2014
    researcher       -> 2014
      wiki_search    -> <Document source=".../Year_2000_problem"/> ...
      wiki_search    -> <Document source=".../Computerworld"/> ...
```

- **Down** the tree is the request path.
- **Up** the `Output` fields is the response path. There is no separate "return" span; a span's
  Output *is* what that agent handed back, and the span closing is the return.

The answer visibly condenses at each handoff: raw documents, then a sentence, then the year.

---

## Naming spans

**The root span** takes `name` from the workflow config:

```yaml
workflow:
  _type: react_agent
  name: planner
```

`display_name = config.name or instance_name` (`nat/builder/function.py:78`), and the runner
attaches that to the workflow events (`nat/runtime/runner.py:211`).

**Nested agents and tools** are named by their key under `functions:`. `researcher:` shows up as
`researcher`. This is the cheapest readability win available — name your agents for whoever is
reading the trace.

**The `<workflow>` row cannot be renamed.** It sits between the root and your first agent. It is the
entry *function* span, and its name comes from the instance name, which for the top-level workflow is
the literal placeholder `<workflow>`. No display name is attached to it, so config cannot override
it. It has no content of its own — its Output is identical to the root's — so it is safe to read
past.

**Measured**, including confirming that `name:` renames the root and not the wrapper.

---

## Working out which agent did what

Two ways.

**Structurally** — the nesting is the attribution. `wiki_search` under `researcher` means the
researcher made those calls.

**Explicitly** — every span carries these, in Phoenix's **Attributes** tab:

| Attribute | Meaning |
|---|---|
| `nat.function.name` | which agent or tool this span is |
| `nat.function.parent_name` | **which agent handed it the work** |
| `nat.function.id` / `nat.function.parent_id` | the same, as UUIDs |
| `nat.span.kind` | `WORKFLOW` / `FUNCTION` |
| `nat.workflow.trace_id` | the workflow's trace id |

Read the `parent_name` chain and you get the handoff in words:

```
researcher    parent_name = <workflow>
wiki_search   parent_name = researcher
```

Note the friendly name only lands on the root, so a child of the planner reports `<workflow>` rather
than `planner`.

---

## Trace context does not cross an A2A hop

Out of the box, a planner calling a researcher over A2A produces **two traces, two trace ids, two
roots**, with nothing linking them. Phoenix cannot tell you the researcher's work was caused by the
planner's request.

The usual framing — "nat has no trace context propagation" — is wrong, and it is worth being precise
because it is the kind of claim people check.

**nat already has the receiving half:**

- `nat/runtime/session.py:643` parses a W3C `traceparent` header and sets `workflow_trace_id`
- `nat/runtime/runner.py:185` is `workflow_trace_id = existing_trace_id or uuid.uuid4().int`, so a
  workflow **inherits** an incoming trace id rather than always minting a fresh one
- there are even cross-workflow headers: `workflow-trace-id`, `workflow-parent-id`,
  `workflow-parent-name`

**What is missing is the two ends of the wire:**

- **No inject.** The A2A client builds a bare `httpx.AsyncClient`
  (`nat/plugins/a2a/client/client_base.py:87`) and never sets the header.
- **No extract.** `set_metadata_from_http_request()` only runs for a Starlette `Request`
  (`nat/runtime/session.py:496`), and the A2A adapter calls `session()` with no arguments
  (`nat/plugins/a2a/server/agent_executor_adapter.py:107`). The parsing exists and is never reached.

**Measured.**

### Closing it, and where that stops working

You can supply both ends from a shim — see
[`plugin/nat_demo_shims/trace_propagation.py`](../plugin/nat_demo_shims/trace_propagation.py).
Helpfully, the a2a-sdk already stores the incoming headers on the call context
(`a2a/server/apps/jsonrpc/jsonrpc_app.py:153`: `state['headers'] = dict(request.headers)`), so the
server side needs no ASGI middleware — the header is sitting there unread.

Measured, against a wiped Phoenix volume:

| | traces | trace ids | root spans |
|---|---|---|---|
| stock 1.8.0 | 2 | 2 | 2 |
| with the shim | **1** | **1** | 2 |

So the hop gets linked and both agents land in one trace. **You still do not get the researcher
nested under the planner's call span.**

That last step is not another header. nat resolves span parentage through an in-process dictionary:

```python
# nat/observability/exporter/span_exporter.py:138-142
parent_span = self._span_stack.get(event.parent_id, None)
if parent_span is None:
    logger.warning("No parent span found for step %s", event.UUID)
    return          # <- the span is dropped
```

`runner.py:124` will happily set the root step's parent to `workflow_parent_id` if you provide one,
and nat parses a `workflow-parent-id` header for exactly this purpose — but a parent id minted in
the caller's process is not in the callee's span stack, so feeding one across the wire would
**delete** the callee's root span rather than reparent it. Real cross-process nesting needs a change
inside `span_exporter`.

**Measured** for the one-trace result. **Read from source** for why nesting does not follow.

### Practical consequence

If you need to follow a chain end to end, compose agents **in one process**. Across a process
boundary you can get them into the same trace, but not into the same tree.

---

## Phoenix, practically

- Project list → your project → tabs **Spans / Traces / Sessions / Metrics / Config**
- **Traces** tab: one row per trace. This is where you count roots, and it is the clearest way to
  show linkage or the lack of it.
- **Spans** tab defaults to a `parent_id is None` filter, which is roots-only — useful for showing
  "still two roots" precisely.
- Clicking a trace opens the span tree with **Info** (input/output) and **Attributes** per span.
- The GraphQL API at `/graphql` is far easier than the UI for checking structure in scripts:

```bash
curl -s -X POST http://localhost:6006/graphql -H "Content-Type: application/json" \
  -d '{"query":"{ projects { edges { node { name traceCount } } } }"}'
```

- Wipe between runs with `docker compose down -v && docker compose up -d`. Trace counts are only
  meaningful against a clean project.
- The exporter batches, so give it a few seconds before concluding nothing arrived.
