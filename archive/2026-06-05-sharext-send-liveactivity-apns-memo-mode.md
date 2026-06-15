---
level: 3
mode: log
status: draft
last_verified: 2026-06-05
confidence: 0.5
owners: [송준서]
title: ingest 업링크 재설계 제안 — ShareExt 직접 전송 + Live Activity APNs + 출처앱·일반메모
description: 3개 작업(ShareExt 직접 전송 / Live Activity·헷갈려요 APNs 재설계 / 출처앱 컨텍스트·일반 메모 모드)의 설계 제안(L3 draft, 미승인). 이 셋 중 하나라도 손대기 전 읽어라 — 공유표면(인증 토큰·push token DB·API 계약·CoreDomain) 다수 포함(L1/L2 수정 팀 합의 완료 2026-06-05). 구현 후 ARCHITECTURE/DOMAIN/PRIVACY 로 harvest 후 삭제.
---

# ingest 업링크 재설계 제안 — ShareExt 직접 전송 + Live Activity APNs + 출처앱·일반 메모

> 동기: 캡처 ingest 의 "전송 경로"와 "처리 상태 피드백"을 한 묶음으로 손본다. 세 작업이 모두 같은 단명 캡처 흐름(ShareExt·백탭)에 닿고 공유표면(인증·push·계약)을 건드리므로 한 저널에서 의존 관계를 함께 본다. **draft(미구현) — L1/L2 포함 공유표면 수정은 팀 합의 완료(2026-06-05). contract-first 킥오프(`WORKFLOW.md` §9)에서 계약 세부만 확정.**
>
> 선행 저널: [`journal/2026-06-05-shortcut-context-privacy-gate.md`](2026-06-05-shortcut-context-privacy-gate.md) — 출처앱(§3-C)·OCR·민감 게이트는 거기서 빌드업. 본 문서는 그 위에 "전송 경로"와 "Live Activity"를 더한다.

---

## 결정 로그 (2026-06-05, 송준서)

본 제안을 검토하며 내린 방향 결정. 미결은 §막힌 것 참고.

- **L1/L2 수정 권한**: L1(PRODUCT/WORKFLOW)·L2(DOMAIN/ARCHITECTURE/PRIVACY) 문서 수정 **팀 합의 완료(2026-06-05).** 더는 "합의 선행" 게이트 아님 — 구현 시 정합성 폭포대로 함께 정정한다(`WORKFLOW.md` §2 의 합의 게이트 충족).
- **B-MVP**: Live Activity·헷갈려요 APNs 를 **MVP(제출 2026-07-15) 범위에 포함.** post-submission 미루기 안 함.
- **B-역할분담**: 실시간 반영을 앱 상태로 나눈다 — **foreground = 기존 폴링 유지**(이미 작동, 0 추가비용), **background/종료 = APNs**. SSE(long-lived HTTP)는 background 진입 시 소켓 suspend 로 끊겨 foreground 전용인데, foreground 는 이미 폴링이 덮으므로 **SSE 는 MVP 제외**(서버엔 존재 — post-MVP 업그레이드 여지). scenePhase 경계 **reconcile**(background 중 놓친 push 메우기)은 공통 필수.
- **A·C-2 확인 2건**: Keychain access group 사용 여부(A)·ShareExt 취소 경로 이미지 정리 여부(C-2)는 **별도 선조사 없이 구현하며 확인**(우선 적용 후 검증).
- **B-헷갈려요표면**: 헷갈려요 의도 선택은 **interactive notification 으로 확정**(실기 확인 — 송준서). Live Activity 는 처리상태(analyzing→ready) ambient 표시 전담, 의도 *선택* 인터랙션은 notification 이 1급. 앱 내 needsReview 버킷은 always-on fallback.
- **B-알림정책**: 분석 완료 시 **항상 알림**(무음 분기 없음 — 빈도 과다는 **OS 알림 설정으로 사용자가 조절**, 앱이 가르지 않음). `needs_review=false` → "이렇게 저장했어요 — <요약>" 완료 알림(informative, 탭→앱), `needs_review=true` → interactive notification(후보 선택). 알림 본문은 **iOS 길이 제한으로 truncate** 되니 **요약은 1줄**(intent별 템플릿).
- **B-LA범위**: Live Activity 는 **백탭 스크린샷만 점유**. 공유시트 링크/텍스트 등은 LA 없이 완료 알림만. LA `.ready` 는 분류 *표시*만(선택 인터랙션은 notification).
- **C-1-컨텍스트**: 전달 대상은 "출처앱" 단일이 아니라 **확장 가능한 시스템 컨텍스트 묶음**(focus·시간 등 — 숏컷 테스트 후 추가 결정). → 포맷은 sentinel JSON(키 추가로 확장), 1급화 시 단일 `source_app` 컬럼 아니라 **확장 구조**(`capture_context jsonb`). MVP 1급화 여부는 숏컷 테스트 후.
- **C-2-channel**: 이미지 0 장(스크린샷 제거) 백탭은 **메모 channel** 로 적재(스크린샷 의미 탈색). 정확한 enum 값은 구현 시.

