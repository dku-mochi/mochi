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

## 실험 결과 — 20260606 23:51

| 지표 | 값 |
|------|----|
| 총 케이스 | 34건 (오류 2건, skip 0건) |
| Intent Recall | 0.266 |
| Intent Precision | 0.344 |
| Exact match | 0.188 |
| Alignment Score | 3.81 / 5 |
| Contradiction | 0.031 |

### Intent Recall < 0.5 케이스
- `memo_todo_저날이후로보러가려고 (2).png` gold=['memo', 'todo'] -> predicted=['knowledge'] (recall=0.00)
- `memo_todo_저날이후로보러가려고.png` gold=['memo', 'todo'] -> predicted=['schedule'] (recall=0.00)
- `memo_나중에가보려고.png` gold=['memo'] -> predicted=['knowledge'] (recall=0.00)
- `memo_나중에가보려고저장.png` gold=['memo'] -> predicted=['knowledge'] (recall=0.00)
- `memo_나중에먹어보려고.png` gold=['memo'] -> predicted=['knowledge'] (recall=0.00)
- `memo_나중에사먹으려고.jpg` gold=['memo'] -> predicted=['todo'] (recall=0.00)
- `memo_나중에살신발.png` gold=['memo'] -> predicted=['todo'] (recall=0.00)
- `memo_나중에살화장품.png` gold=['memo'] -> predicted=['knowledge'] (recall=0.00)
- `memo_나중에써봐야지.PNG` gold=['memo'] -> predicted=['knowledge'] (recall=0.00)
- `memo_나중에여행갈때참고하려고.png` gold=['memo'] -> predicted=['knowledge', 'todo'] (recall=0.00)
- `memo_넷플릭스에서볼것들.png` gold=['memo'] -> predicted=['knowledge', 'knowledge'] (recall=0.00)
- `memo_머리자를때참고하려고.png` gold=['memo'] -> predicted=['knowledge'] (recall=0.00)
- `memo_부동산정보.png` gold=['memo'] -> predicted=['todo', 'knowledge'] (recall=0.00)
- `memo_상하이정보.jpeg` gold=['memo'] -> predicted=['knowledge'] (recall=0.00)
- `memo_옷살때참고하려고.png` gold=['memo'] -> predicted=['knowledge'] (recall=0.00)
- `memo_이뻐서나중에가보려고.png` gold=['memo'] -> predicted=['knowledge'] (recall=0.00)
- `memo_중국갈때설치할거.jpeg` gold=['memo'] -> predicted=['todo'] (recall=0.00)
- `memo_화장품나중에살거.png` gold=['memo'] -> predicted=['knowledge'] (recall=0.00)
- `schedule_todo_친구공연장장소와시간.jpeg` gold=['schedule', 'todo'] -> predicted=[] (recall=0.00)
- `schedule_공차할인날짜시간.jpeg` gold=['schedule'] -> predicted=[] (recall=0.00)
- `schedule_이때집비워야함.png` gold=['schedule'] -> predicted=['knowledge'] (recall=0.00)

### Alignment Score <= 2 케이스
- `memo_todo_저날이후로보러가려고 (2).png` score=2 — 사용자는 미래의 관람 계획을 위해 저장했으나, 에이전트는 이를 단순 정보성 기록으로 오판하여 의도와 충돌하는
- `memo_나중에살화장품.png` score=2 — 사용자는 화장품 구매를 목적으로 저장했으나, 에이전트는 특정 향 제품 추천 정보로 한정하여 해석함으로써 의도
- `memo_넷플릭스에서볼것들.png` score=2 — 사용자는 넷플릭스 시청 목록을 저장하려 했으나, 에이전트는 넷플릭스와 무관한 도서 정보를 포함하여 의도를 과
- `memo_화장품나중에살거.png` score=2 — 사용자는 나중에 구매하기 위해 정보를 저장하려는 의도였으나, 에이전트는 단순한 정보 확인 및 기록으로만 분석
- `schedule_todo_친구공연장장소와시간.jpeg` score=2 — 사용자는 특정 공연의 장소와 시간을 저장하려는 의도가 명확했으나, 에이전트는 행사 종료 여부만 판단하고 실제
- `schedule_공차할인날짜시간.jpeg` score=1 — 사용자는 특정 할인 정보의 날짜와 시간을 저장하고자 했으나, 에이전트는 이벤트의 종료 여부만 판단하고 정작 
- `schedule_이때집비워야함.png` score=1 — 사용자는 '집을 비워야 한다'는 퇴거 관련 행동 의도를 가졌으나, 에이전트는 단순한 기숙사 생활 정보 저장으
- `todo_schedule_날짜맞춰서가려고.jpg` score=2 — 사용자는 날짜에 맞춰 가기 위한 일정 관리를 원했으나, 에이전트는 과거 날짜라는 이유로 이를 단순 기록물로 

