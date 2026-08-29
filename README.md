# NAT + A2A + Phoenix tracing sandbox

A two-agent demo you can record in about six minutes. A planner agent calls a researcher agent
over the A2A protocol. Both export traces to a local Phoenix instance.

The point of the demo is what Phoenix shows you, and what it does not.

Verified against `nvidia-nat` 1.8.0 (August 2026). Both config files pass `nat validate`.

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
`nvidia-nat[phoenix,langchain,a2a]==1.8.0`, starts Phoenix, and validates both configs. It is safe
to re-run. Missing pieces produce a warning rather than a stop, so one pass shows you everything
that needs fixing.

## Run

Terminal 1, the researcher, served as an A2A agent on port 9002:

```bash
nat start --config_file configs/researcher.yml
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

## The three beats

**Beat 1 — the span tree inside one agent.**
Open the researcher's trace. You get the ReAct loop as nested spans: the agent span at the root,
an LLM span for each reasoning turn, a tool span for each `wiki_search` call, with token counts and
latency on each. This is the thing per-component logging cannot give you, because the structure is
the information.

**Beat 2 — the gap at the process boundary.**
You will see two separate root traces at the same timestamp, one for the planner and one for the
researcher, with no parent-child link between them. Nothing in Phoenix tells you the researcher's
nine seconds were caused by the planner's request.

This is not a misconfiguration. As of `nvidia-nat-a2a` 1.8.0 there is no W3C trace context
propagation in the A2A client or server, and NAT generates a fresh trace ID per workflow run
(`nat/data_models/span.py`, `SpanContext.trace_id`). Distributed tracing across an A2A hop needs the
`traceparent` header injected on the client and extracted on the server, and NAT does not do it yet.

Say this out loud in the video. It is the most useful thing in the demo, it is current, and most
people assume OpenTelemetry underneath means it just works.

**Beat 3 — looping inefficiency.**
Ask for something Wikipedia cannot answer:

```bash
nat run --config_file configs/planner.yml \
  --input "What was Aeven's revenue in 2026? Use the researcher."
```

The researcher's ReAct loop re-queries with rephrased arguments until `max_tool_calls` stops it.
Every span is green. No errors, no timeouts, a plausible final answer. The failure is only visible
as repeated sibling spans under one parent, which is exactly what a log line per tool call hides:
six successes.

## Files

| File | What it is |
|---|---|
| `configs/researcher.yml` | Agent B. `front_end: a2a` on :9002, `wiki_search` tool, Phoenix exporter |
| `configs/planner.yml` | Agent A. `a2a_client` function group pointed at :9002, Phoenix exporter |
| `docker-compose.yml` | Phoenix, UI and OTLP collector on 6006 |
| `scripts/setup.sh` | Setup for Ubuntu, Debian, WSL2, macOS |
| `scripts/setup.ps1` | Setup for Windows PowerShell |
| `.env.example` | Template for `NVIDIA_API_KEY` |

## Notes for recording

- Send one warm-up request before you hit record. First call to the NIM endpoint is slow and it
  reads as a broken demo.
- The researcher binds to `0.0.0.0` and NAT prints an auth warning at startup. Change `host` to
  `127.0.0.1` if you would rather it did not appear on camera.
- Phoenix keeps traces in the named volume, so `docker compose down` between takes is safe but
  `docker compose down -v` wipes them.
- If you want a clean project per take, change `project:` in both configs.
