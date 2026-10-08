"""One httpx client per outside service, kept for the server's whole life.

Why: a new `httpx.AsyncClient` per request opens a new connection every time (a TCP handshake, then a TLS
handshake) and throws it away after one request. A client kept alive keeps its connections open, and the next
request to the same host reuses one. Measured on searches (6 Oct, medians of 5): YouTube Music 599 ms with a new
client each time, 463 ms with a kept one; JioSaavn 283 ms and 193 ms. About 90-140 ms saved per request.

Use it at module level, once per service:

    http = SharedClient(timeout=2)
    r = await http.client.get(url)          # every request in the module goes through the same client

The server's lifespan closes them at shutdown (`await http.close()`).
"""
import httpx


class SharedClient:
    def __init__(self, **options):
        self.options = options              # passed to httpx.AsyncClient as is: timeout, headers, ...
        self._client: httpx.AsyncClient | None = None

    @property
    def client(self) -> httpx.AsyncClient:
        # made on first use, not at import: an AsyncClient belongs to the event loop it first runs in, and there is
        # no loop yet at import. A closed one is replaced (tests start and stop the server many times).
        if self._client is None or self._client.is_closed:
            self._client = httpx.AsyncClient(**self.options)
        return self._client

    async def close(self) -> None:
        if self._client is not None:
            await self._client.aclose()