---

## 0. 현황 스냅샷 (코드 정본 추적, 2026-06-05)

세 작업의 출발점을 코드에서 확인한 결과.

| 축 | 현재 구현 | 정본 위치 |
|---|---|---|
| ShareExt 전송 | **전송 안 함** — App Group `inbound/*.json` + `capturedImages/` 에 떨굼. 메인 앱이 부팅/foreground 시 `drain()` → Realm `.pendingUpload` → `MochiItemSyncWorker` 가 presign→GCS PUT→`POST /mochi_items` | `ShareExtensionPrincipal.swift:58-66`(persist), `InboundQueueConsumer.swift:22-49`(drain), `MochiItemSyncWorker.swift:68-167`(전송) |
| Live Activity | **mock 프로토타입** — `MockUseCaseActivityAttributes`, `pushType: nil`, DEBUG 한정, 앱 launch 후 10초 가짜 흐름. 실제 분석 반영은 **foreground 3초 폴링**(SSE 서버엔 있으나 iOS 미구독, APNs 미도입) | `MockUseCaseActivityAttributes.swift`, `MockUseCaseNotificationPrototype.swift`, `MochiItemSyncWorker.swift:215-297`(폴링) |
| 처리상태/헷갈려요 | 처리상태 `ingested→analyzing→analyzed\|failed`. 헷갈려요 = `needs_review` boolean + `reviewOptions`(projection, **DB 미영속**). 버킷은 instances 빈 List=분석중, needsReview=헷갈려요 | `DOMAIN_DESIGN.md` §4.4·§7.1, `MochiItemAnalysis.swift` |
| 입력 채널 분리 | `text`=자동추출(OCR/공유텍스트/출처앱마커), `user_memo`=사용자 직접입력. **이미 2채널 분리됨** | `IngestSource.swift:22-29`, `ShareEntryView.swift:212-220` |
| 출처앱 | **필드 없음.** 컨텍스트 숏컷이 `[출처앱: X]` 를 List 로 이미지와 함께 보내 `text` 로 흡수 | `build-backtap-context-shortcut.py:56-71`, `ShareExtensionPrincipal.swift:104-112` |
| 이미지 삭제 | 없음 — `BackTapShareView` 는 이미지 우세 + 메모 한 줄, 제거 UI 없음 | `BackTapShareView.swift` |

---

## A. ShareExt 직접 전송 (인증/네트워크 구현)

### A.1 왜 지금은 큐인가 (제거하면 안 되는 제약)
ShareExtension 은 **단명 별도 프로세스**다. `AppDependencies.bootstrap()` 이 돌지 않아 `mochiAPIClient`·`AuthCoordinator`·`liveActivityCoordinator` 가 부재한다 (`ARCHITECTURE.md:137` 이 근거를 백탭 맥락에서 이미 명시). 그래서 "저장 결정"만 큐에 남기고 전송은 메인 앱에 위임하는 게 현재 설계다.

