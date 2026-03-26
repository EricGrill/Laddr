from __future__ import annotations

import copy


class TemplateRegistry:
    def __init__(self) -> None:
        self._templates: dict[str, dict] = {}

    def register(self, template: dict) -> None:
        """Store a template by its name."""
        self._templates[template["name"]] = template

    def get(self, name: str) -> dict | None:
        """Return the template with the given name, or None if not found."""
        return self._templates.get(name)

    def list_all(self) -> list[dict]:
        """Return all registered templates."""
        return list(self._templates.values())


def resolve_requirements(job_reqs: dict, template_registry: TemplateRegistry) -> dict:
    """Resolve a job's raw requirement block into matching criteria.

    Modes:
      - "generic" or missing → empty requirements and defaults
      - "template" → look up named template, deep copy, apply overrides
      - "explicit" → extract models/model_match/mcps/skills/min_context_window

    Raises ValueError if mode is "template" and the template is not found.
    """
    mode = job_reqs.get("mode", "generic")

    if mode == "generic" or not mode:
        return {"requirements": {}, "defaults": {}}

    if mode == "template":
        template_name = job_reqs.get("template", "")
        template = template_registry.get(template_name)
        if template is None:
            raise ValueError(f"Template not found: {template_name!r}")

        requirements = copy.deepcopy(template.get("requirements", {}))
        defaults = copy.deepcopy(template.get("defaults", {}))

        overrides = job_reqs.get("overrides", {})
        requirements.update(overrides.get("requirements", {}))
        defaults.update(overrides.get("defaults", {}))

        return {"requirements": requirements, "defaults": defaults}

    if mode == "explicit":
        requirements: dict = {}
        for key in ("models", "model_match", "mcps", "skills", "min_context_window"):
            if key in job_reqs:
                requirements[key] = job_reqs[key]
        return {"requirements": requirements, "defaults": {}}

    # Unknown mode — treat as generic
    return {"requirements": {}, "defaults": {}}
