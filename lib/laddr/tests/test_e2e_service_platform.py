"""End-to-end test for the service platform.

Tests the complete flow: config → registry → discovery → playbook → job enrichment.
"""

import asyncio
import json
import yaml
import pytest


class FakeRedis:
    def __init__(self, data):
        self._data = data

    async def hgetall(self, key):
        return {k.encode(): v.encode() for k, v in self._data.items()}


@pytest.fixture
def full_config(tmp_path):
    """Use the actual services.yml structure with 2 services."""
    config = {
        "services": [
            {
                "id": "image-generation",
                "name": "Image Generation",
                "category": "creative",
                "icon": "🎨",
                "description": "Generate images from text prompts using Gemini.",
                "mcp": "nano-banana",
                "tools": ["generate_image", "generate_blog_images"],
                "playbook": (
                    "## When to use\n"
                    "Use when a task requires creating or visualizing something.\n\n"
                    "## Tools\n"
                    "- `generate_image(prompt, filename, aspectRatio)`\n"
                ),
            },
            {
                "id": "knowledge-base",
                "name": "Knowledge Base",
                "category": "data",
                "icon": "📚",
                "description": "Persistent markdown storage with semantic search.",
                "mcp": "holocron",
                "tools": ["knowledge_search", "knowledge_get"],
                "playbook": (
                    "## When to use\n"
                    "Use for finding or storing persistent information.\n\n"
                    "## Tools\n"
                    "- `knowledge_search(query)`\n"
                ),
            },
        ]
    }
    path = tmp_path / "services.yml"
    path.write_text(yaml.dump(config))
    return str(path)


@pytest.fixture
def redis_with_both_mcps():
    return FakeRedis({
        "worker-snoke": json.dumps({
            "worker_id": "worker-snoke",
            "node": "snoke",
            "mcps": ["nano-banana", "holocron", "context7"],
            "last_heartbeat": 9999999999,
        }),
    })


class TestServicePlatformE2E:
    def test_full_flow_all_services(self, full_config, redis_with_both_mcps):
        """Config → discover → playbook for unrestricted job."""
        from laddr.core.service_registry import ServiceRegistry

        registry = ServiceRegistry(config_path=full_config, redis_client=redis_with_both_mcps)
        asyncio.get_event_loop().run_until_complete(registry.discover())

        assert len(registry.get_available()) == 2

        job = {"system_prompt": "Do something creative."}
        playbook = registry.build_playbook(job)

        assert "Image Generation" in playbook
        assert "Knowledge Base" in playbook
        assert "generate_image" in playbook
        assert "knowledge_search" in playbook

        enriched = f"{playbook}\n\n{job['system_prompt']}"
        assert "# Available Platform Services" in enriched
        assert "Do something creative." in enriched

    def test_full_flow_filtered_by_service(self, full_config, redis_with_both_mcps):
        """Config → discover → playbook filtered to one service."""
        from laddr.core.service_registry import ServiceRegistry

        registry = ServiceRegistry(config_path=full_config, redis_client=redis_with_both_mcps)
        asyncio.get_event_loop().run_until_complete(registry.discover())

        job = {
            "system_prompt": "Generate a hero image.",
            "services": ["image-generation"],
        }
        playbook = registry.build_playbook(job)

        assert "Image Generation" in playbook
        assert "Knowledge Base" not in playbook

    def test_api_response_shape(self, full_config, redis_with_both_mcps):
        """Verify the catalog can be serialized to API response format."""
        from laddr.core.service_registry import ServiceRegistry

        registry = ServiceRegistry(config_path=full_config, redis_client=redis_with_both_mcps)
        asyncio.get_event_loop().run_until_complete(registry.discover())

        services = registry.get_all()
        response = {
            "services": [
                {
                    "id": s.id, "name": s.name, "category": s.category, "icon": s.icon,
                    "description": s.description, "mcp": s.mcp, "tools": s.tools, "available": s.available,
                }
                for s in services
            ],
            "summary": {
                "total": len(services),
                "available": sum(1 for s in services if s.available),
                "unavailable": sum(1 for s in services if not s.available),
            },
        }

        serialized = json.dumps(response)
        parsed = json.loads(serialized)
        assert parsed["summary"]["total"] == 2
        assert parsed["summary"]["available"] == 2
