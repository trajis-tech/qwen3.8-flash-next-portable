# One-click portable Qwen3.8-Flash-Next (Strata NVFP4).
#
# Every step checks first and only downloads what is missing:
#   1. Strata source         -> strata-nvfp4\
#   2. Portable Python       -> strata-nvfp4\.venv\Scripts\   (python.org embeddable, no install, no registry)
#   3. Engine + model        -> strata-nvfp4\engine\, Strata-data\   (~130 GB, Strata's own resumable downloader)
#   4. Start Strata on 127.0.0.1:UpstreamPort and the gateway on HostAddress:Port
# When everything is present, nothing touches the network and it starts directly.
param(
    [string]$HostAddress = "0.0.0.0",
    [int]$Port = 8000,
    [int]$UpstreamPort = 8080,
    [string]$Family = "qwen",          # ISTA-DASLab GSQ-RCO GGUF; qwen-nvfp4-gptq etc. for NVFP4 packs
    [string]$Model = "",               # GGUF size; "" = IQ3_S for qwen (fits 64 GB RAM). Ignored for NVFP4 packs
    [int]$Context = 131072,            # 128K: agent clients (Codex etc.) outgrow 64K; 0 = let Strata pick from VRAM
    [string]$Vision = "yes",           # images on; for NVFP4 Strata maps yes -> CPU encoder (no VRAM cost)
    [string]$ClientKey = "",
    [string]$UpstreamKey = "",
    [double]$Temperature = [double]::NaN,
    [double]$TopP = [double]::NaN,
    [int]$TopK = -1,
    [double]$TemperatureCap = [double]::NaN,
    [string]$Tag = "v0.1.44.1-nvfp4.2",
    [string]$PythonVersion = "3.12.10",
    [switch]$Reinstall,
    [switch]$SetupOnly,
    [switch]$CheckOnly,
    [switch]$SetPageFile,              # set a fixed page file (admin, then reboot) instead of starting
    [string]$PageFileDrive = "",       # default: this folder's drive
    [int]$PageFileMB = 65536
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"   # Invoke-WebRequest is very slow with the progress bar on PS 5.1
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# NVFP4 packs (and qwen-q8) come in one size; GGUF families pick a size with --model.
if ($Family -match 'nvfp4|^qwen-q8$') { $Model = "" }
elseif (-not $Model -and $Family -eq "qwen") { $Model = "IQ3_S" }

$root = (Resolve-Path $PSScriptRoot).Path
$src = Join-Path $root "strata-nvfp4"
$scripts = Join-Path $src ".venv\Scripts"
$python = Join-Path $scripts "python.exe"
$dataDir = Join-Path $root "Strata-data"
$state = Join-Path $root "portable_state"
$dl = Join-Path $state "dl"
$marker = Join-Path $state "installed.json"
$configTool = Join-Path $root "portable\strata_config.py"
New-Item -ItemType Directory -Force $dl | Out-Null

function Write-Step($text) { Write-Host "-- $text" }
function Write-Warn($text) { Write-Host "!! $text" -ForegroundColor Yellow }
function Get-Stamp { Get-Date -Format "yyyyMMddHHmmss" }

function Get-File($url, $out) {
    for ($try = 1; $try -le 3; $try++) {
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile "$out.part"
            Move-Item -Force "$out.part" $out
            return
        } catch {
            Write-Warn "Download failed ($try/3): $url"
            if ($try -eq 3) { throw }
            Start-Sleep -Seconds 5
        }
    }
}

function Read-Marker {
    if (-not (Test-Path $marker)) { return $null }
    try { return Get-Content $marker -Raw -Encoding utf8 | ConvertFrom-Json } catch { return $null }
}

function Write-Marker($info) {
    $info | ConvertTo-Json | Set-Content -Encoding utf8 $marker
}

