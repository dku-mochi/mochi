# FINDINGS — agent-loop-image-eval

lab 실험 중 발견한 결론·인사이트와 프로덕션 반영 메모를 기록한다.
실제 반영 시 `mochi-backend/` 의 해당 파일을 수정한다.

---

## 현재 lab 에서 우회한 것

### 1. 로컬 이미지 지원 (`gemini_agent_client.py`)

**현재 프로덕션 코드** (`_to_contents` 내):
```python
for uri, mime in part.get("images", []):
    content_parts.append(types.Part.from_uri(file_uri=uri, mime_type=mime))
```

**lab 우회** (`lab_gemini_client.py`):
```python
for path_or_uri, mime in part.get("images", []):
    if path_or_uri.startswith("gs://"):
        content_parts.append(types.Part.from_uri(file_uri=path_or_uri, mime_type=mime))
    else:
        content_parts.append(
            types.Part.from_bytes(data=Path(path_or_uri).read_bytes(), mime_type=mime)
        )
```

**프로덕션 반영 여부**: 테스트 전용 분기이므로 반영 불필요.
프로덕션은 항상 GCS → gs:// URI 경로를 사용한다.

---

## 실험 결과 메모

<!-- 실험 진행하며 여기에 기록 -->
