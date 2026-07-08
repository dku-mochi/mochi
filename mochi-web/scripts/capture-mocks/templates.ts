/*
 * 페르소나 캡처 이미지 목업 템플릿 — 390×844(@2x) 스크린샷으로 촬영된다.
 * 실서비스 로고·상표는 쓰지 않고 "그 앱처럼 보이는" 제네릭 UI만 재현한다 (저작권 안전).
 * 사진 영역은 그라데이션+블롭으로 대체 — 텍스트 정보(OCR 대응)가 주인공.
 */

const BASE_CSS = /* css */ `
  * { margin: 0; padding: 0; box-sizing: border-box; }
  html, body { width: 390px; height: 844px; overflow: hidden; }
  body {
    font-family: -apple-system, "Apple SD Gothic Neo", "Pretendard", sans-serif;
    -webkit-font-smoothing: antialiased;
    color: #1a1a1a; background: #fff;
    display: flex; flex-direction: column;
  }
  .sb { display:flex; justify-content:space-between; align-items:center;
        padding: 14px 24px 8px; font-size: 15px; font-weight: 600; }
  .sb .icons { display:flex; gap:5px; align-items:center; }
  .sig { display:flex; gap:1.5px; align-items:flex-end; }
  .sig i { width:3px; background:currentColor; border-radius:1px; display:block; }
  .batt { width:24px; height:12px; border:1px solid currentColor; border-radius:3.5px;
          padding:1.5px; margin-left:2px; }
  .batt i { display:block; height:100%; width:70%; background:currentColor; border-radius:1.5px; }
  .grow { flex: 1; overflow: hidden; }
`;

function statusBar(light = false) {
  return `<div class="sb" style="color:${light ? "#fff" : "#111"}">
    <span>9:41</span>
    <span class="icons">
      <span class="sig"><i style="height:4px"></i><i style="height:6px"></i><i style="height:8px"></i><i style="height:10px"></i></span>
      <svg width="16" height="12" viewBox="0 0 16 12" fill="none"><path d="M8 10.5a1.4 1.4 0 100 .01M4.7 8.2a4.8 4.8 0 016.6 0M2 5.4a8.7 8.7 0 0112 0" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"/></svg>
      <span class="batt"><i></i></span>
    </span>
  </div>`;
}

function page(body: string, extraCss = "", light = false, bg = "#fff") {
  return `<!doctype html><html><head><meta charset="utf-8"><style>${BASE_CSS}
  body { background: ${bg}; }
  ${extraCss}</style></head><body>${statusBar(light)}${body}</body></html>`;
}

/* ── 1. 카카오톡 대화 ─────────────────────────────── */
export type KakaoMsg =
  | { from: string; text: string; time?: string }
  | { mine: true; text: string; time?: string }
  | { card: { title: string; lines: string[]; deco?: string } };

