"""view_item_image 채팅 툴 단위 테스트.

고정하는 보장: ① owner-scoped 조회 실패(미실재·타인 소유·soft-deleted)·이미지 부재·잘못된
id 는 전부 에러 payload (예외 없음 — 모델이 스스로 복구) ② 성공 시 images 가 gs:// URI 로
정확히 해석된다(object_key 없는 ref 는 스킵) ③ run 루프가 images 를 별도 user part 로
다음 라운드에 주입하되 tool 행 영속에는 싣지 않는다 — 과거 턴 히스토리 재구성에 이미지가
구조적으로 재주입되지 않음 ④ ``_to_contents`` 가 images 를 ``Part.from_uri`` 로 변환.
"""

from typing import Any
from uuid import UUID, uuid4

from app.modules.conversations.application.run_chat_turn import _contents_from_history
from app.modules.conversations.domain.entities import Message, MessageRole
from app.modules.conversations.domain.ports import ChatLLMChunk, ChatToolResult
from app.modules.conversations.infrastructure.gemini_chat_client import _to_contents
from app.modules.conversations.infrastructure.run_registry import RunRegistry
from app.modules.conversations.infrastructure.tools.view_item_image import ViewItemImageTool
from app.modules.mochi_items.domain.entities import (
    ImageRef,
    IngestChannel,
    IngestSource,
    MochiItem,
)
from tests.unit.test_chat_run import FakeLLM, FakeStore, _drain, _runner

_OWNER = uuid4()
_CONVERSATION = uuid4()
_BUCKET = "mochi-captures-test"


def _item_with_images(*refs: ImageRef) -> MochiItem:
    return MochiItem(
        id=uuid4(),
        source=IngestSource(channel=IngestChannel.SCREENSHOT, image_refs=tuple(refs)),
    )


def _reader_for(item: MochiItem | None):
    calls: list[tuple[UUID, UUID]] = []

    async def _read(owner_id: UUID, mochi_item_id: UUID) -> MochiItem | None:
        calls.append((owner_id, mochi_item_id))
        return item

    _read.calls = calls  # type: ignore[attr-defined]
    return _read


def _ref(object_key: str | None, mime: str = "image/jpeg") -> ImageRef:
    return ImageRef(sha256="a" * 64, mime_type=mime, byte_size=1024, object_key=object_key)


# ---------- ①② 툴 단독 ----------


async def test_resolves_uploaded_images_to_gs_uris_and_skips_keyless_refs() -> None:
    item = _item_with_images(_ref("u1/aa.jpg"), _ref(None), _ref("u1/bb.png", mime="image/png"))
    reader = _reader_for(item)
    tool = ViewItemImageTool(reader, bucket=_BUCKET)

    result = await tool.run(owner_id=_OWNER, args={"mochi_item_id": str(item.id)})

    assert reader.calls == [(_OWNER, item.id)]  # owner-scoped 조회로 위임 — 누설 방지의 단일 지점
    assert result.payload == {"id": str(item.id), "image_count": 2, "attached": True}
    assert result.images == (
        (f"gs://{_BUCKET}/u1/aa.jpg", "image/jpeg"),
        (f"gs://{_BUCKET}/u1/bb.png", "image/png"),
    )
    # 과거 턴 축약본은 이미지를 싣지 않고 재호출 경로만 알려준다
    assert result.compact["id"] == str(item.id)
    assert "view_item_image again" in result.compact["note"]


async def test_record_without_image_returns_error_payload() -> None:
    item = _item_with_images()  # URL-only/텍스트 기록
    tool = ViewItemImageTool(_reader_for(item), bucket=_BUCKET)

    result = await tool.run(owner_id=_OWNER, args={"mochi_item_id": str(item.id)})

    assert "no captured image" in result.payload["error"]
    assert result.images == ()


async def test_caps_attachments_and_reports_omitted_count() -> None:
    item = _item_with_images(*[_ref(f"u1/{i}.jpg") for i in range(5)])
    tool = ViewItemImageTool(_reader_for(item), bucket=_BUCKET)

    result = await tool.run(owner_id=_OWNER, args={"mochi_item_id": str(item.id)})

    assert len(result.images) == 3  # _MAX_IMAGES — 요청 크기·비용 유계
    assert result.payload["image_count"] == 3
    assert result.payload["omitted_image_count"] == 2


