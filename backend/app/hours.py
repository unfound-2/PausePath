"""Conservative time-zone-aware hours. Unsupported raw OSM rules remain unknown."""
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

def timestamp(value):
    return datetime.fromisoformat(value.replace('Z', '+00:00'))

def minutes(value):
    hour, minute = map(int, value.split(':'))
    if not (0 <= hour <= 24 and 0 <= minute < 60 and (hour < 24 or minute == 0)):
        raise ValueError('Invalid local time')
    return hour*60+minute

def is_open(hours, arrival):
    if not hours: return None
    if isinstance(hours, str): return True if hours.strip() == '24/7' else None
    if not isinstance(hours, dict): return None
    if hours.get('raw') == '24/7': return True
    try:
        if 'windows' in hours:
            start = timestamp(hours['valid_from'])
            end = timestamp(hours['valid_until'])
            if not start.tzinfo or not end.tzinfo or not start <= arrival < end: return None
            for window in hours['windows']:
                opened = timestamp(window['start']); closed = timestamp(window['end'])
                if not opened.tzinfo or not closed.tzinfo: return None
                if opened <= arrival < closed: return True
            return False
        if 'weekly' not in hours: return None
        local = arrival.astimezone(ZoneInfo(hours['timezone']))
        exceptions = hours.get('exceptions', {})
        for day_offset in (0, -1):
            day = local.date() + timedelta(days=day_offset)
            rows = exceptions.get(day.isoformat())
            if rows is None:
                rows = [r for r in hours['weekly'] if r['weekday'] == day.weekday()]
            now_minutes = local.hour*60+local.minute - day_offset*1440
            for row in rows:
                opened, closed = minutes(row['open']), minutes(row['close'])
                if closed <= opened: closed += 1440
                # A date-specific closure also overrides an overnight spill into that date.
                if day_offset == -1 and local.date().isoformat() in exceptions: continue
                if opened <= now_minutes < closed: return True
        return False
    except (AttributeError, KeyError, TypeError, ValueError, ZoneInfoNotFoundError):
        return None


def open_during(hours, arrival, duration_seconds):
    """Check the whole half-open break, including closures between its endpoints."""
    end = arrival + timedelta(seconds=duration_seconds)
    points = {arrival}
    if duration_seconds > 0:
        points.add(end - timedelta(microseconds=1))
        # Weekly schedules change on minute boundaries. Absolute windows may
        # change at arbitrary seconds, so include all their boundaries as well.
        point = arrival.replace(second=0, microsecond=0) + timedelta(minutes=1)
        while point < end:
            points.add(point)
            point += timedelta(minutes=1)
        if isinstance(hours, dict) and 'windows' in hours:
            try:
                values = [hours['valid_from'], hours['valid_until']]
                values += [w[key] for w in hours['windows'] for key in ('start', 'end')]
                for value in values:
                    point = timestamp(value)
                    if not point.tzinfo: return None
                    if arrival <= point < end: points.add(point)
            except (KeyError, TypeError, ValueError, AttributeError):
                return None
    states = [is_open(hours, point) for point in points]
    if False in states: return False
    return True if all(state is True for state in states) else None
