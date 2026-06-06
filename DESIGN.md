---
level: 2
mode: reference
status: active
last_verified: 2026-05-23
confidence: 0.7
owners: [송준서, 이용찬, 박세현]
description: 모찌 iOS Design System & UX Guide. iOS 디자인 토큰·컴포넌트·UX 패턴이 흔들릴 때 또는 새 화면을 디자인할 때 읽어라. 토큰의 ⓪ 정본은 코드의 DesignSystem 모듈 — 이 문서는 의도·rationale·전체 그림을 담는다.
---

# DESIGN.md — 모찌 iOS Design System & UX Guide

> Version: 1.0  
> Product: 모찌  
> Platform: iOS  
> Last updated: 2026-05-23  
> Owner: Team 세얼간이 (송준서·이용찬·박세현)

---

## 0. 문서 목적

이 문서는 iOS 기반 AI 기록 관리 앱 **모찌**의 디자인 원칙, 화면 구조, 컴포넌트 규칙, 디자인 토큰, 접근성 기준, 개발 핸드오프 규칙을 정의한다.

모찌는 단순히 예쁜 앱이 아니라, 사용자가 저장한 스크린샷·링크·메모를 AI가 자동으로 분류하고 다시 활용할 수 있게 만드는 **AI 기록 관리 에이전트**이다. 따라서 디자인의 목표는 다음과 같다.

1. 사용자가 기록을 쉽게 맡길 수 있게 한다.
2. AI가 정리하고 있다는 신뢰감을 준다.
3. 일정·할 일·지식·기록이라는 네 가지 Intent를 명확하게 구분한다.
4. 귀엽고 말랑한 브랜드 감성을 유지하되, 생산성 앱으로서의 가독성과 안정감을 해치지 않는다.
5. iOS 사용자가 익숙한 네비게이션, 터치 영역, 접근성 원칙을 따른다.

---

## 1. 참고한 디자인 가이드

본 문서는 다음 기준을 반영한다.

- Apple Human Interface Guidelines  
  - iOS 앱은 플랫폼의 기본 패턴, 명확한 레이아웃, 접근성, 직관적인 네비게이션을 따라야 한다.
- Apple App Icon Guidelines  
  - 앱 아이콘은 앱의 목적과 성격을 한눈에 전달해야 하며, 작은 크기에서도 기억 가능해야 한다.
- Apple Layout / Navigation Guidance  
  - 탭바, 모달, 네비게이션 구조는 사용자가 앱 구조를 예측할 수 있도록 단순해야 한다.
- Design Token 기반 시스템  
  - 색상, 간격, 모서리, 타이포그래피, 그림자 값은 하드코딩하지 않고 토큰화한다.
- iOS 26 이후 Liquid Glass 계열 디자인 흐름  
  - 투명도, 블러, 유리 질감은 최신 iOS 시각 언어와 맞지만, 과하면 가독성과 접근성을 해칠 수 있으므로 모찌에서는 제한적으로 사용한다.

### 참고 링크

- Apple HIG: https://developer.apple.com/design/human-interface-guidelines
- Apple App Icons: https://developer.apple.com/design/human-interface-guidelines/app-icons
- Apple Layout: https://developer.apple.com/design/human-interface-guidelines/layout
- Material Design Tokens: https://m3.material.io/foundations/design-tokens
- Material Typography: https://m3.material.io/styles/typography/overview
- SAP Design Tokens: https://www.sap.com/design-system/fiori-design-android/v25-8/foundations/design-tokens

---

## 2. 브랜드 정의

### 2.1 브랜드 키워드

모찌의 브랜드 키워드는 다음과 같다.

| 키워드 | 의미 |
|---|---|
| 말랑함 | 사용자가 부담 없이 기록을 맡길 수 있는 친근함 |
| 귀여움 | 모찌 캐릭터를 통한 기억성 |
| 정돈됨 | 흩어진 기록을 깔끔하게 정리하는 생산성 |
| 신뢰감 | AI가 자동으로 처리하되, 사용자가 결과를 이해하고 수정할 수 있음 |
| 똑똑함 | Agent, Tool Use, RAG 기반으로 기록을 분석하고 재조합 |
| 따뜻함 | 차갑고 기술적인 AI 앱이 아닌 개인 비서 같은 감성 |

---

### 2.2 브랜드 문장

#### Primary Tagline

> 뭐든지 찍어보세요.  
> 모찌가 기억하고 정리해드릴게요.

#### Short Tagline

> 모찌에게 맡겨보세요.

#### Functional Tagline

> 스크린샷, 링크, 메모를 AI가 자동으로 정리해주는 기록 관리 앱

---

### 2.3 브랜드 톤

모찌의 말투는 다음과 같아야 한다.

- 친근하지만 과하게 유아적이지 않다.
- AI가 “결정했다”고 말하기보다 “제안한다”고 말한다.
- 사용자의 실수를 지적하지 않는다.
- 불확실한 AI 결과는 확신하지 않는다.
- 사용자가 원하면 언제든 수정할 수 있다는 느낌을 준다.

#### 좋은 문구

```text
마감일이 있는 과제처럼 보여요.
할 일로 저장해둘까요?
```