직접 전송으로 바꿀 때 부딪히는 4가지:
1. **인증 토큰 접근** — access token 이 메인 앱 Keychain 에 있다. ShareExt 가 읽으려면 **Keychain access group**(`keychain-access-groups` entitlement, App Group 과 별개) 공유가 필요. 현재 토큰 저장소가 access group 을 쓰는지 확인 필요(미확인).
2. **토큰 만료/refresh** — ShareExt 에서 refresh 토큰 회전까지 하는 건 부담(동시성·재진입). access token 만 읽고, 만료(401)면 **refresh 시도하지 말고 큐로 폴백**하는 게 안전.
3. **리소스 한계** — ShareExt 메모리 상한(~120MB)·실행시간 제약. 다중 이미지/대용량이면 presign+PUT 중 OOM/kill 위험. JPEG 변환(`CaptureUploadImagePreprocessor`)은 이미 메인 앱 경로에 있음 — ShareExt 로 옮기면 메모리 압박.
4. **사용자 대기** — 직접 전송하면 "저장" 탭 후 네트워크 왕복 동안 시트가 안 닫힌다. UX 저하. 백그라운드 전송 + 즉시 dismiss 가 필요.

### A.2 권장: "직접 전송 시도 → 실패 시 큐 폴백" 하이브리드 (큐 제거 금지)
큐를 없애지 말고 **fallback 으로 강등**한다. 둘 다 유지하는 게 안전성·속도 둘 다 잡는다.

```
ShareExt "저장" 탭
  → 이미지 저장(capturedImages/) + payload 구성             (지금과 동일)
  → 시트 즉시 dismiss + 백그라운드 Task
       ├─ access token 있음(Keychain group) → presign→PUT→POST /mochi_items (best-effort)
       │     성공 → 끝 (메인 앱 drain 불필요, 중복은 Idempotency-Key 가 흡수)
       │     실패(401·네트워크·timeout) ↓
       └─ inbound/*.json 큐에 떨굼 → 다음 메인 앱 active tick 의 SyncWorker 가 재시도
```
- **멱등키가 안전망**: payload `id`(UUID)가 곧 Idempotency-Key 라, ShareExt 가 올리고 메인 앱이 또 올려도 백엔드가 같은 행 반환(`router.py:160-203`). 중복 적재 불가 → 폴백이 안전.
- ShareExt 전송용으로 **경량 API 클라이언트**가 필요(전체 `OpenAPIMochiClient` DI 그래프 없이 presign/PUT/ingest 3개 op + AuthMiddleware 만). `CoreNetworking` 을 ShareExt 타겟에 링크 — TCA/Realm 그래프는 끌어오지 않게 의존 경계 주의(`ios-boundaries.sh` 통과해야).

### A.3 공유표면 / 견적
| 항목 | 공유표면 | AI 편집 견적 | 합의 리드타임 |
|---|---|---|---|
| Keychain access group 공유 (토큰 read) | iOS 인증 인프라 (`CoreNetworking`/`CoreAuth`) | ~1h + entitlement·실기 검증 | 낮음 (내부 결정) |
| ShareExt 경량 API 클라 + 폴백 로직 | ShareExt ↔ CoreNetworking 의존 | ~2h | 낮음 |
| 백엔드 | **0** — 같은 `POST /mochi_items` 재사용 | 0 | — |

> 백엔드·DB·openapi 무변경. iOS 인증 인프라(공유 Core)만 닿음. **A 는 공유표면이 가벼운 편** — Keychain group 한 가지만 합의.

---

## B. Live Activity·"헷갈려요" APNs 재설계 (iOS 가 기획 정본이 아님)

### B.1 "기획 정본 아님" 의 의미
현재 `MockUseCaseActivityAttributes`/`MockUseCaseNotificationPrototype` 은 **하드코딩 mock**("마우스 살까 말까", 10초 타이머, `pushType: nil`)이라 도메인을 표현하지 않는다. 따라서 재설계는 코드 포팅이 아니라 **기획 차원에서 두 가지를 먼저 정의**하는 일이다:
1. **Live Activity 가 표현할 상태 모델** — 처리상태(`analyzing→ready`)와 헷갈려요(needs_review)가 Live Activity 의 phase 와 어떻게 매핑되는가.
2. **헷갈려요 인터랙션을 어디서 받는가** — Live Activity 후보 버튼 vs interactive notification vs 앱 내. (현재 셋 다 mock 으로 흩어져 있음)

