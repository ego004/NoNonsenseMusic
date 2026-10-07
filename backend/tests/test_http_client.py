"""The shared httpx client: one connection kept and reused, closed at shutdown. Offline: a tiny local server counts
the connections it is asked to open; nothing outside this Mac is contacted."""
import asyncio

import httpx
import pytest
from fastapi.testclient import TestClient

from music_backend import db
from music_backend.http_client import SharedClient
from music_backend.sources import jiosaavn, ytmusic

TEST_URL = "postgresql:///music_test"


class CountingServer:
    """Answers every request with 200 "ok", and counts the connections clients open to it."""

    def __init__(self):
        self.connections = 0

    async def handle(self, reader, writer):
        self.connections += 1
        try:
            while True:                                   # one connection can carry many requests, one after another
                await reader.readuntil(b"\r\n\r\n")      # a GET is its headers, ending in a blank line
                writer.write(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
                await writer.drain()
        except (asyncio.IncompleteReadError, ConnectionResetError):
            pass                                          # the client closed the connection
        finally:
            writer.close()


@pytest.fixture
async def local():
    counter = CountingServer()
    server = await asyncio.start_server(counter.handle, "127.0.0.1", 0)
    port = server.sockets[0].getsockname()[1]
    yield counter, f"http://127.0.0.1:{port}/"
    server.close()


def test_the_same_client_every_time():
    http = SharedClient()
    assert http.client is http.client


def test_options_reach_the_client():
    http = SharedClient(timeout=2, headers={"User-Agent": "NoNonsenseMusic test"})
    assert http.client.timeout.read == 2
    assert http.client.headers["user-agent"] == "NoNonsenseMusic test"


@pytest.mark.anyio
async def test_five_requests_share_one_connection(local):
    counter, url = local
    http = SharedClient(timeout=2)
    for _ in range(5):
        assert (await http.client.get(url)).text == "ok"
    await http.close()
    assert counter.connections == 1


@pytest.mark.anyio
async def test_a_new_client_per_request_opens_a_connection_each_time(local):
    # what the sources did before: the cost the shared client removes
    counter, url = local
    for _ in range(5):
        async with httpx.AsyncClient(timeout=2) as client:
            assert (await client.get(url)).text == "ok"
    assert counter.connections == 5


@pytest.mark.anyio
async def test_a_closed_client_is_replaced(local):
    _, url = local
    http = SharedClient(timeout=2)
    first = http.client
    await http.close()
    assert first.is_closed
    second = http.client
    assert second is not first and not second.is_closed
    assert (await second.get(url)).text == "ok"
    await http.close()


def test_server_shutdown_closes_both_sources_connections(monkeypatch):
    monkeypatch.setattr(db, "DATABASE_URL", TEST_URL)
    from music_backend.main import app
    with TestClient(app):
        clients = [ytmusic.http.client, jiosaavn.http.client]
        assert not any(c.is_closed for c in clients)
    assert all(c.is_closed for c in clients)
