"""Tests for capability_matcher — pure logic, no I/O."""
from __future__ import annotations

import pytest

from laddr.core.capability_matcher import matches_requirements, select_best_worker


# ---------------------------------------------------------------------------
# Fixtures / helpers
# ---------------------------------------------------------------------------

def make_worker(
    worker_id: str = "w-01",
    models: list[dict] | None = None,
    mcps: list[str] | None = None,
    skills: list[str] | None = None,
    max_concurrent: int = 4,
    active_jobs: int = 0,
) -> dict:
    if models is None:
        models = [
            {
                "id": "llama-3.3-70b",
                "provider": "lmstudio",
                "context_window": 131072,
                "loaded": True,
            }
        ]
    return {
        "worker_id": worker_id,
        "capabilities": {
            "models": models,
            "mcps": mcps or [],
            "skills": skills or [],
            "max_concurrent": max_concurrent,
        },
        "active_jobs": active_jobs,
    }


# ---------------------------------------------------------------------------
# TestMatchesRequirements
# ---------------------------------------------------------------------------


class TestMatchesRequirements:
    def test_empty_requirements_match_any_worker(self):
        worker = make_worker()
        assert matches_requirements(worker, {}) is True

    def test_model_any_mode_has_matching_model(self):
        worker = make_worker(
            models=[
                {"id": "llama-3.3-70b", "context_window": 131072, "loaded": True},
                {"id": "deepseek-r1-32b", "context_window": 32768, "loaded": False},
            ]
        )
        requirements = {"models": ["deepseek-r1-32b"], "model_match": "any"}
        assert matches_requirements(worker, requirements) is True

    def test_model_any_mode_no_matching_model(self):
        worker = make_worker(
            models=[
                {"id": "llama-3.3-70b", "context_window": 131072, "loaded": True},
            ]
        )
        requirements = {"models": ["deepseek-r1-32b"], "model_match": "any"}
        assert matches_requirements(worker, requirements) is False

    def test_model_all_mode_has_all_models(self):
        worker = make_worker(
            models=[
                {"id": "llama-3.3-70b", "context_window": 131072, "loaded": True},
                {"id": "deepseek-r1-32b", "context_window": 32768, "loaded": False},
            ]
        )
        requirements = {
            "models": ["llama-3.3-70b", "deepseek-r1-32b"],
            "model_match": "all",
        }
        assert matches_requirements(worker, requirements) is True

    def test_model_all_mode_missing_one_model(self):
        worker = make_worker(
            models=[
                {"id": "llama-3.3-70b", "context_window": 131072, "loaded": True},
            ]
        )
        requirements = {
            "models": ["llama-3.3-70b", "deepseek-r1-32b"],
            "model_match": "all",
        }
        assert matches_requirements(worker, requirements) is False

    def test_mcp_requirements_all_present(self):
        worker = make_worker(mcps=["holocron", "context7", "filesystem"])
        requirements = {"mcps": ["holocron", "context7"]}
        assert matches_requirements(worker, requirements) is True

    def test_mcp_requirements_missing_one(self):
        worker = make_worker(mcps=["holocron"])
        requirements = {"mcps": ["holocron", "context7"]}
        assert matches_requirements(worker, requirements) is False

    def test_skill_requirements_all_present(self):
        worker = make_worker(skills=["web-research", "code-gen", "summarize"])
        requirements = {"skills": ["web-research", "code-gen"]}
        assert matches_requirements(worker, requirements) is True

    def test_skill_requirements_missing_one(self):
        worker = make_worker(skills=["web-research"])
        requirements = {"skills": ["web-research", "code-gen"]}
        assert matches_requirements(worker, requirements) is False

    def test_min_context_window_met_by_at_least_one_model(self):
        worker = make_worker(
            models=[
                {"id": "small-model", "context_window": 4096, "loaded": True},
                {"id": "big-model", "context_window": 131072, "loaded": False},
            ]
        )
        requirements = {"min_context_window": 32768}
        assert matches_requirements(worker, requirements) is True

    def test_min_context_window_not_met_by_any_model(self):
        worker = make_worker(
            models=[
                {"id": "small-model", "context_window": 4096, "loaded": True},
            ]
        )
        requirements = {"min_context_window": 32768}
        assert matches_requirements(worker, requirements) is False

    def test_combined_requirements_all_satisfied(self):
        worker = make_worker(
            models=[{"id": "deepseek-r1-32b", "context_window": 32768, "loaded": True}],
            mcps=["holocron"],
            skills=["code-gen"],
        )
        requirements = {
            "models": ["deepseek-r1-32b"],
            "model_match": "any",
            "mcps": ["holocron"],
            "skills": ["code-gen"],
            "min_context_window": 32768,
        }
        assert matches_requirements(worker, requirements) is True

    def test_combined_requirements_one_dimension_fails(self):
        worker = make_worker(
            models=[{"id": "deepseek-r1-32b", "context_window": 32768, "loaded": True}],
            mcps=["holocron"],
            skills=[],  # missing required skill
        )
        requirements = {
            "models": ["deepseek-r1-32b"],
            "model_match": "any",
            "mcps": ["holocron"],
            "skills": ["code-gen"],
        }
        assert matches_requirements(worker, requirements) is False


# ---------------------------------------------------------------------------
# TestSelectBestWorker
# ---------------------------------------------------------------------------


class TestSelectBestWorker:
    def test_prefers_least_loaded_worker(self):
        busy = make_worker(worker_id="busy", active_jobs=3)
        idle = make_worker(worker_id="idle", active_jobs=0)
        result = select_best_worker([busy, idle], {})
        assert result["worker_id"] == "idle"

    def test_prefers_worker_with_model_loaded_in_memory(self):
        # Both have the same active_jobs count; one has the model loaded.
        not_loaded = make_worker(
            worker_id="not-loaded",
            active_jobs=1,
            models=[{"id": "deepseek-r1-32b", "context_window": 32768, "loaded": False}],
        )
        loaded = make_worker(
            worker_id="loaded",
            active_jobs=1,
            models=[{"id": "deepseek-r1-32b", "context_window": 32768, "loaded": True}],
        )
        requirements = {"models": ["deepseek-r1-32b"], "model_match": "any"}
        result = select_best_worker([not_loaded, loaded], requirements)
        assert result["worker_id"] == "loaded"

    def test_skips_workers_at_max_concurrent(self):
        full = make_worker(worker_id="full", max_concurrent=2, active_jobs=2)
        available = make_worker(worker_id="available", max_concurrent=4, active_jobs=1)
        result = select_best_worker([full, available], {})
        assert result["worker_id"] == "available"

    def test_returns_none_when_all_workers_are_full(self):
        full1 = make_worker(worker_id="full-1", max_concurrent=2, active_jobs=2)
        full2 = make_worker(worker_id="full-2", max_concurrent=1, active_jobs=1)
        result = select_best_worker([full1, full2], {})
        assert result is None
