---
level: 3
mode: log
status: active
last_verified: 2026-06-04
confidence: 0.9
owners: [송준서]
title: OpenAPI 단일 계약(A) — Phase 1 완료 핸드오프
description: API 명세 분산 → openapi.json 단일 계약(code-first 생성) 통합 작업. Phase 1(swift-openapi-generator 배선·생성·컴파일 검증·sync 메커니즘) 완료. Phase 2(adapter·DI swap·수기 클라 삭제)·3(게이트)·4(docs) 미완. 이어받을 때 읽어라 — 생성 surface 매핑·발견된 DTO drift·날짜/미들웨어 주의사항 전부 여기.
---

# OpenAPI 단일 계약(A) — Phase 1 핸드오프

## 0. TL;DR
- **목표:** API 명세가 4곳(백엔드 code·openapi.json·iOS 수기 클라/DTO·docs 산문)에 분산 → **openapi.json 단일 계약**으로. 백엔드 code=source(code-first), openapi.json=생성물, iOS=거기서 *생성*, docs=참조. (WORKFLOW ⓪-tier 목표, iOS 쪽이 비어 있던 것.)
- **Phase 1 완료·검증:** swift-openapi-generator 배선 → `Client.swift`+`Types.swift` 생성 → **`tuist build CoreNetworking` green** → `make openapi` sync 메커니즘 검증.
- **앱 안 깨짐:** 생성 클라이언트는 **additive**(컴파일만, 미사용). 라이브는 여전히 수기 `URLSessionMochiAPIClient`. Phase 2에서 swap.
- **미완:** Phase 2(adapter+swap+삭제) · 3(게이트 정리) · 4(docs dedup).

## 1. Phase 1 — 완료 (검증됨)
| 산출물 | 내용 |
|---|---|
| `mochi-ios/CodeGen/` | 사이드카 SPM 패키지(Tuist 밖). swift-openapi-generator **1.12.2**(1.6.0은 Swift 6.2서 컴파일 실패). `generate.sh` 가 생성 실행. |
| `CoreNetworking/openapi.json` | 백엔드 계약 사본(`make openapi` 가 동기화). |
| `CoreNetworking/openapi-generator-config.yaml` | `generate: [types, client]`, `accessModifier: public`. |
| `CoreNetworking/Sources/Generated/{Client,Types}.swift` | 생성물(1555+4214줄). **CoreNetworking 에서 컴파일 green**(runtime 1.6.0 그대로, HTTPTypes transitive). |
| `mochi-backend/Makefile` `openapi` | export + iOS 동기화. idempotent 확인(재export시 백엔드 json 변화 0). |

**검증:** `tuist build CoreNetworking` = **Build Succeeded**. `make openapi` 재실행 = no-diff + iOS 사본 일치.

## 2. 생성 surface (Phase 2용 매핑표)
**5개 operation (Client.swift):**
| 프로토콜 메서드 | 생성 operation |
|---|---|
| `ingestMochiItem` | `create_mochi_item_api_v1_mochi_items_post` |
| `ingestBackTapMochiItem` | `create_back_tap_mochi_item_api_v1_mochi_items_back_tap_post` |
| `presignCaptureUpload` | `presign_capture_upload_api_v1_mochi_items_presign_post` |
| `getMochiItem` | `get_mochi_item_api_v1_mochi_items__mochi_item_id__get` |
| `search` | `search_api_v1_search_post` |
| `putCaptureImage` | **(없음 — GCS 직접 PUT, URLSession 유지)** |

**Client init:** `Client(serverURL:configuration:transport:middlewares:)`. transport=`URLSessionTransport()`(swift-openapi-urlsession). `Servers` enum 비어 있음 → serverURL 직접 전달.

**스키마 매핑 (생성 `Components.Schemas.*` → 기존 DTO):**
- `MochiItemResponse` → `MochiItemDTO`: id `String`→`UUID`(파싱), channel, intent(생성은 **non-optional**, DTO는 `Intent?`), secondaryIntents `[Intent]?`, intentApplicability=**중첩 `intentApplicabilityPayload.additionalProperties [String:Double]`**, importance, confidence, candidates `[IntentCandidateResponse]?`, lifecycleKind, syncKind, imageRefs `[ImageRefResponse]?`, capturedAt/createdAt `Date`.
- `PresignResponse` → `PresignUploadDTO`: objectKey, uploadURL `String`→`URL`, expiresAt `Date`.
- `SearchResponse` → `SearchResponse`: answer, citations `[CitationDTO]`(mochiItemId `String`→`UUID`, snippet, score), totalTokens `Int?`.
- 요청: `MochiItemCreateRequest`(channel, imageRefs), `BackTapMochiItemRequest`(objectKey,sha256,mimeType,byteSize), `PresignRequest`, `SearchRequest`(query, scope `SearchScope?`).

