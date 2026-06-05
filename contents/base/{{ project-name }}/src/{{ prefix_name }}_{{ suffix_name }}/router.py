from fastapi import FastAPI, Request
from strawberry.fastapi import GraphQLRouter

from .schema import Mutation, Query
import strawberry


async def get_context(request: Request) -> dict:
    ctx: dict = {}
{% if persistence ~= 'None' %}
    from . import persistence as _persistence
    if _persistence._session_factory is not None:
        ctx["session"] = _persistence.get_session()
{% endif %}
{% if cache ~= 'None' %}
    from . import cache as _cache
    if _cache._client is not None:
        ctx["cache"] = _cache.get_cache()
{% endif %}
{% if messaging ~= 'None' %}
    from . import messaging as _messaging
    if _messaging._producer is not None:
        ctx["producer"] = _messaging.get_producer()
{% endif %}
    return ctx


schema = strawberry.Schema(query=Query, mutation=Mutation)
graphql_router = GraphQLRouter(schema, context_getter=get_context)


def build_router(app: FastAPI) -> None:
    app.include_router(graphql_router, prefix="/graphql")
