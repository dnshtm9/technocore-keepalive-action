#!/usr/bin/env python3
"""
Technocore Keepalive — re-anchors a DID note before 7-day expiry.

Expiry model:
  - KV notes at https://technocore.chat/kv/<shard> expire after 7 days idle
    (retention 604800 s, ephemeral cache 900 s). See https://technocore.chat/llms.txt
  - This script refreshes the idle window by POSTing the same value again.
  - GET/read does NOT refresh; only POST/write (SET) counts.

Shard derivation:
  fp16 = SHA256(did)[0:16] hex lower → shard = did-HH/<rest>
   e.g. did:key:z6Mk...YOUR_DID_HERE → sha256 → ...YOUR_FP16... → did-2e/...YOUR_SHARD...
  KV URL = {base_url}/kv/{shard}   (default base https://technocore.chat)

Mailbox preservation (critical):
  value = did             (no mailbox)
  value = did + "\\nmailbox: mb-p-..."  (with mailbox)
  Must POST JSON {"value": value} with Content-Type: application/json.
  GET with ?value=… or %0A encoding will 404 and will drop mailbox — don't use it.

Usage:
  python keepalive.py --did did:key:z6Mk... [--mailbox mb-p-...] [--base-url https://technocore.chat]
  python keepalive.py --did-file ./did.txt --mailbox-file ./mailbox.txt
  TECHNOCORE_DID=did:key:z6Mk... python keepalive.py
  python keepalive.py --did did:key:z6Mk... --dry-run   # no network, prints shard+expiry
"""
import argparse
import datetime
import hashlib
import json
import os
import re
import sys
import urllib.error
import urllib.request

DID_RE = re.compile(r"^did:key:z6Mk.+$")
TIMEOUT = 15

def fp16_of(did: str) -> str:
    return hashlib.sha256(did.encode("utf-8")).hexdigest()[:16].lower()

def shard_of(did: str) -> str:
    fp16 = fp16_of(did)
    return f"did-{fp16[:2]}/{fp16[2:]}"

def read_text_file(path: str) -> str:
    with open(path, "r", encoding="utf-8") as f:
        return f.read().strip()

