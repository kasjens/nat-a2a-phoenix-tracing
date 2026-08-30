"""
W3C trace context propagation across the A2A hop.

Why this exists
---------------
Out of the box, a planner calling a researcher over A2A produces *two* traces in
Phoenix with two separate roots and no link between them. That is the gap the
demo is built around, and the cause is narrow: nat 1.8.0 already has the
receiving half, and only the two ends of the wire are missing.

- The A2A client builds a bare ``httpx.AsyncClient``
  (``nat/plugins/a2a/client/client_base.py``) and never sets a ``traceparent``
  header, so the request carries no trace identity.
- The A2A server never reads one. ``set_metadata_from_http_request()`` does parse
  ``traceparent`` (``nat/runtime/session.py``), but it only runs when a Starlette
  ``Request`` is handed to ``session()``, and the A2A adapter calls ``session()``
  with no arguments (``nat/plugins/a2a/server/agent_executor_adapter.py``).

Everything downstream is already in place. ``nat/runtime/runner.py`` computes
``workflow_trace_id = existing_trace_id or uuid.uuid4().int``, so a workflow will
adopt an inherited trace id instead of minting a fresh one, and the span exporter
stamps spans with whatever that resolves to.

So this module supplies the two missing ends:

- **inject**, as an httpx request hook on the A2A client, applied by
  ``a2a_shared.py`` when it builds the function group
- **extract**, by wrapping ``NATWorkflowAgentExecutor.execute`` to read the
  header and set ``workflow_trace_id`` before the workflow starts

The extract side is helped by the a2a-sdk, which already stashes the full
incoming header dict on the call context
(``a2a/server/apps/jsonrpc/jsonrpc_app.py``: ``state['headers'] = dict(request.headers)``).
Nothing needs to be intercepted at the ASGI layer; the header is simply sitting
there unread.

What this actually achieves
---------------------------
Measured, against a wiped Phoenix volume:

- **without it**: 2 traces, 2 trace ids, 2 roots, nothing linking them
- **with it**: 1 trace, 1 trace id, and still 2 root spans

So the hop is linked and both agents land in a single trace, which is the thing you
could not do at all before. What you do *not* get is the researcher's tree nested
underneath the planner's ``researcher__call`` span.

That last step is not a matter of propagating one more header. nat resolves span
parentage through an in-process dictionary: ``span_exporter`` looks the parent up in
``self._span_stack`` by intermediate-step UUID, and on a miss it logs "No parent span
found" and **drops the span entirely**. ``runner.py`` will happily set the root step's
parent to ``workflow_parent_id`` if you give it one, and nat even parses a
``workflow-parent-id`` header for exactly this purpose, but a parent id minted in the
planner's process is not in the researcher's span stack, so feeding one across the wire
would delete the researcher's root span rather than reparent it. True cross-process
nesting needs a change inside ``span_exporter``, not another shim.

Status: demo-grade
------------------
This reaches into a private attribute on the A2A client and monkeypatches a nat
class. It is the shape of the upstream fix, not a substitute for it. Set
``NAT_DEMO_NO_TRACE_PROPAGATION=1`` to disable it and get the original broken
behaviour back, which is what you want when recording beat 2.
"""

import logging
import os
import secrets

logger = logging.getLogger(__name__)

_DISABLE_ENV = "NAT_DEMO_NO_TRACE_PROPAGATION"


def is_disabled() -> bool:
    """True when the demo wants the original, unpropagated behaviour."""
    return os.environ.get(_DISABLE_ENV, "").strip().lower() in {"1", "true", "yes", "on"}


def format_traceparent(trace_id: int, span_id: int | None = None) -> str:
    """Build a W3C ``traceparent`` value.

    Format is ``00-<32 hex trace id>-<16 hex span id>-<2 hex flags>``. Both ids
    must be non-zero to be valid.
    """
    if span_id is None:
        span_id = secrets.randbits(64) or 1
    return f"00-{trace_id & ((1 << 128) - 1):032x}-{span_id & ((1 << 64) - 1):016x}-01"


def parse_traceparent(value: str) -> int | None:
    """Return the trace id from a ``traceparent`` header, or None if unusable.

    Deliberately lenient: a malformed header should leave tracing looking like it
    does today, not break the request.
    """
    try:
        parts = value.strip().split("-")
        if len(parts) < 4 or len(parts[1]) != 32:
            return None
        trace_id = int(parts[1], 16)
        return trace_id or None
    except Exception:
        return None


# --------------------------------------------------------------------------
# inject: client side
# --------------------------------------------------------------------------
def install_client_injection(httpx_client) -> bool:
    """Attach a request hook that stamps ``traceparent`` on outgoing A2A calls.

    Returns True if the hook was attached. The trace id is read at request time,
    not at install time, because the client is built once and reused across runs
    while the trace id changes per workflow run.
    """
    if is_disabled():
        logger.info("A2A trace propagation disabled via %s; not injecting traceparent", _DISABLE_ENV)
        return False

    from nat.builder.context import ContextState

    async def _inject_traceparent(request) -> None:
        try:
            trace_id = ContextState.get().workflow_trace_id.get()
            if not trace_id:
                return
            request.headers["traceparent"] = format_traceparent(trace_id)
        except Exception:
            # Never let telemetry plumbing break the actual call.
            logger.debug("could not inject traceparent", exc_info=True)

    try:
        hooks = httpx_client.event_hooks
        hooks.setdefault("request", [])
        hooks["request"].append(_inject_traceparent)
        httpx_client.event_hooks = hooks
    except Exception:
        logger.warning("could not attach traceparent hook to the A2A httpx client", exc_info=True)
        return False

    logger.info("A2A trace propagation: injecting traceparent on outgoing requests")
    return True


# --------------------------------------------------------------------------
# extract: server side
# --------------------------------------------------------------------------
_patched = False


def install_server_extraction() -> bool:
    """Wrap the A2A agent executor so it honours an incoming ``traceparent``."""
    global _patched
    if _patched:
        return True
    if is_disabled():
        logger.info("A2A trace propagation disabled via %s; not extracting traceparent", _DISABLE_ENV)
        return False

    try:
        from nat.builder.context import ContextState
        from nat.plugins.a2a.server.agent_executor_adapter import NATWorkflowAgentExecutor
    except ImportError:
        logger.debug("nat a2a server not installed; skipping traceparent extraction")
        return False

    original_execute = NATWorkflowAgentExecutor.execute

    async def execute(self, context, event_queue):
        token = None
        try:
            call_context = getattr(context, "call_context", None)
            state = getattr(call_context, "state", None) or {}
            headers = state.get("headers") or {}
            # Header names are case-insensitive on the wire.
            header = next((v for k, v in headers.items() if k.lower() == "traceparent"), None)
            trace_id = parse_traceparent(header) if header else None
            if trace_id:
                token = ContextState.get().workflow_trace_id.set(trace_id)
                logger.info("A2A trace propagation: inherited trace id %032x", trace_id)
        except Exception:
            logger.debug("could not extract traceparent", exc_info=True)

        try:
            return await original_execute(self, context, event_queue)
        finally:
            if token is not None:
                try:
                    ContextState.get().workflow_trace_id.reset(token)
                except Exception:
                    logger.debug("could not reset workflow_trace_id", exc_info=True)

    NATWorkflowAgentExecutor.execute = execute
    _patched = True
    logger.info("A2A trace propagation: reading traceparent on incoming requests")
    return True


install_server_extraction()
