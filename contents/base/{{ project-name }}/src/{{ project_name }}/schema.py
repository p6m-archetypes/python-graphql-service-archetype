from typing import Optional

import strawberry
{% if persistence ~= 'None' %}
from uuid import uuid4

from sqlalchemy import select

from .domain.{{ entity_name }}s import {{ EntityName }}Entity
from .persistence import get_session
{% endif %}


@strawberry.type
class {{ EntityName }}:
    id: strawberry.ID
    display_name: str


{% if persistence ~= 'None' %}
# Sample scaffold resolvers proving the persistence round trip end-to-end over the
# {{ EntityName }} entity (domain/{{ entity_name }}s.py). Replace with your real domain as it solidifies.
def _to_graphql(item: {{ EntityName }}Entity) -> {{ EntityName }}:
    return {{ EntityName }}Entity(id=item.id, display_name=item.display_name)


{% endif %}
@strawberry.type
class Query:
    @strawberry.field
    async def {{ entity_name }}(self, info: strawberry.types.Info, id: strawberry.ID) -> Optional[{{ EntityName }}]:
{% if persistence ~= 'None' %}
        async with get_session() as session:
            item = await session.get({{ EntityName }}Entity, id)
            return None if item is None else _to_graphql(item)
{% else %}
        return None
{% endif %}

    @strawberry.field
    async def {{ entity_name }}s(self, info: strawberry.types.Info) -> list[{{ EntityName }}]:
{% if persistence ~= 'None' %}
        async with get_session() as session:
            result = await session.execute(select({{ EntityName }}Entity).order_by({{ EntityName }}Entity.created_at))
            return [_to_graphql(item) for item in result.scalars()]
{% else %}
        return []
{% endif %}


@strawberry.type
class Mutation:
    @strawberry.mutation
    async def create_{{ entity_name }}(
        self, info: strawberry.types.Info, display_name: str
    ) -> {{ EntityName }}:
{% if persistence ~= 'None' %}
        item = {{ EntityName }}Entity(id=str(uuid4()), display_name=display_name)
        async with get_session() as session:
            session.add(item)
            await session.commit()
        return _to_graphql(item)
{% else %}
        return {{ EntityName }}Entity(id="", display_name=display_name)
{% endif %}
{% if persistence ~= 'None' %}

    @strawberry.mutation
    async def update_{{ entity_name }}(
        self, info: strawberry.types.Info, id: strawberry.ID, display_name: str
    ) -> Optional[{{ EntityName }}]:
        async with get_session() as session:
            item = await session.get({{ EntityName }}Entity, id)
            if item is None:
                return None
            item.display_name = display_name
            await session.commit()
            return _to_graphql(item)

    @strawberry.mutation
    async def delete_{{ entity_name }}(self, info: strawberry.types.Info, id: strawberry.ID) -> bool:
        async with get_session() as session:
            item = await session.get({{ EntityName }}Entity, id)
            if item is None:
                return False
            await session.delete(item)
            await session.commit()
            return True
{% endif %}