# ---- Hardware check (warnings only; the driver is the one thing that cannot be portable) ----
function Test-Hardware {
    if ($root -match '[^\x00-\x7F]') {
        Write-Warn "This folder's path has non-ASCII characters: $root"
        Write-Warn "Native engines often fail on such paths. Prefer a plain path such as D:\QwenNext."
    }
    # Hard requirement of this bundle: an NVIDIA GPU with 16 GB or more (16 GB cards report ~16300 MiB).
    $bestMiB = 0
    if (-not (Get-Command nvidia-smi -ErrorAction SilentlyContinue)) {
        Write-Warn "nvidia-smi not found: install an NVIDIA driver 580 or newer first."
    } else {
        foreach ($line in @(& nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader,nounits)) {
            $name, $mem, $driver = $line -split ",\s*"
            Write-Step "GPU: $name, $mem MiB VRAM, driver $driver"
            if ([double]($driver -replace '^(\d+\.\d+).*', '$1') -lt 580) { Write-Warn "Driver $driver is older than 580; Strata needs 580+ (CUDA 13)." }
            if ([int]$mem -gt $bestMiB) { $bestMiB = [int]$mem }
        }
    }
    if ($bestMiB -lt 15500) {
        $script:hardwareError = "This bundle needs an NVIDIA GPU with 16 GB of VRAM or more (found: $bestMiB MiB)."
        Write-Warn $script:hardwareError
    }
    $ramGiB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
    Write-Step "RAM: $ramGiB GiB"
    if ($ramGiB -lt 60) { Write-Warn "Strata needs 64 GB RAM or more." }
    elseif ($ramGiB -lt 92) { Write-Step "Below ~92 GiB RAM Strata uses low-RAM mode and reads some experts from disk; keep this folder on NVMe." }
    if ($root -match '^[A-Za-z]:') {
        $drive = $root.Substring(0, 1)
        $freeGiB = [math]::Round((Get-PSDrive $drive).Free / 1GB, 1)
        Write-Step "Free disk on ${drive}: $freeGiB GiB"
        if ($freeGiB -lt 150 -and -not (Test-Path $marker)) { Write-Warn "A model needs 90-130 GB; less than 150 GB is free." }
    } else {
        Write-Warn "This folder is on a network path; put it on a local NVMe drive."
    }
    Test-PageFile
}

# Strata needs a fixed-size page file of 65536 MB in total. System-managed files do not count
# because they may not grow in time. Settings apply only after a reboot, so compare with usage.
function Test-PageFile {
    $fixedMB = 0
    $pending = $false
    if (-not (Get-CimInstance Win32_ComputerSystem).AutomaticManagedPagefile) {
        $usage = @(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue)
        foreach ($p in @(Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue)) {
            if ($p.InitialSize -gt 0 -and $p.InitialSize -eq $p.MaximumSize) {
                $fixedMB += $p.MaximumSize
                $active = $usage | Where-Object { $_.Name -eq $p.Name } | Select-Object -First 1
                if (-not $active -or $active.AllocatedBaseSize -lt $p.MaximumSize) { $pending = $true }
            }
        }
    }
    if ($fixedMB -lt 65536) {
        Write-Warn "Strata needs a fixed 65536 MB page file (now: $fixedMB MB fixed). Run START.bat -SetPageFile, then restart Windows."
    } elseif ($pending) {
        Write-Warn "The page file is set to $fixedMB MB but not active yet: restart Windows first."
    } else {
        Write-Step "Page file: $fixedMB MB fixed"
    }
}

