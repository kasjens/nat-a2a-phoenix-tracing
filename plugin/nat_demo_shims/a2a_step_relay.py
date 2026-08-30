"""
Relay the remote agent's reasoning chain back across the A2A hop, and nest it.

Why this exists
---------------
``trace_propagation.py`` gets the planner and the researcher into a single trace by
carrying a ``traceparent`` across the hop. It stops short of nesting: you end up
with one trace containing two root spans, because nat resolves span parentage
through an in-process dictionary (``span_exporter._span_stack``) that has no entry
for a span id minted in another process.

Sending a parent id across the wire does not fix that. But nat has a second,
entirely different mechanism for this problem, and it is the one that works:

    nat/builder/intermediate_step_manager.py
        push_intermediate_steps(steps)
        "Inject a sequence of intermediate steps into the event stream ... Used to
         replay steps from a remote workflow (for example, from a /generate/full
         response) into the current workflow's observability stream so the full
         tree is visible."

There is a complete worked example of it in ``nat/experimental/relay_telemetry_bridge.py``,
which folds NeMo Relay's out-of-process events into the active nat trace by
re-parenting them onto ``context.active_span_id``.

So nat's own answer to cross-process tracing is not "propagate a span id". It is
"have the callee hand its steps back, and let the caller replay them into its own
stream as if they had happened locally". That is wired up for the ``/generate/full``
HTTP path and for Relay. It is not wired up for A2A.

What this does
--------------
- **Server**: collects the intermediate steps the researcher produces during a
  request and attaches them to the A2A response ``Message.metadata`` under
  ``nat.intermediate_steps``.
- **Client**: pulls them out of the response, re-parents the remote root onto the
  planner's currently-open call span, and replays them through
  ``push_intermediate_steps``.

The replayed START events land in the *planner's* span stack, so the parent lookup
that failed for a foreign span id now succeeds: the researcher's whole tree —
including its ``wiki_search`` calls, and its LLM spans if ``llm_spans.py`` is
active — is drawn underneath the planner's ``researcher`` span, in one trace, in
one tree.

Why this is the right shape for A2A, not just the convenient one
----------------------------------------------------------------
A2A is built around opaque agents: the protocol's premise is that agents interact
without exposing their internals to each other. Sideband telemetry that silently
collects a remote agent's prompts is in tension with that premise the moment the
two agents belong to different organisations.

Replaying steps from the *response* inverts the control. The callee decides what
to put in ``Message.metadata``, so exposure is something it grants rather than
something the caller takes. A server that wants to publish latency and tool names
but not prompts can filter what it attaches; ``NAT_DEMO_NO_STEP_RELAY=1`` on the
server is the crude version of that, and it publishes nothing.

Who publishes what
------------------
If the callee exports its own spans *and* the caller replays them, the same work
lands in the trace twice — measured on a real hop as 2 roots and 18 spans where
one nested tree of 9 was intended. So publication is negotiated: the caller sets
``x-nat-relay-steps: 1``, and only then does the callee collect its steps and skip
starting its own exporters for that request.

That ordering matters. Absent the header nothing changes at all — no collection,
no suppression — so a stock caller gets stock behaviour and the callee can never
be left publishing nothing because a flag was forgotten. It is request-scoped, so
the same server still exports normally for direct calls.

It also means the callee needs no route to the caller's collector: its telemetry
travels home in the response it was already sending.

When the call fails
-------------------
The adapter enqueues an error ``Message`` and *then* raises ``ServerError``, so the
JSON-RPC layer discards the message body — and any steps attached to it. Since a
failed call is the trace most worth reading, the steps go on the error instead:
``InternalError`` has a ``data`` field the adapter leaves empty. The client catches
``A2AClientJSONRPCError``, replays from ``data``, and re-raises, so error handling
upstream is unchanged.

Status: demo-grade
------------------
Reimplements the five lines of ``_create_high_level_function`` so it can see the
raw events, patches ``Runner.__aenter__`` to subscribe a collector, wraps the A2A
executor's event queue, and wraps ``ExporterManager.start``. It is the shape of the
upstream change, not a substitute for it. The relayed payload is uncompressed JSON
on the response, and prompts are large — see ``NAT_DEMO_STEP_RELAY_MAX`` below.

Environment
-----------
- ``NAT_DEMO_NO_STEP_RELAY=1`` — disable both halves; A2A behaves as it does stock.
- ``NAT_DEMO_STEP_RELAY_MAX`` — cap on relayed steps per response, default 500.
  Hitting the cap logs a warning and relays nothing, because a truncated step list
  produces a broken tree rather than a smaller one.

Read at import time, so set them before starting either process.
"""

