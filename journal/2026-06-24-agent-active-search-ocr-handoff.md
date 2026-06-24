---
level: 3
mode: handoff
status: active
last_verified: 2026-06-24
confidence: 0.9
owners: [송준서]
title: 분석 에이전트 능동 검색 + 멀티쿼리 RRF + ephemeral OCR — PR1 구현 완료, PR2 인수인계
description: 캡처 분석(ingestion) 에이전트 고도화 4종(과거 기록 능동 검색·멀티쿼리 RRF·webSearch 이식·ephemeral OCR)의 설계 결정과 구현 인수인계. PR1(검색 트랙, 백엔드)은 코드+테스트 완료(브랜치 feature/agent-active-search), code-reviewer 반영만 남음. PR2(ephemeral OCR + iOS)는 전량 미착수 — 이 문서 §5 + Plan 문서로 0부터 이어받는다. Plan 정본: /Users/jun/.claude/plans/jazzy-wandering-anchor.md.
---

# 분석 에이전트 능동 검색 + ephemeral OCR — 인수인계 (2026-06-24)

## 0. 한 줄 요약

오너가 캡처 분석 에이전트 고도화 4종을 확정했다. **PR1(검색 트랙, 백엔드)은 구현+테스트 완료**(브랜치 `feature/agent-active-search`), code-reviewer 발견사항 반영만 남음. **PR2(ephemeral OCR 백엔드 + iOS + PRIVACY 개정)는 전량 미착수** — 별도 PR로 0부터 이어받는다.

**Plan 정본(필독)**: `/Users/jun/.claude/plans/jazzy-wandering-anchor.md` — PR1/PR2 단계별 + 검증 전부 들어있다. architect 2명이 코드 앵커를 재검증한 산물.

---

## 1. 어쩌다 여기까지 — 대화 흐름

1. 오너가 "채팅 에이전트가 쓰는 tool 종류"를 물음 → 코드 조사: 채팅 10종(search_items·web_search(Tavily)·get_item_detail·view_item_image·web_fetch·propose 5종), 분석 에이전트 4종(platformContext·webFetch·recoverYoutubeUrl·findReferenceUrls).
2. 오너 평가: "분석 tool이 생각보다 빈약하다 — WebSearch 없고, OCR 없다(iOS 기본 제공인데). findReferenceUrls가 효용 1위." → **분석 에이전트 고도화** 요청.
3. 제안→피드백 3라운드로 **4개 작업 확정**(§2). 핵심 통찰: search_items는 이미 hybrid+rerank였고(오너는 vector-only로 오해), 키워드도 5단어 AND였다 — 코드로 전제를 계속 바로잡으며 설계.
4. 오너가 plan mode 진입 지시 + "architect가 '문서와 다르다/실험 안 했다'고 몸 사리지 말고 최상급 플랜 짜게 하라" + "이번 세션 한정 서브에이전트로 코드 수정 OK" + "OCR은 iOS OCR 동봉(b안)". Explore 3 + architect 2로 플랜 확정 → 승인.
5. 구현: PR1 완료. 컨텍스트 한계로 이 핸드오프 작성 후 PR2는 다음 세션.

---

## 2. 확정된 4개 작업 + 왜

**미션 기준선**: "놓치기 쉬운 순간은 쉽게 남기고, 필요한 기억은 쉽게 떠오른다 — 회수의 주체는 모찌." (PRODUCT §1.5)

| # | 작업 | 왜 | PR |
| --- | --- | --- | --- |
| T1 | search_items를 분석 에이전트 능동 tool로 (hybridSearch) | 분석 중 "이거 전에 비슷한 거 있었지?"를 모찌가 능동 회수 → 중복·연결·일정충돌 인지. 미션의 "회수" 빈자리. 기존 `_recent_analysis_context`(최근 40건 수동 주입)는 능동 검색이 아님 | PR1 |
| T2 | search_items·web_search 멀티쿼리(queries) + RRF | 한 캡처/turn이 여러 측면(인물·장소·주제)을 가질 때 한 호출에. 오너 직관 "성능 올리는 가장 쉬운 방법" | PR1 |
| T3 | webSearch(Tavily)를 분석 에이전트에 이식 | KNOWLEDGE intent 외부 사실 그라운딩(findReferenceUrls는 커머스·장소 특화라 빈자리) | PR1 |
| T4 | iOS Vision OCR 텍스트 동봉 → ephemeral 분석 | 일반 스크린샷은 텍스트 레이어가 없어 정보 밀도 높으면 멀티모달이 누락. OCR을 **영속/노출 안 하고 분석 컨텍스트로만 쓰고 추론 후 삭제** → 민감 게이트 미적용(러프) | PR2 |