# ---- 1. Strata source ----
function Install-Source {
    if (Test-Path (Join-Path $src "START-HERE.bat")) { Write-Step "Strata source: present"; return }
    if (Test-Path $src) {
        # Left over from an interrupted clone or unzip; keep it aside rather than mixing versions.
        $aside = "$src.incomplete-" + (Get-Stamp)
        Write-Warn "strata-nvfp4\ is incomplete; moving it to $aside"
        Move-Item $src $aside
    }
    Write-Step "Strata source: downloading $Tag"
    if (Get-Command git -ErrorAction SilentlyContinue) {
        & git clone --depth 1 --branch $Tag https://github.com/sergqwer/strata-nvfp4 $src
        if ($LASTEXITCODE -eq 0) { return }
        Write-Warn "git clone failed; falling back to the source zip"
        if (Test-Path $src) { Move-Item $src ("$src.failed-clone-" + (Get-Stamp)) }
    }
    $zip = Join-Path $dl "strata-src-$Tag.zip"
    $tmp = Join-Path $dl ("src-" + [guid]::NewGuid().ToString("N"))
    if (-not (Test-Path $zip)) { Get-File "https://github.com/sergqwer/strata-nvfp4/archive/refs/tags/$Tag.zip" $zip }
    Expand-Archive $zip -DestinationPath $tmp
    $inner = Get-ChildItem $tmp -Directory | Select-Object -First 1
    Move-Item $inner.FullName $src
}

# ---- 2. Portable Python inside .venv\Scripts (START-HERE.bat and setup.py use whatever python is there) ----
function Install-Python {
    $venv = Join-Path $src ".venv"
    $venvCfg = Join-Path $venv "pyvenv.cfg"
    if ($Reinstall -and (Test-Path $venvCfg)) {
        $old = "$venv.system-" + (Get-Stamp)
        Write-Step "Replacing the system-Python venv with portable Python; old one kept as $old"
        Move-Item $venv $old
    }
    if (Test-Path $python) {
        & $python -c "import pip"
        if ($LASTEXITCODE -eq 0) {
            if (Test-Path $venvCfg) { Write-Warn "strata-nvfp4\.venv is a normal venv tied to this PC's Python; it breaks if the folder is moved. Use -Reinstall to replace it." }
            Write-Step "Python: present"
            return
        }
        # Interrupted install, or a venv that came from another PC: start the interpreter over.
        $broken = "$venv.broken-" + (Get-Stamp)
        Write-Warn "strata-nvfp4\.venv is incomplete or does not run; keeping it as $broken"
        Move-Item $venv $broken
    }
    Write-Step "Python: downloading embeddable $PythonVersion"
    $zip = Join-Path $dl "python-$PythonVersion-embed-amd64.zip"
    if (-not (Test-Path $zip)) { Get-File "https://www.python.org/ftp/python/$PythonVersion/python-$PythonVersion-embed-amd64.zip" $zip }
    New-Item -ItemType Directory -Force (Join-Path $scripts "Lib\site-packages") | Out-Null
    Expand-Archive $zip -DestinationPath $scripts -Force
    $short = "python" + ($PythonVersion -replace '^(\d+)\.(\d+).*', '$1$2')
    # Relative entries keep the interpreter relocatable; 'import site' enables site-packages and sitecustomize.
    Set-Content -Encoding ascii -Path (Join-Path $scripts "$short._pth") -Value @("$short.zip", ".", "Lib\site-packages", "import site")
    Copy-Item (Join-Path $root "portable\sitecustomize.py") $scripts -Force
    $getPip = Join-Path $dl "get-pip.py"
    Get-File "https://bootstrap.pypa.io/get-pip.py" $getPip
    & $python $getPip --no-warn-script-location --disable-pip-version-check
    if ($LASTEXITCODE -ne 0) { throw "pip bootstrap failed; run START.bat again to retry" }
    & $python -c "import pip, ssl, ctypes, sqlite3; print('-- portable python OK')"
    if ($LASTEXITCODE -ne 0) { throw "portable Python check failed" }
}

