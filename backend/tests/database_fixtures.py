"""Non-spatial schema shared by isolated community and social API tests."""
from pathlib import Path

def create_community_schema(conn):
    migrations=Path(__file__).resolve().parents[1]/'migrations'
    for name in ['20261017170000_community_challenges.sql','20261022045314_community_goal_lifecycle.sql','20261022090000_community_features.sql','20261023010527_social_routes_and_notifications.sql']:
        conn.execute((migrations/name).read_text())
    initial=(migrations/'001_initial.sql').read_text()
    conn.execute(initial[initial.index('CREATE TABLE api_request_receipts'):initial.index('CREATE TABLE api_rate_buckets')])