import logging
import os
from contextlib import asynccontextmanager
from contextvars import ContextVar

try:
    from a2a.utils.errors import ServerError
except ImportError:  # pragma: no cover - a2a server not installed
    ServerError = ()  # type: ignore[assignment,misc]

logger = logging.getLogger(__name__)

_DISABLE_ENV = "NAT_DEMO_NO_STEP_RELAY"
_MAX_ENV = "NAT_DEMO_STEP_RELAY_MAX"
_DEFAULT_MAX_STEPS = 500

#: Key under which the serialized steps travel on ``Message.metadata`` and, when the
#: call fails, on the JSON-RPC error's ``data``.
STEPS_KEY = "nat.intermediate_steps"

#: Request header by which a caller declares "I will collect your telemetry, so do not
#: publish it yourself". Without it the server behaves exactly as it does stock.
RELAY_HEADER = "x-nat-relay-steps"

#: Armed on the server for the duration of one A2A request; the list collects the
#: steps that request produces.
_collector: ContextVar[list | None] = ContextVar("nat_demo_step_collector", default=None)

#: Set alongside the collector when the caller asked to take over publication.
_suppress_export: ContextVar[bool] = ContextVar("nat_demo_suppress_export", default=False)

_patched_server = False
_patched_client = False


def is_disabled() -> bool:
    """True when the demo wants stock A2A behaviour."""
    return os.environ.get(_DISABLE_ENV, "").strip().lower() in {"1", "true", "yes", "on"}


def _max_steps() -> int:
    try:
        return int(os.environ.get(_MAX_ENV, "").strip() or _DEFAULT_MAX_STEPS)
    except ValueError:
        return _DEFAULT_MAX_STEPS


# --------------------------------------------------------------------------
# server: collect steps and attach them to the response
# --------------------------------------------------------------------------
def install_server_relay() -> bool:
    """Collect each request's intermediate steps and put them on the response."""
    global _patched_server
    if _patched_server:
        return True
    if is_disabled():
        logger.info("A2A step relay disabled via %s; not attaching steps to responses", _DISABLE_ENV)
        return False

    try:
        from nat.observability.exporter_manager import ExporterManager
        from nat.plugins.a2a.server.agent_executor_adapter import NATWorkflowAgentExecutor
        from nat.runtime.runner import Runner
    except ImportError:
        logger.debug("nat a2a server not installed; skipping step relay collection")
        return False

    # When the caller has taken over publication, exporting locally as well would put
    # the same work in the trace twice: once as the callee's own root, once replayed
    # under the caller's call span. Measured on a real hop: 2 roots and 18 spans where
    # one nested tree of 9 was intended.
    original_start = ExporterManager.start

    @asynccontextmanager
    async def start(self, context_state=None):
        if not _suppress_export.get():
            async with original_start(self, context_state=context_state) as manager:
                yield manager
            return
        logger.info("A2A step relay: caller is collecting telemetry, not exporting locally")
        yield self

    ExporterManager.start = start

    # The event stream is replaced with a fresh Subject inside Runner.__aenter__, so a
    # collector armed before the run has nothing to subscribe to yet. Subscribe here,
    # immediately after the stream exists, and only when a request has armed one.
    original_aenter = Runner.__aenter__

    async def aenter(self):
        result = await original_aenter(self)
        collector = _collector.get()
        if collector is not None:
            try:
                self._context_state.event_stream.get().subscribe(collector.append)
            except Exception:
                logger.debug("could not subscribe step collector", exc_info=True)
        return result

    Runner.__aenter__ = aenter

    original_execute = NATWorkflowAgentExecutor.execute

    async def execute(self, context, event_queue):
        # Only collect when the caller asked for it. Absent the header this is a
        # normal A2A request and the server behaves exactly as it does stock.
        if not _caller_wants_steps(context):
            return await original_execute(self, context, event_queue)

        collected: list = []
        token = _collector.set(collected)
        suppress_token = _suppress_export.set(True)

        # The adapter builds the response Message internally, so the only place to
        # decorate it is on its way into the queue.
        original_enqueue = event_queue.enqueue_event

        async def enqueue_event(event):
            try:
                if hasattr(event, "metadata"):
                    payload = _serialize_steps(collected)
                    if payload is not None:
                        metadata = dict(event.metadata or {})
                        metadata[STEPS_KEY] = payload
                        event.metadata = metadata
                        logger.info("A2A step relay: attached %d steps to the response", len(payload))
            except Exception:
                logger.debug("could not attach steps to the A2A response", exc_info=True)
            return await original_enqueue(event)

        event_queue.enqueue_event = enqueue_event
        try:
            return await original_execute(self, context, event_queue)
        except ServerError as e:
            # The adapter enqueues an error Message and *then* raises, and the JSON-RPC
            # layer discards the message body in favour of an error response — so the
            # steps attached above never reach the caller. The trace of a failed call is
            # the one most worth having, so put them on the error instead.
            try:
                payload = _serialize_steps(collected)
                if payload is not None and getattr(e, "error", None) is not None:
                    data = e.error.data if isinstance(getattr(e.error, "data", None), dict) else {}
                    e.error.data = {**data, STEPS_KEY: payload}
                    logger.info("A2A step relay: attached %d steps to the error response", len(payload))
            except Exception:
                logger.debug("could not attach steps to the A2A error", exc_info=True)
            raise
        finally:
            _collector.reset(token)
            _suppress_export.reset(suppress_token)
            event_queue.enqueue_event = original_enqueue

    NATWorkflowAgentExecutor.execute = execute
    _patched_server = True
    logger.info("A2A step relay: publishing intermediate steps on responses")
    return True


