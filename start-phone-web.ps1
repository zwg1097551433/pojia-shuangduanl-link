# start-phone-web.ps1 — boot a LAN-bound dsh web instance for the phone.
# No admin needed (Windows Firewall is off on this host; if you turn it on,
# run once as admin: New-NetFirewallRule -DisplayName "dsh phone web" -Direction Inbound -Protocol TCP -LocalPort 5288 -Action Allow)
param(
  [int]$Port = 5288,
  [string]$BindIp = "",
  [string]$DshHome = "C:\Users\10975\.dsh",
  [string[]]$TrustedHost = @()
)

$ErrorActionPreference = 'Stop'
$exe = 'F:\deepseek\DeepSeek Harness.exe'
$cli = 'F:\deepseek\resources\app\dsh\node_modules\@deepseek-ai\dsh\lib\bin.js'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$log  = Join-Path $here "web-lan-$Port.log"
$urlFile = Join-Path $here "phone-url-$Port.txt"

if (-not (Test-Path $exe)) { throw "DSH exe not found: $exe" }
if (-not (Test-Path $cli)) { throw "DSH CLI not found: $cli" }

if (-not $BindIp) {
  $BindIp = (Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
    Sort-Object -Property SkipAsSource, InterfaceMetric |
    Select-Object -First 1).IPAddress
}
if (-not $BindIp) { throw "No LAN IPv4 address found. Pass -BindIp <your.ip>." }

# Kill only a previous instance bound to THIS port (never touch other ports / the desktop app).
Get-CimInstance Win32_Process -Filter "Name='DeepSeek Harness.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -match 'bin\.js' -and $_.CommandLine -match '\bweb\b' -and $_.CommandLine -match "--port\s+$Port\b" } |
  ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop; "stopped old pid $($_.ProcessId) on port $Port" } catch {} }

# Launch fully detached: a generated .cmd runner started through WMI. The child
# never inherits this console, so the script returns instead of hanging on a pipe.
# Extra authorities for the /api browser-trust fence (needed behind a tunnel).
$thArgs = ''
if ($TrustedHost.Count -gt 0) {
  foreach ($h in $TrustedHost) { if ($h) { $thArgs += " --trusted-host $h" } }
}
$runner = Join-Path $here "run-web-$Port.cmd"
$lines = @(
  '@echo off',
  'set ELECTRON_RUN_AS_NODE=1',
  "set DSH_HOME=$DshHome",
  "`"$exe`" `"$cli`" web --host $BindIp --port $Port --no-open$thArgs > `"$log`" 2>&1"
)
Set-Content -Path $runner -Value $lines -Encoding Default
$cmdLine = 'cmd.exe /c ""' + $runner + '""'
Invoke-CimMethod -ClassName Win32_Process -MethodName Create `
  -Arguments @{ CommandLine = $cmdLine } | Out-Null

$url = $null
for ($i = 0; $i -lt 40; $i++) {
  Start-Sleep -Milliseconds 500
  if (Test-Path $log) {
    $hit = Select-String -Path $log -Pattern 'https?://\S+\?token=\S+' -ErrorAction SilentlyContinue |
      Select-Object -First 1
    if ($hit) { $url = $hit.Matches[0].Value.Trim(); break }
  }
}
if (-not $url) { throw "dsh web did not print a token URL. See $log and $log.err" }

Set-Content -Path $urlFile -Value $url -Encoding UTF8
if ($Port -eq 5288) { Set-Content -Path (Join-Path $here 'phone-url.txt') -Value $url -Encoding UTF8 }
Write-Host ""
Write-Host "dsh web is up (fully armor-broken: same patches + prompt-inject.md as desktop)." -ForegroundColor Green
Write-Host "Open this on the phone (same Wi-Fi):" -ForegroundColor Yellow
Write-Host "  $url" -ForegroundColor Cyan
Write-Host ""
Write-Host "Saved to: $urlFile"
Write-Host "Token rotates every restart - re-run this script and reopen the fresh URL."
