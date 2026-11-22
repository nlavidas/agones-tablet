"""Big-tile TV remote for the tablet: one tap changes the MagentaTV channel through the BroadLink,
and the day's automatic switch plan runs in the background.

  python remote.py learn    record the decoder remote's keys once
  python remote.py serve    start the remote for the tablet
  python remote.py test 318 send one channel number
"""

import base64
import datetime as dt
import json
import socket
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent
CFG = json.loads((ROOT / "remote.json").read_text(encoding="utf-8"))
if len(sys.argv) > 2 and sys.argv[1] == "demo":
    CFG["today_url"] = sys.argv[2]
CODES_FILE = ROOT / "codes.json"
PAGE = (ROOT / "remote.html").read_text(encoding="utf-8")
if sys.stdout is None:
    sys.stdout = sys.stderr = open(ROOT / "remote.log", "a", encoding="utf-8", buffering=1)
LABELS = {"ok": "OK", "vol_up": "Φωνή +", "vol_down": "Φωνή −", "mute": "Σίγαση"}


class FakeDevice:
    def __init__(self):
        self.sent = []

    def send_data(self, packet):
        self.sent.append(packet)
        print("demo send", packet[:6])


def find_device(keep_trying=False):
    import broadlink
    while True:
        try:
            if CFG.get("broadlink_host"):
                dev = broadlink.hello(CFG["broadlink_host"])
            else:
                found = [d for d in broadlink.discover(timeout=6) if hasattr(d, "send_data")]
                if not found:
                    raise LookupError("no device")
                dev = found[0]
            dev.auth()
            break
        except Exception as e:
            msg = ("Δεν βρέθηκε BroadLink στο δίκτυο. Το tablet, ο υπολογιστής και το BroadLink "
                   f"πρέπει να είναι στο ίδιο Wi-Fi. ({e.__class__.__name__})")
            if not keep_trying:
                sys.exit(msg)
            print(f"{dt.datetime.now():%H:%M:%S} {msg}")
            time.sleep(30)
    print(f"BroadLink: {dev.host[0]} ({dev.model or dev.type})")
    return dev


def learn():
    import broadlink.exceptions as bx
    dev = find_device()
    codes = json.loads(CODES_FILE.read_text(encoding="utf-8")) if CODES_FILE.exists() else {}
    for key in CFG["keys_to_learn"]:
        label = LABELS.get(key, key)
        input(f"\nΠλήκτρο «{label}»: πάτα Enter, μετά σημάδεψε το τηλεκοντρόλ του αποκωδικοποιητή "
              f"στο BroadLink και πάτα μία φορά το «{label}».")
        dev.enter_learning()
        packet = None
        for _ in range(30):
            time.sleep(1)
            try:
                packet = dev.check_data()
                break
            except (bx.ReadError, bx.StorageError):
                continue
        if packet is None:
            print(f"Δεν πιάστηκε το «{label}». Ξανατρέξε το learn για να το συμπληρώσεις.")
            continue
        codes[key] = base64.b64encode(packet).decode()
        CODES_FILE.write_text(json.dumps(codes, indent=1), encoding="utf-8")
        print(f"Αποθηκεύτηκε το «{label}».")
    print("\nΤέλος. Δοκίμασε: python remote.py test 103")


class Remote:
    def __init__(self, device):
        self.dev = device
        self.codes = {k: base64.b64decode(v) for k, v in
                      json.loads(CODES_FILE.read_text(encoding="utf-8")).items()} if CODES_FILE.exists() else {}
        self.lock = threading.Lock()
        self.last = {"what": None, "at": 0.0}
        self.current = None
        self.auto = bool(CFG.get("auto_plan", True))

    def _key(self, key):
        if key not in self.codes:
            raise KeyError(key)
        self.dev.send_data(self.codes[key])

    def channel(self, number, source="tap"):
        digits = str(int(number))
        now = time.time()
        with self.lock:
            if source == "tap" and self.last["what"] == digits and now - self.last["at"] < CFG["ignore_repeat_seconds"]:
                return False
            for d in digits:
                self._key(d)
                time.sleep(CFG["digit_pause_seconds"])
            if CFG.get("send_ok_after_digits", True) and "ok" in self.codes:
                self._key("ok")
            self.last = {"what": digits, "at": time.time()}
            self.current = int(digits)
        print(f"{dt.datetime.now():%H:%M:%S} {source}: κανάλι {digits}")
        return True

    def key(self, key):
        with self.lock:
            self._key(key)
        return True


