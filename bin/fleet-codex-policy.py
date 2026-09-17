#!/usr/bin/env python3
"""Materialize fleet startup policy as native Codex -c values, without writes."""
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys


def load(value):
    if value == 'none':
        return {}, False
    if value.lstrip().startswith('{'):
        data = json.loads(value)
    else:
        path = Path(value).expanduser()
        if path.suffix == '.toml':
            try:
                import tomllib
            except ImportError:
                raise ValueError('TOML MCP policies require Python 3.11+; JSON also works') from None
            with path.open('rb') as stream:
                data = tomllib.load(stream)
        else:
            data = json.loads(path.read_text())
    if not isinstance(data, dict):
        raise ValueError('MCP policy must be an object')
    key = 'mcp_servers' if 'mcp_servers' in data else 'mcpServers'
    if set(data) != {key} or not isinstance(data[key], dict):
        raise ValueError('MCP policy must contain only mcp_servers or mcpServers')
    return data[key], key == 'mcpServers'


def translate(server):
    if not isinstance(server, dict):
        raise ValueError('each MCP server must be an object')
    server = dict(server)
    transport = server.pop('type', 'stdio' if 'command' in server else 'http')
    if transport not in ('stdio', 'http'):
        raise ValueError('Codex fleet MCP translation supports stdio and HTTP; use a native config for other transports')
    if 'headers' in server:
        server['http_headers'] = server.pop('headers')
    allowed = {'command', 'args', 'env', 'cwd', 'url', 'http_headers', 'enabled'}
    if set(server) - allowed:
        raise ValueError('unsupported Claude MCP fields: ' + ', '.join(sorted(set(server) - allowed)))
    if ('command' in server) == ('url' in server):
        raise ValueError('each MCP server needs exactly one command or URL')
    return server


def policy(argv):
    runtime = runpy.run_path(str(Path(__file__).with_name('fleet-codex-runtime.py')))
    toml = runtime['toml_value']
    out = []
    model = os.environ.get('FLEET_CODEX_SUBAGENT_MODEL', '')
    if model and model != 'inherit':
        out.append('agents.default_subagent_model=' + toml(model))
    effort = os.environ.get('FLEET_CODEX_SUBAGENT_EFFORT', '')
    if effort:
        # Effort values are advertised by the selected model, not a closed enum.
        out.append('agents.default_subagent_reasoning_effort=' + toml(effort))
    value = os.environ.get('FLEET_CODEX_MCP_CONFIG', '')
    if not value:
        return out
    servers, shared = load(value)
    # Ask the installed CLI for its effective configuration (home + project +
    # profile + caller overrides). This lists configuration; no server is run.
    result = subprocess.run(['codex', *runtime['server_flags'](argv), 'mcp', 'list', '--json'],
                            capture_output=True, text=True, timeout=15)
    if result.returncode:
        raise ValueError('cannot enumerate effective Codex MCP configuration; policy was not applied')
    configured = json.loads(result.stdout)
    if not isinstance(configured, list) or any(not isinstance(x, dict) or not isinstance(x.get('name'), str) for x in configured):
        raise ValueError('unrecognised codex mcp list response; refusing an incomplete allowlist')
    overrides = {item['name']: {'enabled': False} for item in configured if item['name'] not in servers}
    # Apps/connectors and automatic skill-driven MCP installation have separate
    # controls in Codex. A strict fleet allowlist must also close those paths.
    out += ['features.apps=false', 'features.skill_mcp_dependency_install=false']
    for name, server in servers.items():
        if not isinstance(name, str) or not name or not isinstance(server, dict):
            raise ValueError('invalid MCP server name or configuration')
        server = translate(server) if shared else dict(server)
        server.setdefault('enabled', True)
        overrides[name] = server
    # Codex splits -c key paths on dots; quotes in a key path are literal bytes.
    # Put server names/field names in the TOML value so dotted names stay intact.
    out.append('mcp_servers=' + toml(overrides))
    return out


if __name__ == '__main__':
    try:
        args = sys.argv[1:]
        if args[:1] == ['--']:
            args = args[1:]
        for entry in policy(args):
            print(entry)
    except (OSError, ValueError, TypeError, subprocess.SubprocessError) as error:
        print('fleet-codex-policy: ' + str(error), file=sys.stderr)
        sys.exit(2)
