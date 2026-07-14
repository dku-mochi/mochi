#!/usr/bin/env python3
"""카테고리 어휘 노출률과 스냅샷 파편화를 오프라인으로 재현한다.

이 실험의 coverage 는 과거에 쓴 *정확한 라벨 문자열*이 새 분석 입력에 보이는 비율이다.
LLM 이 실제로 그 라벨을 선택하는 정확도나 의미상 동의어 판정률은 측정하지 않는다.
"""

from __future__ import annotations

import json
from collections import Counter
from collections.abc import Callable
from datetime import UTC, datetime, timedelta
from difflib import SequenceMatcher
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).with_name("results.json")

Event = tuple[datetime, str]
Selector = Callable[[list[Event], datetime], set[str]]


def _jsonl(path: Path) -> list[dict[str, object]]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def _category(row: dict[str, object]) -> str:
    return str(row.get("category") or "").strip()


def _recent(*, limit: int, days: int | None) -> Selector:
    def select(history: list[Event], now: datetime) -> set[str]:
        eligible = (
            event for event in reversed(history) if days is None or now - event[0] <= timedelta(days=days)
        )
        return {category for _, category in list(eligible)[:limit]}

    return select


def _lifetime(*, limit: int) -> Selector:
    def select(history: list[Event], _now: datetime) -> set[str]:
        counts = Counter(category for _, category in history)
        last_used = {category: at for at, category in history}
        ranked = sorted(counts, key=lambda category: (-counts[category], -last_used[category].timestamp(), category))
        return set(ranked[:limit])

    return select


SELECTORS: dict[str, Selector] = {
    "current_recent18_30d": _recent(limit=18, days=30),
    "recent40_30d": _recent(limit=40, days=30),
    "recent40_all_time": _recent(limit=40, days=None),
    "lifetime50": _lifetime(limit=50),
}


def _repeat_coverage(events: list[Event], selector: Selector) -> dict[str, float | int]:
    history: list[Event] = []
    seen: set[str] = set()
    repeats = hits = 0
    for at, category in events:
        if category in seen:
            repeats += 1
            hits += category in selector(history, at)
        history.append((at, category))
        seen.add(category)
    return {
        "repeat_events": repeats,
        "hits": hits,
        "coverage_pct": round(100 * hits / repeats, 1) if repeats else 0.0,
    }


def _probe_coverage(history: list[Event], queries: list[Event], selector: Selector) -> dict[str, float | int]:
    working = list(history)
    hits = 0
    for at, category in queries:
        hits += category in selector(working, at)
        working.append((at, category))
    return {
        "queries": len(queries),
        "hits": hits,
        "coverage_pct": round(100 * hits / len(queries), 1),
    }


def _controlled_probes(topics: list[str]) -> dict[str, dict[str, dict[str, float | int]]]:
    start = datetime(2026, 1, 1, tzinfo=UTC)
    seeds = [(start + timedelta(minutes=i), category) for i, category in enumerate(topics)]

    scenarios: dict[str, tuple[list[Event], list[Event]]] = {
        "31d_dormancy": (
            seeds,
            [(start + timedelta(days=31, minutes=i), category) for i, category in enumerate(topics)],
        ),
        "25_intervening_saves": (
            seeds + [(start + timedelta(days=1, minutes=i), "__filler__") for i in range(25)],
            [(start + timedelta(days=2, minutes=i), category) for i, category in enumerate(topics)],
        ),
        "60_intervening_saves": (
            seeds + [(start + timedelta(days=1, minutes=i), "__filler__") for i in range(60)],
            [(start + timedelta(days=2, minutes=i), category) for i, category in enumerate(topics)],
        ),
    }
    return {
        scenario: {name: _probe_coverage(history, queries, selector) for name, selector in SELECTORS.items()}
        for scenario, (history, queries) in scenarios.items()
    }


