"""Opt-in directory, mutual friendships, private invitations and a scoped inbox.

Server-only tables follow the existing API authorization model. No email, account
subject, activity recording or precise location is returned by directory search.
"""
from uuid import UUID
from datetime import datetime
from typing import Optional
from typing import Literal
from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import Field, StrictBool
from .models import StrictModel
from .auth import identity
from .db import transaction

router = APIRouter(prefix='/api/v1/social', tags=['social'])

class ProfileSettings(StrictModel):
    username: str = Field(pattern=r'^[a-z0-9_]{3,24}$')
    discoverable: StrictBool = False
    allow_requests: StrictBool = True
    allow_walk_invites: StrictBool = True
    notify_invites: StrictBool = True
    notify_walks: StrictBool = True
    notify_goals: StrictBool = True

class NotificationPreferences(StrictModel):
    notify_invites: StrictBool
    notify_walks: StrictBool
    notify_goals: StrictBool

class Target(StrictModel):
    person_id: UUID

class FriendshipAction(StrictModel):
    action: Literal['accept','decline','cancel','remove']

class InvitationAction(StrictModel):
    accept: StrictBool

class NotificationRead(StrictModel):
    ids: list[UUID] = Field(min_length=1,max_length=100)


class PublicProfile(ProfileSettings):
    id: UUID

class ProfileResponse(StrictModel):
    profile: Optional[PublicProfile]

class PublicPerson(StrictModel):
    id: UUID
    username: str

class PeopleResponse(StrictModel):
    people: list[PublicPerson]

class FriendRow(StrictModel):
    id: UUID
    status: Literal['pending','accepted']
    incoming: bool
    person_id: UUID
    username: str

class FriendsResponse(StrictModel):
    friends: list[FriendRow]

class InboxItem(StrictModel):
    id: UUID
    category: Literal['invites','walks','goals']
    message: str
    community_id: Optional[UUID]
    walk_id: Optional[UUID]
    created_at: datetime
    read_at: Optional[datetime]

class InboxResponse(StrictModel):
    notifications: list[InboxItem]

class WalkReminder(StrictModel):
    id: UUID
    title: str
    starts_at: datetime

class RemindersResponse(StrictModel):
    walks: list[WalkReminder]

class WalkInvitation(StrictModel):
    id: UUID
    walk_id: UUID
    title: str
    starts_at: datetime
    community_name: str
    sender: str

class InvitationsResponse(StrictModel):
    invitations: list[WalkInvitation]


def limit(user, action, count=30):
    from .main import rate_limit
    rate_limit(user,action,count)


def profile(conn, subject):
    row=conn.execute('SELECT * FROM social_profiles WHERE user_id=%s',(subject,)).fetchone()
    if not row: raise HTTPException(409,'Choose a friend username in Profile settings first')
    return row


def pair_lock(conn, a, b):
    conn.execute('SELECT pg_advisory_xact_lock(hashtextextended(%s,0))',(':'.join(sorted([a,b])),))


def blocked(conn, a, b):
    return bool(conn.execute('SELECT 1 FROM user_blocks WHERE (user_id=%s AND target_id=%s) OR (user_id=%s AND target_id=%s)',(a,b,b,a)).fetchone())


def target(conn, public_id):
    row=conn.execute('SELECT * FROM social_profiles WHERE id=%s',(public_id,)).fetchone()
    if not row: raise HTTPException(404,'Person unavailable')
    return row


def notify(conn, recipient, actor, category, message, group=None, walk=None):
    if recipient==actor or (actor and blocked(conn,recipient,actor)): return
    preferences=conn.execute('SELECT notify_invites,notify_walks,notify_goals FROM social_profiles WHERE user_id=%s',(recipient,)).fetchone()
    if not preferences or not preferences['notify_'+category]: return
    conn.execute('INSERT INTO user_notifications(user_id,actor_id,category,message,community_id,walk_id) VALUES (%s,%s,%s,%s,%s,%s)',(recipient,actor,category,message,group,walk))
    # Bound per-account storage, including long-lived accounts on the free tier.
    conn.execute('DELETE FROM user_notifications WHERE user_id=%s AND id IN (SELECT id FROM user_notifications WHERE user_id=%s ORDER BY created_at DESC,id DESC OFFSET 200)',(recipient,recipient))