→ 이건 `DOMAIN_DESIGN.md`(L2)·`ARCHITECTURE.md`(L2)·`PRODUCT.md`(L1, "헷갈려요" 컨셉) 에 정본을 박아야 하는 **기획 결정**이다. 코드가 아니라.

### B.2 APNs 아키텍처 — foreground 폴링 + background APNs 핸드오프
**결정(§결정 로그)**: 실시간 반영을 앱 상태로 분담한다. 새로 까는 건 **background 용 APNs 한쪽**이고, 진짜 빈 구멍(백탭 후 앱 안 봄)을 APNs 가 메운다. foreground 는 기존 폴링이 이미 덮는다.

```
[foreground] 앱 켜짐
   → 기존 폴링(MochiItemSyncWorker.startForegroundPolling, 3초) 유지
     · 앱 내 기록 / 큐 fallback 도는 중 / 분석중 항목 → 홈·캘린더 실시간 반영
[background/종료] 앱 안 봄  ← 폴링·SSE 둘 다 못 잡는 유일한 구멍
   → APNs 만 메움

ingest(POST /mochi_items) 시 함께:
  ① Live Activity push token 등록 (Activity.request(pushType: .token) → 백엔드로)
  ② device APNs token 등록 (완료/헷갈려요 알림 용)
        ↓
백엔드 outbox worker 분석 완료 시:
  ├─ Live Activity 살아있으면 → APNs liveactivity push 로 ContentState 갱신 (analyzing→ready)
  └─ APNs alert push (분석 완료 시 항상 — 빈도는 OS 알림 설정으로 사용자 조절):
       · needs_review=false → "이렇게 저장했어요 — <요약>" 완료 알림 (informative, 탭→앱)
       · needs_review=true  → "어떤 의도로 남겼나요?" interactive notification (후보 선택)
     ⚠️ 알림 본문은 iOS 길이 제한으로 truncate → 요약 1줄(intent별 템플릿)
        ↓
scenePhase active 복귀 시 → reconcile: 폴링 1회 즉시 돌려 background 중 놓친 push 메움
```

- **Live Activity push 는 token 등록만 하면 백엔드가 ActivityKit push endpoint 로 직접 update** — 앱이 foreground 아니어도 갱신됨(폴링의 핵심 한계 해소, Live Activity 의 존재 이유).
- **staleDate·dismissal** 정책 필요 — 분석이 deadline(현재 폴링 90s) 초과 시 stale 처리.
- **폴링 제거 금지** — foreground 담당이자 push 누락 reconcile 수단(A 와 같은 fallback 철학). SSE 교체는 MVP 후 선택(여러 건 동시 분석 시 폴링 부하가 체감되면).

### B.3 처리상태/헷갈려요 상태 모델 재설계 (기획 정본 작성)
- `MockUseCaseActivityAttributes` → **실 attributes**: `mochiItemID`(로컬)·`serverID`·`capturedAt` + `ContentState{phase: analyzing|ready|confirmed, instances|candidates, needsReview}`.
- phase 매핑 정의: 처리상태 `analyzing` → LA `.analyzing`, `analyzed` + needsReview=false → `.ready`(확정 표시), `analyzed` + needsReview=true → `.ready`(후보 선택 대기). `failed` → end(실패).
- 헷갈려요 후보는 `reviewOptions`(projection)에서 옴 — DB 미영속이라 push payload 4KB 안에 실어야(후보 3개면 여유). **payload 4KB 한도** 가 instances 직렬화 설계 제약.
- **표면 분리(결정 — interactive notification)**: Live Activity = 처리상태 ambient 표시 전담(선택 액션 최소), **헷갈려요 의도 선택 = interactive notification**(`UNNotificationCategory` actions + NotificationContent multi-select). 앱 내 needsReview 버킷이 푸시 미수신 시 always-on fallback. → `MockUseCaseNotificationPrototype`·`NotificationViewController`·`MultiSelectCandidateView` 가 그 방향 프로토타입(실 데이터로 재배선).

