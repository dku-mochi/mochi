import * as THREE from "three";
import type { ResolvedItem } from "@/lib/seedRuntime";

/*
 * 이미지 없는 기록(메모·링크)의 코버플로우 카드 텍스처 — 타일 문법을 캔버스로 그린다.
 * 모서리는 캔버스 클리핑으로 라운딩 (transparent plane 에 얹힘).
 */

const W = 512;
const H = 966; // 카드 비율 0.53 (iOS cardWidth = height*0.53)
const R = 44;

const TINT = {
  url: { bg: "#F4EFFF", glyph: "#D8CBFF", accent: "#6F50E8" },
  memo: { bg: "#FFF8DE", glyph: "#EDD9A0", accent: "#8A6410" },
} as const;

function roundRectPath(ctx: CanvasRenderingContext2D) {
  ctx.beginPath();
  ctx.moveTo(R, 0);
  ctx.arcTo(W, 0, W, H, R);
  ctx.arcTo(W, H, 0, H, R);
  ctx.arcTo(0, H, 0, 0, R);
  ctx.arcTo(0, 0, W, 0, R);
  ctx.closePath();
}

function wrapText(
  ctx: CanvasRenderingContext2D,
  text: string,
  maxWidth: number,
  maxLines: number,
): string[] {
  const lines: string[] = [];
  let line = "";
  for (const ch of text) {
    if (ctx.measureText(line + ch).width > maxWidth) {
      lines.push(line);
      line = ch;
      if (lines.length === maxLines) {
        lines[maxLines - 1] = lines[maxLines - 1].slice(0, -1) + "…";
        return lines;
      }
    } else {
      line += ch;
    }
  }
  if (line) lines.push(line);
  return lines;
}

export function makeCardTexture(item: ResolvedItem): THREE.CanvasTexture {
  const canvas = document.createElement("canvas");
  canvas.width = W;
  canvas.height = H;
  const ctx = canvas.getContext("2d")!;
  const tint = item.kind === "url" ? TINT.url : TINT.memo;
  const font = `"Pretendard Variable", "Apple SD Gothic Neo", sans-serif`;

  ctx.clearRect(0, 0, W, H);
  roundRectPath(ctx);
  ctx.save();
  ctx.clip();

  ctx.fillStyle = tint.bg;
  ctx.fillRect(0, 0, W, H);

  // 워터마크 글리프
  ctx.fillStyle = tint.glyph;
  ctx.globalAlpha = 0.5;
  ctx.font = `800 260px ${font}`;
  ctx.fillText(item.kind === "url" ? "@" : "“", W - 210, 230);
  ctx.globalAlpha = 1;

  // 제목 (줄바꿈)
  ctx.fillStyle = "#17172A";
  ctx.font = `800 52px ${font}`;
  const titleLines = wrapText(ctx, item.title, W - 120, 4);
  titleLines.forEach((line, i) => ctx.fillText(line, 60, 330 + i * 72));

  // 본문 미리보기
  if (item.text) {
    ctx.fillStyle = "#373750";
    ctx.font = `500 34px ${font}`;
    const bodyLines = wrapText(ctx, item.text, W - 120, 5);
    bodyLines.forEach((line, i) =>
      ctx.fillText(line, 60, 360 + titleLines.length * 72 + i * 52),
    );
  }

  // 출처 푸터
  ctx.fillStyle = tint.accent;
  ctx.font = `700 30px ${font}`;
  ctx.fillText(item.source, 60, H - 70);

  ctx.restore();

  const texture = new THREE.CanvasTexture(canvas);
  texture.colorSpace = THREE.SRGBColorSpace;
  // 렌더러가 하드웨어 상한으로 클램프한다 — 기울어진 카드의 텍스트 선명도 (랜딩과 동일값)
  texture.anisotropy = 8;
  return texture;
}
