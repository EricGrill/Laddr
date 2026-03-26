"""
Worker CLI commands for Laddr.

Provides commands for managing Laddr worker processes.
"""

import asyncio
import click


@click.group()
def worker():
    """Manage Laddr workers."""


@worker.command()
@click.option("--config", required=True, type=click.Path(exists=True), help="Path to worker.yml config file")
def start(config):
    """Start a Laddr worker process."""
    from laddr.core.worker_process import WorkerProcess
    click.echo(f"Starting worker with config: {config}")
    proc = WorkerProcess(config_path=config)
    asyncio.run(proc.start())
