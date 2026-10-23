"""uvicorn app:app --uds "$HOME/.fleet-preview/uvicorn.sock" (umask 077).
No third-party web framework is required beyond Uvicorn itself.
"""
import asyncio
import json


async def app(scope, receive, send):
    if scope['type'] == 'lifespan':
        while True:
            event = await receive()
            if event['type'] == 'lifespan.startup':
                await send({'type': 'lifespan.startup.complete'})
            elif event['type'] == 'lifespan.shutdown':
                await send({'type': 'lifespan.shutdown.complete'})
                return
    elif scope['type'] == 'websocket':
        await receive()
        await send({'type': 'websocket.accept'})
        while True:
            event = await receive()
            if event['type'] == 'websocket.disconnect':
                return
            await send({'type': 'websocket.send', 'text': event.get('text', '')})
    elif scope['type'] == 'http':
        body = b''
        while True:
            event = await receive()
            body += event.get('body', b'')
            if not event.get('more_body'):
                break
        headers = dict(scope['headers'])
        if scope['path'] == '/events':
            await send({'type': 'http.response.start', 'status': 200, 'headers': [(b'content-type', b'text/event-stream')]})
            await send({'type': 'http.response.body', 'body': b'data: ready\n\n', 'more_body': True})
            while True:
                try:
                    if (await asyncio.wait_for(receive(), 1))['type'] == 'http.disconnect':
                        return
                except asyncio.TimeoutError:
                    await send({'type': 'http.response.body', 'body': b'data: tick\n\n', 'more_body': True})
        else:
            result = {'method': scope['method'], 'body': body.decode(), 'cookie': headers.get(b'cookie', b'').decode(), 'auth': headers.get(b'authorization', b'').decode(), 'custom': headers.get(b'x-app-value', b'').decode()}
            await send({'type': 'http.response.start', 'status': 200, 'headers': [(b'content-type', b'application/json')]})
            await send({'type': 'http.response.body', 'body': json.dumps(result).encode()})