### 오류 케이스
- `memo_사고싶다.PNG`: Error -3 while decompressing data: incorrect header check
- `memo_저장해두고나중에봐야지.PNG`: Error -3 while decompressing data: incorrect header check

## 실험 결과 — 20260607 14:46

| 지표 | 값 |
|------|----|
| 총 케이스 | 34건 (오류 0건, skip 0건) |
| Intent Recall | 0.676 |
| Intent Precision | 0.735 |
| Exact match | 0.618 |
| Alignment Score | 3.76 / 5 |
| Contradiction | 0.176 |

### Intent Recall < 0.5 케이스
- `memo_나중에써봐야지.PNG` gold=['memo'] → predicted=['knowledge'] (recall=0.00)
- `memo_중국갈때설치할거.jpeg` gold=['memo'] → predicted=['todo'] (recall=0.00)
- `schedule_todo_비행기스케줄.jpeg` gold=['schedule', 'todo'] → predicted=['memo'] (recall=0.00)
- `schedule_todo_수강신청꼭해야지.jpeg` gold=['schedule', 'todo'] → predicted=['memo'] (recall=0.00)
- `schedule_todo_친구공연장장소와시간.jpeg` gold=['schedule', 'todo'] → predicted=['memo'] (recall=0.00)
- `schedule_공차할인날짜시간.jpeg` gold=['schedule'] → predicted=['memo'] (recall=0.00)
- `schedule_이때집비워야함.png` gold=['schedule'] → predicted=['memo'] (recall=0.00)
- `schedule_제출날짜.jpeg` gold=['schedule'] → predicted=['todo'] (recall=0.00)
- `todo_schedule_날짜맞춰서가려고.jpg` gold=['todo', 'schedule'] → predicted=['memo'] (recall=0.00)

### Alignment Score ≤ 2 케이스
- `memo_기프티콘나중에꼭써야지.jpeg` score=1 — 사용자는 기프티콘을 나중에 사용하겠다는 의지를 명확히 밝혔으나, 에이전트는 유효기간이 지났다는 이유로 이를 
- `memo_넷플릭스에서볼것들.png` score=2 — 사용자는 넷플릭스 시청 목록을 저장하려 했으나, 에이전트는 책 추천 정보를 포함한 불필요한 메모를 생성하여 
- `schedule_todo_비행기스케줄.jpeg` score=2 — 사용자는 비행기 스케줄로 저장하길 원했으나, 에이전트가 임의로 과거 일정이라 판단하여 메모로 분류함으로써 데
- `schedule_todo_수강신청꼭해야지.jpeg` score=1 — 사용자는 수강신청을 하겠다는 강한 의지를 보였으나, 에이전트는 단순히 과거의 공고로 치부하여 사용자의 능동적
- `schedule_todo_친구공연장장소와시간.jpeg` score=1 — 사용자는 친구 공연의 장소와 시간을 저장하려 했으나, 에이전트는 이를 과거의 행사로 판단하여 단순 메모로 처
- `schedule_공차할인날짜시간.jpeg` score=2 — 사용자는 할인 날짜와 시간을 저장하고자 했으나, 에이전트는 이를 단순한 과거 이벤트 기록으로 간주하여 핵심 
- `schedule_이때집비워야함.png` score=1 — 사용자는 퇴거를 위해 집을 비워야 한다는 구체적인 행동 의도를 밝혔으나, 에이전트는 이를 단순한 과거 정보성
- `todo_schedule_날짜맞춰서가려고.jpg` score=1 — 사용자는 해당 날짜에 맞춰 가기 위해 저장하려 했으나, 에이전트는 과거의 공연으로 오판하여 단순 기록용 메모
