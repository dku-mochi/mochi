---
level: 3
mode: log
status: active
last_verified: 2026-05-30
confidence: 0.9
owners: [송준서]
description: 백탭 분석을 동기 /back-tap 분류에서 비동기 worker 단일 경로로 통합 + confidence/헷갈려요 3상태(복수 의도) 재설계. 백엔드·iOS·문서 코드 전부 완료·검증(make test 95 passed, tuist test/build). 미커밋 — 다음 세션은 §5 잔여 과제 + git diff 확인 후 커밋/실기기 e2e 부터.
---

# 백탭 worker 단일화 + confidence 3상태 재설계 작업 로그

## 0. TL;DR

- **증상**: 백탭 스크린샷이 **무조건** "모찌가 헷갈려요"로 분류됨. (이미지 내용 무관)
- **근본 원인**: 백탭 동기 `/back-tap` 경로의 `MochiItem.from_classification` 이 `confidence` 를 안 채워 응답이 항상 `0.0` → iOS 가 그걸 저장하고 백탭을 폴링에서 제외해, worker 가 비동기로 채운 진짜 confidence 를 **영영 못 받음**(DB↔Realm 불일치). `isUncertain = confidence < 0.6` 이 항상 참.
- **해결 (사용자 결정)**: 동기 분류 제거 → **worker(agent) 단일 분석 경로**로 통합. agent 가 use case 후보(`candidates`)를 산출하고 `confidence := max(applicability)` 를 서버가 derive. iOS 는 폴링으로 반영.
- **추가 (사용자 요청)**: "헷갈려요" 판정 재설계 — 박빙 gap 조건 폐기, **top1·top2 둘 다 높으면 복수 의도**(헷갈림 아님).
- **상태**: 코드+문서 전부 완료·검증. **미커밋.** develop 브랜치.

## 1. 무엇을 / 왜

confidence 를 채우는 경로가 둘이었다 — 동기 분류기(`gemini_classifier`, confidence 미산출)와 비동기 agent(`finalizeAnalysis`, confidence 산출). 백탭이 동기 경로를 타면서 0.0 이 고정됐다. 두 경로를 **worker 하나로 단일화**해 일관성을 회복하고, 동시에 Gemini 호출을 2회→1회로 줄였다.

## 2. 변경 묶음

### backend (`make test` 95 passed · lint · typecheck)
- **B1** `orm.py` `mochi_items.intent_candidates`(JSONB) + alembic `0008`.
- **B2** agent `finalizeAnalysis` 스키마를 candidates 모델로(`gemini_agent_client.py`), `MultimodalAnalyzeOutput`/`AnalysisResult` 에 candidates, `orchestrator._to_analysis_result` 가 primary/secondary/applicability/`confidence=max(applicability)` derive. 프롬프트 **V5 신설**(`system_prompts.py`, 분류기의 3-후보 한국어 프롬프트 통합) → `ACTIVE_PROMPT`.
- **B3** `apply_analysis`(ports·repository·gateway)에 `intent_candidates` 저장.
- **B4** `/back-tap` 동기 분류 제거 → `.ingested` 적재 + outbox emit 만(`back_tap_ingest.py`). 고아 정리: `gemini_classifier.py` 삭제, `IntentClassifier` 포트·`IntentClassificationResult`·`from_classification`·`BackTapMochiItemResponse`·deps 배선 제거.
- **B5** `MochiItemResponse.candidates` + `_to_response` round-trip(`schemas.py`·`router.py`). `IntentClassification`(단일 후보)은 도메인 `MochiItem.intent_candidates` 값객체로 재사용.
- 테스트: `test_intent_classification_result.py`(derive→`_to_analysis_result`), `test_mochi_item_entity.py`/`test_override_intent.py`(MochiItem 직접 생성), `test_back_tap_ingest.py`(분류 없는 ingest), `test_agent_loop.py`(candidates payload) 재작성.