export function kakao(p: { room: string; count?: number; messages: KakaoMsg[] }) {
  const msgs = p.messages
    .map((m) => {
      if ("card" in m)
        return `<div class="row"><div class="card">
          ${m.card.deco ? `<div class="deco">${m.card.deco}</div>` : ""}
          <div class="ct">${m.card.title}</div>
          ${m.card.lines.map((l) => `<div class="cl">${l}</div>`).join("")}
        </div></div>`;
      if ("mine" in m)
        return `<div class="row me">${m.time ? `<span class="t">${m.time}</span>` : ""}<div class="b mine">${m.text}</div></div>`;
      return `<div class="row"><div class="av">${m.from[0]}</div><div>
        <div class="nm">${m.from}</div>
        <div class="wrap"><div class="b">${m.text}</div>${m.time ? `<span class="t">${m.time}</span>` : ""}</div>
      </div></div>`;
    })
    .join("");
  return page(
    `<div class="hd"><span class="back">‹</span><b>${p.room}</b><span class="cnt">${p.count ?? ""}</span><span style="flex:1"></span><span class="ic">☰</span></div>
     <div class="grow chat">${msgs}</div>
     <div class="input"><span>+</span><div class="field"></div><span>#</span></div>`,
    `body { background:#B2C7DA; }
     .sb { color:#111; }
     .hd { display:flex; align-items:center; gap:10px; padding:10px 18px; font-size:17px; }
     .hd .back { font-size:26px; font-weight:300; }
     .hd .cnt { color:#556; font-size:15px; } .hd .ic { color:#445; }
     .chat { padding: 12px 14px; display:flex; flex-direction:column; gap:14px; }
     .row { display:flex; gap:9px; align-items:flex-start; }
     .row.me { justify-content:flex-end; align-items:flex-end; gap:6px; }
     .av { width:38px; height:38px; border-radius:15px; background:#8FA5B5; color:#fff;
           display:flex; align-items:center; justify-content:center; font-weight:700; }
     .nm { font-size:12.5px; color:#3d4a55; margin-bottom:4px; }
     .wrap { display:flex; gap:6px; align-items:flex-end; }
     .b { background:#fff; border-radius:4px 14px 14px 14px; padding:9px 12px; font-size:15px;
          line-height:1.45; max-width:250px; box-shadow:0 1px 1px rgb(0 0 0 / .05); }
     .b.mine { background:#FEE500; border-radius:14px 4px 14px 14px; }
     .t { font-size:10.5px; color:#5b6b78; }
     .card { background:#fff; border-radius:14px; padding:0 0 16px; width:270px; overflow:hidden;
             box-shadow:0 1px 2px rgb(0 0 0 / .07); margin-left:47px; }
     .deco { height:120px; background:linear-gradient(135deg,#f6e7e9,#e8d5ef 55%,#d9e4f5);
             display:flex; align-items:center; justify-content:center; font-size:15px;
             letter-spacing:.2em; color:#9a7d92; font-weight:600; }
     .ct { font-size:16.5px; font-weight:700; padding:14px 16px 6px; }
     .cl { font-size:13.5px; color:#556; padding:2px 16px; line-height:1.5; }
     .input { display:flex; align-items:center; gap:10px; background:#fff; padding:12px 16px 30px;
              font-size:22px; color:#889; }
     .field { flex:1; height:36px; background:#f1f3f5; border-radius:18px; }`,
  );
}

/* ── 2. LMS 공지 ─────────────────────────────── */
export function lms(p: {
  course: string;
  title: string;
  author: string;
  date: string;
  body: string[];
  due?: string;
}) {
  return page(
    `<div class="hd"><span>‹</span><b>${p.course}</b></div>
     <div class="grow post">
       <span class="badge">과제</span>
       <h1>${p.title}</h1>
       <div class="meta">${p.author} · ${p.date}</div>
       <hr/>
       ${p.body.map((b) => `<p>${b}</p>`).join("")}
       ${p.due ? `<div class="due"><b>제출 기한</b><span>${p.due}</span></div>` : ""}
       <div class="file"><span class="fic">PDF</span> 과제4_명세서.pdf <span class="fs">312KB</span></div>
     </div>`,
    `.hd { display:flex; gap:12px; align-items:center; background:#1F3A5F; color:#fff;
           padding:14px 18px; font-size:17px; } .hd span { font-size:24px; }
     .sb { background:#1F3A5F; color:#fff !important; }
     .sb, .sb * { color:#fff; }
     .post { padding:22px 20px; }
     .badge { background:#E8EEF7; color:#1F3A5F; font-size:12px; font-weight:700;
              padding:4px 10px; border-radius:6px; }
     h1 { font-size:21px; line-height:1.35; margin:12px 0 8px; }
     .meta { color:#8892a0; font-size:13px; }
     hr { border:none; border-top:1px solid #eef0f3; margin:16px 0; }
     p { font-size:15px; line-height:1.7; color:#333; margin-bottom:14px; }
     .due { margin-top:18px; background:#FFF6E8; border:1px solid #F5DEB8; border-radius:10px;
            padding:14px 16px; display:flex; justify-content:space-between; font-size:14.5px; }
     .due span { color:#B4690E; font-weight:700; }
     .file { margin-top:14px; border:1px solid #e8eaee; border-radius:10px; padding:12px 14px;
             font-size:14px; display:flex; gap:10px; align-items:center; }
     .fic { background:#E74C3C; color:#fff; font-size:10px; font-weight:800; padding:4px 6px; border-radius:5px; }
     .fs { color:#99a; margin-left:auto; font-size:12px; }`,
  );
}

