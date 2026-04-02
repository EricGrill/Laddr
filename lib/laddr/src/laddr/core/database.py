"""
Database layer with SQLAlchemy models and high-level API.

Provides Job, Trace, Memory, and AgentRegistry models.
All metrics and traces are stored internally (no external services).
"""

from __future__ import annotations

from collections.abc import Generator
from contextlib import contextmanager
from datetime import datetime, timedelta
import hashlib
import hmac
import json
import os
from typing import Any
import uuid

from sqlalchemy import JSON, Column, DateTime, Integer, String, create_engine, text
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import Session, sessionmaker
import logging

logger = logging.getLogger(__name__)

Base = declarative_base()


def _json_safe(value: Any) -> Any:
    """Best-effort JSON sanitization for arbitrary Python objects."""
    try:
        return json.loads(json.dumps(value, default=str))
    except Exception:
        return str(value)


def _iso_z(dt: datetime | None) -> str | None:
    """Convert datetime to ISO format with Z suffix (UTC)."""
    if not dt:
        return None
    # stored as naive UTC; normalize to Z-suffixed ISO for clients
    return dt.isoformat() + "Z"


class Job(Base):
    """Job execution record (legacy terminology)."""

    __tablename__ = "jobs"

    job_id = Column(String(36), primary_key=True)
    pipeline_name = Column(String(255), nullable=False)
    status = Column(String(50), default="pending")  # pending, running, completed, failed
    inputs = Column(JSON, nullable=False)
    outputs = Column(JSON, nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow)
    completed_at = Column(DateTime, nullable=True)


class PromptExecution(Base):
    """Prompt execution record (new terminology for pipeline/job)."""

    __tablename__ = "prompt_executions"

    prompt_id = Column(String(36), primary_key=True)
    prompt_name = Column(String(255), nullable=False)  # Agent/prompt name
    status = Column(String(50), default="pending")  # pending, running, completed, failed
    inputs = Column(JSON, nullable=False)
    outputs = Column(JSON, nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow)
    completed_at = Column(DateTime, nullable=True)


class Batch(Base):
    """Batch operation record for tracking parallel task execution."""

    __tablename__ = "batches"

    batch_id = Column(String(36), primary_key=True)  # Unique ID for the batch
    agent_name = Column(String(255), nullable=False)  # Primary agent (evaluator)
    status = Column(String(50), default="running")  # running, completed, failed, submitted
    task_count = Column(Integer, default=0)  # Number of tasks in batch
    job_ids = Column(JSON, nullable=True)  # List of job_ids for individual tasks in this batch
    task_ids = Column(JSON, nullable=True)  # List of task_ids for this batch
    inputs = Column(JSON, nullable=False)  # Original batch request
    outputs = Column(JSON, nullable=True)  # Final aggregated results
    created_at = Column(DateTime, default=datetime.utcnow)
    completed_at = Column(DateTime, nullable=True)


class Trace(Base):
    """Trace event for observability with hierarchical span support."""

    __tablename__ = "traces"

    id = Column(Integer, primary_key=True, autoincrement=True)
    job_id = Column(String(36), nullable=False, index=True)
    agent_name = Column(String(255), nullable=False, index=True)
    event_type = Column(String(100), nullable=False)  # task_start, task_complete, tool_call, etc.
    parent_id = Column(Integer, nullable=True, index=True)  # For hierarchical traces (span parent)
    payload = Column(JSON, nullable=False)
    timestamp = Column(DateTime, default=datetime.utcnow, index=True)


class Memory(Base):
    """Agent memory storage."""

    __tablename__ = "memory"

    id = Column(Integer, primary_key=True, autoincrement=True)
    agent_name = Column(String(255), nullable=False, index=True)
    job_id = Column(String(36), nullable=True, index=True)  # Optional: job-specific memory
    key = Column(String(255), nullable=False)
    value = Column(JSON, nullable=False)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)


class AgentRegistry(Base):
    """Agent registration and metadata."""

    __tablename__ = "agent_registry"

    agent_name = Column(String(255), primary_key=True)
    meta = Column(JSON, nullable=False)  # role, goal, tools, status, host_url, etc.
    last_seen = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)