### B.4 공유표면 / 견적 ⚠️ (B 가 가장 무겁다)
| 항목 | 공유표면 | AI 편집 견적 | 합의 리드타임 |
|---|---|---|---|
| device/LA push token 테이블 (신규) | **DB 스키마**(alembic 마이그레이션) | ~1.5h | 중 — 스키마 합의 |
| `POST /devices/push-token`·LA token 등록 API | **API 계약**(openapi.json) | ~2h | 중 — contract-first |
| 백엔드 APNs 클라이언트 (httpx + JWT auth key, p8) | 백엔드 인프라 + **외부 비밀값**(`TODO.md` 체크리스트) | ~3h + Apple 설정 | 높음 — APNs key 발급·환경변수 |
| outbox worker → push 발송 배선 | 백엔드 application/infra | ~2h | 낮음 |
| 실 Live Activity attributes + 위젯 UI | iOS Widgets/CoreLiveActivity | ~3h | 낮음 |
| 헷갈려요 상태모델 기획 정본 | **L1 PRODUCT·L2 DOMAIN/ARCHITECTURE**(수정 합의 완료) | 문서 ~1.5h | 중 — 헷갈려요 정본 표면 결정(막힌것§1) |

> B 는 DB·API·외부비밀·L1/L2 문서를 전부 건드린다. **편집 자체보다 합의·Apple 설정(APNs p8 key) 리드타임이 지배적.** 분리 착수 권장(B 를 A·C 와 같은 PR 에 묶지 말 것).

---

## C. 이미지+메모 / 출처앱 컨텍스트 / 일반 메모 모드

### C-1. 출처앱 컨텍스트를 "사용자 메모와 구분"해 전달 — 아이디어

**핵심 원칙: 모찌의 데이터는 이미 "자동 신호 ↔ 사용자 의도" 2채널이다.**
- `text` = 자동 신호 (OCR·공유 텍스트·**출처앱**) — 모찌가 분석 컨텍스트로 쓰는 재료
- `user_memo` = 사용자 의도 (직접 입력) — "왜 남겼나" 신호, `hasUserIntentSignal` 로 confidence 보정(`IngestSource.swift:51`)

→ **출처앱은 "자동 신호"이므로 `text` 계열이 맞고, `user_memo` 에 섞이면 안 된다.** 사용자가 요구한 "메모와 구분"은 이 2채널 경계를 지키면 자동 충족된다. 현재 숏컷 흐름(출처앱→`text`, 메모→`user_memo`)이 이미 그 경계를 지킨다. 문제는 **전달 포맷의 깔끔함**과 **사용자 노출**.

세 가지 전달 방법과 트레이드오프:

| 방법 | 전달 형태 | 공유표면 | 사용자 노출 | 평가 |
|---|---|---|---|---|
| **(1) 평문 마커** (현행) | `text` 머리에 `[출처앱: YouTube]\n…OCR…` | 0 | `ShareEntryView` previewCard 에 raw 노출 (어색) | 지금은 동작, UX 거침 |
| **(2) sentinel JSON** | 숏컷이 `{"__mochi_ctx__":{"sourceApp":"YouTube"}}` 텍스트로 전달 → ShareExt 가 파싱해 분해 | 0 (ShareExt 내부 분해, 백엔드 무변경) | ShareExt 가 칩으로 렌더, text 엔 구조적으로 합침 | **권장(지금)** |
| **(3) 컨텍스트 1급화 (확장 구조)** | `IngestSource.captureContext` + `mochi_items.capture_context jsonb` + API | **3곳**(CoreDomain·DB·openapi) | 키 추가로 확장(출처앱+focus+…) | **권장(컨텍스트 확정 후)** |

**권장: (2)→(3) 2단계 수렴.**
- **지금(무공유표면)**: 숏컷이 출처앱을 sentinel JSON 으로 보내고, `ShareExtensionPrincipal.extractInboundPayload` 가 "이 text 가 `__mochi_ctx__` sentinel 이면" 분해해서 (a) UI 엔 "YouTube에서 캡처" 칩으로 보여주고 (b) 백엔드엔 `text` 앞에 정규화된 한 줄(`[출처앱: YouTube]`)로 합쳐 보낸다. 사용자 입력 `memo` 는 끝까지 `user_memo` 로 격리. → **백엔드/DB/openapi 0 변경**, 사용자 노출 깔끔.
  - sentinel 이면 ShareExt 가 이걸 "텍스트 콘텐츠"가 아니라 "메타"로 인지 → previewCard 에 raw JSON 안 뜸.
  - 숏컷 빌더(`build-backtap-context-shortcut.py`)의 `text_with_token` 을 JSON 조립으로 교체.
