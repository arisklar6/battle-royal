# Zero Sum: local match: 16 AI seats, humans sponsor only.
#
#   powershell -ExecutionPolicy Bypass -File scripts\run_match.ps1
#   powershell ... -File scripts\run_match.ps1 -Port 8400 -Team C
#
# All 16 agents are AI (baseline bots as local placeholders). Humans never
# take a seat: they adopt a team (A-H) and drive its softcoin via the
# sponsor console -- one package at a time, dropped on a chosen tile.
# The seed is minted per match (recorded in the replay bundle under
# results\). Tokens here are local-play placeholders only.

param(
  [int]$Port = 8321,
  [string]$Team = 'A'
)

$root = Split-Path $PSScriptRoot -Parent
$server = Join-Path $root "game\server.exe"
$bot = Join-Path $root "player\baseline.exe"
$config = Join-Path $root "configs\audience_match.json"

if (-not (Test-Path $server)) { throw "game\server.exe missing - compile it first (see README)" }
if (-not (Test-Path $bot)) { throw "player\baseline.exe missing - compile it first (see README)" }

Start-Process -FilePath $server -WorkingDirectory $root `
  -ArgumentList "--port:$Port", "--config-path:$config"
Start-Sleep -Seconds 2

foreach ($slot in 0..15) {
  $env:COWORLD_PLAYER_WS_URL = "ws://127.0.0.1:$Port/player?slot=$slot&token=t$slot"
  Start-Process -FilePath $bot -WorkingDirectory $root -WindowStyle Hidden
}
Remove-Item Env:COWORLD_PLAYER_WS_URL -ErrorAction SilentlyContinue

$sponsorToken = "s$Team"
Start-Process "http://127.0.0.1:$Port/client/global"
Start-Process "http://127.0.0.1:$Port/client/analyst"
Start-Process "http://127.0.0.1:$Port/client/sponsor?team=$Team&token=$sponsorToken"

Write-Host "Zero Sum on port $Port - 16 AI seats, humans sponsor only."
Write-Host "Sponsor console (team $Team) opened. Other teams: http://127.0.0.1:$Port/client/sponsor?team=<A-H>&token=s<A-H>"
Write-Host "Agent cams: http://127.0.0.1:$Port/client/player?slot=N  (N = 0..15)"