class UserSession(Base):
    """Dashboard user session tracking."""

    __tablename__ = "user_sessions"

    id = Column(Integer, primary_key=True, autoincrement=True)
    session_id = Column(String(64), nullable=False, index=True, unique=True)
    username = Column(String(255), nullable=False, index=True)
    role = Column(String(50), nullable=False, default="read_only")
    login_at = Column(DateTime, default=datetime.utcnow, nullable=False, index=True)
    logout_at = Column(DateTime, nullable=True, index=True)
    duration_ms = Column(Integer, nullable=True)
    ip = Column(String(128), nullable=True)
    user_agent = Column(String(512), nullable=True)


class DashboardUser(Base):
    """Dashboard user credentials and role."""

    __tablename__ = "dashboard_users"

    id = Column(Integer, primary_key=True, autoincrement=True)
    username = Column(String(255), nullable=False, unique=True, index=True)
    password_hash = Column(String(255), nullable=False)
    role = Column(String(50), nullable=False, default="read_only")
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow, nullable=False)


class DatabaseService:
    """
    High-level database API.
    
    Provides methods for job management, tracing, memory, and agent registry.
    Supports both Postgres and SQLite.
    """

    def __init__(self, database_url: str, external_tracer: Any | None = None):
        """
        Initialize database service.
        
        Args:
            database_url: SQLAlchemy connection string
                         e.g., "postgresql://user:pass@host:5432/db"
                         or "sqlite:///./laddr.db" for local dev
        """
        # Fallback to SQLite if URL is None or connection fails
        if not database_url:
            logger.warning("DATABASE_URL not set, using local SQLite")
            database_url = "sqlite:///laddr.db"

        # Track final DB type so we can make backend-specific decisions (e.g., tracing)
        def _db_type_from_url(url: str) -> str:
            return url.split("://")[0] if "://" in url else "unknown"

        try:
            self.engine = create_engine(database_url, echo=False)
            # Test connection
            with self.engine.connect() as conn:
                conn.execute(text("SELECT 1"))
            logger.info(
                f"Connected to database: {database_url.split('@')[-1] if '@' in database_url else database_url}"
            )
        except Exception as e:
            db_type = _db_type_from_url(database_url)
            logger.warning(f"Failed to connect to {db_type} database: {e}")
            logger.info("Falling back to SQLite database")
            database_url = "sqlite:///laddr.db"
            self.engine = create_engine(database_url, echo=False)

        # Record the effective DB type after any fallbacks
        self._db_type: str = _db_type_from_url(database_url)
        # Traces are only supported when the effective backend is NOT Postgres.
        # This ensures that when users point DATABASE_URL/DB_BACKEND at Postgres,
        # trace rows are never written.
        self._tracing_backend_enabled: bool = self._db_type not in {"postgresql", "postgres"}
        self._trace_backend_warned: bool = False

        self.SessionLocal = sessionmaker(bind=self.engine)

        # Create tables if they don't exist
        Base.metadata.create_all(self.engine)

    def create_tables(self):
        """Create all database tables if they don't exist."""
        Base.metadata.create_all(self.engine)

    @contextmanager
    def get_session(self) -> Generator[Session, None, None]:
        """Context manager for database sessions."""
        session = self.SessionLocal()
        try:
            yield session
            session.commit()
        except Exception:
            session.rollback()
            raise
        finally:
            session.close()

    # Job management

    def create_job(self, job_id: str | None, pipeline: str, inputs: dict) -> str:
        """Create a new job record, or reuse existing if job_id already exists (for sequential chains)."""
        if job_id is None:
            job_id = str(uuid.uuid4())

        with self.get_session() as session:
            # Check if job already exists (for sequential mode where agents share job_id)
            existing_job = session.query(Job).filter_by(job_id=job_id).first()
            if existing_job:
                # Job already exists (e.g., from first agent in sequential chain)
                # Just return the job_id without creating a duplicate
                return job_id
            
            # Create new job
            job = Job(
                job_id=job_id,
                pipeline_name=pipeline,
                status="pending",
                inputs=inputs
            )
            session.add(job)

        return job_id

    def save_result(self, job_id: str, outputs: dict, status: str = "completed") -> None:
        """Save job result."""
        with self.get_session() as session:
            job = session.query(Job).filter_by(job_id=job_id).first()
            if job:
                job.outputs = outputs
                job.status = status
                job.completed_at = datetime.utcnow()

    def get_result(self, job_id: str) -> dict | None:
        """Get job result."""
        with self.get_session() as session:
            job = session.query(Job).filter_by(job_id=job_id).first()
            if not job:
                return None

            return {
                "job_id": job.job_id,
                "pipeline_name": job.pipeline_name,
                "status": job.status,
                "inputs": job.inputs,
                "outputs": job.outputs,
                "created_at": _iso_z(job.created_at),
                "completed_at": _iso_z(job.completed_at),
            }

    def list_jobs(self, limit: int = 50) -> list[dict]:
        """List recent jobs."""
        with self.get_session() as session:
            jobs = session.query(Job).order_by(Job.created_at.desc()).limit(limit).all()

            return [
                {
                    "job_id": job.job_id,
                    "pipeline_name": job.pipeline_name,
                    "status": job.status,
                    "created_at": _iso_z(job.created_at),
                }
                for job in jobs
            ]

    # Prompt execution management (new terminology)

    def create_prompt(self, prompt_id: str | None, prompt_name: str, inputs: dict) -> str:
        """Create a new prompt execution record."""
        if prompt_id is None:
            prompt_id = str(uuid.uuid4())

        with self.get_session() as session:
            prompt = PromptExecution(
                prompt_id=prompt_id,
                prompt_name=prompt_name,
                status="pending",
                inputs=inputs
            )
            session.add(prompt)

        return prompt_id

    def save_prompt_result(self, prompt_id: str, outputs: dict, status: str = "completed") -> None:
        """Save prompt execution result."""
        with self.get_session() as session:
            prompt = session.query(PromptExecution).filter_by(prompt_id=prompt_id).first()
            if prompt:
                prompt.outputs = outputs
                prompt.status = status
                prompt.completed_at = datetime.utcnow()

    def update_prompt_status(self, prompt_id: str, status: str) -> None:
        """Update prompt execution status only; set completed_at for terminal states."""
        terminal = {"completed", "failed", "error", "canceled"}
        with self.get_session() as session:
            prompt = session.query(PromptExecution).filter_by(prompt_id=prompt_id).first()
            if prompt:
                prompt.status = status
                if status in terminal and prompt.completed_at is None:
                    prompt.completed_at = datetime.utcnow()

    def get_prompt_result(self, prompt_id: str) -> dict | None:
        """Get prompt execution result."""
        with self.get_session() as session:
            prompt = session.query(PromptExecution).filter_by(prompt_id=prompt_id).first()
            if not prompt:
                return None

            return {
                "prompt_id": prompt.prompt_id,
                "prompt_name": prompt.prompt_name,
                "status": prompt.status,
                "inputs": prompt.inputs,
                "outputs": prompt.outputs,
                "created_at": _iso_z(prompt.created_at),
                "completed_at": _iso_z(prompt.completed_at),
            }

    def list_prompts(self, limit: int = 50) -> list[dict]:
        """List recent prompt executions."""
        with self.get_session() as session:
            prompts = session.query(PromptExecution).order_by(PromptExecution.created_at.desc()).limit(limit).all()

            return [
                {
                    "prompt_id": prompt.prompt_id,
                    "prompt_name": prompt.prompt_name,
                    "status": prompt.status,
                    "created_at": _iso_z(prompt.created_at),
                    "completed_at": _iso_z(prompt.completed_at),
                }
                for prompt in prompts
            ]

    def reap_zombie_jobs(self, max_age_minutes: int = 60) -> int:
        """Mark stuck pending/running prompt executions as failed.

        Returns the number of reaped rows.
        """
        cutoff = datetime.utcnow() - timedelta(minutes=max_age_minutes)
        with self.get_session() as session:
            zombies = (
                session.query(PromptExecution)
                .filter(
                    PromptExecution.status.in_(["pending", "running"]),
                    PromptExecution.created_at < cutoff,
                )
                .all()
            )
            for z in zombies:
                z.status = "failed"
                z.completed_at = datetime.utcnow()
                z.outputs = {"error": "Reaped: stuck in %s for >%d min" % (z.status, max_age_minutes)}
            return len(zombies)

    def count_executions_by_bucket(self, since_minutes: int) -> dict[str, int]:
        """Count PromptExecution rows by status within the last N minutes.

        Returns {"inbound": N, "completed": N, "failed": N} where:
        - inbound = rows with created_at in the window
        - completed = rows with completed_at in window and status="completed"
        - failed = rows with completed_at in window and status="failed"
        """
        from sqlalchemy import func

        cutoff = datetime.utcnow() - timedelta(minutes=since_minutes)
        with self.get_session() as session:
            inbound = (
                session.query(func.count())
                .select_from(PromptExecution)
                .filter(PromptExecution.created_at >= cutoff)
                .scalar()
            )
            completed = (
                session.query(func.count())
                .select_from(PromptExecution)
                .filter(
                    PromptExecution.completed_at >= cutoff,
                    PromptExecution.status == "completed",
                )
                .scalar()
            )
            failed = (
                session.query(func.count())
                .select_from(PromptExecution)
                .filter(
                    PromptExecution.completed_at >= cutoff,
                    PromptExecution.status == "failed",
                )
                .scalar()
            )
        return {"inbound": inbound, "completed": completed, "failed": failed}

    def get_job_traces(self, job_ids: str | list[str]) -> list[dict]:
        """Get all traces for one or more jobs."""
        if isinstance(job_ids, str):
            job_ids = [job_ids]
        with self.get_session() as session:
            traces = (
                session.query(Trace)
                .filter(Trace.job_id.in_(job_ids))
                .order_by(Trace.timestamp)
                .all()
            )

            return [
                {
                    "id": trace.id,
                    "job_id": trace.job_id,
                    "agent_name": trace.agent_name,
                    "event_type": trace.event_type,
                    "parent_id": trace.parent_id,  # Include parent_id for hierarchical traces
                    "payload": trace.payload,
                    "timestamp": _iso_z(trace.timestamp),
                }
                for trace in traces
            ]

    # Tracing
    
    @property
    def tracing_backend_enabled(self) -> bool:
        """
        Whether the current database backend supports trace storage.
        
        Traces are disabled when using Postgres as the effective backend.
        """
        return self._tracing_backend_enabled

    def append_trace(self, job_id: str, agent_name: str, event_type: str, payload: dict) -> None:
        """
        Append a trace event to the internal database.
        
        When the effective database backend is Postgres, trace storage is disabled and
        this becomes a no-op. This ensures observability data is never written into a
        Postgres database while still allowing jobs/results to be stored there.
        """
        # DB-based tracing is disabled on Postgres backends.
        if not self._tracing_backend_enabled:
            # Log once per process to aid debugging, but never raise.
            if not self._trace_backend_warned:
                logger.info(
                    "Trace storage is disabled for Postgres backend; "
                    "no trace rows will be written."
                )
                self._trace_backend_warned = True
            return
        
        # Fallback: write to internal DB.
        with self.get_session() as session:
            trace = Trace(
                job_id=job_id,
                agent_name=agent_name,
                event_type=event_type,
                payload=payload,
            )
            session.add(trace)

    def list_traces(self, agent: str | None = None, limit: int = 100) -> list[dict]:
        """List recent traces, optionally filtered by agent."""
        with self.get_session() as session:
            query = session.query(Trace)

            if agent:
                query = query.filter_by(agent_name=agent)

            traces = query.order_by(Trace.timestamp.desc()).limit(limit).all()

            return [
                {
                    "id": trace.id,
                    "job_id": trace.job_id,
                    "agent_name": trace.agent_name,
                    "event_type": trace.event_type,
                    "payload": trace.payload,
                    "timestamp": _iso_z(trace.timestamp),
                }
                for trace in traces
            ]

    def get_trace(self, trace_id: str) -> dict | None:
        """Get a single trace event by id with full payload."""
        with self.get_session() as session:
            trace = session.query(Trace).filter_by(id=trace_id).first()
            if not trace:
                return None
            return {
                "id": trace.id,
                "job_id": trace.job_id,
                "agent_name": trace.agent_name,
                "event_type": trace.event_type,
                "payload": trace.payload,
                "timestamp": _iso_z(trace.timestamp),
            }

    # Memory

    def memory_put(self, agent_name: str, key: str, value: Any, job_id: str | None = None) -> None:
        """Store a memory entry."""
        with self.get_session() as session:
            # Check if exists
            existing = session.query(Memory).filter_by(
                agent_name=agent_name,
                key=key,
                job_id=job_id
            ).first()

            if existing:
                existing.value = value
                existing.updated_at = datetime.utcnow()
            else:
                memory = Memory(
                    agent_name=agent_name,
                    job_id=job_id,
                    key=key,
                    value=value
                )
                session.add(memory)

    def memory_get(self, agent_name: str, key: str, job_id: str | None = None) -> Any:
        """Retrieve a memory entry."""
        with self.get_session() as session:
            memory = session.query(Memory).filter_by(
                agent_name=agent_name,
                key=key,
                job_id=job_id
            ).first()

            return memory.value if memory else None

    def memory_list(self, agent_name: str, job_id: str | None = None) -> dict[str, Any]:
        """List all memory entries for an agent."""
        with self.get_session() as session:
            query = session.query(Memory).filter_by(agent_name=agent_name)

            if job_id:
                query = query.filter_by(job_id=job_id)

            memories = query.all()

            return {mem.key: mem.value for mem in memories}

    # Agent registry

    def register_agent(self, agent_name: str, metadata: dict) -> None:
        """Register or update an agent in the registry."""
        with self.get_session() as session:
            existing = session.query(AgentRegistry).filter_by(agent_name=agent_name).first()

            if existing:
                existing.meta = metadata
                existing.last_seen = datetime.utcnow()
            else:
                registry = AgentRegistry(
                    agent_name=agent_name,
                    meta=metadata
                )
                session.add(registry)

    def list_agents(self) -> list[dict]:
        """List all registered agents with trace counts and last execution time."""
        with self.get_session() as session:
            agents = session.query(AgentRegistry).all()

            result = []
            for agent in agents:
                # Get trace count for this agent
                trace_count = session.query(Trace).filter_by(agent_name=agent.agent_name).count()
                
                # Get last execution time (most recent trace)
                last_trace = (
                    session.query(Trace)
                    .filter_by(agent_name=agent.agent_name)
                    .order_by(Trace.timestamp.desc())
                    .first()
                )
                last_executed = _iso_z(last_trace.timestamp) if last_trace else None
                
                result.append({
                    "agent_name": agent.agent_name,
                    "metadata": agent.meta,
                    "last_seen": _iso_z(agent.last_seen),
                    "trace_count": trace_count,
                    "last_executed": last_executed,
                })
            
            return result

    # User session tracking

    def start_user_session(
        self,
        session_id: str,
        username: str,
        role: str,
        ip: str | None = None,
        user_agent: str | None = None,
    ) -> dict[str, Any]:
        """Create (or update) a user session start record."""
        with self.get_session() as session:
            existing = session.query(UserSession).filter_by(session_id=session_id).first()
            now = datetime.utcnow()
            if existing:
                existing.username = username
                existing.role = role
                existing.login_at = now
                existing.logout_at = None
                existing.duration_ms = None
                existing.ip = ip
                existing.user_agent = user_agent
                record = existing
            else:
                record = UserSession(
                    session_id=session_id,
                    username=username,
                    role=role,
                    login_at=now,
                    ip=ip,
                    user_agent=user_agent,
                )
                session.add(record)
                session.flush()

            return self._session_to_dict(record)

    def end_user_session(self, session_id: str) -> dict[str, Any] | None:
        """Finalize a user session and store computed duration."""
        with self.get_session() as session:
            record = session.query(UserSession).filter_by(session_id=session_id).first()
            if not record:
                return None
            if record.logout_at is None:
                now = datetime.utcnow()
                record.logout_at = now
                record.duration_ms = int((now - record.login_at).total_seconds() * 1000)
            return self._session_to_dict(record)

    def list_user_sessions(self, limit: int = 100) -> list[dict[str, Any]]:
        """List recent user sessions."""
        with self.get_session() as session:
            sessions = (
                session.query(UserSession)
                .order_by(UserSession.login_at.desc())
                .limit(limit)
                .all()
            )
            return [self._session_to_dict(record) for record in sessions]

    def _session_to_dict(self, record: UserSession) -> dict[str, Any]:
        return {
            "id": record.id,
            "session_id": record.session_id,
            "username": record.username,
            "role": record.role,
            "login_at": _iso_z(record.login_at),
            "logout_at": _iso_z(record.logout_at),
            "duration_ms": record.duration_ms,
            "is_active": record.logout_at is None,
            "ip": record.ip,
            "user_agent": record.user_agent,
        }

    # Dashboard user management

    def _normalize_role(self, role: str | None) -> str:
        return "admin" if role == "admin" else "read_only"

    def _hash_password(self, password: str) -> str:
        """Store salted PBKDF2 hash as `pbkdf2_sha256$iterations$salt_hex$hash_hex`."""
        iterations = 390000
        salt = os.urandom(16)
        digest = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, iterations)
        return f"pbkdf2_sha256${iterations}${salt.hex()}${digest.hex()}"

    def _verify_password(self, password: str, encoded_hash: str) -> bool:
        try:
            algo, iter_s, salt_hex, digest_hex = encoded_hash.split("$", 3)
            if algo != "pbkdf2_sha256":
                return False
            iterations = int(iter_s)
            salt = bytes.fromhex(salt_hex)
            expected = bytes.fromhex(digest_hex)
            actual = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, iterations)
            return hmac.compare_digest(actual, expected)
        except Exception:
            return False

    def _parse_dash_users_env(self, dash_users: str | None) -> list[dict[str, str]]:
        parsed: list[dict[str, str]] = []
        if dash_users:
            entries = [entry.strip() for entry in dash_users.split(",") if entry.strip()]
            for entry in entries:
                username, password, role = (entry.split(":") + ["read_only"])[:3]
                if username and password:
                    parsed.append(
                        {
                            "username": username.strip(),
                            "password": password.strip(),
                            "role": self._normalize_role(role.strip()),
                        }
                    )
        if not parsed:
            parsed.append({"username": "admin", "password": "admin", "role": "admin"})
        return parsed

    def bootstrap_dashboard_users(self, dash_users: str | None) -> None:
        """
        Seed dashboard users from env when table is empty.
        Keeps backward compatibility with env-based auth.
        """
        with self.get_session() as session:
            existing_count = session.query(DashboardUser).count()
            if existing_count > 0:
                return

            for entry in self._parse_dash_users_env(dash_users):
                session.add(
                    DashboardUser(
                        username=entry["username"],
                        password_hash=self._hash_password(entry["password"]),
                        role=self._normalize_role(entry["role"]),
                    )
                )

    def verify_dashboard_user(self, username: str, password: str) -> dict[str, Any] | None:
        with self.get_session() as session:
            user = session.query(DashboardUser).filter_by(username=username).first()
            if not user:
                return None
            if not self._verify_password(password, user.password_hash):
                return None
            return self._dashboard_user_to_dict(user)

    def list_dashboard_users(self) -> list[dict[str, Any]]:
        with self.get_session() as session:
            users = session.query(DashboardUser).order_by(DashboardUser.username.asc()).all()
            return [self._dashboard_user_to_dict(user) for user in users]

    def create_dashboard_user(self, username: str, password: str, role: str) -> dict[str, Any]:
        with self.get_session() as session:
            existing = session.query(DashboardUser).filter_by(username=username).first()
            if existing:
                raise ValueError("User already exists")
            user = DashboardUser(
                username=username,
                password_hash=self._hash_password(password),
                role=self._normalize_role(role),
            )
            session.add(user)
            session.flush()
            return self._dashboard_user_to_dict(user)

    def delete_dashboard_user(self, username: str) -> bool:
        with self.get_session() as session:
            user = session.query(DashboardUser).filter_by(username=username).first()
            if not user:
                return False
            if user.role == "admin":
                admin_count = session.query(DashboardUser).filter_by(role="admin").count()
                if admin_count <= 1:
                    raise ValueError("Cannot delete the last admin user")
            session.delete(user)
            return True

    def _dashboard_user_to_dict(self, user: DashboardUser) -> dict[str, Any]:
        return {
            "id": user.id,
            "username": user.username,
            "role": self._normalize_role(user.role),
            "created_at": _iso_z(user.created_at),
            "updated_at": _iso_z(user.updated_at),
        }

    # Metrics (aggregated from traces and jobs)

    def get_metrics(self) -> dict[str, Any]:
        """Get aggregated metrics."""
        with self.get_session() as session:
            # Count both legacy Jobs and new PromptExecutions
            total_jobs = session.query(Job).count()
            total_prompts = session.query(PromptExecution).count()
            total_executions = total_jobs + total_prompts
            
            completed_jobs = session.query(Job).filter_by(status="completed").count()
            completed_prompts = session.query(PromptExecution).filter_by(status="completed").count()
            total_completed = completed_jobs + completed_prompts
            
            failed_jobs = session.query(Job).filter_by(status="failed").count()
            failed_prompts = session.query(PromptExecution).filter_by(status="failed").count()
            total_failed = failed_jobs + failed_prompts

            # Calculate average latency from both Jobs and PromptExecutions
            latencies = []
            
            # Get latencies from completed jobs
            completed = session.query(Job).filter_by(status="completed").all()
            for job in completed:
                if job.created_at and job.completed_at:
                    delta = (job.completed_at - job.created_at).total_seconds()
                    latencies.append(delta)
            
            # Get latencies from completed prompts
            completed_prompts_list = session.query(PromptExecution).filter_by(status="completed").all()
            for prompt in completed_prompts_list:
                if prompt.created_at and prompt.completed_at:
                    delta = (prompt.completed_at - prompt.created_at).total_seconds()
                    latencies.append(delta)

            avg_latency_sec = sum(latencies) / len(latencies) if latencies else 0

            # Active agents (from registry)
            active_agents = session.query(AgentRegistry).count()

            # Tool calls (from traces)
            tool_calls = session.query(Trace).filter_by(event_type="tool_call").count()

            # Cache hits (from traces)
            cache_hits = session.query(Trace).filter_by(event_type="cache_hit").count()

            # Total tokens from llm_usage traces
            llm_usage_traces = session.query(Trace).filter_by(event_type="llm_usage").all()
            total_tokens = 0
            for trace in llm_usage_traces:
                payload = trace.payload or {}
                total_tokens += int(payload.get("total_tokens") or 0)

            return {
                "total_jobs": total_executions,
                "completed_jobs": total_completed,
                "failed_jobs": total_failed,
                "avg_latency_ms": int(avg_latency_sec * 1000),
                "active_agents_count": active_agents,
                "tool_calls": tool_calls,
                "cache_hits": cache_hits,
                "total_tokens": total_tokens,
            }

    # Token usage metrics aggregated from llm_usage traces
    def get_token_usage(self, job_id: str) -> dict:
        """Aggregate token usage for a job from llm_usage traces."""
        with self.get_session() as session:
            traces = (
                session.query(Trace)
                .filter_by(job_id=job_id, event_type="llm_usage")
                .all()
            )
            total_prompt = 0
            total_completion = 0
            total = 0
            breakdown: dict[tuple[str | None, str | None], dict] = {}
            for tr in traces:
                payload = tr.payload or {}
                pt = int(payload.get("prompt_tokens") or 0)
                ct = int(payload.get("completion_tokens") or 0)
                tt = int(payload.get("total_tokens") or (pt + ct))
                prov = payload.get("provider")
                model = payload.get("model")
                total_prompt += pt
                total_completion += ct
                total += tt
                key = (prov, model)
                if key not in breakdown:
                    breakdown[key] = {
                        "provider": prov,
                        "model": model,
                        "prompt_tokens": 0,
                        "completion_tokens": 0,
                        "total_tokens": 0,
                        "calls": 0,
                    }
                breakdown[key]["prompt_tokens"] += pt
                breakdown[key]["completion_tokens"] += ct
                breakdown[key]["total_tokens"] += tt
                breakdown[key]["calls"] += 1

            return {
                "prompt_tokens": total_prompt,
                "completion_tokens": total_completion,
                "total_tokens": total,
                "by_model": list(breakdown.values()),
            }

    # Batch management methods
    def create_batch(
        self,
        batch_id: str,
        agent_name: str,
        task_count: int,
        job_ids: list[str],
        task_ids: list[str],
        inputs: dict,
    ) -> None:
        """Create a new batch record."""
        with self.get_session() as session:
            batch = Batch(
                batch_id=batch_id,
                agent_name=agent_name,
                status="running",
                task_count=task_count,
                job_ids=job_ids,
                task_ids=task_ids,
                inputs=inputs,
            )
            session.add(batch)

    def get_batch(self, batch_id: str) -> dict | None:
        """Get batch by ID."""
        with self.get_session() as session:
            query = session.query(Batch).filter_by(batch_id=batch_id)
            if self._db_type in {"postgresql", "postgres"}:
                try:
                    query = query.with_for_update()
                except Exception:
                    pass
            batch = query.first()
            if not batch:
                return None
            return {
                "batch_id": batch.batch_id,
                "agent_name": batch.agent_name,
                "status": batch.status,
                "task_count": batch.task_count,
                "job_ids": batch.job_ids or [],
                "task_ids": batch.task_ids or [],
                "inputs": batch.inputs,
                "outputs": batch.outputs,
                "created_at": _iso_z(batch.created_at),
                "completed_at": _iso_z(batch.completed_at),
            }

    def update_batch_status(
        self,
        batch_id: str,
        status: str,
        outputs: dict | None = None,
        completed_tasks: int | None = None,
        failed_tasks: int | None = None,
    ) -> None:
        """Update batch status and optionally outputs."""
        with self.get_session() as session:
            batch = session.query(Batch).filter_by(batch_id=batch_id).first()
            if not batch:
                return
            batch.status = status
            if outputs is not None:
                batch.outputs = outputs
            if status in ("completed", "failed") and batch.completed_at is None:
                batch.completed_at = datetime.utcnow()

    def add_tasks_to_batch(
        self,
        batch_id: str,
        new_job_ids: list[str],
        new_task_ids: list[str],
        inputs: dict | None = None,
    ) -> None:
        """Add more tasks to an existing batch."""
        with self.get_session() as session:
            batch = session.query(Batch).filter_by(batch_id=batch_id).first()
            if not batch:
                return
            existing_job_ids = batch.job_ids or []
            existing_task_ids = batch.task_ids or []
            batch.job_ids = existing_job_ids + new_job_ids
            batch.task_ids = existing_task_ids + new_task_ids
            batch.task_count = len(batch.job_ids)
            if inputs is not None:
                batch.inputs = inputs

    def record_batch_task_result(
        self,
        batch_id: str,
        job_id: str,
        response: dict,
        *,
        status: str | None = None,
        metadata: dict | None = None,
    ) -> dict | None:
        """
        Record per-task batch results and auto-update batch status.
        
        Args:
            batch_id: Parent batch identifier.
            job_id: Job/task identifier being recorded.
            response: Full response payload from the worker/agent.
            status: Optional explicit status override (defaults to response["status"]).
            metadata: Optional metadata to associate with the task entry.
        
        Returns:
            Summary dict with counts, or None if batch not found.
        """
        success_states = {"success", "completed"}
        failure_states = {"failed", "error"}

        normalized_status = (status or response.get("status") or "success").lower()

        with self.get_session() as session:
            batch = session.query(Batch).filter_by(batch_id=batch_id).first()
            if not batch:
                return None

            # Work on defensive copies so SQLAlchemy change tracking is triggered
            outputs = _json_safe(batch.outputs or {})
            results_map: dict = dict(outputs.get("results") or {})

            results_map[job_id] = {
                "status": normalized_status,
                "response": _json_safe(response),
                "metadata": _json_safe(
                    {
                        **(metadata or {}),
                        "recorded_at": _iso_z(datetime.utcnow()),
                    }
                ),
            }

            outputs["results"] = results_map

            success_count = sum(
                1 for entry in results_map.values() if entry.get("status") in success_states
            )
            failure_count = sum(
                1 for entry in results_map.values() if entry.get("status") in failure_states
            )
            recorded = len(results_map)
            total_expected = batch.task_count or recorded

            outputs["summary"] = {
                "total_expected": total_expected,
                "recorded": recorded,
                "succeeded": success_count,
                "failed": failure_count,
            }
            # Reassign sanitized copy so SQLAlchemy detects JSON mutation
            batch.outputs = _json_safe(outputs)

            # Transition batch state automatically
            if batch.status == "submitted":
                batch.status = "running"

            if recorded >= total_expected:
                batch.status = "failed" if failure_count > 0 else "completed"
                if batch.completed_at is None:
                    batch.completed_at = datetime.utcnow()

            session.flush()

            return {
                "status": batch.status,
                "recorded": recorded,
                "succeeded": success_count,
                "failed": failure_count,
            }

    def list_batches(self, limit: int = 50) -> list[dict]:
        """List recent batches."""
        with self.get_session() as session:
            batches = (
                session.query(Batch)
                .order_by(Batch.created_at.desc())
                .limit(limit)
                .all()
            )
            return [
                {
                    "batch_id": batch.batch_id,
                    "agent_name": batch.agent_name,
                    "status": batch.status,
                    "task_count": batch.task_count,
                    "job_ids": batch.job_ids or [],
                    "task_ids": batch.task_ids or [],
                    "created_at": _iso_z(batch.created_at),
                    "completed_at": _iso_z(batch.completed_at),
                }
                for batch in batches
            ]
