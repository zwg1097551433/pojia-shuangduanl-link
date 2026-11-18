# stop-remote-tunnel.ps1 — stop the Cloudflare quick tunnel (keeps dsh web running)
$ErrorActionPreference = 'SilentlyContinue'
Get-CimInstance Win32_Process -Filter "Name='cloudflared.exe'" |
  Where-Object { $_.CommandLine -match 'trycloudflare|--url' } |
  ForEach-Object {
    try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop; "stopped cloudflared pid $($_.ProcessId)" } catch { "could not stop $($_.ProcessId)" }
  }
if (-not (Get-Process cloudflared -ErrorAction SilentlyContinue)) { "no cloudflared running" }
