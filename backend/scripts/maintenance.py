"""Run daily: recalculate expiring votes and prune non-content rate counters."""
import sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from app.db import transaction
with transaction() as conn:
    ids=conn.execute('SELECT DISTINCT poi_id FROM poi_reports').fetchall()
for row in ids:
    with transaction() as conn: conn.execute('SELECT update_poi_confidence(%s)',(row['poi_id'],))
with transaction() as conn:
    conn.execute("DELETE FROM api_rate_buckets WHERE window_start<now()-interval '2 days'")
