#!/usr/bin/env bash
# Technocore Keepalive — bash+curl for Linux cron / GitHub runner (ubuntu)
# Usage: keepalive.sh "did:key:z6Mk..." [mailbox]
# Env: BASE_URL (default https://technocore.chat)
set -euo pipefail
DID="${1:-}"
MBOX="${2:-}"
BASE_URL="${BASE_URL:-https://technocore.chat}"
if [[ -z "$DID" ]]; then
  echo "Usage: $0 \"did:key:z6Mk...\" [mailbox]" >&2
  echo "  or: BASE_URL=https://technocore.chat $0 \"did:key:z6Mk...\" \"mb-p-...\"" >&2
  exit 2
fi
if [[ ! "$DID" =~ ^did:key:z6Mk ]]; then
  echo "ERROR: invalid DID: $DID" >&2
  exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 required for safe JSON encoding" >&2
  exit 2
fi
# shard via python3 (required — fail-fast above)
SHARD=$(python3 -c "import hashlib,sys; h=hashlib.sha256(sys.argv[1].encode()).hexdigest()[:16].lower(); print(f'did-{h[:2]}/{h[2:]}')" "$DID")
KV_URL="$BASE_URL/kv/$SHARD"
if [[ -n "$MBOX" ]]; then
  VALUE_JSON=$(python3 -c "import json,sys; print(json.dumps({\"value\": sys.argv[1]+\"\nmailbox: \"+sys.argv[2]}))" "$DID" "$MBOX")
  echo "mailbox: $MBOX (preserving)"
else
  VALUE_JSON=$(python3 -c "import json,sys; print(json.dumps({\"value\": sys.argv[1]}))" "$DID")
  echo "mailbox: (none)"
fi
echo "DID: $DID"
echo "shard: $SHARD"
echo "kv_url: $KV_URL"
echo "POST JSON: $KV_URL  payload=$VALUE_JSON"
RESP=$(curl -sS -X POST -H "Content-Type: application/json" -d "$VALUE_JSON" "$KV_URL" || true)
echo "POST -> $RESP"
GET_BODY=$(curl -sS "$KV_URL" || true)
echo "GET $KV_URL -> $(echo "$GET_BODY" | head -c 400)"
# verify: strip banner !! line
FILTERED=$(echo "$GET_BODY" | grep -v "^!!" | tr -d '\r')
if echo "$FILTERED" | grep -qF "$DID"; then V_DID=true; else V_DID=false; fi
if [[ -n "$MBOX" ]]; then
  if echo "$FILTERED" | grep -qF "$MBOX"; then V_MB=true; else V_MB=false; fi
else
  V_MB=true
fi
if [[ "$V_DID" == true && "$V_MB" == true ]]; then VERIFIED=true; else VERIFIED=false; fi
echo "verified: $VERIFIED (did:$V_DID mailbox:$V_MB)"
# expiry hint +7d
if command -v python3 >/dev/null 2>&1; then
  python3 -c "import datetime; print('next expiry (+7d):', (datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(days=7)).isoformat())"
else
  date -u -d "+7 days" 2>/dev/null || date -u -v+7d 2>/dev/null || echo "next expiry: +7d from now"
fi
if [[ "$VERIFIED" == true ]]; then echo "status: OK"; exit 0; else echo "status: FAILED" >&2; exit 1; fi
