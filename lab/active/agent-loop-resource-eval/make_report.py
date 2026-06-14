"""baseline_*.json -> 사람이 눈으로 검수하는 단일 HTML 리포트.

사용:  python3 make_report.py results/baseline_YYYYMMDD_HHMMSS.json
출력:  lab/data/<json이름>.html  (screenshot 상대경로 + 원격 OG/유튜브 썸네일)
"""

import json
import sys
import html
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT_DIR = HERE.parents[1] / "data"  # lab/data


def esc(v):
    return html.escape("" if v is None else str(v))


def chip(text, cls="chip"):
    return f'<span class="{cls}">{esc(text)}</span>'


def render_findref(out):
    useful = out.get("useful")
    score = out.get("usefulness")
    badge_cls = "score-hi" if (score or 0) >= 4 else ("score-mid" if (score or 0) >= 2 else "score-lo")
    rows = ""
    for u in out.get("ranked_urls", []):
        rows += (
            '<li class="rank-row">'
            f'<span class="tier">{esc(u.get("tier_label", ""))}</span>'
            f'<a href="{esc(u.get("url"))}" target="_blank" rel="noopener">{esc(u.get("title") or u.get("url"))}</a>'
            f'<span class="rank-url">{esc(u.get("url"))}</span>'
            "</li>"
        )
    comment = out.get("comment")
    return (
        '<div class="tool tool-find">'
        '<div class="tool-head">'
        '<span class="tool-name">🔎 findReferenceUrls</span>'
        f'<span class="score {badge_cls}">usefulness {esc(score)}/5</span>'
        f'<span class="useful-flag {"ok" if useful else "no"}">{"useful" if useful else "not useful"}</span>'
        "</div>"
        + (f'<div class="comment">{esc(comment)}</div>' if comment else "")
        + f'<ol class="ranks">{rows}</ol>'
        "</div>"
    )


def render_platform(out):
    thumb = out.get("thumbnail_url")
    conf = out.get("confidence")
    img = f'<img class="og-img" src="{esc(thumb)}" loading="lazy" referrerpolicy="no-referrer" onerror="this.style.display=\'none\'">' if thumb else ""
    meta = []
    for k in ("platform", "author", "source", "status_code", "duration_seconds"):
        if out.get(k) not in (None, ""):
            meta.append(f'<span class="kv"><b>{k}</b> {esc(out.get(k))}</span>')
    final_url = out.get("final_url") or out.get("canonical_url")
    return (
        '<div class="tool tool-og">'
        '<div class="tool-head">'
        '<span class="tool-name">🌐 platformContext</span>'
        + (f'<span class="score {"score-hi" if (conf or 0) >= 0.7 else "score-mid"}">conf {conf}</span>' if conf is not None else "")
        + (f'<span class="useful-flag {"ok" if out.get("sufficient") else "no"}">{"sufficient" if out.get("sufficient") else "insufficient"}</span>')
        + "</div>"
        '<div class="og-card">'
        f"{img}"
        '<div class="og-body">'
        f'<div class="og-title">{esc(out.get("title"))}</div>'
        f'<div class="og-desc">{esc(out.get("description"))}</div>'
        + (f'<a class="og-url" href="{esc(final_url)}" target="_blank" rel="noopener">{esc(final_url)}</a>' if final_url else "")
        + f'<div class="og-meta">{"".join(meta)}</div>'
        "</div></div></div>"
    )


def render_youtube(out):
    vid = out.get("video_id")
    thumb = f"https://i.ytimg.com/vi/{vid}/hqdefault.jpg" if vid else None
    url = out.get("url")
    recovered = out.get("recovered")
    img = f'<img class="og-img" src="{esc(thumb)}" loading="lazy" referrerpolicy="no-referrer" onerror="this.style.display=\'none\'">' if thumb else ""
    cands = out.get("candidates") or []
    return (
        '<div class="tool tool-yt">'
        '<div class="tool-head">'
        '<span class="tool-name">▶️ recoverYoutubeUrl</span>'
        f'<span class="useful-flag {"ok" if recovered else "no"}">{"recovered" if recovered else "failed"}</span>'
        "</div>"
        '<div class="og-card">'
        f"{img}"
        '<div class="og-body">'
        f'<div class="og-title">{esc(out.get("recovered_title"))}</div>'
        f'<div class="og-desc">채널: {esc(out.get("recovered_channel"))}</div>'
        + (f'<a class="og-url" href="{esc(url)}" target="_blank" rel="noopener">{esc(url)}</a>' if url else "")
        + (f'<div class="og-meta"><span class="kv"><b>candidates</b> {esc(", ".join(cands))}</span></div>' if cands else "")
        + "</div></div></div>"
    )


