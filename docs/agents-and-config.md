# Agents, function groups and config

## `nat validate` does not mean it runs

`nat validate` checks that the YAML matches the config schemas. It does not resolve `tool_names`,
build function groups, or check that anything can actually reach anything else.

Both of these validate cleanly and then fail at startup:

```
ValueError: Function `researcher` not found in list of functions
```

**Measured.** Treat `nat validate` as a syntax check. The real test is `nat run`.

---

## `nat start` needs a subcommand

```bash
nat start --config_file configs/researcher.yml       # Error: No such option '--config_file'
nat start a2a --config_file configs/researcher.yml   # correct
```

`nat start` dispatches to a front end: `a2a`, `console`, or `fastapi`. The `--config_file` option
belongs to the subcommand, not to `start`. `nat run` takes `--config_file` directly, which makes the
inconsistency easy to trip over.

**Measured.**

---

## One agent calling another, in one process

This is the arrangement that works well and traces cleanly. A `react_agent` is registered as an
ordinary function, so it can be listed under `functions:` and handed to another agent as a tool:

```yaml
functions:
  wiki_search:
    _type: wiki_search

  researcher:                 # <- this key becomes the span name in Phoenix
    _type: react_agent
    llm_name: nim_llm
    tool_names: [wiki_search]
    description: >-
      Authoritative lookup for any question of fact...

workflow:
  _type: react_agent
  name: planner               # <- names the root span
  llm_name: nim_llm
  tool_names: [researcher]
```

Phoenix draws this as one tree with one root. See [tracing.md](tracing.md).

**Measured**: 1 trace, 1 root, spans `planner` → `<workflow>` → `researcher` → `wiki_search`.

---

## `a2a_client` cannot be used by a `react_agent`

This one costs an afternoon if you do not know it.

`a2a_client` is registered with `@register_per_user_function_group`
(`nat/plugins/a2a/client/client_impl.py:311`). Per-user function groups are **deliberately skipped**
during eager construction, to be built later by `PerUserWorkflowBuilder`:

```python
# nat/builder/workflow_builder.py:1455
if registration.is_per_user:
    # Skip per-user function groups as they will be built lazily by PerUserWorkflowBuilder
    continue
```

A `react_agent` workflow is *shared*, not per-user, so it is built eagerly. By the time it calls
`get_tools()` the group does not exist, and you get:

```
ValueError: Function `researcher` not found in list of functions
```

which does not mention function groups at all.

There is a much clearer error for the real situation:

```python
# nat/builder/workflow_builder.py:1608
raise ValueError(f"Shared Workflow depends on per-user function_group `{dep_fg_name}`")
```

You never reach it, because of the next gotcha.

**Whether the workflow is per-user is decided by the workflow's own registration**
(`nat/runtime/session.py:231`), so there is no config switch to turn this on.

**Measured**, from both directions: as a plain string, and with the ref coerced to a real
`FunctionGroupRef`.

### The workaround

Re-register the same implementation as a *shared* group under a new type name. See
[`plugin/nat_demo_shims/a2a_shared.py`](../plugin/nat_demo_shims/a2a_shared.py). Roughly:

```python
class A2AClientSharedConfig(A2AClientConfig, name="a2a_client_shared"):
    pass

@register_function_group(config_type=A2AClientSharedConfig)
async def a2a_client_shared_function_group(config, builder):
    async with A2AClientFunctionGroup(config, builder) as group:
        yield group
```

Two caveats. Per-user registration exists so each user gets a client bound to their own credentials,
so only do this against an unauthenticated agent — the shim rejects `auth_provider` rather than
sharing one user's token with everyone. And `A2AClientFunctionGroup.__aenter__` requires a `user_id`
in context; for an unauthenticated agent that value only reaches a log line, so a synthetic one is
enough.

---

## `tool_names` always resolves a YAML string to `FunctionRef`

```python
# nat/plugins/langchain/agent/react_agent/register.py:50
tool_names: list[FunctionRef | FunctionGroupRef]
```

Both are `str` subclasses, so a plain YAML string is coerced to the left arm of the union every
time:

```
'researcher'  type=FunctionRef  group=functions
```

even when `researcher` is declared under `function_groups:`. The dependency graph is built from the
runtime type of the value (`nat/builder/component_utils.py:163`), so it registers a dependency on a
*function* that does not exist, and the group is never scheduled.

**Measured**, by loading the config and inspecting the resolved types.

---

## Tool call budget also sets the recursion limit

`max_tool_calls` does more than cap tool calls:

```python
# nat/plugins/langchain/agent/react_agent/register.py:163
config={'recursion_limit': (config.max_tool_calls + 1) * 2}
```

So `max_tool_calls: 4` gives langgraph a recursion limit of 10. A single wasted turn — a malformed
tool call, a parse retry — can exhaust it, and you get:

```
Recursion limit of 10 reached without hitting a stop condition.
```

