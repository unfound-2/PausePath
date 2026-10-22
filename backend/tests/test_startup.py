"""Deployment must not serve requests after a migration failure."""
import importlib.util
from pathlib import Path
import subprocess
import pytest


def startup_module():
    spec = importlib.util.spec_from_file_location('pausepath_startup', Path(__file__).resolve().parents[1] / 'scripts/start.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_migration_failure_prevents_server_start(monkeypatch):
    module = startup_module()
    def failure(*args, **kwargs): raise subprocess.CalledProcessError(1, 'migration')
    monkeypatch.setattr(module.subprocess, 'run', failure)
    monkeypatch.setattr(module.os, 'execv', lambda *args: pytest.fail('Server started after failed migration'))
    with pytest.raises(subprocess.CalledProcessError): module.main()