### 결정의 핵심 근거 (다시 흔들리지 않게)

- **T1은 "저장 게이트"가 절대 아니다.** 중복이어도 항상 저장한다(미션 "놓치기 쉬운 순간은 쉽게 남긴다"). 도메인도 중복 허용(intent_instances 1:N). 발견한 중복/연결/일정충돌은 summary·needs_review에만 반영. "기록 안 함/저장 안 함"은 미션 위반.
- **T1 vs 트랙C 구분**: hybridSearch=분석 *중* LLM이 과거를 떠올려 분석 품질 보강. 트랙C(`generate_recall_candidates`)=분석 *후* worker가 임베딩 ANN으로 알림 발송 판단. 다른 단계, 중복 아님.
- **캘린더 맥락은 별도 툴 불필요** — search_items의 `occurs_from/occurs_to`+`intent_type` 필터가 "그날 이미 잡힌 일정/할일"을 답한다. T1에 흡수.
- **T4 ephemeral은 PRIVACY와 양립**: PRIVACY가 막는 핵심 위험은 ① 서버 영속 ② 사용자 노출 ③ 검색 인덱스 잔류 — ephemeral OCR은 셋 다 회피. 오너 강조: "민감 게이트에 과민하면(이름만 나와도 OCR 차단) tool 효용 급락, 사용성 > 과도한 게이트, 일반 추론 성능 악화가 더 치명적."
- **OCR 방식 = (b) iOS Vision OCR 동봉** (서버 OCR 아님 — 온디바이스 무료). 단 비동기 outbox라 분석 전까지 DB에 잠깐 존재, 분석 done 후 NULL.

### 비차단 결정 (추천 채택, 확정)

- 어댑터 타입 = **duck-typing(Any)** — agent가 conversations 구체 타입 import 안 함(모듈 경계).
- RRF rerank query = **`" | ".join(queries)`** (멀티 측면 함께 rerank).
- RRF k=60, _MAX_QUERIES=4.
- OCR 분석 입력 = **별도 "# 화면 텍스트(OCR)" 블록**(source.text와 분리 — 신뢰도 다름).
- OCR 컬럼명 = **`analysis_ocr_text`**, iOS OCR Realm **비영속**.
- **PR 구조 = 트랙별 분리 PR 2개** (검색 / OCR).
- **범위 = 검색+OCR+iOS 전부** (ShareExt 메모리/지연 최적화는 오너가 후속 — 우선 동작 구현).

---

## 3. PR1 (검색 트랙) — 구현 완료 상태

**브랜치**: `feature/agent-active-search` (base: `develop`). **검증**: `make typecheck`·`make lint` 통과, `make test` 461 pass(1 chat 버전 assert 갱신 완료), 신규 어댑터 테스트 3 + 멀티쿼리 테스트 3 추가. **code-reviewer(codex) 백그라운드 실행 중 — 발견사항 반영만 남음.**

### 변경 파일 (13개)

**멀티쿼리+RRF (T2)**
- `app/modules/conversations/infrastructure/tools/search_items.py` — `run`을 queries 루프로. query별 `_keyword_candidates`+`_vector_candidates` → `_rrf_fuse`(k=60) → rerank 1회(`" | ".join`). `_parse_queries`(하위호환 query str→[query]), `_MAX_QUERIES=4`, `_RRF_K=60`. degrade 유지(voyage 죽음→키워드만, rerank 실패→폴백, 빈 queries→`_filter_only`).
- `app/modules/conversations/infrastructure/tools/web_search.py` — query별 Tavily → url union/dedup, `_RESULTS_CAP=10`. 부분 실패 degrade.

