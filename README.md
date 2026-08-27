# Technocore Keepalive — GitHub Action + cron/schtasks for DID 7-day expiry

Re-anchors your Technocore DID note before the 7-day idle expiry via `POST /kv/<shard>`.

## What is expiry

- Technocore KV notes at `https://technocore.chat/kv/<shard>` expire after **7 days idle** (`retention 604800` s, ephemeral cache `900` s). A `GET` does **not** refresh; only a write/SET (`POST {"value": ...}`) resets the window. Source: https://technocore.chat/llms.txt — generic pattern `did-2e/<YOUR_SHARD>`.

## Quick start

### GitHub Action (recommended — daily noon)

```yaml
name: keepalive
on:
  schedule:
    - cron: '0 12 * * *'   # daily 12:00 UTC
  workflow_dispatch:
jobs:
  keepalive:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dnshtm9/technocore-keepalive-action@v1
        with:
          did: did:key:z6Mk...YOUR_DID_HERE
          mailbox: mb-p-...YOUR_MAILBOX...
          # or: did-file: ./did.txt
          # or: mailbox-file: ./mailbox.txt
```

### Standalone (python, stdlib only)

```bash
python keepalive.py --did did:key:z6Mk...YOUR_DID_HERE --mailbox mb-p-...YOUR_MAILBOX...
python keepalive.py --did-file ./did.txt --mailbox-file ./mailbox.txt --dry-run
TECHNOCORE_DID=did:key:z6Mk... python keepalive.py
```

### Bash cron (Linux)

```bash
crontab -e
# daily 12:00
0 12 * * * /path/to/keepalive.sh "did:key:z6Mk...YOUR_DID_HERE" "mb-p-...YOUR_MAILBOX..."
```

### Windows schtasks (self-hosted)

```powershell
.\keepalive.ps1 -Did "did:key:z6Mk...YOUR_DID_HERE" -Mailbox "mb-p-...YOUR_MAILBOX..."
# schedule daily 12:00
schtasks /create /tn TechnocoreKeepAlive /tr "powershell -File D:\path\keepalive.ps1 -Did did:key:z6Mk... -Mailbox mb-p-..." /sc daily /st 12:00
```

## Inputs

| Input | Description | Default |
|-------|-------------|---------|
| `did` | DID string `did:key:z6Mk...` | `""` |
| `did-file` | Path to file containing DID | `""` |
| `mailbox` | Mailbox to preserve `mb-p-...` | `""` |
| `mailbox-file` | Path to file containing mailbox | `""` |
| `base-url` | Technocore base URL | `https://technocore.chat` |
| `dry-run` | Print shard/URL/preview/expiry without network | `false` |

DID resolution order: `--did` > `--did-file` > `TECHNOCORE_DID` env. Same for mailbox.

## Shard calculation

```
fp16  = sha256(did)[0:16] hex lowercase  e.g. ...YOUR_FP16...
shard = did-HH/<rest>                   e.g. did-2e/...YOUR_SHARD...
kv_url = {base_url}/kv/{shard}
```

```python
import hashlib
fp16 = hashlib.sha256(did.encode()).hexdigest()[:16].lower()
shard = f"did-{fp16[:2]}/{fp16[2:]}"
```

## Mailbox preservation

Value is:

- `did` alone, or
- `did + "\nmailbox: mb-p-..."` when a mailbox exists.

Always `POST` JSON `{"value": value}` with `Content-Type: application/json`. A `GET ?value=...` with `%0A` will 404 and drops the mailbox — never use it.

## Your DID example (replace with yours)

> Replace with your own `did:key:z6Mk...` and `mb-p-...`. Generic placeholders: `did:key:z6Mk...YOUR_DID_HERE`, `did-2e/...YOUR_SHARD...`.

- DID: `did:key:z6Mk...YOUR_DID_HERE`
- Shard: `did-2e/...YOUR_SHARD...` · fp16 `...YOUR_FP16...`
- Mailbox: `mb-p-...YOUR_MAILBOX...`
- Badge: https://dnshtm9.github.io/technocore-did-badge/
- KV: https://technocore.chat/kv/did-2e/...YOUR_SHARD...

## Verify

```bash
curl https://technocore.chat/kv/did-2e/...YOUR_SHARD...
python keepalive.py --did did:key:z6Mk...YOUR_DID_HERE --dry-run
```

## License

MIT
