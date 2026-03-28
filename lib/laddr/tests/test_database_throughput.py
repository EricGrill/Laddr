import uuid
from datetime import datetime, timedelta

import pytest

from laddr.core.database import DatabaseService


@pytest.fixture
def db(tmp_path):
    db_path = tmp_path / f"test-{uuid.uuid4()}.db"
    return DatabaseService(f"sqlite:///{db_path}")


def _create_prompt(db, name="test-agent", status="pending", created_ago_min=0, completed_ago_min=None):
    """Helper: create a PromptExecution with controlled timestamps."""
    prompt_id = str(uuid.uuid4())
    db.create_prompt(prompt_id=prompt_id, prompt_name=name, inputs={"task": "test"})
    if status != "pending":
        outputs = {"result": "ok"} if status == "completed" else {"error": "boom"}
        db.save_prompt_result(prompt_id, outputs, status)
    # Backdate timestamps directly via session
    from laddr.core.database import PromptExecution
    with db.get_session() as session:
        row = session.query(PromptExecution).filter_by(prompt_id=prompt_id).one()
        row.created_at = datetime.utcnow() - timedelta(minutes=created_ago_min)
        if completed_ago_min is not None:
            row.completed_at = datetime.utcnow() - timedelta(minutes=completed_ago_min)
        session.commit()
    return prompt_id


def test_count_executions_empty_db(db):
    result = db.count_executions_by_bucket(since_minutes=60)
    assert result == {"inbound": 0, "completed": 0, "failed": 0}


def test_count_executions_inbound_within_window(db):
    _create_prompt(db, created_ago_min=2)  # 2 min ago — inside 5min window
    _create_prompt(db, created_ago_min=10)  # 10 min ago — outside 5min window

    result = db.count_executions_by_bucket(since_minutes=5)
    assert result["inbound"] == 1

    result = db.count_executions_by_bucket(since_minutes=60)
    assert result["inbound"] == 2


def test_count_executions_completed_and_failed(db):
    _create_prompt(db, status="completed", created_ago_min=3, completed_ago_min=1)
    _create_prompt(db, status="failed", created_ago_min=4, completed_ago_min=2)
    _create_prompt(db, status="completed", created_ago_min=90, completed_ago_min=80)  # outside 1hr

    result = db.count_executions_by_bucket(since_minutes=60)
    assert result["completed"] == 1
    assert result["failed"] == 1


def test_count_executions_pending_not_counted_as_completed(db):
    _create_prompt(db, status="pending", created_ago_min=1)

    result = db.count_executions_by_bucket(since_minutes=5)
    assert result["inbound"] == 1
    assert result["completed"] == 0
    assert result["failed"] == 0
