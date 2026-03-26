from __future__ import annotations

import pytest

from laddr.core.job_templates import TemplateRegistry, resolve_requirements


SAMPLE_TEMPLATE = {
    "name": "code-review",
    "requirements": {
        "models": ["deepseek-r1-32b"],
        "model_match": "any",
        "mcps": [],
        "skills": ["code-gen"],
        "min_context_window": 32768,
    },
    "defaults": {
        "max_iterations": 10,
        "max_tool_calls": 20,
        "timeout_seconds": 300,
    },
}


class TestTemplateRegistry:
    def test_get_template(self):
        registry = TemplateRegistry()
        registry.register(SAMPLE_TEMPLATE)
        result = registry.get("code-review")
        assert result == SAMPLE_TEMPLATE

    def test_get_missing_template(self):
        registry = TemplateRegistry()
        result = registry.get("nonexistent")
        assert result is None

    def test_list_templates(self):
        registry = TemplateRegistry()
        registry.register(SAMPLE_TEMPLATE)
        another = {
            "name": "data-analysis",
            "requirements": {"models": [], "model_match": "any", "mcps": [], "skills": [], "min_context_window": 8192},
            "defaults": {},
        }
        registry.register(another)
        templates = registry.list_all()
        assert len(templates) == 2
        names = {t["name"] for t in templates}
        assert names == {"code-review", "data-analysis"}


class TestResolveRequirements:
    def setup_method(self):
        self.registry = TemplateRegistry()
        self.registry.register(SAMPLE_TEMPLATE)

    def test_template_mode(self):
        job_reqs = {"mode": "template", "template": "code-review"}
        result = resolve_requirements(job_reqs, self.registry)
        assert result["requirements"] == SAMPLE_TEMPLATE["requirements"]
        assert result["defaults"] == SAMPLE_TEMPLATE["defaults"]

    def test_template_mode_with_overrides(self):
        job_reqs = {
            "mode": "template",
            "template": "code-review",
            "overrides": {
                "requirements": {"min_context_window": 65536},
                "defaults": {"timeout_seconds": 600},
            },
        }
        result = resolve_requirements(job_reqs, self.registry)
        # Overridden fields replaced
        assert result["requirements"]["min_context_window"] == 65536
        assert result["defaults"]["timeout_seconds"] == 600
        # Other fields preserved
        assert result["requirements"]["models"] == ["deepseek-r1-32b"]
        assert result["requirements"]["skills"] == ["code-gen"]
        assert result["defaults"]["max_iterations"] == 10
        assert result["defaults"]["max_tool_calls"] == 20

    def test_explicit_mode(self):
        job_reqs = {
            "mode": "explicit",
            "models": ["gpt-4o"],
            "model_match": "exact",
            "mcps": ["filesystem"],
            "skills": ["web-search"],
            "min_context_window": 16384,
        }
        result = resolve_requirements(job_reqs, self.registry)
        assert result["requirements"]["models"] == ["gpt-4o"]
        assert result["requirements"]["model_match"] == "exact"
        assert result["requirements"]["mcps"] == ["filesystem"]
        assert result["requirements"]["skills"] == ["web-search"]
        assert result["requirements"]["min_context_window"] == 16384

    def test_generic_mode(self):
        job_reqs = {"mode": "generic"}
        result = resolve_requirements(job_reqs, self.registry)
        assert result == {"requirements": {}, "defaults": {}}

    def test_missing_mode_defaults_to_generic(self):
        result = resolve_requirements({}, self.registry)
        assert result == {"requirements": {}, "defaults": {}}

    def test_template_not_found_raises(self):
        job_reqs = {"mode": "template", "template": "nonexistent-template"}
        with pytest.raises(ValueError, match="nonexistent-template"):
            resolve_requirements(job_reqs, self.registry)
