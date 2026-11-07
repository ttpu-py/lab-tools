<# : TTPU Lab launcher - batch part. Do not change these lines.
@echo off
setlocal
set "TTPU_SELF=%~f0"
set "TTPU_ARGS=%*"
title TTPU Lab
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "Get-Content -Raw -LiteralPath $env:TTPU_SELF | Invoke-Expression"
exit /b %errorlevel%
#>

# =====================================================================
#  TTPU Lab - work on your lab repo in local VS Code on a shared PC.
#
#  Double-click to START a lab session:
#    1. Removes old GitHub logins from this PC.
#    2. You sign in to GitHub once (private browser window, one code).
#    3. Downloads (clones) your lab repo and opens it in VS Code.
#    4. When you close VS Code: saves your work to GitHub (commit and
#       push) and removes your login from this PC.
#
#  Double-click it again while VS Code is open to finish the session
#  (for example if the TTPU Lab window was closed by mistake). A hidden
#  helper also finishes the session when VS Code closes in that case.
#
#  Teacher settings are in $Config below.
# =====================================================================

$Config = @{
    Version          = '1.4.0'
    Org              = 'ttpu-py'
    # Client ID of the OAuth App owned by the ttpu-py organization.
    # The app must have "Enable Device Flow" switched on.
    ClientId         = 'Ov23lisuQHvMwfGUJ3RM'
    Scope            = 'repo'
    # If a previous student did not finish the session, push their work
    # before cleaning the PC, so it is not lost.
    SaveLeftoverWork = $true
    # Seconds to wait for an answer before the default answer is used.
    AnswerTimeout    = 30
    # Installed automatically (no admin rights) if missing on the PC.
    Extensions       = @('ms-python.python', 'ms-python.vscode-pylance', 'ms-python.debugpy')
    PythonVersion    = '3.12.8'
    GitFallbackUrl   = 'https://github.com/git-for-windows/git/releases/download/v2.47.1.windows.1/PortableGit-2.47.1-64-bit.7z.exe'
    # Turn off AI chat / Copilot features in the lab VS Code session.
    DisableAI        = $true
    # Newest launcher. A lab PC gets it automatically at the start of a
    # session if it is newer than the installed copy. Empty = no updates.
    UpdateUrl        = 'https://github.com/ttpu-py/lab-tools/releases/latest/download/TTPU-Lab.cmd'
}

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
try { $Host.UI.RawUI.WindowTitle = 'TTPU Lab' } catch { }

$script:Self = $env:TTPU_SELF
$script:Mode = ("$env:TTPU_ARGS").Trim().ToLower()
if (-not $script:Mode) { $script:Mode = 'start' }
# "safe" mode: do not touch machine-wide logins (for testing on a personal PC).
$script:Safe = $script:Mode -match 'safe'
$script:Mode = ($script:Mode -replace 'safe', '').Trim()
if (-not $script:Mode) { $script:Mode = 'start' }

$script:Root = Join-Path $env:LOCALAPPDATA 'TTPU-Lab'
if ($script:Root.Contains("'")) { $script:Root = Join-Path $env:ProgramData 'TTPU-Lab' }
$script:SessionDir = Join-Path $script:Root 'session'
$script:StateFile = Join-Path $script:SessionDir 'state.json'
$script:PidFile = Join-Path $script:Root 'launcher.pid'
$script:LogFile = Join-Path $script:Root 'ttpu-lab.log'
$script:Git = $null
$script:Code = $null
$script:Token = $null
$script:AuthExpired = $false
$script:Python = $null
$script:ExtensionsFailed = $false
$script:Protected = $false
$script:BackupBranch = $null
$script:Phase = 'setup'

# ---------------------------------------------------------------- output

function Say([string]$Text, [string]$Color = 'Gray') { Write-Host $Text -ForegroundColor $Color }
function Ok([string]$Text) { Say "  [OK] $Text" 'Green' }
function Warn([string]$Text) { Say "  [!] $Text" 'Yellow' }
function Fail([string]$Text) { Say "  [X] $Text" 'Red' }
function Step([string]$Text) { Say ''; Say "== $Text" 'Cyan'; Write-Log "STEP $Text" }

function Write-Log([string]$Text) {
    try {
        if (-not (Test-Path $script:Root)) { New-Item -ItemType Directory -Path $script:Root -Force | Out-Null }
        if ((Test-Path $script:LogFile) -and ((Get-Item $script:LogFile).Length -gt 1MB)) { Remove-Item $script:LogFile -Force }
        Add-Content -Path $script:LogFile -Value ("{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $Text)
    } catch { }
}

function Ask-YesNo([string]$Question, [bool]$Default = $true, [int]$Timeout = 0) {
    $hint = if ($Default) { '[Y/n]' } else { '[y/N]' }
    if ($Timeout -gt 0) {
        $deadline = (Get-Date).AddSeconds($Timeout)
        try {
            while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) }
            Write-Host "$Question $hint (auto-answer in $Timeout s): " -NoNewline -ForegroundColor White
            while ((Get-Date) -lt $deadline) {
                if ([Console]::KeyAvailable) {
                    $k = [Console]::ReadKey($true)
                    if ($k.Key -eq 'Enter') { Write-Host ''; return $Default }
                    if ($k.KeyChar -eq 'y' -or $k.KeyChar -eq 'Y') { Write-Host 'y'; return $true }
                    if ($k.KeyChar -eq 'n' -or $k.KeyChar -eq 'N') { Write-Host 'n'; return $false }
                }
                Start-Sleep -Milliseconds 100
            }
            Write-Host '(auto)'
            return $Default
        } catch { }
    }
    $a = Read-Host "$Question $hint"
    if (-not $a) { return $Default }
    return ($a.Trim().ToLower().StartsWith('y'))
}

function Pause-End {
    Say ''
    Say 'Press Enter to close this window.' 'DarkGray'
    try { [void](Read-Host) } catch { }
}

# ---------------------------------------------------------------- tools

function Find-FirstFile([string[]]$Paths) {
    foreach ($p in $Paths) { if ($p -and (Test-Path -LiteralPath $p)) { return $p } }
    return $null
}

function Find-Git {
    $c = Get-Command git.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    $p = Find-FirstFile @(
        "$env:ProgramFiles\Git\cmd\git.exe",
        "${env:ProgramFiles(x86)}\Git\cmd\git.exe",
        "$env:LOCALAPPDATA\Programs\Git\cmd\git.exe",
        (Join-Path $script:Root 'tools\git\cmd\git.exe'))
    if ($p -and -not (Test-GitWorks $p)) { Write-Log "git found but broken: $p"; return $null }
    if ($p) { $env:PATH = (Split-Path $p) + ';' + $env:PATH }
    return $p
}

function Find-Code {
    $p = Find-FirstFile @(
        "$env:LOCALAPPDATA\Programs\Microsoft VS Code\Code.exe",
        "$env:ProgramFiles\Microsoft VS Code\Code.exe",
        "${env:ProgramFiles(x86)}\Microsoft VS Code\Code.exe")
    if ($p) { return $p }
    $c = Get-Command code.cmd -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) {
        $exe = Join-Path (Split-Path (Split-Path $c.Source)) 'Code.exe'
        if (Test-Path -LiteralPath $exe) { return $exe }
    }
    return $null
}