- **재설계 후(컨텍스트 확정 시)**: 시스템 컨텍스트를 1급화 — 단일 `source_app` 컬럼이 아니라 **확장 구조**(`mochi_items.capture_context jsonb` + `IngestSource.captureContext`). 출처앱·focus·시간 등 키 추가만으로 확장되고, sentinel JSON 의 키 집합이 그대로 jsonb 로 승격된다. 분석 프롬프트가 구조적으로 받아 채널·intent 추론 품질↑. ⚠️ 위치·클립보드 등 민감 컨텍스트 확장은 **민감 게이트 선행**(선행 저널 §5).

> 왜 sentinel JSON 이 평문 마커보다 나은가: 평문 `[출처앱: X]` 는 (a) 사용자에게 그대로 노출되고 (b) 진짜 OCR 텍스트와 경계가 모호(파싱 깨지기 쉬움). JSON sentinel 은 "이건 메타다"를 명시해 UI/분석 분리를 깨끗하게 한다. **단 sentinel 도 숏컷이 만드는 거라 보안 경계 아님** — 선행 저널 §2 의 "숏컷은 신뢰 경계 아님" 원칙 그대로(컨텍스트 보너스일 뿐).

### C-2. 일반 메모 모드 (스크린샷 삭제) — UX 아이디어

**요구**: 백탭 → 숏컷 → ShareExt 진입했는데, 사용자가 "이건 스크린샷 필요 없는 일반 메모"면 스크린샷을 지우고 메모만 남긴다.

**제약 인식**: 백탭 숏컷은 진입 전에 **이미 스크린샷을 찍는다**(`takescreenshot` 액션). 즉 ShareExt 도착 시점엔 이미지가 손에 있다. "안 찍기"는 숏컷 분기로 불가능(시스템 액션 순서 고정)에 가까움 → **ShareExt 안에서 "버리는" UX 가 현실적**.

**권장 흐름: 인라인 제거 + 레이아웃 모핑 (별도 숏컷·별도 모드 진입 금지)**
```
백탭 → 스크린샷 자동 촬영 → ShareExt 시트
  [스크린샷 썸네일] ← 우상단에 (×) 또는 하단 "스크린샷 없이 메모만" 보조 버튼
        │ 탭
        ▼
  이미지 collapse 애니메이션 → 메모 textarea 확장 + 키보드 자동 포커스
  (= "스크린샷 없는 일반 메모" 모드. imageRefs 비워짐)
        │
        ▼
  capturedImages/ 의 해당 PNG 삭제 (고아 방지) + payload.imageRefs = []
  저장 → channel 재평가 (.screenshot → 메모성으로? §C-2 결정 필요)
```

UX 디테일 권장:
- **단일 진입, 시트 안에서 분기**: 메모용/캡처용 숏컷을 2개로 쪼개지 않는다. 백탭은 한 동작이라 사용자가 사전 선택 못 함 → 찍고 나서 시트에서 "이거 필요 없어요"로 버리는 게 자연스럽다.
- **제거 = undo 가능**: 이미지 collapse 후 "스크린샷 제거됨 · 되돌리기" 스낵바(수 초). 실수 복구 — 백탭이 오발화하는 경우가 잦아 안전망 가치 큼.
- **빈 상태 카피**: 이미지 제거 후 헤더를 "모찌에 남길까요?" → "메모를 남겨요" 로 모핑, placeholder "지금 떠오른 생각을…".
- **App Group 고아 청소**: ShareExt 가 `persistImage` 로 이미 디스크에 쓴 뒤라(`ShareExtensionPrincipal.swift:124-145`), 제거 시 그 파일을 지워야 stash 누수 없음. 저장 안 하고 취소(dismiss)할 때도 동일 — 현재 취소 경로의 이미지 정리 여부 확인 필요(미확인, 잠재 누수).
- **channel = 메모(결정)**: 이미지 0 장이 된 백탭은 스크린샷 의미를 벗고 **메모 channel** 로 적재. 정확한 enum 값(`.appDirectInput` 재사용 vs 신규 `.backtapMemo`)은 구현 시 결정 — 버킷·분석 프롬프트 영향. **시스템 컨텍스트(출처앱 등)는 이미지를 지워도 유지할지 결정 필요**(§막힌것) — "어느 앱에서 백탭" 은 메모에도 가치.