async def test_missing_record_and_invalid_id_return_error_payload() -> None:
    tool = ViewItemImageTool(_reader_for(None), bucket=_BUCKET)

    not_found = await tool.run(owner_id=_OWNER, args={"mochi_item_id": str(uuid4())})
    assert not_found.payload == {"error": "record not found"}

    invalid = await tool.run(owner_id=_OWNER, args={"mochi_item_id": "not-a-uuid"})
    assert "invalid mochi_item_id" in invalid.payload["error"]
    assert invalid.images == ()


# ---------- ③ run 루프 주입 — 현재 턴 전용, 영속 제외 ----------


class _FakeImageTool:
    name = "view_item_image"
    label = "캡처 이미지를 보고 있어요"
    description = "view"
    parameters: dict[str, Any] = {"type": "object", "properties": {}}

    async def run(self, *, owner_id: UUID, args: dict[str, Any]) -> ChatToolResult:
        return ChatToolResult(
            payload={"id": "x", "image_count": 1, "attached": True},
            summary="캡처 이미지를 봤어요",
            compact={"id": "x", "note": "call view_item_image again"},
            images=((f"gs://{_BUCKET}/u1/aa.jpg", "image/jpeg"),),
        )


async def test_loop_injects_image_part_for_current_round_but_never_persists_it() -> None:
    llm = FakeLLM(
        rounds=[
            [ChatLLMChunk(tool_call=("view_item_image", {"mochi_item_id": "x"}))],
            [ChatLLMChunk(text_delta="이미지를 보니 12,000원이에요")],
        ]
    )
    store = FakeStore()
    registry = RunRegistry()
    run_id = uuid4()
    queue = registry.create(run_id)

    await _runner(llm, store, registry, tools=[_FakeImageTool()]).execute(
        owner_id=_OWNER, conversation_id=_CONVERSATION, run_id=run_id
    )
    await _drain(queue)

    # 2라운드째 contents 에 function_response 직후 이미지 user part 가 들어갔다
    image_parts = [p for p in llm.calls[1]["contents"] if "images" in p]
    assert len(image_parts) == 1
    assert image_parts[0]["images"] == [(f"gs://{_BUCKET}/u1/aa.jpg", "image/jpeg")]
    assert "attached: 1 image(s)" in image_parts[0]["text"]

    # tool 행 영속에는 이미지가 없다 — 히스토리 재구성에 재주입될 경로 자체가 없음
    tool_row = next(m for m in store.appended if m.role is MessageRole.TOOL)
    assert tool_row.tool_payload is not None
    assert "images" not in tool_row.tool_payload
    assert tool_row.tool_payload["compact"] == {"id": "x", "note": "call view_item_image again"}


async def test_multi_call_round_appends_images_after_all_call_response_pairs() -> None:
    """병렬 툴콜 라운드에서 이미지 user part 가 fc/fr 시퀀스 **사이에 끼지 않는다** (리뷰 P1).

    이미지 툴이 먼저 불려도 user part 는 라운드의 마지막 function_response 뒤에 1개만 —
    사이에 끼면 Gemini 의 "fc 수 == 다음 turn fr 수" 검증이 깨져 run 전체가 실패한다.
    """
    from tests.unit.test_chat_run import FakeSearchTool

    llm = FakeLLM(
        rounds=[
            [
                ChatLLMChunk(tool_call=("view_item_image", {"mochi_item_id": "x"})),
                ChatLLMChunk(tool_call=("search_items", {"query": "카페"})),
            ],
            [ChatLLMChunk(text_delta="이미지와 기록을 같이 봤어요")],
        ]
    )
    store = FakeStore()
    registry = RunRegistry()
    run_id = uuid4()
    queue = registry.create(run_id)

    await _runner(llm, store, registry, tools=[_FakeImageTool(), FakeSearchTool()]).execute(
        owner_id=_OWNER, conversation_id=_CONVERSATION, run_id=run_id
    )
    await _drain(queue)

    contents = llm.calls[1]["contents"]
    image_indexes = [i for i, p in enumerate(contents) if "images" in p]
    last_fr_index = max(i for i, p in enumerate(contents) if "function_response" in p)
    assert len(image_indexes) == 1
    assert image_indexes[0] > last_fr_index  # 모든 fc/fr 쌍이 닫힌 뒤


