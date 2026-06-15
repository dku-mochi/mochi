---
level: 3
mode: log
status: active
last_verified: 2026-06-05
confidence: 0.9
owners: [송준서]
title: intent 빅뱅 + ingest 단일화 — PR-1 backend 구현 완료 핸드오프
description: 2026-06-04 핸드오프 설계의 backend 구현(PR-1) 완료. intent_instances 별도 테이블·0009·V7·G1·search/worker P1 수정·검증 green. 남은 것은 문서 폭포 잔여(DOMAIN_DESIGN 자기모순 해소)와 iOS PR-2. 이어받을 때 §2(남은 것)부터 읽어라.
---

# intent 빅뱅 + ingest 단일화 — PR-1 backend 핸드오프 (2026-06-05)

> 설계: `journal/2026-06-04-intent-instances-bigbang-handoff.md`. plan: `~/.claude/plans/splendid-doodling-yeti.md`.
> 이 세션은 **PR-1 backend 코드 + 핵심 문서**를 완성했다. 남은 건 문서 폭포 잔여 + iOS PR-2.

## 1. 완료 (backend — 검증 green)

- **도메인**: `value_objects.py`(IntentInstance/IntentPayload/ReviewOption/InstanceLifecycleKind/ArchiveReason/InstanceLifecycleState), `entities.py`(MochiItem 5필드→intent_instances/needs_review/review_options + `intent_types` property, LifecycleStateKind 4값 처리상태 `active`→`analyzed`, ArchiveReason 이동), `ports.py`(update_lifecycle/update_primary_intent 삭제, apply_analysis 시그니처).
- **DB**: `orm.py`(IntentInstanceRow 신설, MochiItemRow 5컬럼+lifecycle_archive_reason 제거+needs_review), `alembic 0009`(단일, backfill 없음, down 대칭). 체인 0008→0009 head 확인. **DB 대칭(upgrade/downgrade) 실DB 검증은 미실행** — 사용자 `make migrate` 환경에서.
- **agent**: `system_prompts.py` V7(boolean_instances_refined), `multimodal_analyze.py`/`gemini_agent_client._FINALIZE_PARAMS`(가변 instance + payload typed), `orchestrator._to_analysis_result`(derive 삭제→1:1), `analysis.AnalysisResult`, `mochi_item_gateway`/`profile`(intent_types).
- **repository/queries/api**: apply_analysis instance delete-reinsert(멱등), `_intent_match` EXISTS 조인, list_active_todos instance 조인, `_representative_intent` 고정 우선순위, `lifecycle_policy.py` instance 단위(표 B), schemas/router 응답 instance.
- **G1**: back-tap 라우트/`back_tap_ingest`/`BackTapMochiItemRequest`/`test_back_tap_ingest` 삭제, `_verify_uploaded_object`를 `create_mochi_item`으로 흡수(50MB·object_key 보유 전체 imageRef). `override_intent`/`PATCH /intent`/`swap_primary`/`test_override_intent` 삭제.
- **P1 수정 (code-reviewer가 잡음)**:
  - `search/postgres_index.py:44,69` — DROP된 `mochi_items.intent` raw SQL 참조 → `EXISTS(intent_instances)` 로. (빅뱅이 search 모듈 동기화 누락했던 것)
  - `agent/mochi_item_worker.py:135` — dead-letter 시 `mochi_items.lifecycle_kind='failed'` 전이 추가(iOS 폴링 컷오버 신호 §7.1, 기존 미구현).
- **테스트**: 단위 5개 재작성(entity/intent_classification/lifecycle/queries/agent_loop) + user_profile/ingest_e2e 정합. **89 passed**.
- **검증**: `make lint` ✅ `make typecheck` ✅ `make test`(89) ✅. `make openapi` 재생성(back-tap 소멸·intentInstances/needsReview/reviewOptions·폐기키 제거 확인) + iOS 동기화.
- **문서(완료)**: `DOMAIN_DESIGN` §4.4·§7·frontmatter·**§3 ERD·§4.3 DDL**, `CHANGELOG` 2026-06-05, **양 README(back-tap 제거)·INTENT_REDESIGN(status superseded)**.

## 2. 남은 것 — 다음 세션 시작점

### 2.1 문서 폭포 잔여 (`DOMAIN_DESIGN` 아직 일부 자기모순 — 머지 전 마저)
§4.4·§7·§3 ERD·§4.3 DDL·frontmatter 갱신 완료. 양 README·INTENT_REDESIGN(status superseded) 완료. **아직 옛 모델인 위치(라인은 §3/§4.3 갱신으로 밀렸을 수 있으니 grep 재확인):**
- `DOMAIN_DESIGN.md`: §1 원칙5(flat 원천), §2 용어(applicability/τ/confidence), §5 Realm 매핑(confidence/intentCandidates/candidates projection), **§6 endpoint 표(back-tap·`/{id}/intent` 잔존)**, §8.2 write-back 의사코드(candidates/applicability), **§10 마이그레이션(0009/0011 옛 서술 → 0009 단일·backfill 없음)**, §11 인덱스(GIN intents → intent_instances 인덱스), §12 카탈로그(intent_instances 행 추가·13테이블), 부록 C(confidence 3상태 — **통째 폐기 후보**)·D(reviewOpinions/candidates → needsReview/reviewOptions).
- `ARCHITECTURE.md`: §1 토폴로지(back-tap), §2.4 lifecycle 표(→2분할), §3.4 데이터흐름(back-tap·failed), §5.5 agent 주석(applicability/confidence/derive/위계). + 별개 축(이번 빅뱅 무관): §2.1/§7 수기 클라(URLSessionMochiAPIClient) 잔여 drift, "Gemini 3.5 Flash"→`gemini-3.1-flash-lite`.
- `PRODUCT.md §5`(L1): item↔instance 함의 1줄 보강(과잉 전파 회피 — substantive 판단).

