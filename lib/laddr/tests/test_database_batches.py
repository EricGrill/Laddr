import uuid

import pytest

from laddr.core.database import DatabaseService


@pytest.fixture
def db(tmp_path):
    """Provide an isolated SQLite database for each test."""
    db_path = tmp_path / f"test-{uuid.uuid4()}.db"
    return DatabaseService(f"sqlite:///{db_path}")


def _create_batch(db: DatabaseService, task_count: int = 2) -> tuple[str, list[str]]:
    batch_id = str(uuid.uuid4())
    job_ids = [str(uuid.uuid4()) for _ in range(task_count)]
    task_ids = [str(uuid.uuid4()) for _ in range(task_count)]
    db.create_batch(
        batch_id=batch_id,
        agent_name="evaluator",
        task_count=task_count,
        job_ids=job_ids,
        task_ids=task_ids,
        inputs={"tasks": []},
    )
    db.update_batch_status(batch_id, "submitted")
    return batch_id, job_ids


def test_record_batch_task_result_transitions_to_running(db):
    batch_id, job_ids = _create_batch(db)

    summary = db.record_batch_task_result(
        batch_id=batch_id,
        job_id=job_ids[0],
        response={"status": "success", "result": {"score": 10}},
    )

    assert summary["status"] == "running"
    batch = db.get_batch(batch_id)
    assert batch["status"] == "running"
    assert batch["outputs"]["summary"]["recorded"] == 1
    assert batch["completed_at"] is None


def test_record_batch_task_result_marks_completed(db):
    batch_id, job_ids = _create_batch(db)

    for job_id in job_ids:
        summary = db.record_batch_task_result(
            batch_id=batch_id,
            job_id=job_id,
            response={"status": "success", "result": {"job": job_id}},
        )

    assert summary["status"] == "completed"
    batch = db.get_batch(batch_id)
    assert batch["status"] == "completed"
    assert batch["outputs"]["summary"]["succeeded"] == len(job_ids)
    assert batch["completed_at"] is not None


def test_record_batch_task_result_marks_failed_on_error(db):
    batch_id, job_ids = _create_batch(db)

    db.record_batch_task_result(
        batch_id=batch_id,
        job_id=job_ids[0],
        response={"status": "success", "result": {"job": job_ids[0]}},
    )
    summary = db.record_batch_task_result(
        batch_id=batch_id,
        job_id=job_ids[1],
        response={"status": "error", "error": "boom"},
    )

    assert summary["status"] == "failed"
    batch = db.get_batch(batch_id)
    assert batch["status"] == "failed"
    assert batch["outputs"]["summary"]["failed"] == 1
    assert batch["completed_at"] is not None