/* ── 3. 유튜브 재생 ─────────────────────────────── */
export function youtube(p: {
  title: string;
  channel: string;
  meta: string;
  duration: string;
  progress: number;
  next: Array<{ t: string; c: string; d: string }>;
}) {
  return page(
    `<div class="video">
       <div class="thumb"><div class="play"></div></div>
       <div class="bar"><i style="width:${p.progress}%"></i></div>
       <span class="dur">${p.duration}</span>
     </div>
     <div class="grow info">
       <h1>${p.title}</h1>
       <div class="meta">${p.meta}</div>
       <div class="ch"><span class="cav">${p.channel[0]}</span><b>${p.channel}</b><span class="sub">구독</span></div>
       <div class="acts"><span>좋아요</span><span>공유</span><span>오프라인 저장</span><span>클립</span></div>
       ${p.next
         .map(
           (n) => `<div class="nx"><div class="nt"></div><div>
             <div class="nx1">${n.t}</div><div class="nx2">${n.c} · ${n.d}</div></div></div>`,
         )
         .join("")}
     </div>`,
    `body { background:#0f0f0f; color:#fff; }
     .sb, .sb * { color:#fff; }
     .video { position:relative; }
     .thumb { height:219px; background:
        radial-gradient(120% 140% at 15% 20%, #3b2f63 0%, transparent 55%),
        radial-gradient(110% 130% at 85% 80%, #14532d 0%, transparent 50%),
        linear-gradient(150deg, #1e293b, #0b1020);
        display:flex; align-items:center; justify-content:center; }
     .play { width:0; height:0; border-left:26px solid rgb(255 255 255 / .92);
             border-top:16px solid transparent; border-bottom:16px solid transparent; }
     .bar { position:absolute; bottom:0; left:0; right:0; height:3px; background:rgb(255 255 255 / .25); }
     .bar i { display:block; height:100%; background:#f03; }
     .dur { position:absolute; right:10px; bottom:10px; background:rgb(0 0 0 / .75);
            font-size:12px; padding:2px 6px; border-radius:4px; }
     .info { padding:14px 16px; }
     h1 { font-size:17.5px; line-height:1.4; font-weight:600; }
     .meta { color:#aaa; font-size:12.5px; margin:8px 0 14px; }
     .ch { display:flex; align-items:center; gap:10px; padding-bottom:14px; border-bottom:1px solid #272727; }
     .cav { width:36px; height:36px; border-radius:50%; background:#6d5ae0; display:flex;
            align-items:center; justify-content:center; font-weight:700; }
     .sub { margin-left:auto; background:#fff; color:#111; font-size:13px; font-weight:700;
            padding:8px 14px; border-radius:18px; }
     .acts { display:flex; gap:8px; margin:14px 0 18px; }
     .acts span { background:#272727; font-size:12.5px; padding:8px 13px; border-radius:16px; color:#eee; }
     .nx { display:flex; gap:10px; margin-bottom:14px; }
     .nt { width:150px; height:84px; border-radius:10px; flex:none;
           background:linear-gradient(140deg,#243b55,#141e30); }
     .nx1 { font-size:13.5px; line-height:1.4; }
     .nx2 { font-size:11.5px; color:#999; margin-top:5px; }`,
    true,
  );
}

