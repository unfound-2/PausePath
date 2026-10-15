from datetime import datetime, timedelta, timezone
from types import SimpleNamespace
import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi import HTTPException
from fastapi.security import HTTPAuthorizationCredentials
from app import auth

def test_supabase_es256_and_server_managed_roles(monkeypatch):
    private=ec.generate_private_key(ec.SECP256R1())
    monkeypatch.setenv('AUTH_ISSUER','https://example.supabase.co/auth/v1')
    monkeypatch.setenv('AUTH_AUDIENCE','authenticated')
    monkeypatch.setenv('AUTH_ROLES_SOURCE','app_metadata')
    monkeypatch.setattr(auth,'jwks',lambda: SimpleNamespace(get_signing_key_from_jwt=lambda token: SimpleNamespace(key=private.public_key())))
    claims={'sub':'user-id','iss':'https://example.supabase.co/auth/v1','aud':'authenticated',
        'exp':datetime.now(timezone.utc)+timedelta(minutes=5),'app_metadata':{'roles':['reviewer']},
        'user_metadata':{'roles':['admin']},'roles':['admin']}
    token=jwt.encode(claims,private,algorithm='ES256')
    user=auth.identity(HTTPAuthorizationCredentials(scheme='Bearer',credentials=token))
    assert user['roles']==['reviewer']
    with pytest.raises(HTTPException): auth.admin(user)
    claims['aud']='wrong-project-audience'
    with pytest.raises(HTTPException):
        auth.identity(HTTPAuthorizationCredentials(scheme='Bearer',credentials=jwt.encode(claims,private,algorithm='ES256')))
