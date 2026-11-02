# 모찌 (MOCHI)

<img src="mochi-ios/Targets/App/Resources/Assets.xcassets/LoginMochi.imageset/login-mochi.png" alt="모찌 캐릭터" width="150" align="right" />

**저장한 정보를 필요할 때 다시 꺼내 쓰도록**

모찌는 스크린샷, 링크, 메모를 모아 정리하고 검색하는 iOS 앱입니다.

여러 앱에 저장해 두고도 나중에 어디에 뒀는지 찾지 못하는 일을 줄이기 위해 만들었습니다. 내용을 직접 분류하는 수고를 줄이고, 저장한 정보를 일정이나 할 일로 활용할 수 있도록 돕습니다.

2026 SW중심대학 디지털 경진대회 SW부문 출품작 / 팀 **세얼간이**

<br clear="all" />

## 사용 흐름

```text
공유로 저장 → AI가 내용 정리 → 검색과 채팅으로 찾기 → 일정과 알림으로 활용
```

## 주요 기능

- **간편한 저장** — 스크린샷과 링크, 메모를 한곳에 모으기
- **AI 정리** — 내용을 요약하고 일정, 할 일, 지식, 메모로 분류
- **검색과 질문** — 자연어로 정보를 찾고, 저장한 기록을 근거로 답변 받기
- **일정과 알림** — 캘린더와 미리알림에 연결하고, 다시 볼 기록을 알림으로 확인

## 구성

| 디렉터리 | 역할 | 안내 |
| --- | --- | --- |
| [`mochi-ios/`](mochi-ios/) | iOS 클라이언트 — SwiftUI + TCA, Tuist | [README](mochi-ios/README.md) |
| [`mochi-backend/`](mochi-backend/) | API 서버 — FastAPI, Modular Monolith + Hexagonal | [README](mochi-backend/README.md) |

빌드와 실행, 테스트 방법은 각 프로젝트 README에 있습니다. API 계약은 `mochi-backend/openapi.json`에서 확인할 수 있습니다.