# Returns the full path of a working Python 3.9+ python.exe with sqlite3 (not the Microsoft Store stub), or $null.
function Find-Python {
    $cands = @()
    foreach ($c in @(Get-Command python.exe -All -ErrorAction SilentlyContinue)) {
        if ($c.Source -notlike '*\WindowsApps\*') { $cands += $c.Source }
    }
    foreach ($base in @("$env:LOCALAPPDATA\Programs\Python", $env:ProgramFiles, "${env:ProgramFiles(x86)}", 'C:\')) {
        if (-not $base -or -not (Test-Path -LiteralPath $base)) { continue }
        $dirs = @(Get-ChildItem -LiteralPath $base -Directory -Filter 'Python3*' -ErrorAction SilentlyContinue |
            Sort-Object { $n = 0; [void][int]::TryParse(($_.Name -replace '[^0-9]', ''), [ref]$n); $n } -Descending)
        foreach ($d in $dirs) { $cands += (Join-Path $d.FullName 'python.exe') }
    }
    foreach ($p in ($cands | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try {
            $out = & $p -c "import sys, sqlite3; print(sys.version_info >= (3, 9))" 2>$null
            if ("$out".Trim() -eq 'True') { return $p }
        } catch { Write-Log "python check failed for ${p}: $_" } finally { $ErrorActionPreference = $old }
    }
    return $null
}

function Add-PythonToPath([string]$Python) {
    if (-not $Python) { return }
    $d = Split-Path $Python
    $env:PATH = "$d;$d\Scripts;$env:PATH"
}

function Get-Arch {
    if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') { return 'arm64' }
    return 'x64'
}

# Downloads a file with retries: curl.exe first (built into Windows 10/11), then PowerShell (uses the system proxy).
function Download-File([string]$Url, [string]$OutFile) {
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    for ($try = 1; $try -le 3; $try++) {
        foreach ($method in @('curl', 'ps')) {
            if ($method -eq 'curl' -and -not (Test-Path -LiteralPath $curl)) { continue }
            Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
            $ok = $false
            $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
            try {
                if ($method -eq 'curl') {
                    & $curl -L --fail --retry 2 --retry-delay 3 --connect-timeout 30 --speed-limit 1024 --speed-time 60 --progress-bar -o $OutFile $Url
                    $ok = ($LASTEXITCODE -eq 0)
                } else {
                    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec 1800 -ErrorAction Stop
                    $ok = $true
                }
            } catch { Write-Log "download error ($method): $_" } finally { $ErrorActionPreference = $old }
            if ($ok -and (Test-Path -LiteralPath $OutFile) -and (Get-Item -LiteralPath $OutFile).Length -gt 1MB) { return $true }
            Write-Log "download failed ($method, try $try): $Url"
        }
        Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
        Warn "Download failed (try $try of 3)..."
        Start-Sleep -Seconds (5 * $try)
    }
    return $false
}

# Runs an installer and waits. Returns $false if Windows or antivirus blocks it.
function Run-Installer([string]$Exe, [string[]]$InstallerArgs) {
    try {
        Start-Process -FilePath $Exe -ArgumentList $InstallerArgs -Wait -WindowStyle Hidden -ErrorAction Stop
        return $true
    } catch {
        Write-Log "installer blocked: $Exe $_"
        Warn 'Windows or the antivirus blocked the installer.'
        return $false
    }
}

function Install-VSCode {
    Step 'Installing VS Code (only the first time on this PC, about 100 MB)'
    $exe = Join-Path $env:TEMP 'TTPU-VSCodeUserSetup.exe'
    if (-not (Download-File "https://update.code.visualstudio.com/latest/win32-$(Get-Arch)-user/stable" $exe)) { return $null }
    Say 'Installing... (1-3 minutes)'
    [void](Run-Installer $exe @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/MERGETASKS=!runcode,addtopath'))
    Remove-Item -LiteralPath $exe -Force -ErrorAction SilentlyContinue
    $c = Find-Code
    if ($c) { Ok "VS Code installed: $c"; Write-Log "installed vscode $c" }
    return $c
}

function Test-GitWorks([string]$GitExe) {
    if (-not $GitExe -or -not (Test-Path -LiteralPath $GitExe)) { return $false }
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = & $GitExe --version 2>$null; return ($LASTEXITCODE -eq 0 -and "$out" -match 'git version') }
    catch { return $false } finally { $ErrorActionPreference = $old }
}

function Install-Git {
    Step 'Installing Git (only the first time on this PC, about 60 MB)'
    $urls = @()
    try {
        $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/git-for-windows/git/releases/latest' -UserAgent 'TTPU-Lab' -TimeoutSec 20
        $pattern = if ((Get-Arch) -eq 'arm64') { '^PortableGit-.*-arm64\.7z\.exe$' } else { '^PortableGit-.*-64-bit\.7z\.exe$' }
        $asset = @($rel.assets | Where-Object { $_.name -match $pattern }) | Select-Object -First 1
        if ($asset) { $urls += $asset.browser_download_url }
    } catch { Write-Log "git release lookup failed: $_" }
    $urls += $Config.GitFallbackUrl
    $sfx = Join-Path $env:TEMP 'TTPU-PortableGit.7z.exe'
    $downloaded = $false
    foreach ($u in ($urls | Select-Object -Unique)) { if (Download-File $u $sfx) { $downloaded = $true; break } }
    if (-not $downloaded) { return $null }
    $dest = Join-Path $script:Root 'tools\git'
    $tmp = Join-Path $script:Root 'tools\git.new'
    Remove-Dir $tmp
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    Say 'Unpacking... (about 1 minute)'
    $ran = Run-Installer $sfx @('-y', "-o`"$tmp`"")
    Remove-Item -LiteralPath $sfx -Force -ErrorAction SilentlyContinue
    if (-not $ran -or -not (Test-GitWorks (Join-Path $tmp 'cmd\git.exe'))) { Remove-Dir $tmp; return $null }
    Remove-Dir $dest
    try { Move-Item -LiteralPath $tmp -Destination $dest -Force -ErrorAction Stop } catch { Write-Log "git move failed: $_"; return $null }
    $g = Join-Path $dest 'cmd\git.exe'
    if (Test-GitWorks $g) { $env:PATH = (Split-Path $g) + ';' + $env:PATH; Ok "Git installed: $g"; Write-Log "installed git $g"; return $g }
    return $null
}

function Install-Python {
    $v = $Config.PythonVersion
    Step "Installing Python $v (only the first time on this PC, about 25 MB)"
    $suffix = if ((Get-Arch) -eq 'arm64') { 'arm64' } else { 'amd64' }
    $exe = Join-Path $env:TEMP "TTPU-python-$v.exe"
    if (-not (Download-File "https://www.python.org/ftp/python/$v/python-$v-$suffix.exe" $exe)) { return $null }
    Say 'Installing... (1-2 minutes)'
    [void](Run-Installer $exe @('/quiet', 'InstallAllUsers=0', 'PrependPath=1', 'Include_test=0', 'Include_launcher=1', 'InstallLauncherAllUsers=0', 'Shortcuts=0'))
    Remove-Item -LiteralPath $exe -Force -ErrorAction SilentlyContinue
    $p = Find-Python
    if ($p) { Ok "Python installed: $p"; Write-Log "installed python $p" }
    return $p
}

function Get-CodeCli {
    if (-not $script:Code) { return $null }
    $cli = Join-Path (Split-Path $script:Code) 'bin\code.cmd'
    if (Test-Path -LiteralPath $cli) { return $cli }
    return $null
}

function Get-RepoExtensions([string]$RepoDir) {
    if (-not $RepoDir) { return @() }
    $f = Join-Path $RepoDir '.vscode\extensions.json'
    if (-not (Test-Path -LiteralPath $f)) { return @() }
    try {
        $text = Get-Content -LiteralPath $f -Raw
        $text = $text -replace '(?m)^\s*//.*$', '' -replace '/\*[\s\S]*?\*/', '' -replace ',(\s*[\]}])', '$1'
        return @(($text | ConvertFrom-Json).recommendations)
    } catch { Write-Log "extensions.json not readable: $_"; return @() }
}

# Installs the VS Code extensions the lab needs (default list + the repo's .vscode/extensions.json).
function Ensure-Extensions([string]$RepoDir) {
    if ($script:ExtensionsFailed) { return }
    $cli = Get-CodeCli
    if (-not $cli) { Warn 'Cannot install VS Code extensions (code.cmd not found).'; return }
    $want = @($Config.Extensions) + @(Get-RepoExtensions $RepoDir)
    $want = @($want | Where-Object { $_ } | ForEach-Object { "$_".Trim().ToLower() } | Select-Object -Unique)
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $env:ELECTRON_NO_ATTACH_CONSOLE = $null
        $have = @(& $cli --list-extensions 2>$null | ForEach-Object { "$_".Trim().ToLower() })
        $missing = @($want | Where-Object { $have -notcontains $_ })
        if ($missing.Count -eq 0) { return }
        Step 'Installing VS Code extensions (only the first time on this PC)'
        foreach ($e in $missing) {
            Say "  $e ..."
            $out = & $cli --install-extension $e --force 2>&1
            $have = @(& $cli --list-extensions 2>$null | ForEach-Object { "$_".Trim().ToLower() })
            if ($have -contains $e) { Ok $e; continue }
            Write-Log "extension $e failed: $($out -join ' ')"
            Warn "Could not install $e (no connection to the extension store?). Skipping extensions for now."
            $script:ExtensionsFailed = $true
            break
        }
    } catch { Write-Log "extensions error: $_" } finally { $ErrorActionPreference = $old }
}

# Runs git. Returns @{ Code = exit code; Out = text }. Never throws.
function Run-Git([string[]]$GitArgs, [string]$Dir = $null, [string]$InputText = $null) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $env:GIT_TERMINAL_PROMPT = '0'
    $env:GCM_INTERACTIVE = 'Never'
    try {
        $all = @()
        if ($Dir) { $all += @('-C', $Dir) }
        $all += $GitArgs
        if ($null -ne $InputText) { $out = $InputText | & $script:Git @all 2>&1 }
        else { $out = & $script:Git @all 2>&1 }
        $code = $LASTEXITCODE
    } catch {
        $out = "$_"; $code = 1
    } finally { $ErrorActionPreference = $old }
    $text = (@($out) | ForEach-Object { "$_" }) -join "`n"
    Write-Log ("git {0} -> {1}" -f (($GitArgs | Where-Object { $_ -notmatch 'gh[op]_|github_pat' }) -join ' '), $code)
    return @{ Code = $code; Out = $text }
}

function Api([string]$Path, [string]$Method = 'GET', $Body = $null) {
    $p = @{
        Method    = $Method
        Uri       = 'https://api.github.com' + $Path
        Headers   = @{ Authorization = "token $script:Token"; Accept = 'application/vnd.github+json' }
        UserAgent = 'TTPU-Lab'
    }
    if ($null -ne $Body) { $p.Body = ($Body | ConvertTo-Json); $p.ContentType = 'application/json' }
    $r = Invoke-RestMethod @p
    return $r
}

# ------------------------------------------------- Windows credentials

function Remove-WindowsGitHubCredentials {
    $n = 0
    # cmdkey prints "...target=<name>"; the "target=" part is the same in every Windows language.
    try {
        $lines = @(cmdkey.exe /list 2>$null)
        foreach ($l in $lines) {
            if ($l -match 'target=(.*github.*)$') {
                $t = $Matches[1].Trim()
                cmdkey.exe "/delete:$t" | Out-Null
                Write-Log "removed credential $t"
                $n++
            }
        }
    } catch { Write-Log "cmdkey failed: $_" }
    # Ask Git Credential Manager (and any other global helper) to forget github.com.
    if ($script:Git) {
        for ($i = 0; $i -lt 3; $i++) {
            [void](Run-Git @('credential', 'reject') -InputText "protocol=https`nhost=github.com`n`n")
        }
    }
    return $n
}

# ---------------------------------------------------------- PC cleanup

function Remove-Dir([string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return }
    for ($i = 0; $i -lt 5 -and (Test-Path -LiteralPath $Path); $i++) {
        cmd.exe /c "rd /s /q `"$Path`"" 2>$null | Out-Null
        if (Test-Path -LiteralPath $Path) { Start-Sleep -Seconds 2 }
    }
}

function Confirm-LabPC {
    if ($script:Safe) { return }
    $marker = Join-Path $script:Root 'lab-pc.txt'
    if (Test-Path -LiteralPath $marker) { return }
    Say ''
    Warn 'TTPU Lab is made for SHARED university PCs.'
    Warn 'Each time it runs, it removes ALL GitHub logins and the global git name/e-mail'
    Warn 'from this Windows account, and it closes VS Code.'
    if (-not (Ask-YesNo 'Is this a shared university lab PC?' $false)) {
        Warn 'OK. Running in safe mode: logins on this PC are not removed.'
        $script:Safe = $true
        return
    }
    New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
    Set-Content -Path $marker -Value ("Confirmed as a lab PC on {0:yyyy-MM-dd HH:mm}" -f (Get-Date))
}

function Stop-AllVSCode {
    $procs = @(Get-Process -Name 'Code' -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { return }
    Warn 'VS Code is open. It will be closed now (it can be from the previous student).'
    foreach ($p in $procs) { try { if ($p.MainWindowHandle -ne 0) { [void]$p.CloseMainWindow() } } catch { } }
    for ($i = 0; $i -lt 15 -and @(Get-Process -Name 'Code' -ErrorAction SilentlyContinue).Count -gt 0; $i++) { Start-Sleep -Seconds 1 }
    Get-Process -Name 'Code' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
}

function Clear-VSCodeDefaultGitHubLogin {
    $db = Join-Path $env:APPDATA 'Code\User\globalStorage\state.vscdb'
    if (-not (Test-Path -LiteralPath $db)) { return }
    $py = Find-Python
    if (-not $py) { Write-Log 'no python: VS Code GitHub login not cleared'; return }
    $pyFile = Join-Path $env:TEMP 'ttpu-clear-vscode.py'
    $code = @'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1], timeout=5)
cur = con.execute("DELETE FROM ItemTable WHERE key LIKE 'secret://%github%' OR key LIKE 'github.%account%'")
con.commit()
print(cur.rowcount)
'@
    Set-Content -Path $pyFile -Value $code -Encoding ASCII
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = & $py $pyFile $db 2>&1; Write-Log "vscode default profile github secrets removed: $out" } catch { } finally { $ErrorActionPreference = $old }
    Remove-Item $pyFile -Force -ErrorAction SilentlyContinue
}

function Remove-GitHubLinesFromFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $keep = @(Get-Content -LiteralPath $Path | Where-Object { $_ -notmatch 'github\.com' })
    if ($keep.Count -eq 0) { Remove-Item -LiteralPath $Path -Force } else { Set-Content -LiteralPath $Path -Value $keep }
}

function Clear-PCLogins {
    if ($script:Safe) { Warn 'Safe mode: machine-wide logins are not changed.'; return }
    Stop-AllVSCode
    $n = Remove-WindowsGitHubCredentials
    Remove-GitHubLinesFromFile (Join-Path $env:USERPROFILE '.git-credentials')
    Remove-GitHubLinesFromFile (Join-Path $env:USERPROFILE '.config\git\credentials')
    $ghHosts = Join-Path $env:APPDATA 'GitHub CLI\hosts.yml'
    if (Test-Path -LiteralPath $ghHosts) { Remove-Item -LiteralPath $ghHosts -Force -ErrorAction SilentlyContinue }
    Clear-VSCodeDefaultGitHubLogin
    if ($script:Git) {
        [void](Run-Git @('config', '--global', '--unset-all', 'user.name'))
        [void](Run-Git @('config', '--global', '--unset-all', 'user.email'))
    }
    try { Set-Clipboard -Value ' ' } catch { }
    Write-Log "PC logins cleared ($n Windows credentials)"
}

# ------------------------------------------------------------- session

function Save-State($State) {
    New-Item -ItemType Directory -Path $script:SessionDir -Force | Out-Null
    $State | ConvertTo-Json | Set-Content -Path $script:StateFile -Encoding UTF8
}

function Load-State {
    if (-not (Test-Path -LiteralPath $script:StateFile)) { return $null }
    try { return (Get-Content -LiteralPath $script:StateFile -Raw | ConvertFrom-Json) } catch { return $null }
}

function Get-SessionCodeProcesses([string]$ProfileDir) {
    if (-not $ProfileDir) { return @() }
    try {
        return @(Get-CimInstance Win32_Process -Filter "Name='Code.exe'" -ErrorAction Stop |
            Where-Object { $_.CommandLine -and $_.CommandLine.Contains($ProfileDir) })
    } catch {
        try {
            return @(Get-WmiObject Win32_Process -Filter "Name='Code.exe'" |
                Where-Object { $_.CommandLine -and $_.CommandLine.Contains($ProfileDir) })
        } catch { return @() }
    }
}

function Write-PidFile {
    New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
    $me = Get-Process -Id $PID
    Set-Content -Path $script:PidFile -Value ("{0}|{1}" -f $PID, $me.StartTime.Ticks)
}

# $true = VS Code of this session is open, $false = closed, $null = cannot tell.
function Test-SessionCodeRunning([string]$ProfileDir) {
    $list = $null
    try {
        $list = @(Get-CimInstance Win32_Process -Filter "Name='Code.exe'" -ErrorAction Stop)
    } catch {
        try { $list = @(Get-WmiObject Win32_Process -Filter "Name='Code.exe'" -ErrorAction Stop) } catch { return $null }
    }
    foreach ($p in $list) { if ($p.CommandLine -and $p.CommandLine.Contains($ProfileDir)) { return $true } }
    return $false
}

function Wait-SessionCodeClosed([string]$ProfileDir) {
    $closedCount = 0
    while ($closedCount -lt 2) {
        Start-Sleep -Seconds 3
        $r = Test-SessionCodeRunning $ProfileDir
        if ($r -eq $false) { $closedCount++ } else { $closedCount = 0 }
    }
}

function Test-LauncherRunning {
    if (-not (Test-Path -LiteralPath $script:PidFile)) { return $false }
    try {
        $parts = (Get-Content -LiteralPath $script:PidFile -Raw).Trim().Split('|')
        $id = [int]$parts[0]
        if ($id -eq $PID) { return $false }
        $p = Get-Process -Id $id -ErrorAction SilentlyContinue
        if ($null -eq $p -or $p.ProcessName -notlike 'powershell*') { return $false }
        return ($p.StartTime.Ticks -eq [long]$parts[1])
    } catch { return $false }
}

# Pushes the current branch. Fixes the usual problems. Returns $true if the work is on GitHub.
function Push-Work([string]$Dir, [string]$Branch) {
    for ($try = 1; $try -le 3; $try++) {
        $r = Run-Git @('push', 'origin', "HEAD:refs/heads/$Branch") $Dir
        if ($r.Code -eq 0) { return $true }
        Write-Log "push failed: $($r.Out)"
        if ($r.Out -match 'rejected|fetch first|non-fast-forward') {
            Warn 'GitHub has newer commits (for example from Codespaces). Merging them first...'
            $m = Run-Git @('pull', '--no-rebase', '--no-edit', 'origin', $Branch) $Dir
            if ($m.Code -ne 0) {
                [void](Run-Git @('merge', '--abort') $Dir)
                $backup = 'local-work-' + (Get-Date -Format 'yyyyMMdd-HHmm')
                $b = Run-Git @('push', 'origin', "HEAD:refs/heads/$backup") $Dir
                if ($b.Code -eq 0) {
                    $script:BackupBranch = $backup
                    Warn "Your changes conflict with the code on GitHub. They are saved on GitHub in the branch '$backup'."
                    Warn "Open your repo in Codespaces, merge that branch into $Branch, or tell the teacher."
                    return $true
                }
            }
            continue
        }
        if ($r.Out -match 'Authentication failed|Invalid username or password|could not read Username|401') {
            $script:AuthExpired = $true
            Fail 'The GitHub login for this work has expired (logins stop working after 8 hours).'
            return $false
        }
        if ($r.Out -match '403|denied|not allowed') {
            Fail 'GitHub refused the push (no write access). Maybe the deadline is over. Tell the teacher.'
            return $false
        }
        Warn "Push failed (try $try of 3). Check the internet connection..."
        Start-Sleep -Seconds (5 * $try)
    }
    return $false
}

# Commits and pushes the session repo, then removes everything.
function Finish-Session([bool]$Interactive) {
    $state = Load-State
    $saved = $true
    if ($state -and $state.RepoDir -and (Test-Path -LiteralPath (Join-Path $state.RepoDir '.git'))) {
        $dir = $state.RepoDir
        Step "Saving your work ($($state.Repo))"
        $changes = (Run-Git @('status', '--porcelain') $dir).Out.Trim()
        if ($changes) {
            Say 'Changed files:'
            Say $changes 'DarkGray'
            $doCommit = $true
            if ($Interactive) {
                $doCommit = Ask-YesNo 'Save these changes to GitHub now (commit and push)?' $true $Config.AnswerTimeout
            }
            if ($doCommit) {
                $msg = if ($Interactive) { 'Lab work ' + (Get-Date -Format 'yyyy-MM-dd HH:mm') } else { 'Auto-save: lab session was not finished ' + (Get-Date -Format 'yyyy-MM-dd HH:mm') }
                Remove-Item -LiteralPath (Join-Path $dir '.git\index.lock') -Force -ErrorAction SilentlyContinue
                [void](Run-Git @('add', '-A') $dir)
                $c = Run-Git @('commit', '-m', $msg) $dir
                if ($c.Code -eq 0) { Ok "Commit: $msg" } else { Warn "Commit failed: $($c.Out)" }
            } else {
                Warn 'Changes that are not committed will be deleted from this PC.'
                if ($Interactive -and -not (Ask-YesNo 'Delete them? (answer n to go back and save)' $false)) {
                    return 'back'
                }
            }
        }
        Remove-Item -LiteralPath (Join-Path $dir '.git\index.lock') -Force -ErrorAction SilentlyContinue
        if ($changes -and $doCommit -and (Run-Git @('status', '--porcelain') $dir).Out.Trim()) {
            Fail 'Some changes could not be committed.'
            $saved = $false
        }
        [void](Run-Git @('fetch', 'origin') $dir)
        $ahead = (Run-Git @('rev-list', '--count', "origin/$($state.Branch)..HEAD") $dir).Out.Trim()
        if ($ahead -notmatch '^\d+$') { Write-Log "rev-list failed: $ahead"; $saved = $false }
        elseif ($saved -and [int]$ahead -gt 0) {
            Say "Pushing $ahead commit(s) to GitHub..."
            $saved = Push-Work $dir $state.Branch
        }
        if ($saved) {
            [void](Run-Git @('fetch', 'origin') $dir)
            $left = (Run-Git @('rev-list', '--count', "origin/$($state.Branch)..HEAD") $dir).Out.Trim()
            if ($left -eq '0') { Ok "Your work is on GitHub: $($state.Url)" }
            elseif ($script:BackupBranch) { Ok "Your work is on GitHub in the branch '$($script:BackupBranch)'." }
            else { Write-Log "after push still ahead: $left"; $saved = $false }
        }
        if (-not $saved) {
            Fail 'Your work could NOT be saved to GitHub.'
            if ($Interactive) {
                Fail "It stays on this PC in: $dir"
                Fail 'Check the internet and double-click TTPU Lab again. The next TTPU Lab start on this PC also tries again.'
                Write-Log "work not saved, kept $dir"
                return 'unsaved'
            }
            Move-ToUnsaved $state
        }
    }
    Step 'Removing your login from this PC'
    if ($state -and $state.ProfileDir) {
        foreach ($p in (Get-SessionCodeProcesses $state.ProfileDir)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 1
    }
    Remove-Dir $script:SessionDir
    Clear-PCLogins
    if (Test-Path -LiteralPath $script:SessionDir) { Warn "Some files could not be deleted: $script:SessionDir" } else { Ok 'Session files deleted.' }
    if ($Interactive) {
        Say ''
        Say 'LAST STEP: sign out of github.com in your browser.' 'Yellow'
        Say 'A browser page opens now. Click "Sign out", then close all browser windows.' 'Yellow'
        try { Start-Process 'https://github.com/logout' } catch { }
    }
    return 'done'
}

# Keeps work that could not be pushed (no internet, GitHub down) for a later retry.
function Move-ToUnsaved($State) {
    $target = Join-Path (Join-Path $script:Root 'unsaved') ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $State.Login)
    New-Item -ItemType Directory -Path (Split-Path $target) -Force | Out-Null
    if ($State.ProfileDir) { Remove-Dir $State.ProfileDir }
    $moved = $false
    for ($i = 0; $i -lt 3 -and -not $moved; $i++) {
        try { Move-Item -LiteralPath $script:SessionDir -Destination $target -Force -ErrorAction Stop; $moved = $true }
        catch { Write-Log "move failed: $_"; Start-Sleep -Seconds 2 }
    }
    if (-not $moved) {
        try { Copy-Item -LiteralPath $script:SessionDir -Destination $target -Recurse -Force -ErrorAction Stop; $moved = $true }
        catch { Write-Log "copy failed: $_"; Warn "Could not keep the unsaved work of $($State.Login). Tell the teacher."; return }
    }
    $cfgFile = Join-Path (Join-Path $target $State.Repo) '.git\config'
    $oldCred = (Join-Path $script:SessionDir 'git-credentials').Replace('\', '/')
    $newCred = (Join-Path $target 'git-credentials').Replace('\', '/')
    if (Test-Path -LiteralPath $cfgFile) {
        $utf8 = New-Object Text.UTF8Encoding $false
        [IO.File]::WriteAllText($cfgFile, [IO.File]::ReadAllText($cfgFile, $utf8).Replace($oldCred, $newCred), $utf8)
    }
    if ($script:AuthExpired) {
        Set-Content -LiteralPath (Join-Path $target 'LOGIN-EXPIRED.txt') -Value 'The login expired before this work was pushed. Copy the files to the student repo by hand.'
        Warn "Work of $($State.Login) could not be pushed because the login expired. It is kept in $target for the teacher."
    } else {
        Warn "Work of $($State.Login) could not be pushed. It is kept in $target and TTPU Lab tries again next time."
    }
    Write-Log "moved unsaved work to $target"
}

function Retry-Unsaved {
    $base = Join-Path $script:Root 'unsaved'
    if (-not (Test-Path -LiteralPath $base)) { return }
    foreach ($d in @(Get-ChildItem -LiteralPath $base -Directory)) {
        if (Test-Path -LiteralPath (Join-Path $d.FullName 'LOGIN-EXPIRED.txt')) { continue }
        try {
            $st = Get-Content -LiteralPath (Join-Path $d.FullName 'state.json') -Raw | ConvertFrom-Json
            $dir = Join-Path $d.FullName $st.Repo
            [void](Run-Git @('fetch', 'origin') $dir)
            $ahead = (Run-Git @('rev-list', '--count', "origin/$($st.Branch)..HEAD") $dir).Out.Trim()
            $pushed = ($ahead -eq '0')
            if (-not $pushed) { $pushed = Push-Work $dir $st.Branch }
            if ($pushed) {
                Remove-Dir $d.FullName
                Ok "Old unsaved work of $($st.Login) is now on GitHub."
                Write-Log "retry ok $($d.Name)"
            }
        } catch { Write-Log "retry failed $($d.Name): $_" }
    }
}

function Finish-Leftover {
    if ($Config.SaveLeftoverWork) { Retry-Unsaved }
    $state = Load-State
    if (-not $state) { if (Test-Path -LiteralPath $script:SessionDir) { Remove-Dir $script:SessionDir }; return }
    Step 'Cleaning up the previous session'
    if (Test-LauncherRunning) {
        Fail 'Another TTPU Lab window is still running. Close VS Code and that window first.'
        Pause-End; exit 1
    }
    if ($state.ProfileDir) { foreach ($p in (Get-SessionCodeProcesses $state.ProfileDir)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue } }
    if ($Config.SaveLeftoverWork) {
        Say "The previous session ($($state.Login)) was not finished. Saving that work to GitHub first..."
        [void](Finish-Session $false)
    } else {
        Remove-Dir $script:SessionDir
    }
}

# --------------------------------------------------------- GitHub login

function Open-PrivateBrowser([string]$Url) {
    $browsers = @(
        @{ Name = 'Microsoft Edge (InPrivate)'; Arg = '--inprivate'; Paths = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") },
        @{ Name = 'Google Chrome (Incognito)'; Arg = '--incognito'; Paths = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe", "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe") },
        @{ Name = 'Firefox (Private)'; Arg = '-private-window'; Paths = @("$env:ProgramFiles\Mozilla Firefox\firefox.exe", "${env:ProgramFiles(x86)}\Mozilla Firefox\firefox.exe") },
        @{ Name = 'Yandex Browser (Incognito)'; Arg = '--incognito'; Paths = @("$env:LOCALAPPDATA\Yandex\YandexBrowser\Application\browser.exe") }
    )
    foreach ($b in $browsers) {
        $exe = Find-FirstFile $b.Paths
        if ($exe) {
            try { Start-Process -FilePath $exe -ArgumentList @($b.Arg, $Url); return $b.Name } catch { }
        }
    }
    Start-Process $Url
    return 'default browser'
}

function Get-DeviceToken {
    $headers = @{ Accept = 'application/json' }
    $dc = Invoke-RestMethod -Method Post -Uri 'https://github.com/login/device/code' -Headers $headers -UserAgent 'TTPU-Lab' `
        -Body @{ client_id = $Config.ClientId; scope = $Config.Scope }
    if (-not $dc.user_code) { throw "GitHub did not give a sign-in code. Answer: $($dc | ConvertTo-Json -Compress)" }
    try { Set-Clipboard -Value $dc.user_code } catch { }
    Say ''
    Say '  Your sign-in code:' 'White'
    Say ''
    Say "        $($dc.user_code)" 'Yellow'
    Say ''
    Say '  The code is already copied. In the browser window:' 'White'
    Say '    1. Sign in with YOUR GitHub account.' 'White'
    Say '    2. Paste the code (Ctrl+V), click Continue, then click Authorize.' 'White'
    $name = Open-PrivateBrowser $dc.verification_uri
    Say "  (opened $name at $($dc.verification_uri))" 'DarkGray'
    Say ''
    Say '  Waiting for you to authorize...' 'DarkGray'
    $interval = [Math]::Max(5, [int]$dc.interval)
    $deadline = (Get-Date).AddSeconds([int]$dc.expires_in)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $interval
        try {
            $r = Invoke-RestMethod -Method Post -Uri 'https://github.com/login/oauth/access_token' -Headers $headers -UserAgent 'TTPU-Lab' `
                -Body @{ client_id = $Config.ClientId; device_code = $dc.device_code; grant_type = 'urn:ietf:params:oauth:grant-type:device_code' }
        } catch { Write-Log "token poll error: $_"; continue }
        if ($r.access_token) { return $r.access_token }
        switch ("$($r.error)") {
            'authorization_pending' { }
            'slow_down' { $interval += 5 }
            'expired_token' { Warn 'The code expired.'; return $null }
            'access_denied' { Warn 'You clicked Cancel in the browser.'; return $null }
            default { throw "GitHub sign-in error: $($r.error) $($r.error_description)" }
        }
    }
    Warn 'The code expired.'
    return $null
}

function SignIn {
    while ($true) {
        Step 'Sign in to GitHub'
        $script:Token = Get-DeviceToken
        if (-not $script:Token) {
            if (Ask-YesNo 'Try again with a new code?' $true) { continue } else { return $null }
        }
        try { $me = Api '/user' } catch { Warn "GitHub did not accept the login: $_"; continue }
        $label = if ($me.name) { "$($me.login) ($($me.name))" } else { $me.login }
        Say ''
        Say "  Signed in as: $label" 'Green'
        for ($k = 0; $k -lt 2; $k++) {
            $typed = Read-Host '  To confirm, type YOUR GitHub username'
            if ("$typed".Trim().ToLower() -eq $me.login.ToLower()) { return $me }
            Warn "That is not '$($me.login)'."
        }
        Warn 'In the browser window, click your profile picture -> Sign out. Then sign in with your account.'
        $script:Token = $null
    }
}

function Accept-Invitations {
    try { $inv = @(Api '/user/repository_invitations?per_page=100') } catch { Write-Log "invitations: $_"; return }
    foreach ($i in $inv) {
        if ($i.repository.owner.login -ne $Config.Org) { continue }
        if ($i.expired) { Warn "The invitation to $($i.repository.name) has expired. Ask the teacher to invite you again."; continue }
        try { [void](Api "/user/repository_invitations/$($i.id)" 'PATCH' @{}); Ok "Accepted the invitation to $($i.repository.name)" }
        catch { Warn "Could not accept the invitation to $($i.repository.name): $_" }
    }
}

function Get-LabRepos([string]$Login) {
    $all = @()
    for ($page = 1; $page -le 5; $page++) {
        $batch = @(Api "/user/repos?per_page=100&page=$page&affiliation=owner,collaborator,organization_member&sort=created&direction=desc")
        $all += $batch
        if ($batch.Count -lt 100) { break }
    }
    $org = @($all | Where-Object { $_.owner.login -eq $Config.Org -and -not $_.is_template -and -not $_.archived })
    $mine = @($org | Where-Object { $_.name.ToLower().EndsWith('-' + $Login.ToLower()) })
    return @($mine | Sort-Object { [datetime]$_.created_at } -Descending)
}

function Choose-Repo($Me) {
    while ($true) {
        Step 'Finding your lab repos'
        Accept-Invitations
        $repos = @(Get-LabRepos $Me.login)
        if ($repos.Count -gt 0) { break }
        Fail "No lab repo found for $($Me.login) in $($Config.Org)."
        Say '  - Did you accept the assignment link? Open it in the browser and accept it first.' 'Yellow'
        Say '  - After you accept, wait about 1 minute until GitHub creates your repo.' 'Yellow'
        Say '  - Check your e-mail for an invitation from GitHub and accept it.' 'Yellow'
        if (-not (Ask-YesNo 'Search again?' $true)) { return $null }
    }
    $max = [Math]::Min($repos.Count, 9)
    for ($i = 0; $i -lt $max; $i++) {
        $d = ([datetime]$repos[$i].created_at).ToString('yyyy-MM-dd')
        $mark = if ($i -eq 0) { '  <- newest' } else { '' }
        Say ("  {0}) {1}   (created {2}){3}" -f ($i + 1), $repos[$i].name, $d, $mark) 'White'
    }
    if ($max -eq 1) { return $repos[0] }
    $a = Read-Host "Type the number and press Enter (just Enter = 1)"
    $n = 0
    if ([int]::TryParse("$a".Trim(), [ref]$n) -and $n -ge 1 -and $n -le $max) { return $repos[$n - 1] }
    return $repos[0]
}

# --------------------------------------------------------- clone + open

function Clone-Repo($Repo, $Me) {
    Step "Downloading $($Repo.name)"
    New-Item -ItemType Directory -Path $script:SessionDir -Force | Out-Null
    $dir = Join-Path $script:SessionDir $Repo.name
    Remove-Dir $dir
    $credFile = Join-Path $script:SessionDir 'git-credentials'
    # LF only: git credential-store does not accept CRLF lines.
    [IO.File]::WriteAllText($credFile, ("https://{0}:{1}@github.com`n" -f $Me.login, $script:Token), (New-Object Text.ASCIIEncoding))
    $branch = if ($Repo.default_branch) { $Repo.default_branch } else { 'main' }

    $r = Run-Git @('init', '-q', $dir)
    if ($r.Code -ne 0) { throw "git init failed: $($r.Out)" }
    # Use only this session's login for this repo (ignore old saved logins).
    $credPath = $credFile.Replace('\', '/')
    $cfg = "`n[credential]`n`thelper =`n`thelper = store --file '$credPath'`n"
    [IO.File]::AppendAllText((Join-Path $dir '.git\config'), $cfg, (New-Object Text.UTF8Encoding $false))
    $email = "{0}+{1}@users.noreply.github.com" -f $Me.id, $Me.login
    $uname = if ($Me.name) { $Me.name } else { $Me.login }
    [void](Run-Git @('config', 'user.name', $uname) $dir)
    [void](Run-Git @('config', 'user.email', $email) $dir)
    [void](Run-Git @('config', 'push.default', 'current') $dir)
    [void](Run-Git @('remote', 'add', 'origin', $Repo.clone_url) $dir)

    $ok = $false
    for ($try = 1; $try -le 3 -and -not $ok; $try++) {
        $f = Run-Git @('fetch', 'origin') $dir
        if ($f.Code -eq 0) { $ok = $true; break }
        Write-Log "fetch failed: $($f.Out)"
        if ($f.Out -match 'not found') { throw "GitHub says the repo $($Repo.name) is not found for $($Me.login)." }
        if ($f.Out -match 'could not read Username|Authentication failed|Invalid username') { throw "Git could not use your GitHub login. Details: $($f.Out)" }
        Warn "Download failed (try $try of 3). Check the internet connection..."
        Start-Sleep -Seconds (5 * $try)
    }
    if (-not $ok) { throw 'Could not download the repo. Check the internet connection and try again.' }
    $c = Run-Git @('checkout', '-q', '-B', $branch, '--track', "origin/$branch") $dir
    if ($c.Code -ne 0) { throw "git checkout failed: $($c.Out)" }
    Ok "Downloaded to $dir"
    Ok "Git name and e-mail set to $uname <$email>"
    return @{ Dir = $dir; Branch = $branch }
}

function Open-VSCode([string]$Dir) {
    $profileDir = Join-Path $script:SessionDir 'vscode-profile'
    $userDir = Join-Path $profileDir 'User'
    New-Item -ItemType Directory -Path $userDir -Force | Out-Null
    $settings = [ordered]@{
        'git.path'                        = $script:Git
        'git.autofetch'                   = $true
        'git.confirmSync'                 = $false
        'git.enableSmartCommit'           = $true
        'git.postCommitCommand'           = 'push'
        'github.gitAuthentication'        = $false
        'files.autoSave'                  = 'afterDelay'
        'files.hotExit'                   = 'off'
        'security.workspace.trust.enabled' = $false
        'workbench.startupEditor'         = 'none'
        'window.restoreWindows'           = 'none'
        'telemetry.telemetryLevel'        = 'off'
        'update.mode'                     = 'none'
        'extensions.ignoreRecommendations' = $true
        'workbench.welcomePage.walkthroughs.openOnInstall' = $false
        'workbench.tips.enabled'          = $false
        'python.createEnvironment.trigger' = 'off'
    }
    if ($script:Python) { $settings['python.defaultInterpreterPath'] = $script:Python }
    if ($Config.DisableAI) { $settings['chat.disableAIFeatures'] = $true; $settings['github.copilot.enable'] = @{ '*' = $false } }
    Ensure-Extensions $Dir
    $settings | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $userDir 'settings.json') -Encoding UTF8
    $readme = Join-Path $Dir 'README.md'
    $args2 = @('--user-data-dir', "`"$profileDir`"", '--new-window', "`"$Dir`"")
    if (Test-Path -LiteralPath $readme) { $args2 += "`"$readme`"" }
    # Keep VS Code's own log messages out of this window.
    $env:ELECTRON_NO_ATTACH_CONSOLE = '1'
    Start-Process -FilePath $script:Code -ArgumentList $args2 | Out-Null
    return $profileDir
}

# --------------------------------------------- protect the session window

# Turns the close (X) button and Ctrl+C of this window off/on (classic console only).
function Set-WindowProtection([bool]$On) {
    if (-not $On -and -not $script:Protected) { return }
    $script:Protected = $On
    try { [Console]::TreatControlCAsInput = $On } catch { }
    try {
        if (-not ('TtpuWin.Con' -as [type])) {
            Add-Type -Namespace TtpuWin -Name Con -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern IntPtr GetSystemMenu(IntPtr hWnd, bool bRevert);
[DllImport("user32.dll")] public static extern bool EnableMenuItem(IntPtr hMenu, uint uIDEnableItem, uint uEnable);
'@
        }
        $h = [TtpuWin.Con]::GetConsoleWindow()
        if ($h -eq [IntPtr]::Zero) { return }
        if ($On) { [void][TtpuWin.Con]::EnableMenuItem([TtpuWin.Con]::GetSystemMenu($h, $false), 0xF060, 0x1) }
        else { [void][TtpuWin.Con]::GetSystemMenu($h, $true) }
    } catch { Write-Log "window protection: $_" }
}

# Starts a hidden helper that finishes the session if this window is closed before VS Code.
function Start-Guard {
    try {
        $env:TTPU_ARGS = if ($script:Safe) { 'guard safe' } else { 'guard' }
        Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', '"Get-Content -Raw -LiteralPath $env:TTPU_SELF | Invoke-Expression"')
    } catch { Write-Log "guard start failed: $_" }
    finally { $env:TTPU_ARGS = '' }
}

function Guard-Session {
    $script:Git = Find-Git
    if (-not $script:Git) { return }
    while ($true) {
        Start-Sleep -Seconds 5
        $state = Load-State
        if (-not $state) { return }
        if ((Test-SessionCodeRunning $state.ProfileDir) -ne $false) { continue }
        Start-Sleep -Seconds 5
        if ((Test-SessionCodeRunning $state.ProfileDir) -ne $false) { continue }
        if (Test-LauncherRunning) { continue }
        Write-Log 'guard: the TTPU Lab window was closed; finishing the session'
        Write-PidFile
        [void](Finish-Session $false)
        return
    }
}

# Closes the VS Code of the open session so that VS Code asks to save files first.
function Close-SessionCode($State) {
    if (-not $State -or -not $State.ProfileDir) { return }
    foreach ($p in (Get-SessionCodeProcesses $State.ProfileDir)) {
        try { $gp = Get-Process -Id $p.ProcessId -ErrorAction Stop; if ($gp.MainWindowHandle -ne 0) { [void]$gp.CloseMainWindow() } } catch { }
    }
    for ($i = 0; $i -lt 60 -and (Test-SessionCodeRunning $State.ProfileDir) -ne $false; $i++) { Start-Sleep -Seconds 2 }
}

# ------------------------------------------------------------- install

function Get-FileVersion([string]$Path) {
    try {
        $m = Select-String -LiteralPath $Path -Pattern "Version\s*=\s*'([0-9.]+)'" | Select-Object -First 1
        if ($m) { return [version]$m.Matches[0].Groups[1].Value }
    } catch { }
    return [version]'0.0.0'
}

function Install-Tool([bool]$Force = $false) {
    if (-not $script:Self) { return }
    $dest = Join-Path $script:Root 'TTPU-Lab.cmd'
    New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
    $isInstalled = ($script:Self -eq $dest)
    if (-not $isInstalled) {
        if ($Force -or -not (Test-Path -LiteralPath $dest) -or ((Get-FileVersion $script:Self) -gt (Get-FileVersion $dest))) {
            Copy-Item -LiteralPath $script:Self -Destination $dest -Force
            try { Unblock-File -LiteralPath $dest } catch { }
            Write-Log "installed version $($Config.Version)"
        }
    }
    try {
        $desktop = [Environment]::GetFolderPath('Desktop')
        $sh = New-Object -ComObject WScript.Shell
        $made = $false
        foreach ($old in @('TTPU Lab - Start.lnk', 'TTPU Lab - End.lnk')) {
            Remove-Item -LiteralPath (Join-Path $desktop $old) -Force -ErrorAction SilentlyContinue
        }
        foreach ($item in @(@{ Name = 'TTPU Lab'; Arg = ''; Icon = "$env:SystemRoot\System32\shell32.dll,137" })) {
            $lnk = Join-Path $desktop ($item.Name + '.lnk')
            if ((Test-Path -LiteralPath $lnk) -and -not $Force) { continue }
            $s = $sh.CreateShortcut($lnk)
            $s.TargetPath = $dest
            $s.Arguments = $item.Arg
            $s.WorkingDirectory = $script:Root
            $s.IconLocation = $item.Icon
            $s.Save()
            $made = $true
        }
        if ($made) { Ok 'Desktop shortcut "TTPU Lab" is ready. Use it next time.' }
    } catch { Write-Log "shortcut error: $_" }
}

# Gets the newest launcher from UpdateUrl. If it is newer, installs it and starts it instead of this copy.
function Update-Self {
    if (-not $Config.UpdateUrl -or $env:TTPU_UPDATED -eq '1' -or -not $script:Self) { return }
    $tmp = Join-Path $env:TEMP 'TTPU-Lab.update.cmd'
    $ok = $false
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
        if (Test-Path -LiteralPath $curl) {
            & $curl -L -s --fail --connect-timeout 10 --max-time 30 -o $tmp $Config.UpdateUrl 2>$null
            $ok = ($LASTEXITCODE -eq 0)
        }
        if (-not $ok) {
            Invoke-WebRequest -Uri $Config.UpdateUrl -OutFile $tmp -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
            $ok = $true
        }
    } catch { Write-Log "update check failed: $_" } finally { $ErrorActionPreference = $old }
    try {
        if (-not $ok -or -not (Test-Path -LiteralPath $tmp)) { return }
        $text = [IO.File]::ReadAllText($tmp)
        if (-not $text.StartsWith('<# : TTPU Lab launcher') -or -not $text.Contains("`r`n") -or $text -notmatch 'ClientId\s*=') { Write-Log 'update file is not valid'; return }
        $newV = Get-FileVersion $tmp
        if ($newV -le [version]$Config.Version) { return }
        $dest = Join-Path $script:Root 'TTPU-Lab.cmd'
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        Copy-Item -LiteralPath $tmp -Destination $dest -Force
        try { Unblock-File -LiteralPath $dest } catch { }
        Write-Log "updated from $($Config.Version) to $newV"
        Ok "TTPU Lab was updated to $newV. Starting the new version in a new window..."
        $env:TTPU_UPDATED = '1'
        $p = @{ FilePath = $dest; WorkingDirectory = $script:Root }
        if ("$env:TTPU_ARGS".Trim()) { $p.ArgumentList = "$env:TTPU_ARGS".Trim() }
        Start-Process @p
        Start-Sleep -Seconds 2
        exit 0
    } catch { Write-Log "update failed: $_" } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------- main

function Check-Tools {
    $script:Git = Find-Git
    if (-not $script:Git) { $script:Git = Install-Git }
    if (-not $script:Git) { Fail 'Git is missing and could not be installed. Check the internet, or use Codespaces.'; Pause-End; exit 1 }
    $script:Code = Find-Code
    if (-not $script:Code) { $script:Code = Install-VSCode }
    if (-not $script:Code) { Fail 'VS Code is missing and could not be installed. Check the internet, or use Codespaces.'; Pause-End; exit 1 }
    $script:Python = Find-Python
    if (-not $script:Python) { $script:Python = Install-Python }
    if (-not $script:Python) { Warn 'Python could not be installed. You can edit and push code, but you cannot run it on this PC.' }
    Add-PythonToPath $script:Python
    Ensure-Extensions $null
}

function Start-Lab {
    Say ''
    Say "TTPU Lab $($Config.Version) - local VS Code for your lab repo" 'Cyan'
    if ($script:Safe) { Warn 'SAFE MODE (test): old logins on this PC are not removed.' }
    if (-not $Config.ClientId) { Fail 'Teacher setup is missing (ClientId). Tell the teacher.'; Pause-End; exit 1 }
    Update-Self
    Check-Tools
    Confirm-LabPC
    Install-Tool

    $active = Load-State
    if ($active -and $active.ProfileDir -and (Test-SessionCodeRunning $active.ProfileDir) -ne $false) {
        Say ''
        Warn "A lab session of $($active.Login) is still open (VS Code is running)."
        if (Test-LauncherRunning) {
            Say 'Its TTPU Lab window is still open. Close VS Code; that window saves the work and signs out.' 'Yellow'
            Pause-End; exit 0
        }
        if (-not (Ask-YesNo 'Finish that session now (save the work to GitHub and sign out)?' $true)) { Pause-End; exit 0 }
        Write-PidFile
        Say 'Closing VS Code. If it asks to save files, click Save.'
        Close-SessionCode $active
        $r = Finish-Session $true
        if ($r -ne 'done') { Pause-End; exit 0 }
        if (-not (Ask-YesNo 'Start a new lab session (sign in)?' $false)) { Say ''; Say 'All done. You can leave the PC.' 'Green'; Pause-End; exit 0 }
    }

    Finish-Leftover
    Step 'Removing old GitHub logins from this PC'
    Clear-PCLogins
    Ok 'Done.'

    $script:Phase = 'signin'
    $me = SignIn
    if (-not $me) { Say 'Stopped.' 'Yellow'; Pause-End; return }
    $repo = Choose-Repo $me
    if (-not $repo) { $script:Token = $null; [void](Finish-Session $false); Pause-End; return }
    $script:Phase = 'clone'
    $clone = Clone-Repo $repo $me

    Step 'Opening VS Code'
    New-Item -ItemType Directory -Path $script:SessionDir -Force | Out-Null
    Write-PidFile
    $profileDir = Join-Path $script:SessionDir 'vscode-profile'
    Save-State @{ Login = $me.login; Repo = $repo.name; Url = $repo.html_url; RepoDir = $clone.Dir; Branch = $clone.Branch; ProfileDir = $profileDir; Started = (Get-Date).ToString('s') }
    [void](Open-VSCode $clone.Dir)
    $script:Token = $null
    $script:Phase = 'running'
    Start-Guard
    Set-WindowProtection $true

    Say ''
    Say '  VS Code is open. Do your lab work there.' 'Green'
    Say '  - Your files are saved automatically.' 'White'
    Say '  - To save to GitHub any time: Source Control -> write a message -> Commit (it also pushes).' 'White'
    Say '  - When you finish, just CLOSE VS Code. This window then pushes your work and signs you out.' 'White'
    Say ''
    Say '  Do NOT close this window. (If it is closed by mistake, double-click TTPU Lab on the desktop.)' 'Yellow'

    while ($true) {
        $seen = $false
        for ($i = 0; $i -lt 30 -and -not $seen; $i++) { Start-Sleep -Seconds 2; $seen = ((Test-SessionCodeRunning $profileDir) -ne $false) }
        if (-not $seen) { Warn 'Could not see VS Code start. When you finish, close VS Code and press Enter here.'; [void](Read-Host) }
        else { Wait-SessionCodeClosed $profileDir }
        Say ''
        Say 'VS Code is closed.' 'Cyan'
        Set-WindowProtection $false
        $result = Finish-Session $true
        if ($result -ne 'back') { break }
        Say 'Opening VS Code again. Close it when you finish.' 'Yellow'
        [void](Open-VSCode $clone.Dir)
        Set-WindowProtection $true
    }
    if ($result -eq 'done') { Say ''; Say 'All done. You can leave the PC.' 'Green' }
}

function End-Lab {
    Say ''
    Say "TTPU Lab $($Config.Version) - finish the session" 'Cyan'
    $script:Git = Find-Git
    if (Test-LauncherRunning) {
        $state = Load-State
        Say 'The TTPU Lab window is still running. Closing VS Code, then that window saves your work.'
        if ($state) {
            foreach ($p in (Get-SessionCodeProcesses $state.ProfileDir)) {
                try { $gp = Get-Process -Id $p.ProcessId -ErrorAction Stop; if ($gp.MainWindowHandle -ne 0) { [void]$gp.CloseMainWindow() } } catch { }
            }
        }
        Say 'If VS Code asks to save files, click Save. Then look at the TTPU Lab window.'
        Pause-End
        return
    }
    Write-PidFile
    $state = Load-State
    if ($state -and $state.ProfileDir -and (Test-SessionCodeRunning $state.ProfileDir) -ne $false) {
        Say 'Closing VS Code. If it asks to save files, click Save.'
        Close-SessionCode $state
    }
    Confirm-LabPC
    $result = 'done'
    if ($script:Git) { $result = Finish-Session $true } else { Clear-PCLogins }
    Say ''
    if ($result -eq 'done') { Say 'All done. You can leave the PC.' 'Green' }
    elseif ($result -eq 'back') { Say 'Nothing was deleted. Open the repo folder in VS Code, save your work, then double-click TTPU Lab again.' 'Yellow' }
}

try {
    Write-Log "run mode=$script:Mode safe=$script:Safe version=$($Config.Version)"
    switch ($script:Mode) {
        'end' { End-Lab }
        'guard' { Guard-Session }
        'install' { Install-Tool $true }
        default { Start-Lab }
    }
} catch {
    Write-Log "ERROR $_ $($_.ScriptStackTrace)"
    Fail "Error: $_"
    Say "Details are in $script:LogFile" 'DarkGray'
    if ($script:Phase -eq 'signin' -or $script:Phase -eq 'clone') {
        # Nothing to save yet: do not leave the login token on the PC.
        $script:Token = $null
        try { Remove-Dir $script:SessionDir } catch { }
        Say 'Your login was removed from this PC. Double-click TTPU Lab to try again.' 'Yellow'
    }
} finally {
    try { if ((Test-Path -LiteralPath $script:PidFile) -and ((Get-Content -LiteralPath $script:PidFile -Raw).Trim().StartsWith("$PID|"))) { Remove-Item -LiteralPath $script:PidFile -Force } } catch { }
    if ($script:Mode -ne 'guard') { Set-WindowProtection $false }
}
if ($script:Mode -ne 'guard') { Pause-End }
