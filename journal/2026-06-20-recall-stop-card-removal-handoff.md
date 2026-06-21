---
level: 3
mode: log
status: active
last_verified: 2026-06-20
confidence: 0.9
owners: [송준서, 이용찬, 박세현]
title: 회수 "그만 보기" 카드 화면 제거 — Handoff
description: 능동 회수 상세의 "그만 보기"가 reaction 만 기록하고 홈/목록에서 카드를 안 빼는 미션 위반(코드리뷰 Phase 1 잔여). 다음 세션이 0부터 구현할 수 있게 파일·앵커·delegate 배선·opened 패턴·미완 결정·검증을 정리.
---

# 회수 "그만 보기" 카드 화면 제거 — Handoff (2026-06-20)

## 0. TL;DR (한 화면 요약)

능동 회수 상세(`RecallDetailFeature`)에서 **"그만 보기"** 를 누르면 서버에 `stop` reaction(plan cancel)은 기록되지만, **홈 회수 히어로(그리고 목록)에서 그 카드는 그대로 남는다.** "보던 기억을 그만 보겠다"는데 화면에 계속 보이는 미션 위반. `opened` 경로는 이미 `recallDetailClosed(itemID:)` 신호로 카드를 빼는데, `stop` 경로엔 그 신호가 없다. **고칠 것: `RecallDetailFeature` 에 `stopped(itemID:)` delegate 추가 → `MainTabFeature` 가 홈 제거(기존 `recallDetailClosed` 재사용)로 전달.** 코드 변경 ~3파일, 결정 불필요(아래 §4는 선택지).

> 코드리뷰 전체 리포트의 LOW 항목(미션 직결로 medium 상향 권장)으로 분류됐던 건이다. Phase 1 에서 보안(SSRF·nonce)·decay 를 먼저 처리하고 이 UI 건은 핸드오프로 남긴다(사용자 지시 2026-06-20).

## 1. 대화 흐름 — 어떻게 여기까지 왔는가

- 전체 코드리뷰(다관점 멀티에이전트) 결과를 Phase 0/1 로 나눠 처리 중.
- Phase 1 = SSRF 연결-핀 + Apple nonce + knowledge decay (완료) + 이 "그만 보기" 건.
- 사용자가 "그만 보기는 핸드오프만 작성" 으로 지시 → 구현 대신 본 문서 작성.

## 2. 현재 코드 상태 (작동 가능 여부 + 관련 파일)

작동은 한다(빌드/테스트 green). 단 "그만 보기" 후 카드가 안 빠지는 UX 결함만 존재.

**핵심 파일·앵커 (모두 미수정 현재 상태):**

- `mochi-ios/Targets/Features/FeatureInbox/Sources/RecallFeature.swift`
  - `RecallDetailFeature` (line 94~) — ③ 회수 상세. **목록 탭→상세, 알림 landing 직행**으로 push 된다(홈 히어로 카드 탭은 별도 경로 — 아래 주의).
  - `stopTapped` 핸들러 **line 173-184**: `didStop=true` + 토스트("이 기억은 더 꺼내지 않을게요") + `recordRecallReaction(reaction: .stop)`. **여기엔 홈/목록 제거 신호가 없다(= 버그 지점).**
  - `RecallDetailFeature.Action.Delegate` **line 126-131**: 현재 `openOriginal(itemID:)`, `openRelated(itemID:)` 만. → **여기에 `stopped(itemID:)` 추가.**
  - `state.entry.itemID` 가 회수 대상 mochiItem PK (제거 키).

- `mochi-ios/Targets/App/Sources/MainTabFeature.swift`
  - `RecallDetailFeature` push 위치: 목록에서 `.recallList(.delegate(.openDetail(entry)))` → `path.append(.recallDetail(...))` (**line 185-187**), 알림 landing (**line 372**).
  - `recallDetail` delegate 처리: `openOriginal`/`openRelated` (**line 190-198**). → **여기에 `stopped` case 추가.**
  - **opened 카드 제거 패턴(이걸 미러)**: `recallDetailClosed` — `state.detail`(zoom) 닫을 때 480ms 후 `.home(.recallDetailClosed(itemID: recallID))` 전송 (**line 273-293**). 같은 itemID 캡처로 "다른 카드가 안 빠지는" 가드 포함.
  - path enum 의 `.recallDetail(RecallDetailFeature)` (**line 403**).

- `mochi-ios/Targets/Features/FeatureInbox/Sources/MochiHomeFeature.swift`
  - 홈 회수 상태: `state.recall: [RecallFeedEntryDTO]` (**line 22**), `state.recallImages: [UUID: ImageRef]` (**line 25**).
  - 제거 핸들러 `recallDetailClosed(itemID:)` (**line 220-225**): `state.recall.removeAll { $0.itemID == itemID }` + `state.recallImages[itemID] = nil`. **stop 도 똑같은 제거가 필요 → 이 액션 재사용 가능.**

**⚠️ 두 개의 회수 상세 표면을 헷갈리지 말 것:**
1. **홈 회수 히어로 카드 탭** → `recallEntryOpened`(MochiHome line 204) → `recallItemOpened` delegate → MainTab 이 `state.detail`(zoom = 원본 `DetailFeature`)로 연다. "그만 보기"는 **여기 없다**(원본 mochiItem 상세이지 RecallDetailFeature 아님).
2. **회수 목록/알림 → `RecallDetailFeature`** (path push). **"그만 보기"는 여기 있다.** 그런데 사용자가 stop 하려는 카드는 홈 히어로(`state.recall`)에도 떠 있으므로, stop 시 홈 `state.recall` 에서도 빼야 한다.

