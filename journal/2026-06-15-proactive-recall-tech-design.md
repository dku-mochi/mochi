---
level: 3
mode: design
status: draft
last_verified: 2026-06-15
confidence: 0.75
owners: [송준서]
title: 능동 정보 회수 기술 설계 — 트랙 C 맥락 소환 MVP (Claude×codex 3턴 합의)
description: 능동 정보 회수의 구현 기술 설계. 코드 변경 없음(설계만). 트랙 C(맥락 소환) MVP 스펙을 Claude와 codex가 3턴 토론으로 상호 합의한 산물 + 실제 백엔드 스키마 제약 조사 + "남들이 잘 생각 못하는" 개발 디테일. recall_candidates/recall_log 2테이블, 분석 후단 hook 트리거, best-chunk dedup, channel allowlist 임시 민감게이트가 핵심. 능동 회수(트랙 A/B/C)·스케줄러·소환 카드를 구현하기 전 읽어라. 미승인 — 선결 의존성(민감 필드)·신규 테이블은 팀 합의 선행. 자매문서: 2026-06-15-proactive-recall-design.md(제품 기획).
---

# 능동 정보 회수 기술 설계 — 2026-06-15

> 코드/문서 변경 없음. **기술 설계 + Claude×codex 3턴 합의**만. CHANGELOG 미추가(결과 없음). 제품 기획은 자매문서 `2026-06-15-proactive-recall-design.md`, 이 문서는 **구현 기술**에 집중한다.

---

## 0. 범위

- **주축**: 트랙 C(맥락 소환) MVP 기술 스펙 — 3트랙 중 "시간으로 못 푸는" 유일한 트랙이라 설계 난도 최고.
- **부록**: 트랙 A/B 공통 인프라 메모(§6) + 데이터 모델 DDL 스케치(§7).
- **방법**: 실제 백엔드 코드를 조사(§1)한 뒤, Claude와 codex가 3턴 토론으로 합의(§9). 스펙의 모든 결정엔 "왜 안 되는/되는" 근거가 코드 사실에 묶여 있다.

---

## 1. 현재 인프라 사실 (코드 조사 — 추측 아님)

| 구성 | 상태 | 위치 / 비고 |
| --- | --- | --- |
| **벡터 검색** | ✅ 있음 | `embeddings(mochi_item_id, chunk_text, embedding Vector(1024), model_version)`. HNSW `vector_cosine_ops` (m=16, ef_construction=64), `ix_embeddings_vector_hnsw`. **chunk 단위**(item 1:N chunk). |
| **유사 검색 쿼리** | ✅ 있음 | `similar` 엔드포인트(`postgres_index.py`): `1 - (e.embedding <=> target)` cosine, owner 필터 + `deleted_at IS NULL` + 자기제외 + `>= min_score`(기본 0.7). reasons=sharedSource(같은 url)/sameIntent(intent 교집합). |
| **intent_instances** | ✅ 있음 | `(intent_type, payload JSONB, lifecycle_kind, created_at …)`. 복합인덱스 `(owner_id, intent_type, lifecycle_kind)`. |
| **entities** | ✅ 있음 | `entities(mochi_item_id, kind String(16), value String(512))`. kind=deadline/reference_url/shopping_product/person…. **kind에 인덱스 없음.** |
| **mochi_items** | ✅ 있음 | channel, summary, category, importance, needs_review, is_favorite, lifecycle_kind(ingested/analyzing/analyzed/failed), deleted_at … |
| **APNs 클라이언트** | ✅ 범용 | `HttpxAPNsClient.send(token, push_type, topic, payload dict …)` — **임의 payload 가능**. JWT 50분 캐시. |
| **outbox/워커** | ✅ 있음 | `mochi_item_outbox` + `MochiItemWorker`(동시성 2, 5초 폴링, FOR UPDATE SKIP LOCKED). **mochi_item 분석 전용, channel/kind 분기 없음.** |
| **재방문/소환 로그** | ❌ **없음** | last_accessed·view_count·recalled_at 컬럼, access_log 테이블 전무. |
| **민감도 필드** | ❌ **없음** | sensitivity_level/redaction_status DB 미구현. `PRIVACY_SENSITIVE_CAPTURE.md`는 설계만. `postgres_index.py`에 TODO 주석만. |
| **SendAnalysisNotification** | ⚠️ 분석완료 전용 | 하드코딩(needs_review 분기). 임의 텍스트 푸시는 apns_client 직접 호출로. |
| **스케줄러(cron)** | ❌ **없음** | 시각 기반 실행 인프라 없음. main.py lifespan에 worker asyncio task만. |

