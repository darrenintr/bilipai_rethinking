<#
.SYNOPSIS
  Smoke test for the Paladala Portal Worker. Sends a signed report and
  verifies it appears in /api/errors.

.DESCRIPTION
  Reads HMAC_SECRET from `worker/.dev.vars` (or $env:HMAC_SECRET),
  generates a fake report, computes HMAC-SHA256(ts + "." + body) and
  POSTs to the local Worker. Expects wrangler dev to be running.

.EXAMPLE
  .\smoke-test.ps1
  .\smoke-test.ps1 -WorkerUrl http://127.0.0.1:8787
#>

param(
  [string]$WorkerUrl = 'http://127.0.0.1:8787',
  [int]$Repeat = 1
)

$ErrorActionPreference = 'Stop'

# 1. Read HMAC_SECRET
$devVarsPath = Join-Path $PSScriptRoot '..\worker\.dev.vars'
if (-not (Test-Path $devVarsPath)) {
  throw "Missing $devVarsPath - copy .dev.vars.example to .dev.vars and set HMAC_SECRET."
}
$secret = (Get-Content $devVarsPath | Where-Object { $_ -match '^HMAC_SECRET=' }) -replace '^HMAC_SECRET=', ''
if (-not $secret) { throw 'HMAC_SECRET is empty in .dev.vars' }

Write-Host "  HMAC secret: $($secret.Substring(0, [Math]::Min(8, $secret.Length)))..." -ForegroundColor DarkGray
Write-Host "  Worker:      $WorkerUrl" -ForegroundColor DarkGray

# 2. Health check
Write-Host "`n>> Health check ..." -ForegroundColor Cyan
$health = Invoke-RestMethod -Uri "$WorkerUrl/health" -Method Get
Write-Host "   $health" -ForegroundColor DarkGray

# 3. Build a fake report
$body = @{
  app_build   = '0.5.22.322'
  app_version = '0.5.22'
  os_version  = 'iOS 18.5 (simulator)'
  error_class = 'SmokeTestError'
  message     = 'Smoke test from smoke-test.ps1 at ' + (Get-Date -Format 'o')
  device_model = 'iPad13,4'
  locale      = 'zh-HK'
  session_id  = [Guid]::NewGuid().ToString()
  stacktrace  = "SmokeTestError: simulated failure`n  at ViewController.viewDidLoad (file:///src/Views/HomeViewController.swift:42:13)`n  at AppDelegate.application(_:didFinishLaunchingWithOptions:) (file:///src/AppDelegate.swift:88:7)"
  raw         = @{
    build = '0.5.22.322'
    phase = 'release'
    diagnostics = 'placeholder'
  }
} | ConvertTo-Json -Depth 8 -Compress

Write-Host "`n>> Sending $Repeat report(s) ..." -ForegroundColor Cyan
$reportIds = @()
for ($i = 1; $i -le $Repeat; $i++) {
  $ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $msg = "$ts.$body"

  $hmac = [System.Security.Cryptography.HMACSHA256]::new(
    [Text.Encoding]::UTF8.GetBytes($secret)
  )
  $mac = $hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($msg))
  $sig = ([BitConverter]::ToString($mac)).Replace('-', '').ToLower()

  $headers = @{
    'Content-Type' = 'application/json'
    'X-Timestamp'  = $ts.ToString()
    'X-Signature'  = $sig
  }

  try {
    $resp = Invoke-RestMethod -Uri "$WorkerUrl/v1/report" `
      -Method Post -Headers $headers -Body $body
    Write-Host "   [$i/$Repeat] report_id=$($resp.report_id) dedup=$($resp.dedup)" -ForegroundColor Green
    $reportIds += $resp.report_id
  } catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
    $respBody = $reader.ReadToEnd()
    Write-Host "   [$i/$Repeat] FAILED: HTTP $statusCode - $respBody" -ForegroundColor Red
    throw
  }
}

# 4. Verify via /api/errors
Write-Host "`n>> Verifying via /api/errors ..." -ForegroundColor Cyan
$list = Invoke-RestMethod -Uri "$WorkerUrl/api/errors?limit=10" -Method Get
$totalShown = $list.reports.Count
Write-Host "   /api/errors returned $totalShown reports (next_cursor: $($list.next_cursor))" -ForegroundColor DarkGray

$found = $list.reports | Where-Object { $reportIds -contains $_.id }
if ($found) {
  Write-Host "   OK: all $Repeat report(s) found" -ForegroundColor Green
  $found | ForEach-Object {
    Write-Host "     #$($_.id) [$($_.error_class)] $($_.message)" -ForegroundColor DarkGray
  }
} else {
  Write-Host "   FAIL: reports not found in /api/errors!" -ForegroundColor Red
  Write-Host "     expected ids: $($reportIds -join ', ')" -ForegroundColor DarkGray
  Write-Host "     got ids:      $(($list.reports | ForEach-Object { $_.id }) -join ', ')" -ForegroundColor DarkGray
  exit 1
}

Write-Host "`nSmoke test passed." -ForegroundColor Green
