# Minimal plaintext IMAP4 server for benchmarking Inkwell's sync (not a real server).
import socketserver, re, sys, time, threading, queue, os, zlib
N = int(sys.argv[2]) if len(sys.argv) > 2 else 2000
CONDSTORE = sys.argv[3] == "1" if len(sys.argv) > 3 else True
msgs = {}
for uid in range(1, N + 1):
    body = (f"From: Sender {uid%50} <s{uid%50}@ex.com>\r\nTo: me@example.com\r\nSubject: Message {uid}\r\n"
            f"Date: Tue, 3 Jun 2025 10:22:01 +0200\r\nMessage-ID: <m{uid}@ex.com>\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n"
            + ("Hello, can you review this? " * 40) + "\r\n").encode()
    msgs[uid] = {"flags": ["\\Seen"] if uid % 3 else [], "modseq": 1, "raw": body}
state = {"modseq": 1}
changed = threading.Condition()
LATENCY = float(sys.argv[4]) if len(sys.argv) > 4 else 0
GMAIL = len(sys.argv) > 5 and sys.argv[5] == "1"
COMPRESS = os.environ.get("FAKE_COMPRESS") == "1"
def gm_category(uid):
    # Fake Gmail tabs: injected sign-in mail → updates; otherwise a fixed pattern.
    if uid > N: return "updates"
    return "promotions" if uid % 5 == 0 else "updates" if uid % 5 == 1 else "social" if uid % 5 == 2 else "primary"

