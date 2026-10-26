"""Self-service account deletion (App Store Review Guideline 5.1.1(v)).

Order matters for retries: personal rows are removed first in one transaction,
then the Supabase Auth user. Every step is idempotent, so a client whose request
failed part-way can simply send it again with a still-valid access token.
"""
import logging
import os
import time
from typing import Optional
import httpx
import jwt
from fastapi import APIRouter, Depends, HTTPException
from pydantic import Field
from .auth import identity
from .db import transaction
from .models import StrictModel

router = APIRouter(prefix='/api/v1/account', tags=['account'])
_log = logging.getLogger('uvicorn.error')

# Shared placeholder for community-owned records that must outlive their author.
DELETED_SUBJECT = 'deleted-account'


class AccountDeletion(StrictModel):
    # Fresh Sign in with Apple authorization code, used only to revoke Apple tokens.
    apple_authorization_code: Optional[str] = Field(default=None, min_length=1, max_length=2000)


def _auth_admin():
    url = os.environ.get('SUPABASE_URL', '').rstrip('/')
    key = os.environ.get('SUPABASE_SERVICE_ROLE_KEY', '')
    if not url.startswith('https://') or not key:
        return None
    return url, key


def delete_personal_data(conn, subject):
    """Remove or detach everything keyed to one account. Safe to run twice."""
    # Communities this person owns pass to the longest-standing other member;
    # communities with no other member are deleted (children cascade).
    owned = conn.execute('SELECT id FROM walking_communities WHERE created_by=%s FOR UPDATE', (subject,)).fetchall()
    for row in owned:
        heir = conn.execute('''SELECT user_id FROM walking_community_members WHERE community_id=%s AND user_id<>%s
            ORDER BY created_at,user_id LIMIT 1''', (row['id'], subject)).fetchone()
        if heir:
            conn.execute('UPDATE walking_communities SET created_by=%s,request_id=NULL WHERE id=%s', (heir['user_id'], row['id']))
        else:
            conn.execute('DELETE FROM walking_communities WHERE id=%s', (row['id'],))
    # Group walks they organised carry their route and meeting point: remove them.
    conn.execute('DELETE FROM community_walks WHERE created_by=%s', (subject,))
    conn.execute('DELETE FROM community_walk_rsvps WHERE user_id=%s', (subject,))
    conn.execute('DELETE FROM community_reactions WHERE user_id=%s', (subject,))
    conn.execute('DELETE FROM community_posts WHERE user_id=%s', (subject,))
    conn.execute('DELETE FROM walking_challenge_progress WHERE user_id=%s', (subject,))
    # Goals belong to the group; keep them but drop the author's identity.
    conn.execute('UPDATE walking_challenges SET created_by=%s WHERE created_by=%s', (DELETED_SUBJECT, subject))
    conn.execute('DELETE FROM walking_community_members WHERE user_id=%s', (subject,))
    # Profile rows cascade to friendships, blocks, invitations and their inbox.
    conn.execute('DELETE FROM user_notifications WHERE actor_id=%s', (subject,))
    conn.execute('DELETE FROM social_profiles WHERE user_id=%s', (subject,))
    # Stop reports: drop their votes and recompute the affected stops.
    reported = conn.execute('DELETE FROM poi_reports WHERE user_id=%s RETURNING poi_id', (subject,)).fetchall()
    for poi in sorted({row['poi_id'] for row in reported}):
        conn.execute('SELECT update_poi_confidence(%s)', (poi,))
    conn.execute("DELETE FROM poi_suggestions WHERE user_id=%s AND status='pending'", (subject,))
    conn.execute('UPDATE poi_suggestions SET user_id=%s WHERE user_id=%s', (DELETED_SUBJECT, subject))
    conn.execute('DELETE FROM api_request_receipts WHERE user_id=%s', (subject,))
    conn.execute('DELETE FROM api_rate_buckets WHERE user_id=%s', (subject,))


def _apple_client_secret():
    team, key_id = os.environ.get('APPLE_TEAM_ID'), os.environ.get('APPLE_KEY_ID')
    client, private_key = os.environ.get('APPLE_CLIENT_ID'), os.environ.get('APPLE_PRIVATE_KEY', '').replace('\\n', '\n')
    if not (team and key_id and client and private_key):
        return None, None
    now = int(time.time())
    secret = jwt.encode({'iss': team, 'iat': now, 'exp': now + 300, 'aud': 'https://appleid.apple.com', 'sub': client},
                        private_key, algorithm='ES256', headers={'kid': key_id})
    return client, secret


def revoke_apple(code):
    """Best effort. Returns True only when Apple confirmed the revocation."""
    if not code:
        return False
    try:
        client, secret = _apple_client_secret()
        if not client:
            return False
        with httpx.Client(timeout=8) as http:
            token = http.post('https://appleid.apple.com/auth/token', data={
                'client_id': client, 'client_secret': secret, 'code': code, 'grant_type': 'authorization_code'})
            token.raise_for_status()
            refresh = token.json().get('refresh_token')
            if not refresh:
                return False
            revoked = http.post('https://appleid.apple.com/auth/revoke', data={
                'client_id': client, 'client_secret': secret, 'token': refresh, 'token_type_hint': 'refresh_token'})
            revoked.raise_for_status()
        return True
    except (httpx.HTTPError, ValueError, jwt.PyJWTError):
        # Never log the code, secret or response body.
        _log.warning('apple_token_revocation_failed')
        return False


def delete_auth_user(subject):
    admin = _auth_admin()
    url, key = admin
    response = httpx.delete(f'{url}/auth/v1/admin/users/{subject}', timeout=10,
                            headers={'apikey': key, 'Authorization': f'Bearer {key}'})
    # 404 means an earlier attempt already removed the user.
    if response.status_code not in (200, 204, 404):
        response.raise_for_status()


@router.post('/delete')
def delete_account(body: AccountDeletion, user=Depends(identity)):
    from .main import rate_limit
    rate_limit(user, 'account-delete', 3)
    if _auth_admin() is None:
        raise HTTPException(503, 'Account deletion is not configured on the server yet. Please try again later.')
    subject = user['sub']
    apple_revoked = revoke_apple(body.apple_authorization_code)
    with transaction() as conn:
        conn.execute('SELECT pg_advisory_xact_lock(hashtextextended(%s,0))', ('account-delete:' + subject,))
        delete_personal_data(conn, subject)
    try:
        delete_auth_user(subject)
    except httpx.HTTPError:
        _log.warning('auth_user_deletion_failed')
        raise HTTPException(502, 'Your PausePath data was deleted, but your sign-in could not be removed. Please try again.')
    return {'deleted': True, 'apple_revoked': apple_revoked}
