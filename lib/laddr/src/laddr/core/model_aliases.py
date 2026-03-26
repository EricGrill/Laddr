"""Model alias registry — canonical ID mapping across providers.

No I/O, no async, no Redis. Pure data + lookup functions.
"""
from __future__ import annotations

from dataclasses import dataclass, field


@dataclass
class ModelAlias:
    canonical: str
    aliases: dict[str, str]  # provider → provider-specific ID
    family: str


class ModelAliasRegistry:
    """Registry mapping canonical model IDs to provider-specific names."""

    def __init__(self) -> None:
        self._by_canonical: dict[str, ModelAlias] = {}
        # Reverse index: provider-specific ID → canonical
        self._reverse: dict[str, str] = {}

    def register(
        self,
        canonical: str,
        aliases: dict[str, str],
        family: str = "",
    ) -> None:
        """Register a canonical model ID with its provider-specific aliases."""
        alias = ModelAlias(canonical=canonical, aliases=aliases, family=family)
        self._by_canonical[canonical] = alias
        for provider_id in aliases.values():
            self._reverse[provider_id] = canonical

    def resolve(self, canonical: str, provider: str) -> str:
        """Return provider-specific ID for *canonical* on *provider*.

        Falls back to *canonical* if the model or provider is unknown.
        """
        alias = self._by_canonical.get(canonical)
        if alias is None:
            return canonical
        return alias.aliases.get(provider, canonical)

    def find_canonical(self, provider_id: str) -> str | None:
        """Reverse lookup: return canonical ID for a provider-specific *provider_id*.

        Returns None if not found.
        """
        return self._reverse.get(provider_id)

    def worker_models_to_canonical(self, worker_models: list[str]) -> list[str]:
        """Convert a worker's provider model list to canonical IDs.

        Unknown provider IDs pass through unchanged.
        """
        result = []
        for model_id in worker_models:
            canonical = self._reverse.get(model_id, model_id)
            result.append(canonical)
        return result

    def list_all(self) -> list[dict]:
        """Return all registered aliases as a list of dicts."""
        return [
            {
                "canonical": alias.canonical,
                "aliases": dict(alias.aliases),
                "family": alias.family,
            }
            for alias in self._by_canonical.values()
        ]