TOOL_RENDER = {
    "findReferenceUrls": render_findref,
    "platformContext": render_platform,
    "recoverYoutubeUrl": render_youtube,
}


def render_card(r, img_rel):
    a = r.get("analysis") or {}
    intents = "".join(chip(i, "chip intent") for i in a.get("intents", []))
    entities = "".join(
        chip(f'{e.get("kind")}: {e.get("value")}', "chip ent") for e in a.get("entities", [])
    )
    needs = a.get("needs_review")
    review_badge = chip("⚠ needs review", "chip review") if needs else ""
    err = r.get("error")

    tools_html = ""
    for tc in r.get("tool_calls", []):
        fn = TOOL_RENDER.get(tc["tool"])
        if fn:
            inp = tc.get("input")
            q = ""
            if inp:
                if inp.get("queries"):
                    q = f'<div class="tool-input">queries: {esc(", ".join(inp["queries"]))}'
                    if inp.get("category"):
                        q += f' · cat={esc(inp["category"])}'
                    q += "</div>"
                elif inp.get("query"):
                    q = f'<div class="tool-input">query: {esc(inp["query"])}</div>'
                elif inp.get("url"):
                    q = f'<div class="tool-input">url: {esc(inp["url"])}</div>'
            tools_html += fn(tc.get("output") or {}) + q
    if not tools_html:
        tools_html = '<div class="no-tool">— tool 호출 없음 —</div>'

    img_src = esc(img_rel)
    return f"""
    <article class="card" data-tools="{esc(','.join(tc['tool'] for tc in r.get('tool_calls', [])))}" data-review="{1 if needs else 0}">
      <div class="card-img">
        <a href="{img_src}" target="_blank"><img src="{img_src}" loading="lazy" alt="{esc(r['file'])}"></a>
        <div class="img-cap">{esc(r['file'])}<br><span class="app">{esc(r.get('source_app'))}</span></div>
      </div>
      <div class="card-body">
        <div class="badges">{review_badge}{chip('cat: ' + str(a.get('category')), 'chip cat')}{intents}</div>
        <div class="cmp">
          <div class="cmp-col gt">
            <div class="cmp-h">GT</div>
            <div class="cmp-cat">{esc(r.get('gt_category'))}</div>
            <div class="cmp-sum">{esc(r.get('gt_summary'))}</div>
          </div>
          <div class="cmp-col pred">
            <div class="cmp-h">분석</div>
            <div class="cmp-cat">{esc(a.get('category'))}</div>
            <div class="cmp-sum">{esc(a.get('summary'))}</div>
          </div>
        </div>
        {f'<div class="entities">{entities}</div>' if entities else ''}
        {f'<div class="err">ERROR: {esc(err)}</div>' if err else ''}
        <div class="tools">{tools_html}</div>
      </div>
    </article>"""


