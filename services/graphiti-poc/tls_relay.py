"""Loopback TCP -> certificate-verified TLS; no MCP or memory processing.

Native Graphiti's pinned Falkor factory lacks TLS options. This transport-only
sidecar lets the unchanged client use loopback Redis while encrypting VNet hops.
Never logs payloads, credentials or connection exception details.
"""
import asyncio
import os
import ssl


def tls_context(ca_pem):
    ctx = ssl.create_default_context(cadata=ca_pem)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    return ctx


async def copy_stream(reader, writer):
    while data := await reader.read(65536):
        writer.write(data)
        await writer.drain()


async def relay(reader, writer, *, host, context):
    remote = None
    tasks = []
    try:
        upstream, remote = await asyncio.wait_for(asyncio.open_connection(
            host, 6380, ssl=context, server_hostname=host), timeout=10)
        tasks = [asyncio.create_task(copy_stream(reader, remote)),
                 asyncio.create_task(copy_stream(upstream, writer))]
        await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
    except Exception:
        print('Database TLS connection ended or unavailable', flush=True)
    finally:
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        for stream in (writer, remote):
            if stream:
                stream.close()
                try:
                    await stream.wait_closed()
                except Exception:
                    pass


async def main():
    host = os.environ['DATABASE_TLS_HOST']
    if host != '10.42.4.4':
        raise ValueError('Unexpected owner database host')
    context = tls_context(os.environ['DATABASE_CA_PEM'])
    server = await asyncio.start_server(
        lambda r, w: relay(r, w, host=host, context=context), '127.0.0.1', 6380)
    async with server:
        await server.serve_forever()


if __name__ == '__main__':
    asyncio.run(main())
