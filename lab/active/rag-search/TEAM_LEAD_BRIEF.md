# RAG 검색 실험 환경 요약

## 목적

실제 Gemini 분석 결과를 기반으로 검색 성능을 비교해 프로덕션에 적용할 최적 조합을 결정한다.

- 임베딩 모델과 차원
- 임베딩에 포함할 Gemini 분석 필드
- BM25 / Vector / RRF 검색 방식

Gemini의 intent·summary 분석 품질은 기존 `agent-loop-image-eval`에서 담당한다.  
`rag-search`는 Gemini 분석 결과가 주어졌을 때 올바른 기록을 검색하는지를 평가한다.

## 실험 흐름

```text
실제 입력
→ Gemini Agent 분석
→ AnalysisResult
→ 전략별 임베딩 문서 생성
→ 임베딩 생성
→ 검색 실행
→ Gold Query 기반 평가
```

## 디렉터리 구조

```text
lab/active/rag-search/
├── data/cases.json          # 실험 입력
├── gold/queries.json        # 검색어와 기대 검색 결과
├── analyze.py               # 입력 → Gemini AnalysisResult
├── embed.py                 # AnalysisResult → 전략별 임베딩
├── eval_retrieval.py        # BM25 / Vector / RRF 검색 평가
├── _lab_utils.py            # 모델·차원·전략 후보 단일 원천
├── artifacts/               # 분석·임베딩 중간 결과, Git 제외
└── results/                 # 검색 평가 결과, Git 제외
```

## 1. 실험 입력

`data/cases.json`에는 입력만 정의한다. 현재는 `lab/data/screenshot`의 실제 스크린샷 46개를 사용하며, 이후 스크린샷+메모, text, URL 입력도 추가할 수 있다.

```json
{
  "id": "memo_나중에살화장품",
  "image": "memo_나중에살화장품.png",
  "text": null,
  "url": null,
  "user_memo": null
}
```

## 2. Gemini 분석

`analyze.py`가 프로덕션과 동일한 `AgentOrchestrator`, 활성 prompt, `AnalysisResult` 타입을 사용해 입력을 분석한다.

```text
cases.json
→ AnalysisInput
→ Gemini Agent
→ AnalysisResult
→ artifacts/analysis/{fingerprint}.json
```

## 3. 임베딩 생성

`embed.py`는 동일한 `AnalysisResult`를 여러 문서 전략과 모델·차원 조합으로 임베딩한다.

### 모델·차원 후보

```text
text-multilingual-embedding-002: 256 / 768
gemini-embedding-001: 256 / 768 / 1536
voyage-4: 256 / 1024
voyage-4-large: 256 / 1024
```

### 문서 전략

```text
summary
summary + labels
summary + labels + payload
summary + labels + payload + entities
structured fields
```

총 `9 모델·차원 × 5 문서 전략 = 45개` 조합을 생성한다.

## 4. 검색 정답

`gold/queries.json`에는 사람이 검색어와 기대 검색 결과를 정의한다.

```json
{
  "query": "나중에 사려고 저장한 물건",
  "type": "semantic_paraphrase",
  "expected_ids": ["memo_나중에살신발", "memo_나중에살화장품", "memo_화장품나중에살거"]
}
```

## 5. 검색 평가

`eval_retrieval.py`는 각 임베딩 조합에 대해 다음 검색 방식을 평가한다.

```text
BM25
Vector
BM25 + Vector RRF
```

평가 지표:

- `HitRate@3`: 상위 3개에 정답이 하나 이상 존재하는가
- `Recall@5`: 기대 정답 중 상위 5개에서 찾은 비율
- `MRR`: 첫 정답이 얼마나 높은 순위에 위치하는가
- `nDCG@5`: 여러 정답의 전체 순위 품질

키워드 검색, 의미 기반 재표현, intent 기반, entity 기반, 구어체 쿼리 유형별 결과도 분리해서 확인한다.

## 실행 방법

`mochi-backend` 디렉터리에서 실행한다.

```powershell
uv run python ..\lab\active\rag-search\analyze.py
uv run python ..\lab\active\rag-search\embed.py
uv run --group lab python ..\lab\active\rag-search\eval_retrieval.py
```

## 결과 활용

실험 결과를 바탕으로 다음 프로덕션 설정을 결정한다.

- 적용할 임베딩 모델과 차원
- 임베딩 문서에 포함할 분석 필드
- Vector 단독 또는 BM25+Vector RRF 사용 여부
- 후속 reranker 또는 LLM query rewrite 실험 필요 여부