```text
이 링크는 AI Agent 관련 지식으로 분류했어요.
```

```text
아직 확인하지 않은 일정 후보가 있어요.
```

#### 피해야 할 문구

```text
이건 무조건 할 일입니다.
```

```text
정확히 분석 완료했습니다.
```

```text
사용자가 정리하지 않아 기록이 쌓였습니다.
```

---

## 3. 디자인 원칙

### 3.1 입력은 가볍게, 결과는 명확하게

모찌의 핵심 입력 경로는 백탭과 Share Sheet이다.  
사용자는 “정리”를 하기 위해 앱에 들어오는 것이 아니라, 기록을 “맡기기” 위해 들어온다.

따라서 입력 UI는 짧고 가벼워야 한다.

- 저장 전 입력값은 최소화한다.
- 힌트 입력은 선택 사항으로 둔다.
- 분류 결과는 저장 후 상세에서 확인 가능하게 한다.
- AI 처리 중이어도 사용자는 화면을 떠날 수 있어야 한다.

---

### 3.2 AI는 숨기지 말고, 과시하지도 않는다

모찌는 AI 앱이지만, AI 모델명이나 기술 용어를 과하게 노출하지 않는다.  
대신 사용자가 체감할 수 있는 형태로 보여준다.

| 내부 동작 | 사용자 표시 |
|---|---|
| OCR | 이미지 속 글자를 읽고 있어요 |
| WebFetch | 링크 내용을 확인하고 있어요 |
| Vector Search | 관련 기록을 찾고 있어요 |
| Intent Classification | 어떤 기록인지 분류하고 있어요 |
| Tool Use | 필요한 정보를 확인하고 있어요 |

---

### 3.3 귀여움은 보조, 정보가 주인공

모찌 캐릭터는 브랜드를 전달하지만, 화면의 모든 곳에 등장하면 정보 탐색을 방해할 수 있다.

캐릭터 사용 기준:

- 스플래시, 온보딩, Empty State, 백탭 모달에서는 적극 사용한다.
- 홈에서는 작게 사용한다.
- 리스트, 검색 결과, 캘린더에서는 정보 가독성을 우선한다.
- 질문 화면에서는 AI 응답 상태를 표현하는 아바타로 사용한다.

---

### 3.4 분류는 색상만으로 전달하지 않는다

Intent는 색상, 아이콘, 텍스트 라벨을 함께 사용한다.

예:

- 일정: 보라색 + 캘린더 아이콘 + “일정”
- 할 일: 주황색 + 체크 아이콘 + “할 일”
- 지식: 민트색 + 책 아이콘 + “지식”
- 기록: 파란색 + 문서 아이콘 + “기록”

색각 이상 사용자를 위해 색상만으로 상태를 구분하지 않는다.

---

### 3.5 Liquid Glass는 절제해서 사용한다

iOS 26 이후 Apple은 투명도와 유리 질감을 강조하는 Liquid Glass 디자인을 도입했다.  
그러나 투명도는 배경에 따라 가독성을 해칠 수 있으므로 모찌에서는 다음 규칙을 따른다.

사용 가능:

- 탭바 배경
- 상단 검색 바
- 백탭 모달 배경
- 온보딩 카드
- Floating sheet

사용 금지:

- 본문 텍스트 뒤
- 긴 리스트 카드 뒤
- 중요한 숫자나 날짜 뒤
- 접근성 대비가 낮아지는 영역

Glass 효과를 쓰는 경우:

- blur radius는 충분히 크게 둔다.
- 배경 위에 반투명 흰색 레이어를 추가한다.
- 텍스트 대비를 WCAG 기준에 맞춘다.
- Reduce Transparency 설정이 켜져 있으면 불투명 배경으로 대체한다.

---

## 4. 정보 구조

### 4.1 앱 전체 구조

```text
Splash
└─ Login
   └─ Onboarding
      └─ Main Tab
         ├─ Home
         ├─ Ask
         ├─ Mochis
         └─ Search

Global
├─ Back Tap Modal
├─ Share Extension
├─ Mochi Detail
├─ Notification
└─ Settings
```

---

### 4.2 탭바 구조

탭바는 총 4개 항목이다.

| 탭 | 아이콘 | 역할 |
|---|---|---|
| 홈 | house | 요약, 추천, 최근 모찌 |
| 질문 | bubble / sparkle bubble | AI 질의응답 |
| 모찌들 | calendar | 캘린더 기반 기록 탐색 |
| 검색 | magnifying glass | 전체 검색 |

탭바에는 텍스트를 노출하지 않는다.  
단, 접근성 label은 반드시 제공한다.

```swift
.accessibilityLabel("홈")
.accessibilityLabel("질문")
.accessibilityLabel("모찌들")
.accessibilityLabel("검색")
```

중앙 플로팅 버튼은 사용하지 않는다.

이유:

1. 백탭과 Share Sheet가 핵심 입력 경로이다.
2. 중앙 버튼의 의미가 불명확하다.
3. 사용자가 “+ 버튼을 눌러야만 저장 가능하다”고 오해할 수 있다.
4. 홈 화면의 집중도를 떨어뜨린다.

