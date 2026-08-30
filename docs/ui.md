# Driving nat from the NeMo Agent Toolkit UI

The demo is presented through a chat window rather than a terminal. The UI is a separate NVIDIA
project — [NeMo-Agent-Toolkit-UI](https://github.com/NVIDIA/NeMo-Agent-Toolkit-UI) — and is not part
of `nvidia-nat`. It is a Next.js app.

`scripts/setup.sh` fetches and configures it, into two directories: `ui/` pointed at the planner and
`ui-model-only/` pointed at the bare model. Both are gitignored. Start each with `npm run dev` from
its own directory. If node is not on your PATH the script says so and carries on — nothing else in
the repo needs it.

## It shows the *remote* agent's reasoning, which is the whole point

Set this in the UI's `.env`:

```
NEXT_PUBLIC_NAT_ENABLE_INTERMEDIATE_STEPS=true
```

and the chat window renders an **Intermediate Steps** panel that fills in while the agent works.
With the step relay loaded (see [tracing.md](tracing.md)) that panel contains the *researcher's* own
steps — its reasoning, its `wiki_search` call, its conclusion — nested inside the planner's call,
even though the researcher is a different process.

This is worth dwelling on, because it is not what the relay was built for. The relay replays remote
steps into the caller's **intermediate step stream**, and that stream is what the span exporter
consumes. The UI happens to subscribe to the same stream. So a fix aimed at Phoenix also makes the
remote agent's reasoning readable live, in the caller's chat window, before any tracing tool is
opened.

**Measured**: with the relay disabled, the panel shows only the planner's own steps and the
researcher's work is a result appearing from nowhere.

## One UI instance talks to exactly one backend

`NAT_BACKEND_URL` is read by the UI's gateway process at startup. There is no way to switch backends
from inside the running app.

The Settings dialog does have an **HTTP endpoint** selector, which is easy to mistake for one. It
only chooses among four fixed paths on the backend already configured (`constants/index.js`):

```
/chat/stream    /chat    /generate/stream    /generate
```

nat serves the same workflow on all four, so it does not let you reach a second workflow.

**Consequence:** showing two different workflows side by side needs **two UI instances**. That is
how Scene 1 of the demo works — the bare model on `:3001`, the planner on `:3000`, two browser tabs.
The setup script does this for you; the table is here so you know what it changed, and so you can
do it by hand if you are working from a UI checkout of your own. `node_modules` is symlinked on
Unix so the second instance costs nothing; the PowerShell script copies it instead, because
symlinks on Windows need Developer Mode or an elevated shell.

| Setting | First instance | Second |
|---|---|---|
| `NAT_BACKEND_URL` | `http://127.0.0.1:8001` | `http://127.0.0.1:8002` |
| `PORT` (the port you browse to) | 3000 | 3001 |
| `NEXT_INTERNAL_URL` | `http://localhost:3099` | `http://localhost:3098` |
| `dev:next` in `package.json` | `next dev -p 3099` | `next dev -p 3098` |

The internal Next port is not cosmetic: two `next dev` processes on the same port silently fight,
and the README of the UI warns not to browse the internal port directly.

## Port 8000 is a bad default

The fastapi front end defaults to `port: 8000`, which OnlyOffice Document Server and plenty of other
things also want. The clash is reported as an `AttributeError` about `_dask_client` — see
[agents-and-config.md](agents-and-config.md). This repo uses 8001 and 8002 for that reason.

Check before you start anything:

```bash
ss -ltn | grep -E ':(8001|8002|9002|3000|3001|6006)'
```

## CORS

The browser talks to the UI's own gateway, which proxies to nat server-side, so cross-origin rules
usually do not apply. The configs still set `cors.allow_origins` for the UI's port, because it costs
nothing and removes a confusing failure mode if you ever point the browser straight at nat.

## Small things that matter on stage

- **The microphone button sits immediately left of the send arrow.** Clicking the wrong one prompts
  for microphone access in front of the room. Send is the paper plane, on the far right.
- `NEXT_PUBLIC_*` variables are inlined by Next at build time. Changing one needs a restart of the
  UI process, and a hard reload in the browser.
- The greeting and placeholder text are configurable (`NEXT_PUBLIC_NAT_GREETING_TITLE`,
  `..._SUBTITLE`, `..._INPUT_PLACEHOLDER`). Naming the two instances "Ask the planner" and
  "Ask the model" is the cheapest way to stop an audience losing track of which tab is which.