## 3. ⚠️ Phase 2 발견사항 (반드시 처리)
1. **DTO drift (계약이 더 작다):** 생성 `MochiItemResponse` 에 **`url`·`text`·`userMemo`·`summary` 없음**. 수기 DTO엔 있음 → 여태 항상 nil 디코드. adapter는 가용 필드만 매핑, 없는 건 nil → **동작 보존**(앱은 이미 그 필드 nil). 단 백엔드가 그 필드를 *정말* 안 주는지(response_model 확인) 한 번 점검 권장.
2. **★ 날짜 (가장 위험):** 생성 클라가 `Date` 를 runtime 기본 transcoder 로 디코드. 백엔드는 **microsecond/naive** datetime(`2026-05-26T19:27:44.244325`) 송신 → 기본 ISO8601 거부. **`Configuration(dateTranscoder:)` 에 커스텀 주입 필수** — 수기 클라의 `tryParseDate`(URLSessionMochiAPIClient.swift:51-76) 로직 이식.
3. **Auth/헤더:** `ClientMiddleware` 로 `Authorization: Bearer`(`AuthTokenProvider`) + `X-Mochi-Request-ID` 주입. `Idempotency-Key` 는 op별 `Input.headers` 파라미터.
4. **SearchResponse.agentRunId 누락:** 생성기가 nullable(`anyOf[uuid,null]`) 을 skip(생성 경고). 기존 DTO `agentRunID: UUID?` → adapter nil. (원래 nullable이라 무해.) **장기적으론 백엔드가 OpenAPI 3.0 nullable 스타일로 내보내면 깔끔.**
5. **Output enum:** 각 op `Operations.<op>.Output` 의 성공 케이스(`.ok`/`.created`)·body 접근(`try output.ok.body.json`)는 **Types.swift 2589~4214 미독** — Phase 2서 읽어라.

## 4. Phase 2~4 단계 (이어서)
```
Phase 2 (CoreNetworking):
  - OpenAPIMochiClient.swift 작성 (MochiAPIClient 구현, 생성 Client 위임)
    · Client(serverURL, Configuration(dateTranscoder: 커스텀), URLSessionTransport(), [authMiddleware])
    · 5개 op 위임 + 매핑(§2,§3) / putCaptureImage 는 URLSession 유지
  - MochiAPIClientDI.liveValue = OpenAPIMochiClient(...)  ← swap (현재 NotConfigured)
    · 단, App/AppDependencies.swift 가 실제 live 주입하는 곳 확인
  - tuist build CoreNetworking green 확인  ← 게이트
  - URLSessionMochiAPIClient.swift 삭제 (green 확인 후에만!)
  - tuist test CoreNetworking / 8 호출부 무수정 컴파일
Phase 3 (게이트):
  - openapi-check.sh + ship-precheck §5 삭제 (iOS 생성이라 drift 구조적 불가)
  - ship/CI 에 'make openapi && git diff --exit-code' no-diff 게이트 추가
  - WORKFLOW ⓪-tier 표: API 계약 ③→⓪ 승격 기재
Phase 4 (docs §2.1):
  - ARCHITECTURE(21)·DOMAIN(13)·양 README 의 엔드포인트/필드 나열 → openapi.json 참조로
```

## 5. 안전 규칙
- **수기 `URLSessionMochiAPIClient` 는 adapter가 build green 되기 전까지 삭제 금지.** 그 전엔 생성 클라 additive.
- 8 호출부(App·FeatureMochiItem·FeatureSearch·SyncWorker·AppIntents 등)는 `MochiAPIClient` 프로토콜에 의존 → swap시 무수정.

## 6. 미해결 (사람 결정)
- §3-1 DTO drift: url/text/summary 를 백엔드 계약에 *추가*할지(수기 DTO 의도였다면) vs 계약대로 둘지.
- §3-4 백엔드 nullable 직렬화 스타일(3.0 vs 3.1) — agentRunId 등 깔끔히 생성되게 할지.
- CodeGen 생성물(Generated/*.swift) 을 커밋 유지 vs build-time 생성(현재: 커밋 + no-diff 게이트 방침).