## 3. 결정 / trade-off (권장 구현)

기존 `recallDetailClosed` 제거 로직을 **재사용**하는 게 가장 작고 일관적이다(opened-close 와 stop 의 "홈에서 카드 제거" 효과가 동일). 새 `recallStopped` 액션을 따로 만들면 의미는 또렷하나 중복.

**권장 3단계:**

1. **`RecallFeature.swift` — `RecallDetailFeature.Action.Delegate` 에 `case stopped(itemID: UUID)` 추가**, `stopTapped` 의 `.merge(...)` 에 `.send(.delegate(.stopped(itemID: state.entry.itemID)))` 한 줄 추가. (토스트·reaction 기록은 그대로 유지.)

2. **`MainTabFeature.swift` — recallDetail delegate 처리에 `stopped` case 추가** (line 190 근처):
   ```swift
   case let .path(.element(id: _, action: .recallDetail(.delegate(.stopped(itemID))))):
       // "그만 보기" → 홈 회수 히어로에서 그 카드 제거(opened-close 와 동일 제거 재사용).
       // 사용자는 토스트를 본 뒤 back 으로 돌아오면 카드가 사라져 있다(§4 (a) 참고).
       return .send(.home(.recallDetailClosed(itemID: itemID)),
                    animation: .spring(response: 0.45, dampingFraction: 0.85))
   ```
   (선택: 동시에 `state.path` 에서 그 `.recallDetail` 요소를 pop 해 자동 복귀 — §4 (a).)

3. **`MochiHomeFeature.swift` — 변경 불필요**(기존 `recallDetailClosed` 가 `state.recall`+`recallImages` 제거를 이미 수행). 새 `recallStopped` 를 만들고 싶다면 line 220-225 로직 복제.

서버 상호작용: `.stop` 은 트랙 A/B plan 을 cancel → 다음 `recallFeed` 에 안 뜬다(영구). 트랙 C(plan 없음)는 `dismissed_at` 기록 — 단 **백엔드 GetRecallFeed 가 dismissed_at 필터를 안 한다는 별도 리뷰 발견(HIGH-perf 항목)** 이 있으니, 트랙 C stop 카드가 재fetch 로 되살아나면 그 백엔드 필터를 먼저 고쳐야 한다(이 핸드오프 범위 밖, 교차 참조).

## 4. 미완 결정 (사람 선택 대기)

- **(a) stop 후 화면 동작**: 현재 stopTapped 는 상세에 머물며 토스트 + 버튼 잠금(`didStop`). 선택지 — (1) **그대로 머물고** 사용자가 back 하면 홈 카드 없음(최소 변경, 권장), (2) 토스트 후 **자동 pop**(`state.path` 에서 recallDetail 제거)해 즉시 복귀. (2)는 "보던 상세가 손가락 안 댔는데 사라짐" 위화감 vs 즉시성 trade-off — opened 의 480ms 착지-후-제거 톤과 맞추려면 약간의 지연 pop.
- **(b) 푸시된 회수 목록(`RecallListFeature`) 동기화**: 목록→상세로 들어가 stop 한 경우, 목록 화면에는 그 entry 가 재fetch 전까지 남는다. 목록도 즉시 빼려면 list 쪽 제거 신호가 추가로 필요. 목록은 재진입 시 refetch 하므로 **MVP 는 홈만 빼도 충분**할 수 있음 — 데모 시나리오(목록에 머무는지) 보고 결정.
- **(c) 액션 재사용 vs 신설**: `recallDetailClosed` 재사용(권장) vs `recallStopped` 신설(의미 또렷). 로깅/분석에서 close 와 stop 을 구분해야 하면 신설.

## 5. 다음 단계 + 검증 기준

1. §3 의 1~2 적용(delegate + MainTab 배선). §4 (a)(b)(c) 는 구현자가 선택.
2. **빌드**: `tuist build FeatureInbox` + `tuist build Mochi` (Claude 가 직접 실행 가능).
3. **TestStore 테스트** (FeatureInbox 테스트 타깃 존재 — `FeatureInboxTests`):
   - `RecallDetailFeature` `stopTapped` → `didStop=true` + `delegate(.stopped(itemID:))` 방출 + reaction 호출. (`mochiAPIClient` 는 테스트 더블, `continuousClock` 은 TestClock 로 토스트 advance.)
   - (MainTab 통합까지 본다면) `recallDetail(.delegate(.stopped))` → `.home(.recallDetailClosed(itemID:))` 전달.
   - 회귀: 홈 `state.recall` 에 그 itemID 가 사라지는지.
4. **수동 검증(실기기/시뮬, 사용자 실행)**: 홈 회수 히어로에 뜬 기억 → (목록 또는 알림으로) 상세 진입 → "그만 보기" → 토스트 → 뒤로 → **홈에서 그 카드 없음** + 다음 새로고침에도 안 뜸(트랙 A/B). 
5. **문서 동기화(§6 필수)**: `docs/UX_SPEC.md` 회수 섹션에 "그만 보기 → 카드 제거" 명문화, `docs/CHANGELOG.md` 한 줄.

**검증 통과 기준**: "그만 보기" 후 그 회수 카드가 홈에서 사라지고(낙관적, 서버 실패와 무관) 재출현하지 않는다. opened 경로 카드 제거는 회귀 없음.