class H(socketserver.StreamRequestHandler):
    deflater = None
    def w(self, s):
        b = s if isinstance(s, bytes) else s.encode()
        if self.deflater: b = self.deflater.compress(b) + self.deflater.flush(zlib.Z_SYNC_FLUSH)
        self.wfile.write(b)
    def caps(self): return "IMAP4rev1 IDLE MOVE UIDPLUS" + (" CONDSTORE" if CONDSTORE else "") + (" X-GM-EXT-1" if GMAIL else "") + (" COMPRESS=DEFLATE" if COMPRESS else "")
    def reader(self):
        # Timestamps each line on arrival; a reply is due one round trip later. Pipelined
        # commands arrive together, so they share a single round trip like on a real network.
        inflater, buf = None, b""
        while True:
            if inflater is None:
                line = self.rfile.readline()
                self.lines.put((time.time(), line))
                if not line: return
                # After COMPRESS DEFLATE everything the client sends is deflated.
                if COMPRESS and line.split(b" ", 1)[-1].strip().upper() == b"COMPRESS DEFLATE":
                    inflater = zlib.decompressobj(-15)
                continue
            data = self.rfile.read1(65536)
            if not data: self.lines.put((time.time(), b"")); return
            buf += inflater.decompress(data)
            now = time.time()
            while b"\r\n" in buf:
                line, buf = buf.split(b"\r\n", 1)
                self.lines.put((now, line + b"\r\n"))
    def handle(self):
        self.lines = queue.Queue()
        threading.Thread(target=self.reader, daemon=True).start()
        self.w(f"* OK [CAPABILITY {self.caps()}] fake ready\r\n")
        while True:
            arrived, line = self.lines.get()
            if not line: return
            line = line.decode().rstrip("\r\n")
            time.sleep(max(0, arrived + LATENCY - time.time()))
            tag, _, rest = line.partition(" ")
            cmd = rest.upper()
            if cmd.startswith("LOGIN"): self.w(f"{tag} OK [CAPABILITY {self.caps()}] logged in\r\n")
            elif cmd.startswith("CAPABILITY"): self.w(f"* CAPABILITY {self.caps()}\r\n{tag} OK\r\n")
            elif cmd.startswith("LIST"):
                for a, n in [("", "INBOX"), ("\\Sent", "Sent"), ("\\Archive", "Archive"), ("\\Trash", "Trash")]:
                    self.w(f'* LIST ({a}) "/" "{n}"\r\n')
                self.w(f"{tag} OK\r\n")
            elif cmd.startswith("SELECT") or cmd.startswith("EXAMINE"):
                box = msgs if '"INBOX"' in rest else {}
                self.box = box
                self.w(f"* {len(box)} EXISTS\r\n* OK [UIDVALIDITY 7] ok\r\n* OK [UIDNEXT {max(box or [0])+1}] ok\r\n")
                if CONDSTORE: self.w(f"* OK [HIGHESTMODSEQ {state['modseq']}] ok\r\n")
                self.w(f"{tag} OK [READ-WRITE] selected\r\n")
            elif cmd.startswith("UID SEARCH"):
                crit = rest[len("UID SEARCH "):].strip()
                gm = re.search(r'X-GM-RAW "(.*)"', crit)
                if gm:
                    cats = re.findall(r"category:(\w+)", gm.group(1))
                    m = re.search(r"UID (\d+):\*", crit)
                    lo = int(m.group(1)) if m else 1
                    hits = [u for u in sorted(self.box) if u >= lo and gm_category(u) in cats]
                elif crit.upper() == "UNSEEN":
                    hits = [u for u in sorted(self.box) if "\\Seen" not in self.box[u]["flags"]]
                else:
                    m = re.search(r"UID (\S+)", crit)
                    hits = set()
                    for part in (m.group(1) if m else "1:*").split(","):
                        a, _, b = part.partition(":")
                        lo, hi = int(a), (10**12 if b == "*" else int(b or a))
                        hits |= {u for u in self.box if lo <= u <= hi}
                    hits = sorted(hits)
                self.w("* SEARCH " + " ".join(str(u) for u in hits) + "\r\n" + f"{tag} OK\r\n")
            elif cmd.startswith("UID FETCH") or cmd.startswith("FETCH"):
                byuid = cmd.startswith("UID")
                m = re.match(r"(?:UID )?FETCH (\S+) \((.*?)\)(?: \(CHANGEDSINCE (\d+)\))?$", rest, re.I)
                rng, items, since = m.group(1), m.group(2).upper(), m.group(3)
                uids = sorted(self.box)
                sel = []
                for part in rng.split(","):
                    a, _, b = part.partition(":")
                    if byuid:
                        lo = int(a); hi = (uids[-1] if uids else 0) if b == "*" else int(b or a)
                        sel += [u for u in uids if lo <= u <= hi] or ([uids[-1]] if b == "*" and uids else [])
                    else:
                        lo = int(a); hi = len(uids) if b == "*" else int(b or a)
                        sel += uids[lo-1:hi]
                for u in sel:
                    msg = self.box[u]
                    if since and msg["modseq"] <= int(since): continue
                    seq = uids.index(u) + 1
                    parts = [f"UID {u}"]
                    if "FLAGS" in items: parts.append("FLAGS (" + " ".join(msg["flags"]) + ")")
                    if CONDSTORE and since: parts.append(f"MODSEQ ({msg['modseq']})")
                    if "INTERNALDATE" in items: parts.append('INTERNALDATE "03-Jun-2025 10:22:01 +0200"')
                    if "RFC822.SIZE" in items: parts.append(f"RFC822.SIZE {len(msg['raw'])}")
                    if "X-GM-THRID" in items: parts.append(f"X-GM-THRID {1000000 + u}")
                    out = f"* {seq} FETCH (" + " ".join(parts)
                    lits = []
                    if "BODY.PEEK[HEADER]" in items:
                        lits.append(("BODY[HEADER]", msg["raw"].split(b"\r\n\r\n")[0] + b"\r\n\r\n"))
                    pm = re.search(r"BODY\.PEEK\[\](?:<(\d+)\.(\d+)>)?", items)
                    if pm:
                        if pm.group(1): lits.append((f"BODY[]<{pm.group(1)}>", msg["raw"][int(pm.group(1)):int(pm.group(1)) + int(pm.group(2))]))
                        else: lits.append(("BODY[]", msg["raw"]))
                    self.w(out)
                    for name, data in lits:
                        self.w(f" {name} {{{len(data)}}}\r\n"); self.w(data)
                    self.w(")\r\n")
                self.w(f"{tag} OK\r\n")
            elif cmd.startswith("UID STORE"):
                m = re.match(r"UID STORE (\d+) ([+-])FLAGS\.SILENT \((.*)\)", rest, re.I)
                u, op, fl = int(m.group(1)), m.group(2), m.group(3)
                state["modseq"] += 1
                if u in self.box:
                    f = self.box[u]["flags"]
                    if op == "+" and fl not in f: f.append(fl)
                    if op == "-" and fl in f: f.remove(fl)
                    self.box[u]["modseq"] = state["modseq"]
                self.w(f"{tag} OK\r\n")
            elif cmd.startswith("IDLE"):
                # Pushes "* n EXISTS" as soon as X-INJECT adds mail, until the client sends DONE.
                self.w("+ idling\r\n"); seen = len(self.box)
                while True:
                    if len(self.box) != seen:
                        seen = len(self.box); self.w(f"* {seen} EXISTS\r\n")
                    try: self.lines.get(timeout=0.005); break
                    except queue.Empty: pass
                self.w(f"{tag} OK\r\n")
            elif cmd.startswith("X-INJECT"):
                # Test hook: a new sign-in code mail lands in INBOX.
                uid = max(msgs) + 1
                state["modseq"] += 1
                raw = (f"From: Acme <no-reply@acme.com>\r\nTo: me@example.com\r\nSubject: Your Acme sign-in code\r\n"
                       f"Date: Tue, 3 Jun 2025 10:22:01 +0200\r\nMessage-ID: <inj{uid}@acme.com>\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n"
                       f"Your verification code is {uid % 900000 + 100000}. It expires in 10 minutes.\r\n").encode()
                msgs[uid] = {"flags": [], "modseq": state["modseq"], "raw": raw}
                self.w(f"{tag} OK [UID {uid}]\r\n")
            elif cmd.startswith("X-DELETE"):
                # Test hook: another client deletes a message (UID given, or the newest).
                arg = rest[len("X-DELETE"):].strip()
                u = int(arg) if arg else max(msgs)
                msgs.pop(u, None); state["modseq"] += 1
                self.w(f"{tag} OK\r\n")
            elif cmd.startswith("COMPRESS DEFLATE") and COMPRESS:
                self.w(f"{tag} OK deflate active\r\n")
                self.deflater = zlib.compressobj(6, zlib.DEFLATED, -15)
            elif cmd.startswith("LOGOUT"): self.w(f"* BYE\r\n{tag} OK\r\n"); return
            else: self.w(f"{tag} OK\r\n")

class S(socketserver.ThreadingMixIn, socketserver.TCPServer): allow_reuse_address = True; daemon_threads = True
S(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
