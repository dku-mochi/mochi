---
level: 3
mode: log
status: active
last_verified: 2026-06-21
confidence: 0.9
owners: [송준서, 이용찬, 박세현]
title: 채팅 propose 일정 메타 채움(category/summary/entities) + 테스터 피드백 4건 — Handoff
description: 채팅 propose_create_schedule(일정 카드)이 §5.2 분석 생략이라 MochiItem.analysis 산출물(category/summary/entities)이 통째 비어 월간정리 "그 외"·리스트 빈약. propose를 gemini_monthly_digest 패턴(간소화 카테고라이징 컨텍스트 + category window + 확정 일정 → response_schema JSON 1회)으로 감싸 메타를 도출·운반하는 ⓪티어 계약 폭포 작업을 다음 세션이 0부터 구현할 수 있게 정리. 테스터 4건 현황 포함.
---

# 채팅 propose 일정 메타 채움 + 테스터 피드백 4건 — Handoff (2026-06-21)

## 0. TL;DR (한 화면)

채팅에서 **`propose_create_schedule`(일정 카드)로 만든 항목**은 §5.2(분석 생략) 때문에 `MochiItem.analysis` 산출물(`category`·`summary`·`entities`)이 **통째로 비어** 태어난다 → 월간정리에서 "그 외"로 빠지고 리스트/검색이 빈약하다. (`propose_create_memo`는 분석 경유라 정상 — 문제는 schedule만.)

**고칠 것**: `propose_create_schedule`을 **`gemini_monthly_digest` 패턴으로 감싼 경량 메타 도출 LLM**으로 보강 — 간소화 카테고라이징 컨텍스트 + 최근 category window + 확정 일정 맥락을 주입하고 `response_schema`로 `{category, summary, entities[]}`를 JSON 1회(flash-lite) 받아 → `confirmedInstances` 확정 저장 경로로 운반. **instance(날짜·일정)는 채팅 확정값 그대로 보존(§5.2 유지), 메타만 채움.** ⓪티어 계약이라 백엔드→`make openapi`→iOS→문서 폭포가 한 묶음.

테스터 4건 중 **1**(단축어/설정 영역, 앱 무관)·**3**(RecallHero 2개 흔들림)·**4-iOS 안전망**은 처리되어 커밋(`6b2c0ed`). **2**(알림 딥링크 cold-start)·**4-근본**(이 propose 작업)은 **미착수**.

> 남은 미완 결정 1개: 메타 도출 LLM에 줄 "채팅 맥락" 범위(확정 args만 vs 대화 history 일부 — summary 품질용, **history 일부 권장**).

## ✅ 구현 완료 (2026-06-21) — 이 핸드오프의 propose-메타 부분은 머지 코드에 반영됨

다음 세션이 이 문서만 보고 폐기 결정을 되돌리지 않도록, **실제 구현이 원안에서 갈라진 3곳**을 못박는다(상세·근거는 `docs/CHANGELOG.md` 2026-06-21):

1. **entities 제외** — §0/§4/§6 의 `entities[]` "필수 필드" 계획은 **폐기**. `MochiItem` 도메인이 raw entities 가 아니라 projection(`reference_links`/`shopping_product_query`)으로만 보유하고, `propose_create_schedule` 엔 `url` 필드도 없어 schedule 의 entity 가치가 marginal. 최종 범위 = **category + summary 만**.
2. **window 소스 = `list_normalized_categories`** (repository, 정규화 라벨) — §6-A #1 의 `_recent_analysis_context`(=`list_recent_window`, 분석 전체) 재사용안 대신 채택. category 네이밍 일관성이 목적이라 정규화 라벨 window 가 적합.
3. **raw 대화 history 미주입** — §5.1 의 "history 일부 권장"은 **채택 안 함**. propose `args`(`note`·`display.description`)가 이미 메인 채팅 모델이 대화를 distill 한 값이고, raw history 주입은 `ChatTool` 포트(tool 9개) 변경이 필요해 비례하지 않음. 최종 맥락 = **args + category window**.

