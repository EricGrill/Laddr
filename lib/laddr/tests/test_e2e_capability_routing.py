"""End-to-end test for capability-based routing.
Uses in-memory backends (no Redis/Docker required).
"""
import pytest
from laddr.core.capability_matcher import matches_requirements, select_best_worker
from laddr.core.dispatcher import Dispatcher
from laddr.core.job_templates import TemplateRegistry
from laddr.core.worker_process import build_agent_config, select_model_for_job
from laddr.core.worker_registry import WorkerRegistry


class TestEndToEndRouting:
    def setup_method(self):
        self.workers = WorkerRegistry(backend="memory")
        self.templates = TemplateRegistry()
        self.templates.register({
            "name": "code-review",
            "requirements": {"models": ["deepseek-r1-32b"], "model_match": "any", "mcps": [], "skills": ["code-gen"], "min_context_window": 32768},
            "defaults": {"max_iterations": 10, "max_tool_calls": 20, "timeout_seconds": 300},
        })
        self.templates.register({
            "name": "web-research",
            "requirements": {"models": [], "mcps": ["context7"], "skills": ["web-research"], "min_context_window": 8192},
            "defaults": {"max_iterations": 15, "max_tool_calls": 30, "timeout_seconds": 600},
        })
        self.workers.register(
            worker_id="snoke-01", node="snoke",
            capabilities={
                "models": [
                    {"id": "llama-3.3-70b", "provider": "lmstudio", "context_window": 131072, "loaded": True},
                    {"id": "deepseek-r1-32b", "provider": "lmstudio", "context_window": 65536, "loaded": True},
                ],
                "mcps": ["holocron", "context7", "nano-banana"],
                "skills": ["web-research", "code-gen"],
                "max_concurrent": 2,
            },
        )
        self.workers.register(
            worker_id="venice-01", node="bitlay",
            capabilities={
                "models": [{"id": "llama-3.3-70b", "provider": "venice", "context_window": 131072, "loaded": True}],
                "mcps": [],
                "skills": [],
                "max_concurrent": 3,
            },
        )
        self.dispatcher = Dispatcher(
            worker_registry=self.workers,
            template_registry=self.templates,
        )

    def test_code_review_routes_to_snoke(self):
        """Code review needs deepseek-r1-32b + code-gen — only snoke has both."""
        job = {"job_id": "j1", "requirements": {"mode": "template", "template": "code-review"}, "priority": "normal"}
        worker = self.dispatcher.find_worker_for_job(job)
        assert worker is not None
        assert worker["worker_id"] == "snoke-01"

    def test_web_research_routes_to_snoke(self):
        """Web research needs context7 MCP — only snoke has it."""
        job = {"job_id": "j2", "requirements": {"mode": "template", "template": "web-research"}, "priority": "normal"}
        worker = self.dispatcher.find_worker_for_job(job)
        assert worker is not None
        assert worker["worker_id"] == "snoke-01"

    def test_generic_job_load_balances(self):
        """Generic job goes to least loaded worker."""
        job = {"job_id": "j3", "requirements": {"mode": "generic"}, "priority": "normal"}
        w1 = self.dispatcher.find_worker_for_job(job)
        assert w1 is not None
        self.workers.heartbeat(w1["worker_id"], active_jobs=w1["capabilities"]["max_concurrent"])
        w2 = self.dispatcher.find_worker_for_job(job)
        assert w2 is not None
        assert w2["worker_id"] != w1["worker_id"]

    def test_explicit_requirements(self):
        """Explicit model requirement routes correctly."""
        job = {"job_id": "j4", "requirements": {"mode": "explicit", "models": ["llama-3.3-70b"], "model_match": "any"}, "priority": "normal"}
        worker = self.dispatcher.find_worker_for_job(job)
        assert worker is not None
        assert worker["worker_id"] in ("snoke-01", "venice-01")

    def test_agent_config_from_job(self):
        """Job payload maps correctly to agent config."""
        job = {"job_id": "j5-abcdef", "system_prompt": "You are a code reviewer", "user_prompt": "Review PR #42", "max_iterations": 10}
        config = build_agent_config(job, worker_id="snoke-01")
        assert "snoke-01" in config["name"]
        assert config["goal"] == "You are a code reviewer"
        assert config["instructions"] == "Review PR #42"

    def test_model_selection_for_job(self):
        """Worker picks the right model for the job."""
        models = [
            {"id": "llama-3.3-70b", "provider": "lmstudio", "loaded": True},
            {"id": "deepseek-r1-32b", "provider": "lmstudio", "loaded": True},
        ]
        requirements = {"models": ["deepseek-r1-32b"]}
        model = select_model_for_job(models, requirements)
        assert model["id"] == "deepseek-r1-32b"