> **이 표가 스펙을 강제한다**: 재방문 로그·민감 필드·entity 인덱스 부재가 곧 트랙 C MVP의 제약(아래)이다.

---

## 2. 핵심 아키텍처 결정 (3트랙 공통)

### 2.1 trigger-time retrieval — "역방향 인덱스"
보통 회수는 *사용자 질의 → 검색*. 맥락 소환은 반대 — **새 이벤트(캡처/채팅)가 도착하면 그것을 질의로 삼아 기존 아카이브를 검색**한다. 모든 새 신호가 잠재적 질의다. 이게 트랙 C가 "시간 트리거"가 아닌 이유이자, 구현이 검색 인프라 위에 거의 공짜로 얹히는 이유.

### 2.2 능동 회수는 분석 워커와 자원 분리
- **트랙 B(시각형)**: 별도 경량 cron 루프(기존 outbox 폴링 패턴 확장, 새 의존성 0). `FOR UPDATE SKIP LOCKED`라 수평확장 안전. pub/sub는 불필요(저지연 무의미).
- **트랙 C(새 저장 트리거)**: **분석 워커 후단 hook**(best-effort). embedding이 분석 끝에 이미 생겼으니 ANN 1회 = 거의 공짜. **별도 스캔/cron 없음.**
- 둘 다 분석 throughput(동시성 2)을 잠식하지 않게 설계 — 회수는 지연 둔감, 분석은 지연 민감.

### 2.3 시각형 vs 조건형 (materialize vs rule-eval)
- 고정 시각(트랙 B 약속·마감) → `scheduled_recall`에 `fire_at` **미리 박음**.
- 조건형(트랙 A decay) → 미리 박으면 stale → 워커가 **주기 재평가**.
- 트랙 C는 둘 다 아님 — **이벤트 도착 시 즉시 materialize**(`recall_candidates`).

---

## 3. 트랙 C MVP 최종 스펙 (Claude×codex 합의)

> 원칙: **시간 예측 아님.** 사용자가 방금 던진 현재 맥락(새 저장 / 채팅 질문)으로 과거 archive를 붙인다. **푸시 금지, 카드만.**

### 3.1 트리거
- **T1 새 저장**: 분석 워커 후단 hook. *best-effort — 실패해도 분석 롤백 안 함*(분석완료의 하위효과이지 조건이 아님). embedding 재사용 → ANN 1회.
- **T2 채팅 질문**: 기존 채팅 RAG retrieval **재사용**. recall card용 post-filter만 분리(답변 본문에 인용된 item 제외 / 민감·채널 게이트 / suppression / max 3). 검색 재사용, **노출 정책 분리**.

### 3.2 후보 판정 (deterministic — 가중합 폐기)
- 주력: **best_chunk_similarity** (item별 MAX chunk cosine).
- 후보 조건: `best_chunk_sim ≥ 0.78` **OR** `(best_chunk_sim ≥ 0.65 AND entity_overlap ≥ 2)`.
- entity는 **보조**: 고유 kind(person/product/org/url/place)만, **topic 제외**. canonicalization 부재라 임계조정엔 보수적, 근거표시엔 자유.
- (점수 가중합은 v2 — 튜닝 데이터 쌓인 뒤. MVP에 임의상수 7개는 과적합.)

