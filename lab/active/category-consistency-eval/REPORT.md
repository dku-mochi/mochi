---
level: 3
mode: reference
status: active
last_verified: 2026-07-14
confidence: 0.8
owners: [송준서, 이용찬, 박세현]
description: 저장 시 category 명명 일관성과 월간 정규화 사이의 공백을 검토하거나 전체기간 카테고리 어휘 변경을 재평가할 때 읽어라.
---

# 카테고리 일관성 조사·실험·개선 보고서

브랜치: `fix/be-category-consistency`

## 결론

우려는 **단기에는 작지만 장기에는 구조적으로 실제인 문제**다.

- 실제 활성 시계열 98건(관측기간 약 5일)에서 현행 최근 18줄 컨텍스트는 과거에 한 번이라도 나온
  정확한 라벨을 81회 중 80회 노출했다(98.8%). 따라서 월간 정규화를 안 돌리면 저장 시 컨텍스트가
  곧바로 무의미해진다는 평가는 과하다.
- 그러나 현행 프롬프트가 실제로 보는 것은 “30일 최대 40건”이 아니라 **요약이 있는 최대 18줄**이다.
  31일 휴면, 사이에 25건 저장, 사이에 60건 저장 통제 실험에서 현행 exact-label 노출률은 모두 0%였다.
- 97건 프로덕션 스냅샷에는 의미가 명확히 겹치는 `쇼핑` 19건과 `쇼핑 후보` 9건이 동시에 있었다.
  쇼핑 관련 28건 중 32.1%가 대체 라벨에 놓인 것이 확인 가능한 파편화 하한이다.
- 실제 `gemini-3.1-flash-lite` 소규모 A/B에서 기존 어휘가 없는 baseline은 canonical exact reuse
  0/9, 전체기간 어휘 블록은 9/9였다. 표적 3개짜리 stress set이라 일반 정확도 추정치는 아니지만,
  라벨 노출이 실제 모델 선택으로 이어지는지는 확인했다.
- 월간 정규화는 효과가 있지만 클라이언트가 HTTP를 호출해야만 실행된다. 실제 덤프에서도 활성
  정규화 69건은 7라벨·singleton 1개인 반면, 미정규화 29건은 11라벨·singleton 8개였다.
  선택 시기와 주제가 달라 인과효과로 단정할 수는 없지만, “호출되지 않은 구간은 raw fine이 계속
  쌓인다”는 코드 경로와 일치한다.

따라서 저장 시에는 전체기간의 기존 어휘로 **새 alias 생성을 예방**하고, 월간 정규화는 이미 생긴
alias를 실제 DB에서 합치는 **repair**로 역할을 분리했다. 추가 LLM 호출이나 cron은 만들지 않았다.

## 현행 구조와 공백

### 저장 시 분석

`AgentOrchestrator`는 매 분석마다 `list_recent_window(limit=40)`을 호출한다. 어댑터는 최근 30일만
남기지만, 프롬프트 포매터는 현재 item과 빈 summary를 제외한 뒤 18줄에서 중단한다. 이 컨텍스트는
category뿐 아니라 title, intent, summary를 포함하므로 **최근 기록의 풍부한 예시**로는 유용하다.

공백은 다음 두 축이다.

1. 캘린더 시간: 30일 넘게 저장하지 않은 주제는 목록에서 사라진다.
2. 저장량: 30일 안이어도 더 최근 기록 18건이 있으면 해당 라벨은 프롬프트에서 사라진다.

### 월간 정규화

`POST /mochi_items/monthly_digest`는 그 달 fine category를 LLM 한 번으로 coarse label에 매핑하고
`category`를 실제로 덮어쓴다. `category_normalized_at`이 있는 라벨만 다음 digest의 기준 어휘로
사용하므로 한 번 실행된 구간은 수렴할 수 있다.

하지만 서버 cron이나 N건 트리거가 아니며, 월간 화면을 연 클라이언트의 요청에 의존한다. 호출이
없으면 DB repair도, 정규화 어휘도 생기지 않는다. 저장 시 최근 컨텍스트와 월간 repair 사이에
장기 어휘를 보존하는 경로가 없었던 것이 구조적 공백이다.

## 데이터와 평가 방법

재현 명령:

```bash
python3 lab/active/category-consistency-eval/run_eval.py
```

산출물은 `results.json`이다. 원문 summary·memo는 출력하지 않고 category·시각·정규화 마커만
집계했다.

### 데이터 범위

| 데이터 | 사용 범위 | 한계 |
|---|---:|---|
| `recall-dump/mochi_items.jsonl` | 원본 114건, 삭제 제외·category 존재 활성 98건 | 2026-06-10~15 약 5일뿐이라 30일 재등장 빈도를 직접 추정할 수 없음 |
| `mochi_items_prod.jsonl` | 97건 중 category 존재 91건 | timestamp·정규화 마커가 없어 순서/인과 분석 불가 |
| 통제 시뮬레이션 | 실제 덤프에서 2회 이상 등장한 8라벨 | 실패 가능성을 보이는 stress test이며 실제 발생률 추정이 아님 |

