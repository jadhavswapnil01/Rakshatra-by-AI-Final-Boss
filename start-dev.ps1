# i still start server using this script and the updating envs are important and as also i didnt ran docker commands yet
# ----------------------------
# AUTO DEV ENV STARTER SCRIPT (robust)
# ----------------------------

# firstly start powershell in administrator mode to avoid permission issues
# then run set-executionpolicy remotesigned and giev Y as answer
# then run this script using: .\start-dev.ps1

$BackendPath  = "C:\Dev\smart-tourist-safety-app\Backend"
$FrontendPath = "C:\Dev\smart-tourist-safety-app\Frontend\tourist_safety"
$FrontendPath_2 = "C:\Dev\smart-tourist-safety-app\authority-dashboard"



# START NGROK in external window
Write-Host "Starting ngrok in external PowerShell..."
Start-Process powershell -ArgumentList @(
    "-NoExit",
    "-Command",
    "cd '$BackendPath'; ngrok http 8000"
)

# Poll ngrok local API to get public URL
$NgrokApi = "http://127.0.0.1:4040/api/tunnels"
$NgrokUrl = $null
$tries = 0
$maxTries = 30

Write-Host "Waiting for ngrok to publish tunnels (polling $NgrokApi)..."

while (($tries -lt $maxTries) -and (-not $NgrokUrl)) {
    try {
        $resp = Invoke-RestMethod -Uri $NgrokApi -UseBasicParsing -ErrorAction Stop
        if ($resp.tunnels) {
            # prefer https tunnel
            $httpsTunnel = $resp.tunnels | Where-Object { $_.public_url -like "https:*" } | Select-Object -First 1
            $anyTunnel   = $resp.tunnels | Select-Object -First 1
            if ($httpsTunnel) { $NgrokUrl = $httpsTunnel.public_url }
            elseif ($anyTunnel) { $NgrokUrl = $anyTunnel.public_url }
        }
    } catch {
        # ngrok API not ready yet
    }
    if (-not $NgrokUrl) {
        Start-Sleep -Seconds 1
        $tries++
    }
}

if (-not $NgrokUrl) {
    Write-Host "ERROR: Could not read ngrok URL from $NgrokApi after $maxTries tries."
    Write-Host "Check the ngrok window (it may not have started or is blocked)."
    exit 1
}

Write-Host "NGROK URL FOUND: $NgrokUrl"

# ----------------------------
# 5) UPDATE .env FILE
# ----------------------------
$envPath = Join-Path $FrontendPath ".env"
$envPath_2 = Join-Path $FrontendPath_2 ".env.local"
$envPath_3 = Join-Path $FrontendPath_2 ".env.example"
$envPath_4 = Join-Path $FrontendPath_2 ".env"

if (-Not (Test-Path $envPath)) {
    Write-Host "WARNING: .env not found at $envPath. Skipping .env update."
} else {
    (Get-Content $envPath) -replace "API_BASE_URL=.*", "API_BASE_URL=$NgrokUrl" | Set-Content $envPath
    Write-Host "Updated .env at $envPath"
}

if (-Not (Test-Path $envPath_2)) {
    Write-Host "WARNING: .env.local not found at $envPath_2. Skipping .env update."
} else {
    (Get-Content $envPath_2) -replace "API_BASE_URL=.*", "API_BASE_URL=$NgrokUrl" | Set-Content $envPath_2
    Write-Host "Updated .env.local at $envPath_2"
}

if (-Not (Test-Path $envPath_3)) {
    Write-Host "WARNING: .env.example not found at $envPath_3. Skipping .env update."
} else {
    (Get-Content $envPath_3) -replace "API_BASE_URL=.*", "API_BASE_URL=$NgrokUrl" | Set-Content $envPath_3
    Write-Host "Updated .env.example at $envPath_3"
}

if (-Not (Test-Path $envPath_4)) {
    Write-Host "WARNING: .env not found at $envPath_4. Skipping .env update."
} else {
    (Get-Content $envPath_4) -replace "API_BASE_URL=.*", "API_BASE_URL=$envPath_4" | Set-Content $envPath_4
    Write-Host "Updated .env at $envPath_4"
}

# ----------------------------
# 6) UPDATE api_service.dart
# ----------------------------
$dartPath = Join-Path $FrontendPath "lib\Services\api_service.dart"

if (-Not (Test-Path $dartPath)) {
    Write-Host "WARNING: api_service.dart not found at $dartPath. Skipping dart update."
} else {
    (Get-Content $dartPath) `
        -replace "dotenv\.env\['API_BASE_URL'\] \?\? 'https://.+?'", "dotenv.env['API_BASE_URL'] ?? '$NgrokUrl'" `
        -replace "String get baseUrl2 => 'https://.+?'", "String get baseUrl2 => '$NgrokUrl'" |
        Set-Content $dartPath

    Write-Host "Updated api_service.dart at $dartPath"
}

function Wait-ForPort {
    param(
        [string]$TargetHost = "127.0.0.1",
        [int]$Port = 8545,
        [int]$TimeoutSeconds = 60
    )
    $end = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $end) {
        $r = Test-NetConnection -ComputerName $TargetHost -Port $Port -WarningAction SilentlyContinue
        if ($r.TcpTestSucceeded) { return $true }
        Start-Sleep -Seconds 1
    }
    return $false
}


Write-Host "Starting Ganache in external PowerShell..."
Start-Process powershell -ArgumentList @(
    "-NoExit",
    "-Command",
    "& 'C:/Users/swapn/CPP Dev/dtid-local/Backend/.venv/Scripts/Activate.ps1'; cd '$BackendPath'; ganache --host 127.0.0.1 --port 8545 --accounts 10 --mnemonic 'test test test test test test test test test test test junk'"
)


# give Ganache a sec to boot
Write-Host "Waiting for Ganache RPC at 127.0.0.1:8545..."
if (-not (Wait-ForPort -TargetHost '127.0.0.1' -Port 8545 -TimeoutSeconds 20)) {
    Write-Host "Warning: Ganache did not respond on 127.0.0.1:8545 within timeout. Truffle may fail."
} else {
    Write-Host "Ganache is responding."
}

# starting ipfs daemon
Write-Host "Starting IPFS daemon in external PowerShell..."
Start-Process powershell -ArgumentList @(
    "-NoExit",
    "-Command",
    "& 'C:\ipfs\ipfs.exe' daemon"
)


# TRUFFLE COMPILE + MIGRATE + START SERVER (runs in separate window, kept open)
Write-Host "Starting Truffle / migrate / Uvicorn in external PowerShell..."
Start-Process powershell -ArgumentList @(
    "-NoExit",
    "-Command",
    "& 'C:/Users/swapn/CPP Dev/dtid-local/Backend/.venv/Scripts/Activate.ps1'; cd '$BackendPath'; truffle compile; truffle migrate --network development --reset; python -m uvicorn server.main:app --workers 8 --reload --port 8000"
)





Write-Host "-----------------------------"
Write-Host "ALL SYSTEMS STARTED (or started attempts made)."
Write-Host "Ganache -> Truffle -> Uvicorn -> ngrok started."
Write-Host "NGROK public URL: $NgrokUrl"
Write-Host "-----------------------------"