---

## 5. 디자인 토큰

디자인 토큰은 SwiftUI 코드에서 하드코딩을 줄이기 위해 사용한다.

토큰 레벨은 다음과 같이 나눈다.

1. Reference Token: 실제 색상, 크기 값
2. Semantic Token: UI 역할 기반 이름
3. Component Token: 특정 컴포넌트에 적용되는 값

---

## 5.1 Color Tokens

### 5.1.1 Reference Colors

```swift
enum MochiColor {
    static let purple50 = Color(hex: "#F4EFFF")
    static let purple100 = Color(hex: "#EDE7FF")
    static let purple200 = Color(hex: "#D8CBFF")
    static let purple400 = Color(hex: "#A084FF")
    static let purple500 = Color(hex: "#8B6CFF")
    static let purple600 = Color(hex: "#6F50E8")

    static let cream50 = Color(hex: "#FFFDF8")
    static let cream100 = Color(hex: "#FFF9F1")
    static let cream200 = Color(hex: "#F7ECDD")

    static let mint50 = Color(hex: "#EFFCF5")
    static let mint100 = Color(hex: "#DFF8EC")
    static let mint400 = Color(hex: "#4CCB8F")

    static let peach50 = Color(hex: "#FFF3EC")
    static let peach100 = Color(hex: "#FFE8DA")
    static let peach400 = Color(hex: "#FF9B73")

    static let sky50 = Color(hex: "#EFF7FF")
    static let sky100 = Color(hex: "#DDEEFF")
    static let sky400 = Color(hex: "#6BA9FF")

    static let ink900 = Color(hex: "#17172A")
    static let ink700 = Color(hex: "#373750")
    static let ink500 = Color(hex: "#7A7A90")
    static let ink300 = Color(hex: "#B8B8C8")
    static let ink100 = Color(hex: "#ECECF4")

    static let white = Color(hex: "#FFFFFF")
    static let black = Color(hex: "#000000")
}
```

---

### 5.1.2 Semantic Colors

| Token | Light | Dark | 사용처 |
|---|---|---|---|
| `color.background.primary` | `cream100` | `ink900` | 앱 전체 배경 |
| `color.background.surface` | `white` | `ink700` | 카드, 시트 |
| `color.background.elevated` | `white` | `ink700` | 모달, 팝오버 |
| `color.text.primary` | `ink900` | `white` | 제목, 본문 |
| `color.text.secondary` | `ink500` | `ink300` | 보조 텍스트 |
| `color.text.disabled` | `ink300` | `ink500` | 비활성 |
| `color.brand.primary` | `purple500` | `purple400` | CTA, 선택 상태 |
| `color.brand.secondary` | `purple100` | `purple600` | 브랜드 배경 |
| `color.border.default` | `ink100` | `ink700` | 카드 경계 |
| `color.shadow.default` | `purple200` | `black` | 부드러운 그림자 |

---

### 5.1.3 Intent Colors

| Intent | Background | Foreground | Icon |
|---|---|---|---|
| 일정 | `purple100` | `purple600` | calendar |
| 할 일 | `peach100` | `peach400` | checkmark.circle |
| 지식 | `mint100` | `mint400` | book |
| 기록 | `sky100` | `sky400` | doc.text |
| 미확인 | `cream200` | `ink700` | questionmark.circle |

---

## 5.2 Typography Tokens

모찌는 iOS 기본 San Francisco 계열을 사용한다.  
한국어 본문은 시스템 폰트 사용을 기본으로 하며, 별도 커스텀 폰트는 MVP에서 사용하지 않는다.

| Token | iOS Text Style | Size | Weight | 용도 |
|---|---|---:|---|---|
| `type.largeTitle` | `.largeTitle` | 34 | Bold | 스플래시, 온보딩 핵심 문구 |
| `type.title1` | `.title` | 28 | Bold | 페이지 제목 |
| `type.title2` | `.title2` | 22 | Semibold | 섹션 제목 |
| `type.title3` | `.title3` | 20 | Semibold | 카드 제목 |
| `type.body` | `.body` | 17 | Regular | 본문 |
| `type.callout` | `.callout` | 16 | Regular | 보조 설명 |
| `type.subheadline` | `.subheadline` | 15 | Regular | 리스트 메타 정보 |
| `type.caption` | `.caption` | 12 | Medium | 태그, 시간, 상태 |

SwiftUI에서는 가능한 한 Dynamic Type을 지원하는 시스템 스타일을 우선 사용한다.

```swift
Text("오늘도 모찌가 정리해뒀어요")
    .font(.title2.weight(.bold))
```

---

## 5.3 Spacing Tokens

8pt grid를 기본으로 한다.

| Token | Value | 용도 |
|---|---:|---|
| `space.0` | 0 | 없음 |
| `space.1` | 4 | 미세 간격 |
| `space.2` | 8 | 작은 내부 여백 |
| `space.3` | 12 | 태그, 작은 카드 |
| `space.4` | 16 | 기본 카드 패딩 |
| `space.5` | 20 | 섹션 간격 |
| `space.6` | 24 | 큰 섹션 간격 |
| `space.8` | 32 | 화면 블록 간격 |
| `space.10` | 40 | 온보딩 요소 간격 |

