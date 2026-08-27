<#
.SYNOPSIS
  Technocore Keepalive — pwsh+curl.exe for Windows schtasks / self-hosted runner.
.DESCRIPTION
  Re-anchors a DID note before 7-day expiry via POST JSON {"value": value}.
  Preserves mailbox (did + newline "mailbox: mb-p-..."). GET does not refresh.
  Shard = sha256(did)[0:16] hex → did-HH/rest e.g. did-2e/...YOUR_SHARD...
.PARAMETER Did
  DID string (did:key:z6Mk...) or path to did.txt (if file exists it is read).
.PARAMETER Mailbox
  Mailbox id (mb-p-...) to preserve.
.PARAMETER MailboxFile
  Path to file containing mailbox (mailbox.txt).
.PARAMETER BaseUrl
  Technocore base URL (default https://technocore.chat).
.EXAMPLE
  # Example — replace with your DID and mailbox
  .\keepalive.ps1 -Did "did:key:z6Mk...YOUR_DID_HERE" -Mailbox "mb-p-...YOUR_MAILBOX..."
  .\keepalive.ps1 -Did .\did.txt -MailboxFile .\mailbox.txt
#>
param(
  [string]$Did = "",
  [string]$Mailbox = "",
  [string]$MailboxFile = "",
  [string]$BaseUrl = "https://technocore.chat"
)

$ErrorActionPreference = "Stop"

function Resolve-Did {
  param([string]$DidParam)
  if ($DidParam -and (Test-Path -LiteralPath $DidParam -PathType Leaf)) {
    return (Get-Content -LiteralPath $DidParam -Raw -Encoding utf8).Trim()
  }
  if ($DidParam -and $DidParam.Trim()) { return $DidParam.Trim() }
  if ($env:TECHNOCORE_DID -and $env:TECHNOCORE_DID.Trim()) { return $env:TECHNOCORE_DID.Trim() }
  # fallback: ./did.txt next to script
  $fallback = Join-Path $PSScriptRoot "did.txt"
  if (Test-Path -LiteralPath $fallback) { return (Get-Content -LiteralPath $fallback -Raw -Encoding utf8).Trim() }
  Write-Error "No DID supplied. Use -Did did:key:z6Mk... or -Did .\did.txt or env TECHNOCORE_DID"
  exit 2
}

function Resolve-Mailbox {
  param([string]$MbParam, [string]$MbFile)
  if ($MbParam -and $MbParam.Trim()) { return $MbParam.Trim() }
  if ($MbFile -and $MbFile.Trim()) {
    if (Test-Path -LiteralPath $MbFile) { return (Get-Content -LiteralPath $MbFile -Raw -Encoding utf8).Trim() }
    Write-Error "Mailbox file not found: $MbFile"; exit 2
  }
  if ($env:TECHNOCORE_MAILBOX -and $env:TECHNOCORE_MAILBOX.Trim()) { return $env:TECHNOCORE_MAILBOX.Trim() }
  $fallback = Join-Path $PSScriptRoot "mailbox.txt"
  if (Test-Path -LiteralPath $fallback) {
    $m = (Get-Content -LiteralPath $fallback -Raw -Encoding utf8).Trim()
    if ($m) { return $m }
  }
  return ""
}

function Get-Fp16 {
  param([string]$Text)
  # prefer python for correctness if available (matches py exactly)
  $py = Get-Command python -ErrorAction SilentlyContinue
  if (-not $py) { $py = Get-Command python3 -ErrorAction SilentlyContinue }
  if ($py) {
    try {
      $out = & $py.Source -c "import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest()[:16].lower())" $Text 2>$null
      if ($LASTEXITCODE -eq 0 -and $out) { return $out.Trim().ToLower() }
    } catch {}
  }
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $hash = $sha.ComputeHash($bytes)
    $hex = -join ($hash | ForEach-Object { $_.ToString("x2") })
    return $hex.Substring(0,16).ToLower()
  } finally { $sha.Dispose() }
}

$didVal = Resolve-Did -DidParam $Did
if (-not $didVal.StartsWith("did:key:z6Mk")) { Write-Error "Invalid DID (expected did:key:z6Mk...): $didVal"; exit 2 }
$mbVal = Resolve-Mailbox -MbParam $Mailbox -MbFile $MailboxFile

$fp16 = Get-Fp16 -Text $didVal
$shard = "did-$($fp16.Substring(0,2))/$($fp16.Substring(2))"
$BaseUrl = $BaseUrl.TrimEnd("/")
$kvUrl = "$BaseUrl/kv/$shard"