/* ── 4. 인스타그램 포스트 ─────────────────────────────── */
export function insta(p: {
  handle: string;
  location?: string;
  photo: { css: string; label?: string; sub?: string };
  likes: string;
  caption: string;
  time: string;
  next?: { handle: string; css: string };
}) {
  return page(
    `<div class="hd"><b>피드</b></div>
     <div class="grow">
      <div class="post-hd">
        <span class="pav"></span>
        <div><b>${p.handle}</b>${p.location ? `<div class="loc">${p.location}</div>` : ""}</div>
        <span class="more">⋯</span>
      </div>
      <div class="photo" style="background:${p.photo.css}">
        ${p.photo.label ? `<div class="pl">${p.photo.label}</div>` : ""}
        ${p.photo.sub ? `<div class="ps">${p.photo.sub}</div>` : ""}
      </div>
      <div class="acts">
        <svg viewBox="0 0 24 24"><path d="M12 20.3C5.4 15.9 2.5 11.8 2.5 8.6 2.5 6 4.6 4 7.1 4c1.9 0 3.6 1.1 4.9 3 1.3-1.9 3-3 4.9-3 2.5 0 4.6 2 4.6 4.6 0 3.2-2.9 7.3-9.5 11.7z" fill="none" stroke="#111" stroke-width="1.8"/></svg>
        <svg viewBox="0 0 24 24"><path d="M21 11.5c0 4.1-4 7.5-9 7.5-1 0-2-.1-2.9-.4L4 20l1.2-3.6C3.8 15.1 3 13.4 3 11.5 3 7.4 7 4 12 4s9 3.4 9 7.5z" fill="none" stroke="#111" stroke-width="1.8"/></svg>
        <svg viewBox="0 0 24 24"><path d="M21 3L10 14M21 3l-7 18-4-8-8-3.5L21 3z" fill="none" stroke="#111" stroke-width="1.8" stroke-linejoin="round"/></svg>
        <svg style="margin-left:auto" viewBox="0 0 24 24"><path d="M6 3h12v18l-6-4.5L6 21V3z" fill="none" stroke="#111" stroke-width="1.8" stroke-linejoin="round"/></svg>
      </div>
      <div class="likes">좋아요 ${p.likes}개</div>
      <div class="cap"><b>${p.handle}</b> ${p.caption}</div>
      <div class="time">${p.time}</div>
      <div class="post-hd next"><span class="pav"></span><div><b>${p.next?.handle ?? "weekend.archive"}</b></div><span class="more">⋯</span></div>
      <div class="photo next-photo" style="background:${p.next?.css ?? "linear-gradient(150deg,#E8E3F5,#B9AEDC)"}"></div>
     </div>`,
    `.hd { padding:8px 18px 12px; font-size:22px; }
     .post-hd { display:flex; align-items:center; gap:10px; padding:10px 14px; font-size:14px; }
     .pav { width:34px; height:34px; border-radius:50%;
            background:conic-gradient(from 200deg,#f9ce34,#ee2a7b,#6228d7,#f9ce34); padding:2px; }
     .loc { font-size:11.5px; color:#667; }
     .more { margin-left:auto; font-size:18px; }
     .photo { height:390px; position:relative; display:flex; flex-direction:column;
              align-items:center; justify-content:center; gap:8px; }
     .pl { font-size:20px; font-weight:700; color:rgb(255 255 255 / .96);
           text-shadow:0 1px 12px rgb(0 0 0 / .18); letter-spacing:-.01em; }
     .ps { font-size:13px; color:rgb(255 255 255 / .85); text-shadow:0 1px 8px rgb(0 0 0 / .18); }
     .acts { display:flex; gap:16px; padding:12px 14px 8px; }
     .acts svg { width:26px; height:26px; }
     .likes { font-size:14px; font-weight:600; padding:0 14px 6px; }
     .cap { font-size:14px; line-height:1.5; padding:0 14px; }
     .time { font-size:11.5px; color:#8a94a0; padding:8px 14px 14px; }
     .post-hd.next { border-top:1px solid #f2f3f5; }
     .next-photo { height:180px; }`,
  );
}

