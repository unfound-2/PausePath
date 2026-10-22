"""Member-only group plans and opt-in posts. No recorded journeys are published."""
from datetime import datetime, timezone
from uuid import UUID
from fastapi import APIRouter, Body, Depends, HTTPException
from .models import GoalDetails, GoalArchive
from .auth import identity
from .db import transaction

router = APIRouter(prefix='/api/v1/communities', tags=['community'])

def text_field(body, key, maximum, minimum=1):
    value = body.get(key)
    if not isinstance(value, str) or not minimum <= len(value.strip()) <= maximum:
        raise HTTPException(422, f'{key.replace("_", " ").capitalize()} must be {minimum}–{maximum} characters')
    return value.strip()

def request_id(body):
    try: return UUID(str(body.get('request_id')))
    except (ValueError, TypeError): raise HTTPException(422, 'A valid request ID is required')

def member(conn, group, user, owner=False):
    row = conn.execute('SELECT c.created_by FROM walking_communities c JOIN walking_community_members m ON m.community_id=c.id WHERE c.id=%s AND m.user_id=%s FOR UPDATE OF c', (group,user['sub'])).fetchone()
    if not row: raise HTTPException(403, 'Join this community first')
    if owner and row['created_by'] != user['sub']: raise HTTPException(403, 'Only the community owner can do this')
    return row['created_by'] == user['sub']

@router.post('/{group}/rename')
def rename(group: UUID, body: dict=Body(...), user=Depends(identity)):
    name = text_field(body,'name',60,2)
    with transaction() as conn:
        member(conn,group,user,True)
        conn.execute('UPDATE walking_communities SET name=%s WHERE id=%s',(name,group))
    return {'saved':True}

@router.post('/{group}/leave')
def leave(group: UUID, user=Depends(identity)):
    with transaction() as conn:
        if member(conn,group,user): raise HTTPException(409,'Transfer ownership before leaving, or delete your community')
        remove_member(conn,group,user['sub'])
    return {'saved':True}

def remove_member(conn,group,target):
    conn.execute('DELETE FROM walking_challenge_progress p USING walking_challenges c WHERE p.challenge_id=c.id AND c.community_id=%s AND p.user_id=%s',(group,target))
    conn.execute('DELETE FROM community_walk_rsvps r USING community_walks w WHERE r.walk_id=w.id AND w.community_id=%s AND r.user_id=%s',(group,target))
    conn.execute('DELETE FROM community_reactions r USING community_posts p WHERE r.post_id=p.id AND p.community_id=%s AND r.user_id=%s',(group,target))
    conn.execute('DELETE FROM community_posts WHERE community_id=%s AND user_id=%s',(group,target))
    conn.execute('UPDATE community_walks SET cancelled=true WHERE community_id=%s AND created_by=%s',(group,target))
    conn.execute('DELETE FROM walking_community_members WHERE community_id=%s AND user_id=%s',(group,target))

@router.get('/{group}/members')
def members(group: UUID, user=Depends(identity)):
    with transaction() as conn:
        member(conn,group,user,True)
        rows=conn.execute('SELECT user_id,display_name FROM walking_community_members WHERE community_id=%s ORDER BY display_name',(group,)).fetchall()
    return {'members':rows}

@router.post('/{group}/members/remove')
def remove(group: UUID, body: dict=Body(...), user=Depends(identity)):
    target=text_field(body,'user_id',200)
    with transaction() as conn:
        member(conn,group,user,True)
        if target == user['sub']: raise HTTPException(409,'Use transfer ownership or delete community')
        remove_member(conn,group,target)
    return {'saved':True}

@router.post('/{group}/transfer')
def transfer(group: UUID, body: dict=Body(...), user=Depends(identity)):
    target=text_field(body,'user_id',200)
    with transaction() as conn:
        member(conn,group,user,True)
        if not conn.execute('SELECT 1 FROM walking_community_members WHERE community_id=%s AND user_id=%s',(group,target)).fetchone(): raise HTTPException(404,'Member not found')
        conn.execute('UPDATE walking_communities SET created_by=%s WHERE id=%s',(target,group))
    return {'saved':True}

@router.post('/{group}/delete')
def delete(group: UUID, user=Depends(identity)):
    with transaction() as conn:
        member(conn,group,user,True)
        conn.execute('DELETE FROM walking_communities WHERE id=%s',(group,))
    return {'deleted':True}

