# Choosing a model that can drive a ReAct agent

The single biggest time sink in this project. Model choice is not a tuning detail here — most models
cannot run the agent at all, and they fail in ways that look like bugs in your config.

## Why it is fragile

nat's `react_agent` parses **plain text** in a `Thought:` / `Action:` / `Action Input:` format. Any
model whose output does not land in that shape, in the `content` field, breaks the agent.

Reasoning models are the main hazard. Several put their turn in a separate `reasoning_content`
field and return an **empty `content`**, which surfaces as:

```
ReActAgentParsingFailedError: Failed to parse agent output after N attempts.
Error: Invalid Format: Missing 'Action:' after 'Thought:'. LLM output: ''
```

That message reads like a prompt problem. It is a model problem.

---

## Survey: 83 models, 18 usable, 9 that work

We probed the whole `build.nvidia.com` catalogue with a realistic ReAct prompt. Of 83 models listed,
**18 were entitled** on our key, and **9 produced correct `Thought:` / `Action:` output**:

| Model | Latency | Separate reasoning channel | ReAct format |
|---|---|---|---|
| `google/diffusiongemma-26b-a4b-it` | 2s | no | ✅ |
| `poolside/laguna-xs-2.1` | 3s | no | ✅ |
| `nvidia/nemotron-3-nano-30b-a3b` | 3s | yes | ✅ |
| `nvidia/nemotron-3-nano-omni-30b-a3b-reasoning` | 3s | yes | ✅ |
| `nvidia/nemotron-3.5-lightning-30b-a3b` | 5s | yes | ✅ |
| `openai/gpt-oss-120b` | 8s | yes | ✅ |
| `meta/llama-3.2-11b-vision-instruct` | 14s | no | ✅ |
| `meta/muse-glimmer-30b` | 15s | yes | ✅ |
| `minimaxai/minimax-m3` | 18s | no | ✅ |

Failing the format:

| Model | How it fails |
|---|---|
| `openai/gpt-oss-20b` | empty `content` → `ReActAgentParsingFailedError` |
| `nvidia/nemotron-3-super-120b-a12b` | answers with bare JSON, not `Thought:`/`Action:` |
| `nvidia/nemotron-3-ultra-550b-a55b` | same |
| `meta/llama-3.3-70b-instruct` | **retired — HTTP 410 Gone** |

The rest of the 18 are safety, translation or embedding models that are not chat agents.

**Measured.** The probe script pattern is in this repo's history; it is ~40 lines and worth
re-running when you change models, because it takes two minutes and saves hours.

---

## A single probe is not enough

Two models passed the one-shot probe and still failed in the real agent:

- **`poolside/laguna-xs-2.1`** — 3s in the probe, then `Timeout on reading data from socket` under
  the agent's much larger prompt. It is a coding model.
- **`moonshotai/kimi-k3`** — fast (4s) and produced *perfect* ReAct output with correct tool
  arguments on one run, then returned empty completions three times in a row on the next.
  Intermittent, which is worse than consistently broken.

Probe to eliminate candidates. Confirm with a real end-to-end run before committing.

**Measured.**

---

## Latency is not what the playground says

`build.nvidia.com`'s playground shows time-to-answer for a warm, short prompt. That is not what you
will see:

- `deepseek-ai/deepseek-v4-pro-0813` — playground 14s, **API 92-120s warm**
- `deepseek-ai/deepseek-v4-flash-0731` — never responded at all (HTTP 000 after 120s and 240s)

Some models are also listed in `/v1/models` but return **404** for your account. Listed ≠ entitled.

Measure with your own key, against a realistic prompt.

---

## `max_tokens` needs headroom

Reasoning models spend part of the budget before emitting anything. At `max_tokens: 1024`,
`gpt-oss-20b` returned an empty completion. Leave room:

```yaml
max_tokens: 4096
```

This does not rescue a model that puts everything in `reasoning_content`, but it removes one
variable.

---

## The `thinking` switch is narrower than it looks

`NIMModelConfig` has a `thinking: bool | None` field, but it is gated to Nemotron models by regex:

```python
# nat/data_models/thinking_mixin.py:24
_NEMOTRON_REGEX = re.compile(r"^nvidia/(llama|nvidia).*nemotron", re.IGNORECASE)
```

Note what that matches: `nvidia/llama…nemotron` and `nvidia/nvidia…nemotron`. It does **not** match
`nvidia/nemotron-3-…`, so most of the Nemotron 3 line is rejected:

```
ValueError: Invalid configuration: llms: Value error, thinking is not supported for
model_name: moonshotai/kimi-k3
```

For anything else, use the passthrough described in
[agents-and-config.md](agents-and-config.md#unknown-config-keys-are-forwarded-to-the-client):

```yaml
chat_template_kwargs:
  enable_thinking: false
```

**But test whether you want it off.** On `nemotron-3.5-lightning`, disabling reasoning stopped the
agent converging — it looped to `max_tool_calls` on every request instead of answering. With
reasoning on it converged in one search. The reasoning was doing useful work.

**Measured**, both directions.

---

## What we settled on

`nvidia/nemotron-3-nano-omni-30b-a3b-reasoning`, reasoning left on.

It emits clean ReAct text, returns a final answer with no reasoning preamble leaking into it, and
completes a two-agent chain in roughly two minutes. It was not the fastest candidate, but it was the
one that finished reliably.

Two runners-up worth knowing about:

- `openai/gpt-oss-120b` works but is slow enough that it tripped the A2A `task_timeout` at 120s.
- `nvidia/nemotron-3.5-lightning-30b-a3b` is faster and converges, but leaks
  `"Here's a thinking process:"` into the final answer.

---

## Models are confidently wrong about specifics

Useful for demos, and worth knowing generally. Asked directly, our model gave:

| Question | Model | Reality |
|---|---|---|
| LUMI supercomputer CPU cores | 67,584 | 362,496 |
| Computerworld final print issue | 2013 / 2014 / 2015, varying per run | 2014 |

It described LUMI accurately in general terms — EuroHPC, CSC, Kajaani — and then invented the core
count. General knowledge is solid; precise figures are not, and the confidence is identical either
way.

For a demo, that instability is more useful than a single wrong answer: ask three times, get three
answers, and the point makes itself.
