#Requires -Version 5.1
<#
.SYNOPSIS
    Build and deploy the market-bot to the VM.

.DESCRIPTION
    Cross-compiles the bot for Linux/amd64, uploads the binary and item data
    via SCP, applies the k8s manifest, and rolls out the Deployment.

    On Windows the server typically runs in a Hyper-V VM. Find its IP with:
        Get-VM | Select-Object Name, @{n='IP';e={($_ | Get-VMNetworkAdapter).IPAddresses[0]}}

    Credentials and connection details are stored in .deploy-config (gitignored).
    Run with -Setup on first use, or any time you need to reconfigure.

.PARAMETER VmIp
    IP address of the server VM. Defaults to DUNE_VM_IP in .deploy-config or env.

.PARAMETER Setup
    Run the interactive setup wizard and exit (does not deploy).

.EXAMPLE
    .\deploy.ps1 -Setup
    .\deploy.ps1
    .\deploy.ps1 -VmIp 172.28.144.1
#>
param(
    [string]$VmIp = "",
    [switch]$Setup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir    = $PSScriptRoot
$VmUser       = "dune"
$RemoteDir    = "/opt/market-bot"
$DeployConfig = Join-Path $ScriptDir ".deploy-config"

# ── Load .deploy-config into process env (never overwrites already-set vars) ──
function Import-DeployConfig {
    if (-not (Test-Path $DeployConfig)) { return }
    foreach ($line in (Get-Content $DeployConfig)) {
        $line = $line.Trim()
        if ($line -match '^#' -or $line -eq '') { continue }
        if ($line -match '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
            $k = $Matches[1]; $v = $Matches[2]
            if (-not [System.Environment]::GetEnvironmentVariable($k, 'Process')) {
                [System.Environment]::SetEnvironmentVariable($k, $v, 'Process')
            }
        }
    }
}

# ── Upsert a key in .deploy-config ────────────────────────────────────────────
function Export-ConfigValue {
    param([string]$Key, [string]$Value)
    $lines = @()
    if (Test-Path $DeployConfig) {
        $lines = Get-Content $DeployConfig | Where-Object { $_ -notmatch "^$([regex]::Escape($Key))=" }
    }
    $lines += "${Key}=${Value}"
    $lines | Set-Content $DeployConfig
}

# ── Find SSH key from candidate locations ─────────────────────────────────────
function Resolve-SshKey {
    $candidates = @(
        (Join-Path $ScriptDir "sshKey"),
        (Join-Path $env:USERPROFILE ".ssh\dune"),
        (Join-Path $env:USERPROFILE ".ssh\id_ed25519"),
        (Join-Path $env:USERPROFILE ".ssh\id_rsa")
    )
    foreach ($p in $candidates) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

# ── Interactive setup wizard ──────────────────────────────────────────────────
function Invoke-Setup {
    Write-Host ""
    Write-Host "=== deploy setup ===" -ForegroundColor Cyan
    Write-Host ""

    # 1. SSH key
    Write-Host "Checking for SSH key..."
    $keyPath = $env:SSH_KEY
    if ($keyPath -and -not (Test-Path $keyPath)) { $keyPath = $null }
    if (-not $keyPath) { $keyPath = Resolve-SshKey }
    if (-not $keyPath) {
        Write-Host "  x not found (checked ./sshKey, ~/.ssh/dune, ~/.ssh/id_ed25519, ~/.ssh/id_rsa)" -ForegroundColor Yellow
        $keyPath = Read-Host "  Path to SSH private key"
        if (-not $keyPath) { throw "SSH key is required" }
        if (-not (Test-Path $keyPath)) { throw "Key not found: $keyPath" }
    } else {
        Write-Host "  v SSH key: $keyPath" -ForegroundColor Green
    }
    Export-ConfigValue "SSH_KEY" $keyPath
    $env:SSH_KEY = $keyPath
    Write-Host ""

    # 2. VM IP
    Write-Host "VM connection:"
    $ip = $env:DUNE_VM_IP
    if (-not $ip) {
        try {
            $hvIp = Get-VM | Get-VMNetworkAdapter |
                    Where-Object { $_.IPAddresses } |
                    Select-Object -ExpandProperty IPAddresses |
                    Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } |
                    Select-Object -First 1
            if ($hvIp) {
                $ip = $hvIp
                Write-Host "  Hyper-V detected: $ip"
            }
        } catch {}
    }
    $prompt = if ($ip) { "  VM IP address [$ip]" } else { "  VM IP address" }
    $input = Read-Host $prompt
    if ($input) { $ip = $input }
    if (-not $ip) { throw "VM IP is required" }
    Export-ConfigValue "DUNE_VM_IP" $ip
    $env:DUNE_VM_IP = $ip
    Write-Host ""

    # 3. Verify SSH
    Write-Host "Testing SSH connection to $ip..."
    & ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -i $keyPath "${VmUser}@${ip}" "echo ok" 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  v connected" -ForegroundColor Green
    } else {
        Write-Host "  x connection failed" -ForegroundColor Red
        Write-Host "  Check: VM reachable at $ip, key authorized for user $VmUser, passwordless sudo for kubectl"
        throw "SSH connection failed"
    }
    Write-Host ""

    # 4. Discover DB
    Write-Host "Discovering database from cluster..."
    $svcLine = & ssh -o StrictHostKeyChecking=no -i $keyPath "${VmUser}@${ip}" `
        "sudo kubectl get svc -A --no-headers 2>/dev/null | awk '`$2 ~ /db-dbdepl-svc`$/ { print; exit }'" 2>$null
    if ($svcLine) {
        $parts = ($svcLine -split '\s+', 3)
        $dbHost = "$($parts[1]).$($parts[0]).svc.cluster.local"
        Write-Host "  v DB host: $dbHost" -ForegroundColor Green
        Export-ConfigValue "DUNE_DB_HOST" $dbHost
        $env:DUNE_DB_HOST = $dbHost
    } else {
        Write-Host "  x DB service not found" -ForegroundColor Yellow
    }

    $podLine = & ssh -o StrictHostKeyChecking=no -i $keyPath "${VmUser}@${ip}" `
        "sudo kubectl get pods -A --no-headers 2>/dev/null | awk '`$2 ~ /db-dbdepl-sts-0`$/ { print; exit }'" 2>$null

    $dbUser = ""; $dbPass = ""; $dbName = ""; $dbPort = ""

    if ($podLine) {
        $parts   = ($podLine -split '\s+', 3)
        $podNs   = $parts[0]; $podName = $parts[1]
        Write-Host "  v DB pod: $podName" -ForegroundColor Green

        # List battlegroups: try direct CLI, then bash -lc, then ~/.dune/*.yaml files
        Write-Host "  Listing battlegroups..."
        $bgListRaw = & ssh -o StrictHostKeyChecking=no -i $keyPath "${VmUser}@${ip}" `
            'battlegroup list 2>/dev/null || bash -lc "battlegroup list" 2>/dev/null' 2>$null
        $battlegroups = @()
        foreach ($bl in ($bgListRaw -split "`n")) {
            if ($bl -match '^\s*-\s+(.+)$') { $battlegroups += $Matches[1].Trim() }
        }
        if ($battlegroups.Count -eq 0) {
            # Fall back: enumerate ~/.dune/*.yaml filenames
            $yamlFiles = & ssh -o StrictHostKeyChecking=no -i $keyPath "${VmUser}@${ip}" `
                'for f in ~/.dune/*.yaml; do [ -f "$f" ] && basename "$f" .yaml; done' 2>$null
            foreach ($yf in ($yamlFiles -split "`n")) {
                $yf = $yf.Trim()
                if ($yf -ne '') { $battlegroups += $yf }
            }
        }
        if ($battlegroups.Count -eq 0) {
            Write-Host "  x battlegroup list returned nothing" -ForegroundColor Yellow
            $manualBg = Read-Host "  Battlegroup name (check 'battlegroup list' on the VM)"
            if ($manualBg) { $battlegroups = @($manualBg) }
        }

        $chosenBg = $null
        if ($battlegroups.Count -eq 0) {
            Write-Host "  x no battlegroups found" -ForegroundColor Yellow
        } elseif ($battlegroups.Count -eq 1) {
            $chosenBg = $battlegroups[0]
            Write-Host "  v battlegroup: $chosenBg" -ForegroundColor Green
        } else {
            Write-Host "  Available battlegroups:"
            for ($i = 0; $i -lt $battlegroups.Count; $i++) {
                Write-Host "    [$($i+1)] $($battlegroups[$i])"
            }
            $choice = Read-Host "  Choose [1-$($battlegroups.Count)]"
            if (-not $choice) { $choice = "1" }
            $idx = [int]$choice - 1
            if ($idx -ge 0 -and $idx -lt $battlegroups.Count) {
                $chosenBg = $battlegroups[$idx]
            } else {
                $chosenBg = $battlegroups[0]
            }
            Write-Host "  v battlegroup: $chosenBg" -ForegroundColor Green
        }

        # Read credentials from ~/.dune/<battlegroup>.yaml (only source — never use superuser from printenv)
        if ($chosenBg) {
            $bgYaml = & ssh -o StrictHostKeyChecking=no -i $keyPath "${VmUser}@${ip}" `
                "cat ~/.dune/${chosenBg}.yaml 2>/dev/null" 2>$null
            if ($bgYaml) {
                $inDeploy = $false; $linesSince = 0
                foreach ($yl in ($bgYaml -split "`n")) {
                    if ($yl -match 'deployment:') { $inDeploy = $true; $linesSince = 0 }
                    if ($inDeploy) { $linesSince++ }
                    if ($inDeploy -and $linesSince -le 20 -and $yl -match '^\s+user:\s*(.+)$') {
                        $dbUser = $Matches[1].Trim().Trim('"')
                    }
                    if ($inDeploy -and $linesSince -le 20 -and $yl -match '^\s+password:\s*(.+)$') {
                        $dbPass = $Matches[1].Trim().Trim('"'); break
                    }
                }
                if ($dbPass) {
                    Write-Host "  v credentials from ~/.dune/${chosenBg}.yaml" -ForegroundColor Green
                } else {
                    Write-Host "  x battlegroup YAML found but missing password" -ForegroundColor Yellow
                }
            } else {
                Write-Host "  x battlegroup YAML not found at ~/.dune/${chosenBg}.yaml" -ForegroundColor Yellow
            }
        }

        if ($dbUser) { Export-ConfigValue "DUNE_DB_USER" $dbUser; $env:DUNE_DB_USER = $dbUser }
        if ($dbPass) { Export-ConfigValue "DUNE_DB_PASS" $dbPass; $env:DUNE_DB_PASS = $dbPass }
    } else {
        Write-Host "  x DB pod not found" -ForegroundColor Yellow
    }

    if (-not $dbUser) {
        $dbUser = Read-Host "  DB user [dune]"
        if (-not $dbUser) { $dbUser = "dune" }
        Export-ConfigValue "DUNE_DB_USER" $dbUser; $env:DUNE_DB_USER = $dbUser
    }
    if (-not $dbPass) {
        $sec = Read-Host "  DB password" -AsSecureString
        $dbPass = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
        if (-not $dbPass) { throw "DB password is required" }
        Export-ConfigValue "DUNE_DB_PASS" $dbPass; $env:DUNE_DB_PASS = $dbPass
    }

    Write-Host ""
    Write-Host "v Setup complete - config saved to .deploy-config" -ForegroundColor Green
    Write-Host ""
}