핵심 지표는 **exact prior-label availability**다. 새 분석 시점에 과거의 정확한 라벨 문자열이
컨텍스트에 있는지를 측정한다. 이는 LLM이 실제로 그 라벨을 고르는 정확도나 두 라벨의 의미가 같은지
판정하는 지표가 아니다.

## 실험 결과

### 1. 관측 시계열과 통제 probe

| 접근 | 실제 98건 반복 81회 | 31일 휴면 | 사이 25건 | 사이 60건 |
|---|---:|---:|---:|---:|
| 현행: 최근 18줄 + 30일 | 98.8% | 0% | 0% | 0% |
| 최근 40줄 + 30일 | 100% | 0% | 100% | 0% |
| 최근 40줄 + 시간제한 없음 | 100% | 100% | 100% | 0% |
| **전체기간 어휘 50개** | **100%** | **100%** | **100%** | **100%** |

단기 실데이터에서 현행은 이미 강했다. 단순히 18→40줄로 늘리면 관측 손실 1건은 회수하지만 31일
휴면과 60건 eviction을 해결하지 못한다. 전체기간 distinct label은 summary 없이 문자열만 보내므로
장기 기억을 추가하면서 최근 18줄의 풍부한 예시는 그대로 유지할 수 있다.

### 2. 정규화 유무와 파편화

| 부분집합 | item | distinct label | singleton label |
|---|---:|---:|---:|
| 정규화됨 | 69 | 7 | 1 |
| 미정규화 | 29 | 11 | 8 |

정규화 라벨만 어휘로 쓰면 미정규화 29건 중 exact label이 겹치는 것은 6건(20.7%)뿐이었다. 즉 기존
`list_normalized_categories`만 저장 시 재사용하면, digest를 한 번도 실행하지 않은 사용자는 어휘가
0개이고 부분 실행 사용자도 아직 repair되지 않은 관심사를 대부분 잃는다. 채택안이 raw label도
fallback으로 포함하는 이유다.

### 3. 문자열 fuzzy merge

97건 스냅샷에서 `SequenceMatcher` threshold 0.55는 `쇼핑/쇼핑 후보`,
`취미 및 관심사/취미 및 자기계발` 두 쌍만 찾았고, 0.65에서는 한 쌍도 찾지 못했다. threshold를
0.35로 내리면 `쇼핑 후보/스포츠 정보`(0.364) 같은 명백한 오병합 후보가 들어왔다. 짧은 한국어
라벨은 철자 유사도만으로 의미를 안전하게 합칠 수 없었다.

### 4. 라이브 LLM A/B

프로덕션 `ACTIVE_PROMPT`와 function schema, `gemini-3.1-flash-lite`를 그대로 사용했다. 동일한 새
캡처 텍스트에 baseline은 카테고리 어휘 없이, variant는 기존 canonical label 6개를 이번 구현의
약한 컨텍스트 블록으로 넣었다. 3케이스 × 조건별 3회다.

| 케이스/기대 라벨 | baseline 3회 | 전체기간 어휘 3회 |
|---|---|---|
| 투자 글 → `투자` | `투자 공부` ×3 | `투자` ×3 |
| 수강신청 → `학업` | `학사 일정` ×3 | `학업` ×3 |
| 상품 구매 고민 → `쇼핑` | `쇼핑 고민` ×1, `쇼핑 계획` ×2 | `쇼핑` ×3 |
| **exact reuse 합계** | **0/9 (0%)** | **9/9 (100%)** |
| 중앙 지연 | 1,970.3ms | 1,791.0ms |

별도 LLM 호출을 추가한 것이 아니므로 variant 지연이 늘지 않았다. 다만 기존 라벨을 재사용하기 쉬운
세 주제를 의도적으로 고른 소규모 stress set이며, category 의미 정확도나 전체 도메인의 100% 성공률을
뜻하지 않는다. 더 큰 순차 캡처셋과 여러 모델 run으로 일반화 검증이 필요하다.

## 비교한 개선 접근

