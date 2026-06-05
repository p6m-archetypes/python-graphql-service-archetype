import pytest
from httpx import AsyncClient, ASGITransport

from {{ prefix_name }}_{{ suffix_name }}.main import app
from {{ prefix_name }}_{{ suffix_name }}.management import management_app


@pytest.mark.asyncio
async def test_readiness():
    async with AsyncClient(
        transport=ASGITransport(app=management_app), base_url="http://test"
    ) as client:
        response = await client.get("/health/readiness")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


@pytest.mark.asyncio
async def test_liveness():
    async with AsyncClient(
        transport=ASGITransport(app=management_app), base_url="http://test"
    ) as client:
        response = await client.get("/health/liveness")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


@pytest.mark.asyncio
async def test_graphql_query():
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as client:
        response = await client.post(
            "/graphql",
            json={"query": "{ {{ prefix_name }}s { id displayName } }"},
        )
    assert response.status_code == 200
    data = response.json()
    assert "data" in data
    assert data["data"]["{{ prefix_name }}s"] == []