---

## 5.4 Radius Tokens

| Token | Value | 용도 |
|---|---:|---|
| `radius.xs` | 8 | 작은 태그 |
| `radius.sm` | 12 | 작은 버튼 |
| `radius.md` | 16 | 리스트 카드 |
| `radius.lg` | 20 | 홈 카드 |
| `radius.xl` | 24 | 모달, 큰 카드 |
| `radius.full` | 999 | pill, avatar |

---

## 5.5 Shadow Tokens

모찌의 그림자는 강하지 않고, 떠 있는 느낌만 준다.

| Token | 값 | 용도 |
|---|---|---|
| `shadow.card` | y: 6, blur: 18, opacity: 0.08 | 일반 카드 |
| `shadow.elevated` | y: 10, blur: 30, opacity: 0.12 | 모달, 중요 카드 |
| `shadow.softPurple` | y: 8, blur: 24, opacity: 0.14, color: purple | 브랜드 카드 |

---

## 5.6 Motion Tokens

| Token | Value | 용도 |
|---|---:|---|
| `motion.fast` | 0.18s | 버튼 반응 |
| `motion.normal` | 0.28s | 카드 전환 |
| `motion.slow` | 0.45s | 온보딩 fade |
| `motion.spring` | spring(response: 0.35, dampingFraction: 0.82) | 모달 등장 |

Reduce Motion이 켜져 있으면 scale, bounce, blur transition을 줄이고 opacity transition으로 대체한다.

---

# 6. 공통 컴포넌트

## 6.1 MochiCard

모든 리스트/요약 카드의 기본 컴포넌트.

### Anatomy

```text
┌─────────────────────────────┐
│ [thumbnail/icon] Title       │
│                 [Intent Tag] │
│ Source · Time                │
└─────────────────────────────┘
```

### 규칙

- 최소 높이: 72pt
- 좌우 패딩: 16pt
- radius: 20pt
- title은 최대 1~2줄
- Intent tag는 항상 표시
- 처리 중 상태는 skeleton 또는 “정리 중” 표시

---

## 6.2 IntentCard

홈의 4개 요약 카드.

### Anatomy

```text
┌──────────┐
│  icon    │
│ 일정      │
│  8       │
└──────────┘
```

### 규칙

- 한 줄에 4개 배치
- 카드 폭은 동일
- 숫자는 크고 명확하게
- 누르면 해당 Intent 필터 목록으로 이동
- 개수가 0이면 Empty State 문구 제공

---

## 6.3 SuggestionCard

홈의 “모찌가 중요해 보여요” 영역에 사용한다.

### 종류

1. 일정 임박
2. 마감 임박
3. 미확인 분류
4. 관련 기록 묶음
5. 자주 등장한 주제

### 문구 예시

```text
내일 3시 팀 회의가 있어요.
캘린더에 추가할까요?
```

```text
마감일이 있는 과제 2개를 발견했어요.
확인해볼까요?
```

```text
AI Agent 관련 자료가 5개 모였어요.
요약해드릴까요?
```

---

## 6.4 SearchBar

### 규칙

- 홈에서는 질문 유도형 placeholder
- 검색 탭에서는 검색 명령형 placeholder
- 질문 탭에서는 대화 입력창과 구분

Placeholder:

| 위치 | 문구 |
|---|---|
| 홈 | 무엇을 찾고 있나요? |
| 검색 | 제목, 내용, 링크, 기억나는 말로 검색 |
| 질문 | 모찌에게 물어보세요 |

---

## 6.5 IntentTag

### Anatomy

```text
[icon] 지식
```

### 규칙

- 색상 + 아이콘 + 텍스트를 함께 사용
- 작은 카드에서는 아이콘 생략 가능하지만 텍스트는 유지
- VoiceOver에서는 “지식으로 분류됨”처럼 읽히게 한다

---

## 6.6 ToolStatusBubble

질문 화면에서 AI 작업 상태를 보여준다.

### 예시

```text
모찌가 관련 기록을 찾고 있어요...
```

```text
링크 내용을 확인하고 있어요...
```

```text
답변을 정리하고 있어요...
```

### 규칙

- 내부 tool name을 그대로 보여주지 않는다.
- 사용자가 이해 가능한 문장으로 변환한다.
- 완료된 단계는 체크 아이콘을 표시할 수 있다.

---

## 6.7 EmptyState

### 사용 위치

- 최근 모찌 없음
- 검색 결과 없음
- 캘린더 선택 날짜 기록 없음
- 할 일 없음
- 질문 기록 없음

### 기본 구조

```text
[모찌 캐릭터]
아직 저장한 모찌가 없어요.
스크린샷이나 링크를 모찌에게 보내보세요.
```

### 문구 예시

검색 결과 없음:

```text
찾는 모찌가 없어요.
다른 표현으로 검색해볼까요?
```

할 일 없음:

```text
지금 해야 할 일은 없어 보여요.
필요한 게 생기면 모찌가 알려드릴게요.
```

---

