"""Official MCP SDK adapter; imported only by the optional `serve` command."""

import asyncio
import contextvars
import os
from typing import Any
from urllib.parse import urlsplit

from fleet_hub_common import Fault, canonical, now

try:
    import jwt
    from mcp.server import MCPServer
    from mcp.server.auth.middleware.auth_context import get_access_token
    from mcp.server.auth.provider import AccessToken
    from mcp.server.auth.settings import AuthSettings
    from mcp.server.mcpserver.exceptions import ToolError
    from mcp.server.transport_security import TransportSecuritySettings
    from mcp.types import ToolAnnotations
    from pydantic import StrictBool, StrictInt
    from starlette.responses import JSONResponse
except ImportError as exc:
    raise Fault("MISSING_DEPENDENCY", "Install requirements-mcp.txt in a Python 3.10+ environment to serve MCP") from exc


def https_url(value):
    parsed = urlsplit(value or "")
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or parsed.fragment or parsed.query:
        raise Fault("INVALID_ARGUMENT", "OAuth issuer, JWKS and resource URLs must be explicit HTTPS URLs")
    return value


class JWTVerifier:
    """OAuth resource server only; the configured issuer handles token issuance."""
    def __init__(self, hub, issuer, jwks_url, resource_url):
        self.hub = hub
        self.issuer = https_url(issuer)
        self.resource = https_url(resource_url)
        self.keys = jwt.PyJWKClient(https_url(jwks_url), timeout=5, lifespan=300)

    def decode(self, token):
        key = self.keys.get_signing_key_from_jwt(token).key
        claims = jwt.decode(token, key, algorithms=["RS256", "ES256"], audience=self.resource,
                            issuer=self.issuer, options={"require": ["exp", "iat", "sub", "client_id"]})
        if (not isinstance(claims["sub"], str) or not claims["sub"]
                or not isinstance(claims["client_id"], str) or not claims["client_id"]
                or type(claims["exp"]) is not int or claims["exp"] <= now()
                or not isinstance(claims.get("scope"), str)):
            raise ValueError("Invalid access-token claims")
        self.hub.authenticate(oauth=(self.issuer, claims["sub"], claims["client_id"]))
        return AccessToken(token=token, client_id=claims["client_id"], subject=claims["sub"],
                           scopes=claims["scope"].split(), expires_at=claims["exp"],
                           resource=self.resource, claims={"iss": self.issuer})

    async def verify_token(self, token):
        if not isinstance(token, str) or len(token) > 16384:
            return None
        try:
            return await asyncio.to_thread(self.decode, token)
        except (jwt.PyJWTError, Fault, ValueError, OSError, TypeError):
            return None


request_grant_token = contextvars.ContextVar("fleet_hub_request_token", default=None)


class GrantTokenAuth:
    """Explicit pre-authorized private HTTP mode; this does not advertise OAuth."""
    def __init__(self, app, hub):
        self.app, self.hub = app, hub

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        values = [v for k, v in scope.get("headers", []) if k.lower() == b"authorization"]
        token = None
        if len(values) == 1 and len(values[0]) <= 4096:
            scheme, _, value = values[0].decode("latin1").partition(" ")
            if scheme.lower() == "bearer":
                token = value.strip()
        try:
            await asyncio.to_thread(self.hub.authenticate, token=token)
        except Fault:
            response = JSONResponse({"error": "unauthorized"}, status_code=401,
                                    headers={"WWW-Authenticate": 'Bearer realm="Fleet Hub"', "Cache-Control": "no-store"})
            return await response(scope, receive, send)
        context = request_grant_token.set(token)
        try:
            return await self.app(scope, receive, send)
        finally:
            request_grant_token.reset(context)


