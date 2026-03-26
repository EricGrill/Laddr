"""Tests for ModelAliasRegistry — canonical ID mapping across providers."""
from __future__ import annotations

import pytest

from laddr.core.model_aliases import ModelAlias, ModelAliasRegistry


@pytest.fixture
def registry() -> ModelAliasRegistry:
    reg = ModelAliasRegistry()
    reg.register(
        canonical="deepseek-r1-32b",
        aliases={
            "venice": "deepseek/deepseek-r1",
            "lmstudio": "deepseek-r1-distill-qwen-32b",
        },
        family="deepseek",
    )
    reg.register(
        canonical="qwen-2.5-7b",
        aliases={
            "venice": "qwen/qwen-2.5-7b-instruct",
            "lmstudio": "qwen2.5-7b-instruct",
        },
        family="qwen",
    )
    reg.register(
        canonical="llama-3.1-8b",
        aliases={
            "venice": "meta-llama/llama-3.1-8b-instruct",
        },
        family="llama",
    )
    return reg


class TestModelAliasRegistry:
    def test_resolve_canonical_to_provider(self, registry: ModelAliasRegistry):
        """resolve('deepseek-r1-32b', 'venice') → 'deepseek/deepseek-r1'"""
        result = registry.resolve("deepseek-r1-32b", "venice")
        assert result == "deepseek/deepseek-r1"

    def test_resolve_unknown_provider_returns_canonical(self, registry: ModelAliasRegistry):
        """Unknown provider falls back to the canonical ID."""
        result = registry.resolve("deepseek-r1-32b", "openai")
        assert result == "deepseek-r1-32b"

    def test_resolve_unknown_model_returns_as_is(self, registry: ModelAliasRegistry):
        """Unknown canonical ID returns the input unchanged."""
        result = registry.resolve("gpt-4o", "venice")
        assert result == "gpt-4o"

    def test_find_canonical_from_provider_id(self, registry: ModelAliasRegistry):
        """Reverse lookup: provider-specific ID → canonical."""
        assert registry.find_canonical("deepseek/deepseek-r1") == "deepseek-r1-32b"
        assert registry.find_canonical("qwen2.5-7b-instruct") == "qwen-2.5-7b"
        assert registry.find_canonical("meta-llama/llama-3.1-8b-instruct") == "llama-3.1-8b"

    def test_find_canonical_unknown_returns_none(self, registry: ModelAliasRegistry):
        """Unknown provider ID returns None."""
        assert registry.find_canonical("totally-unknown-model") is None

    def test_worker_models_to_canonical(self, registry: ModelAliasRegistry):
        """Convert a worker's provider model list to canonical IDs."""
        worker_models = [
            "deepseek/deepseek-r1",
            "qwen2.5-7b-instruct",
        ]
        result = registry.worker_models_to_canonical(worker_models)
        assert result == ["deepseek-r1-32b", "qwen-2.5-7b"]

    def test_worker_models_unknown_kept_as_is(self, registry: ModelAliasRegistry):
        """Unknown provider IDs pass through unchanged."""
        worker_models = [
            "deepseek/deepseek-r1",
            "some-custom-model",
        ]
        result = registry.worker_models_to_canonical(worker_models)
        assert result == ["deepseek-r1-32b", "some-custom-model"]

    def test_list_all(self, registry: ModelAliasRegistry):
        """list_all returns all registered aliases as dicts."""
        all_aliases = registry.list_all()
        assert len(all_aliases) == 3
        canonicals = {entry["canonical"] for entry in all_aliases}
        assert canonicals == {"deepseek-r1-32b", "qwen-2.5-7b", "llama-3.1-8b"}
        # Each entry has the expected keys
        for entry in all_aliases:
            assert "canonical" in entry
            assert "aliases" in entry
            assert "family" in entry
