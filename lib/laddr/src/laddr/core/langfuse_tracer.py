"""
Very small Langfuse helper for Laddr.

We follow the official pattern:

    from langfuse import get_client
    langfuse = get_client()
    span = langfuse.start_span(...)
    ...
    span.end()
    langfuse.flush()
"""

from __future__ import annotations

from typing import Any
import logging

logger = logging.getLogger(__name__)

try:  # Langfuse SDK is optional
    from langfuse import get_client  # type: ignore
except Exception:  # pragma: no cover - optional dependency
    get_client = None  # type: ignore


_langfuse_client: Any | None = None


def get_langfuse_client() -> Any | None:
    """
    Lazily get a shared Langfuse client using get_client().
    
    Returns None if the SDK is not installed or initialization fails.
    """
    global _langfuse_client

    if _langfuse_client is not None:
        return _langfuse_client

    if get_client is None:
        logger.info("langfuse package not installed; Langfuse tracing disabled")
        return None

    try:
        _langfuse_client = get_client()  # type: ignore[call-arg]
        logger.info("Langfuse client initialized via get_client()")
    except Exception as e:  # pragma: no cover - defensive
        logger.warning(f"Failed to initialize Langfuse client: {e}")
        _langfuse_client = None

    return _langfuse_client


