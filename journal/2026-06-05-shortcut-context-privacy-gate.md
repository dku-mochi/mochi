---
level: 3
mode: log
status: draft
last_verified: 2026-06-05
confidence: 0.6
owners: [송준서]
title: 숏컷 활용 제안 — 캡처 컨텍스트 고도화 + 민감정보 1차 게이트
description: iOS 단축어로 백탭 캡처를 보강(앱이름·화면URL·OCR)하고 민감정보를 업로드 전 차단하는 제안(L3 draft, 미승인). 백탭 ingest·민감캡처·컨텍스트 보강을 손대기 전 읽어라. 공유표면(API/DB/CoreDomain) 닿는 항목 표시됨 — 재설계 안정 후 contract-first 합의 대상. 승인 시 PRIVACY_SENSITIVE_CAPTURE/DOMAIN 으로 harvest 후 삭제 가능.
---

# 숏컷 활용 제안 — 캡처 컨텍스트 고도화 + 민감정보 1차 게이트

> 동기: 백탭 스크린샷은 URL·텍스트가 없어 4-Intent 분류 컨텍스트가 가장 빈약하다. iOS 단축어 시스템 액션으로 (1) 캡처 컨텍스트를 보강하고 (2) 민감정보를 업로드 전 사용자 통제로 차단할 수 있는지 조사한 결과 + 제안. **미승인 draft.**

## 0. 전제 — 백탭 캡처는 이미 "단축어 조합" 구조

`CaptureScreenshotIntent.swift:6` 주석이 명시: 백탭 단축어가 `Take Screenshot → 이미지 변환(PNG) → 모찌 화면 캡쳐` 로 호출. 시스템 액션의 출력을 우리 인텐트의 `@Parameter image: IntentFile`(`:37`)로 받는 파이프라인이 **이미 작동 중**. 따라서 액션을 더 끼워 새 파라미터로 받는 것은 구조적으로 자연스럽다.

단축어 자체는 **iCloud 링크로 배포 가능** → 사용자는 링크 탭으로 추가/교체, 백탭 트리거 연결만 1회. 배포 마찰 낮음.

## 1. 실기기 검증 결과 (송준서, 2026-06-05)

| 액션 | 결과 | 판정 |
|---|---|---|
| **현재 앱 가져오기** (Get Current App, iOS 18.2+) | 너무 잘 작동 | 채택 후보 — 앱 *이름* 컨텍스트 |
| **화면상 항목 가져오기** (Get On-Screen Content) | **Safari URL만** 실효, 타 앱 빈약 | 제한적 — 앱 협조(NSUserActivity 추정) 의존 |
| **스크린샷 OCR** (Extract Text from Image) | 범용적으로 됨 | 채택 후보 — 단 노이즈 가공 필요 (§4) |

→ `Get On-Screen Content` 는 범용성이 낮아 우선순위 후순위. **OCR 이 범용 텍스트 컨텍스트의 실질 후보.**

## 2. 보안 — PRIVACY 문서와의 정합성

`PRIVACY_SENSITIVE_CAPTURE.md`(L2 committed)와 **방향 100% 일치**:
- §3.5 한국형 룰(주민번호·카드 Luhn·계좌·OTP·여권 등), §4 0-10점 스코어링, §5 6점↑ 경고/되묻기, §2.2 위험도 정책.

**그러나 설계만 있고 구현은 0.** §7.1 명시: *"MVP §8 구현 순서 기준 아직 미통합이며, 현재 intent 는 감지 없이 promote 한다"*(`PRIVACY_SENSITIVE_CAPTURE.md:307`). 1세션 백엔드 조사("ingest 경로에 마스킹 구현 없음")와 일치. → **숏컷 게이트가 이 공백을 가장 싸게 메우는 첫 방어선이 될 수 있다.**

### 숏컷 게이트 ≠ 문서의 CorePrivacy (대체 아님, 보완)

| | 문서 설계 `CorePrivacy`(§7.1) | 숏컷 게이트(제안) |
|---|---|---|
| 엔진 | Vision OCR + NSDataDetector + NER + Luhn + 조합 스코어링 | Match Text(정규식) + If |
| 커버리지 | 모든 경로(ShareExt·백탭·앱내) | 백탭(숏컷 경유)만 |
| 사용자 수정 | 불가(앱 바이너리) | **가능 → 보안 경계로는 약함** |
| 구현 비용 | 큼(§8 8단계) | 거의 0 |

문서가 "도메인 불변식이라 우회 금지"(`:8`)라 못박았으므로 **숏컷이 유일 방어선이 되면 안 됨**(사용자가 끄면 뚫림). 진짜 불변식은 앱/백엔드에도 필요. 숏컷은 "지금·백탭·공짜" 1차 게이트.

## 3. 두 수준 — 되묻기 vs 서버 전달

| | Level 0 — 되묻기만 | Level 1 — 서버로 민감 플래그/마스킹 텍스트 전달 |
|---|---|---|
| 동작 | 패턴 감지 → "민감정보 있는데 저장?" → 취소 시 ingest 안 함 | 마스킹 텍스트 + `sensitivity_score` 등 전송 |
| 백엔드 변경 | **0** | 필요 — §6.2 필드(`sensitivity_score`/`redaction_status`/`original_image_uploaded`…) 백엔드에 아직 없음 → **공유표면(API·DB)** |
| 지금 가능 | ✅ | ❌ 재설계 후 합의 |