**대안(비추) 및 이유**:
- ~~"메모 전용 백탭 숏컷 별도 배포"~~ — 백탭 트리거는 더블/트리플 2개뿐, 캡처용에 이미 점유. 사용자가 메모/캡처를 미리 못 정함. UX 부담 ↑.
- ~~"스크린샷 안 찍는 숏컷"~~ — 그럼 ShareExt 가 이미지·텍스트 다 빈 채로 떠 빈 시트. 백탭의 "지금 화면" 맥락이 사라져 일반 메모앱과 차별성 상실.

### C-3. 공유표면 / 견적
| 항목 | 공유표면 | AI 편집 견적 | 합의 |
|---|---|---|---|
| sentinel JSON 출처앱 (C-1 지금) | **0** (ShareExt 분해 + 숏컷 빌더) | iOS ~1h + 숏컷 ~30m | 낮음 |
| 일반 메모 모드 UI (C-2) | iOS ShareExt UI 만 | ~2h | 낮음 |
| ShareExt 취소/제거 시 이미지 고아 청소 | iOS (버그성) | ~30m | 낮음 |
| `source_app` 1급 필드 (C-1 재설계 후) | **3곳** CoreDomain·DB·openapi | ~1.5h | 중 — contract-first |
| 빈 이미지 백탭 channel 의미 | DOMAIN(채널 enum) — 합의 시 openapi/DB | 결정 의존 | 중 |

> **C 의 "지금 할 수 있는 부분"(sentinel + 메모모드 UI + 고아청소)은 공유표면 0** — 재설계와 충돌 없이 선착수 가능. `source_app` 1급화·channel 의미만 재설계 후로 미룬다.

---

## 정합성 폭포 — 손댈 문서 (L1/L2 포함)

승인·구현 시 따라 바꿔야 하는 문서. **L1/L2 수정 팀 합의 완료(2026-06-05)** — 구현 시 함께 정정(`WORKFLOW.md` §2 합의 게이트 충족).

| 작업 | L1 | L2 | L3/코드/계약 |
|---|---|---|---|
| A 직접전송 | — | `ARCHITECTURE.md` §2.3 데이터흐름(ShareExt 전송 분기 추가) | iOS ShareExt·CoreNetworking, 양 README |
| B LiveActivity/APNs | `PRODUCT.md`(헷갈려요 컨셉이 push UX 와 닿으면) | `ARCHITECTURE.md` §2.5(폴링→push), `DOMAIN_DESIGN.md`(처리상태↔LA phase 매핑), push token **DB 스키마** | `openapi.json`(token API), alembic 마이그레이션, `TODO.md`(APNs p8 key), iOS Widgets |
| C 출처앱/메모 | — | `DOMAIN_DESIGN.md`(source_app 필드·channel enum, 재설계 후), `PRIVACY_SENSITIVE_CAPTURE.md` §6.2(출처앱은 §3-C 와 정합) | `ARCHITECTURE.md` §2.3 채널표, 숏컷 빌더, ShareExt |

→ 승인되면 본 저널의 결정을 위 문서로 **harvest 후 이 파일 삭제**(`WORKFLOW.md` §2.2 decision scaffolding 규칙).

---

## 권장 실행 순서 (의존성 기준)

빅뱅을 한 PR 로 묶지 말 것 — 공유표면 무게가 제각각이라 합의 리드타임이 다르다.