def main() -> None:
    recall = _jsonl(ROOT / "lab/data/recall-dump/mochi_items.jsonl")
    active = [
        row
        for row in recall
        if row.get("deleted_at") is None and _category(row)
    ]
    active.sort(key=lambda row: datetime.fromisoformat(str(row["captured_at"])))
    events = [(datetime.fromisoformat(str(row["captured_at"])), _category(row)) for row in active]

    normalized = [row for row in active if row.get("category_normalized_at") is not None]
    raw = [row for row in active if row.get("category_normalized_at") is None]
    normalized_labels = {_category(row) for row in normalized}
    raw_counts = Counter(_category(row) for row in raw)
    normalized_counts = Counter(_category(row) for row in normalized)

    prod = _jsonl(ROOT / "lab/data/mochi_items_prod.jsonl")
    prod_categories = [_category(row) for row in prod if _category(row)]
    prod_counts = Counter(prod_categories)

    recurring_topics = sorted(category for category, count in Counter(category for _, category in events).items() if count >= 2)
    labels = sorted(prod_counts)
    fuzzy = {}
    for threshold in (0.35, 0.40, 0.55, 0.65):
        pairs = [
            [a, b, round(SequenceMatcher(None, a, b).ratio(), 3)]
            for index, a in enumerate(labels)
            for b in labels[index + 1 :]
            if SequenceMatcher(None, a, b).ratio() >= threshold
        ]
        fuzzy[str(threshold)] = {"pair_count": len(pairs), "pairs": pairs}

    results = {
        "metric_scope": "exact prior-label availability; not semantic correctness or LLM reuse accuracy",
        "data": {
            "recall_snapshot": {
                "source_rows": len(recall),
                "active_categorized": len(active),
                "captured_min": min(at for at, _ in events).isoformat(),
                "captured_max": max(at for at, _ in events).isoformat(),
                "distinct_categories": len({category for _, category in events}),
                "normalized": {
                    "items": len(normalized),
                    "distinct": len(normalized_counts),
                    "singleton_labels": sum(count == 1 for count in normalized_counts.values()),
                },
                "raw": {
                    "items": len(raw),
                    "distinct": len(raw_counts),
                    "singleton_labels": sum(count == 1 for count in raw_counts.values()),
                    "items_exactly_covered_by_normalized_vocabulary": sum(
                        count for category, count in raw_counts.items() if category in normalized_labels
                    ),
                    "normalized_vocabulary_exact_coverage_pct": round(
                        100 * sum(count for category, count in raw_counts.items() if category in normalized_labels) / len(raw),
                        1,
                    ),
                },
            },
            "prod_snapshot": {
                "rows": len(prod),
                "categorized": len(prod_categories),
                "distinct_categories": len(prod_counts),
                "singleton_labels": sum(count == 1 for count in prod_counts.values()),
                "singleton_item_share_pct": round(
                    100 * sum(count for count in prod_counts.values() if count == 1) / len(prod_categories), 1
                ),
                "clear_alias_lower_bound": {
                    "labels": ["쇼핑", "쇼핑 후보"],
                    "counts": [prod_counts["쇼핑"], prod_counts["쇼핑 후보"]],
                    "cluster_total": prod_counts["쇼핑"] + prod_counts["쇼핑 후보"],
                    "alternate_label_share_pct": round(
                        100 * prod_counts["쇼핑 후보"] / (prod_counts["쇼핑"] + prod_counts["쇼핑 후보"]), 1
                    ),
                },
            },
        },
        "observed_stream": {name: _repeat_coverage(events, selector) for name, selector in SELECTORS.items()},
        "controlled_probes": _controlled_probes(recurring_topics),
        "fuzzy_label_probe": fuzzy,
        "live_ab_followup": {
            "model": "gemini-3.1-flash-lite",
            "cases": 3,
            "variants": 2,
            "runs_per_cell": 3,
            "successful_runs": 18,
            "target_definition": "exact match to an existing canonical label supplied only to lifetime_vocab",
            "baseline": {
                "target_matches": 0,
                "runs": 9,
                "target_match_pct": 0.0,
                "categories_by_case": {
                    "investment": ["투자 공부", "투자 공부", "투자 공부"],
                    "academic": ["학사 일정", "학사 일정", "학사 일정"],
                    "shopping": ["쇼핑 고민", "쇼핑 계획", "쇼핑 계획"],
                },
                "median_latency_ms": 1970.3,
            },
            "lifetime_vocab": {
                "target_matches": 9,
                "runs": 9,
                "target_match_pct": 100.0,
                "categories_by_case": {
                    "investment": ["투자", "투자", "투자"],
                    "academic": ["학업", "학업", "학업"],
                    "shopping": ["쇼핑", "쇼핑", "쇼핑"],
                },
                "median_latency_ms": 1791.0,
            },
            "caveat": "small hand-authored stress set; not a general category-accuracy estimate",
        },
    }
    OUT.write_text(json.dumps(results, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
