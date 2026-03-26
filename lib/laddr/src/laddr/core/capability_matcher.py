"""Capability matcher — pure functions for job-to-worker routing.

No I/O, no Redis, no async. All functions take and return plain dicts.
"""
from __future__ import annotations


def matches_requirements(worker: dict, requirements: dict) -> bool:
    """Return True if *worker* satisfies all dimensions of *requirements*.

    Empty requirements always match.
    """
    if not requirements:
        return True

    caps = worker.get("capabilities", {})
    worker_models = caps.get("models", [])
    worker_model_ids = {m["id"] for m in worker_models}

    # --- model check ---
    required_models = requirements.get("models")
    if required_models:
        match_mode = requirements.get("model_match", "any")
        if match_mode == "all":
            if not all(m in worker_model_ids for m in required_models):
                return False
        else:  # "any"
            if not any(m in worker_model_ids for m in required_models):
                return False

    # --- MCP check (must have ALL) ---
    required_mcps = requirements.get("mcps")
    if required_mcps:
        worker_mcps = set(caps.get("mcps", []))
        if not all(m in worker_mcps for m in required_mcps):
            return False

    # --- skill check (must have ALL) ---
    required_skills = requirements.get("skills")
    if required_skills:
        worker_skills = set(caps.get("skills", []))
        if not all(s in worker_skills for s in required_skills):
            return False

    # --- min_context_window check (at least one model meets threshold) ---
    min_ctx = requirements.get("min_context_window")
    if min_ctx is not None:
        if not any(m.get("context_window", 0) >= min_ctx for m in worker_models):
            return False

    return True


def _has_loaded_required_model(worker: dict, requirements: dict) -> bool:
    """Return True if the worker has at least one required model currently loaded."""
    required_models = requirements.get("models")
    if not required_models:
        return False
    caps = worker.get("capabilities", {})
    for model in caps.get("models", []):
        if model.get("id") in required_models and model.get("loaded"):
            return True
    return False


def select_best_worker(workers: list[dict], requirements: dict) -> dict | None:
    """Return the best available worker for *requirements*, or None.

    Selection criteria (in priority order):
    1. Worker must not be at max_concurrent capacity.
    2. Worker must satisfy all requirements.
    3. Prefer fewest active_jobs.
    4. Among equally loaded workers, prefer one with a required model loaded in memory.
    """
    candidates = [
        w for w in workers
        if w["active_jobs"] < w["capabilities"]["max_concurrent"]
        and matches_requirements(w, requirements)
    ]

    if not candidates:
        return None

    # Sort: ascending active_jobs, then loaded-model preference (loaded=True sorts before False)
    candidates.sort(
        key=lambda w: (
            w["active_jobs"],
            not _has_loaded_required_model(w, requirements),  # False < True → loaded first
        )
    )

    return candidates[0]