function Test-NeedsSetup {
    return (-not $env:DUNE_VM_IP -or -not $env:DUNE_DB_PASS)
}

# ── Bootstrap ─────────────────────────────────────────────────────────────────
Import-DeployConfig

if ($Setup) {
    Invoke-Setup
    exit 0
} elseif (Test-NeedsSetup) {
    Write-Host "First run: launching setup wizard. Re-run with -Setup to reconfigure." -ForegroundColor Cyan
    Invoke-Setup
}

# Resolve SSH key
$SshKey = $env:SSH_KEY
if (-not $SshKey) { $SshKey = Resolve-SshKey }
if (-not $SshKey) { throw "SSH key not found. Run .\deploy.ps1 -Setup to configure." }

# Resolve VM IP (param overrides config)
if (-not $VmIp) { $VmIp = $env:DUNE_VM_IP }
if (-not $VmIp) { throw "VM IP not set. Run .\deploy.ps1 -Setup to configure." }

Write-Host "==> Deploying to $VmIp..." -ForegroundColor Cyan

function Invoke-Ssh {
    param([string[]]$Command)
    & ssh -o StrictHostKeyChecking=no -i $SshKey "${VmUser}@${VmIp}" @Command
    if ($LASTEXITCODE -ne 0) { throw "SSH command failed (exit $LASTEXITCODE)" }
}

