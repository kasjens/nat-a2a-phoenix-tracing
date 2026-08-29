"""
Give the `wikipedia` library a User-Agent so `wiki_search` works.

Why this exists
---------------
NAT's ``wiki_search`` tool goes through langchain's ``WikipediaLoader``, which
uses the ``wikipedia`` package (1.4.0, last released 2014). That package sends
``User-Agent: wikipedia (https://github.com/goldsmith/Wikipedia/)``.

Wikimedia now enforces its User-Agent policy and answers unidentified clients
with ``HTTP 403`` and a *plain text* body (see
https://phabricator.wikimedia.org/T400119). The library tries to parse that as
JSON, so every single search fails with::

    json.decoder.JSONDecodeError: Expecting value: line 1 column 1 (char 0)

Every ``wiki_search`` span would be an error, which takes out the two beats of
the demo that depend on successful tool calls.

``wikipedia.set_user_agent()`` sets the header used for all requests, so calling
it once at import time is enough. This module is loaded through a
``nat.components`` entry point, which NAT imports at startup in every process.

Set ``WIKIPEDIA_USER_AGENT`` to identify yourself properly -- Wikimedia asks for
a descriptive agent with a contact address.
"""

import logging
import os

logger = logging.getLogger(__name__)

_DEFAULT_USER_AGENT = ("nat-a2a-phoenix-tracing/0.1 "
                       "(https://github.com/example/nat-a2a-phoenix-tracing) "
                       "python-wikipedia/1.4.0")

try:
    import wikipedia

    wikipedia.set_user_agent(os.environ.get("WIKIPEDIA_USER_AGENT", _DEFAULT_USER_AGENT))
except ImportError:  # pragma: no cover - wiki_search simply is not in use
    logger.debug("wikipedia package not installed; skipping User-Agent shim")
