# Zero Sum: play one human seat against 15 baseline bots, locally.
#
#   powershell -ExecutionPolicy Bypass -File scripts\play_vs_bots.ps1
#   powershell ... -File scripts\play_vs_bots.ps1 -Port 8400 -HumanSlot 5
#
# Opens your tactical player client and the analyst dashboard in the
# default browser. The seed is minted per match (recorded in the replay
# bundle under results\). Tokens here are local-play placeholders only.

param(
  [int]$Port = 8321,
  [int]$HumanSlot = 0
)

$root = Split-Path $PSScriptRoot -Parent
$server = Join-Path $root "game\server.exe"
$bot = Join-Path $root "player\baseline.exe"
$config = Join-Path $root "configs\play_vs_bots.json"

if (-not (Test-Path $server)) { throw "game\server.exe missing - compile it first (see README)" }
if (-not (Test-Path $bot)) { throw "player\baseline.exe missing - compile it first (see README)" }

Start-Process -FilePath $server -WorkingDirectory $root `
  -ArgumentList "--port:$Port", "--config-path:$config"
Start-Sleep -Seconds 2

foreach ($slot in 0..15) {
  if ($slot -eq $HumanSlot) { continue }
  $env:COWORLD_PLAYER_WS_URL = "ws://127.0.0.1:$Port/player?slot=$slot&token=t$slot"
  Start-Process -FilePath $bot -WorkingDirectory $root -WindowStyle Hidden
}
Remove-Item Env:COWORLD_PLAYER_WS_URL -ErrorAction SilentlyContinue

Start-Process "http://127.0.0.1:$Port/client/player?slot=$HumanSlot&token=t$HumanSlot"
Start-Process "http://127.0.0.1:$Port/client/analyst"
Write-Host "Zero Sum on port $Port - you are P$HumanSlot. Global view: http://127.0.0.1:$Port/client/global"