def _caller_wants_steps(context) -> bool:
    """True when the incoming request carries the relay header.

    The a2a-sdk already stores the raw headers on the call context
    (``a2a/server/apps/jsonrpc/jsonrpc_app.py``: ``state['headers'] = dict(request.headers)``),
    so nothing needs intercepting at the ASGI layer.
    """
    try:
        call_context = getattr(context, "call_context", None)
        headers = (getattr(call_context, "state", None) or {}).get("headers") or {}
        value = next((v for k, v in headers.items() if k.lower() == RELAY_HEADER), None)
        return str(value).strip().lower() in {"1", "true", "yes", "on"} if value is not None else False
    except Exception:
        logger.debug("could not read the relay header", exc_info=True)
        return False


def install_client_request_header(httpx_client) -> bool:
    """Declare on every outgoing A2A call that this caller will collect the callee's steps."""
    if is_disabled():
        return False

    async def _add_relay_header(request) -> None:
        request.headers[RELAY_HEADER] = "1"

    try:
        hooks = httpx_client.event_hooks
        hooks.setdefault("request", [])
        hooks["request"].append(_add_relay_header)
        httpx_client.event_hooks = hooks
    except Exception:
        logger.warning("could not attach the relay header hook to the A2A httpx client", exc_info=True)
        return False

    logger.info("A2A step relay: requesting steps on outgoing calls (%s)", RELAY_HEADER)
    return True


def _serialize_steps(steps: list) -> list | None:
    """Dump collected steps to JSON-safe dicts, or None if there is nothing usable.

    Only START and END steps are relayed. ``LangchainProfilerHandler`` also pushes a
    ``LLM_NEW_TOKEN`` step per streamed token, and the span exporter only reacts to
    START and END (``span_exporter.export``), so chunks can never become spans. On a
    real run they are the overwhelming majority: one request produced 982 steps, of
    which 950 were chunks.
    """
    if not steps:
        return None

    from nat.data_models.intermediate_step import IntermediateStepState

    total = len(steps)
    steps = [s for s in steps if s.payload.event_state in (IntermediateStepState.START, IntermediateStepState.END)]
    if total != len(steps):
        logger.debug("A2A step relay: dropped %d chunk steps, %d spans-worth remain", total - len(steps), len(steps))

    if not steps:
        return None

    cap = _max_steps()
    if len(steps) > cap:
        # A truncated step list produces a broken tree rather than a smaller one:
        # END events whose START was dropped are logged as errors by the exporter.
        logger.warning("A2A step relay: %d steps exceeds the %s cap of %d; relaying nothing",
                       len(steps),
                       _MAX_ENV,
                       cap)
        return None

    dumped = []
    for step in steps:
        try:
            dumped.append(step.model_dump(mode="json"))
        except Exception:
            logger.debug("could not serialize intermediate step", exc_info=True)
    return dumped or None