/* ── 5. 슬랙 스레드 ─────────────────────────────── */
export function slack(p: {
  channel: string;
  messages: Array<{ name: string; color: string; time: string; html: string }>;
}) {
  return page(
    `<div class="hd"><b># ${p.channel}</b><span class="sub">멤버 14명</span></div>
     <div class="grow th">
       ${p.messages
         .map(
           (m) => `<div class="msg">
            <span class="av" style="background:${m.color}">${m.name[0]}</span>
            <div><div class="top"><b>${m.name}</b><span>${m.time}</span></div>
            <div class="body">${m.html}</div></div></div>`,
         )
         .join("")}
     </div>
     <div class="input">메시지 보내기…</div>`,
    `.sb, .sb * { color:#fff; } .sb { background:#3F1F47; }
     .hd { background:#3F1F47; color:#fff; padding:12px 18px 14px; font-size:17px; }
     .hd .sub { display:block; font-size:12px; color:#c9b8ce; margin-top:3px; }
     .th { padding:16px 16px; }
     .msg { display:flex; gap:10px; margin-bottom:18px; }
     .av { width:38px; height:38px; border-radius:8px; color:#fff; font-weight:700;
           display:flex; align-items:center; justify-content:center; flex:none; }
     .top { display:flex; gap:8px; align-items:baseline; font-size:14.5px; }
     .top span { font-size:11.5px; color:#8a94a0; }
     .body { font-size:14.5px; line-height:1.55; margin-top:3px; color:#222; }
     .body .mention { color:#0b4f8f; background:#e8f2fb; border-radius:3px; padding:0 3px; }
     .body .code { font-family:ui-monospace,monospace; font-size:12.5px; background:#f6f3f6;
                   border:1px solid #e3dde3; border-radius:4px; padding:0 4px; color:#c2185b; }
     .input { margin:0 14px 28px; border:1.5px solid #d6d0d6; border-radius:10px;
              padding:12px 14px; color:#9aa; font-size:14px; }`,
  );
}

/* ── 6. 쇼핑 상품 ─────────────────────────────── */
export function shop(p: {
  brand: string;
  name: string;
  price: string;
  coupon: string;
  colors: string[];
  photoCss: string;
}) {
  return page(
    `<div class="photo" style="background:${p.photoCss}">
       <div class="dress"></div>
     </div>
     <div class="grow body">
       <div class="coupon">${p.coupon}</div>
       <div class="brand">${p.brand}</div>
       <h1>${p.name}</h1>
       <div class="price">${p.price}</div>
       <div class="opt">색상 <span>${p.colors.map((c) => `<i title="${c}"></i>`).join("")}</span>
         <em>${p.colors.join(" · ")}</em></div>
       <div class="rev">리뷰 128 ★ 4.8</div>
     </div>
     <div class="cta"><span class="wish">♡</span><button>구매하기</button></div>`,
    `.photo { height:420px; position:relative; display:flex; align-items:center; justify-content:center; }
     .dress { width:150px; height:280px; background:linear-gradient(180deg,#F4EEE2,#EDE2CC);
              clip-path:polygon(35% 0, 65% 0, 72% 12%, 60% 22%, 78% 92%, 65% 100%, 35% 100%, 22% 92%, 40% 22%, 28% 12%);
              box-shadow:0 22px 40px rgb(90 70 40 / .18); }
     .body { padding:18px 20px; }
     .coupon { background:#FFF0EC; color:#D9480F; font-size:12.5px; font-weight:700;
               padding:8px 12px; border-radius:8px; display:inline-block; }
     .brand { color:#8a94a0; font-size:13px; margin-top:14px; }
     h1 { font-size:19px; margin-top:4px; font-weight:600; }
     .price { font-size:22px; font-weight:800; margin-top:10px; }
     .opt { margin-top:16px; font-size:13.5px; color:#556; display:flex; gap:8px; align-items:center; }
     .opt span { display:flex; gap:6px; }
     .opt i { width:20px; height:20px; border-radius:50%; border:1px solid #ddd; display:block; }
     .opt i:first-child { background:#F3EAD8; } .opt i:last-child { background:#9CAF88; }
     .opt em { font-style:normal; color:#99a; font-size:12px; }
     .rev { margin-top:12px; font-size:13px; color:#667; }
     .cta { display:flex; gap:12px; padding:14px 18px 32px; border-top:1px solid #f0f1f3; }
     .wish { width:52px; height:52px; border:1px solid #ddd; border-radius:12px; display:flex;
             align-items:center; justify-content:center; font-size:22px; color:#889; }
     button { flex:1; background:#111; color:#fff; border:none; border-radius:12px;
              font-size:16.5px; font-weight:700; }`,
  );
}