# ---- 3. Engine + model (Strata setup.py; it skips finished steps itself) ----
function Find-StrataConfig {
    $info = Read-Marker
    if ($info -and $info.config -and (Test-Path (Join-Path $src $info.config))) { return Get-Item (Join-Path $src $info.config) }
    # Fallback before the first install is recorded: match the family name.
    $key = ($Family -replace '^qwen-', '' -replace 'nvfp4', '' -replace '-', '')
    $all = @(Get-ChildItem $src -Filter "strata-*.json" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    $hit = $all | Where-Object { $_.Name -like "*$key*" } | Select-Object -First 1
    if (-not $hit -and $all.Count -eq 1) { $hit = $all[0] }
    return $hit
}

function Install-Model {
    $contextKey = if ($Context -gt 0) { "$Context" } else { "auto" }
    $want = "$Family|$Model|$contextKey|$Vision"
    $label = if ($Model) { "$Family $Model" } else { $Family }
    $info = Read-Marker
    if (-not $Reinstall -and $info -and (Find-StrataConfig)) {
        if ($info.key -eq $want) { Write-Step "Engine + model: present ($label, context $contextKey)"; return }
        Write-Step "Settings changed since install; running Strata setup again for $label (finished downloads are kept)"
    } else {
        Write-Step "Engine + model: installing $label (90-130 GB; interrupted downloads resume on the next start)"
    }
    $setupArgs = @("setup.py", "--family", $Family, "--data-dir", $dataDir, "--host", "127.0.0.1", "--port", $UpstreamPort,
                   "--vision", $Vision, "--no-browser", "--yes", "--no-start")
    if ($Model) { $setupArgs += @("--model", $Model) }
    if ($Context -gt 0) { $setupArgs += @("--context", $Context) }
    $started = (Get-Date).AddSeconds(-2)
    Push-Location $src
    try {
        & $python @setupArgs
        if ($LASTEXITCODE -ne 0) { throw "Strata setup failed (exit $LASTEXITCODE). Run START.bat again to resume." }
    } finally { Pop-Location }
    # The config this setup run wrote is the newest strata-*.json touched since it started;
    # if setup left an unchanged file alone, fall back to the recorded/matching one.
    $written = Get-ChildItem $src -Filter "strata-*.json" | Where-Object { $_.LastWriteTime -ge $started } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $written) { $written = Find-StrataConfig }
    if (-not $written) { throw "Strata setup finished but no strata-*.json was found in $src" }
    Write-Step "Strata config: $($written.Name)"
    Write-Marker @{ key = $want; family = $Family; model = $Model; config = $written.Name; root = $root; installed = (Get-Date).ToString("s") }
}

# Strata checks response_format json_schema answers against the schema only when the jsonschema
# package is installed; without it a schema is reduced to "one JSON object". Its setup does not install it.
function Install-Extras {
    & $python -c "import jsonschema"
    if ($LASTEXITCODE -eq 0) { return }
    Write-Step "Installing jsonschema (full response_format json_schema checking)"
    & $python -m pip install --quiet --disable-pip-version-check "jsonschema>=4.23,<5"
    if ($LASTEXITCODE -ne 0) { Write-Warn "jsonschema could not be installed; json_schema answers are only checked to be one JSON object." }
}

# Keys this bundle needs in the Strata config, re-applied every start because setup rewrites its own keys.
# Also rewrites absolute paths when the folder was moved or copied after install.
function Update-StrataConfig($config) {
    $info = Read-Marker
    $toolArgs = @($configTool, $config.FullName,
                  "--set-str", "host=127.0.0.1",       # Strata stays private; the gateway is the LAN face
                  "--set", "fit_max_tokens=true")       # clamp oversized max_tokens instead of HTTP 400
    if ($UpstreamKey) { $toolArgs += @("--set-str", "api_key=$UpstreamKey") } else { $toolArgs += @("--unset", "api_key") }
    if ($info -and $info.root -and $info.root -ne $root) {
        Write-Step "Folder moved from $($info.root); updating paths in $($config.Name)"
        $toolArgs += @("--move", $info.root, $root)
    }
    & $python @toolArgs
    if ($LASTEXITCODE -ne 0) { throw "could not update $($config.Name)" }
    if ($info -and $info.root -and $info.root -ne $root) {
        $info.root = $root
        Write-Marker $info
    }
}

