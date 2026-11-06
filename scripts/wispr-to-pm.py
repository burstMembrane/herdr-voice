#!/usr/bin/env python3
"""Sends Wispr Flow dictations that start with a wake word ("PM, ...", "hey PM", "product manager") to the PM's terminal.

Wispr Flow has no API, but it keeps each dictation in a local SQLite file. This reads that file read-only, remembers
nothing about other dictations, and forwards only text that begins with the wake word (minus the wake word).
Replies come back by hc send to this machine's voice terminal or are spoken by the PM's stop hook.

  wispr-to-pm.py              run the watcher
  wispr-to-pm.py --dry-run    print what would be sent instead of sending
  wispr-to-pm.py --db FILE    use another database (tests)
"""
import argparse, os, re, sqlite3, subprocess, sys, time, json

DB = os.path.expanduser("~/Library/Application Support/Wispr Flow/flow.sqlite")
WAKE = re.compile(r"^\s*(?:hey[,\s]+|ok(?:ay)?[,\s]+)?(?:the\s+)?(?:p\.?\s?m\.?|product manager)\b[\s,.:;!-]*(.*)$", re.I | re.S)
TAG = "[Liam, speaking by voice] "

def hc(*args):
    return subprocess.run(["hc", *args], capture_output=True, text=True, timeout=20).stdout

def find_pm():
    if os.environ.get("WISPR_PM"): return os.environ["WISPR_PM"]
    try: terms = json.loads(hc("ls", "--json")).get("terminals", [])
    except Exception: return None
    for t in terms:
        if "status" not in t: continue
        addr = t["address"]
        try: title = (json.loads(hc("get", addr, "--json")).get("title") or "").lower()
        except Exception: continue
        if "product manager" in title or title == "pm" or (t.get("name") or "").lower() == "pm": return t.get("name") or addr
    return None

def new_rows(con, seen):
    rows = con.execute("select transcriptEntityId, coalesce(nullif(formattedText,''), asrText, '') from History order by rowid desc limit 12").fetchall()
    return [(i, t) for i, t in reversed(rows) if i not in seen]

def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--db", default=DB); ap.add_argument("--dry-run", action="store_true"); ap.add_argument("--interval", type=float, default=0.7)
    a = ap.parse_args()
    con = sqlite3.connect(f"file:{a.db}?mode=ro", uri=True, timeout=2)
    seen = {i for i, _ in new_rows(con, set())}          # what was dictated before we started is not news
    me = os.environ.get("HC_TERMINAL_ID", "")
    print(f"watching {a.db}; wake words: PM / product manager{' (dry run)' if a.dry_run else ''}", flush=True)
    while True:
        try:
            for i, text in new_rows(con, seen):
                if not text.strip(): continue            # Wispr may add the row before the text is ready; look again next time
                seen.add(i)
                m = WAKE.match(text)
                if not m or not m.group(1).strip(): continue
                body = m.group(1).strip()
                msg = TAG + body + (f'\n(Reply to this with: hc send {me} "<one or two plain spoken sentences>".)' if me else "")
                if a.dry_run: print("WOULD SEND:", body, flush=True); continue
                pm = find_pm()
                if not pm: print("PM terminal not found; dropped:", body[:60], flush=True); continue
                out = hc("send", pm, msg, "--json"); print("sent to", pm, "->", out.strip()[:80], flush=True)
        except sqlite3.OperationalError as e:
            print("db busy:", e, flush=True)
        time.sleep(a.interval)

if __name__ == "__main__":
    try: main()
    except KeyboardInterrupt: pass
