import json
import sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from app.main import app
Path(__file__).resolve().parents[1].joinpath('openapi.json').write_text(json.dumps(app.openapi(),indent=2)+'\n')