def notify_group(conn, group, actor, category, message, walk=None):
    # Two bounded set operations instead of one database round trip per member.
    conn.execute('''INSERT INTO user_notifications(user_id,actor_id,category,message,community_id,walk_id)
        SELECT p.user_id,%s,%s,%s,%s,%s FROM walking_community_members m
        JOIN social_profiles p ON p.user_id=m.user_id WHERE m.community_id=%s AND p.user_id<>%s
        AND CASE %s WHEN 'invites' THEN p.notify_invites WHEN 'walks' THEN p.notify_walks WHEN 'goals' THEN p.notify_goals ELSE false END
        AND NOT EXISTS(SELECT 1 FROM user_blocks b WHERE (b.user_id=p.user_id AND b.target_id=%s) OR (b.user_id=%s AND b.target_id=p.user_id))''',
        (actor,category,message,group,walk,group,actor,category,actor,actor))
    conn.execute('''WITH ranked AS (
        SELECT n.id,row_number() OVER(PARTITION BY n.user_id ORDER BY n.created_at DESC,n.id DESC) AS position
        FROM user_notifications n JOIN walking_community_members m ON m.user_id=n.user_id WHERE m.community_id=%s)
        DELETE FROM user_notifications n USING ranked r WHERE n.id=r.id AND r.position>200''',(group,))


@router.get('/profile',response_model=ProfileResponse)
def get_profile(user=Depends(identity)):
    with transaction() as conn:
        row=conn.execute('SELECT * FROM social_profiles WHERE user_id=%s',(user['sub'],)).fetchone()
        if row: row.pop('user_id')
        return {'profile':row}


@router.post('/profile',response_model=PublicProfile)
def save_profile(body: ProfileSettings,user=Depends(identity)):
    from psycopg.errors import UniqueViolation
    limit(user,'social-profile',10)
    try:
        with transaction() as conn:
            row=conn.execute('''INSERT INTO social_profiles(user_id,username,discoverable,allow_requests,allow_walk_invites,notify_invites,notify_walks,notify_goals)
            VALUES (%s,%s,%s,%s,%s,%s,%s,%s) ON CONFLICT(user_id) DO UPDATE SET
            username=excluded.username,discoverable=excluded.discoverable,allow_requests=excluded.allow_requests,
            allow_walk_invites=excluded.allow_walk_invites,notify_invites=excluded.notify_invites,notify_walks=excluded.notify_walks,notify_goals=excluded.notify_goals RETURNING *''',
            (user['sub'],body.username,body.discoverable,body.allow_requests,body.allow_walk_invites,body.notify_invites,body.notify_walks,body.notify_goals)).fetchone()
            if not body.allow_requests:
                conn.execute("DELETE FROM friendships WHERE recipient=%s AND status='pending'",(user['sub'],))
            if not body.allow_walk_invites:
                conn.execute("UPDATE walk_invitations SET status='declined' WHERE recipient=%s AND status='pending'",(user['sub'],))
            row.pop('user_id'); return row
    except UniqueViolation: raise HTTPException(409,'That username is already taken')


@router.post('/notification-preferences')
def notification_preferences(body: NotificationPreferences,user=Depends(identity)):
    with transaction() as conn:
        profile(conn,user['sub'])
        conn.execute('UPDATE social_profiles SET notify_invites=%s,notify_walks=%s,notify_goals=%s WHERE user_id=%s',(body.notify_invites,body.notify_walks,body.notify_goals,user['sub']))
    return {'saved':True}


@router.get('/search',response_model=PeopleResponse)
def search(q: str=Query(min_length=3,max_length=24,pattern=r'^[a-z0-9_]+$'),user=Depends(identity)):
    limit(user,'friend-search',20)
    with transaction() as conn:
        profile(conn,user['sub'])
        # Escape literal underscores; the partial pattern index bounds prefix discovery.
        rows=conn.execute('''SELECT p.id,p.username FROM social_profiles p WHERE p.discoverable AND p.allow_requests
        AND p.username LIKE %s AND p.user_id<>%s
        AND NOT EXISTS(SELECT 1 FROM user_blocks b WHERE (b.user_id=%s AND b.target_id=p.user_id) OR (b.user_id=p.user_id AND b.target_id=%s))
        ORDER BY p.username LIMIT 20''',(q.replace('_',r'\_')+'%',user['sub'],user['sub'],user['sub'])).fetchall()
    return {'people':rows}