/* ── 7. 예매/티켓 오픈 ─────────────────────────────── */
export function booking(p: {
  site: string;
  title: string;
  subtitle: string;
  openLabel: string;
  openValue: string;
  notice: string[];
  heroCss: string;
  cta: string;
}) {
  return page(
    `<div class="site">${p.site}</div>
     <div class="hero" style="background:${p.heroCss}">
       <div class="ht">${p.title}</div>
       <div class="hs">${p.subtitle}</div>
     </div>
     <div class="grow body">
       <div class="open"><span>${p.openLabel}</span><b>${p.openValue}</b></div>
       ${p.notice.map((n) => `<div class="ni">· ${n}</div>`).join("")}
     </div>
     <div class="cta"><button>${p.cta}</button></div>`,
    `.site { padding:10px 20px 12px; font-size:18px; font-weight:800; letter-spacing:-.02em; }
     .hero { height:300px; display:flex; flex-direction:column; justify-content:flex-end;
             padding:26px 24px; }
     .ht { color:#fff; font-size:27px; font-weight:800; line-height:1.25;
           text-shadow:0 2px 18px rgb(0 0 0 / .25); }
     .hs { color:rgb(255 255 255 / .88); font-size:14px; margin-top:8px;
           text-shadow:0 1px 10px rgb(0 0 0 / .25); }
     .body { padding:20px; }
     .open { background:#F5F1FF; border:1px solid #E4DBFF; border-radius:12px; padding:16px 18px;
             display:flex; justify-content:space-between; align-items:center; font-size:14.5px; }
     .open b { color:#5B3FD1; font-size:16px; }
     .ni { font-size:13.5px; color:#667; margin-top:12px; line-height:1.5; }
     .cta { padding:14px 18px 32px; }
     button { width:100%; height:54px; background:#5B3FD1; color:#fff; border:none;
              border-radius:14px; font-size:16.5px; font-weight:700; }`,
  );
}

/* ── 8. 포스터 (공모전) ─────────────────────────────── */
export function poster(p: {
  kicker: string;
  title: string;
  lines: string[];
  footer: string;
}) {
  return page(
    `<div class="grow poster">
       <div class="kicker">${p.kicker}</div>
       <h1>${p.title}</h1>
       <div class="orb"></div><div class="orb b"></div>
       <div class="lines">${p.lines.map((l) => `<div>${l}</div>`).join("")}</div>
       <div class="foot">${p.footer}</div>
     </div>`,
    `body { background:#101423; }
     .sb, .sb * { color:#fff; }
     .poster { position:relative; padding:60px 32px; color:#fff; overflow:hidden; }
     .kicker { font-size:14px; letter-spacing:.35em; color:#8fa3ff; font-weight:600; }
     h1 { font-size:42px; line-height:1.22; margin-top:18px; font-weight:800; letter-spacing:-.02em; }
     .orb { position:absolute; width:260px; height:260px; border-radius:50%;
            background:radial-gradient(circle at 35% 30%, #7f8cff, #4338ca 70%);
            filter:blur(2px); opacity:.85; right:-70px; top:290px; }
     .orb.b { width:130px; height:130px; left:-40px; top:480px;
              background:radial-gradient(circle at 35% 30%, #fda4af, #be185d 75%); }
     .lines { position:relative; margin-top:230px; font-size:15.5px; line-height:2.1; color:#dbe2ff; }
     .foot { position:absolute; bottom:44px; left:32px; font-size:12px; color:#7c86a8;
             letter-spacing:.12em; }`,
    true,
  );
}