### ios (`tuist build` CorePersistence + `tuist test` CoreDomain·CorePersistence 통과)
- **I3** `ingestBackTapMochiItem` → `MochiItemDTO` 반환, `MochiItemDTO.candidates` 추가, `BackTapMochiItemResponseDTO` 제거(`MochiAPIClient`·`URLSession`·`DI`).
- **I1** `MochiItemSyncWorker.uploadOne` 백탭 분기: 분류 응답 처리·`applyClassification` 제거 → `.uploaded` 만 → `pollAnalysisOnce` 대상이 됨.
- **I2** 판정 재설계(`MochiItemAnalysis`): `isUncertain := confidence < 0.6`(박빙 gap 폐기), `activeSecondaryIntents`/`isMultiIntent`(top1·top2 둘 다 ≥0.6 = 복수 의도). `candidates(from dto)` 가 label 보존. 폴링 active 분기가 Live Activity `.ready` 트리거(foreground). `RealmObjects.intentTopGap` 제거 + Realm schemaVersion **3→4**. `listAmbiguous` 쿼리 `confidence < 0.6`.

### docs
- `DOMAIN_DESIGN.md`: confidence 정의·**3상태 판정**(헷갈림/단일 확신/복수 의도) 명문화, `intent_candidates`·`secondary_intents`·`intent_applicability` 스키마 추가, multi-intent 를 **단일테이블 JSONB 정본 확정**(frontmatter).
- `ARCHITECTURE.md`: agent `finalizeAnalysis` candidates 모델 반영(§5.5).
- `CHANGELOG.md` 최상단 항목. `openapi.json` 재생성(`make openapi`, BackTap 스펙 0건).

## 3. 핵심 설계 결정 (정본)

- `confidence := 최상위 후보 applicability` (단일 원천). 3상태가 이 값으로 갈림:
  - **헷갈림** `confidence < 0.6` → "헷갈려요" 카드.
  - **단일 확신** top1 ≥ 0.6, top2 < 0.6.
  - **복수 의도** top1·top2 둘 다 ≥ 0.6 → 헷갈림 아님. 보조 의도는 UI 미노출, 추천·알림·채팅용.
- 박빙(top-2 gap) 조건 폐기 — 둘 다 높은 복수 의도를 헷갈림으로 오분류했기 때문.

## 4. 검증 상태

- backend: `make test`(95 passed) · `make lint`(clean) · `make typecheck`(97 files, no issues).
- ios: `tuist build CorePersistence`(빌드 성공, 경고는 pre-existing) · `tuist test CoreDomain`·`tuist test CorePersistence`(통과).
- **미수행**: 실서버 e2e, 실기기/시뮬 앱 실행(사용자 `xcodebuild` 영역).

## 5. 잔여 과제 (다음 세션 — git diff 확인 후 진행)

1. **커밋** — 현재 미커밋. develop 브랜치. backend·ios·docs 한 단위(계약으로 묶여 부분 머지 불가). `/ship` → 커밋.
2. **실기기/시뮬 e2e 검증** (사용자) — 실제 백탭 → worker 분석 → foreground 폴링 반영 → "헷갈려요"가 confidence 를 제대로 반영하는지. **Realm schemaVersion 3→4** 라 기존 설치 앱은 자동 migration(또는 재설치) 필요.
3. **APNs / background Live Activity** — 현재 LA `.ready` 는 foreground 폴링 한정. background 백탭(snippet 직접 업로드)은 앱 active 시 폴링이 정리. APNs push-to-start/update 도입 시 즉시 갱신. (사용자: "APNs 추가 예정, 지금은 아님".)
4. **multi-intent UI 활용 배선** — `activeSecondaryIntents`/`isMultiIntent` 는 derive 되지만 Features 레이어 미사용(top1 만 노출). 추천·알림·채팅에서 활용.
5. **문서 전면 정합 (잔존 drift)** — `DOMAIN_DESIGN` 문서↔코드 컬럼명(`title`/`summary`, `intent_confidence`/`confidence`, `occurred_at`/`captured_at`) 정합. frontmatter 에 잔존으로 명시함. openapi known-drift 3건 재확인.
