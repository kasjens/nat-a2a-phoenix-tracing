"""
A shared-lifetime A2A client function group.

Why this exists
---------------
NAT 1.8.0 registers the stock ``a2a_client`` group with
``@register_per_user_function_group``. Per-user groups are deliberately skipped
during eager construction (``workflow_builder.py:1455``) and left to
``PerUserWorkflowBuilder``. ``react_agent`` is a *shared* workflow, so it is
built eagerly, and by the time it calls ``get_tools()`` the group does not exist::

    ValueError: Function `researcher` not found in list of functions

NAT has a dedicated error for the real problem -- "Shared Workflow depends on
per-user function_group" (``workflow_builder.py:1608``) -- which you never reach,
because ``tool_names: list[FunctionRef | FunctionGroupRef]`` coerces a plain YAML
string to ``FunctionRef`` first. There is no YAML-level fix in 1.8.0, which is
the latest release.

This module re-registers the same implementation as a *shared* group under the
type name ``a2a_client_shared``.

The tradeoff
------------
Per-user registration exists so each user gets a client bound to their own
credentials. Sharing one instance is only appropriate against an unauthenticated
agent, as in this demo, so ``auth_provider`` is rejected rather than silently
shared. ``A2AClientFunctionGroup.__aenter__`` also demands a ``user_id`` in
context; for an unauthenticated agent that value only reaches a log line, so a
synthetic one is supplied when the runtime has not set a real one (``nat run``
never does).
"""

import logging
from collections.abc import AsyncGenerator

from nat.builder.builder import Builder
from nat.builder.context import ContextState
from nat.cli.register_workflow import register_function_group
from nat.plugins.a2a.client.client_config import A2AClientConfig
from nat.plugins.a2a.client.client_impl import A2AClientFunctionGroup

logger = logging.getLogger(__name__)

_SHARED_USER_ID = "nat-demo-shared"


class A2AClientSharedConfig(A2AClientConfig, name="a2a_client_shared"):
    """Same settings as ``a2a_client``, built once and shared by all callers."""


@register_function_group(config_type=A2AClientSharedConfig)
async def a2a_client_shared_function_group(config: A2AClientSharedConfig,
                                           builder: Builder) -> AsyncGenerator[A2AClientFunctionGroup]:
    if config.auth_provider:
        raise ValueError(
            "a2a_client_shared does not support `auth_provider`: a shared client would reuse one "
            "user's credentials for every caller. Use the stock `a2a_client` from a per-user "
            "workflow when the remote agent requires authentication.")

    state = ContextState.get()
    token = None
    if not state.user_id.get():
        token = state.user_id.set(_SHARED_USER_ID)

    try:
        async with A2AClientFunctionGroup(config, builder) as group:
            yield group
    finally:
        if token is not None:
            state.user_id.reset(token)