if ($mbVal) { $value = "$didVal`nmailbox: $mbVal" } else { $value = $didVal }
$preview = $value -replace "`n","\\n"
$now = [DateTime]::UtcNow
$expiry = $now.AddDays(7)

Write-Host "DID: $didVal"
Write-Host "fp16: $fp16"
Write-Host "shard: $shard"
Write-Host "kv_url: $kvUrl"
Write-Host "value: '$preview'"
if ($mbVal) { Write-Host "mailbox: $mbVal (preserving)" } else { Write-Host "mailbox: (none)" }

# POST JSON
$jsonBody = @{ value = $value } | ConvertTo-Json -Compress
Write-Host "POST JSON $kvUrl"

$curl = Get-Command curl.exe -ErrorAction SilentlyContinue
$postStatus = 0
$postBody = ""
if ($curl) {
  $tmpFile = Join-Path $env:TEMP ("tc-body-" + [Guid]::NewGuid().ToString() + ".json")
  Set-Content -LiteralPath $tmpFile -Value $jsonBody -Encoding utf8 -NoNewline
  try {
    $postBody = & curl.exe -sS -X POST -H "Content-Type: application/json" --data-binary "@$tmpFile" "$kvUrl" 2>&1 | Out-String
    $postStatus = $LASTEXITCODE
    # curl exit 0 but need HTTP check; fallback: if body starts with ok
    if ($postBody.Trim().StartsWith("ok")) { $postStatus = 200 } elseif ($postBody -match '"ok"\s*:\s*true') { $postStatus = 200 }
  } finally { Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue }
} else {
  try {
    $resp = Invoke-RestMethod -Uri $kvUrl -Method Post -Body $jsonBody -ContentType "application/json" -TimeoutSec 15
    $postBody = $resp | Out-String
    $postStatus = 200
    if ($resp -is [string] -and $resp.StartsWith("ok")) { $postBody = $resp }
  } catch {
    $postBody = $_.Exception.Message
    if ($_.Exception.Response) {
      try { $sr = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream()); $postBody = $sr.ReadToEnd() } catch {}
    }
  }
}
$firstLine = ($postBody.Trim() -split "`n")[0]
Write-Host "POST -> HTTP $postStatus`: $($firstLine.Substring(0, [Math]::Min(600, $firstLine.Length)))"
# try parse timestamp
try {
  $parts = $firstLine.Trim().Split(" ")
  $cand = $parts[-1]
  foreach ($tok in $parts) { if ($tok.Contains("T")) { $cand = $tok } }
  $ts = [DateTime]::Parse($cand.Replace("Z","+00:00"))
  $expiry = $ts.AddDays(7)
  Write-Host "published: $($ts.ToString('o'))"
  Write-Host "next expiry (+7d): $($expiry.ToString('o'))"
} catch {
  Write-Host "next expiry (approx +7d): $($expiry.ToString('o'))"
}

# GET verify
$getBody = ""
if ($curl) {
  $getBody = & curl.exe -sS "$kvUrl" 2>&1 | Out-String
} else {
  try { $getBody = Invoke-RestMethod -Uri $kvUrl -Method Get -TimeoutSec 15 | Out-String } catch { $getBody = $_.Exception.Message }
}
$getFiltered = ($getBody -split "`n" | Where-Object { -not $_.TrimStart().StartsWith("!!") }) -join "`n"
if ($getFiltered -match "UNTRUSTED" -and $getFiltered.TrimStart().StartsWith("UNTRUSTED")) {
  # already handled by !! filter; extra banner drop
}
$verifiedDid = $getFiltered.Contains($didVal)
$verifiedMb = if ($mbVal) { $getFiltered.Contains($mbVal) } else { $true }
$verified = $verifiedDid -and $verifiedMb
$valLine = ($getFiltered.Trim().Split("`n") | Where-Object { $_.Trim() } | Select-Object -Last 1)
if (-not $valLine) { $valLine = "" }
Write-Host "GET $kvUrl -> verified=$verified (did:$verifiedDid mailbox:$verifiedMb) value='$($valLine.Substring(0, [Math]::Min(200, $valLine.Length)))'"

if ($postStatus -eq 200 -and $verified) { Write-Host "status: OK — idle window refreshed"; exit 0 }
# also accept ok in body even if curl exit code non-200 mapping
if ($postBody.Trim().StartsWith("ok") -and $verified) { Write-Host "status: OK — idle window refreshed"; exit 0 }
Write-Error "status: FAILED — verification failed"
exit 1