# 7. 페이지별 디자인 스펙

## 7.1 SplashViewController / SplashView

### 목적

브랜드 첫인상 제공.

### 구성

- 크림/라벤더 그라데이션 배경
- 중앙 모찌 캐릭터
- 앱명 “모찌”
- 짧은 태그라인

### 문구

```text
모찌

뭐든지 찍어보세요.
모찌가 기억하고 정리해드릴게요.
```

### Motion

- 모찌 캐릭터 fade in + scale 0.96 → 1.0
- 로고 텍스트 0.2초 지연 등장
- 1.2초 후 로그인 또는 홈으로 이동

---

## 7.2 LoginViewController / LoginView

### 목적

OAuth 로그인.

### 구성

- 상단: 환영 문구
- 중앙: 모찌 캐릭터
- 하단:
  - Apple로 계속하기
  - Google로 계속하기
  - 약관/개인정보 안내

### 문구

```text
모찌에 오신 것을 환영해요 👋
```

### 버튼 규칙

- Apple 로그인 버튼은 Apple 가이드라인을 따른다.
- Google 로그인 버튼은 Google 브랜드 가이드를 따른다.
- 두 버튼은 같은 높이로 유지한다.

---

## 7.3 OnboardingViewController / OnboardingView

### 목적

첫 사용자에게 모찌의 핵심 사용법을 설명한다.

### 구조

- Full screen
- 모찌 캐릭터
- 한 단계당 1개 메시지
- Fade In / Fade Out
- 하단 CTA
- 5단계 progress dot

### 단계

#### Step 1

```text
안녕하세요!
만나서 반가워요.
제 이름은 모찌예요 😊
```

CTA: `다음`

#### Step 2

```text
앞으로 아이폰 뒷면을
빠르게 두 번 탭하면
제가 나타날게요!
```

CTA: `단축어 등록하기`

#### Step 3

```text
탭이 아니어도 괜찮아요.
SNS나 유튜브에서 공유 버튼으로도
모찌에게 기록을 보낼 수 있어요.
```

CTA: `다음`

#### Step 4

```text
뭐든지 캡처만 해보세요.
제가 일정, 할 일, 지식, 기록으로
자동 정리해드릴게요.
```

CTA: `다음`

#### Step 5

```text
이제 모찌에게 맡겨보세요!
```

CTA: `시작하기`

---

## 7.4 HomeViewController / HomeView

### 목적

오늘 사용자가 봐야 할 기록과 AI 제안을 보여준다.

### 레이아웃

```text
[Top Bar]
안녕하세요 👋
오늘도 모찌가 정리해뒀어요        [알림] [설정]

[Search/Question Bar]
무엇을 찾고 있나요?

[Intent Cards]
일정 / 할 일 / 지식 / 기록

[Important Suggestions]
모찌가 중요해 보여요

[Weekly Summary]
이번 주 모찌가 저장한 기록

[Recent Mochis]
최근 추가한 모찌

[Tab Bar]
```

### 상단 버튼

- 알림: 미확인 제안, 일정/할 일 알림
- 설정: 계정, 단축어, 개인정보, 앱 설정

### 중요 제안 섹션

제목:

```text
모찌가 중요해 보여요 ✨
```

카드 예시:

```text
내일 3시 팀 회의가 있어요
캘린더에 추가할까요?
```

```text
마감일이 있는 과제 2개를 발견했어요
가장 빠른 마감은 5월 25일이에요
```

```text
아직 확인하지 않은 일정 후보가 있어요
2건의 일정 후보 확인하기
```

### 이번 주 요약 섹션

제목:

```text
이번 주 모찌가 저장한 기록
```

예시:

```text
이번 주에는 총 23개의 모찌를 저장했어요.
지식 11 · 할 일 5 · 기록 6 · 일정 1
```

표시 요소:

- 총 저장 수
- Intent별 개수
- 대표 키워드 3개
- 가장 많이 저장한 출처

### 최근 추가한 모찌

카드 구성:

- 썸네일
- 제목
- 출처
- Intent tag
- 저장 시간
- bookmark icon

---

## 7.5 AskViewController / AskView

### 목적

사용자가 자연어로 자신의 기록을 질문한다.

### 구조

```text
[Navigation Title] 질문

[Chat History]
User Bubble
AI Bubble
Tool Status Bubble
Source Mochi List

[Input Bar]
모찌에게 물어보세요
```

### 추천 질문

초기 Empty State에서 다음 칩을 보여준다.

- 지난주 저장한 자료 정리해줘
- 이번 달 할 일 알려줘
- AI Agent 관련 모찌 찾아줘
- 발표 준비에 필요한 기록 모아줘
- 마감일 있는 것만 보여줘

### AI 답변 구성

AI 답변은 다음 형식을 따른다.

```text
답변 요약

근거가 된 모찌
- 모찌 A
- 모찌 B
- 모찌 C

추가로 할 수 있는 것
- 할 일로 만들기
- 요약 저장하기
- 캘린더에 추가하기
```

### Tool Status 표시

```text
관련 기록을 찾고 있어요...
```

```text
저장된 모찌 5개를 확인했어요.
```

