import pytest
from httpx import AsyncClient, ASGITransport

from {{ project_name }}.main import app
from {{ project_name }}.management import management_app


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


{% if persistence ~= 'None' %}
@pytest.mark.asyncio
async def test_graphql_schema_exposes_crud():
    # Executing the resolvers needs a live database (covered by the acceptance
    # suite); introspection proves the CRUD surface without one.
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as client:
        response = await client.post(
            "/graphql",
            json={
                "query": "{ __schema {"
                " queryType { fields { name } }"
                " mutationType { fields { name } }"
                " } }"
            },
        )
    assert response.status_code == 200
    schema = response.json()["data"]["__schema"]
    queries = {f["name"] for f in schema["queryType"]["fields"]}
    mutations = {f["name"] for f in schema["mutationType"]["fields"]}
    assert {"{{ entity_name }}", "{{ entity_name }}s"} <= queries
    assert {"create{{ EntityName }}", "update{{ EntityName }}", "delete{{ EntityName }}"} <= mutations
{% else %}
@pytest.mark.asyncio
async def test_graphql_query():
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as client:
        response = await client.post(
            "/graphql",
            json={"query": "{ {{ entity_name }}s { id displayName } }"},
        )
    assert response.status_code == 200
    data = response.json()
    assert "data" in data
    assert data["data"]["{{ entity_name }}s"] == []
{% endif %}