@router.get('/friends',response_model=FriendsResponse)
def friends(user=Depends(identity)):
    with transaction() as conn:
        profile(conn,user['sub'])
        rows=conn.execute('''SELECT f.id,f.status,(f.recipient=%s) AS incoming,p.id AS person_id,p.username
        FROM friendships f JOIN social_profiles p ON p.user_id=CASE WHEN f.requester=%s THEN f.recipient ELSE f.requester END
        WHERE (f.requester=%s OR f.recipient=%s) AND NOT EXISTS(SELECT 1 FROM user_blocks b WHERE
        (b.user_id=%s AND b.target_id=p.user_id) OR (b.user_id=p.user_id AND b.target_id=%s)) ORDER BY p.username LIMIT 500''',(user['sub'],)*6).fetchall()
    return {'friends':rows}


@router.post('/friends')
def request_friend(body: Target,user=Depends(identity)):
    limit(user,'friend-request',12)
    with transaction() as conn:
        profile(conn,user['sub']); person=target(conn,body.person_id); other=person['user_id']
        if other==user['sub']: raise HTTPException(422,'Choose another person')
        pair_lock(conn,user['sub'],other)
        person=conn.execute('SELECT * FROM social_profiles WHERE id=%s FOR NO KEY UPDATE',(body.person_id,)).fetchone()
        if not person or blocked(conn,user['sub'],other) or not person['discoverable'] or not person['allow_requests']: raise HTTPException(404,'Person unavailable')
        row=conn.execute('''SELECT * FROM friendships WHERE least(requester,recipient)=least(%s,%s) AND greatest(requester,recipient)=greatest(%s,%s)''',(user['sub'],other,user['sub'],other)).fetchone()
        if row: return {'id':row['id'],'status':row['status']}
        for subject in (user['sub'],other):
            if conn.execute('SELECT count(*) AS n FROM friendships WHERE requester=%s OR recipient=%s',(subject,subject)).fetchone()['n']>=500: raise HTTPException(409,'Friend limit reached')
        row=conn.execute('INSERT INTO friendships(requester,recipient) VALUES (%s,%s) RETURNING id,status',(user['sub'],other)).fetchone()
        notify(conn,other,user['sub'],'invites','You have a new friend request.')
        return row


@router.post('/friends/{friendship}')
def act_friend(friendship: UUID,body: FriendshipAction,user=Depends(identity)):
    with transaction() as conn:
        row=conn.execute('SELECT * FROM friendships WHERE id=%s AND (requester=%s OR recipient=%s)',(friendship,user['sub'],user['sub'])).fetchone()
        if not row: raise HTTPException(404,'Request unavailable')
        pair_lock(conn,row['requester'],row['recipient'])
        row=conn.execute('SELECT * FROM friendships WHERE id=%s FOR UPDATE',(friendship,)).fetchone()
        if not row or blocked(conn,row['requester'],row['recipient']): raise HTTPException(404,'Request unavailable')
        if body.action=='accept':
            if row['recipient']!=user['sub']: raise HTTPException(403,'Only the recipient can accept')
            if row['status']!='accepted':
                conn.execute("UPDATE friendships SET status='accepted' WHERE id=%s",(friendship,))
                notify(conn,row['requester'],user['sub'],'invites','Your friend request was accepted.')
        else:
            if body.action=='decline' and row['recipient']!=user['sub']: raise HTTPException(403,'Only the recipient can decline')
            if body.action=='cancel' and row['requester']!=user['sub']: raise HTTPException(403,'Only the sender can cancel')
            conn.execute('DELETE FROM friendships WHERE id=%s',(friendship,))
            conn.execute("UPDATE walk_invitations SET status='declined' WHERE status='pending' AND ((sender=%s AND recipient=%s) OR (sender=%s AND recipient=%s))",(row['requester'],row['recipient'],row['recipient'],row['requester']))
    return {'saved':True}


@router.get('/blocks',response_model=PeopleResponse)
def blocks(user=Depends(identity)):
    with transaction() as conn:
        rows=conn.execute('SELECT p.id,p.username FROM user_blocks b JOIN social_profiles p ON p.user_id=b.target_id WHERE b.user_id=%s ORDER BY p.username',(user['sub'],)).fetchall()
    return {'people':rows}


