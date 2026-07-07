import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { SHOTS } from "./manifest";

/*
 * 목업 HTML → 390×844(@2x) JPEG 촬영.
 * 실행: npx tsx scripts/capture-mocks/shoot.ts [출력파일필터]
 */
const OUT_DIR = join(process.cwd(), "public/seed/caps");

async function main() {
  const filter = process.argv[2];
  mkdirSync(OUT_DIR, { recursive: true });

  const browser = await chromium.launch();
  const ctx = await browser.newContext({
    viewport: { width: 390, height: 844 },
    deviceScaleFactor: 2,
  });
  const page = await ctx.newPage();

  const targets = filter ? SHOTS.filter((s) => s.out.includes(filter)) : SHOTS;
  for (const shot of targets) {
    await page.setContent(shot.html, { waitUntil: "networkidle" });
    await page.evaluate(() => document.fonts.ready);
    await page.screenshot({
      path: join(OUT_DIR, shot.out),
      type: "jpeg",
      quality: 82,
    });
    console.log(`✓ ${shot.out}`);
  }

  await browser.close();
  console.log(`\n${targets.length}장 완료 → public/seed/caps/`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