### 3.3 제외 게이트
- source item 자기 자신, deleted/archived, **추출실패 빈껍데기**.
- **민감**: MVP는 **channel allowlist**(safari/youtube/instagram 등 공개출처만). screenshot/kakaoTalk 등 보류.
  - ⚠️ **트레이드오프(codex 지적)**: "혹시몰라" 저장의 핵심이 screenshot일 가능성이 큼 → allowlist는 트랙 C 가치를 깎는 *임시 안전장치*. **screenshot 회수 개방은 sensitivity 필드 구현을 blocker로 명시**(§7 선결 의존성).
- **suppression**(shown 기준만): `blocked`=영구 / `shown` 7일내 same(item, surface_family) / `dismissed` 7일내 same(item, trigger_type). **candidate는 suppression에 안 씀.**

### 3.4 저장 모델 (신규 2 테이블 — 책임 분리)
- **recall_candidates**: materialize된 후보(미노출 포함). `status[pending/consumed/expired]`, `expires_at`. suppression 미사용.
- **recall_log**: append-only **이벤트** 로그. `event_type[shown/opened/dismissed/blocked]`. **shown=실제 렌더 시점만**(계산 시점 아님 — 안 그러면 suppression 오염).
- **freshness**(codex 함정①): `expires_at` 기본 **24시간**, expired candidate는 홈/카드 조회 제외("방금 맥락"이 썩지 않게).
- **dedup**(codex 함정②): **pending 기준** `same(owner, source_item_id|source_message_id, recalled_item_id, trigger_type, surface)` 중복 생성 금지(unique partial index) — 워커 재시도·재분석·채팅 retry 중복 방지.

### 3.5 노출 (푸시 금지)
- 저장 직후 카드 / 홈 "모찌가 챙기는 것"(pending candidate를 surface별 조회) / 채팅 하단.
- **근거는 chunk 기반**("저장한 내용 중 '…' 부분이 현재 맥락과 유사"). → **소환 단위(item) ≠ 설명 단위(chunk)**.
- 액션: 열기(opened) / 같이보기 / 관련없어요(dismissed=trigger family suppress) / 다신 소환 안함(blocked=영구).

### 3.6 decision_compare = "비교 후보 소환" (새 스키마 0)
- 새 저장에 shopping_product/product entity → 과거 동종 entity item을 relaxed 임계로 비교 카드. **상태추적 없음**("결정 관리" 아님 — 명칭이 곧 책임 경계). 데모 임팩트 큼.

### 3.7 MVP 제외 (명시)
위치 / 캘린더 교차(트랙 B로) / 앱 사용패턴 / 점수 가중합 / access(열람)로그 / entity canonicalization.

---

## 4. 남들이 잘 생각 못하는 개발 디테일 ★

토론에서 추려진, 순진하게 구현하면 반드시 밟는 함정들.