@router.post('/{group}/challenges/{challenge}/delete')
def delete_task(group: UUID, challenge: UUID, user=Depends(identity)):
    with transaction() as conn:
        owner=member(conn,group,user)
        row=conn.execute('SELECT created_by FROM walking_challenges WHERE id=%s AND community_id=%s',(challenge,group)).fetchone()
        if not row: raise HTTPException(404,'Task not found')
        if not owner and row['created_by'] != user['sub']: raise HTTPException(403,'Only the task creator or group owner can delete it')
        conn.execute('DELETE FROM walking_challenges WHERE id=%s',(challenge,))
    return {'deleted':True}

@router.get('/{group}/walks')
def walks(group: UUID, user=Depends(identity)):
    with transaction() as conn:
        owner=member(conn,group,user)
        rows=conn.execute("""SELECT w.*, (w.created_by=%s OR %s) AS can_manage,
        (SELECT count(*) FROM community_walk_rsvps r WHERE r.walk_id=w.id) AS attendees,
        EXISTS(SELECT 1 FROM community_walk_rsvps r WHERE r.walk_id=w.id AND r.user_id=%s) AS attending
        FROM community_walks w WHERE community_id=%s AND starts_at > now()-interval '1 day' ORDER BY starts_at LIMIT 100""",(user['sub'],owner,user['sub'],group)).fetchall()
    return {'walks':rows}

@router.post('/{group}/walks')
def create_walk(group: UUID, body: dict=Body(...), user=Depends(identity)):
    from .main import rate_limit
    rate_limit(user,"group-walk",12)
    title=text_field(body,'title',80,2); meeting=text_field(body,'meeting_point',160)
    route=text_field(body,'route_description',500); key=request_id(body)
    try:
        start=datetime.fromisoformat(body.get('starts_at','').replace('Z','+00:00'))
        if start.tzinfo is None: raise ValueError()
    except (ValueError,TypeError,AttributeError): raise HTTPException(422,'Choose a valid date and timezone')
    with transaction() as conn:
        member(conn,group,user)
        conn.execute('SELECT pg_advisory_xact_lock(hashtextextended(%s,0))',(user['sub']+str(key),))
        old=conn.execute('SELECT * FROM community_walks WHERE created_by=%s AND request_id=%s',(user['sub'],key)).fetchone()
        if old:
            if old['community_id'] != group or old['title'] != title or old['meeting_point'] != meeting or old['route_description'] != route or old['starts_at'] != start: raise HTTPException(409,'This request changed. Review your entries and submit again.')
            return old
        if start <= datetime.now(timezone.utc): raise HTTPException(422,'Choose a future start time')
        row=conn.execute('INSERT INTO community_walks(community_id,created_by,request_id,title,meeting_point,route_description,starts_at) VALUES (%s,%s,%s,%s,%s,%s,%s) RETURNING *',(group,user['sub'],key,title,meeting,route,start)).fetchone()
    return row

@router.post('/{group}/walks/{walk}/rsvp')
def rsvp(group: UUID, walk: UUID, body: dict=Body(...), user=Depends(identity)):
    if type(body.get('attending')) is not bool: raise HTTPException(422,'Choose attending or not attending')
    with transaction() as conn:
        member(conn,group,user)
        if not conn.execute('SELECT 1 FROM community_walks WHERE id=%s AND community_id=%s AND NOT cancelled AND starts_at>now()', (walk,group)).fetchone(): raise HTTPException(409,'This walk is no longer accepting RSVPs')
        if body['attending']: conn.execute('INSERT INTO community_walk_rsvps VALUES (%s,%s) ON CONFLICT DO NOTHING',(walk,user['sub']))
        else: conn.execute('DELETE FROM community_walk_rsvps WHERE walk_id=%s AND user_id=%s',(walk,user['sub']))
    return {'saved':True}

@router.post('/{group}/walks/{walk}/cancel')
def cancel_walk(group: UUID, walk: UUID, user=Depends(identity)):
    with transaction() as conn:
        owner=member(conn,group,user)
        row=conn.execute('SELECT created_by FROM community_walks WHERE id=%s AND community_id=%s',(walk,group)).fetchone()
        if not row: raise HTTPException(404,'Walk not found')
        if not owner and row['created_by'] != user['sub']: raise HTTPException(403,'Only the organizer or owner can cancel')
        conn.execute('UPDATE community_walks SET cancelled=true WHERE id=%s',(walk,))
    return {'saved':True}

