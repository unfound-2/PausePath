from datetime import datetime, timezone
import pytest
from pydantic import ValidationError
from app.hours import is_open
from app.geometry import densify,at_distance,distance
from app.models import CurateRequest,Point,Preferences,ExistingReport


def test_hours_overnight_and_closing_boundary():
    hours={'timezone':'America/Chicago','weekly':[{'weekday':0,'open':'22:00','close':'02:00'}]}
    assert is_open(hours,datetime.fromisoformat('2026-10-13T01:00:00-05:00')) is True
    assert is_open(hours,datetime.fromisoformat('2026-10-13T02:00:00-05:00')) is False


def test_hours_dst_uses_place_timezone():
    hours={'timezone':'America/New_York','weekly':[{'weekday':0,'open':'09:00','close':'17:00'}]}
    assert is_open(hours,datetime.fromisoformat('2026-01-05T13:30:00+00:00')) is False
    assert is_open(hours,datetime.fromisoformat('2026-07-06T13:30:00+00:00')) is True


def test_date_exception_overrides_weekly_and_overnight():
    hours={'timezone':'UTC','weekly':[{'weekday':0,'open':'22:00','close':'02:00'}],'exceptions':{'2026-10-13':[]}}
    assert is_open(hours,datetime.fromisoformat('2026-10-13T01:00:00+00:00')) is False


def test_unknown_hours_and_window_horizon():
    date=datetime.now(timezone.utc)
    assert is_open(None,date) is None
    assert is_open({'raw':'Mo-Fr 08:00-17:00; PH off'},date) is None
    assert is_open({'raw':'24/7'},date) is True
    hours={'valid_from':'2026-10-01T00:00:00Z','valid_until':'2026-10-02T00:00:00Z','windows':[]}
    assert is_open(hours,datetime.fromisoformat('2026-10-01T12:00:00+00:00')) is False
    assert is_open(hours,datetime.fromisoformat('2026-10-03T12:00:00+00:00')) is None


def test_geodesic_targets_and_dateline():
    path,total=densify([(179.99,40),(-179.99,40)])
    marker=at_distance(path,total/2)
    assert abs(abs(marker[0])-180)<0.001
    assert max(distance(a,b) for a,b in zip(path,path[1:]))<=25.01
    assert abs(distance(path[0],marker)-total/2)<0.1


def test_route_limits():
    with pytest.raises(ValueError): densify([(0,0),(0,0)])
    with pytest.raises(ValueError): densify([(0,0),(20,20)])
    with pytest.raises(ValidationError): Point(coordinates=(190,0))
    with pytest.raises(ValidationError): Preferences(prioritized_categories=['bench','bench'])
    with pytest.raises(ValidationError): CurateRequest(geometry={'coordinates':[(0,0),(0,.01)]},movement_type='walk',departure_at='2026-10-01T12:00:00')


def test_client_cannot_supply_identity_or_report_timestamp():
    with pytest.raises(ValidationError):
        ExistingReport(request_id='00000000-0000-0000-0000-000000000001',poi_id='00000000-0000-0000-0000-000000000002',
                       report_type='confirm_exists',user_id='forged')


def test_break_rejects_closure_between_open_endpoints():
    from app.hours import open_during
    hours={'timezone':'UTC','weekly':[
        {'weekday':0,'open':'09:00','close':'12:01'},
        {'weekday':0,'open':'12:02','close':'17:00'}]}
    arrival=datetime.fromisoformat('2026-10-12T12:00:30+00:00')
    assert open_during(hours,arrival,180) is False
    assert open_during({'raw':'24/7'},arrival,180) is True
    assert open_during(['malformed'],arrival,180) is None
