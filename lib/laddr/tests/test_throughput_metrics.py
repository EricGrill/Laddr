"""Tests for _compute_throughput() logic in mission_control."""

import time
from unittest.mock import MagicMock

import pytest


def _make_db_mock(buckets: dict[int, dict[str, int]]):
    """Create a mock DatabaseService that returns given counts per bucket."""
    db = MagicMock()
    db.count_executions_by_bucket.side_effect = lambda since_minutes: buckets.get(
        since_minutes, {"inbound": 0, "completed": 0, "failed": 0}
    )
    return db


def test_compute_throughput_basic():
    from laddr.api.mission_control import _compute_throughput, _imbalance_start_time

    db = _make_db_mock({
        5: {"inbound": 3, "completed": 2, "failed": 0},
        15: {"inbound": 10, "completed": 9, "failed": 1},
        60: {"inbound": 42, "completed": 38, "failed": 4},
        1440: {"inbound": 380, "completed": 365, "failed": 15},
    })

    result = _compute_throughput(db)

    assert result["inbound"] == {"5m": 3, "1h": 42, "24h": 380}
    assert result["completed"] == {"5m": 2, "1h": 38, "24h": 365}
    assert result["failed"] == {"5m": 0, "1h": 4, "24h": 15}
    assert result["capacity"]["status"] == "healthy"
    assert 0.0 <= result["capacity"]["saturation"] <= 1.0


def test_compute_throughput_saturation_clamped():
    from laddr.api.mission_control import _compute_throughput

    db = _make_db_mock({
        5: {"inbound": 0, "completed": 0, "failed": 0},
        15: {"inbound": 3, "completed": 5, "failed": 0},
        60: {"inbound": 5, "completed": 10, "failed": 0},  # more completed than inbound
        1440: {"inbound": 5, "completed": 10, "failed": 0},
    })

    result = _compute_throughput(db)
    assert result["capacity"]["saturation"] == 1.0  # clamped, not 2.0


def test_compute_throughput_none_database():
    from laddr.api.mission_control import _compute_throughput

    result = _compute_throughput(None)

    assert result["inbound"] == {"5m": 0, "1h": 0, "24h": 0}
    assert result["capacity"]["status"] == "healthy"


def test_capacity_warning_on_sustained_imbalance():
    """Capacity goes to warning when imbalance sustained 5+ minutes."""
    import laddr.api.mission_control as mc

    # Reset module-level state
    mc._imbalance_start_time = None

    # Imbalanced: inbound 15m > completed 15m * 1.2
    db = _make_db_mock({
        5: {"inbound": 10, "completed": 2, "failed": 0},
        15: {"inbound": 50, "completed": 20, "failed": 0},  # 50 > 20*1.2=24
        60: {"inbound": 100, "completed": 80, "failed": 0},
        1440: {"inbound": 500, "completed": 400, "failed": 0},
    })

    # First call — starts the imbalance timer, but not yet 5 min
    result = mc._compute_throughput(db)
    assert result["capacity"]["status"] == "healthy"
    assert mc._imbalance_start_time is not None

    # Simulate 6 minutes passing
    mc._imbalance_start_time = time.time() - 360

    result = mc._compute_throughput(db)
    assert result["capacity"]["status"] == "warning"


def test_capacity_critical_on_long_imbalance():
    """Capacity goes to critical when imbalance sustained 15+ minutes."""
    import laddr.api.mission_control as mc

    mc._imbalance_start_time = time.time() - 960  # 16 minutes ago

    db = _make_db_mock({
        5: {"inbound": 10, "completed": 2, "failed": 0},
        15: {"inbound": 50, "completed": 20, "failed": 0},
        60: {"inbound": 100, "completed": 80, "failed": 0},
        1440: {"inbound": 500, "completed": 400, "failed": 0},
    })

    result = mc._compute_throughput(db)
    assert result["capacity"]["status"] == "critical"


def test_capacity_resets_when_balanced():
    """Imbalance timer resets when system becomes balanced."""
    import laddr.api.mission_control as mc

    mc._imbalance_start_time = time.time() - 600  # was imbalanced

    db = _make_db_mock({
        5: {"inbound": 5, "completed": 5, "failed": 0},
        15: {"inbound": 20, "completed": 20, "failed": 0},  # 20 <= 20*1.2=24, balanced
        60: {"inbound": 80, "completed": 80, "failed": 0},
        1440: {"inbound": 400, "completed": 400, "failed": 0},
    })

    result = mc._compute_throughput(db)
    assert result["capacity"]["status"] == "healthy"
    assert mc._imbalance_start_time is None
