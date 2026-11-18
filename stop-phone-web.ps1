# stop-phone-web.ps1 — stop the LAN-bound dsh web instance started by start-phone-web.ps1
$ErrorActionPreference = 'SilentlyContinue'
Get-CimInstance Win32_Process -Filter "Name='DeepSeek Harness.exe'" |
  Where-Object { $_.CommandLine -match 'bin\.js' -and $_.CommandLine -match '\bweb\b' } |
  ForEach-Object {
    try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop; "stopped pid $($_.ProcessId)" } catch { "could not stop $($_.ProcessId): $($_.Exception.Message)" }
  }
$conn = Get-NetTCPConnection -State Listen -LocalPort 5288 -ErrorAction SilentlyContinue
if (-not $conn) { "port 5288 is free" } else { "port 5288 still listening (pid $($conn.OwningProcess))" }
