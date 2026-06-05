from typing import Optional

import strawberry


@strawberry.type
class {{ PrefixName }}:
    id: str
    display_name: str


@strawberry.type
class Query:
    @strawberry.field
    async def {{ prefix_name }}(self, info: strawberry.types.Info, id: str) -> Optional[{{ PrefixName }}]:
{% if persistence ~= 'None' %}
        # session = info.context["session"]
{% endif %}
        return None

    @strawberry.field
    async def {{ prefix_name }}s(self, info: strawberry.types.Info) -> list[{{ PrefixName }}]:
{% if persistence ~= 'None' %}
        # session = info.context["session"]
{% endif %}
        return []


@strawberry.type
class Mutation:
    @strawberry.mutation
    async def create_{{ prefix_name }}(
        self, info: strawberry.types.Info, display_name: str
    ) -> {{ PrefixName }}:
{% if persistence ~= 'None' %}
        # session = info.context["session"]
{% endif %}
        return {{ PrefixName }}(id="", display_name=display_name)