which reads like a runaway loop but is often just a tight budget. Give the calling agent headroom.

**Measured.**

---

## Getting one agent to actually delegate

The calling agent will answer from its own knowledge if it thinks it can, and then the handoff never
happens. You get a two-span trace and no delegation at all.

**What does not work:** `additional_instructions` on the calling agent. Three attempts, three
different failures, all measured:

| Instruction | Failure |
|---|---|
| "You never answer from your own knowledge…" | `Parsing LLM output produced both a final answer and a parse-able action` |
| "Always use the researcher tool…" | Delegated, then `Recursion limit of 10 reached` |
| plus "call it with a single input_message string…" | Returned the tool-call JSON as the final answer |

Returning the tool call as the answer is not only a bad-instruction failure — it also happens
spontaneously. Measured over nine otherwise-identical A2A runs with instructions that work: seven
delegated correctly, two printed `{"action": "researcher__call", ...}` as the final answer in about
1.4 seconds without ever calling anything. There is no fix here beyond retrying; budget for it.

Instructions on the calling agent compete with the ReAct prompt template, and the model ends up
negotiating with the format instead of following it.

**What works:**

1. **Strengthen the callee's `description`.** That is what the caller reads when deciding whether to
   delegate, and it is not part of the ReAct scaffolding, so it does not fight it.
2. **Ask something the model cannot answer from memory.** If it thinks it knows, it will answer.

**Measured.**

### The callee gives up after one search

Delegation working is not the same as the answer being right. A separate failure, measured on 3 of 5
runs over A2A: the researcher ran a single `wiki_search`, did not find the fact, and answered "not
available" — with a perfect trace showing exactly that.

The cause was its own instructions. `additional_instructions` ended with "If the searches return
nothing useful, say so plainly", which reads as permission to stop after one attempt. The first query
is usually the user's question verbatim, and a Wikipedia *article title* rarely matches a question.

The fix is to make a second attempt mandatory before it may conclude anything, and to tell it to
search for the likely article title rather than the question:

```yaml
additional_instructions: >-
  ... Search for the most likely Wikipedia article *title* rather than the question ...
  If your first search does not contain the fact, you must try at least one more search
  with different wording before concluding anything.
```

**Measured**: after the change, the researcher searched `Computerworld` directly and answered
correctly on the first try, and the whole run dropped from 33s to 12s.

The general lesson is that an escape hatch in an agent's instructions will be taken at the first
opportunity. If you give it a way to say "I could not find it", say how hard it has to try first.

### The nested agent's input schema

A `react_agent` used as a tool accepts `messages` *or* `input_message`, not both. Callers sometimes
send both and burn a turn on:

```
Either messages or input_message must be provided, not both
```

Worth knowing when you are budgeting `max_tool_calls`.

---

## Custom component types need a real package

There is no "import this module" hook in the config. `general:` has no such field. Plugins are
discovered through the `nat.components` / `nat.plugins` entry point groups
(`nat/runtime/loader.py:140`), so a custom `_type` means a `pyproject.toml` and a
`pip install -e .`. See [`plugin/`](../plugin/).

---

## Unknown config keys are forwarded to the client

`NIMModelConfig` is declared `extra="allow"`
(`nat/llm/nim_llm.py:37`), and the langchain client splats the whole config into the constructor:

```python
# nat/plugins/langchain/llm.py:206
client = ChatNVIDIA(**llm_config.model_dump(...))
```

So any key you add in YAML reaches `ChatNVIDIA` as a keyword argument. That is the escape hatch for
model-specific parameters nat does not model explicitly:

```yaml
llms:
  nim_llm:
    _type: nim
    model_name: ...
    chat_template_kwargs:      # not a nat field; forwarded as-is
      enable_thinking: false
```

**Measured** — it validates and reaches the model. Whether the model does anything useful with it is
a separate question; see [models.md](models.md).


---

## An A2A error response discards the message body

Worth knowing if you ever attach anything to an A2A response. The nat adapter's error path does this
(`nat/plugins/a2a/server/agent_executor_adapter.py`):

```python
except Exception as e:
    error_message = new_agent_text_message(f"An error occurred ...")
    await event_queue.enqueue_event(error_message)
    raise ServerError(error=InternalError()) from e
```

It enqueues a `Message` and *then* raises. The JSON-RPC layer turns the raised `ServerError` into an
error response, so the message it just enqueued — and anything you put on its `metadata` — never
reaches the caller. What the client sees is:

```
a2a.client.errors.A2AClientJSONRPCError: JSON-RPC Error code=-32603 message='Internal error'
```

`InternalError` does have a `data` field, and the adapter leaves it empty, so that is the one place
on the error path where a payload survives the trip. `plugin/nat_demo_shims/a2a_step_relay.py` uses
it to get the failed call's telemetry home.

**Measured**, on a run where the researcher's ReAct loop failed: 47 steps were attached to the
message and none of them arrived.
