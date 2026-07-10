"""entities.value — String(512) → Text (장소 사진 URL 절단 방지).

Google Places 매장사진 URL(imageUrl, lh3.googleusercontent.com/place-photos/…, 400자+)이
붙은 place entity JSON 이 512 상한을 넘겨 repository 가 value[:512] 로 잘랐고, 잘린 JSON 이
파싱 실패해 좌표(지도 섹션)까지 통째로 사라졌다(place_geo 의 "보강 실패가 백본을 해치지
않는다" 원칙이 저장 단계에서 깨진 회귀). 컬럼을 Text 로 넓혀 절단을 없앤다. reference_url
entity 도 같은 컬럼이라 함께 완화된다.

Revision ID: 0027
Revises: 0026
Create Date: 2026-07-09 12:00:00.000000
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0027"
down_revision: str | None = "0026"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.alter_column(
        "entities",
        "value",
        existing_type=sa.String(length=512),
        type_=sa.Text(),
        existing_nullable=False,
    )


def downgrade() -> None:
    # Text → String(512) 축소는 무손실이 아니다 — 512 초과 값을 잘라야 타입이 맞는다.
    op.alter_column(
        "entities",
        "value",
        existing_type=sa.Text(),
        type_=sa.String(length=512),
        existing_nullable=False,
        postgresql_using="left(value, 512)",
    )