구현: 백엔드 `ScheduleMetaLLM`/`GeminiScheduleMeta`(`conversations/infrastructure/gemini_schedule_meta.py`) + `ProposeCreateScheduleTool` 주입, ⓪계약 `MochiItemCreateRequest.category/summary` → ingest 확정 분기 운반, iOS `CreateSchedulePayload`·`MochiItemIngestRequest` 운반. **§6 의 2번(알림 딥링크 cold-start)은 여전히 미착수** — 별개 축.

---

## 1. 대화 흐름 — 어떻게 여기까지 왔는가

테스터 피드백 4건을 받아 각각 근본원인을 추적했다. 4번("그 외/미분류·빈약")이 가장 깊었고, 표면→근본으로 파고든 과정이 핵심이다:

1. 표면: 월간정리에 "그 외"(미분류) 묶음과 "그외"(top-N 초과분)가 공존 + 띄어쓰기 불일치 → iOS 문자열·`makeGroups` 안전망 수정(아래 §2).
2. 한 겹 아래: 백엔드 `monthly_digest.py:28,102` `_FALLBACK_GROUP = "그 외"`가 `category` 없는 항목을 묶고, iOS `MonthlyDigestFeature.swift`의 `updateCategories`가 그 라벨을 로컬에 write → "그 외" 영구화.
3. **진짜 근본(사용자가 직접 지목)**: 채팅 `propose_create_schedule` 확정이 `ingest.py:64-72`에서 분석을 생략(§5.2)해 `category`·`summary`·`entities`를 안 채운다 → "그 외"의 발원지.
4. 해법 수렴(사용자 주도): "propose 시점에 LLM이 다 채워라" → "별도 분석 재호출은 instance를 delete-reinsert로 덮으니(§5.2 위반) 안 됨" → "propose tool을 LLM+window로 감싸라(채팅 프롬프트 항상 오염 X)" → "`monthly_digest`처럼 간소화 컨텍스트 + JSON 응답이면 끝(nested LLM 무게 걱정은 over-engineering)".

근본원인·운반경로는 워크플로 2개로 매핑: `wim3vp5p3`(피드백 4건 근본원인+적대적 검증), `wm0qcfude`(propose→ingest 운반경로+계약·문서 영향).

---

## 2. 현재 코드 상태 (작동 가능 여부 + 변경 파일)

- **working tree clean** — 추적 파일 변경 없음(untracked PNG 20개만, 무관). 이 세션의 iOS 변경은 **커밋 `6b2c0ed`("주간→월간 digest + 분류 v25 + 홈 히어로 3D")에 포함**됨. 세션이 3일(06-19~06-21)에 걸쳐 진행되며 외부에서 커밋됨.
- **세션 중 리네임**: `WeeklyDigest*` → `MonthlyDigest*` (커밋 `6b2c0ed`). 옛 라인번호 무효.

### 처리·커밋된 것 (`6b2c0ed`)
- **3번 RecallHero 흔들림** — `mochi-ios/.../FeatureInbox/Sources/RecallHeroView.swift`:
  - `placement`(:244-250 부근) `count > 2`만 무한 wrap, `count <= 2`는 wrap off(`n = index - rotation`).
  - `dragGesture` onChanged(:171)·onEnded(:183) `count <= 2`면 `rotation`을 `[0, count-1]`로 clamp.
  - 근거: count==2에서 wrap 윈도우 (-1,1] 퇴화 → 정수(스냅 타깃) 경계 텔레포트 + underdamped 스프링 overshoot 왕복이 "왔다리 갔다리". (RecallHero는 auto-rotate 없고 100% 드래그 구동.)
- **4번 iOS 안전망** (분석 전·미분류 항목용; 근본은 백엔드):
  - `MonthlyDigestFeature.swift`: `pendingLabel = "정리 중"`(:266), `DigestGroup.isSearchable`(:49), `makeGroups`(:268~) — `category 있음→그 값` / `analysis==nil→"정리 중"` / `분석됨·category 없음→MochiHomeFeature.fallbackCategory(intent 기반)`. "그 외" 묶음 제거. "정리 중"은 맨 끝 정렬.
  - `MonthlyDigestView.swift`: `canViewAll`→`group.isSearchable`(검색 가능 그룹만 "전체 보기"), 초과분 문자열 "외 N개"·"그 외 N개 더 보기"→**"기타"** 통일.
  - `MochiHomeView.swift`: 초과분 "그외"→**"기타"**(name·accessibilityLabel·주석).
  - `MochiHomeFeature.swift`: `fallbackCategory` `private` 제거(상세에서 재사용, 같은 모듈 internal).