def make_server(hub, *, token=None, oauth=None, grant_tokens=False):
    verifier, auth = None, None
    if oauth:
        verifier = JWTVerifier(hub, **oauth)
        auth = AuthSettings(issuer_url=oauth["issuer"], resource_server_url=oauth["resource_url"],
                            required_scopes=["fleet:read"], validate_token_resource=True)
    elif not grant_tokens:
        hub.authenticate(token=token)
    server = MCPServer("Fleet Hub", version="0.1.0", token_verifier=verifier, auth=auth,
                       instructions="Manage registered fleets within your grant. Keep operation IDs and query uncertain results before retrying.")

    async def invoke(tool, params):
        try:
            if oauth:
                access = get_access_token()
                if access is None:
                    raise Fault("UNAUTHORIZED", "An OAuth access token is required")
                identity = ((access.claims or {}).get("iss"), access.subject, access.client_id)
                return await asyncio.to_thread(hub.call, tool, params, oauth=identity, token_scopes=access.scopes)
            return await asyncio.to_thread(hub.call, tool, params,
                                           token=request_grant_token.get() if grant_tokens else token)
        except Fault as exc:
            raise ToolError(canonical({"error": exc.as_dict()})) from exc

    read = ToolAnnotations(readOnlyHint=True, destructiveHint=False, openWorldHint=True)
    change = ToolAnnotations(readOnlyHint=False, destructiveHint=False, idempotentHint=True, openWorldHint=True)

    @server.tool(annotations=read, structured_output=True)
    async def fleet_list(refresh: StrictBool = True) -> dict[str, Any]:
        """List only granted fleets across registered machines, with freshness and reachability."""
        return await invoke("fleet_list", {"refresh": refresh})

    @server.tool(annotations=read, structured_output=True)
    async def fleet_status(fleet_id: str) -> dict[str, Any]:
        """Read a fleet's current state and workers. Each worker's worker_id is its durable identity (use it for worker_message/stop/resume); window_id and handle are observations."""
        return await invoke("fleet_status", {"fleet_id": fleet_id})

    @server.tool(annotations=read, structured_output=True)
    async def config_get(fleet_id: str) -> dict[str, Any]:
        """Read remotely managed configuration values and the fleet-overlay revision."""
        return await invoke("config_get", {"fleet_id": fleet_id})

    @server.tool(annotations=change, structured_output=True)
    async def worker_start(fleet_id: str, issue: StrictInt, idempotency_key: str, agent: str = "") -> dict[str, Any]:
        """Start work on an existing issue under local Fleet gates. Reuse the key only for the same request; poll operation_get."""
        return await invoke("worker_start", {"fleet_id": fleet_id, "idempotency_key": idempotency_key,
                                             "params": {"issue": issue, "agent": agent}})

    @server.tool(annotations=change, structured_output=True)
    async def config_set(fleet_id: str, key: str, value: StrictInt, expected_revision: str, idempotency_key: str) -> dict[str, Any]:
        """Set one granted Fleet-level integer/bool key using config_get's revision; poll operation_get."""
        return await invoke("config_set", {"fleet_id": fleet_id, "idempotency_key": idempotency_key,
                                           "params": {"key": key, "value": value, "expected_revision": expected_revision}})

    lifecycle = ToolAnnotations(readOnlyHint=False, destructiveHint=True, idempotentHint=True, openWorldHint=True)

    @server.tool(annotations=change, structured_output=True)
    async def worker_message(worker_id: str, text: str, idempotency_key: str) -> dict[str, Any]:
        """Send text to a live worker as its next turn through the fleet's issue bridge (a comment on its issue, no keystrokes). Needs worker:message; poll operation_get."""
        return await invoke("worker_message", {"worker_id": worker_id, "text": text, "idempotency_key": idempotency_key})

    @server.tool(annotations=lifecycle, structured_output=True)
    async def worker_stop(worker_id: str, idempotency_key: str) -> dict[str, Any]:
        """Gracefully end a live worker's session (/exit, then the fleet's normal exit policy). Worktree, branch and issue are left in place; the session stays resumable. Needs worker:stop; poll operation_get."""
        return await invoke("worker_stop", {"worker_id": worker_id, "idempotency_key": idempotency_key})

    @server.tool(annotations=change, structured_output=True)
    async def worker_resume(worker_id: str, idempotency_key: str) -> dict[str, Any]:
        """Resume a stopped worker from its /fleet-history row in a new window under local Fleet gates. Refused while a live window holds the identity. Needs worker:resume; poll operation_get."""
        return await invoke("worker_resume", {"worker_id": worker_id, "idempotency_key": idempotency_key})

    @server.tool(annotations=read, structured_output=True)
    async def operation_get(operation_id: str) -> dict[str, Any]:
        """Reconcile one of your operations with its machine. Unknown means the outcome is unconfirmed."""
        return await invoke("operation_get", {"operation_id": operation_id})

    return server


def grant_token_app(hub, resource_url):
    server = make_server(hub, grant_tokens=True)
    app = server.streamable_http_app(stateless_http=True, json_response=True,
                                    max_request_body_size=65536, transport_security=http_security(resource_url))
    return GrantTokenAuth(app, hub)


def http_security(resource_url):
    parsed = urlsplit(https_url(resource_url))
    if parsed.path != "/mcp":
        raise Fault("INVALID_ARGUMENT", "The public resource URL must use the /mcp endpoint")
    origin = "https://" + parsed.netloc
    return TransportSecuritySettings(enable_dns_rebinding_protection=True,
                                     allowed_hosts=[parsed.netloc], allowed_origins=[origin])


def serve(hub, args):
    if args.transport == "stdio":
        token = os.environ.pop("FLEET_HUB_TOKEN", None)
        server = make_server(hub, token=token)
        server.run(transport="stdio")
    elif args.auth == "grant-token":
        # TLS is terminated by a private reverse proxy, such as Tailscale Serve.
        # Binding this pre-authorized mode directly to a network interface is
        # deliberately not an option.
        if args.host not in ("127.0.0.1", "::1", "localhost"):
            raise Fault("INVALID_ARGUMENT", "Grant-token HTTP must listen on loopback behind an HTTPS proxy")
        import uvicorn
        uvicorn.run(grant_token_app(hub, args.resource_url), host=args.host, port=args.port,
                    proxy_headers=False, access_log=False, timeout_graceful_shutdown=20)
    else:
        oauth = dict(issuer=args.issuer, jwks_url=args.jwks_url, resource_url=args.resource_url)
        security = http_security(args.resource_url)
        server = make_server(hub, oauth=oauth)
        server.run(transport="streamable-http", host=args.host, port=args.port,
                   stateless_http=True, json_response=True, max_request_body_size=65536,
                   transport_security=security)
