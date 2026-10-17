from datetime import datetime
from typing import Any, Dict, List, Literal, Optional, Tuple, Union
from uuid import UUID
from pydantic import UUID4
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

Category = Literal['bench', 'toilet', 'drinking_water', 'cafe']
ReportType = Literal['confirm_exists', 'broken_or_empty', 'temporarily_closed', 'removed']

class StrictModel(BaseModel):
    model_config = ConfigDict(extra='forbid', allow_inf_nan=False)

class Point(StrictModel):
    type: Literal['Point'] = 'Point'
    coordinates: Tuple[float, float]
    @field_validator('coordinates')
    @classmethod
    def coordinates_valid(cls, value):
        if not (-180 <= value[0] <= 180 and -90 < value[1] < 90):
            raise ValueError('Use longitude, latitude in EPSG:4326; poles are unsupported')
        return value

class LineString(StrictModel):
    type: Literal['LineString'] = 'LineString'
    coordinates: List[Tuple[float, float]] = Field(min_length=2, max_length=5000)
    @field_validator('coordinates')
    @classmethod
    def line_valid(cls, value):
        for point in value:
            Point(coordinates=point)
        return value

class Attributes(StrictModel):
    backrest: Optional[bool] = None
    wheelchair_accessible: Optional[bool] = None
    shaded: Optional[bool] = None
    access: Optional[Literal['public','customers','private','unknown']] = None

class Preferences(StrictModel):
    target_break_interval_meters: float = Field(default=2000, ge=100, le=10000)
    prioritized_categories: List[Category] = Field(default_factory=lambda: ['bench','drinking_water','toilet','cafe'], min_length=1, max_length=4)
    require_wheelchair_accessible: bool = False
    allow_unknown_hours: bool = False
    break_duration_seconds: int = Field(default=300, ge=0, le=7200)
    max_connector_meters: float = Field(default=400, ge=0, le=1000)
    @field_validator('prioritized_categories')
    @classmethod
    def unique_categories(cls, value):
        if len(value) != len(set(value)): raise ValueError('Categories must be unique')
        return value

class CurateRequest(StrictModel):
    geometry: LineString
    movement_type: Literal['walk','run']
    departure_at: datetime
    speed_meters_per_second: Optional[float] = Field(default=None, ge=0.2, le=8)
    preferences: Preferences = Field(default_factory=Preferences)
    @field_validator('departure_at')
    @classmethod
    def aware_date(cls, value):
        if value.tzinfo is None: raise ValueError('departure_at must have a timezone offset')
        return value

class ExistingReport(StrictModel):
    kind: Literal['status'] = 'status'
    request_id: UUID
    poi_id: UUID
    report_type: ReportType

class Suggestion(StrictModel):
    kind: Literal['suggestion']
    request_id: UUID
    name: Optional[str] = Field(default=None, max_length=200)
    category: Category
    location: Point
    attributes: Attributes = Field(default_factory=Attributes)

class ReportReceipt(StrictModel):
    id: UUID
    kind: Literal['status','suggestion']
    status: str
    poi_id: Optional[UUID] = None
    confidence_score: Optional[float] = None
    is_active: Optional[bool] = None

class IngestRequest(StrictModel):
    south: float = Field(ge=-85, le=85)
    west: float = Field(ge=-180, le=180)
    north: float = Field(ge=-85, le=85)
    east: float = Field(ge=-180, le=180)
    @model_validator(mode='after')
    def bounded_area(self):
        if not (0 < self.north-self.south <= 0.1 and 0 < self.east-self.west <= 0.1):
            raise ValueError('Use a non-wrapping bbox no larger than 0.1 × 0.1 degrees; split larger/dateline areas')
        return self

class Review(StrictModel):
    decision: Literal['approve','reject']
    evidence: str = Field(min_length=20, max_length=2000)

class POIReview(StrictModel):
    is_active: bool
    evidence: str = Field(min_length=20, max_length=2000)
    # Normalized hours are validated/evaluated conservatively by the hours engine.
    operating_hours: Optional[Dict[str, Any]] = None
    attributes: Optional[Attributes] = None

class QueueEdit(StrictModel):
    poi_id: UUID
    action: Literal['add','remove']
    evidence: str = Field(min_length=20, max_length=2000)

class QueueReceipt(StrictModel):
    status: Literal['submitted','needs_reconciliation']
    changeset_id: int = Field(gt=0)

class MapboxCategorySearch(StrictModel):
    category: Literal['coffee', 'food_and_drink'] = 'coffee'
    proximity: Point
    bbox: Tuple[float, float, float, float]
    limit: int = Field(default=10, ge=1, le=25)
    language: str = Field(default='en', min_length=2, max_length=35, pattern=r'^[A-Za-z-]+$')
    @model_validator(mode='after')
    def bounded_viewport(self):
        west, south, east, north = self.bbox
        IngestRequest(west=west, south=south, east=east, north=north)
        lon, lat = self.proximity.coordinates
        if not west <= lon <= east or not south <= lat <= north:
            raise ValueError('proximity must be inside bbox')
        return self

class MapboxSuggest(StrictModel):
    query: str = Field(min_length=1, max_length=256)
    proximity: Point
    session_token: UUID4
    limit: int = Field(default=5, ge=1, le=10)
    language: str = Field(default='en', min_length=2, max_length=35, pattern=r'^[A-Za-z-]+$')

class MapboxRetrieve(StrictModel):
    mapbox_id: str = Field(min_length=1, max_length=512, pattern=r'^[A-Za-z0-9._:-]+$')
    session_token: UUID4
    language: str = Field(default='en', min_length=2, max_length=35, pattern=r'^[A-Za-z-]+$')

class MapboxResponse(StrictModel):
    provider: Literal['mapbox'] = 'mapbox'
    storage: Literal['temporary'] = 'temporary'
    arrival_hours_status: Literal['unknown'] = 'unknown'
    data: Dict[str, Any]

class POISummary(StrictModel):
    id: UUID
    name: Optional[str]
    category: Category
    confidence_score: float
    location: Point
    attributes: Dict[str, Any]
    source: Literal['osm','community']
    external_id: str

class Connector(StrictModel):
    outbound: LineString
    return_path: LineString = Field(alias='return')
    outbound_meters: float
    return_meters: float

class BreakPoint(StrictModel):
    target_distance_meters: float
    distance_marker_meters: float
    distance_from_target_meters: float
    arrival_at: datetime
    score: float
    hours_status: Literal['open','unknown']
    poi: POISummary
    connector: Connector

class RouteProperties(StrictModel):
    base_distance_meters: float
    total_distance_with_detours_meters: float
    movement_type: Literal['walk','run']
    speed_meters_per_second: float
    break_points: List[BreakPoint]
    unfilled_targets_meters: List[float]
    all_targets_filled: bool
    geometry_includes_detours: bool = False
    attribution: str = '© OpenStreetMap contributors; community reports by PausePath users'
    warnings: List[str]

class CuratedRoute(StrictModel):
    type: Literal['Feature'] = 'Feature'
    geometry: LineString
    properties: RouteProperties


class DiscoveryPOI(POISummary):
    is_active: bool
    operating_hours: Optional[Dict[str, Any]] = None
    closed_until: Optional[datetime] = None
    source_updated_at: Optional[datetime] = None

class DiscoveryResponse(StrictModel):
    loading_state: Literal['ready', 'loading', 'unavailable'] = 'ready'
    retry_after_seconds: int = 15
    tiles_ready: int = 0
    tiles_total: int = 0
    pois: List[DiscoveryPOI]
    truncated: bool
    warning: Optional[str] = None
    attribution: str
