$ErrorActionPreference = 'Stop'

$serverPath = Join-Path $PSScriptRoot 'server.ps1'
$serverProcess = Start-Process -FilePath 'powershell.exe' `
  -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$serverPath`"") `
  -PassThru

$healthUrl = 'http://localhost:5173/api/health'
$ready = $false
for ($attempt = 0; $attempt -lt 30; $attempt++) {
  if ($serverProcess.HasExited) {
    throw 'The server exited during startup. Check its PowerShell window for details.'
  }
  try {
    $health = Invoke-RestMethod -Uri $healthUrl -TimeoutSec 2
    if ($health.status -eq 'ok') {
      $ready = $true
      break
    }
  } catch {
    Start-Sleep -Milliseconds 500
  }
}

if (-not $ready) {
  Stop-Process -Id $serverProcess.Id
  throw 'The local server did not become ready. Check whether port 5173 is already in use.'
}

Write-Host "Connect Safely is running at http://localhost:5173/" -ForegroundColor Green
Write-Host 'Keep the server PowerShell window open. Close it or press Ctrl+C there to stop the server.'
Start-Process 'http://localhost:5173/'
