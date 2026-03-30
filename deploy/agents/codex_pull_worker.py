#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path


BASE_URL = "https://laddr.chainbytes.io"
API_KEY = "628d73c47741dabd9d077d7df5ae4c05ffaada3a5fb5263f"
AGENT_ID = "codex-agent-01"
AGENT_NAME = "Codex (OpenAI)"
SKILLS = ["coding", "code-review", "refactoring", "debugging", "testing", "devops"]
MODELS = ["codex-gpt-5.4"]
MAX_CONCURRENT = 1
HEARTBEAT_SECONDS = 120
IDLE_POLL_SECONDS = 10
JOB_CLAIM_LIMIT = 1


@dataclass
class Config:
    base_url: str = BASE_URL
    api_key: str = API_KEY
    agent_id: str = AGENT_ID
    agent_name: str = AGENT_NAME
    skills: list[str] = None  # type: ignore[assignment]
    models: list[str] = None  # type: ignore[assignment]
    max_concurrent: int = MAX_CONCURRENT
    heartbeat_seconds: int = HEARTBEAT_SECONDS
    idle_poll_seconds: int = IDLE_POLL_SECONDS
    workdir: Path = Path.cwd()

    def __post_init__(self) -> None:
        if self.skills is None:
            self.skills = list(SKILLS)
        if self.models is None:
            self.models = list(MODELS)


STOP = False


def _handle_signal(signum: int, _frame: object) -> None:
    global STOP
    STOP = True
    print(f"[worker] received signal {signum}, shutting down", flush=True)


def api_request(config: Config, method: str, path: str, body: dict | None = None) -> dict:
    url = urllib.parse.urljoin(config.base_url, path)
    data = None
    headers = {"X-API-Key": config.api_key}
    if body is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode("utf-8")
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {exc.code} for {path}: {detail}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"Request failed for {path}: {exc}") from exc


def register_worker(config: Config) -> None:
    payload = {
        "agent_id": config.agent_id,
        "name": config.agent_name,
        "skills": config.skills,
        "models": config.models,
        "max_concurrent": config.max_concurrent,
        "metadata": {"version": "1.0", "runtime": "codex-cli-worker"},
    }
    response = api_request(config, "POST", "/api/agent-workers/register", payload)
    ttl = response.get("ttl_seconds", "unknown")
    print(f"[worker] registered {config.agent_id} ttl={ttl}s", flush=True)


def claim_jobs(config: Config) -> list[dict]:
    query = urllib.parse.urlencode(
        {
            "agent_id": config.agent_id,
            "limit": JOB_CLAIM_LIMIT,
            "explicit_only": "true",
        }
    )
    response = api_request(config, "POST", f"/api/agent-workers/claim?{query}")
    return response.get("claimed", [])


def build_prompt(job: dict) -> str:
    system_prompt = job.get("system_prompt", "").strip()
    user_prompt = job.get("user_prompt", "").strip()
    inputs = job.get("inputs", {})
    requirements = job.get("requirements", {})

    parts = []
    if system_prompt:
        parts.append(system_prompt)
    if user_prompt:
        parts.append("\nUser request:\n" + user_prompt)
    if inputs:
        parts.append("\nStructured inputs:\n" + json.dumps(inputs, indent=2, sort_keys=True))
    if requirements:
        parts.append("\nJob requirements:\n" + json.dumps(requirements, indent=2, sort_keys=True))
    return "\n".join(parts).strip() + "\n"


def run_job(config: Config, job: dict) -> tuple[str, dict]:
    job_id = job.get("job_id", "")
    prompt = build_prompt(job)
    print(f"[worker] running job {job_id}", flush=True)
    proc = subprocess.run(
        ["codex", "exec", "--sandbox", "danger-full-access"],
        input=prompt,
        text=True,
        capture_output=True,
        cwd=str(config.workdir),
    )
    stdout = proc.stdout.strip()
    stderr = proc.stderr.strip()
    response_text = stdout or stderr or f"codex exited with status {proc.returncode} and produced no output"
    status = "completed" if proc.returncode == 0 else "failed"
    summary = response_text.splitlines()[0][:200] if response_text else f"Job {status}"
    result = {
        "response": response_text,
        "summary": summary,
        "exit_code": proc.returncode,
    }
    if stderr:
        result["stderr"] = stderr[-4000:]
    return status, result


def submit_result(config: Config, job_id: str, status: str, result: dict) -> None:
    payload = {"status": status, "result": result}
    api_request(config, "POST", f"/api/agent-workers/{job_id}/result", payload)
    print(f"[worker] submitted {status} for {job_id}", flush=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run the Codex Laddr pull worker.")
    parser.add_argument("--once", action="store_true", help="Register and perform a single claim cycle.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    config = Config()
    signal.signal(signal.SIGINT, _handle_signal)
    signal.signal(signal.SIGTERM, _handle_signal)

    last_heartbeat = 0.0
    while not STOP:
        now = time.time()
        if now - last_heartbeat >= config.heartbeat_seconds:
            try:
                register_worker(config)
                last_heartbeat = now
            except Exception as exc:
                print(f"[worker] heartbeat failed: {exc}", file=sys.stderr, flush=True)
                time.sleep(10)
                continue

        try:
            claimed = claim_jobs(config)
        except Exception as exc:
            print(f"[worker] claim failed: {exc}", file=sys.stderr, flush=True)
            time.sleep(10)
            continue

        if not claimed:
            if args.once:
                return 0
            time.sleep(config.idle_poll_seconds)
            continue

        for job in claimed:
            job_id = job.get("job_id", "")
            try:
                status, result = run_job(config, job)
            except Exception as exc:
                status = "failed"
                result = {
                    "response": f"Worker exception while executing {job_id}: {exc}",
                    "summary": f"Worker exception for {job_id}",
                }
            try:
                submit_result(config, job_id, status, result)
            except Exception as exc:
                print(f"[worker] submit failed for {job_id}: {exc}", file=sys.stderr, flush=True)
        if args.once:
            return 0

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