# ---- Run ----
if ($SetPageFile) {
    $pf = @{ SizeMB = $PageFileMB }
    if ($PageFileDrive) { $pf.Drive = $PageFileDrive }
    & (Join-Path $root "set_pagefile.ps1") @pf
    exit $LASTEXITCODE
}
$script:hardwareError = $null
Test-Hardware
if ($script:hardwareError -and -not $CheckOnly) { throw $script:hardwareError }
$env:PATH ="$scripts;$scripts\Scripts;$env:PATH"
$env:NEXT_ROOT = $root
Install-Source
Install-Python
if ($CheckOnly) {
    Push-Location $src
    $checkArgs = @("setup.py", "--check", "--family", $Family)
    if ($Model) { $checkArgs += @("--model", $Model) }
    try { & $python @checkArgs } finally { Pop-Location }
    return
}
if ($Reinstall -and (Test-Path $marker)) { Remove-Item $marker }
Install-Model
Install-Extras
$config = Find-StrataConfig
if (-not $config) { throw "No Strata config found in $src; run START.bat -Reinstall" }
Update-StrataConfig $config
if ($SetupOnly) { Write-Step "Setup complete. Run START.bat to start."; return }

function Q($v) { '"' + $v + '"' }
Write-Step "Starting Strata with $($config.Name) (model load can take several minutes)"
$strata = Start-Process -FilePath $python -ArgumentList @("serve\server.py", "--engine", "strata", "--config", (Q $config.Name), "--port", $UpstreamPort) -WorkingDirectory $src -PassThru -NoNewWindow
$null = $strata.Handle   # cache the handle so ExitCode is readable after exit

$gatewayArgs = @((Join-Path $root "next_gateway.py"), "--host", $HostAddress, "--port", $Port, "--upstream-port", $UpstreamPort)
if ($UpstreamKey) { $gatewayArgs += @("--upstream-key", $UpstreamKey) }
if ($ClientKey)   { $gatewayArgs += @("--client-key", $ClientKey) }
if (-not [double]::IsNaN($Temperature))    { $gatewayArgs += @("--temperature", $Temperature) }
if (-not [double]::IsNaN($TopP))           { $gatewayArgs += @("--top-p", $TopP) }
if ($TopK -ge 0)                           { $gatewayArgs += @("--top-k", $TopK) }
if (-not [double]::IsNaN($TemperatureCap)) { $gatewayArgs += @("--temperature-cap", $TemperatureCap) }
if (-not $ClientKey -and $HostAddress -ne "127.0.0.1") { Write-Warn "The API is open to the LAN without a key; consider -ClientKey." }

$gateway = Start-Process -FilePath $python -ArgumentList ($gatewayArgs | ForEach-Object { Q $_ }) -WorkingDirectory $root -PassThru -NoNewWindow
$null = $gateway.Handle
$code = 0
try {
    Write-Step "API: http://127.0.0.1:$Port/v1   readiness: http://127.0.0.1:$Port/health   (Ctrl+C to stop)"
    # If either process ends (crash, port in use, Ctrl+C), stop the other one too.
    while (-not $strata.HasExited -and -not $gateway.HasExited) { Start-Sleep -Milliseconds 500 }
    if ($strata.HasExited) {
        $code = [int]$strata.ExitCode
        Write-Warn "Strata stopped (exit $code). See its output above; logs are under strata-nvfp4\."
    } else {
        $code = [int]$gateway.ExitCode
        Write-Warn "Gateway stopped (exit $code); is port $Port already in use?"
    }
} finally {
    foreach ($p in @($strata, $gateway)) {
        if ($p -and -not $p.HasExited) { & taskkill.exe /PID $p.Id /T /F | Out-Null }
    }
}
exit $code
