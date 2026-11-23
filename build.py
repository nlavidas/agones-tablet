"""Daily page of matches on MagentaTV satellite, in priority order, with a channel switch plan."""

import argparse
import datetime as dt
import html
import json
import re
import sys
import unicodedata
from pathlib import Path
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parent
CONFIG = json.loads((ROOT / "config.json").read_text(encoding="utf-8"))
TZ = ZoneInfo(CONFIG["timezone"])
UA = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/131.0 Safari/537.36",
    "Accept": "application/json, text/plain, */*",
    "Accept-Language": "el-GR,el;q=0.9",
    "Referer": "https://www.gazzetta.gr/tv-program",
}
DAYS = ["Δευτέρα", "Τρίτη", "Τετάρτη", "Πέμπτη", "Παρασκευή", "Σάββατο", "Κυριακή"]
MONTHS_GEN = ["Ιανουαρίου", "Φεβρουαρίου", "Μαρτίου", "Απριλίου", "Μαΐου", "Ιουνίου",
              "Ιουλίου", "Αυγούστου", "Σεπτεμβρίου", "Οκτωβρίου", "Νοεμβρίου", "Δεκεμβρίου"]
LABELS = {c["id"]: c["label"] for c in CONFIG["categories"]}
CHANNELS = [dict(c, rx=re.compile(c["pattern"], re.I)) for c in CONFIG["channels"]]
OTHER = [dict(c, rx=re.compile(c["pattern"], re.I)) for c in CONFIG.get("other_channels", [])]


def norm(text):
    text = unicodedata.normalize("NFD", text or "")
    text = "".join(c for c in text if unicodedata.category(c) != "Mn")
    return re.sub(r"\s+", " ", text.casefold().replace("ς", "σ")).strip()


GREEK = [norm(x) for x in CONFIG["greek_clubs"]]
NOT_GREEK = [norm(x) for x in CONFIG["not_greek"]]


def channel_info(name, table=None):
    name = (name or "").strip()
    for c in (table or CHANNELS):
        m = c["rx"].search(name)
        if not m:
            continue
        if "base" in c:
            n = int(next(g for g in m.groups() if g))
            return {"number": c["base"] + n, "name": c["name"].format(n=n)}
        return {"number": c.get("number"), "name": name}
    return None


def is_greek_club(team):
    t = norm(team)
    if any(x in t for x in NOT_GREEK):
        return False
    return any(t == g or t.startswith(g + " ") for g in GREEK)


def is_team(team, name):
    t, n = norm(team), norm(name)
    return (t == n or t.startswith(n + " ")) and not any(x in t for x in NOT_GREEK)


def category(ev):
    league = (ev.get("league") or {}).get("name", "").strip()
    sport = norm(ev.get("sport_name"))
    p1 = (ev.get("participant1") or {}).get("name", "")
    p2 = (ev.get("participant2") or {}).get("name", "")
    teams = [p1, p2]
    if any(x.lower() in league.lower() for x in CONFIG["exclude_league"]):
        return None
    football = sport.startswith("ποδοσφ")
    basketball = sport.startswith("μπασκ")
    greece = any(is_team(t, "ΕΛΛΑΔΑ") for t in teams)
    lg = norm(league)
    euro_cup = any(k in lg for k in ("champions league", "europa league", "conference league"))
    if football:
        if greece:
            return 1
        if any(k in league for k in CONFIG["national_football_leagues"]) and not euro_cup:
            return 2
        if lg == "super league":
            return 3
        if euro_cup:
            return 4 if any(is_greek_club(t) for t in teams) else 6
        if "κυπελλο" in lg and not any(k in lg for k in ("ισπαν", "αγγλ", "ιταλ", "γερμαν", "γαλλ", "fa cup", "copa")):
            return 5
        if lg == "super league 2":
            return 11
        if lg == "premier league":
            return 12
        if lg == "la liga" or "copa del rey" in lg or "κυπελλο ισπανιασ" in lg:
            return 13
        return None
    if basketball:
        pao = any(is_team(t, "ΠΑΝΑΘΗΝΑΙΚΟΣ") for t in teams)
        oly = any(is_team(t, "ΟΛΥΜΠΙΑΚΟΣ") for t in teams)
        if "euroleague" in lg and pao:
            return 7
        if pao and lg in ("gbl", "basket league") or (pao and "κυπελλο" in lg):
            if any(is_team(t, x) for t in teams for x in ("ΟΛΥΜΠΙΑΚΟΣ", "ΠΑΟΚ", "ΑΡΗΣ")):
                return 8
        if greece:
            return 9
        if "euroleague" in lg and oly:
            return 10
    return None