```text
답변을 정리하고 있어요.
```

---

## 7.6 MochisCalendarViewController / MochisCalendarView

### 목적

날짜 기반으로 기록을 탐색한다.

### 구조

```text
[Month Header]
2026년 5월

[Calendar Grid]
날짜별 dot / icon / count

[Selected Day Summary]
5월 20일 화요일

[Stored Mochis]
해당 날짜 저장 기록

[Todo List]
해야 할 일
```

### 캘린더 셀 규칙

- 기본 날짜 숫자
- 기록이 있으면 작은 dot 표시
- Intent가 강한 날은 대표 아이콘 표시
- 여러 개면 count 표시

예:

```text
20
● ● 3
```

### 날짜 선택 시 요약

```text
5월 20일에는 총 7개의 모찌를 저장했어요.
발표 관련 기록이 많고, 마감이 있는 할 일 2개가 있어요.
```

### 할 일 리스트

- 미완료 우선
- 마감 임박 우선
- 완료한 항목은 접을 수 있음

---

## 7.7 SearchViewController / SearchView

### 목적

모든 모찌를 검색한다.

### 구조

```text
[Search Bar]
AI Agent

[Filter Chips]
전체 / 일정 / 할 일 / 지식 / 기록 / 이미지 / 링크 / 미확인

[Result Count]
검색 결과 12개

[Result List]
MochiCard...
```

### 검색 결과 없음

```text
찾는 모찌가 없어요.
다른 단어나 날짜로 검색해볼까요?
```

### 검색 결과 카드

- 썸네일
- 제목
- 검색어 하이라이트
- 요약
- Intent
- 출처
- 날짜

---

## 7.8 MochiDetailViewController / MochiDetailView

### 목적

단일 모찌의 모찌 해석(요약·의도)·원본·액션을 확인하고, 분류가 틀렸으면 가볍게 교정한다.

### 구조 (as-built, push navigation)

정보 위계는 "모찌의 결론 먼저, 원본은 아래". 회수의 능동 주체가 모찌이므로 원본을 맨 위에 두지 않는다.

```text
[Hero]
대표 Intent 색칩 + 제목(payload.title or 요약) + 출처 · 시각

[헷갈림 배너]   ← needsReview 일 때만

[지금 할 수 있어요]   ← actionCandidates
캘린더에 추가 / 링크 열기

[모찌가 이렇게 봤어요]   ← multi-intent (한 기록에 의도 여럿)
의도 카드: Intent 칩 + payload(날짜·마감·인물·주제) + 보관
└ "분류가 안 맞나요?" → 인라인 hint 교정

[모찌가 정리한 내용]
요약 + 원본(이미지 / 링크 / 텍스트 / 내 메모)

[더 자세히]   ← 접힘
추출 정보 · 태그 · 모찌의 근거 · 처리 상태
```

상태 분기: 분석 중(`정리 중` + 원본 먼저) · 실패(`정리하지 못했어요`) · 로딩.

### AI 분류 교정 (hint 재추론)

닫힌 4-Intent 버튼 대신 **짧은 자유 텍스트 hint → 모찌 재추론**. 사용자가 직접 분류(노동)하지 않고 단서만 주면 모찌가 다시 본다(미션: 회수 주체=모찌).

- 위치: 각 의도 카드 안 인라인("분류가 안 맞나요?" → 펼침). multi-intent 에서 어느 의도를 고치는지 모호하지 않도록 **instance 단위 스코프**.
- 톤: "모찌가 '지식'으로 봤어요. 아니라면 짧게 알려주면 다시 살펴볼게요." (제안형, 사용자 탓 없음)
- 이미 sync 된 의도(schedule↔캘린더 / todo↔미리알림)는 hint 대신 "직접 정리해야 해요" 안내 — 재추론이 외부 부수효과를 자동 정리하지 못함.
- **현재 비작동 프로토타입**: 입력은 받되 "다시 맡기기" disabled. 백엔드 재추론 라우트(`POST /mochi_items/{id}/reanalyze` 류) 미구현.

---

## 7.9 BackTapModalViewController / BackTapModalView

### 목적

백탭으로 빠르게 메모 또는 스크린샷을 저장한다.

### 구조

```text
[Close]

[모찌 캐릭터]

무엇을 기록할까요?
모찌가 정리해드릴게요!

[메모] [스크린샷]
```

### 버튼

#### 메모

```text
아이디어, 할 일, 메모를
간단히 적어보세요
```

#### 스크린샷

```text
화면을 캡처하면
AI가 정리해드려요
```

### 메모 입력 상태

```text
까먹기 전에 모찌에게 알려주세요
```

### 스크린샷 힌트 입력

```text
왜 캡처했는지 힌트를 적어도 좋아요
```

---

## 7.10 ShareExtensionViewController

### 목적

다른 앱에서 이미지, 텍스트, 링크를 모찌로 전달한다.

### 구조

```text
[모찌 아이콘]
모찌에 저장할까요?

[Content Preview]
URL / Image / Text Preview

[Optional Hint]
왜 저장하는지 힌트를 적어도 좋아요

[저장하고 정리하기]
```

### 처리 상태