def main():
    if len(sys.argv) < 2:
        # 기본: 가장 최근 baseline
        cands = sorted((HERE / "results").glob("baseline_*.json"))
        if not cands:
            print("결과 json 경로를 인자로 주세요.")
            sys.exit(1)
        json_path = cands[-1]
    else:
        json_path = Path(sys.argv[1])
        if not json_path.is_absolute():
            json_path = (Path.cwd() / json_path).resolve()

    data = json.loads(json_path.read_text(encoding="utf-8"))
    summary = data.get("summary", {})
    results = data.get("results", [])

    # screenshot 상대경로: lab/data/<html> 기준 -> screenshot_prod/images/<file>
    cards = "\n".join(
        render_card(r, f"screenshot_prod/images/{r['file']}") for r in results
    )

    summ_items = "".join(
        f'<div class="stat"><div class="stat-v">{esc(v)}</div><div class="stat-k">{esc(k)}</div></div>'
        for k, v in summary.items()
    )

    out_path = OUT_DIR / (json_path.stem + ".html")
    out_path.write_text(PAGE.format(
        title=esc(json_path.name),
        summary=summ_items,
        cards=cards,
    ), encoding="utf-8")
    print(f"wrote {out_path}")


PAGE = """<!doctype html>
<html lang="ko"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>ResourceFinder baseline — {title}</title>
<style>
  :root {{ --bg:#0f1115; --card:#181b22; --line:#272b35; --txt:#e6e8ec; --dim:#9aa3b2; --acc:#5b9dff; --gt:#7ee2a8; --pred:#ffd479; }}
  * {{ box-sizing:border-box; }}
  body {{ margin:0; background:var(--bg); color:var(--txt); font:14px/1.5 -apple-system,BlinkMacSystemFont,"Pretendard","Apple SD Gothic Neo",sans-serif; }}
  header {{ position:sticky; top:0; z-index:10; background:rgba(15,17,21,.95); backdrop-filter:blur(8px); border-bottom:1px solid var(--line); padding:14px 22px; }}
  h1 {{ font-size:16px; margin:0 0 10px; }} h1 small {{ color:var(--dim); font-weight:400; }}
  .stats {{ display:flex; gap:8px; flex-wrap:wrap; }}
  .stat {{ background:var(--card); border:1px solid var(--line); border-radius:8px; padding:6px 12px; text-align:center; min-width:74px; }}
  .stat-v {{ font-size:17px; font-weight:700; color:var(--acc); }} .stat-k {{ font-size:10px; color:var(--dim); text-transform:uppercase; letter-spacing:.3px; }}
  .filters {{ margin-top:10px; display:flex; gap:6px; flex-wrap:wrap; }}
  .filters button {{ background:var(--card); color:var(--dim); border:1px solid var(--line); border-radius:20px; padding:4px 12px; cursor:pointer; font-size:12px; }}
  .filters button.on {{ color:#fff; border-color:var(--acc); background:#1d2740; }}
  main {{ padding:22px; display:grid; grid-template-columns:repeat(auto-fill,minmax(560px,1fr)); gap:16px; }}
  .card {{ background:var(--card); border:1px solid var(--line); border-radius:12px; overflow:hidden; display:flex; }}
  .card-img {{ flex:0 0 190px; background:#000; display:flex; flex-direction:column; }}
  .card-img img {{ width:100%; height:340px; object-fit:cover; object-position:top; display:block; }}
  .img-cap {{ padding:6px 8px; font-size:11px; color:var(--dim); text-align:center; }} .img-cap .app {{ color:var(--acc); }}
  .card-body {{ flex:1; padding:12px 14px; min-width:0; }}
  .badges {{ display:flex; gap:5px; flex-wrap:wrap; margin-bottom:10px; }}
  .chip {{ font-size:11px; padding:2px 9px; border-radius:20px; background:#222733; color:var(--dim); border:1px solid var(--line); }}
  .chip.intent {{ background:#16263a; color:#9cc4ff; border-color:#2a4060; }}
  .chip.cat {{ background:#2a2436; color:#cdb6ff; }}
  .chip.review {{ background:#3a1d1d; color:#ff9a9a; border-color:#5a2a2a; }}
  .chip.ent {{ background:#1c2620; color:#9be0bf; }}
  .cmp {{ display:grid; grid-template-columns:1fr 1fr; gap:10px; }}
  .cmp-col {{ background:#10131a; border:1px solid var(--line); border-radius:8px; padding:8px 10px; }}
  .cmp-h {{ font-size:10px; font-weight:700; letter-spacing:.5px; margin-bottom:4px; }}
  .gt .cmp-h {{ color:var(--gt); }} .pred .cmp-h {{ color:var(--pred); }}
  .cmp-cat {{ font-size:12px; font-weight:600; margin-bottom:4px; }}
  .cmp-sum {{ font-size:12px; color:var(--dim); }}
  .entities {{ display:flex; gap:5px; flex-wrap:wrap; margin-top:10px; }}
  .err {{ margin-top:8px; color:#ff8a8a; font-size:12px; }}
  .tools {{ margin-top:12px; display:flex; flex-direction:column; gap:10px; }}
  .no-tool {{ color:#5b6473; font-size:12px; font-style:italic; }}
  .tool {{ border:1px solid var(--line); border-radius:8px; padding:9px 11px; background:#10131a; }}
  .tool-head {{ display:flex; align-items:center; gap:8px; flex-wrap:wrap; margin-bottom:6px; }}
  .tool-name {{ font-size:12px; font-weight:700; }}
  .score {{ font-size:10px; padding:1px 8px; border-radius:12px; font-weight:700; }}
  .score-hi {{ background:#16321f; color:#7ee2a8; }} .score-mid {{ background:#33301a; color:#ffd479; }} .score-lo {{ background:#3a1d1d; color:#ff9a9a; }}
  .useful-flag {{ font-size:10px; padding:1px 8px; border-radius:12px; }}
  .useful-flag.ok {{ background:#16321f; color:#7ee2a8; }} .useful-flag.no {{ background:#332323; color:#ff9a9a; }}
  .comment {{ font-size:12px; color:var(--dim); margin-bottom:6px; }}
  .ranks {{ margin:0; padding-left:18px; }}
  .rank-row {{ margin-bottom:5px; }} .rank-row a {{ color:var(--acc); text-decoration:none; }} .rank-row a:hover {{ text-decoration:underline; }}
  .tier {{ font-size:9px; background:#222733; color:var(--dim); padding:1px 6px; border-radius:4px; margin-right:6px; }}
  .rank-url {{ display:block; font-size:10px; color:#5b6473; }}
  .og-card {{ display:flex; gap:10px; }}
  .og-img {{ width:120px; height:90px; object-fit:cover; border-radius:6px; background:#000; flex:0 0 auto; }}
  .og-body {{ min-width:0; }}
  .og-title {{ font-size:13px; font-weight:600; }} .og-desc {{ font-size:12px; color:var(--dim); margin:3px 0; }}
  .og-url {{ font-size:11px; color:var(--acc); word-break:break-all; }}
  .og-meta {{ margin-top:5px; display:flex; gap:8px; flex-wrap:wrap; }}
  .kv {{ font-size:10px; color:var(--dim); }} .kv b {{ color:#8b93a3; }}
  .tool-input {{ font-size:10px; color:#5b6473; margin-top:5px; word-break:break-all; }}
</style></head><body>
<header>
  <h1>ResourceFinder baseline 검수 <small>{title}</small></h1>
  <div class="stats">{summary}</div>
  <div class="filters">
    <button class="on" data-f="all">전체</button>
    <button data-f="findReferenceUrls">🔎 findReference</button>
    <button data-f="platformContext">🌐 platform</button>
    <button data-f="recoverYoutubeUrl">▶️ youtube</button>
    <button data-f="review">⚠ needs review</button>
    <button data-f="notool">tool 없음</button>
  </div>
</header>
<main id="grid">{cards}</main>
<script>
const btns=[...document.querySelectorAll('.filters button')];
const cards=[...document.querySelectorAll('.card')];
btns.forEach(b=>b.onclick=()=>{{
  btns.forEach(x=>x.classList.remove('on')); b.classList.add('on');
  const f=b.dataset.f;
  cards.forEach(c=>{{
    let show=true;
    if(f==='all') show=true;
    else if(f==='review') show=c.dataset.review==='1';
    else if(f==='notool') show=!c.dataset.tools;
    else show=c.dataset.tools.split(',').includes(f);
    c.style.display=show?'':'none';
  }});
}});
</script>
</body></html>"""


if __name__ == "__main__":
    main()
