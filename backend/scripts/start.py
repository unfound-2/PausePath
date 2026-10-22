"""Free Render-compatible startup: apply checked migrations before serving traffic."""
import os
from pathlib import Path
import subprocess
import sys


def main():
    subprocess.run([sys.executable, str(Path(__file__).with_name('migrate.py'))], check=True)
    port = int(os.environ.get('PORT', '10000'))
    if not 1 <= port <= 65535:
        raise ValueError('PORT must be between 1 and 65535')
    os.execv(sys.executable, [sys.executable, '-m', 'uvicorn', 'app.main:app', '--host', '0.0.0.0', '--port', str(port), '--no-access-log'])


if __name__ == '__main__':
    main()