@router.get('/{group}/posts')
def posts(group: UUID, user=Depends(identity)):
    with transaction() as conn:
        owner=member(conn,group,user)
        rows=conn.execute("""SELECT p.id,p.body,p.created_at,m.display_name,
        (p.user_id=%s OR %s) AS can_delete,
        (SELECT count(*) FROM community_reactions r WHERE r.post_id=p.id) AS cheers,
        EXISTS(SELECT 1 FROM community_reactions r WHERE r.post_id=p.id AND r.user_id=%s) AS cheered
        FROM community_posts p JOIN walking_community_members m ON m.community_id=p.community_id AND m.user_id=p.user_id
        WHERE p.community_id=%s ORDER BY p.created_at DESC LIMIT 50""",(user['sub'],owner,user['sub'],group)).fetchall()
    return {'posts':rows}

@router.post('/{group}/posts')
def create_post(group: UUID, body: dict=Body(...), user=Depends(identity)):
    from .main import rate_limit
    rate_limit(user,'community-post',12)
    message=text_field(body,'body',280); key=request_id(body)
    with transaction() as conn:
        member(conn,group,user)
        conn.execute('SELECT pg_advisory_xact_lock(hashtextextended(%s,0))',(user['sub']+str(key),))
        old=conn.execute('SELECT community_id,body FROM community_posts WHERE user_id=%s AND request_id=%s',(user['sub'],key)).fetchone()
        if old:
            if old['community_id'] != group or old['body'] != message: raise HTTPException(409,'This request changed. Review your entries and submit again.')
            return {'saved':True}
        conn.execute('INSERT INTO community_posts(community_id,user_id,request_id,body) VALUES (%s,%s,%s,%s)',(group,user['sub'],key,message))
    return {'saved':True}

@router.post('/{group}/posts/{post}/cheer')
def cheer(group: UUID, post: UUID, body: dict=Body(...), user=Depends(identity)):
    if type(body.get('cheered')) is not bool: raise HTTPException(422,'Choose a reaction state')
    with transaction() as conn:
        member(conn,group,user)
        if not conn.execute('SELECT 1 FROM community_posts WHERE id=%s AND community_id=%s',(post,group)).fetchone(): raise HTTPException(404,'Post not found')
        if body['cheered']: conn.execute('INSERT INTO community_reactions VALUES (%s,%s) ON CONFLICT DO NOTHING',(post,user['sub']))
        else: conn.execute('DELETE FROM community_reactions WHERE post_id=%s AND user_id=%s',(post,user['sub']))
    return {'saved':True}

@router.post('/{group}/posts/{post}/delete')
def delete_post(group: UUID, post: UUID, user=Depends(identity)):
    with transaction() as conn:
        owner=member(conn,group,user)
        row=conn.execute('SELECT user_id FROM community_posts WHERE id=%s AND community_id=%s',(post,group)).fetchone()
        if not row: raise HTTPException(404,'Post not found')
        if not owner and row['user_id'] != user['sub']: raise HTTPException(403,'Only the author or owner can delete')
        conn.execute('DELETE FROM community_posts WHERE id=%s',(post,))
    return {'deleted':True}


def managed_goal(conn, group, challenge, user):
    owner = member(conn, group, user)
    row = conn.execute('SELECT created_by,metric,shared_goal,archived_at FROM walking_challenges WHERE id=%s AND community_id=%s FOR UPDATE', (challenge,group)).fetchone()
    if not row: raise HTTPException(404, 'Goal not found')
    if not owner and row['created_by'] != user['sub']:
        raise HTTPException(403, 'Only the goal creator or community owner can manage this goal')
    return row

@router.post('/{group}/challenges/{challenge}/edit')
def edit_goal(group: UUID, challenge: UUID, body: GoalDetails, user=Depends(identity)):
    with transaction() as conn:
        row = managed_goal(conn,group,challenge,user)
        if row['archived_at'] is not None: raise HTTPException(409, 'Restore this goal before editing it')
        if row['metric'] != body.metric or row['shared_goal'] != body.shared_goal:
            if conn.execute('SELECT 1 FROM walking_challenge_progress WHERE challenge_id=%s LIMIT 1',(challenge,)).fetchone():
                raise HTTPException(409, 'A goal with shared progress must keep its measure and group mode. Create a new goal instead.')
        conn.execute('UPDATE walking_challenges SET name=%s,metric=%s,target=%s,shared_goal=%s WHERE id=%s',
                     (body.name,body.metric,body.target,body.shared_goal,challenge))
    return {'saved':True}

@router.post('/{group}/challenges/{challenge}/archive')
def archive_goal(group: UUID, challenge: UUID, body: GoalArchive, user=Depends(identity)):
    with transaction() as conn:
        managed_goal(conn,group,challenge,user)
        conn.execute('UPDATE walking_challenges SET archived_at=CASE WHEN %s THEN coalesce(archived_at,now()) ELSE NULL END WHERE id=%s',(body.archived,challenge))
    return {'saved':True,'archived':body.archived}
