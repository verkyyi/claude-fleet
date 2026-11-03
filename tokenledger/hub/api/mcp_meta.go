package api

import (
	"errors"
	"net/http"
	"strconv"
)

// What /mcp tells an MCP client about each tool's authorization (task T4DN),
// as OpenAI's published MCP auth requirements ask: the scope a tool needs
// (its securitySchemes), and — when a connected agent's grant lacks it — the
// insufficient_scope challenge a tool error carries in
// _meta["mcp/www_authenticate"], so the client can send the person back to
// consent for more. The tables stay where they are (sessionToolScope,
// fleetScopeOf); this file only reads them.

// MCPResourceMetadataURL is /mcp's RFC 9728 protected-resource metadata, the
// same address the 401 challenge names (agentUnauthorized).
func (s *Server) MCPResourceMetadataURL(r *http.Request) string {
	return s.nodeHubURL(r) + protectedResourcePath + "/mcp"
}

// MCPToolScope is the one scope a tool needs: a session tool's
// (sessionToolScope), a fleet tool's (fleetScopeOf), else fleet:read — every
// read, and the usage tools.
func MCPToolScope(name string) string {
	if sc, ok := sessionToolScope[name]; ok {
		return sc
	}
	if sc, ok := fleetScopeOf[name]; ok {
		return sc
	}
	return "fleet:read"
}

// MCPToolWrites is whether a tool changes something (its scope is not a
// read's).
func MCPToolWrites(name string) bool {
	sc := MCPToolScope(name)
	return sc != "fleet:read" && sc != "gh:read"
}

// MCPInsufficientScope is the WWW-Authenticate value for err when it is a
// connected agent's grant missing a scope (authorize sets FleetFault.Scope);
// ok is false for every other failure, and on a hub without the agent door
// (no metadata to point at).
func (s *Server) MCPInsufficientScope(r *http.Request, err error) (string, bool) {
	var f *FleetFault
	if !s.agentDoorOn() || !errors.As(err, &f) || f.Scope == "" {
		return "", false
	}
	return `Bearer error="insufficient_scope", scope=` + strconv.Quote(f.Scope) +
		`, resource_metadata=` + strconv.Quote(s.MCPResourceMetadataURL(r)) +
		`, error_description=` + strconv.Quote("This connected agent was not given "+f.Scope), true
}