1. **chunk ≠ item.** embedding은 chunk 단위라 같은 item의 여러 chunk가 top-k를 도배한다. → item별 `MAX(sim)` dedup, **대표 chunk = argmax**. 그리고 **후보창 자르기는 dedup *후*** — "chunk 20개 먼저 뽑고 자르면" 한 item이 창을 다 먹는다. 내부 chunk는 넉넉히 → item dedup → top N.
2. **best-chunk의 "부분만 비슷한 쓰레기".** 긴 페이지에 우연히 맞는 한 문장만 있어도 item 전체가 소환됨. → item-level guard(추출성공·최소 본문) 하나 더.
3. **소환 단위(item) ≠ 설명 단위(chunk).** 사용자에겐 item 카드를 보여주지만 *이유는 특정 chunk*. 카드 근거를 chunk 텍스트로 보여줘야 "왜 떴는지" 설명력이 산다.
4. **shown은 계산 시점이 아니라 렌더 시점.** 분석완료에 후보를 계산하자마자 `shown`을 박으면, 사용자가 홈을 안 열어도 shown이 돼 suppression이 오염된다. → candidate(계산) / shown(노출) 시점 분리.
5. **candidate와 event log를 한 테이블에 섞지 마라.** "단순함은 테이블 수가 아니라 책임이 안 섞이는 것"(codex). 미노출 후보까지 log에 넣으면 의미가 탁해진다. → 2테이블.
6. **dismiss는 전역 item 차단이 아니다.** 한 맥락에서 안 맞다고 영구 차단하면 다른 맥락에서 유용할 기억까지 죽는다. → 기본은 `same trigger family + same item` suppression(7일), 명시적 "다시 보지 않기"만 `blocked`(영구).
7. **entity canonicalization 부재.** `Apple/애플/apple.com/AAPL`이 갈라져 overlap이 망가지고, 흔한 entity는 엉뚱한 걸 끌어온다. kind 인덱스로 안 풀린다. → MVP는 entity를 **보조로 강등**, 고유 kind만, topic 제외.
8. **candidate freshness(24h)** + **pending dedup unique 제약** — §3.4. 홈 썩음·중복 카드 방지.
9. **분석 후단 hook은 best-effort 격리.** 회수 후보 빌드 실패가 분석을 롤백하면 안 됨(이미 done 커밋된 push 패턴과 동일 철학).
10. **채팅: 검색 재사용, 노출 정책 분리.** 기존 RAG top-k를 입력으로, recall_cards는 거기서 인용분 제외·민감/채널·suppression 적용 후 max 3. 답변 본문엔 안 섞음(hallucination/잡음 방지).
11. **embedding 1024d 고정·HNSW.** 차원 변경은 drop→ALTER→재색인 한 세트(비용 큼). ANN은 owner_id 필터라 개인당 수백~수천 → HNSW로 충분히 빠름(전역 스캔 아님). `ef_search`는 회수 품질/지연 트레이드오프 튜닝 포인트.
12. **entities.kind 인덱스 없음.** entity_overlap을 매 저장마다 계산하면 풀스캔. → `(owner_id, kind, value)` 인덱스 추가(트랙 C에서 entity를 쓰기로 한 순간 선결).

---

## 5. 발송 경로 (트랙 B 푸시) — 재사용 가능성

- APNs 클라이언트(`HttpxAPNsClient.send`)는 **범용**(임의 payload) → 트랙 B 시각 알림에 그대로 재사용 가능.
- 단 `SendAnalysisNotification`은 분석완료 전용 하드코딩 → 회수 알림용 **새 빌더**(텍스트 템플릿 + collapse_id) 필요. device_push_tokens(owner 1:N, token_type=apns_device)는 그대로 사용.

---

## 6. 트랙 A/B 기술 메모 (요약 — 상세는 후속)

- **트랙 B 스케줄러**: 기존 outbox 폴링 패턴 확장한 경량 cron 루프(main.py lifespan에 worker 추가). `scheduled_recall(owner, mochi_item_id, kind, fire_at, status, payload)` materialize. 무거운 schedule(대회)은 D-30/14/7/3 다단 row.
- **트랙 A spaced**: knowledge lifecycle(이미 구현된 active/decaying/reviewRequested)에 **발송 경로 연결** + 30/180 상수를 적응형 간격으로. **선결: 재방문 로그**(없음) — 최소 `recall_log`의 opened event로 근사 가능(접근=소환카드 오픈). 본격 access 로그는 v2.
- **트랙 A 사전정리(A-3)**: 기존 `summary` 추출을 지식 한정 심화. 저장 시 얕게/회수 시 깊게.

---

## 7. 데이터 모델 DDL 스케치 (개념 — 구현 아님)