function Invoke-Scp {
    param([string]$Source, [string]$Destination)
    & scp -o StrictHostKeyChecking=no -i $SshKey $Source $Destination
    if ($LASTEXITCODE -ne 0) { throw "SCP failed (exit $LASTEXITCODE)" }
}

function Get-ManifestValue {
    param([string]$Key)
    $line = Get-Content (Join-Path $ScriptDir "k8s\market-bot.yaml") |
            Where-Object { $_ -match "^\s*$([regex]::Escape($Key)):\s*" } |
            Select-Object -First 1
    if (-not $line) { return "" }
    return (($line -replace '^\s*[^:]+:\s*', '') -replace '^"|"$', '')
}

function ConvertTo-YamlString {
    param([string]$Value)
    return '"' + (($Value -replace '\\', '\\') -replace '"', '\"') + '"'
}

function Set-ManifestValue {
    param([string]$Manifest, [string]$Key, [string]$Value)
    $yamlValue = ConvertTo-YamlString $Value
    $pattern = "(?m)^(\s*$([regex]::Escape($Key)):\s*).*$"
    if ($Manifest -notmatch $pattern) { throw "missing manifest key: $Key" }
    return $Manifest -replace $pattern, "`${1}${yamlValue}"
}

# ── 1. Cross-compile ──────────────────────────────────────────────────────────
Write-Host "==> Cross-compiling for Linux/amd64..." -ForegroundColor Cyan
Push-Location $ScriptDir
try {
    $env:GOOS        = "linux"
    $env:GOARCH      = "amd64"
    $env:CGO_ENABLED = "0"
    & go build -trimpath -ldflags="-s -w" -o market-bot-linux .
    if ($LASTEXITCODE -ne 0) { throw "go build failed" }
    $size = (Get-Item "market-bot-linux").Length / 1MB
    Write-Host "    built: $([math]::Round($size, 1)) MB"
} finally {
    Remove-Item Env:\GOOS, Env:\GOARCH, Env:\CGO_ENABLED -ErrorAction SilentlyContinue
    Pop-Location
}

