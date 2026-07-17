import { describe, expect, it } from "vitest";
import type { ResolvedItem } from "@/lib/seedRuntime";
import { purchaseSearchFallback } from "./purchaseSearch";

const item = {
  shoppingProductQuery: "봄이슈 니드 스피드 피그먼트 레이어드 맨투맨 긴팔티",
  referenceLinks: [],
} as unknown as ResolvedItem;

describe("purchaseSearchFallback", () => {
  it("상품명은 있지만 검증된 구매 링크가 없으면 검색 링크를 만든다", () => {
    const fallback = purchaseSearchFallback(item);
    expect(fallback?.label).toBe("네이버에서 상품 찾기");
    expect(new URL(fallback!.url).searchParams.get("query")).toBe(item.shoppingProductQuery);
  });

  it("검증된 구매 링크가 있으면 중복 검색 링크를 만들지 않는다", () => {
    expect(
      purchaseSearchFallback({
        ...item,
        referenceLinks: [
          {
            url: "https://example.com/product",
            title: "상품",
            label: "구매하기",
            role: "buy",
            provider: "official",
            rankProfile: "fashion",
          },
        ],
      }),
    ).toBeNull();
  });

  it("상품 검색어가 없으면 일반 기록에는 노출하지 않는다", () => {
    expect(purchaseSearchFallback({ ...item, shoppingProductQuery: undefined })).toBeNull();
  });
});