**Level 0 이 ROI 최고** — 서버 무변경으로 백탭 경로 민감 유입을 사용자 통제로 차단. Level 1(문서 §6 semantic payload 본설계)은 공유표면이라 후속.

## 4. OCR 노이즈 — 용도 분리로 해소

- **민감 감지용 OCR**: 노이즈 무방 (정규식이 패턴만 잡으면 됨). 가공 불필요.
- **AI 컨텍스트용 OCR**: 노이즈가 분석 품질 저하 → 숏컷에서 자르지 말고 **백엔드 AI 에 raw 로 주고 "신호만 추출" 프롬프트**(AI 가 노이즈 필터링 우수).
- ⚠️ **미검증 의문**: 이미 이미지를 멀티모달(`gs://` 직접)로 넘기는데 OCR 텍스트가 추가 가치(작은 글씨 정확도↑)인지 중복인지 불명. → `lab/` 에서 동일 스크린샷 셋 (이미지만) vs (이미지+OCR) 분류 정확도 벤치 필요 (lab-experimenter).

## 5. 다른 활용 후보 숏컷

| 액션 | 가치 | 주의 |
|---|---|---|
| **집중 모드 가져오기** (Get Current Focus) | 추천 — 업무/개인 컨텍스트 → schedule vs memo·중요도 | 저위험 |
| 바코드/QR 감지 (Detect Barcodes) | 조건부 — 티켓·명함·상품 → knowledge | §3.5에서 QR은 민감 신호(2점)이기도 |
| 클립보드 가져오기 | 직전 복사 보강 | ⚠️ 비번·OTP 자주 담김 → 민감 게이트 필수 전제 |
| 위치 가져오기 | schedule 장소 보강 | ⚠️ 고민감·상시추적 인상 → 신중 |
| ~~캘린더/미리알림 직접 추가~~ | ✗ 비추 | 모찌가 분석 후 *제안*해야 함. 직접 넣으면 미션("모찌가 알아서 떠오르게") 위반 |

**원칙: 컨텍스트↑ = 민감 표면↑.** 민감 게이트(Level 0)를 먼저 깔고 그 위에서 컨텍스트를 늘린다. 게이트 없이 클립보드부터 빨면 PRIVACY §1.2("불안 없는 AI") 위반.

## 6. 공유표면 영향 / 비용 견적

| 항목 | 공유표면 | AI 편집 견적 |
|---|---|---|
| Level 0 되묻기 | 없음(숏컷 로직만) | iOS 0 (숏컷 작성) |
| OCR/URL → `text`/`url` 필드 | **없음** — `IngestSource`에 이미 존재(`IngestSource.swift:25-26`), 백탭 commit 이 안 채울 뿐 | iOS 내부 패스스루 ~30분 |
| `source_app` 컨텍스트 | **3개**(API 계약·DB·CoreDomain) | ~1.5h + 합의 리드타임 |
| Level 1 마스킹 payload | API·DB(§6.2 필드) | 별건, 재설계 후 |

→ **Level 0 + OCR/URL 보강이 재설계와 충돌 최소** (기존 필드 재사용 + 숏컷 로직). `source_app`·Level 1 은 공유표면이라 contract-first 합의 대상.

## 7. 추천 조립 (숏컷 파이프라인)

```
[Take Screenshot] → [Extract Text(OCR)]
   ├─ [Match Text: 주민번호|카드|여권|OTP] → If 감지 → "민감정보 있어요. 저장?" → 취소 시 종료   ← 보안 Level 0
   ├─ [Get Current App] → source_app                                                          ← 컨텍스트(공유표면)
   ├─ [Get Current Focus] → 업무/개인 태그                                                      ← 컨텍스트
   └─ [모찌 화면 캡쳐] (OCR→text, Safari URL→url; 기존 필드 재사용)
```

## 다음 할 일

1. (0원) 추가 실기기 검증 — `Get Current Focus`, 주요 앱(유튜브·카톡·인스타)에서 OCR 품질, Match Text 정규식 되묻기 동작.
2. (lab) OCR 추가가치 벤치 — (이미지만) vs (이미지+OCR) 4-Intent 분류 정확도. → §4 의문 해소.
3. (재설계 후) contract-first 킥오프에 올림 — `source_app` 필드 + Level 1 §6.2 필드 합의.
4. 채택 시 정합성 폭포 — `PRIVACY_SENSITIVE_CAPTURE.md` §3·§7.1 에 "숏컷 1차 게이트" 반영, harvest 후 이 파일 삭제.

## 막힌 것 / 사람 결정 필요

- `Get Current App` 의 18.2+ 게이트 vs 17.0 deployment target — optional 파라미터로 공존 가능하나, 단축어를 버전별(앱정보 有/無) 2링크 병행 배포할지 결정 필요.
- Level 1(마스킹 텍스트를 실제 분석에 사용)을 MVP 범위에 넣을지 — 공유표면 비용 큼.

## 참조

- 코드: `CaptureScreenshotIntent.swift:6,37` · `CommitBackTapCaptureIntent.swift:106-110` · `IngestSource.swift:22-29`
- 문서: `PRIVACY_SENSITIVE_CAPTURE.md` §2.2·§3.5·§4·§5·§6.2·§7.1(`:307`)·§8
- 외부: [Apple — Receive onscreen items](https://support.apple.com/guide/shortcuts/receive-onscreen-items-apd350ce757a/ios) · [Get On-Screen Content (Cassinelli)](https://matthewcassinelli.com/actions/get-on-screen-content/)
