"""Hold one httpx client per external service for the lifetime of the server.

A new `httpx.AsyncClient` per request opens a fresh connection each time (a TCP handshake, then a TLS handshake)
and discards it after one response. A client kept alive holds its connections open, and the next request to the
same host reuses one. Measured on searches (medians of 5): YouTube Music 599 ms with a new client per request
against 463 ms with a kept one; JioSaavn 283 ms against 193 ms, a saving of 90-140 ms per request.

Construct one at module level, once per service:

    http = SharedClient(timeout=2)
    r = await http.client.get(url)          # every request in the module goes through the same client

The server's lifespan closes them at shutdown (`await http.close()`).
"""
import httpx


class SharedClient:
    """Provide a single lazily created httpx.AsyncClient to every caller."""

    def __init__(self, **options):
        self.options = options              # forwarded unchanged to httpx.AsyncClient: timeout, headers, ...
        self._client: httpx.AsyncClient | None = None

    @property
    def client(self) -> httpx.AsyncClient:
        # Created on first use rather than at import: an AsyncClient binds to the event loop it first runs in,
        # and no loop exists at import time. A closed client is replaced, since tests start and stop the
        # server repeatedly.
        if self._client is None or self._client.is_closed:
            self._client = httpx.AsyncClient(**self.options)
        return self._client

    async def get(self, url: str, **kwargs) -> httpx.Response:
        """GET, asked once more after a timeout. JioSaavn answers in 0.17 s (median of 30 from the server, 14 Oct) and
        stalls now and then: 14 searches and lookups timed out at 2 s that day, 9 before the connection opened. A GET
        reads only, so asking again is safe; the second try takes a new connection."""
        try:
            return await self.client.get(url, **kwargs)
        except httpx.TimeoutException:
            return await self.client.get(url, **kwargs)

    async def close(self) -> None:
        """Close the underlying client if one was created."""
        if self._client is not None:
            await self._client.aclose()