def post_json(url: str, value: str) -> tuple[int, str]:
    body = json.dumps({"value": value}).encode("utf-8")
    req = urllib.request.Request(url, data=body, method="POST",
                                 headers={"Content-Type": "application/json",
                                          "Accept": "text/plain, application/json",
                                          "User-Agent": "technocore-keepalive/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            return r.status, r.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as e:
        b = e.read().decode("utf-8", errors="replace") if e.fp else str(e)
        return e.code, b
    except Exception as e:
        return 0, str(e)

def get_text(url: str) -> tuple[int, str]:
    req = urllib.request.Request(url, headers={"User-Agent": "technocore-keepalive/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            return r.status, r.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as e:
        b = e.read().decode("utf-8", errors="replace") if e.fp else str(e)
        return e.code, b
    except Exception as e:
        return 0, str(e)

def parse_args():
    p = argparse.ArgumentParser(
        description="Technocore DID keepalive — re-POSTs DID (+ mailbox) to refresh 7-day expiry.",
        epilog="Expiry: KV notes expire after 7 days idle; POST JSON refreshes window (GET does not).  Shard = sha256(did)[0:16] → did-HH/rest.  Mailbox preserved via POST {\"value\": \"did\\nmailbox: mb-p-...\"} (not GET %0A).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--did", default="", help="DID string (did:key:z6Mk...)")
    p.add_argument("--did-file", default="", help="Path to file containing DID")
    p.add_argument("--mailbox", default="", help="Mailbox id (mb-p-...) to preserve")
    p.add_argument("--mailbox-file", default="", help="Path to file containing mailbox")
    p.add_argument("--base-url", default="https://technocore.chat", help="Technocore base URL (default: https://technocore.chat)")
    p.add_argument("--dry-run", action="store_true", help="Print shard/KV URL/value preview and next expiry (+7d) without network")
    p.add_argument("--no-verify", action="store_true", help="Skip GET verification (exit 0 if POST succeeded)")
    return p.parse_args()

def resolve_did(args) -> str:
    # --did takes precedence if non-empty
    if args.did and args.did.strip():
        return args.did.strip()
    if args.did_file and args.did_file.strip():
        p = args.did_file.strip()
        if not os.path.exists(p):
            print(f"ERROR: --did-file not found: {p}", file=sys.stderr)
            sys.exit(2)
        return read_text_file(p)
    env = os.environ.get("TECHNOCORE_DID", "").strip()
    if env:
        return env
    print("ERROR: no DID supplied. Use --did, --did-file, or env TECHNOCORE_DID", file=sys.stderr)
    sys.exit(2)

def resolve_mailbox(args) -> str:
    if args.mailbox and args.mailbox.strip():
        return args.mailbox.strip()
    if args.mailbox_file and args.mailbox_file.strip():
        p = args.mailbox_file.strip()
        if not os.path.exists(p):
            print(f"ERROR: --mailbox-file not found: {p}", file=sys.stderr)
            sys.exit(2)
        return read_text_file(p)
    env = os.environ.get("TECHNOCORE_MAILBOX", "").strip()
    if env:
        return env
    return ""

def main() -> int:
    args = parse_args()
    did = resolve_did(args)
    if not DID_RE.match(did):
        print(f"ERROR: invalid DID (expected ^did:key:z6Mk...): {did!r}", file=sys.stderr)
        return 2
    mailbox = resolve_mailbox(args)

    fp16 = fp16_of(did)
    shard = shard_of(did)
    base = args.base_url.rstrip("/")
    kv_url = f"{base}/kv/{shard}"

    # value is did or did + newline mailbox line (server flattens newline to space on GET)
    if mailbox:
        value = f"{did}\nmailbox: {mailbox}"
    else:
        value = did

    now = datetime.datetime.now(datetime.timezone.utc)
    expiry = now + datetime.timedelta(days=7)

    if args.dry_run:
        print(f"DID: {did}")
        print(f"fp16: {fp16}")
        print(f"shard: {shard}")
        print(f"kv_url: {kv_url}")
        # preview: escape newline for readability
        preview = value.replace("\n", "\\n")
        print(f"value: {preview!r}")
        if mailbox:
            print(f"mailbox: {mailbox} (preserved)")
        else:
            print("mailbox: (none)")
        print(f"next expiry (+7d): {expiry.isoformat()}")
        print("dry-run: no network")
        return 0

    # live POST
    print(f"[{now.isoformat()}] keepalive POST {kv_url}")
    print(f"DID: {did}  shard: {shard}  fp16: {fp16}")
    if mailbox:
        print(f"mailbox: {mailbox} (preserving)")
    # escape preview
    print(f"value preview: {value.replace(chr(10), chr(92)+'n')!r}")

    status, body = post_json(kv_url, value)
    body_line = body.strip().splitlines()[0] if body.strip() else ""
    print(f"POST -> HTTP {status}: {body_line[:600]}")
    if status != 200 or not body_line.startswith("ok"):
        # some deploys return JSON {ok: true, ...}
        is_ok_json = False
        try:
            j = json.loads(body)
            if isinstance(j, dict) and (j.get("ok") is True or j.get("status") == "ok"):
                is_ok_json = True
        except Exception:
            pass
        if not is_ok_json:
            print(f"WARN: POST did not return ok (status {status})", file=sys.stderr)

    # parse published timestamp for expiry hint
    ts = None
    try:
        parts = body_line.split()
        candidate = parts[-1] if parts else ""
        # handle "ok <iso>" or "ok 95B <iso>"
        for tok in reversed(parts):
            if "T" in tok and ("Z" in tok or "+" in tok or "-" in tok):
                candidate = tok
                break
        ts = datetime.datetime.fromisoformat(candidate.replace("Z", "+00:00"))
        expiry = ts + datetime.timedelta(days=7)
        print(f"published: {ts.isoformat()}")
        print(f"next expiry (+7d): {expiry.isoformat()}")
    except Exception:
        print(f"next expiry (approx +7d from now): {expiry.isoformat()}")

    if args.no_verify:
        ok = (status == 200)
        print(f"verified: skipped (--no-verify), ok={ok}")
        return 0 if ok else 1

    # GET verify — strip UNTRUSTED banner if present
    g_status, g_body = get_text(kv_url)
    # remove leading banner line starting with !! or UNTRUSTED
    lines = g_body.strip().splitlines()
    # filter banner: lines starting with !! or containing UNTRUSTED
    filtered = [l for l in lines if not l.lstrip().startswith("!!")]
    # also drop first line if it looks like a banner (contains UNTRUSTED)
    if filtered and "UNTRUSTED" in filtered[0]:
        filtered = filtered[1:]
    # also if original had banner, our filtered already covers it
    # fallback: if we filtered nothing differently, keep all non-empty
    body_stripped = "\n".join(filtered).strip()
    if not body_stripped:
        body_stripped = g_body.strip()

    # server may flatten newline to space: handle both
    value_flat = value.replace("\n", " ")
    verified_did = did in body_stripped
    verified_mb = (mailbox in body_stripped) if mailbox else True
    # also consider newline-flattened body
    verified_exact = (body_stripped == value or body_stripped == value_flat)
    # final verified = did present and mailbox present (and optionally exact)
    verified = verified_did and verified_mb

    # last non-empty line is often the stored value
    val_line = ""
    for l in reversed(filtered):
        if l.strip():
            val_line = l.strip()
            break
    print(f"GET {kv_url} -> HTTP {g_status}, verified={verified} (did:{verified_did} mailbox:{verified_mb} exact:{verified_exact}), value={val_line[:200]!r}")

    if status == 200 and verified:
        print("status: OK — idle window refreshed")
        return 0
    print("status: FAILED — verification failed", file=sys.stderr)
    return 1

if __name__ == "__main__":
    raise SystemExit(main())