```text
모찌가 정리하고 있어요...
```

저장 성공:

```text
모찌에 맡겨뒀어요.
정리가 끝나면 홈에서 확인할 수 있어요.
```

Share Extension에서는 긴 AI 분석을 기다리게 하지 않는다.  
저장은 빠르게 완료하고, AI 분석은 서버에서 비동기로 처리한다.

---

# 8. 상태 디자인

## 8.1 Processing

AI 분석 중인 모찌.

표시:

```text
정리 중
```

UI:

- shimmer skeleton
- 작은 spinner
- 원본 미리보기는 먼저 표시
- Intent는 “분류 중”으로 표시

---

## 8.2 Needs Review

AI가 확신하지 못한 항목.

표시:

```text
확인이 필요해요
```

예:

```text
마감일이 있는 할 일처럼 보여요.
할 일로 저장할까요?
```

---

## 8.3 Failed

분석 실패.

표시:

```text
정리하지 못했어요
```

액션:

- 다시 시도
- 직접 분류
- 삭제

---

## 8.4 Empty

기록 없음.

표시:

```text
아직 저장한 모찌가 없어요.
스크린샷이나 링크를 모찌에게 보내보세요.
```

---

# 9. 아이콘 시스템

## 9.1 앱 아이콘

앱 아이콘은 다음 조건을 만족해야 한다.

- 모찌 캐릭터가 중심
- 작은 크기에서도 알아볼 수 있음
- 복잡한 문서/링크/이미지 요소는 최소화
- AI 느낌은 반짝이 하나로 표현
- 텍스트 없음
- 음식 앱처럼 보이지 않게 “기록/정리” 요소를 은근히 포함

추천 컨셉:

> 둥근 흰색 모찌 캐릭터 + 작은 공유 카드 + 반짝이

---

## 9.2 기능 아이콘

가능한 SF Symbols를 우선 사용한다.

| 기능 | SF Symbol |
|---|---|
| 홈 | `house.fill` |
| 질문 | `bubble.left.and.sparkles` 또는 `message.fill` |
| 모찌들 | `calendar` |
| 검색 | `magnifyingglass` |
| 알림 | `bell` |
| 설정 | `gearshape` |
| 일정 | `calendar.badge.clock` |
| 할 일 | `checkmark.circle` |
| 지식 | `book.closed` |
| 기록 | `doc.text` |
| 공유 | `square.and.arrow.up` |
| 링크 | `link` |
| 이미지 | `photo` |

---

# 10. 접근성

## 10.1 터치 영역

모든 주요 터치 영역은 최소 44pt 이상이어야 한다.

대상:

- 탭바 아이콘
- 카드
- CTA 버튼
- 필터 칩
- 닫기 버튼
- 체크박스

---

## 10.2 VoiceOver

아이콘만 있는 탭바에는 반드시 label을 제공한다.

```swift
Image(systemName: "house.fill")
    .accessibilityLabel("홈")
```

Intent tag:

```swift
.accessibilityLabel("지식으로 분류됨")
```

Mochi card:

```swift
.accessibilityLabel("LangChain Agent 구조 설명, 지식, 유튜브, 1시간 전 저장됨")
```

---

## 10.3 Dynamic Type

본문 텍스트는 Dynamic Type을 지원한다.

- 리스트 카드 높이는 텍스트 크기에 따라 늘어날 수 있어야 한다.
- 고정 높이 카드에서 텍스트가 잘리지 않게 한다.
- 홈의 4개 IntentCard 숫자는 최소한의 대응을 하되, 너무 큰 텍스트에서는 2x2 배치로 전환할 수 있다.

---

## 10.4 색상 대비

- 본문 텍스트는 배경 대비 충분히 높게 유지한다.
- Glass 효과 뒤에는 반드시 불투명도 레이어를 둔다.
- 밝은 파스텔 배경 위에 연한 회색 텍스트를 사용하지 않는다.
- 중요한 날짜, 숫자, CTA에는 primary text 색상을 사용한다.

---

## 10.5 Reduce Motion / Transparency

시스템 설정을 존중한다.

- Reduce Motion: scale, bounce, parallax 제거
- Reduce Transparency: blur/glass 배경을 solid surface로 대체
- Increase Contrast: border와 text contrast 강화

---

# 11. UX Writing

## 11.1 기본 원칙

- 사용자를 탓하지 않는다.
- AI가 확실하지 않은 경우 “~처럼 보여요”를 사용한다.
- 행동을 요구할 때는 이유를 함께 제공한다.
- 저장 완료 후에는 안심시키는 문구를 사용한다.

---

## 11.2 CTA 문구

| 상황 | CTA |
|---|---|
| 온보딩 시작 | 시작하기 |
| 단축어 등록 | 단축어 등록하기 |
| 저장 | 저장하고 정리하기 |
| 할 일 후보 | 할 일로 추가 |
| 일정 후보 | 캘린더에 추가 |
| 다시 시도 | 다시 정리하기 |
| 질문 | 물어보기 |
| 검색 | 검색하기 |

---

## 11.3 상태 문구