@router.post('/blocks')
def block(body: Target,user=Depends(identity)):
    with transaction() as conn:
        profile(conn,user['sub']); person=target(conn,body.person_id); other=person['user_id']
        if other==user['sub']: raise HTTPException(422,'Choose another person')
        pair_lock(conn,user['sub'],other)
        conn.execute('INSERT INTO user_blocks VALUES (%s,%s) ON CONFLICT DO NOTHING',(user['sub'],other))
        conn.execute('DELETE FROM friendships WHERE (requester=%s AND recipient=%s) OR (requester=%s AND recipient=%s)',(user['sub'],other,other,user['sub']))
        conn.execute("UPDATE walk_invitations SET status='declined' WHERE (sender=%s AND recipient=%s) OR (sender=%s AND recipient=%s)",(user['sub'],other,other,user['sub']))
        conn.execute('DELETE FROM user_notifications WHERE (user_id=%s AND actor_id=%s) OR (user_id=%s AND actor_id=%s)',(user['sub'],other,other,user['sub']))
    return {'saved':True}


@router.post('/blocks/{person}/remove')
def unblock(person: UUID,user=Depends(identity)):
    with transaction() as conn:
        other=target(conn,person)
        conn.execute('DELETE FROM user_blocks WHERE user_id=%s AND target_id=%s',(user['sub'],other['user_id']))
    return {'saved':True}


@router.get('/inbox',response_model=InboxResponse)
def inbox(user=Depends(identity)):
    with transaction() as conn:
        rows=conn.execute('''SELECT n.id,n.category,n.message,n.community_id,n.walk_id,n.created_at,n.read_at
        FROM user_notifications n WHERE n.user_id=%s AND
        (n.actor_id IS NULL OR NOT EXISTS(SELECT 1 FROM user_blocks b WHERE (b.user_id=%s AND b.target_id=n.actor_id) OR (b.user_id=n.actor_id AND b.target_id=%s)))
        AND (n.community_id IS NULL OR EXISTS(SELECT 1 FROM walking_community_members m WHERE m.community_id=n.community_id AND m.user_id=%s)
        OR EXISTS(SELECT 1 FROM walk_invitations i WHERE i.walk_id=n.walk_id AND i.recipient=%s AND i.status='pending'))
        ORDER BY n.created_at DESC,n.id DESC LIMIT 100''',(user['sub'],)*5).fetchall()
    return {'notifications':rows}


@router.post('/inbox/read')
def read_inbox(body: NotificationRead,user=Depends(identity)):
    with transaction() as conn:
        conn.execute('UPDATE user_notifications SET read_at=coalesce(read_at,now()) WHERE user_id=%s AND id=ANY(%s)',(user['sub'],body.ids))
    return {'saved':True}


@router.get('/reminders',response_model=RemindersResponse)
def reminders(user=Depends(identity)):
    with transaction() as conn:
        rows=conn.execute('''SELECT w.id,w.title,w.starts_at FROM community_walks w JOIN community_walk_rsvps r ON r.walk_id=w.id
        JOIN walking_community_members m ON m.community_id=w.community_id AND m.user_id=r.user_id
        WHERE r.user_id=%s AND NOT w.cancelled AND w.starts_at>now()+interval '15 minutes'
        AND w.starts_at<now()+interval '30 days' ORDER BY w.starts_at LIMIT 30''',(user['sub'],)).fetchall()
    return {'walks':rows}


@router.get('/invitations',response_model=InvitationsResponse)
def invitations(user=Depends(identity)):
    with transaction() as conn:
        rows=conn.execute('''SELECT i.id,i.walk_id,w.title,w.starts_at,c.name AS community_name,p.username AS sender
        FROM walk_invitations i JOIN community_walks w ON w.id=i.walk_id JOIN walking_communities c ON c.id=w.community_id
        JOIN social_profiles p ON p.user_id=i.sender
        WHERE i.recipient=%s AND i.status='pending' AND NOT w.cancelled AND w.starts_at>now()
        AND NOT EXISTS(SELECT 1 FROM user_blocks b WHERE (b.user_id=%s AND b.target_id=i.sender) OR (b.user_id=i.sender AND b.target_id=%s))
        ORDER BY w.starts_at LIMIT 100''',(user['sub'],)*3).fetchall()
    return {'invitations':rows}