| 접근 | 장점 | 기각/채택 판단 |
|---|---|---|
| 최근 context 18→40 확대 | 구현이 가장 단순, 관측 98.8→100% | 시간·볼륨 eviction을 일부만 미룸. summary까지 늘어 토큰·민감 추상 재전송도 증가 |
| 30일 제한 제거 | 31일 휴면 회수 | 최근 N건 제한은 남아 60건 probe 0%. 오래된 summary 전체를 보낼 이유가 없음 |
| **전체기간 label vocabulary** | 단일 짧은 DB query, 기존 LLM 호출 안에서 동작, digest 미실행도 fallback | **채택**. 정규화 우선→빈도→최근 순, 최대 50, 약한 힌트로 제한 |
| 저장마다 별도 LLM canonicalizer | 의미상 alias를 적극 병합 가능 | 매 저장 비용·지연·실패면 증가, 메인 LLM과 판단 충돌 가능 |
| 서버 cron/N건마다 digest | 클라이언트 미호출 문제를 직접 제거 | 실행 상태·멱등·동시 write·클라이언트 캐시 반영이 추가되고 LLM 비용 발생. 이번 예방 문제보다 큼 |
| 문자열 fuzzy post-map | 결정적·저비용 | 짧은 한국어에서 recall/precision 동시 확보 실패, 잘못 합치면 사용자 의미를 파괴 |
| 고정 전역 taxonomy | 완전한 철자 안정성 | 개인별 자연스러운 묶음과 구체성을 잃고 기존 제품 방향과 충돌 |
| embedding/`hybridSearch` 강제 | 현재 내용과 비슷한 과거 item을 찾을 수 있음 | 도구 round·검색 비용이 늘고 category 일관성에 항상 실행된다는 보장이 없음 |

## 구현

1. `MochiItemRepository.list_category_vocabulary`를 추가했다.
   - `owner_id`와 soft-delete 조건을 강제한다.
   - 전체기간 distinct category를 조회한다.
   - 한 번이라도 `category_normalized_at`이 있는 라벨을 먼저 두고, 그 안에서 전체 사용빈도와 마지막
     사용시각 순으로 정렬한다.
2. agent gateway를 통해 최대 50개 라벨을 읽는다.
3. 분석 user message에 `# 기존 카테고리 어휘 (전체 기록)` 블록을 별도로 넣는다.
   - 같은 주제일 때만 정확한 철자를 재사용한다.
   - 맞는 라벨이 없으면 새 라벨을 허용한다.
   - 현재 캡처 근거를 덮지 않는 약한 힌트라고 명시한다.
4. 기존 최근 18줄 컨텍스트와 월간 digest 코드는 변경하지 않았다.

API·DB schema·마이그레이션·추가 LLM 호출·cron 변경은 없다.

## 트레이드오프와 남은 리스크

- 소규모 A/B는 9/9 exact reuse였지만 label을 보여 주는 것이 모든 주제에서 같은 철자를 선택한다는
  결정적 보장은 아니다. 더 큰 순차 캡처 A/B와 alias 오병합 평가가 필요하다.
- raw fallback은 digest 미실행 공백을 막지만 이미 생긴 raw alias도 함께 보여 준다. 정규화 라벨을
  우선하고 사용빈도로 정렬해 완화했지만, 실제 병합은 계속 월간 repair의 책임이다.
- 50개를 넘는 사용자 어휘는 뒤쪽 라벨이 잘린다. 현재 두 스냅샷은 각각 17개라 여유가 크지만 장기
  분포를 관측해 cap과 ranking을 재검토해야 한다.
- owner별 category aggregate query가 매 저장마다 1회 추가된다. owner index를 타고 label만 group하므로
  개인 규모에서는 작지만, 대규모 계정은 `EXPLAIN ANALYZE`와 latency metric으로 확인해야 한다.
- 현행 recent window는 `created_at`으로 먼저 80건을 가져온 뒤 `captured_at` 30일을 메모리에서 거른다.
  대량 backfill 시 최근 예시가 비는 별도 edge가 있으나, 이번 장기 label 경로와 독립이라 수정하지 않았다.
- 재분석으로 category가 바뀌어도 기존 `category_normalized_at` 마커를 지우지 않는 동작은 stale canonical
  가능성이 있다. 이번 요청의 최소 변경 범위를 벗어나므로 후속 invariant로 분리한다.

## 검증

- 신규 저장소 query 테스트: owner scope, soft-delete 제외, 정규화 우선→빈도 정렬 SQL, 빈 라벨 제거.
- orchestrator 테스트: 최대 50 요청, 전체기간 블록 주입, 약한 힌트 문구.
- `make test`: **562 passed** (기존 `datetime.utcnow` 등 deprecation warning 419건).
- `make lint`: 통과.
- `make typecheck`: **199 source files**, issue 0.

## 변경 파일

- `mochi-backend/app/modules/mochi_items/domain/ports.py`
- `mochi-backend/app/modules/mochi_items/infrastructure/repository.py`
- `mochi-backend/app/modules/agent/domain/gateway.py`
- `mochi-backend/app/modules/agent/infrastructure/mochi_item_gateway.py`
- `mochi-backend/app/modules/agent/application/orchestrator.py`
- `mochi-backend/tests/unit/test_agent_loop.py`
- `mochi-backend/tests/unit/test_category_vocabulary.py`
- `lab/active/category-consistency-eval/run_eval.py`
- `lab/active/category-consistency-eval/results.json`
- `lab/active/category-consistency-eval/REPORT.md`
- `docs/DOMAIN_DESIGN.md`
- `docs/CHANGELOG.md` (기존 사용자 변경과 분리해 이 작업의 항목만 stage)
