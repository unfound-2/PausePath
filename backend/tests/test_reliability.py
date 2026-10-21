from datetime import datetime
from app.hours import normalize_osm_hours, is_open, enrich_poi


def date(text):
    return datetime.fromisoformat(text.replace("Z", "+00:00"))


def test_osm_weekly_hours_use_facility_timezone():
    hours = normalize_osm_hours({"raw": "Mo-Fr 08:00-18:00; Sa 09:00-13:00; Su off"}, -95.3698, 29.7604)
    assert hours["timezone"] == "America/Chicago"
    assert is_open(hours, date("2026-10-19T13:30:00Z")) is True
    assert is_open(hours, date("2026-10-19T23:00:00Z")) is False
    assert is_open(hours, date("2026-10-18T15:00:00Z")) is False


def test_unsupported_or_invalid_osm_rules_remain_unknown():
    for raw in ["Mo-Fr 08:00-18:00; PH off", "Mo 25:00-26:00"]:
        hours = normalize_osm_hours({"raw": raw}, -95.3698, 29.7604)
        assert "weekly" not in hours
        assert is_open(hours, date("2026-10-19T13:30:00Z")) is None


def test_normalized_overnight_uses_next_day():
    hours = normalize_osm_hours({"raw": "Mo 22:00-02:00"}, -74.006, 40.7128)
    assert is_open(hours, date("2026-10-20T05:30:00Z")) is True
    assert is_open(hours, date("2026-10-20T06:00:00Z")) is False


def test_inactive_poi_is_closed_and_verification_is_not_fabricated():
    row = enrich_poi({"is_active": False, "operating_hours": {"raw": "24/7"}}, date("2026-10-19T13:30:00Z"))
    assert row["hours_status"] == "closed"
    assert "last_verified_at" not in row
    assert "user_id" not in row
