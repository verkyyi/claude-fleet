#!/usr/bin/env python3
"""The schedule MCP's node-authenticated HTTP adapter. Request JSON on stdin."""
import json
import os
import sys
import uuid
from fleet_hub_rest import api, Fail

def main():
    request=json.load(sys.stdin)
    action=request.pop('action','list')
    if action in ('list','runs'):
        return api('GET','/schedules',query={'id':request.get('id')},root='/v1/node',
                   headers={'X-Fleet-Worker':os.environ['FLEET_WORKER_ASSERT']} if os.environ.get('FLEET_WORKER_ASSERT') else {})
    request['action']=action
    request.setdefault('idempotency_key',str(uuid.uuid4()))
    return api('POST','/schedules',request,root='/v1/node',
               headers={'X-Fleet-Worker':os.environ['FLEET_WORKER_ASSERT']} if os.environ.get('FLEET_WORKER_ASSERT') else {})
if __name__=='__main__':
    try: print(json.dumps(main(),ensure_ascii=False))
    except (Fail,ValueError,OSError) as e:
        print(str(e),file=sys.stderr);sys.exit(1)