def events_for(feed, day):
    key = f"{day.day:02d}/{day.month:02d}"
    alt = f"{day.day}/{day.month}"
    block = feed.get("dates", {}).get(key) or feed.get("dates", {}).get(alt) or {}
    games = []
    for ev in block.get("events", []):
        cat = category(ev)
        if cat is None:
            continue
        names = [(c or {}).get("name") for c in (ev.get("channel1"), ev.get("channel2"))]
        chans = []
        for n in names:
            info = channel_info(n)
            if info and all(x["name"] != info["name"] for x in chans):
                chans.append(info)
        if not chans and cat in CONFIG.get("any_channel_categories", []):
            for n in names:
                info = channel_info(n, OTHER)
                if info and all(x["name"] != info["name"] for x in chans):
                    chans.append(info)
        if not chans:
            continue
        ts = ev.get("timestamp")
        if ts:
            start = dt.datetime.fromtimestamp(int(ts), TZ)
        else:
            hh, mm = map(int, ev["plainTime"].split(":"))
            start = dt.datetime.combine(day, dt.time(hh, mm), TZ)
        sport = "basketball" if norm(ev.get("sport_name")).startswith("μπασκ") else "football"
        end = start + dt.timedelta(minutes=CONFIG["minutes"][sport])
        p1 = (ev.get("participant1") or {}).get("name", "").strip()
        p2 = (ev.get("participant2") or {}).get("name", "").strip()
        match = f"{p1} - {p2}" if p1 and p2 else (ev.get("event_text") or p1 or p2).strip()
        games.append({
            "start": start, "end": end, "priority": cat, "category": LABELS[cat],
            "match": match, "competition": (ev.get("league") or {}).get("name", "").strip(),
            "sport": "Μπάσκετ" if sport == "basketball" else "Ποδόσφαιρο",
            "channels": chans,
        })
    games.sort(key=lambda g: (g["start"], g["priority"]))
    return games


def club_rank(g):
    ranks = [i for i, club in enumerate(CONFIG.get("club_order", []))
             for t in g["match"].split(" - ") if is_team(t, club)]
    return min(ranks, default=99)


def rank(g):
    return (g["priority"], g["start"], club_rank(g))


def plan(games):
    """Switch only after the current game ends; then go to the best game still on,
    waiting for a better one that starts soon, and filling a gap only with a game
    that ends before the better one starts."""
    wait = dt.timedelta(minutes=CONFIG["start_wait_minutes"])
    overrun = dt.timedelta(minutes=CONFIG["filler_overrun_minutes"])
    pending = [g for g in games if g["channels"][0]["number"] is not None]
    steps = []
    t = min((g["start"] for g in pending), default=None)
    while pending and t is not None:
        live = [g for g in pending if g["end"] > t]
        if not live:
            break
        best = min(live, key=rank)
        if best["start"] <= t + wait:
            pick = best
        else:
            fill = [g for g in live if g is not best and g["start"] < best["start"]
                    and g["end"] <= best["start"] + overrun]
            pick = min(fill, key=rank) if fill else best
        at = max(t, pick["start"])
        steps.append({"at": at, "game": pick})
        pending = [g for g in live if g is not pick]
        t = pick["end"]
    return steps


def fetch_feed():
    import requests
    r = requests.get(CONFIG["feed"], headers=UA, timeout=30)
    r.raise_for_status()
    return r.json()


def esc(s):
    return html.escape(s or "", quote=True)


