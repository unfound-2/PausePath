from contextlib import contextmanager
from datetime import datetime,timezone
from uuid import uuid4
import pytest
from app.models import CurateRequest,CuratedRoute
import app.curation as engine


def request(**preferences):
    return CurateRequest(geometry={'type':'LineString','coordinates':[(0,0),(.04,0)]},
        movement_type='walk',departure_at='2026-10-15T09:00:00Z',speed_meters_per_second=1,
        preferences={'target_break_interval_meters':2000,'break_duration_seconds':300,**preferences})


def install_rows(monkeypatch, hours='24/7'):
    ids={}
    class Connection:
        def execute(self,query,params):
            target=params['target']; ids.setdefault(target,uuid4())
            self.rows=[{'id':ids[target],'name':'Test bench','category':'bench','confidence_score':.8,
                'source':'community','external_id':str(target),'attributes':{},'closed_until':None,
                'operating_hours':hours,'location':{'type':'Point','coordinates':[params['lon'],.0001]},
                'attachment':{'type':'Point','coordinates':[params['lon'],0]},
                'marker_m':target,'target_distance':11.1,'score':4*.8/12.1}]
            return self
        def fetchall(self): return self.rows
    @contextmanager
    def transaction(): yield Connection()
    monkeypatch.setattr(engine,'transaction',transaction)


def connector(a,b,limit):
    return {'outbound':{'type':'LineString','coordinates':[a,b]},'return':{'type':'LineString','coordinates':[b,a]},
            'outbound_meters':50.,'return_meters':50.}


def test_arrival_accounts_for_detours_and_previous_breaks(monkeypatch):
    install_rows(monkeypatch)
    result=CuratedRoute.model_validate(engine.curate(request(),connector))
    points=result.properties.break_points
    assert len(points)==2
    assert (points[0].arrival_at-request().departure_at).total_seconds()==2050
    assert (points[1].arrival_at-request().departure_at).total_seconds()==4450
    assert result.properties.total_distance_with_detours_meters==pytest.approx(result.properties.base_distance_meters+200)
    assert result.properties.geometry_includes_detours is False


def test_disconnected_pois_never_selected(monkeypatch):
    install_rows(monkeypatch)
    result=engine.curate(request(),lambda *_:None)
    assert result['properties']['break_points']==[]
    assert result['properties']['unfilled_targets_meters']==[2000,4000]
    assert result['properties']['all_targets_filled'] is False


def test_unknown_hours_require_explicit_opt_in(monkeypatch):
    install_rows(monkeypatch,hours=None)
    assert not engine.curate(request(),connector)['properties']['break_points']
    result=engine.curate(request(allow_unknown_hours=True),connector)
    assert all(p['hours_status']=='unknown' for p in result['properties']['break_points'])


def test_closed_hours_never_override_with_unknown_opt_in(monkeypatch):
    install_rows(monkeypatch,hours={'timezone':'UTC','weekly':[]})
    assert not engine.curate(request(allow_unknown_hours=True),connector)['properties']['break_points']
