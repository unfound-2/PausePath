import os
from functools import lru_cache
import jwt
from fastapi import Depends, HTTPException
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

bearer = HTTPBearer(auto_error=False)

@lru_cache(maxsize=1)
def jwks():
    url = os.environ.get('AUTH_JWKS_URL','')
    if not url.startswith('https://'):
        raise HTTPException(503, 'Configure an HTTPS identity-provider JWKS URL')
    return jwt.PyJWKClient(url, cache_jwk_set=True, lifespan=300, timeout=5)

def identity(credentials: HTTPAuthorizationCredentials = Depends(bearer)):
    if not credentials: raise HTTPException(401, 'Bearer authentication required')
    try:
        key = jwks().get_signing_key_from_jwt(credentials.credentials)
        claims = jwt.decode(credentials.credentials, key.key, algorithms=['RS256'],
                            audience=os.environ['AUTH_AUDIENCE'], issuer=os.environ['AUTH_ISSUER'],
                            options={'require':['exp','iss','aud','sub']})
        if not isinstance(claims['sub'], str) or not 1 <= len(claims['sub']) <= 200:
            raise ValueError('Invalid subject')
        roles = claims.get('roles', [])
        if not isinstance(roles, list) or not all(isinstance(role, str) for role in roles):
            raise ValueError('Invalid roles')
        return claims
    except (jwt.PyJWTError, ValueError, KeyError):
        raise HTTPException(401, 'Invalid or expired token')

def reviewer(user=Depends(identity)):
    if 'reviewer' not in user.get('roles', []): raise HTTPException(403, 'Reviewer role required')
    return user

def admin(user=Depends(identity)):
    if 'admin' not in user.get('roles', []): raise HTTPException(403, 'Admin role required')
    return user
