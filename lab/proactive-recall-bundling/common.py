"""공유 로더: 송준서 계정 실데이터(103 items, voyage 1024-dim emb 1개/item).

데이터는 /tmp/mochi_recall_check/ 에서 읽는다. item 당 embedding 1개,
shopping_product value 는 별도 tsv(여러 행 가능 → 한 item 에 여러 상품).
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field

import numpy as np

DATA_DIR = "/tmp/mochi_recall_check"


@dataclass
class Item:
    item_id: str
    category: str
    summary: str
    vec: np.ndarray  # L2-normalized 1024-dim
    shopping: list[str] = field(default_factory=list)

    @property
    def entity_text(self) -> str:
        """LLM/규칙에 넣는 대표 텍스트: shopping_product 있으면 그것 우선 + summary."""
        sp = " / ".join(self.shopping) if self.shopping else ""
        return (sp + " — " if sp else "") + self.summary[:60]


def load_items(data_dir: str = DATA_DIR) -> list[Item]:
    shop: dict[str, list[str]] = {}
    sp_path = os.path.join(data_dir, "shopping_by_item.tsv")
    if os.path.exists(sp_path):
        with open(sp_path) as f:
            for line in f:
                q = line.rstrip("\n").split("\t")
                if len(q) >= 2 and q[1].strip():
                    shop.setdefault(q[0], []).append(q[1].strip())

    items: list[Item] = []
    with open(os.path.join(data_dir, "embeddings.tsv")) as f:
        for line in f:
            p = line.rstrip("\n").split("\t")
            if len(p) < 4:
                continue
            emb = p[3].strip().strip("[]")
            try:
                v = np.array([float(x) for x in emb.split(",")], dtype=np.float32)
            except ValueError:
                continue
            if v.shape[0] != 1024:
                continue
            v = v / (np.linalg.norm(v) + 1e-9)
            items.append(
                Item(
                    item_id=p[0],
                    category=p[1],
                    summary=p[2],
                    vec=v,
                    shopping=shop.get(p[0], []),
                )
            )
    return items


# ---- HDBSCAN ground-truth fine 군집 (baseline 에서 손으로 라벨링한 정답) ----
# baseline cluster.py 의 HDBSCAN 결과 중 "사람이 보면 한 주제" 인 fine 묶음을
# entity 키워드로 정의한다. 정합성 비교의 채점 기준.
GROUND_TRUTH_THEMES: dict[str, list[str]] = {
    "유니클로": ["유니클로"],
    "헨리넥티셔츠": ["헨리", "헨리넥", "henley"],
    "투자종목": ["SOXL", "DELL", "INTC", "Finance 앱", "관심 종목", "종목"],
    "주거정보": ["주거", "청년안심주택", "베르디움", "월세", "전세", "부동산", "매물"],
    "추출실패더미": ["접근할 수 없", "내용을 확인", "wwwjh", "wwwjk", "https://b", "https://k"],
    "무신사여름프로모션": ["무진장", "블랙프라이데이", "여름"],
}


def theme_of(item: Item) -> str | None:
    """item 이 어느 ground-truth 주제에 속하는지(키워드 매칭). 없으면 None."""
    hay = (item.summary + " " + " ".join(item.shopping)).lower()
    for theme, kws in GROUND_TRUTH_THEMES.items():
        for kw in kws:
            if kw.lower() in hay:
                return theme
    return None


def cos(a: np.ndarray, b: np.ndarray) -> float:
    return float(np.dot(a, b))