### 미착수
- **4번 근본** — 백엔드 propose 메타 채움(이 핸드오프의 메인). §6.
- **2번** — 알림 딥링크 cold-start 유실. §6.

---

## 3. codex 검증 결과

이 세션은 `code-reviewer`/`qa-validator`(codex) **미실행**. 3·4번 iOS는 커밋됐으나 이 세션에서 `tuist build/test` 미검증 → **다음 세션이 먼저 `tuist build && tuist test`로 회귀 확인 권장**(특히 `MochiHomeFeature.fallbackCategory` internal 노출·`MonthlyDigestFeature.makeGroups` 시그니처 변경).

---

## 4. 결정 / trade-off (왜 이렇게)

- **propose 메타: "propose-시점 경량 LLM"(채택)** vs 결정론적 채움(A: LLM 없이 intent→category, 빈약) vs 재분석(B: worker가 instance delete-reinsert로 덮음 → §5.2 위반). 채택 이유: instance 보존 + 메타 풍부 + 사용자가 추가 호출/tool 허용.
- **nested LLM "무게" 걱정 기각**: `gemini_monthly_digest`가 이미 동일 패턴(port 1개 주입). 별도 무거운 구조 발명 불필요.
- **window "항상 주입" 기각**: 채팅 본 프롬프트에 매 턴 window를 실으면 토큰 오염·비용. → propose 경량 호출 **안에서만** window 사용.
- **범위 = category + summary + entities**(사용자 확정). entities는 URL 케이스에서 `reference_url`로 채워짐(메모/일정에 링크 끼는 경우). 폴백 불필요 — title처럼 **필수 필드**로 둔다("그 정도는 나와야 propose를 하지").
- **1번(백탭 스샷 오염)**: 앱 코드 문제 아님 — 캡처 주체는 iOS 단축어 `Take Screenshot`(앱은 결과만 받음). iOS18 "Back Tap Detected" 배너는 `설정>손쉬운 사용>터치>뒷면 탭>Show Banner OFF`. 단축어 실행 배너는 "없음(Nothing)" 액션 맨 앞 또는 Wait 폴백. 백탭→Shortcuts 트리거 지연은 시스템 한계(세 번 탭 None으로 더블탭 debounce 완화). **앱 변경 없음 — 단축어/설정·온보딩 가이드 영역.**

---

## 5. 미완 결정 (사용자 선택 대기)

1. **메타 도출 LLM 맥락 범위**: 확정 args(title/date/note)만 vs 대화 history 일부 → **history 일부 권장**(summary "왜 저장" 품질).
2. **`reference_url` 풍부화**: 1차는 URL 직접 저장, `findReferenceUrls`(분석 tool) 호출까지는 보류 vs 포함.
3. **`reanalyze` 409 가드**: `POST /{id}/reanalyze`가 confirmed schedule 메타를 덮을 수 있으나 현실 트리거 경로 없음(`needs_review=False`) → **보류 권장**(Simplicity First).
4. **`model_version`**: confirmed item에 `'chat-proposal'` 출처 표식 넣을지 vs None.

---

## 6. 다음 단계 + 검증 기준

⓪티어 계약 폭포라 **한 묶음으로** 가야 빌드가 맞다(부분 변경은 generator no-diff 게이트에서 깨짐).

