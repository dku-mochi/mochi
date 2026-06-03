#!/usr/bin/env python3
"""의존성 그래프(graph.json) validator — 구조적 드리프트 검출.

이 스크립트가 graph.json 의 *존재 이유*다. JSON 이 산문표(v2)보다 나은 유일한 근거는
"기계 검증 가능" 이고, 그 검증기가 이것이다. validator 없이 graph.json 만 두면
산문표를 JSON 으로 옮긴 것에 불과하다.

검사:
  ERROR (exit 1): 존재하지 않는 node path · dangling edge 참조 · self-loop · 잘못된 구조
  WARN  (exit 0): orphan(엣지 없는 노드) · cycle(상호 의존) · 중복 엣지

한계: *구조적* 드리프트만 잡는다. *의미적* 드리프트(refactor 후 엣지가 더는 사실이
아님)는 못 잡는다 — 그건 doc-guardian(AI) 의 주기 패스 몫.

stdlib only. lab/ 프로토타입.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path


def repo_root(start: Path) -> Path:
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            cwd=start, capture_output=True, text=True, check=True,
        )
        return Path(out.stdout.strip())
    except Exception:
        p = start
        while p != p.parent:
            if (p / ".git").exists():
                return p
            p = p.parent
        return start


def load(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        print(f"✗ graph 파일 없음: {path}", file=sys.stderr)
        sys.exit(2)
    except json.JSONDecodeError as e:
        print(f"✗ JSON 파싱 실패: {e}", file=sys.stderr)
        sys.exit(2)


def find_cycles(nodes, edges):
    """Tarjan SCC — 크기 2 이상 컴포넌트 = cycle."""
    adj = {n: [] for n in nodes}
    for e in edges:
        f, t = e.get("from"), e.get("to")
        if f in adj and t in nodes:
            adj[f].append(t)

    index, low, on_stack, stack, counter, sccs = {}, {}, {}, [], [0], []
    sys.setrecursionlimit(10000)

    def strong(v):
        index[v] = low[v] = counter[0]
        counter[0] += 1
        stack.append(v)
        on_stack[v] = True
        for w in adj[v]:
            if w not in index:
                strong(w)
                low[v] = min(low[v], low[w])
            elif on_stack.get(w):
                low[v] = min(low[v], index[w])
        if low[v] == index[v]:
            comp = []
            while True:
                w = stack.pop()
                on_stack[w] = False
                comp.append(w)
                if w == v:
                    break
            if len(comp) > 1:
                sccs.append(comp)

    for v in nodes:
        if v not in index:
            strong(v)
    return sccs


def main():
    ap = argparse.ArgumentParser(description="의존성 graph.json validator")
    ap.add_argument("graph", nargs="?", default=None, help="graph.json 경로 (기본: 스크립트 옆 graph.json)")
    ap.add_argument("--repo-root", default=None, help="path 해석 기준 (기본: git toplevel)")
    args = ap.parse_args()

    gpath = (Path(args.graph) if args.graph else Path(__file__).with_name("graph.json")).resolve()
    root = Path(args.repo_root).resolve() if args.repo_root else repo_root(gpath.parent)

    data = load(gpath)
    nodes = data.get("nodes")
    edges = data.get("edges", [])

    if not isinstance(nodes, dict):
        print("✗ 'nodes' 가 객체가 아님", file=sys.stderr)
        sys.exit(2)
    if not isinstance(edges, list):
        print("✗ 'edges' 가 배열이 아님", file=sys.stderr)
        sys.exit(2)

    errors, warns = [], []

    # 1) node path 실존
    for nid, n in nodes.items():
        p = (n or {}).get("path")
        if not p:
            errors.append(f"node '{nid}': path 필드 없음")
        elif not (root / p).exists():
            errors.append(f"node '{nid}': path 실존 안 함 → {p}")

    # 2) edge 참조 + self-loop + 중복
    seen, incident = set(), set()
    for i, e in enumerate(edges):
        f, t = e.get("from"), e.get("to")
        if f not in nodes:
            errors.append(f"edge[{i}]: from '{f}' 미정의 노드")
        if t not in nodes:
            errors.append(f"edge[{i}]: to '{t}' 미정의 노드")
        if f is not None and f == t:
            errors.append(f"edge[{i}]: self-loop '{f}'")
        key = (f, t, e.get("rel"))
        if key in seen:
            warns.append(f"중복 엣지: {f} -> {t} ({e.get('rel')})")
        seen.add(key)
        incident.add(f)
        incident.add(t)

    # 3) orphan
    for nid in nodes:
        if nid not in incident:
            warns.append(f"orphan(엣지 없음): {nid}")

    # 4) cycle (info)
    for scc in find_cycles(nodes, edges):
        warns.append(f"cycle(상호 의존, 의도적일 수 있음): {' <-> '.join(scc)}")

    # 보고
    print(f"graph: {gpath}")
    print(f"repo : {root}")
    print(f"nodes={len(nodes)} edges={len(edges)}\n")
    if errors:
        print(f"✗ ERROR {len(errors)}")
        for x in errors:
            print(f"  - {x}")
    if warns:
        print(f"{'⚠' if not errors else ''} WARN {len(warns)}".strip())
        for x in warns:
            print(f"  - {x}")
    if not errors and not warns:
        print("✓ 깨끗함")
    print()
    if errors:
        print(f"VERDICT: FAIL ({len(errors)} errors, {len(warns)} warnings)")
        sys.exit(1)
    print(f"VERDICT: PASS ({len(warns)} warnings)")
    sys.exit(0)


if __name__ == "__main__":
    main()
