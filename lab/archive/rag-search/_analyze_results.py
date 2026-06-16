"""결과 JSON 분석 스크립트 - category vs 비-category 평균 비교, query type별 분석.

실행:
  python "E:/dhapr/Downloads/mochi/lab/active/rag-search/_analyze_results.py" <result_json_path>
"""
import json
import sys
from collections import defaultdict
from pathlib import Path

if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
    sys.stdout.reconfigure(encoding="utf-8")

result_path = Path(sys.argv[1]) if len(sys.argv) > 1 else None
if result_path is None:
    # 최신 결과 자동 선택
    results_dir = Path(__file__).parent / "results" / "retrieval"
    files = sorted(results_dir.glob("*.json"))
    if not files:
        print("[ERROR] 결과 파일 없음")
        sys.exit(1)
    result_path = files[-1]

data = json.loads(result_path.read_text(encoding="utf-8"))
results = data["results"]

# vector 결과만 분리 (BM25, RRF 제외)
vec_results = [r for r in results if r["kind"] == "vector"]

print(f"결과 파일: {result_path.name}")
print(f"전체 결과 수: {len(results)} (vector: {len(vec_results)})")

# ── 1. HitRate@3 기준 상위 10개 ─────────────────────────────────────────────
print("\n\n[HitRate@3 기준 상위 10개 (vector only)]")
print(f"{'rank':<5} {'model':<20} {'dim':<6} {'strategy':<40} {'Hit@3':>7} {'Rec@5':>7} {'MRR':>7} {'nDCG@5':>8}")
print("-" * 105)
sorted_by_hit = sorted(vec_results, key=lambda r: (r["avg"]["hit_rate@3"], r["avg"]["ndcg@5"]), reverse=True)
for i, r in enumerate(sorted_by_hit[:10], 1):
    a = r["avg"]
    print(f"{i:<5} {r['model']:<20} {str(r['dimension']):<6} {r['strategy']:<40} {a['hit_rate@3']:>7.3f} {a['recall@5']:>7.3f} {a['mrr']:>7.3f} {a['ndcg@5']:>8.3f}")

# ── 2. category 전략 vs 비-category 전략 평균 비교 ───────────────────────────
def is_category(strategy: str) -> bool:
    return strategy.endswith("+category")

category_results = [r for r in vec_results if is_category(r["strategy"])]
non_category_results = [r for r in vec_results if not is_category(r["strategy"])]

def avg_metric(results_list, key):
    if not results_list:
        return 0.0
    return sum(r["avg"][key] for r in results_list) / len(results_list)

print("\n\n[category 전략 vs 비-category 전략 평균 (vector only)]")
print(f"{'그룹':<20} {'N':>4} {'Hit@3':>8} {'Recall@5':>10} {'MRR':>8} {'nDCG@5':>9}")
print("-" * 65)
for group_name, group in [("category", category_results), ("non-category", non_category_results)]:
    n = len(group)
    print(
        f"{group_name:<20} {n:>4} "
        f"{avg_metric(group, 'hit_rate@3'):>8.3f} "
        f"{avg_metric(group, 'recall@5'):>10.3f} "
        f"{avg_metric(group, 'mrr'):>8.3f} "
        f"{avg_metric(group, 'ndcg@5'):>9.3f}"
    )

# 모델별 category 효과
print("\n[모델별 category 전략 효과 (nDCG@5 평균 Δ)]")
model_dim_pairs = sorted(set((r["model"], r["dimension"]) for r in vec_results))
print(f"{'model@dim':<35} {'cat_avg':>9} {'nocat_avg':>10} {'delta':>8}")
print("-" * 68)
for model, dim in model_dim_pairs:
    cat = [r for r in vec_results if r["model"] == model and r["dimension"] == dim and is_category(r["strategy"])]
    nocat = [r for r in vec_results if r["model"] == model and r["dimension"] == dim and not is_category(r["strategy"])]
    if not cat or not nocat:
        continue
    cat_avg = avg_metric(cat, "ndcg@5")
    nocat_avg = avg_metric(nocat, "ndcg@5")
    delta = cat_avg - nocat_avg
    label = f"{model}@{dim}"
    print(f"{label:<35}{cat_avg:>9.3f}{nocat_avg:>10.3f}{delta:>+8.3f}")

# ── 3. query type별 HitRate@3 (전체 vector 평균) ────────────────────────────
print("\n\n[query type별 HitRate@3 -vector 전체 평균]")
type_data: dict[str, list[float]] = defaultdict(list)
for r in vec_results:
    for qtype, m in r.get("by_type", {}).items():
        type_data[qtype].append(m["hit_rate@3"])

print(f"{'query_type':<30} {'avg_Hit@3':>10} {'N':>5}")
print("-" * 50)
overall_avg = avg_metric(vec_results, "hit_rate@3")
for qtype in sorted(type_data):
    vals = type_data[qtype]
    avg = sum(vals) / len(vals)
    print(f"{qtype:<30} {avg:>10.3f} {len(vals):>5}")
print(f"{'(전체 평균)':<30} {overall_avg:>10.3f}")

# ── 4. category vs 비-category 전략별 query type nDCG@5 ─────────────────────
print("\n\n[category vs 비-category -query type별 nDCG@5 평균]")
all_types = sorted(type_data.keys())
print(f"{'query_type':<28}", end="")
for gname in ["category", "non-cat", "delta"]:
    print(f"  {gname:>10}", end="")
print()
print("-" * 70)

for qtype in all_types:
    cat_vals = [r["by_type"][qtype]["ndcg@5"] for r in category_results if qtype in r.get("by_type", {})]
    nocat_vals = [r["by_type"][qtype]["ndcg@5"] for r in non_category_results if qtype in r.get("by_type", {})]
    cat_avg = sum(cat_vals) / len(cat_vals) if cat_vals else 0.0
    nocat_avg = sum(nocat_vals) / len(nocat_vals) if nocat_vals else 0.0
    delta = cat_avg - nocat_avg
    marker = " +" if delta > 0.01 else (" -" if delta < -0.01 else "  ")
    print(f"{qtype:<28}  {cat_avg:>10.3f}  {nocat_avg:>10.3f}  {delta:>+9.3f}{marker}")

# ── 5. 상위 전략 상세 query type ─────────────────────────────────────────────
print("\n\n[상위 5 조합의 query type별 nDCG@5]")
top5 = sorted(vec_results, key=lambda r: r["avg"]["ndcg@5"], reverse=True)[:5]
all_types_sorted = sorted(all_types)
header = f"{'query_type':<28}"
for r in top5:
    label = f"{r['model']}@{r['dimension']}×{r['strategy']}"[:24]
    header += f"  {label:>24}"
print(header)
print("-" * (28 + 26 * len(top5)))
for qtype in all_types_sorted:
    row = f"{qtype:<28}"
    for r in top5:
        val = r.get("by_type", {}).get(qtype, {}).get("ndcg@5", 0.0)
        row += f"  {val:>24.3f}"
    print(row)