1. **C-지금 (공유표면 0)** — sentinel 출처앱 + 일반 메모 모드 UI + 이미지 고아 청소. 백엔드/계약 무변경이라 재설계와 독립, 즉시 가치. → 선착수.
2. **A 직접전송** — Keychain group 한 가지만 합의. 백엔드 0. 폴백이라 안전. → C 다음.
3. **B LiveActivity/APNs (MVP 확정)** — DB·API·APNs key·L1/L2 다수라 **contract-first 킥오프 별건.** 순서: 기획 정본(처리상태↔LA phase, 헷갈려요 인터랙션 위치) 합의 → push token API → APNs 클라(p8 key 발급 선행) → 위젯. **foreground 폴링은 유지, background 만 APNs 신규. SSE 는 MVP 제외.**

> 견적 분리(`CLAUDE.md` §1): 위 "AI 편집 견적"은 코드 작성 시간이고, B 는 **Apple APNs key 발급·팀 스키마 합의·L1/L2 승인** 리드타임이 편집 시간을 압도한다. A·C-지금은 편집 시간이 지배적이라 빠르다.

---

## 막힌 것 / 사람 결정 필요

> §결정 로그에서 처리: B-MVP·역할분담·헷갈려요표면(notification)·C-1컨텍스트·C-2channel·A·C-2확인건. 아래는 신규/잔여 미결.

**알림 (정책은 §결정 로그 B-알림정책·B-LA범위에서 확정. 아래는 구현 디테일):**
1. **notification 의도 선택 시 네트워크** — action tap → 백그라운드 즉시 POST(확정) vs 앱 깨우기? "다른 의도"는 foreground 필요. 구현 시.
2. **알림 권한 요청 타이밍** — 온보딩 vs 첫 캡처 시. 거부 시 앱 내 needsReview 버킷이 always-on 진실원천(푸시는 보조).
3. **완료 알림 요약 포맷** — iOS truncate 한도 내 1줄, intent별 템플릿("일정으로 — 6/10 3시 …" 등). 구현 시.

**전송·컨텍스트:**
4. **(A↔B) ShareExt 직접 전송 시 Live Activity 시작 주체** — ShareExt 가 LA 시작(즉시성) vs 메인앱/푸시가? bootstrap 부재라 가능 여부 확인.
5. **(C-1) 시스템 컨텍스트 범위·1급화 — 보류(지금 결정 안 함)** — 출처앱 외 확장(focus·시간·위치·클립보드)·jsonb 1급화 시점은 **숏컷 추가 테스트 후 가치 보이면** 결정. 지금 결정해 얻을 게 적음. 현재는 sentinel JSON 으로 출처앱만 흘리며 확장 여지만 열어둠. 위치·클립보드는 민감 게이트 선행.
6. **(C-2) 빈 이미지 백탭 channel enum 값** — `.appDirectInput` 재사용 vs 신규 `.backtapMemo`. 구현 시.
7. **(C-2) 일반 메모 모드에서 시스템 컨텍스트 유지?** — 스크린샷 지워도 "어느 앱에서 백탭" 은 남길 가치. 구현 시.

### 구현하며 확인 (별도 선조사 없이 — §결정 로그 A·C-2)
- **(A)** access token 저장소가 Keychain **access group** 을 쓰는지 — 안 쓰면 마이그레이션. 직접 전송 착수 시 확인.
- **(C-2)** ShareExt **취소 경로의 이미지 정리** 여부 — 안 되면 기존 stash 누수 버그. 메모 모드 착수 시 확인.

## 참조
- 코드: `ShareExtensionPrincipal.swift:58-66,104-145` · `InboundQueueConsumer.swift:22-49` · `MochiItemSyncWorker.swift:68-167,215-297` · `MockUseCaseActivityAttributes.swift` · `MockUseCaseNotificationPrototype.swift` · `IngestSource.swift:22-51` · `build-backtap-context-shortcut.py:56-71`
- 문서: `ARCHITECTURE.md` §2.3·§2.5(`:137,399-404`) · `DOMAIN_DESIGN.md` §4.3·§4.4·§7.1 · `PRIVACY_SENSITIVE_CAPTURE.md` §6.2·§7 · `WORKFLOW.md` §2·§3·§9
- 선행 저널: `2026-06-05-shortcut-context-privacy-gate.md`(출처앱·OCR·민감 게이트)
