import { describe, expect, it } from "vitest";
import { PERSONAS } from "@seed/index";
import { captureExamplesFor } from "./captureExamples";

describe("captureExamplesFor", () => {
  it.each(PERSONAS)("$name에게 중복 없는 페르소나 예시 15건씩과 장소 예시를 준다", (persona) => {
    const examples = captureExamplesFor(persona);
    const personaImages = new Set(
      persona.items.flatMap((item) => (item.image ? [item.image.file] : [])),
    );

    for (const kind of ["screenshot", "url", "memo"] as const) {
      const selected = examples.filter((example) => example.kind === kind);
      expect(selected).toHaveLength(15);
      expect(new Set(selected.map((example) => example.id)).size).toBe(15);
      expect(new Set(selected.map((example) => example.title)).size).toBe(15);
      expect(selected.filter((example) => example.place).length).toBeGreaterThanOrEqual(5);
      if (kind !== "memo") {
        expect(new Set(selected.map((example) => example.kind !== "memo" && example.image.file)).size).toBe(15);
      }
    }
    const screenshotImages = new Set(
      examples
        .filter((example) => example.kind === "screenshot")
        .map((example) => example.image.file),
    );
    const urlImages = examples
      .filter((example) => example.kind === "url")
      .map((example) => example.image.file);
    expect(urlImages.every((image) => !screenshotImages.has(image))).toBe(true);
    expect(examples.every((example) => example.id.startsWith(`${persona.slug}-`))).toBe(true);
    expect(
      examples
        .filter((example) => example.kind !== "memo")
        .every(
          (example) =>
            personaImages.has(example.image.file) ||
            example.image.file.startsWith(`/seed/examples/${persona.slug}-`) ||
            example.image.file.startsWith(`/seed/examples/links/${persona.slug}-`),
        ),
    ).toBe(true);
  });

  it("김세나의 교체 예시 5건에 실제 캡처와 맞는 설명·장소를 연결한다", () => {
    const sena = PERSONAS.find((persona) => persona.slug === "sena");
    expect(sena).toBeDefined();

    const screenshots = captureExamplesFor(sena!)
      .filter((example) => example.kind === "screenshot");
    const expected = [
      ["AWS AI·클라우드 특화교육", "/seed/examples/sena-dankook-ai-cloud.webp", "단국대학교 소프트웨어ICT관"],
      ["웨이팅 필수 고기리막국수", "/seed/examples/sena-gogiri-makguksu.webp", "고기리막국수"],
      ["핫셀러 신입 개발자 채용", "/seed/examples/sena-hotseller-developer-job.webp", undefined],
      ["용인 웨이팅 맛집 홍춘", "/seed/examples/sena-hongchun-yongin.webp", "홍춘"],
      ["EDC 코리아 2026 일정", "/seed/examples/sena-edc-korea.webp", "인스파이어 엔터테인먼트 리조트"],
    ] as const;

    for (const [title, file, placeName] of expected) {
      const example = screenshots.find((candidate) => candidate.title === title);
      expect(example?.image.file).toBe(file);
      expect(example?.place?.name).toBe(placeName);
    }
  });

  it("박도현의 교체 예시 4건에 실제 캡처와 맞는 설명·장소를 연결한다", () => {
    const dohyun = PERSONAS.find((persona) => persona.slug === "dohyun");
    expect(dohyun).toBeDefined();

    const screenshots = captureExamplesFor(dohyun!)
      .filter((example) => example.kind === "screenshot");
    const expected = [
      ["판교 회식 맛집 양우정", "/seed/examples/dohyun-yangwoojung-pangyo.webp", "양우정"],
      ["TMUX 마스터클래스: cmux 코딩 에이전트", "/seed/examples/dohyun-cmux-masterclass.webp", undefined],
      ["PyCon Korea 2026 프로젝트 쇼케이스", "/seed/examples/dohyun-pycon-showcase.webp", undefined],
      ["판교 공룡런 5km 코스", "/seed/examples/dohyun-pangyo-dinorun.webp", "화랑공원"],
    ] as const;

    for (const [title, file, placeName] of expected) {
      const example = screenshots.find((candidate) => candidate.title === title);
      expect(example?.image.file).toBe(file);
      expect(example?.place?.name).toBe(placeName);
    }
  });

  it("이유나의 교체 예시 9건에 실제 캡처와 맞는 설명·장소를 연결한다", () => {
    const yuna = PERSONAS.find((persona) => persona.slug === "yuna");
    expect(yuna).toBeDefined();

    const screenshots = captureExamplesFor(yuna!)
      .filter((example) => example.kind === "screenshot");
    const expected = [
      ["성수 소금빵 맛집 베통", "/seed/examples/yuna-betong-seongsu.webp", "베통 성수"],
      ["원팬 파스타 레시피 12가지", "/seed/examples/yuna-onepan-pasta-12.webp", undefined],
      ["성수 신상 카페 더 커피", "/seed/examples/yuna-the-coffee-seongsu.webp", "더 커피 성수"],
      ["알로 요가 아이코닉 쇼퍼 토트백", "/seed/examples/yuna-oversized-layered-tee.webp", undefined],
      ["서울일러스트레이션페어 V.21", "/seed/examples/yuna-seoul-illustration-fair.webp", "코엑스 Hall C"],
      ["성수 데이트 카페 4곳", "/seed/examples/yuna-seongsu-date-cafes.webp", "성수동 카페거리"],
      ["연남동 뉴오더클럽 피자", "/seed/examples/yuna-new-order-club-pizza.webp", "뉴오더클럽 연남"],
      ["제주 돌집 스테이 탐라는일상", "/seed/examples/yuna-tamranun-ilsang-jeju.webp", "탐라는일상"],
      ["성수 도자기 클래스 크래프트 프랙티스", "/seed/examples/yuna-craft-practice.webp", "크래프트 프랙티스"],
    ] as const;

    for (const [title, file, placeName] of expected) {
      const example = screenshots.find((candidate) => candidate.title === title);
      expect(example?.image.file).toBe(file);
      expect(example?.place?.name).toBe(placeName);
    }
  });
});
