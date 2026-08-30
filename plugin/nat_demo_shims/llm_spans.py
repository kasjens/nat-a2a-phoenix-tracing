"""
LLM spans, prompts and token counts on the ``react_agent`` path.

Why this exists
---------------
Out of the box, every span this demo produces is ``spanKind: chain`` with a null
token count. You can see the shape of a run — who called whom, how long each step
took, what went in and what came out — but not a single prompt, completion or
token. That is the difference between watching a handoff happen and being able to
say *why* the agent decided to hand off.

nat is not missing the concept. ``SpanKind.LLM`` exists and ``LLM_START`` maps to
it (``nat/data_models/span.py``). The component that emits those events,
``LangchainProfilerHandler``, is attached in exactly one place in 1.8.0::

    nat/plugins/langchain/control_flow/sequential_executor.py:147
        profiler_config = {'callbacks': [LangchainProfilerHandler()]}

``react_agent`` never attaches it, so nothing on this path emits ``LLM_START`` and
no LLM span is ever created.

The registration decorators take a ``framework_wrappers`` argument, documented as
being "for automatic profiler hooking", and ``react_agent`` passes
``framework_wrappers=[LLMFrameworkEnum.LANGCHAIN]``. It does nothing. Grepping the
installed package for reads of that attribute returns **no hits at all** — it is
stored on the registration (``nat/cli/type_registry.py``) and never consulted. So
the hook point exists in the API and was never wired to anything.

What this does
--------------
Installs the handler the way langchain intends handlers to be installed globally:
``register_configure_hook`` binds a context variable whose contents are added to
every callback manager langchain builds. That catches the agent's LLM calls
wherever they happen, without patching nat's LLM client factory or the agent.

The handler pushes ``LLM_START`` / ``LLM_END`` intermediate steps carrying the
prompt, the completion and ``TokenUsageBaseModel``, which the span exporter turns
into ``spanKind: LLM`` spans with ``llm.token_count.*`` populated.

``LangchainProfilerHandler.__init__`` resolves ``Context.get().intermediate_step_manager``
once and stores it. ``ContextState`` is a singleton whose fields are ``ContextVar``s
read at push time, so a single handler instance built at import stays correct
across runs and concurrent requests.

One rough edge, inherited from nat rather than introduced here: the handler reads
``metadata["ls_model_name"]`` unguarded (``callback_handler.py``) and logs an
exception traceback for any model that does not publish it. ``ChatNVIDIA`` does,
so the demo path is quiet; a langchain model that does not will produce a noisy
but harmless ``Error getting model name`` log and an LLM span with an empty model
name.

Because the handler is attached process-wide, this applies to *every* langchain
model call in the process, not just the agent's.

Set ``NAT_DEMO_NO_LLM_SPANS=1`` to turn this off and get the original
chain-spans-only behaviour. It is read at import time, so set it before starting
the process.
"""

import logging
import os
from contextvars import ContextVar

logger = logging.getLogger(__name__)

_DISABLE_ENV = "NAT_DEMO_NO_LLM_SPANS"

_installed = False


def is_disabled() -> bool:
    """True when the demo wants the original chain-spans-only behaviour."""
    return os.environ.get(_DISABLE_ENV, "").strip().lower() in {"1", "true", "yes", "on"}


def install_llm_spans() -> bool:
    """Attach nat's langchain profiler handler to every langchain callback manager.

    Returns True if the handler was installed.
    """
    global _installed
    if _installed:
        return True
    if is_disabled():
        logger.info("LLM spans disabled via %s; react_agent will emit chain spans only", _DISABLE_ENV)
        return False

    try:
        from langchain_core.tracers.context import register_configure_hook
        from nat.plugins.langchain.callback_handler import LangchainProfilerHandler
    except ImportError:
        logger.debug("langchain plugin not installed; skipping LLM span handler")
        return False

    try:
        handler = LangchainProfilerHandler()
    except Exception:
        logger.warning("could not construct LangchainProfilerHandler; LLM spans unavailable", exc_info=True)
        return False

    # register_configure_hook adds whatever this var holds to every callback manager
    # langchain configures, for the lifetime of the process.
    var: ContextVar = ContextVar("nat_demo_llm_profiler", default=None)
    register_configure_hook(var, inheritable=True)
    var.set(handler)

    # Keep a reference so the ContextVar is not the only thing holding the handler.
    install_llm_spans.handler = handler  # type: ignore[attr-defined]
    install_llm_spans.var = var  # type: ignore[attr-defined]

    _installed = True
    logger.info("LLM spans: LangchainProfilerHandler attached to all langchain callback managers")
    return True


install_llm_spans()