@router.post('/invitations/{invitation}')
def invitation_action(invitation: UUID,body: InvitationAction,user=Depends(identity)):
    from .community_features import member
    with transaction() as conn:
        invite=conn.execute('SELECT * FROM walk_invitations WHERE id=%s AND recipient=%s',(invitation,user['sub'])).fetchone()
        if not invite: raise HTTPException(404,'Invitation unavailable')
        # Same group lock order as create/cancel/member changes.
        walk=conn.execute('SELECT w.*,c.created_by AS owner FROM community_walks w JOIN walking_communities c ON c.id=w.community_id WHERE w.id=%s FOR UPDATE OF c',(invite['walk_id'],)).fetchone()
        if not walk: raise HTTPException(404,'Walk unavailable')
        pair_lock(conn,invite['sender'],user['sub'])
        invite=conn.execute('SELECT * FROM walk_invitations WHERE id=%s FOR UPDATE',(invitation,)).fetchone()
        if invite['status']!='pending': return {'saved':True,'status':invite['status']}
        if body.accept:
            me=profile(conn,user['sub'])
            from datetime import datetime, timezone
            if walk['cancelled'] or walk['starts_at']<=datetime.now(timezone.utc) or blocked(conn,invite['sender'],user['sub']) or blocked(conn,walk['owner'],user['sub']): raise HTTPException(409,'This invitation is no longer available')
            member(conn,walk['community_id'],{'sub':invite['sender']})
            conn.execute('INSERT INTO walking_community_members(community_id,user_id,display_name) VALUES (%s,%s,%s) ON CONFLICT DO NOTHING',(walk['community_id'],user['sub'],me['username']))
            conn.execute('INSERT INTO community_walk_rsvps VALUES (%s,%s) ON CONFLICT DO NOTHING',(walk['id'],user['sub']))
        conn.execute('UPDATE walk_invitations SET status=%s WHERE id=%s',('accepted' if body.accept else 'declined',invitation))
    return {'saved':True,'status':'accepted' if body.accept else 'declined'}


@router.post('/walks/{walk}/invite')
def invite_friend(walk: UUID,body: Target,user=Depends(identity)):
    from .community_features import member
    limit(user,'walk-invite',20)
    with transaction() as conn:
        plan=conn.execute('SELECT * FROM community_walks WHERE id=%s',(walk,)).fetchone()
        if not plan: raise HTTPException(404,'Walk unavailable')
        owner=member(conn,plan['community_id'],user)
        if not owner and plan['created_by']!=user['sub']: raise HTTPException(403,'Only the organizer or group owner can invite friends')
        plan=conn.execute('SELECT * FROM community_walks WHERE id=%s',(walk,)).fetchone()
        from datetime import datetime,timezone
        if plan['cancelled'] or plan['starts_at']<=datetime.now(timezone.utc): raise HTTPException(409,'Walk unavailable')
        person=target(conn,body.person_id); other=person['user_id']; pair_lock(conn,user['sub'],other)
        person=conn.execute('SELECT * FROM social_profiles WHERE id=%s FOR NO KEY UPDATE',(body.person_id,)).fetchone()
        if not person or blocked(conn,user['sub'],other) or not person['allow_walk_invites']: raise HTTPException(404,'Person unavailable')
        if not conn.execute("SELECT 1 FROM friendships WHERE status='accepted' AND ((requester=%s AND recipient=%s) OR (requester=%s AND recipient=%s))",(user['sub'],other,other,user['sub'])).fetchone(): raise HTTPException(403,'Only accepted friends can be invited')
        row=conn.execute('INSERT INTO walk_invitations(walk_id,sender,recipient) VALUES (%s,%s,%s) ON CONFLICT(walk_id,recipient) DO NOTHING RETURNING id',(walk,user['sub'],other)).fetchone()
        if row: notify(conn,other,user['sub'],'invites','A friend invited you to a group walk.',plan['community_id'],walk)
        else:
            previous=conn.execute('SELECT status FROM walk_invitations WHERE walk_id=%s AND recipient=%s',(walk,other)).fetchone()
            if previous and previous['status']!='pending': raise HTTPException(409,'This friend has already responded to this walk invitation')
    return {'saved':True}
