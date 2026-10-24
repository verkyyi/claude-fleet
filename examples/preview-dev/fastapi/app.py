"""fleet preview dev --unix -- uvicorn app:app --reload --uds '{socket}'

Plain ASGI so the only dependency is uvicorn. --reload restarts the server when this
file changes; refresh the page to see it.
"""


async def app(scope, receive, send):
    if scope['type'] != 'http':
        return
    await send({'type': 'http.response.start', 'status': 200,
                'headers': [(b'content-type', b'text/html; charset=utf-8')]})
    await send({'type': 'http.response.body', 'body': b'<h1>Hello from a fleet preview (uvicorn on a Unix socket)</h1>'})