class Today:
    def __init__(self):
        self.data, self.fetched = None, 0.0

    def get(self):
        if self.data is None or time.time() - self.fetched > 600:
            try:
                url = CFG["today_url"]
                if url.startswith("http"):
                    with urllib.request.urlopen(url, timeout=20) as r:
                        self.data = json.loads(r.read().decode("utf-8"))
                else:
                    self.data = json.loads(Path(url).read_text(encoding="utf-8"))
                self.fetched = time.time()
            except Exception as e:
                print("today.json:", e.__class__.__name__)
        return self.data or {"games": [], "plan": [], "date": ""}


def auto_loop(remote, today):
    done = set()
    while True:
        data = today.get()
        now = dt.datetime.now()
        if remote.auto and data.get("date") == now.date().isoformat():
            for step in data.get("plan", []):
                key = (data["date"], step["at"], step["number"])
                hh, mm = map(int, step["at"].split(":"))
                at = now.replace(hour=hh, minute=mm, second=0, microsecond=0)
                if key not in done and at <= now < at + dt.timedelta(minutes=20):
                    done.add(key)
                    try:
                        remote.channel(step["number"], source="αυτόματο")
                    except Exception as e:
                        print("αυτόματο:", e)
                elif at + dt.timedelta(minutes=20) <= now:
                    done.add(key)
        time.sleep(20)


def make_handler(remote, today):
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def _send(self, code, body, ctype="application/json; charset=utf-8"):
            raw = body.encode("utf-8") if isinstance(body, str) else body
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def do_GET(self):
            if self.path in ("/", "/index.html"):
                return self._send(200, PAGE, "text/html; charset=utf-8")
            if self.path.startswith("/api/state"):
                return self._send(200, json.dumps({
                    "today": today.get(), "favourites": CFG["favourites"],
                    "auto": remote.auto, "current": remote.current,
                    "keys": sorted(remote.codes)}, ensure_ascii=False))
            self._send(404, "{}")

        def do_POST(self):
            parts = self.path.strip("/").split("/")
            try:
                if parts[:2] == ["api", "ch"] and parts[2].isdigit():
                    ok = remote.channel(int(parts[2]))
                    return self._send(200, json.dumps({"ok": True, "repeat": not ok}))
                if parts[:2] == ["api", "key"]:
                    remote.key(parts[2])
                    return self._send(200, '{"ok": true}')
                if parts[:2] == ["api", "auto"]:
                    remote.auto = parts[2] == "on"
                    return self._send(200, json.dumps({"ok": True, "auto": remote.auto}))
            except KeyError as e:
                return self._send(200, json.dumps({"ok": False, "missing": str(e)}))
            except Exception as e:
                return self._send(200, json.dumps({"ok": False, "error": e.__class__.__name__}))
            self._send(404, "{}")
    return H


def lan_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


def serve(demo=False):
    device = FakeDevice() if demo else find_device(keep_trying=True)
    remote = Remote(device)
    if demo and not remote.codes:
        remote.codes = {k: k.encode() for k in CFG["keys_to_learn"]}
    today = Today()
    threading.Thread(target=auto_loop, args=(remote, today), daemon=True).start()
    srv = ThreadingHTTPServer(("0.0.0.0", CFG["port"]), make_handler(remote, today))
    print(f"\nΣτο tablet άνοιξε:  http://{lan_ip()}:{CFG['port']}/\n")
    srv.serve_forever()


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "serve"
    if cmd == "learn":
        learn()
    elif cmd == "test" and len(sys.argv) > 2:
        Remote(find_device()).channel(int(sys.argv[2]), source="δοκιμή")
    elif cmd == "demo":
        serve(demo=True)
    else:
        serve()
