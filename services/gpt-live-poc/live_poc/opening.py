"""Bound the opening guard without cancelling a pending WebSocket receive."""
import asyncio
from contextlib import suppress
import json


class OpeningDeadline:
    def __init__(self, seconds: float | None):
        self.deadline = None if seconds is None else asyncio.get_running_loop().time() + seconds

    def finish(self) -> None:
        self.deadline = None

    async def messages(self, connection):
        iterator = connection.__aiter__()
        pending = None
        try:
            while True:
                if self.deadline is not None and asyncio.get_running_loop().time() >= self.deadline:
                    self.finish()
                    yield json.dumps({"type": "local.opening_timeout"})
                    continue
                if pending is None:
                    pending = asyncio.create_task(anext(iterator))
                timeout = None if self.deadline is None else max(0, self.deadline - asyncio.get_running_loop().time())
                ready, _ = await asyncio.wait({pending}, timeout=timeout)
                if not ready:
                    self.finish()
                    yield json.dumps({"type": "local.opening_timeout"})
                    continue
                try:
                    message = pending.result()
                except StopAsyncIteration:
                    return
                pending = None
                yield message
        finally:
            if pending is not None:
                pending.cancel()
                with suppress(asyncio.CancelledError, StopAsyncIteration):
                    await pending