### 2.2 iOS PR-2 (S5/S6 — plan 파일 참조)
- Realm: `RealmIntentInstance` 신설, `RealmMochiItem` intentRawValue/confidence→intentInstances/needsReview, schemaVersion 4→5 + `deleteRealmIfMigrationNeeded:true`. Mapper round-trip.
- Repository: `listAmbiguous`→`listNeedsReview`(needsReview 직접), `listActiveTodos` instance SUBQUERY, `listAnalyzing`(처리상태).
- CoreDomain: `MochiItem.intent` 삭제, `MochiItemAnalysis`(confidence/isUncertain/reviewOpinions/activeSecondaryIntents 재배선), `LifecycleState` 2분할.
- 네트: DTO + `OpenAPIMochiClient` 매핑, `MochiItemSyncWorker` **`case "active"`→`case "analyzed"`**(누락 시 폴링 영구 미종료), applyAnalysis/demoteToManual instance. G1: `ingestBackTapMochiItem` 삭제. `CodeGen/generate.sh` 재생성.
- UI: Home 버킷(needsReview), `DetailView` instance별 lifecycle 버튼, `MochiCalendar` 대표색 고정우선순위, `NeedsReviewCard` reviewOptions, IntentBadge instance. 테스트 재작성.

## 3. 미결 / 주의
- **DB 통합 테스트 부재**: round-trip(LLM 배열→행→복원)·instance 부분완료 격리·G1 흡수(위조 메타 거부)·alembic 대칭은 통합 fixture(conftest)가 없어 단위로 커버 못 함. 도메인/orchestrator/lifecycle/queries 로직은 단위로 검증됨. 실DB 검증은 사용자 `make migrate`/`make test`(DB up) 환경에서.
- **review_options 영구 빈 배열**: 분석은 비동기라 `MochiItemGatewayAdapter`가 result.review_options를 repo로 안 넘김 + DB 미영속(가드레일 2 의도). iOS "물어보기" 후보 UX는 DB 컬럼 승격 시 활성. 현재 needs_review boolean만 동작.
- **apply_analysis 사용자 변경 소실**: 재분석 = instance 전량 delete-reinsert라 사용자가 완료/아카이브한 instance lifecycle 소실. 실데이터 없어 안전, 보존은 후속 sprint(handoff §4, repository.py:304 주석).
- **lifecycle_policy unwired**: instance 전이 write 경로(override/PATCH 삭제 후) 없음 — 테스트만 exercise. instance lifecycle 전이 API는 후속(review_option 확정 UX).

## 4. 다음 세션 시작 프롬프트 (복붙)

```
intent 빅뱅 + ingest 단일화의 backend(PR-1)는 끝났다(make lint/typecheck/test 89 green, openapi 재생성). 이어서 남은 둘을 진행한다 — plan 은 이미 승인됨(~/.claude/plans/splendid-doodling-yeti.md), 재설계 금지.

먼저 이 핸드오프(journal/2026-06-05-intent-bigbang-pr1-backend.md) §2~§3 을 읽어라.

## A. 문서 폭포 마저 (DOMAIN_DESIGN 자기모순 완전 해소 — 머지 전 필수)
§2.1 목록대로 DOMAIN_DESIGN(§1·§2·§5·§6·§8.2·§10·§11·§12·부록 C·D)·ARCHITECTURE(§1·§2.4·§3.4·§5.5)·PRODUCT §5 를 새 모델(별도 intent_instances 테이블·needs_review·lifecycle 2분할·점수/대표/위계 폐기·back-tap 삭제)로 정합. 라인은 §3/§4.3 갱신으로 밀렸으니 grep 으로 재확인. 부록 C(confidence 3상태)는 통째 폐기 후보. 끝나면 doc-guardian 재스캔으로 모순 0 확인.

## B. iOS PR-2 (§2.2)
Realm(RealmIntentInstance·schemaVersion 4→5·deleteRealmIfMigrationNeeded), 네트(DTO·OpenAPIMochiClient 매핑·SyncWorker **case "active"→"analyzed"** ← 누락 시 폴링 영구 미종료), UI(Home needsReview 버킷·DetailView instance별 lifecycle 버튼·Calendar 대표색 고정우선순위 schedule>todo>knowledge>memo·NeedsReviewCard reviewOptions·IntentBadge instance). G1: ingestBackTapMochiItem 삭제, MochiItemSyncWorker back-tap 분기를 일반 ingest 로. CodeGen/generate.sh 재생성 → tuist test → ios-boundaries.sh.

## 검증
- 문서: doc-guardian 모순 0.
- iOS: tuist test, generate.sh no-diff, ios-boundaries.sh.
- (사용자 환경) DB: make migrate(0009 upgrade/downgrade 대칭) + make test(DB up) 로 round-trip/instance 격리/G1 흡수 통합 검증.

표준 루프(code-reviewer → qa-validator) 유지. 완료 후 CHANGELOG + /ship.
```