```text
-- 선결 의존성 (트랙 C 민감 게이트 승격용; screenshot 회수의 blocker)
ALTER mochi_items ADD sensitivity_level   varchar  -- low|caution|sensitive|highly_sensitive
ALTER mochi_items ADD recall_eligible     bool     -- 회수 허용 명시 플래그

-- 트랙 C 핵심 (신규 2)
recall_candidates(
  id, owner_id,
  source_item_id NULL, source_message_id NULL,   -- 둘 중 하나 (T1/T2)
  recalled_item_id,
  surface,            -- post_save | home | chat
  trigger_type,       -- new_item | chat_query | decision_compare
  best_chunk_id, best_chunk_similarity, entity_overlap_count,
  decision_reason,    -- short enum
  status,             -- pending | consumed | expired
  created_at, expires_at  -- 기본 +24h
)
UNIQUE(owner_id, source_item_id, source_message_id, recalled_item_id, trigger_type, surface)
  WHERE status='pending'   -- 중복 candidate 방지 (partial index)

recall_log(
  id, recall_candidate_id NULL, owner_id,
  recalled_item_id, source_item_id NULL, source_message_id NULL,
  surface, trigger_type,
  event_type,         -- shown | opened | dismissed | blocked
  created_at
)  -- append-only

-- entity overlap 가속 (트랙 C에서 entity 쓰면 선결)
CREATE INDEX ON entities(owner... kind, value)  -- 현재 mochi_item_id만 indexed

-- 트랙 B (시각형)
scheduled_recall(owner_id, mochi_item_id, kind, fire_at, status, payload, created_at)
```

---

## 8. 구현 단계 + 선결 의존성

```
선결: entities (owner_id,kind,value) 인덱스 / sensitivity 필드(screenshot 개방 전)
P1 트랙 C-T1: 분석 후단 hook + recall_candidates/recall_log + best-chunk dedup
           + channel allowlist + 저장직후 카드 → 검증: 새 저장 시 관련카드 노출·dismiss suppress
P2 트랙 C-홈: "모찌가 챙기는 것" pending candidate surface 조회 + freshness 만료
P3 트랙 C-T2: 채팅 RAG 재사용 + 하단 recall card post-filter
P4 decision_compare: shopping_product entity 재활용 비교카드 (스키마 0)
(트랙 B 스케줄러·트랙 A spaced는 별도 트랙)
```

---

## 9. Claude×codex 토론 합의 (3턴 요약)

- **방법**: `codex exec`(read-only, medium) 3턴 resume. GPT 1차 제안 → 실제 스키마 제약으로 반박/수정 → 합의.
- **합의된 핵심 결정**:
  1. 점수 가중합 폐기 → deterministic 2-신호 임계.
  2. entity는 embedding 보조 신호로 강등(canonicalization 부재).
  3. 새 저장 트리거 = 분석완료 후단 hook(별도 cron 아님).
  4. **recall_candidates / recall_log 분리**(책임 분리), shown=렌더 시점만.
  5. 민감 게이트 = channel allowlist 임시, screenshot 개방은 sensitivity 필드 blocker.
  6. decision_compare = "비교 후보 소환"(상태추적 없음, 새 스키마 0).
  7. candidate freshness 24h + pending dedup unique 제약.
- **codex가 추가로 잡은 것**: decision snapshot 필드(재현성), entity canonicalization 위험, allowlist의 screenshot 가치 손실 트레이드오프, best-chunk 쓰레기 guard, dismiss scope, candidate 만료·중복.
- **양측 "이 이상은 과설계" 합의** — MVP 스펙은 여기서 동결.

---

## 10. 열린 기술 질문 (다음 토론)

1. **재방문 로그**: 트랙 A spaced의 "마지막 접근"을 `recall_log.opened`로 근사할지, 본격 access 로그를 별도로 둘지.
2. **sensitivity 필드 스키마 확정** — `PRIVACY_SENSITIVE_CAPTURE.md §6.2` 설계를 어디까지 DB로 내릴지(트랙 C screenshot 개방 + 민감 캡처 전반 공용).
3. **채팅 RAG의 실제 구현 확인** — conversations 모듈 retrieval이 "현재 대화 맥락"용인지, archive 전용 필터를 따로 둘지(재사용 가정 검증 필요).
4. **best_chunk_sim 임계 0.78/0.65 실측 튜닝** — 실제 임베딩 분포로 보정(현재는 similar 기본 0.7 참고한 추정치).