# --------------------------------------------------------------------------
# client: pull the steps out, re-parent them, replay them
# --------------------------------------------------------------------------
def install_client_relay() -> bool:
    """Replay the remote agent's steps into the caller's own trace."""
    global _patched_client
    if _patched_client:
        return True
    if is_disabled():
        logger.info("A2A step relay disabled via %s; not replaying remote steps", _DISABLE_ENV)
        return False

    try:
        from nat.plugins.a2a.client.client_impl import A2AClientFunctionGroup
    except ImportError:
        logger.debug("nat a2a client not installed; skipping step relay replay")
        return False

    def _create_high_level_function(self):
        """Same contract as the stock high-level function, plus a telemetry replay.

        The stock implementation collects events and throws them away after
        extracting the text. This needs the raw events to reach `Message.metadata`,
        so it repeats those few lines rather than wrapping them.
        """

        async def high_level_fn(query: str, task_id: str | None = None, context_id: str | None = None) -> str:
            if not self._client:
                raise RuntimeError("A2A client not initialized")

            events = []
            try:
                async for event in self._client.send_message(query, task_id, context_id):
                    events.append(event)
            except Exception as e:
                # A failed remote call still produced work worth seeing, and the server
                # puts its steps on the JSON-RPC error precisely because the error
                # response discards the message body.
                try:
                    replay_steps_from_error(e)
                except Exception:
                    logger.debug("could not replay remote steps from the error", exc_info=True)
                raise

            try:
                replay_steps_from_events(events)
            except Exception:
                # Telemetry must never break the actual call.
                logger.debug("could not replay remote steps", exc_info=True)

            return self._client.extract_text_from_events(events)

        return high_level_fn

    A2AClientFunctionGroup._create_high_level_function = _create_high_level_function
    _patched_client = True
    logger.info("A2A step relay: replaying remote steps into the local trace")
    return True


def _iter_metadata(events) -> list:
    """Yield every metadata dict reachable from a list of A2A response events.

    Events are ``Message`` or ``ClientEvent``, and ``ClientEvent`` is a
    ``(Task, UpdateEvent | None)`` tuple, so this walks tuples one level down.
    """
    found = []
    for event in events:
        candidates = event if isinstance(event, (tuple, list)) else (event, )
        for candidate in candidates:
            metadata = getattr(candidate, "metadata", None)
            if isinstance(metadata, dict):
                found.append(metadata)
    return found


def replay_steps_from_error(exc) -> int:
    """Replay steps a failed A2A call carried on its JSON-RPC error `data`."""
    error = getattr(exc, "error", None)
    data = getattr(error, "data", None)
    if not isinstance(data, dict) or not data.get(STEPS_KEY):
        return 0
    return _replay(data[STEPS_KEY])


def replay_steps_from_events(events) -> int:
    """Replay any relayed steps found on `events` into the current trace.

    Returns the number of steps replayed.
    """
    raw = None
    for metadata in _iter_metadata(events):
        if metadata.get(STEPS_KEY):
            raw = metadata[STEPS_KEY]
            break
    if not raw:
        return 0
    return _replay(raw)


def _replay(raw: list) -> int:
    """Deserialize relayed steps, re-parent their roots locally, and push them."""
    from nat.builder.context import Context
    from nat.data_models.intermediate_step import IntermediateStep

    context = Context.get()
    # The call span for this tool is open right now, so its step id is on the stack.
    # Re-parenting the remote root onto it is what makes the exporter's parent lookup
    # succeed instead of falling through to a second root.
    local_parent_id = context.active_span_id
    local_function = context.active_function

    steps = []
    for item in raw:
        try:
            steps.append(IntermediateStep.model_validate(item))
        except Exception:
            logger.debug("could not deserialize relayed step", exc_info=True)

    if not steps:
        return 0

    remote_ids = {step.payload.UUID for step in steps}
    for step in steps:
        # A remote step whose parent is not itself in the relayed set is a root of the
        # remote tree; hang it off the local call span.
        if step.parent_id not in remote_ids:
            step.parent_id = local_parent_id
            ancestry = step.function_ancestry
            if ancestry is not None and local_function is not None:
                step.function_ancestry = ancestry.model_copy(update={
                    "parent_id": local_function.function_id,
                    "parent_name": local_function.function_name,
                })

    context.intermediate_step_manager.push_intermediate_steps(steps)
    logger.info("A2A step relay: replayed %d remote steps under span %s", len(steps), local_parent_id)
    return len(steps)


install_server_relay()
install_client_relay()
