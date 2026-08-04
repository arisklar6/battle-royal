# Zero Sum: coach-mode local play. One browser tab (the cockpit) holds the
# spectator, your team panel, the sponsor console, and the analyst desk.
#
#   powershell -ExecutionPolicy Bypass -File scripts\run_match.ps1
#   powershell ... -File scripts\run_match.ps1 -Port 8400 -Matches 3
#
# Flow: the server starts and waits (up to 10 min) for all 16 seats. The
# cockpit's setup wizard writes coach_policy.json via POST /coach; this
# script waits for that file, then launches 14 baseline bots plus YOUR
# team's two bots running the coached policy. All 16 seats stay AI: you
# coach, the bots execute.
#
# ONE match by default — nothing keeps running after it ends. Pass
# -Matches N to play a set, or -Matches 0 to loop until you close the
# window (the coaching cycle: play, read the result, edit the plan).

param(
  [int]$Port = 8321,
  # NB: not named $Matches — that is a PowerShell automatic variable that
  # any -match operation would clobber. -Matches still works as an alias.
  [Alias('Matches')]
  [int]$MatchCount = 1,    # 1 = single match; 0 = loop until window closed
  [string]$Config = ''     # defaults to configs\coached_match.json
)

$root = Split-Path $PSScriptRoot -Parent
$server = Join-Path $root "game\server.exe"
$bot = Join-Path $root "player\baseline.exe"
$config = if ($Config) { $Config } else { Join-Path $root "configs\coached_match.json" }
$coachFile = Join-Path $root "coach_policy.json"

if (-not (Test-Path $server)) { throw "game\server.exe missing - compile it first (see README)" }
if (-not (Test-Path $bot)) { throw "player\baseline.exe missing - compile it first (see README)" }

$match = 0
$opened = $false
while ($true) {
  $match++
  Write-Host ""
  Write-Host "=== MATCH $match ==="
  $env:ZERO_SUM_LOCAL = "1"    # enables /coach for the cockpit
  $proc = Start-Process -FilePath $server -WorkingDirectory $root `
    -ArgumentList "--port:$Port", "--config-path:$config" -PassThru
  Start-Sleep -Seconds 2

  if (-not $opened) {
    Start-Process "http://127.0.0.1:$Port/client/cockpit"
    $opened = $true
    Write-Host "Cockpit: http://127.0.0.1:$Port/client/cockpit"
    Write-Host "Pick your team and policy in the browser - the match starts once you do."
  }

  # wait for the coach plan (the cockpit writes it via POST /coach)
  $waited = 0
  while (-not (Test-Path $coachFile)) {
    if ($proc.HasExited) { Write-Host "server exited during setup"; exit 1 }
    if ($waited -eq 0) { Write-Host "waiting for your setup in the cockpit..." }
    Start-Sleep -Seconds 1
    $waited++
    if ($waited -ge 570) {
      Write-Host "no setup after 9.5 min - starting with all-baseline seats"
      break
    }
  }

  $coachSlots = @()
  if (Test-Path $coachFile) {
    try {
      $plan = Get-Content $coachFile -Raw | ConvertFrom-Json
      $ti = [int][char]$plan.team[0] - 65
      # parens are load-bearing: PowerShell's comma binds tighter than '*',
      # so @(2*$ti, 2*$ti+1) parses as 2 * ($ti,2) * $ti + 1 and throws
      $coachSlots = @((2 * $ti), (2 * $ti + 1))
      Write-Host "coaching team $($plan.team) (slots $($coachSlots -join ', '))"
    } catch { Write-Host "coach_policy.json unreadable - all-baseline match" }
  }

  foreach ($slot in 0..15) {
    $env:COWORLD_PLAYER_WS_URL = "ws://127.0.0.1:$Port/player?slot=$slot&token=t$slot"
    if ($coachSlots -contains $slot) {
      $env:COACH_POLICY_FILE = $coachFile
      $env:COACH_SLOT = "$slot"
    } else {
      $env:COACH_POLICY_FILE = ""
      $env:COACH_SLOT = ""
    }
    Start-Process -FilePath $bot -WorkingDirectory $root -WindowStyle Hidden
  }
  Remove-Item Env:COWORLD_PLAYER_WS_URL -ErrorAction SilentlyContinue
  Remove-Item Env:COACH_POLICY_FILE -ErrorAction SilentlyContinue
  Remove-Item Env:COACH_SLOT -ErrorAction SilentlyContinue

  Write-Host "match running - watch the cockpit. Replay bundle lands in results\ when it ends."
  $proc.WaitForExit()
  Write-Host "match $match over - artifacts in results\ (results.json, chat_transcript.txt, events.json)."

  if ($MatchCount -gt 0 -and $match -ge $MatchCount) {
    Write-Host "Done. Play again with the same command;"
    Write-Host "add -Matches 0 if you want a continuous coaching loop."
    break
  }
  Write-Host "next match in 3s - close this window to stop."
  Start-Sleep -Seconds 3
}

# bots exit on their own "final" message, but never leave strays behind
Get-Process baseline -ErrorAction SilentlyContinue | Stop-Process -Force
Get-Process server -ErrorAction SilentlyContinue |
  Where-Object { $_.Path -eq $server } | Stop-Process -Force
Write-Host "all Zero Sum processes stopped."
