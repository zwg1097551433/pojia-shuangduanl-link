# start-remote-tunnel.ps1 (v2) — public access for the phone over ANY network.
#
# Why v2: v1 rewrote the Host header back to the LAN address
# (--http-host-header). DSH's /api request-trust fence requires
# Origin == Host when a browser sends Origin, so every /api call and the
# WebSocket failed with 403. Correct approach: keep the public Host as-is and
# teach DSH to trust that authority (--trusted-host), which makes Host, Origin
# and the auth cookie all agree on the public domain.
param(
  [int]$Port = 5288,
  [string]$BindIp = "",
  [string]$DshHome = "C:\Users\10975\.dsh"
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$cf   = Join-Path $here 'bin\cloudflared.exe'
$log  = Join-Path $here 'tunnel.log'
$urlOut = Join-Path $here 'phone-url-remote.txt'
$localUrlFile = Join-Path $here "phone-url-$Port.txt"

if (-not (Test-Path $cf)) { throw "cloudflared.exe missing at $cf" }
if (-not $BindIp) {
  $BindIp = (Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
    Sort-Object -Property SkipAsSource, InterfaceMetric |
    Select-Object -First 1).IPAddress
}
if (-not $BindIp) { throw "No LAN IPv4 address found. Pass -BindIp <your.ip>." }

# ---- 1. make sure a local web instance exists (its token will be replaced in step 3)
if (-not (Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)) {
  Write-Host "dsh web not listening on $Port - starting it..." -ForegroundColor Yellow
  & (Join-Path $here 'start-phone-web.ps1') -Port $Port -BindIp $BindIp -DshHome $DshHome
}

# ---- 2. start cloudflared with the ORIGINAL Host (no --http-host-header)
Get-CimInstance Win32_Process -Filter "Name='cloudflared.exe'" -ErrorAction SilentlyContinue |
  ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {} }
Start-Sleep -Milliseconds 800
if (Test-Path $log) { Remove-Item $log -Force }

$runner = Join-Path $here "run-tunnel-$Port.cmd"
$cfLine = "`"$cf`" tunnel --url http://${BindIp}:${Port} --no-autoupdate --logfile `"$log`" --loglevel info"
Set-Content -Path $runner -Encoding Default -Value @('@echo off', $cfLine)
Invoke-CimMethod -ClassName Win32_Process -MethodName Create `
  -Arguments @{ CommandLine = 'cmd.exe /c ""' + $runner + '""' } | Out-Null

$domain = $null
for ($i = 0; $i -lt 90; $i++) {
  Start-Sleep -Milliseconds 1000
  if (Test-Path $log) {
    $m = Select-String -Path $log -Pattern 'https://([a-z0-9-]+\.trycloudflare\.com)' -ErrorAction SilentlyContinue |
      Select-Object -First 1
    if ($m) { $domain = $m.Matches[0].Groups[1].Value; break }
  }
}
if (-not $domain) { throw "cloudflared did not publish a URL. See $log" }
Write-Host "public host: $domain" -ForegroundColor Cyan

# ---- 3. restart the web instance WITH that authority trusted
Write-Host "restarting dsh web with --trusted-host $domain ..." -ForegroundColor Yellow
& (Join-Path $here 'start-phone-web.ps1') -Port $Port -BindIp $BindIp -DshHome $DshHome -TrustedHost @($domain) |
  Out-Null

$localUrl = (Get-Content $localUrlFile -Raw).Trim()
if ($localUrl -notmatch '\?token=([A-Za-z0-9_\-]+)') { throw "no token in $localUrlFile" }
$token = $Matches[1]
$remote = "https://$domain/?token=$token"

# ---- 4. verify: index + one /api call with browser-like Origin
$ok = $false
for ($i = 1; $i -le 8; $i++) {
  $s = New-Object Microsoft.PowerShell.Commands.WebRequestSession
  try {
    $r = Invoke-WebRequest $remote -WebSession $s -UseBasicParsing -TimeoutSec 20 -MaximumRedirection 5
    if ($r.StatusCode -ne 200) { continue }
    $body = '{"type":"client-request","rpcId":"probe","method":"directoryPicker/list","payload":{"args":[{}]}}'
    $hdr = @{ 'Origin' = "https://$domain"; 'Content-Type' = 'application/json'; 'Referer' = "https://$domain/" }
    $apiStatus = 0
    try {
      $a = Invoke-WebRequest "https://$domain/api/directoryPicker/list" -Method Post -Body $body -Headers $hdr `
        -WebSession $s -UseBasicParsing -TimeoutSec 20
      $apiStatus = $a.StatusCode
    } catch {
      $resp = $_.Exception.Response
      if ($resp) { $apiStatus = [int]$resp.StatusCode }
    }
    if ($apiStatus -ne 403 -and $apiStatus -ne 401) { $ok = $true; break }
    Write-Host "  attempt ${i}: index 200 but /api returned $apiStatus (fence still rejecting)" -ForegroundColor DarkYellow
  } catch {
    Start-Sleep -Seconds 5
  }
}

Set-Content -Path $urlOut -Value $remote -Encoding UTF8

Write-Host ""
if ($ok) {
  Write-Host "PUBLIC TUNNEL OK - index 200 and /api accepted (no 403)." -ForegroundColor Green
} else {
  Write-Host "Tunnel is up but /api still fails the trust fence." -ForegroundColor Red
  Write-Host "Check: the web instance must be started with --trusted-host $domain" -ForegroundColor Red
  Write-Host "  log: $(Join-Path $here "web-lan-$Port.log")" -ForegroundColor Red
}
Write-Host "  $remote" -ForegroundColor Cyan
Write-Host ""
Write-Host "saved to: $urlOut"