def render_day(games, steps, day):
    date_label = f"{DAYS[day.weekday()]} {day.day} {MONTHS_GEN[day.month - 1]}"
    planned = {id(s["game"]): s["at"] for s in steps}
    body = [f'<div class="day" data-date="{day.isoformat()}">', f"<h1>{esc(date_label)}</h1>"]
    if steps:
        parts = [f'{s["at"]:%H:%M} <b>{s["game"]["channels"][0]["number"]}</b>' for s in steps]
        body.append('<p class="plan">Αυτόματες αλλαγές: ' + " · ".join(parts) + "</p>")
    if not games:
        body.append('<p class="empty">Σήμερα δεν υπάρχει αγώνας από τη λίστα στα κανάλια Magenta.</p>')
    else:
        body.append('<table class="games" cellspacing="0" cellpadding="0">')
        for g in games:
            nums = []
            for c in g["channels"]:
                if c["number"] is not None:
                    nums.append(f'<span class="num">{c["number"]}</span>')
                else:
                    nums.append(f'<span class="unknown">{esc(c["name"])}</span>')
            cls = "auto" if id(g) in planned else "other"
            at = planned.get(id(g))
            note = ""
            if at is not None and at > g["start"]:
                note = f'<span class="switch">αλλαγή {at:%H:%M}</span>'
            meta = " · ".join(x for x in (g["sport"], g["competition"]) if x)
            body.append(
                f'<tr class="{cls}" data-t="{g["start"]:%H:%M}" data-e="{g["end"]:%H:%M}">'
                f'<td class="time">{g["start"]:%H:%M}</td>'
                f'<td class="ch">{" ".join(nums)}</td>'
                f'<td class="what"><span class="match">{esc(g["match"])}</span> '
                f'<span class="meta">{esc(meta)}</span> {note}</td></tr>')
        body.append("</table>")
        body.append('<p class="done">Οι σημερινοί αγώνες τελείωσαν.</p>')
    body.append("</div>")
    return "\n".join(body)


def render(days_html, updated, ok):
    if not ok:
        days_html = ['<p class="empty">Το πρόγραμμα δεν είναι διαθέσιμο αυτή τη στιγμή. '
                     'Η σελίδα θα ενημερωθεί μόνη της.</p>']
    tpl = (ROOT / "template.html").read_text(encoding="utf-8")
    return (tpl.replace("{{DAYS}}", "\n".join(days_html))
               .replace("{{FOOTER}}", f"Ενημέρωση {updated} · Πηγή: gazzetta.gr"))


def day_json(games, steps):
    def g2j(g):
        return {"start": g["start"].strftime("%H:%M"), "end": g["end"].strftime("%H:%M"),
                "priority": g["priority"], "category": g["category"], "match": g["match"],
                "competition": g["competition"], "sport": g["sport"], "channels": g["channels"]}
    return {"games": [g2j(g) for g in games],
            "plan": [{"at": s["at"].strftime("%H:%M"), "number": s["game"]["channels"][0]["number"],
                      "match": s["game"]["match"]} for s in steps]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(ROOT / "site"))
    ap.add_argument("--feed-file", help="saved feed JSON, instead of fetching")
    ap.add_argument("--date", help="YYYY-MM-DD, default today in Athens")
    ap.add_argument("--now", help="HH:MM, clock time for the update stamp")
    args = ap.parse_args()

    now = dt.datetime.now(TZ)
    day = dt.date.fromisoformat(args.date) if args.date else now.date()
    try:
        feed = json.loads(Path(args.feed_file).read_text(encoding="utf-8")) if args.feed_file else fetch_feed()
        ok = True
    except Exception as e:
        print(f"feed: {e.__class__.__name__}: {e}")
        feed, ok = {}, False
    days, days_html = {}, []
    for i in range(CONFIG.get("days_ahead", 7)):
        d = day + dt.timedelta(days=i)
        g = events_for(feed, d) if ok else []
        st = plan(g)
        days[d.isoformat()] = day_json(g, st)
        days_html.append(render_day(g, st, d))
        if i == 0:
            games, steps = g, st
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    stamp = args.now or now.strftime("%H:%M")
    (out / "index.html").write_text(render(days_html, stamp, ok), encoding="utf-8")
    first = days[day.isoformat()]
    (out / "today.json").write_text(json.dumps({
        "date": day.isoformat(), "updated": now.isoformat(timespec="minutes"), "found": ok,
        "games": first["games"], "plan": first["plan"], "days": days},
        ensure_ascii=False, indent=1), encoding="utf-8")
    for g in games:
        mark = "*" if any(s["game"] is g for s in steps) else " "
        print(f'{mark} {g["start"]:%H:%M} {g["priority"]:>2} {",".join(str(c["number"]) for c in g["channels"])} '
              f'{g["match"]} | {g["competition"]}')
    for s in steps:
        print(f'  -> {s["at"]:%H:%M} {s["game"]["channels"][0]["number"]} {s["game"]["match"]}')
    if not ok:
        sys.exit(1)


if __name__ == "__main__":
    main()