| 상태 | 문구 |
|---|---|
| 저장 완료 | 모찌에 맡겨뒀어요 |
| 분석 중 | 모찌가 정리하고 있어요 |
| 분류 완료 | 지식으로 분류했어요 |
| 확인 필요 | 확인이 필요한 기록이 있어요 |
| 실패 | 이번에는 정리하지 못했어요 |
| 빈 상태 | 아직 저장한 모찌가 없어요 |

---

# 12. 개발 핸드오프 규칙

## 12.1 네이밍

SwiftUI View 기준:

```text
SplashView
LoginView
OnboardingView
HomeView
AskView
MochisCalendarView
SearchView
MochiDetailView
BackTapModalView
ShareExtensionView
```

UIKit을 사용할 경우:

```text
SplashViewController
LoginViewController
OnboardingViewController
HomeViewController
AskViewController
MochisCalendarViewController
SearchViewController
MochiDetailViewController
BackTapModalViewController
ShareExtensionViewController
```

---

## 12.2 디자인 토큰 파일 구조

```text
DesignSystem/
├─ Colors.swift
├─ Typography.swift
├─ Spacing.swift
├─ Radius.swift
├─ Shadow.swift
├─ Motion.swift
├─ Components/
│  ├─ MochiCard.swift
│  ├─ IntentCard.swift
│  ├─ IntentTag.swift
│  ├─ SearchBar.swift
│  ├─ SuggestionCard.swift
│  └─ EmptyState.swift
└─ Assets/
   ├─ MochiMascot
   ├─ AppIcon
   └─ Illustrations
```

---

## 12.3 컴포넌트 우선 구현 순서

1. Color / Typography / Spacing Token
2. TabBar
3. IntentTag
4. MochiCard
5. IntentCard
6. SearchBar
7. SuggestionCard
8. EmptyState
9. BackTapModal
10. ToolStatusBubble

---

# 13. 화면 우선순위

## MVP 필수 화면

| 화면 | 우선순위 |
|---|---|
| Splash | P0 |
| Login | P0 |
| Onboarding | P0 |
| Home | P0 |
| BackTapModal | P0 |
| ShareExtension | P0 |
| MochiDetail | P0 |
| Ask | P1 |
| MochisCalendar | P1 |
| Search | P1 |
| Settings | P1 |
| Notifications | P2 |

---

# 14. 디자인 QA 체크리스트

## 14.1 공통

- [ ] 모든 주요 버튼의 터치 영역이 44pt 이상인가?
- [ ] Dynamic Type에서 텍스트가 잘리지 않는가?
- [ ] Intent가 색상 외에도 텍스트/아이콘으로 구분되는가?
- [ ] Empty State가 존재하는가?
- [ ] Loading / Error / Success 상태가 존재하는가?
- [ ] VoiceOver label이 제공되는가?
- [ ] Light/Dark Mode에서 대비가 충분한가?
- [ ] Glass 효과가 가독성을 해치지 않는가?

---

## 14.2 홈

- [ ] 알림과 설정 버튼이 상단에 있는가?
- [ ] 4 Intent 카드가 한눈에 보이는가?
- [ ] 중요 제안이 최근 모찌보다 먼저 노출되는가?
- [ ] 이번 주 저장 요약이 표시되는가?
- [ ] 최근 추가한 모찌가 표시되는가?
- [ ] 중앙 플로팅 버튼이 제거되었는가?

---

## 14.3 질문

- [ ] AI 응답의 근거 모찌가 표시되는가?
- [ ] Tool 사용 상태가 사용자 친화적으로 표시되는가?
- [ ] 추천 질문이 제공되는가?
- [ ] 답변 중 로딩 상태가 명확한가?

---

## 14.4 모찌들

- [ ] 월간 캘린더에서 날짜별 기록 여부가 보이는가?
- [ ] 날짜 선택 시 해당 날짜 요약이 보이는가?
- [ ] 캘린더 밑에 할 일 리스트가 있는가?
- [ ] Intent별 구분이 가능한가?

---

## 14.5 검색

- [ ] Intent 필터가 있는가?
- [ ] 이미지/링크/텍스트 필터가 있는가?
- [ ] 검색 결과 없음 상태가 있는가?
- [ ] 검색 결과 카드에서 요약과 출처가 보이는가?

---

# 15. 디자인 변경 관리

디자인 변경 시 다음 절차를 따른다.

1. 변경 이유 작성
2. 영향 화면 확인
3. 디자인 토큰 변경 여부 확인
4. 컴포넌트 재사용 가능 여부 확인
5. 접근성 영향 확인
6. 개발 반영 난이도 확인
7. `DESIGN.md` 업데이트

변경 기록은 아래에 남긴다.

---

# 16. Changelog

## v1.0 — 2026-05-23

- 모찌 iOS 디자인 시스템 초안 작성
- 4개 탭 구조 정의
- 중앙 플로팅 버튼 제거
- 홈 개선사항 반영
  - 알림
  - 이번 주 저장 요약
  - 중요 제안
- 온보딩 튜토리얼 정의
- Back Tap Modal 정의
- Share Extension 디자인 정의
- 디자인 토큰 정의
- 접근성 기준 추가
