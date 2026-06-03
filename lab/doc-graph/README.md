# lab/doc-graph — 의존성 그래프 프로토타입 (HELD · 미채택)

**상태: 보류(HELD).** 작성·검증은 됐으나 채택하지 않았다. 근거·선결조건은
[`journal/2026-06-04-doc-consistency-redesign.md`](../../journal/2026-06-04-doc-consistency-redesign.md) §9.

## 구성
- `graph.json` — canonical 문서 + 코드표면의 의존 그래프 (JSON Graph Format 계열, nodes+edges).
- `validate_graph.py` — 구조적 드리프트 검출 (죽은 path · dangling edge · self-loop = ERROR; orphan · cycle · 중복 = WARN).
- `graph.broken.json` — 음성테스트 fixture.

## 실행
```bash
python3 lab/doc-graph/validate_graph.py                       # 실 그래프 → PASS(exit 0)
python3 lab/doc-graph/validate_graph.py lab/doc-graph/graph.broken.json   # → FAIL(exit 1)
```

## 채택 선결조건 (미충족 — 충족 전 repo 승격 금지)
- **(a)** WORKFLOW §3 공유표면 목록과의 이중 원천 해소 (graph는 현재 §3의 부분집합 — 라우팅 누락).
- **(b)** validator를 `/ship` precheck 또는 CI에 배선 (안 하면 죽은 파일).
- **(c)** P1은 graph(③ reminder)보다 테스트(② 확장)가 더 확실한지 비교 선행.

## 한계
validator는 *구조적* 드리프트만 잡는다. *의미적* 드리프트(refactor 후 엣지가 더는 사실 아님)·*누락 엣지*는 못 잡는다 — 그건 doc-guardian(AI) 몫.