# ── 2. Prepare remote directories ─────────────────────────────────────────────
Write-Host "==> Preparing remote directories..." -ForegroundColor Cyan
Invoke-Ssh "sudo mkdir -p ${RemoteDir}/{data,cache,bin} && sudo chown -R ${VmUser}:${VmUser} ${RemoteDir}"

# ── 3. Detect DB connection details ───────────────────────────────────────────
Write-Host "==> Detecting DB connection details from cluster..." -ForegroundColor Cyan

$DetectedDbHost = ""; $DetectedDbPort = ""
$DbNs = ""; $DbPod = ""

$svcLine = & ssh -o StrictHostKeyChecking=no -i $SshKey "${VmUser}@${VmIp}" `
    "sudo kubectl get svc -A --no-headers 2>/dev/null | awk '`$2 ~ /db-dbdepl-svc`$/ { print; exit }'" 2>$null
if ($svcLine) {
    $parts = ($svcLine -split '\s+', 3)
    $DetectedDbHost = "$($parts[1]).$($parts[0]).svc.cluster.local"
    Write-Host "    host: $DetectedDbHost"
} else {
    Write-Host "    warn: DB service not found, using DB_HOST from config"
}

$podLine = & ssh -o StrictHostKeyChecking=no -i $SshKey "${VmUser}@${VmIp}" `
    "sudo kubectl get pods -A --no-headers 2>/dev/null | awk '`$2 ~ /db-dbdepl-sts-0`$/ { print; exit }'" 2>$null
if ($podLine) {
    $parts = ($podLine -split '\s+', 3)
    $DbNs = $parts[0]; $DbPod = $parts[1]
} else {
    Write-Host "    warn: DB pod not found, skipping order cleanup"
}

$DbHost = if ($env:DUNE_DB_HOST) { $env:DUNE_DB_HOST } elseif ($DetectedDbHost) { $DetectedDbHost } else { Get-ManifestValue "DB_HOST" }
$DbPort = if ($env:DUNE_DB_PORT) { $env:DUNE_DB_PORT } elseif ($DetectedDbPort) { $DetectedDbPort } else { Get-ManifestValue "DB_PORT" }
$DbUser = if ($env:DUNE_DB_USER) { $env:DUNE_DB_USER } else { Get-ManifestValue "DB_USER" }
$DbPass = if ($env:DUNE_DB_PASS) { $env:DUNE_DB_PASS } else { Get-ManifestValue "DB_PASS" }
$DbName = Get-ManifestValue "DB_NAME"

