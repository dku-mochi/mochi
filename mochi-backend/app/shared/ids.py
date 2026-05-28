from typing import NewType
from uuid import UUID

# 도메인 ID들을 NewType으로 래핑해 함수 시그니처에서 잘못된 UUID 혼선을 방지.
CaptureID = NewType("CaptureID", UUID)
AgentRunID = NewType("AgentRunID", UUID)
EmbeddingID = NewType("EmbeddingID", UUID)
UserID = NewType("UserID", UUID)