**어댑터/주입 (T1, T3)**
- `app/modules/agent/domain/tools.py` — `ToolContext(owner_id, mochi_item_id)` + `ContextAwareTool`(run_with_context abstract, 기본 run은 RuntimeError 차단). `ToolName.WEB_SEARCH="webSearch"` 추가.
- `app/modules/agent/application/orchestrator.py` — `_run_tool`에 owner_id/mochi_item_id 주입, `isinstance(tool, ContextAwareTool)` 분기로 `run_with_context(context=ToolContext(...))`. 호출부 `_analyze`도 전달.
- `app/modules/conversations/application/tool_factories.py` (신규) — `make_search_items_tool`, `make_web_search_tool` (모듈 경계 진입점).
- `app/modules/agent/infrastructure/tools/hybrid_search.py` (신규) — `HybridSearchTool(ContextAwareTool)`, ToolName.HYBRID_SEARCH. duck-typing으로 SearchItemsTool 받아 owner_id 바인딩, ChatToolResult→BaseModel 변환.
- `app/modules/agent/infrastructure/tools/web_search.py` (신규) — `WebSearchAgentTool(ContextAwareTool)`, ToolName.WEB_SEARCH.
- `app/modules/agent/infrastructure/registry.py` — `StaticToolRegistry.__init__`에 선택적 `session_factory`/`voyage`/`tavily_api_key`. session_factory 있으면 hybridSearch, tavily 있으면 webSearch 등록(지연 import). 무인자 호출 하위호환.
- `app/modules/agent/application/mochi_item_worker.py` — registry에 session_factory/voyage/tavily_api_key 주입.

**프롬프트 폭포 (T2 동반)**
- `app/modules/agent/infrastructure/gemini_agent_client.py` — `_HYBRID_SEARCH_PARAMS`/`_WEB_SEARCH_PARAMS` + FunctionDeclaration 2개.
- `app/modules/agent/prompts/system_prompts.py` — `# Tools` 고정 카운트("four")를 일반화 + hybridSearch/webSearch 2단락. PromptVersion `classify_and_act@v25→v26`.
- `app/modules/conversations/prompts/chat_prompts.py` — 멀티쿼리 지침(queries), `chat@v11→v12`.

**테스트**
- `test_chat_search_items.py` — 멀티쿼리 RRF(rerank 1회 assert)·query cap 신규 + 기존 semantic 기대값 RRF 순서로 갱신.
- `test_chat_web_tools.py` — 멀티쿼리 union/dedup 신규 + 에러 메시지 갱신(queries/HTTP코드).
- `test_agent_loop.py` — 어댑터 단위 2 + orchestrator owner 주입 통합 1.
- `test_chat_proposals.py` — chat@v12 assert.

**문서 폭포 (완료)**
- `docs/CHANGELOG.md`, `docs/ARCHITECTURE.md` §5.5(능동 검색 도구 + 트랙C 역할분리), `docs/PRIVACY_SENSITIVE_CAPTURE.md` §10(분석 webSearch 반출 경계). openapi.json 불변(tool은 LLM-facing).

### PR1 남은 일
1. **code-reviewer(codex) 발견사항 반영** — P1/P2만 수정, 나머지 판단.
2. `make test && make lint && make typecheck` 최종 + `ship-precheck.sh backend`.
3. 커밋 + PR (오너 승인 후).

---

## 4. ⚠️ PR1 미해결/주의

- **프롬프트 본문 수정(system_prompts v26, chat v12)은 eval 자산** — `# Tools`의 새 도구 안내는 기능 필수라 넣었으나, lab eval(분석 품질 회귀) 미실행. MEMORY[prompt-editing-research-first]. 오너에게 "eval 트랙 후속으로 뺄지" 확인 권장.
- hybridSearch는 worker가 session_factory를 항상 주입 → 운영에서 항상 노출. webSearch는 tavily 키 있을 때만.
- RRF rerank query `" | ".join` 효과는 미검증(lab eval 없음) — 추후 튜닝 여지(첫 query만 쓰는 대안).

---

## 5. PR2 (ephemeral OCR + iOS) — 전량 미착수, 0부터

**Plan 문서 §"PR 2"에 단계별 상세 있음.** architect-B가 코드 앵커 전수 검증. 핵심만:

### 백엔드
1. **컬럼 `analysis_ocr_text`**(String nullable) — 마이그레이션 `alembic/versions/..._0026`. 배선: `mochi_items/infrastructure/orm.py:25`, `presentation/schemas.py:84`(**MochiItemCreateRequest만**, alias `analysisOcrText`), `application/ingest.py`(IngestCommand:21/IngestSource:64), `domain/entities.py`(IngestSource:43), `presentation/router.py:265`, `infrastructure/repository.py:254/186`, `agent/domain/gateway.py:24`(AnalysisInput), `agent/infrastructure/mochi_item_gateway.py:41`(load_source).
2. **분석 입력 주입**: `orchestrator.py:595-625` `_initial_user_text`에 **별도 "# 화면 텍스트(OCR)" 블록**(source.text와 분리). system_prompts에 "OCR=이미지 보완, 대체 아님" 1줄(또 PromptVersion bump — eval 주의).
3. **삭제 훅**: `repository.py:502` `apply_analysis`의 lifecycle='analyzed' 직후 `row.analysis_ocr_text=None`. **DLQ 경로도**: `mochi_item_worker.py:205-209` failed UPDATE에 `analysis_ocr_text=NULL` 추가. 재분석은 OCR 없이(수용).
4. **누수 차단(필수 grep 게이트)** — OCR을 아래에 **추가하지 않음**으로 자연 제외, 검증만: `search_items.py:103`(_HAYSTACK_SQL), `search/postgres_index.py:48,51,55,83`, `router.py:136-210`(_to_response — Response엔 절대 미추가), `get_item_detail.py:91-104`, `orchestrator.py:323`(build_embedding_text). 검증: `rg analysis_ocr_text app/modules/conversations app/modules/search` → 0.

### PRIVACY 개정 (committed L2 — 정합성 폭포 필수)
- `PRIVACY_SENSITIVE_CAPTURE.md` §1.1을 **2종 구분**: (a) 영속 텍스트(`mochi_items.text` — 검색·노출, 민감 게이트 유지) vs (b) 분석용 ephemeral OCR(`analysis_ocr_text` — 추론 후 삭제·영속/노출/인덱스 없음, **민감 게이트 미적용**). §2.2에 불변식(localOnly는 OCR 미동봉 / 추론 직후 삭제 + 로그 digest·부울만).
- DOMAIN_DESIGN §2 테이블 인벤토리, ARCHITECTURE §4 ingest 계약, CHANGELOG.

### iOS (mochi-ios) — OCR 자산 이미 존재, 보존만
- `CorePrivacy/SensitiveCaptureScanner.swift`가 OCR을 만들고 버리는 중 → `SensitiveCaptureScanResult.ocrText` 보존. **비민감 캡처도 OCR 보존**(현재 shouldPromptUser 게이트 뒤에서만 생성 → 게이트 무관 OCR 경로 필요).
- `CoreDomain/IngestSource.swift:31` `analysisOcrText: String?`, 큐(`InboundQueueConsumer.swift:32,65`), 업로드 2경로(`MochiAPIClient.swift:360`·`MochiItemSyncWorker.uploadOne:157`·`ShareExtDirectUpload.attempt:52`).
- **localOnly 제외**: `policy == .localOnly ? nil : source.analysisOcrText`. 민감도 게이트로는 끄지 않음.
- Realm 비영속(큐 JSON에만). 백탭 경로(`CommitBackTapCaptureIntent`)는 업로드 직전 임시 stash.
- ⚠️ **오너가 후속 최적화하기로**: ShareExt 메모리/지연(비민감 OCR 항상 추출). 우선 동작 구현.

### OpenAPI 폭포
- `make openapi`(→ iOS CoreNetworking/openapi.json) → `mochi-ios/CodeGen/generate.sh`. `ship-precheck.sh backend` §5a/§5b no-diff.

### PR2 테스트
- `test_ingest_e2e.py`(analysisOcrText 보존), 신규 `test_analysis_ocr_ephemeral.py`(블록 주입/apply_analysis NULL/DLQ/재분석/누수 부재). iOS `tuist test`(localOnly→nil).

---

## 6. 작업 추적 (TaskList)

PR1: #1·#2·#3·#4 완료, #5(문서+테스트+검증+codex) 진행 중(codex 반영만). PR2: #6~#11 미착수(이 문서 §5).

## 7. 다음 세션 첫 행동

1. code-reviewer 결과 확인 → PR1 P1/P2 반영 → `make test` → 커밋/PR.
2. PR2 시작: `git checkout develop && git checkout -b feature/ephemeral-ocr`, Plan 문서 §"PR 2" + 이 문서 §5로 진행. PRIVACY 개정은 committed L2라 오너 합의 선행 권장.