async def test_repeated_image_calls_in_one_round_merge_into_single_part() -> None:
    two_calls = [
        ChatLLMChunk(tool_call=("view_item_image", {"mochi_item_id": "x"})),
        ChatLLMChunk(tool_call=("view_item_image", {"mochi_item_id": "y"})),
    ]
    llm = FakeLLM(rounds=[two_calls, [ChatLLMChunk(text_delta="둘 다 봤어요")]])
    store = FakeStore()
    registry = RunRegistry()
    run_id = uuid4()
    queue = registry.create(run_id)

    await _runner(llm, store, registry, tools=[_FakeImageTool()]).execute(
        owner_id=_OWNER, conversation_id=_CONVERSATION, run_id=run_id
    )
    await _drain(queue)

    image_parts = [p for p in llm.calls[1]["contents"] if "images" in p]
    assert len(image_parts) == 1  # 라운드당 user part 1개로 병합
    assert len(image_parts[0]["images"]) == 2
    assert "attached: 2 image(s)" in image_parts[0]["text"]


def test_history_reconstruction_never_carries_images() -> None:
    history = [
        Message(id=uuid4(), conversation_id=_CONVERSATION, role=MessageRole.USER, content="가격 얼마였지?"),
        Message(
            id=uuid4(),
            conversation_id=_CONVERSATION,
            role=MessageRole.TOOL,
            tool_name="view_item_image",
            tool_payload={
                "args": {"mochi_item_id": "x"},
                "summary": "캡처 이미지를 봤어요",
                "compact": {"id": "x", "note": "call view_item_image again"},
            },
        ),
        Message(id=uuid4(), conversation_id=_CONVERSATION, role=MessageRole.ASSISTANT, content="12,000원이에요"),
    ]

    contents = _contents_from_history(history)

    assert all("images" not in part for part in contents)
    response = next(p for p in contents if "function_response" in p)["function_response"]["response"]
    assert "view_item_image again" in response["note"]  # 모델에게 재호출 경로를 남긴다


async def test_budget_exhaustion_mid_round_keeps_image_part_after_recorded_pairs() -> None:
    """이미지 콜 실행 → 같은 라운드 후속 콜이 콜 예산으로 스킵 → 폴백 라운드 교차 케이스.

    스킵된 콜은 fc/fr 자체가 미기록이라 unmatched 쌍이 없고, 이미지 part 는 기록된
    마지막 fr 뒤·폴백 instruction 앞 순서를 유지한다.
    """
    from tests.unit.test_chat_run import FakeSearchTool

    llm = FakeLLM(
        rounds=[
            [
                ChatLLMChunk(tool_call=("view_item_image", {"mochi_item_id": "x"})),
                ChatLLMChunk(tool_call=("search_items", {"query": "카페"})),  # 예산 소진으로 스킵
            ],
            [ChatLLMChunk(text_delta="본 것까지만 답해요")],
        ]
    )
    store = FakeStore()
    registry = RunRegistry()
    run_id = uuid4()
    queue = registry.create(run_id)

    await _runner(
        llm, store, registry, tools=[_FakeImageTool(), FakeSearchTool()], max_tool_calls=1
    ).execute(owner_id=_OWNER, conversation_id=_CONVERSATION, run_id=run_id)
    await _drain(queue)

    contents = llm.calls[1]["contents"]
    fc_indexes = [i for i, p in enumerate(contents) if "function_call" in p]
    fr_indexes = [i for i, p in enumerate(contents) if "function_response" in p]
    assert len(fc_indexes) == 1 and len(fr_indexes) == 1  # 스킵된 콜은 미기록 — 쌍 정합
    image_index = next(i for i, p in enumerate(contents) if "images" in p)
    fallback_index = next(
        i for i, p in enumerate(contents) if "Tool budget is exhausted" in p.get("text", "")
    )
    assert fr_indexes[0] < image_index < fallback_index


# ---------- ④ genai 변환 ----------


def test_to_contents_converts_images_to_from_uri_parts() -> None:
    contents = _to_contents(
        [
            {
                "role": "user",
                "text": "(attached: 1 image(s) from the record above)",
                "images": [(f"gs://{_BUCKET}/u1/aa.jpg", "image/jpeg")],
            }
        ]
    )

    assert len(contents) == 1
    parts = contents[0].parts or []
    assert len(parts) == 2
    assert parts[0].text == "(attached: 1 image(s) from the record above)"
    file_data = parts[1].file_data
    assert file_data is not None
    assert file_data.file_uri == f"gs://{_BUCKET}/u1/aa.jpg"
    assert file_data.mime_type == "image/jpeg"