/* ── 9. 코드/터미널 ─────────────────────────────── */
export function code(p: {
  title: string;
  theme: "dark" | "light";
  lines: Array<{ text: string; kind?: "err" | "cmd" | "out" | "cmt" | "hl" }>;
}) {
  const dark = p.theme === "dark";
  return page(
    `<div class="hd"><span class="dots"><i></i><i></i><i></i></span><b>${p.title}</b></div>
     <div class="grow term">${p.lines
       .map((l) => `<div class="ln ${l.kind ?? ""}">${l.text || "&nbsp;"}</div>`)
       .join("")}</div>`,
    `body { background:${dark ? "#1B1E28" : "#FBFBFA"}; }
     .sb, .sb * { color:${dark ? "#fff" : "#111"}; }
     .hd { display:flex; align-items:center; gap:12px; padding:12px 18px;
           border-bottom:1px solid ${dark ? "#2A2E3B" : "#ECECEA"};
           color:${dark ? "#B8BECD" : "#556"}; font-size:13.5px; }
     .dots { display:flex; gap:6px; }
     .dots i { width:11px; height:11px; border-radius:50%; display:block; }
     .dots i:nth-child(1){background:#FF5F57} .dots i:nth-child(2){background:#FEBC2E} .dots i:nth-child(3){background:#28C840}
     .term { padding:18px 18px; font-family:ui-monospace,"SF Mono",Menlo,monospace;
             font-size:12.8px; line-height:1.85; color:${dark ? "#C9D1E3" : "#333"}; }
     .ln { white-space:pre-wrap; word-break:break-all; }
     .ln.cmd { color:${dark ? "#7EE0A3" : "#0A7B4B"}; font-weight:600; }
     .ln.err { color:#F87171; }
     .ln.out { color:${dark ? "#8B93A7" : "#778"}; }
     .ln.cmt { color:${dark ? "#5C6478" : "#99a"}; font-style:italic; }
     .ln.hl { background:${dark ? "#2C3040" : "#FFF3C4"}; border-radius:4px; padding:1px 6px;
              display:inline-block; }`,
    dark,
  );
}

/* ── 10. 아티클/책/노트 ─────────────────────────────── */
export function article(p: {
  outlet: string;
  title: string;
  paras: string[];
  serif?: boolean;
  table?: { headers: string[]; rows: string[][] };
  quote?: string;
}) {
  return page(
    `<div class="hd">${p.outlet}</div>
     <div class="grow art ${p.serif ? "serif" : ""}">
       <h1>${p.title}</h1>
       ${p.quote ? `<blockquote>${p.quote}</blockquote>` : ""}
       ${p.paras.map((t) => `<p>${t}</p>`).join("")}
       ${
         p.table
           ? `<table><tr>${p.table.headers.map((h) => `<th>${h}</th>`).join("")}</tr>
              ${p.table.rows.map((r) => `<tr>${r.map((c) => `<td>${c}</td>`).join("")}</tr>`).join("")}</table>`
           : ""
       }
     </div>`,
    `body { background:${p.serif ? "#FAF6EE" : "#fff"}; }
     .hd { padding:10px 22px 14px; font-size:15px; font-weight:700; color:#445;
           border-bottom:1px solid ${p.serif ? "#EDE5D3" : "#f0f1f3"}; }
     .art { padding:26px 24px; }
     h1 { font-size:23px; line-height:1.4; letter-spacing:-.01em; }
     p { font-size:15px; line-height:1.85; color:#2c2c34; margin-top:16px; }
     .serif h1, .serif p, .serif blockquote { font-family:"Apple SD Gothic Neo", serif; }
     .serif p { color:#3a3428; }
     blockquote { margin-top:20px; padding:18px 20px; background:rgb(0 0 0 / .035);
                  border-left:3px solid #B49AFF; font-size:16.5px; line-height:1.8; color:#333; }
     table { width:100%; border-collapse:collapse; margin-top:18px; font-size:13px; }
     th { text-align:left; color:#778; font-weight:600; padding:8px 6px; border-bottom:1.5px solid #dde; }
     td { padding:9px 6px; border-bottom:1px solid #eef; color:#334; }`,
  );
}