if (-not $DbPort) { $DbPort = "15432" }
if (-not $DbName) { $DbName = "dune" }
if (-not $DbHost -or -not $DbUser -or -not $DbPass) {
    throw "could not detect complete DB credentials. Run .\deploy.ps1 -Setup to configure."
}

Write-Host "    user: $DbUser"
Write-Host "    database: $DbName"
Write-Host "    port: $DbPort"
Write-Host "    password: detected"

# ── 4. Drop existing bot orders ───────────────────────────────────────────────
Write-Host "==> Dropping existing bot orders..." -ForegroundColor Cyan
if ($DbNs -and $DbPod) {
    $sql = @"
WITH bot AS (SELECT id FROM dune.actors WHERE class = 'Revy' LIMIT 1),
del_orders AS (
  DELETE FROM dune.dune_exchange_orders
  WHERE owner_id = (SELECT id FROM bot) AND is_npc_order = TRUE
  RETURNING item_id
),
del_items AS (
  DELETE FROM dune.items
  WHERE id IN (SELECT item_id FROM del_orders WHERE item_id IS NOT NULL)
  RETURNING id
)
SELECT (SELECT COUNT(*) FROM del_orders) AS orders_deleted,
       (SELECT COUNT(*) FROM del_items)  AS items_deleted;
"@
    $sql | & ssh -o StrictHostKeyChecking=no -i $SshKey "${VmUser}@${VmIp}" `
        "sudo kubectl exec -n $DbNs $DbPod -i -- psql -U $DbUser -h localhost -p $DbPort -d $DbName"
} else {
    Write-Host "    warn: DB pod not found, skipping order cleanup."
}

# ── 5. Upload binary ──────────────────────────────────────────────────────────
Write-Host "==> Uploading binary..." -ForegroundColor Cyan
Invoke-Scp (Join-Path $ScriptDir "market-bot-linux") "${VmUser}@${VmIp}:/tmp/market-bot-new"
Invoke-Ssh "sudo mv /tmp/market-bot-new ${RemoteDir}/bin/market-bot && sudo chmod +x ${RemoteDir}/bin/market-bot"

# ── 6. Upload item data ───────────────────────────────────────────────────────
Write-Host "==> Uploading item data..." -ForegroundColor Cyan
Invoke-Scp (Join-Path $ScriptDir "item-data.json") "${VmUser}@${VmIp}:${RemoteDir}/data/item-data.json"

# ── 7. Apply k8s manifest ─────────────────────────────────────────────────────
Write-Host "==> Applying k8s manifests..." -ForegroundColor Cyan
$manifest = Get-Content (Join-Path $ScriptDir "k8s\market-bot.yaml") -Raw
$manifest = Set-ManifestValue $manifest "DB_HOST" $DbHost
$manifest = Set-ManifestValue $manifest "DB_PORT" $DbPort
$manifest = Set-ManifestValue $manifest "DB_USER" $DbUser
$manifest = Set-ManifestValue $manifest "DB_PASS" $DbPass
$manifest = Set-ManifestValue $manifest "DB_NAME" $DbName
$manifest | & ssh -o StrictHostKeyChecking=no -i $SshKey "${VmUser}@${VmIp}" "sudo kubectl apply -f -"
if ($LASTEXITCODE -ne 0) { throw "kubectl apply failed" }

# ── 8. Rollout ────────────────────────────────────────────────────────────────
Write-Host "==> Restarting deployment..." -ForegroundColor Cyan
Invoke-Ssh "sudo kubectl rollout restart deployment/market-bot -n dune-market-bot"
& ssh -o StrictHostKeyChecking=no -i $SshKey "${VmUser}@${VmIp}" `
    "sudo kubectl rollout status deployment/market-bot -n dune-market-bot --timeout=90s" 2>&1 | Out-Host

# ── 9. Logs ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "==> Logs:" -ForegroundColor Cyan
Invoke-Ssh "sudo kubectl logs -n dune-market-bot -l app=market-bot --tail=40"