### 6-A. 백엔드 (`make test`/`make lint`/`make typecheck` + `make openapi`)
1. **경량 메타 도출 use case 신설** — `gemini_monthly_digest.py:27-142` 복제: flash-lite + `thinking_budget=0` + `response_schema`(`{category, summary, entities[]}`). 프롬프트는 `system_prompts.py:229-246`(category 2-8자 명사구·광범위 버킷 금지 / summary 1-2문장 / entities {kind,value}) 발췌 + **최근 category window**(`orchestrator._recent_analysis_context`:349-367 재사용 = `list_recent_window` gateway) + 확정 일정 맥락. port로 정의(`MonthlyDigestLLM` 패턴).
2. `propose.py` `ProposeCreateScheduleTool` — `parameters`(:263-279)는 그대로 두되, `run()`(:281-309)에서 위 use case 호출 → `_card` create_schedule payload(:301-309) 최상위에 `category/summary/entities` 실음. tool에 port 주입(`conversations/presentation/router.py:94` `_build_chat_tools`).
3. `schemas.py` `MochiItemCreateRequest`(:70-85)에 **top-level** `category: str|None`, `summary: str|None`(+entities). instance(ConfirmedInstanceDTO)가 아니라 item 레벨.
4. `ingest.py` `IngestCommand`(:16-27)에 필드 추가 + 확정 분기 `MochiItem` 생성(:67-72)에 `category=`, `summary=` 전달. (도메인·`repository.add`·응답매핑은 **이미 배선됨** — `repository.py:255-258`, `router.py:172-173`. 운반만 뚫으면 저장됨.)
5. `router.py` `IngestCommand` 조립(:254-273)에 전달.
6. `make openapi` → `openapi.json` `MochiItemCreateRequest`에 category/summary 자동 반영(수기 금지).

### 6-B. iOS (`CodeGen/generate.sh` + `tuist build`/`tuist test`)
1. `CodeGen/generate.sh` 재생성 → `Generated/Types.swift` `MochiItemCreateRequest`에 필드(수기 금지, no-diff 게이트).
2. `MochiAPIClient.swift` `MochiItemIngestRequest`(:336-368)에 `category/summary` 프로퍼티+init+CodingKeys.
3. `OpenAPIMochiClient.swift` `ingestMochiItem`(:34-62)에서 전달.
4. `ChatStreamClient.swift` `CreateSchedulePayload`(:107-115)에 필드 + `ChatProposal.init?` create_schedule 분기(:204-215)에서 `payload["category"]/["summary"]` 디코드(SSE는 계약 밖 free-form — 수기).
5. `ChatFeature.swift` `.createSchedule` 확정(:482-493)에서 `MochiItemIngestRequest`에 전달.

### 6-C. 문서 (정합성 폭포)
- `docs/DOMAIN_DESIGN.md` §5.2 — "분석 생략"을 "재분석 없이 propose-시점 메타 채움"으로 재해석.
- `docs/ARCHITECTURE.md` — SSE proposal wire format에 category/summary 추가.
- `docs/CHANGELOG.md` — `backend`·`ios` 범위.
- `ship-precheck.sh §5a/§5b`(OpenAPI 단일계약 동기화) 게이트 통과.

**검증 기준**: 채팅에서 일정 추가 → 카드에 category/summary 미리 보임 → 확정 → `MochiItem.category/summary` 채워짐 → 월간정리에서 "그 외"가 아니라 제 카테고리로, 최근 category와 네이밍 일관.

---

## 7. 컨텍스트 부채 (먼저 볼 것)

- `mochi-backend/app/modules/mochi_items/infrastructure/gemini_monthly_digest.py` — **복제 원본 패턴**(간소화 컨텍스트 + response_schema JSON 1회).
- `mochi-backend/app/modules/agent/prompts/system_prompts.py:229-246` — category/summary/entities **기준 정본**.
- `mochi-backend/app/modules/agent/application/orchestrator.py:349-367` — `_recent_analysis_context` = window 일관성 장치(재사용).
- `mochi-backend/app/modules/mochi_items/application/ingest.py:64-78` — §5.2 확정 분기(메타 미설정 지점).
- `docs/DOMAIN_DESIGN.md §5.2` — 확정 proposal 분석 생략 예외(재해석 대상).
- 워크플로 결과 파일: `wm0qcfude`(운반경로 매핑) / `wim3vp5p3`(피드백 근본원인) — `/private/tmp/claude-501/.../tasks/<id>.output`.
- 백엔드 git: `6b2c0ed`에 대량 변경 커밋. propose 작업 변경은 위 6-A 파일로 격리, 커밋은 사용자 요청 시.
- 2번 딥링크(별개): `RootFeature` `pendingNotificationRoute` 큐 + `phase==.authenticated` 전이(`sessionResolved`/`signedIn`) flush. 끊김 지점 `ZoomDetailPresentation.swift:80`, `MainTabFeature.swift:320`(재진입 락인). recall은 NavigationStack이라 별개 축(`recallLanding` fetch 실패).
