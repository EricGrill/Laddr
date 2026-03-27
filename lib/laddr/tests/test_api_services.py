"""Tests for /api/services endpoints."""
import json
import pytest
import yaml

@pytest.fixture
def sample_services_config(tmp_path):
    config = {
        "services": [
            {
                "id": "test-images",
                "name": "Test Images",
                "category": "creative",
                "icon": "🎨",
                "description": "Image generation.",
                "mcp": "nano-banana",
                "tools": ["generate_image"],
                "playbook": "Use for images.\n",
            },
        ]
    }
    path = tmp_path / "services.yml"
    path.write_text(yaml.dump(config))
    return str(path)

class TestServicesAPI:
    def test_registry_to_api_response_format(self, sample_services_config):
        from laddr.core.service_registry import ServiceRegistry
        registry = ServiceRegistry(config_path=sample_services_config)
        services = registry.get_all()
        response = {
            "services": [
                {"id": s.id, "name": s.name, "category": s.category, "icon": s.icon,
                 "description": s.description, "mcp": s.mcp, "tools": s.tools, "available": s.available}
                for s in services
            ],
            "summary": {"total": len(services), "available": sum(1 for s in services if s.available),
                        "unavailable": sum(1 for s in services if not s.available)},
        }
        assert response["summary"]["total"] == 1
        assert response["services"][0]["id"] == "test-images"
        json.dumps(response)  # verify serializable

    def test_single_service_includes_playbook(self, sample_services_config):
        from laddr.core.service_registry import ServiceRegistry
        registry = ServiceRegistry(config_path=sample_services_config)
        svc = registry.get("test-images")
        detail = {"id": svc.id, "name": svc.name, "playbook": svc.playbook, "tool_schemas": svc.tool_schemas}
        assert "Use for images" in detail["playbook"]
        json.dumps(detail)
