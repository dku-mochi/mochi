<div align="center">

<img src="mochi-ios/Targets/App/Resources/Assets.xcassets/LoginMochi.imageset/login-mochi.png" alt="모찌 캐릭터" width="140" />

# 모찌 · MOCHI

**저장한 정보를, 필요할 때 다시 꺼내 쓰도록.**

스크린샷·링크·메모의 AI 정리부터 검색·질문, 일정·알림까지<br />
흩어진 기록을 다시 활용하기 위한 iOS 기록 관리 서비스

**2026 SW중심대학 디지털 경진대회 SW부문 최우수상 수상작**

단국대학교 캡스톤 프로젝트 · 팀 **세얼간이**

</div>

## 바로가기

| 구분 | 내용 |
| --- | --- |
| 서비스 | [소개](#서비스-소개) · [주요 기능](#주요-기능) · [시연](#시연) |
| 설계·기술 | [시스템 아키텍처](#시스템-아키텍처) · [ERD](#erd) · [기술 스택](#기술-스택) |
| 프로젝트 | [산출물](#프로젝트-산출물) · [실행 방법](#실행-방법) · [팀 소개](#팀-소개) |

## 서비스 소개

여러 앱에 흩어진 스크린샷·링크·메모를 한곳에 모아, **저장부터 정리·탐색·활용까지 연결하는 개인 기록 관리 서비스**

| 문제 | 해결 방향 |
| --- | --- |
| 여러 앱에 분산된 기록 | 공유 시트·앱 내 입력을 통한 통합 저장 |
| 직접 분류하고 정리하는 번거로움 | AI 기반 요약·분류·핵심 정보 추출 |
| 저장 위치와 제목을 잊은 정보 | 자연어 검색·저장 기록 기반 질문 |
| 놓치기 쉬운 일정과 마감 | 캘린더·미리알림 연동 및 회수 알림 |

## 주요 기능

**저장 → AI 정리 → 검색·질문 → 일정·알림 활용**

| 기능 | 주요 내용 |
| --- | --- |
| 간편한 저장 | 공유 시트로 스크린샷·링크 수집, 앱 내 메모 입력 |
| AI 정리 | 멀티모달 분석을 통한 요약·분류·정보 추출, 불확실한 분류의 사용자 확인 |
| 검색·질문 | 키워드·의미 검색 결합, 근거 기록을 함께 제시하는 대화 |
| 일정·할 일 | 기기 캘린더·미리알림 연동 및 완료 상태 관리 |
| 능동 회수 | 다시 볼 기록을 피드와 푸시 알림으로 제공 |
| 민감정보 보호 | 업로드 전 이미지 내 민감정보 감지·가림 |

### 기록 분류

| 일정 | 할 일 | 지식 | 메모 |
| --- | --- | --- | --- |
| 행사·약속·예약 | 신청·제출·마감 | 학습·참고 자료 | 생각·개인 기록 |
| 캘린더 연동 | 미리알림·완료 관리 | 검색·질문의 근거 | 보관·조회 |

하나의 기록에 여러 분류 연결 가능. 백탭 입력은 사용자 단축어의 스크린샷·공유 시트 경로 이용.

## 시연

| 자료 | 상태 |
| --- | --- |
| 서비스 시연 영상 | 준비 중 |
| 앱 설치·체험 안내 | 준비 중 |
| 주요 화면 | 준비 중 |

**시연 구성안**: 행사 안내 캡처 저장 → AI 요약·일정 확인 → 캘린더 연동 → 자연어 질문·근거 기록 확인 → 회수 피드 확인

## 시스템 아키텍처

저장소 코드 기준의 논리 구성도. 운영 배포 구성 문서 별도 준비 중.

```mermaid
flowchart TB
    App["iOS 앱 · Share Extension<br/>SwiftUI · TCA · Realm"]
    API["FastAPI 백엔드<br/>API · 분석 · 검색 · 대화 · 알림"]
    DB[("PostgreSQL · pgvector")]
    AI["Vertex AI · Gemini<br/>멀티모달 분석 · 대화"]
    Search["Voyage AI<br/>임베딩 · 리랭킹"]
    Storage["Google Cloud Storage<br/>이미지 저장"]
    Push["APNs<br/>푸시 알림"]
    Calendar["기기 캘린더 · 미리알림"]

    App <-->|REST · SSE| API
    App -->|EventKit| Calendar
    App -->|Signed URL 업로드| Storage
    API <--> DB
    API --> AI
    API --> Search
    AI -->|이미지 읽기| Storage
    API --> Push
    Push --> App
```

| 구성 | 역할 |
| --- | --- |
| iOS | 화면·상태 관리, 앱·공유 확장의 로컬 데이터 공유, 기기 기능 연동 |
| 백엔드 | 기능별 모듈 분리, 비동기 분석·알림 워커, 검색·대화 처리 |
| 데이터·AI | 기록·대화 저장, 이미지 분석, 키워드·벡터 검색과 리랭킹 |

## ERD

기록·분류·대화·알림 중심의 주요 관계 요약. `논리 참조`는 DB 외래 키 없이 연결되는 관계.

```mermaid
erDiagram
    users ||..o{ mochi_items : "소유 · 논리 참조"
    users ||..o{ conversations : "소유 · 논리 참조"
    mochi_items ||--o{ mochi_item_image_refs : "이미지"
    mochi_items ||--o{ intent_instances : "분류"
    mochi_items ||--o{ embeddings : "검색"
    intent_instances ||--o{ notification_plan : "회수 계획"
    notification_plan o|--o{ notification_outbox : "발송 · 반응"
    conversations ||--o{ messages : "메시지"
    messages ||--o{ message_citations : "답변 근거"
    mochi_items ||..o{ message_citations : "기록 · 논리 참조"
```

전체 테이블·컬럼 정의: [DB 마이그레이션](mochi-backend/alembic/versions/)

## 기술 스택

### iOS

| 구분 | 기술 |
| --- | --- |
| UI·상태 관리 | Swift, SwiftUI, TCA |
| 프로젝트·로컬 저장 | Tuist, Swift Package Manager, Realm, App Group |
| 기기 연동 | Share Extension, EventKit, Vision, Core Image |
| 지도·이미지 | Naver Maps SDK, Kingfisher |

### 백엔드·AI·데이터

| 구분 | 기술 |
| --- | --- |
| API | Python 3.12+, FastAPI, Pydantic |
| 데이터베이스 | PostgreSQL 16, pgvector, SQLAlchemy 2, asyncpg, Alembic |
| AI·검색 | Vertex AI · Gemini, Voyage AI |
| 스토리지·인증·푸시 | Google Cloud Storage, Apple·Google 로그인, JWT, APNs |

### 개발·검증

| 구분 | 기술·자료 |
| --- | --- |
| 패키지·로컬 환경 | uv, Docker Compose |
| 테스트·정적 검사 | pytest, Ruff, mypy, SwiftLint, TCA TestStore |
| 설계·디자인 자료 | 준비 중 |

## 프로젝트 산출물

| 자료 | 링크·상태 |
| --- | --- |
| 시연 영상 | 준비 중 |
| 발표자료 | 준비 중 |
| 최종 발표자료 | 준비 중 |
| 프로젝트 결과보고서 | 준비 중 |
| API 명세 | [OpenAPI](mochi-backend/openapi.json) |
| 개발 문서 | [iOS](mochi-ios/README.md) · [백엔드](mochi-backend/README.md) |

## 실행 방법

| 프로젝트 | 실행 환경 | 상세 안내 |
| --- | --- | --- |
| [`mochi-ios/`](mochi-ios/) | macOS, Xcode, Tuist · iOS 17+ | [빌드·실행](mochi-ios/README.md#시작하기) |
| [`mochi-backend/`](mochi-backend/) | Python 3.12+, uv, Docker Compose | [설치·실행](mochi-backend/README.md#시작하기) |

AI·스토리지·로그인·푸시 사용 시 외부 서비스 설정 필요. 기기 기능 사용 시 서명·권한 설정 필요.

## 팀 소개

**세얼간이** · 단국대학교 캡스톤 프로젝트 팀

| 이름 | 담당 역할 | GitHub |
| --- | --- | --- |
| 준비 중 | 준비 중 | 준비 중 |
| 준비 중 | 준비 중 | 준비 중 |
| 준비 중 | 준비 중 | 준비 중 |

<!-- 시연·산출물·화면·팀원 정보 확보 후 ‘준비 중’ 항목 교체 -->
