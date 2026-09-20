#Requires -Version 5.1
<#
    myco core
    ---------
    Shared logic for every myco entry point. This file only defines functions;
    dot-source it, then call Invoke-MycoCore.

    Invoke-MycoCore returns a result object:
        ExitCode : integer status for the shell
        Plan     : $null, or a launch plan describing the directory to move to,
                   the COPILOT_HOME to export, and the copilot arguments.

    The caller owns the launch so that the working-directory change survives in
    the user's own shell.
#>

Set-StrictMode -Off

# Captured at load time so the launcher can be located however core was reached.
$script:MycoLibRoot = $PSScriptRoot

function Get-MycoLauncherPath {
    <#  Full path to bin\myco.ps1, used when a recovered tab needs to define
        the `myco` function for itself rather than rely on a profile. #>
    if (-not $script:MycoLibRoot) { return '' }
    return (Join-Path (Split-Path -Parent $script:MycoLibRoot) 'bin\myco.ps1')
}

function Get-MycoVersion { '1.2.1' }
function Get-MycoSchemaVersion { 1 }
function Get-MycoDefaultSeed { 'full' }
function Get-MycoDefaultMaxSessions { 15 }

# ------------------------------------------------------------------- output

function Test-MycoColor {
    if ($env:NO_COLOR) { return $false }
    return $true
}

function Write-MycoLine {
    param([string]$Text = '', [string]$Color = '')
    if ($Color -and (Test-MycoColor)) {
        Write-Host $Text -ForegroundColor $Color
    } else {
        Write-Host $Text
    }
}

function Write-MycoError {
    param([string]$Message)
    [Console]::Error.WriteLine('myco: ' + $Message)
}

function Write-MycoWarning {
    param([string]$Message)
    [Console]::Error.WriteLine('myco: warning: ' + $Message)
}

# ------------------------------------------------------------------ terminal

function Get-MycoConsoleWidth {
    <#  Console width, or a sensible default. Console::WindowWidth throws when
        output is redirected, which is exactly what happens when a listing is
        piped or captured, so it is never the first choice. #>
    $width = 0
    try {
        $size = $Host.UI.RawUI.WindowSize
        if ($size) { $width = [int]$size.Width }
    } catch { }
    if ($width -le 0) {
        try { $width = [int][Console]::WindowWidth } catch { $width = 0 }
    }
    if ($width -le 0) { $width = 100 }
    if ($width -lt 60) { $width = 60 }
    if ($width -gt 160) { $width = 160 }
    return $width
}

function Get-MycoGlyph {
    <#  Returns the preferred character when the console encoding can carry it,
        otherwise a plain substitute. Code page 437, for instance, has the box
        drawing set but no filled circle or ellipsis. #>
    param([int]$CodePoint, [string]$Fallback, $Encoding)
    $ch = [string][char]$CodePoint
    if (-not $Encoding) { return $Fallback }
    try {
        if ($Encoding.CodePage -eq 65001) { return $ch }
        if ($Encoding.GetString($Encoding.GetBytes($ch)) -eq $ch) { return $ch }
    } catch { }
    return $Fallback
}

function Get-MycoGlyphSet {
    <#  Builds the drawing set for the current console, degrading one character
        at a time so a legacy code page keeps whatever it can render. #>
    $encoding = $null
    try { $encoding = [Console]::OutputEncoding } catch { }

    return [pscustomobject]@{
        TopLeft     = Get-MycoGlyph 0x250C '+' $encoding
        TopRight    = Get-MycoGlyph 0x2510 '+' $encoding
        BottomLeft  = Get-MycoGlyph 0x2514 '+' $encoding
        BottomRight = Get-MycoGlyph 0x2518 '+' $encoding
        Horizontal  = Get-MycoGlyph 0x2500 '-' $encoding
        Vertical    = Get-MycoGlyph 0x2502 '|' $encoding
        TeeLeft     = Get-MycoGlyph 0x251C '+' $encoding
        TeeRight    = Get-MycoGlyph 0x2524 '+' $encoding
        TeeDown     = Get-MycoGlyph 0x252C '+' $encoding
        TeeUp       = Get-MycoGlyph 0x2534 '+' $encoding
        Cross       = Get-MycoGlyph 0x253C '+' $encoding
        Dot         = Get-MycoGlyph 0x25CF '*' $encoding
        Ellipsis    = Get-MycoGlyph 0x2026 '...' $encoding
        Separator   = Get-MycoGlyph 0x00B7 '-' $encoding
    }
}

function Format-MycoCell {
    <#  Pads or truncates a value to exactly the requested width. #>
    param([string]$Text, [int]$Width, [string]$Ellipsis = '...')
    if ($null -eq $Text) { $Text = '' }
    $clean = ($Text -replace '[\r\n\t]', ' ')
    if ($Width -le 0) { return '' }
    if ($clean.Length -gt $Width) {
        if ($Width -le $Ellipsis.Length) { return $clean.Substring(0, $Width) }
        return ($clean.Substring(0, $Width - $Ellipsis.Length) + $Ellipsis)
    }
    return $clean.PadRight($Width)
}

function Format-MycoRelativeTime {
    <#  Turns a timestamp into something readable at a glance. #>
    param([datetime]$Value)
    $delta = [DateTime]::UtcNow - $Value.ToUniversalTime()
    if ($delta.TotalSeconds -lt 60) { return 'just now' }

    if ($delta.TotalMinutes -lt 60) {
        $n = [int][Math]::Floor($delta.TotalMinutes)
        return ([string]$n + ' min ago')
    }
    if ($delta.TotalHours -lt 24) {
        $n = [int][Math]::Floor($delta.TotalHours)
        $unit = ' hours ago'
        if ($n -eq 1) { $unit = ' hour ago' }
        return ([string]$n + $unit)
    }
    if ($delta.TotalDays -lt 7) {
        $n = [int][Math]::Floor($delta.TotalDays)
        $unit = ' days ago'
        if ($n -eq 1) { $unit = ' day ago' }
        return ([string]$n + $unit)
    }
    return $Value.ToLocalTime().ToString('yyyy-MM-dd')
}

# -------------------------------------------------------------------- paths

function Get-MycoHome {
    if ($env:MYCO_HOME) { return $env:MYCO_HOME }
    $appData = $env:APPDATA
    if (-not $appData) {
        $profileDir = $env:USERPROFILE
        if (-not $profileDir) { $profileDir = $HOME }
        $appData = Join-Path $profileDir 'AppData\Roaming'
    }
    return (Join-Path $appData '.myco')
}

function Get-MycoGlobalCopilotHome {
    $profileDir = $env:USERPROFILE
    if (-not $profileDir) { $profileDir = $HOME }
    return (Join-Path $profileDir '.copilot')
}

function Get-MycoRegistryPath { return (Join-Path (Get-MycoHome) 'registry.json') }
function Get-MycoConfigPath { return (Join-Path (Get-MycoHome) 'config.json') }

function ConvertTo-MycoComparablePath {
    param([string]$Path)
    if (-not $Path) { return '' }
    $full = $Path
    try { $full = [System.IO.Path]::GetFullPath($Path) } catch { }
    return $full.TrimEnd([char]92, [char]47).ToLowerInvariant()
}

function Resolve-MycoDirectory {
    param([string]$Path)
    if (-not $Path) { return '' }
    $full = $Path
    try { $full = [System.IO.Path]::GetFullPath($Path) } catch { }
    $root = ''
    try { $root = [System.IO.Path]::GetPathRoot($full) } catch { }
    if ($root -and (ConvertTo-MycoComparablePath $root) -eq (ConvertTo-MycoComparablePath $full)) {
        return $full
    }
    return $full.TrimEnd([char]92, [char]47)
}

function Test-MycoDriveRoot {
    param([string]$Path)
    $full = $Path
    try { $full = [System.IO.Path]::GetFullPath($Path) } catch { return $false }
    $root = ''
    try { $root = [System.IO.Path]::GetPathRoot($full) } catch { return $false }
    if (-not $root) { return $false }
    return ((ConvertTo-MycoComparablePath $root) -eq (ConvertTo-MycoComparablePath $full))
}

function Get-MycoTimestamp {
    return ([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ'))
}

# ----------------------------------------------------------------- json i/o

function Read-MycoJsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $raw = $null
    try { $raw = [System.IO.File]::ReadAllText($Path) } catch { return $null }
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    try { return ($raw | ConvertFrom-Json) } catch { return 'CORRUPT' }
}

function Write-MycoJsonFile {
    param([string]$Path, $Value)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $json = $Value | ConvertTo-Json -Depth 12
    $tmp = $Path + '.tmp'
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tmp, $json, $encoding)
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            [System.IO.File]::Replace($tmp, $Path, $null)
        } else {
            [System.IO.File]::Move($tmp, $Path)
        }
    } catch {
        Copy-Item -LiteralPath $tmp -Destination $Path -Force
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-MycoWithRegistryLock {
    param([scriptblock]$Body)
    $mutex = New-Object System.Threading.Mutex($false, 'Local\myco-registry-v1')
    $held = $false
    try {
        try { $held = $mutex.WaitOne(15000) }
        catch [System.Threading.AbandonedMutexException] { $held = $true }
        return (& $Body)
    } finally {
        if ($held) { try { $mutex.ReleaseMutex() } catch { } }
        $mutex.Dispose()
    }
}

# ------------------------------------------------------------------- config

function Read-MycoConfig {
    $data = Read-MycoJsonFile (Get-MycoConfigPath)
    $seed = Get-MycoDefaultSeed
    $maxSessions = Get-MycoDefaultMaxSessions
    if ($data -and $data -isnot [string]) {
        $names = @($data.PSObject.Properties.Name)
        if ($names -contains 'seed' -and $data.seed) { $seed = [string]$data.seed }
        if ($names -contains 'maxSessions' -and $data.maxSessions) {
            $parsed = 0
            if ([int]::TryParse([string]$data.maxSessions, [ref]$parsed) -and $parsed -gt 0) {
                $maxSessions = $parsed
            }
        }
    }
    if (@('none', 'config', 'full') -notcontains $seed) { $seed = Get-MycoDefaultSeed }
    return [pscustomobject]@{
        schemaVersion = Get-MycoSchemaVersion
        seed          = $seed
        maxSessions   = $maxSessions
    }
}

function Write-MycoConfig {
    param($Config)
    Write-MycoJsonFile -Path (Get-MycoConfigPath) -Value ([pscustomobject]@{
            schemaVersion = Get-MycoSchemaVersion
            seed          = $Config.seed
            maxSessions   = $Config.maxSessions
        })
}

# ----------------------------------------------------------------- registry

function New-MycoEmptyRegistry {
    return [pscustomobject]@{
        schemaVersion = Get-MycoSchemaVersion
        nextId        = 1
        workspaces    = @()
    }
}

function Read-MycoRegistry {
    $path = Get-MycoRegistryPath
    $data = Read-MycoJsonFile $path
    if ($data -is [string] -and $data -eq 'CORRUPT') {
        $backup = $path + '.corrupt-' + ([DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))
        try {
            Move-Item -LiteralPath $path -Destination $backup -Force
            Write-MycoWarning ('registry was not readable; it has been set aside as ' + (Split-Path -Leaf $backup))
        } catch {
            Write-MycoWarning 'registry was not readable and has been ignored'
        }
        return (New-MycoEmptyRegistry)
    }
    if (-not $data) { return (New-MycoEmptyRegistry) }

    $workspaces = New-Object System.Collections.ArrayList
    $names = @($data.PSObject.Properties.Name)
    if ($names -contains 'workspaces' -and $data.workspaces) {
        foreach ($w in @($data.workspaces)) {
            if (-not $w) { continue }
            $wNames = @($w.PSObject.Properties.Name)
            if (($wNames -notcontains 'id') -or ($wNames -notcontains 'path')) { continue }
            if (-not $w.id -or -not $w.path) { continue }
            $origin = 'created'
            if (($wNames -contains 'origin') -and $w.origin) { $origin = [string]$w.origin }
            $createdAt = ''
            if (($wNames -contains 'createdAt') -and $w.createdAt) { $createdAt = [string]$w.createdAt }
            $lastUsedAt = ''
            if (($wNames -contains 'lastUsedAt') -and $w.lastUsedAt) { $lastUsedAt = [string]$w.lastUsedAt }
            [void]$workspaces.Add([pscustomobject]@{
                    id         = [string]$w.id
                    path       = [string]$w.path
                    origin     = $origin
                    createdAt  = $createdAt
                    lastUsedAt = $lastUsedAt
                })
        }
    }

    $nextId = 1
    if ($names -contains 'nextId') {
        $parsed = 0
        if ([int]::TryParse([string]$data.nextId, [ref]$parsed)) { $nextId = $parsed }
    }
    foreach ($w in $workspaces) {
        $parsed = 0
        if ([int]::TryParse($w.id, [ref]$parsed) -and $parsed -ge $nextId) { $nextId = $parsed + 1 }
    }
    if ($nextId -lt 1) { $nextId = 1 }

    return [pscustomobject]@{
        schemaVersion = Get-MycoSchemaVersion
        nextId        = $nextId
        workspaces    = @($workspaces.ToArray())
    }
}

function Write-MycoRegistry {
    param($Registry)
    Write-MycoJsonFile -Path (Get-MycoRegistryPath) -Value ([pscustomobject]@{
            schemaVersion = Get-MycoSchemaVersion
            nextId        = $Registry.nextId
            workspaces    = @($Registry.workspaces)
        })
}

function Format-MycoWorkspaceId {
    param([int]$Number)
    if ($Number -lt 1000) { return ('{0:000}' -f $Number) }
    return ([string]$Number)
}

function Find-MycoWorkspaceById {
    param($Registry, [string]$Id)
    $wanted = $Id.TrimStart('0')
    if (-not $wanted) { $wanted = '0' }
    foreach ($w in @($Registry.workspaces)) {
        $have = ([string]$w.id).TrimStart('0')
        if (-not $have) { $have = '0' }
        if ($have -eq $wanted) { return $w }
    }
    return $null
}

function Find-MycoWorkspaceByPath {
    param($Registry, [string]$Path)
    $key = ConvertTo-MycoComparablePath $Path
    foreach ($w in @($Registry.workspaces)) {
        if ((ConvertTo-MycoComparablePath $w.path) -eq $key) { return $w }
    }
    return $null
}

function Register-MycoWorkspace {
    <#  Adds the folder to the registry if it is new, otherwise refreshes its
        last-used stamp. Returns the workspace record. #>
    param([string]$Path, [string]$Origin = 'created')
    $result = Invoke-MycoWithRegistryLock {
        $registry = Read-MycoRegistry
        $existing = Find-MycoWorkspaceByPath -Registry $registry -Path $Path
        if ($existing) {
            $existing.lastUsedAt = Get-MycoTimestamp
            Write-MycoRegistry $registry
            return $existing
        }
        $workspace = [pscustomobject]@{
            id         = Format-MycoWorkspaceId $registry.nextId
            path       = $Path
            origin     = $Origin
            createdAt  = Get-MycoTimestamp
            lastUsedAt = Get-MycoTimestamp
        }
        $registry.nextId = [int]$registry.nextId + 1
        $registry.workspaces = @(@($registry.workspaces) + @($workspace))
        Write-MycoRegistry $registry
        return $workspace
    }
    return $result
}

function Update-MycoWorkspaceUsage {
    param([string]$Path)
    [void](Invoke-MycoWithRegistryLock {
            $registry = Read-MycoRegistry
            $existing = Find-MycoWorkspaceByPath -Registry $registry -Path $Path
            if ($existing) {
                $existing.lastUsedAt = Get-MycoTimestamp
                Write-MycoRegistry $registry
            }
            return $null
        })
}

# ----------------------------------------------------------------- sessions

function Read-MycoSessionMeta {
    <#  Parses the flat key: value metadata Copilot writes for each session. #>
    param([string]$Path)
    $meta = @{}
    $lines = $null
    try { $lines = [System.IO.File]::ReadAllLines($Path) } catch { return $meta }
    foreach ($line in $lines) {
        if ($line -match '^\s*([A-Za-z0-9_]+)\s*:\s*(.*)$') {
            $key = $Matches[1]
            $value = $Matches[2].Trim()
            if ($value.Length -ge 2) {
                $first = $value.Substring(0, 1)
                $last = $value.Substring($value.Length - 1, 1)
                if ($first -eq '"' -and $last -eq '"') {
                    $value = $value.Substring(1, $value.Length - 2)
                    $value = $value -replace '\\"', '"' -replace '\\\\', '\'
                } elseif ($first -eq "'" -and $last -eq "'") {
                    # YAML single-quoted style escapes an apostrophe by
                    # doubling it, which is how Copilot writes session names.
                    $value = $value.Substring(1, $value.Length - 2)
                    $value = $value -replace "''", "'"
                }
            }
            $meta[$key] = $value
        }
    }
    return $meta
}

function ConvertTo-MycoDate {
    param([string]$Text, [datetime]$Fallback)
    if (-not $Text) { return $Fallback }
    $parsed = [datetime]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor `
        [System.Globalization.DateTimeStyles]::AssumeUniversal
    if ([datetime]::TryParse($Text, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
        return $parsed
    }
    return $Fallback
}

function Get-MycoRunningProcessMap {
    <#  Snapshot of live process ids and their start times, taken once so a
        listing does not pay for a process lookup per session. #>
    $map = @{}
    try {
        foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
            if ($map.ContainsKey($p.Id)) { continue }
            $started = $null
            try { $started = $p.StartTime } catch { }
            $map[$p.Id] = $started
        }
    } catch { }
    return $map
}

function Test-MycoSessionActive {
    <#  A lock proves a session is running only if its process still exists and
        started no later than the lock was written. The process that wrote the
        lock must have been alive at that moment, so anything that started
        afterwards is a different program that inherited a recycled id. #>
    param([string]$SessionDirectory, $ProcessMap)
    $locks = @()
    try {
        $locks = @(Get-ChildItem -LiteralPath $SessionDirectory -Filter 'inuse.*.lock' -File -ErrorAction SilentlyContinue)
    } catch { return $false }

    foreach ($lock in $locks) {
        if ($lock.Name -notmatch '^inuse\.(\d+)\.lock$') { continue }
        $lockPid = 0
        if (-not [int]::TryParse($Matches[1], [ref]$lockPid)) { continue }
        if (-not $ProcessMap.ContainsKey($lockPid)) { continue }

        $started = $ProcessMap[$lockPid]
        # An unreadable start time means a process this session does not own,
        # so it cannot be the Copilot run that wrote the lock.
        if (-not $started) { continue }
        if ($started -le $lock.LastWriteTime.AddMinutes(2)) { return $true }
    }
    return $false
}

function Get-MycoSessions {
    <#  Returns the workspace's sessions, most recently updated first. #>
    param([string]$CopilotHome, [int]$Max = 15)
    $root = Join-Path $CopilotHome 'session-state'
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return @() }

    $found = New-Object System.Collections.ArrayList
    $dirs = @()
    try { $dirs = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction Stop) } catch { return @() }

    foreach ($dir in $dirs) {
        $sessionId = $dir.Name
        $name = ''
        $updatedAt = $dir.LastWriteTimeUtc
        $metaPath = Join-Path $dir.FullName 'workspace.yaml'
        if (Test-Path -LiteralPath $metaPath -PathType Leaf) {
            $meta = Read-MycoSessionMeta -Path $metaPath
            if ($meta.ContainsKey('id') -and $meta['id']) { $sessionId = $meta['id'] }
            if ($meta.ContainsKey('name') -and $meta['name']) { $name = $meta['name'] }
            if ($meta.ContainsKey('updated_at')) {
                $updatedAt = ConvertTo-MycoDate -Text $meta['updated_at'] -Fallback $dir.LastWriteTimeUtc
            }
        }
        [void]$found.Add([pscustomobject]@{
                Id        = $sessionId
                Name      = $name
                UpdatedAt = $updatedAt
                Directory = $dir.FullName
                Active    = $false
            })
    }

    $ordered = @($found.ToArray() | Sort-Object -Property UpdatedAt -Descending)
    if ($Max -gt 0 -and $ordered.Count -gt $Max) {
        $ordered = @($ordered[0..($Max - 1)])
    }

    # Liveness is resolved only for the sessions actually being shown.
    if ($ordered.Count -gt 0) {
        $processMap = Get-MycoRunningProcessMap
        foreach ($session in $ordered) {
            $session.Active = Test-MycoSessionActive -SessionDirectory $session.Directory -ProcessMap $processMap
        }
    }
    return $ordered
}

# ------------------------------------------------------------------ seeding

function Initialize-MycoWorkspaceSeed {
    <#  Copies the user's global Copilot preferences into a brand new project
        .copilot so a myco session behaves like their normal Copilot. Only ever
        called for a folder myco just created. #>
    param([string]$CopilotHome, [string]$Mode)
    if ($Mode -eq 'none') { return }
    $source = Get-MycoGlobalCopilotHome
    if (-not (Test-Path -LiteralPath $source -PathType Container)) { return }
    # Running in the home folder makes the source and the destination the same
    # directory; there is nothing to seed from.
    if ((ConvertTo-MycoComparablePath $source) -eq (ConvertTo-MycoComparablePath $CopilotHome)) { return }

    foreach ($file in @('settings.json', 'mcp-config.json')) {
        $from = Join-Path $source $file
        if (Test-Path -LiteralPath $from -PathType Leaf) {
            try {
                Copy-Item -LiteralPath $from -Destination (Join-Path $CopilotHome $file) -Force -ErrorAction Stop
            } catch {
                Write-MycoWarning ('could not seed ' + $file)
            }
        }
    }

    if ($Mode -ne 'full') { return }
    foreach ($folder in @('skills', 'installed-plugins', 'instructions')) {
        $from = Join-Path $source $folder
        if (Test-Path -LiteralPath $from -PathType Container) {
            try {
                Copy-Item -LiteralPath $from -Destination $CopilotHome -Recurse -Force -ErrorAction Stop
            } catch {
                Write-MycoWarning ('could not seed ' + $folder)
            }
        }
    }
}

# --------------------------------------------------------------------- plan

function New-MycoPlan {
    param([string]$WorkDir, [string]$CopilotHome, [string[]]$CopilotArgs)
    return [pscustomobject]@{
        WorkDir     = $WorkDir
        CopilotHome = $CopilotHome
        CopilotArgs = @($CopilotArgs)
    }
}

function New-MycoResult {
    param([int]$ExitCode = 0, $Plan = $null)
    return [pscustomobject]@{ ExitCode = $ExitCode; Plan = $Plan }
}

function ConvertTo-MycoCmdArg {
    param([string]$Value)
    if ($null -eq $Value) { return '""' }
    $escaped = $Value -replace '%', '%%'
    if ($escaped -eq '') { return '""' }
    if ($escaped -match '[\s&|<>^"()]') {
        return '"' + ($escaped -replace '"', '""') + '"'
    }
    return $escaped
}

function Get-MycoOemEncoding {
    try {
        $codePage = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage
        if ($codePage -gt 0) { return [System.Text.Encoding]::GetEncoding($codePage) }
    } catch { }
    return [System.Text.Encoding]::ASCII
}

function Remove-MycoStalePlanFiles {
    <#  A cmd.exe run interrupted mid-plan never reaches its own cleanup, so the
        fragment would linger in TEMP. Sweep anything clearly abandoned, while
        leaving fresh files alone in case another myco is mid-flight. #>
    param([int]$OlderThanHours = 24)
    $temp = $env:TEMP
    if (-not $temp -or -not (Test-Path -LiteralPath $temp -PathType Container)) { return }
    $cutoff = [DateTime]::UtcNow.AddHours(-[Math]::Abs($OlderThanHours))
    try {
        $stale = @(Get-ChildItem -LiteralPath $temp -Filter 'myco-plan-*.cmd' -File -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTimeUtc -lt $cutoff })
        foreach ($file in $stale) {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
        }
    } catch { }
}

function Write-MycoCmdPlan {
    <#  Emits a batch fragment the calling cmd.exe session runs in-process, so
        the directory change outlives myco. #>
    param([string]$PlanFile, $Plan)
    $restore = if ([string]::IsNullOrEmpty($env:COPILOT_HOME)) {
        'set "COPILOT_HOME="'
    } else {
        'set "COPILOT_HOME=' + $env:COPILOT_HOME + '"'
    }
    $argLine = (@($Plan.CopilotArgs) | ForEach-Object { ConvertTo-MycoCmdArg $_ }) -join ' '
    # Every element is parenthesised: inside an array literal the comma binds
    # tighter than +, which would otherwise split each line into fragments.
    $lines = @(
        '@echo off',
        ('cd /d "' + $Plan.WorkDir + '"'),
        ('set "COPILOT_HOME=' + $Plan.CopilotHome + '"'),
        ('call copilot ' + $argLine),
        'set "MYCO_COPILOT_RC=%ERRORLEVEL%"',
        $restore,
        'set "MYCO_COPILOT_RC=" & exit /b %MYCO_COPILOT_RC%'
    )
    [System.IO.File]::WriteAllLines($PlanFile, $lines, (Get-MycoOemEncoding))
}

# ----------------------------------------------------------------- commands

function Show-MycoHelp {
    Write-MycoLine ''
    Write-MycoLine ('myco ' + (Get-MycoVersion) + ' - per-project Copilot CLI workspaces') 'Cyan'
    Write-MycoLine ''
    Write-MycoLine 'Usage:'
    Write-MycoLine '  myco start [copilot args]      Start a Copilot session for this folder.'
    Write-MycoLine '                                 Creates ./.copilot if it is missing, then'
    Write-MycoLine '                                 runs: copilot --yolo'
    Write-MycoLine '  myco continue [copilot args]   Resume this folder''s most recent session:'
    Write-MycoLine '                                 copilot --yolo --continue'
    Write-MycoLine '  myco sessions                  List every folder myco knows about, with'
    Write-MycoLine '                                 its id and its last 15 sessions.'
    Write-MycoLine '  myco resume <id>               Move into the folder and resume.'
    Write-MycoLine '                                 <id> is 001 (latest session of folder 001)'
    Write-MycoLine '                                 or 001002 (second session of folder 001).'
    Write-MycoLine '  myco recover [options]         Reopen every session touched in the last'
    Write-MycoLine '                                 2 hours, one Windows Terminal tab each.'
    Write-MycoLine '                                 --hours=<n>  widen or narrow the window'
    Write-MycoLine '                                 --dry-run    list them without opening'
    Write-MycoLine '                                 --here       add tabs to this window'
    Write-MycoLine '                                 --max=<n>    raise the tab cap'
    Write-MycoLine '                                 Sessions already running are left alone.'
    Write-MycoLine '  myco status                    Describe the current folder.'
    Write-MycoLine '  myco config [key] [value]      Show or change settings (seed, maxSessions).'
    Write-MycoLine '  myco forget <id>               Drop a folder from the registry only.'
    Write-MycoLine '  myco prune                     Drop folders that no longer exist on disk.'
    Write-MycoLine '  myco version                   Print the version.'
    Write-MycoLine '  myco help                      Show this help.'
    Write-MycoLine ''
    Write-MycoLine 'Each folder gets its own COPILOT_HOME, so sessions, history and settings'
    Write-MycoLine 'stay with the project instead of piling up in one global directory.'
    Write-MycoLine ''
}

function Assert-MycoManageableFolder {
    <#  Returns an error string when the folder must not be managed. The home
        folder is fine: its .copilot is Copilot's default home, so pointing
        COPILOT_HOME at it simply reproduces normal behaviour. #>
    param([string]$Directory)
    if (Test-MycoDriveRoot $Directory) {
        return 'refusing to create a workspace at a drive root. cd into a project folder first.'
    }
    return ''
}

function Test-MycoGlobalCopilotFolder {
    param([string]$Directory)
    $copilotHome = Join-Path $Directory '.copilot'
    return ((ConvertTo-MycoComparablePath $copilotHome) -eq (ConvertTo-MycoComparablePath (Get-MycoGlobalCopilotHome)))
}

function Invoke-MycoLaunch {
    param([string]$Directory, [string[]]$ExtraArgs, [switch]$Continue)

    $problem = Assert-MycoManageableFolder -Directory $Directory
    if ($problem) {
        Write-MycoError $problem
        return (New-MycoResult 2)
    }

    $copilotHome = Join-Path $Directory '.copilot'
    $existed = Test-Path -LiteralPath $copilotHome -PathType Container
    if (-not $existed) {
        try {
            New-Item -ItemType Directory -Force -Path $copilotHome -ErrorAction Stop | Out-Null
        } catch {
            Write-MycoError ('could not create .copilot here: ' + $_.Exception.Message)
            return (New-MycoResult 1)
        }
        Initialize-MycoWorkspaceSeed -CopilotHome $copilotHome -Mode (Read-MycoConfig).seed
    }

    $origin = if ($existed) { 'adopted' } else { 'created' }
    $workspace = Register-MycoWorkspace -Path $Directory -Origin $origin

    $copilotArgs = @('--yolo')
    if ($Continue) { $copilotArgs += '--continue' }
    if ($ExtraArgs) { $copilotArgs += @($ExtraArgs) }

    $verb = if ($existed) { $workspace.origin } else { 'created' }
    Write-MycoLine ('myco [' + $workspace.id + '] ' + (Split-Path -Leaf $Directory) + '  (' + $verb + ')') 'DarkCyan'

    return (New-MycoResult 0 (New-MycoPlan -WorkDir $Directory -CopilotHome $copilotHome -CopilotArgs $copilotArgs))
}

function Format-MycoSessionName {
    param([string]$Name, [int]$Width = 46)
    if (-not $Name) { return '(unnamed)' }
    $clean = ($Name -replace '\s+', ' ').Trim()
    if ($clean.Length -le $Width) { return $clean }
    return ($clean.Substring(0, $Width - 1) + [char]0x2026)
}

function Write-MycoTableRule {
    <#  Draws one horizontal rule with the right junction glyphs. #>
    param($Glyphs, [int[]]$Widths, [string]$Left, [string]$Middle, [string]$Right)
    $parts = @()
    foreach ($w in $Widths) { $parts += ([string]$Glyphs.Horizontal * ($w + 2)) }
    Write-MycoLine ($Left + ($parts -join $Middle) + $Right) 'DarkGray'
}

function Show-MycoWorkspaceTable {
    <#  Renders one workspace: a titled frame, a column heading, then a row per
        session. Column widths are fixed for the whole table so every row lines
        up, and the name column absorbs whatever width is left. #>
    param($Workspace, $Sessions, $Glyphs, [int]$Width)

    $idWidth = 8
    $statusWidth = 8
    $whenWidth = 12
    # Four columns plus their padding and five vertical rules.
    $overhead = ($idWidth + $statusWidth + $whenWidth) + (4 * 2) + 5
    $nameWidth = $Width - $overhead
    if ($nameWidth -lt 12) { $nameWidth = 12 }
    $widths = @($idWidth, $statusWidth, $whenWidth, $nameWidth)
    $innerWidth = $overhead + $nameWidth - 2

    $title = '[' + $Workspace.id + '] ' + (Split-Path -Leaf $Workspace.path) + ' (' + $Workspace.origin + ')'
    $titleText = ([string]$Glyphs.Horizontal) + ' ' + $title + ' '
    if ($titleText.Length -gt $innerWidth) {
        $titleText = $titleText.Substring(0, $innerWidth)
    }
    $fill = [string]$Glyphs.Horizontal * ($innerWidth - $titleText.Length)
    Write-MycoLine ([string]$Glyphs.TopLeft + $titleText + $fill + [string]$Glyphs.TopRight) 'Cyan'

    Write-MycoLine ([string]$Glyphs.Vertical + ' ' + (Format-MycoCell $Workspace.path ($innerWidth - 2) $Glyphs.Ellipsis) +
        ' ' + [string]$Glyphs.Vertical) 'DarkGray'

    Write-MycoTableRule -Glyphs $Glyphs -Widths $widths `
        -Left ([string]$Glyphs.TeeLeft) -Middle ([string]$Glyphs.TeeDown) -Right ([string]$Glyphs.TeeRight)

    $heading = [string]$Glyphs.Vertical + ' ' + (Format-MycoCell 'ID' $idWidth) +
    ' ' + [string]$Glyphs.Vertical + ' ' + (Format-MycoCell 'STATUS' $statusWidth) +
    ' ' + [string]$Glyphs.Vertical + ' ' + (Format-MycoCell 'WHEN' $whenWidth) +
    ' ' + [string]$Glyphs.Vertical + ' ' + (Format-MycoCell 'SESSION' $nameWidth) +
    ' ' + [string]$Glyphs.Vertical
    Write-MycoLine $heading 'White'

    Write-MycoTableRule -Glyphs $Glyphs -Widths $widths `
        -Left ([string]$Glyphs.TeeLeft) -Middle ([string]$Glyphs.Cross) -Right ([string]$Glyphs.TeeRight)

    $index = 0
    foreach ($session in $Sessions) {
        $index++
        $sessionId = $Workspace.id + ('{0:000}' -f $index)
        $status = ''
        if ($session.Active) { $status = [string]$Glyphs.Dot + ' active' }
        $name = $session.Name
        if (-not $name) { $name = '(unnamed)' }

        $row = [string]$Glyphs.Vertical + ' ' + (Format-MycoCell $sessionId $idWidth) +
        ' ' + [string]$Glyphs.Vertical + ' ' + (Format-MycoCell $status $statusWidth) +
        ' ' + [string]$Glyphs.Vertical + ' ' + (Format-MycoCell (Format-MycoRelativeTime $session.UpdatedAt) $whenWidth) +
        ' ' + [string]$Glyphs.Vertical + ' ' + (Format-MycoCell $name $nameWidth $Glyphs.Ellipsis) +
        ' ' + [string]$Glyphs.Vertical

        $colour = ''
        if ($session.Active) { $colour = 'Green' }
        Write-MycoLine $row $colour
    }

    Write-MycoTableRule -Glyphs $Glyphs -Widths $widths `
        -Left ([string]$Glyphs.BottomLeft) -Middle ([string]$Glyphs.TeeUp) -Right ([string]$Glyphs.BottomRight)
}

function Show-MycoWorkspaceNote {
    <#  A framed one-line message for a workspace with nothing to tabulate. #>
    param($Workspace, [string]$Note, $Glyphs, [int]$Width, [string]$Colour)
    $innerWidth = $Width - 2
    $title = '[' + $Workspace.id + '] ' + (Split-Path -Leaf $Workspace.path) + ' (' + $Workspace.origin + ')'
    $titleText = ([string]$Glyphs.Horizontal) + ' ' + $title + ' '
    if ($titleText.Length -gt $innerWidth) { $titleText = $titleText.Substring(0, $innerWidth) }
    $fill = [string]$Glyphs.Horizontal * ($innerWidth - $titleText.Length)
    Write-MycoLine ([string]$Glyphs.TopLeft + $titleText + $fill + [string]$Glyphs.TopRight) 'Cyan'
    Write-MycoLine ([string]$Glyphs.Vertical + ' ' + (Format-MycoCell $Workspace.path ($innerWidth - 2) $Glyphs.Ellipsis) +
        ' ' + [string]$Glyphs.Vertical) 'DarkGray'
    Write-MycoLine ([string]$Glyphs.Vertical + ' ' + (Format-MycoCell $Note ($innerWidth - 2) $Glyphs.Ellipsis) +
        ' ' + [string]$Glyphs.Vertical) $Colour
    Write-MycoLine ([string]$Glyphs.BottomLeft + ([string]$Glyphs.Horizontal * $innerWidth) + [string]$Glyphs.BottomRight) 'DarkGray'
}

function Show-MycoSessions {
    $registry = Read-MycoRegistry
    $config = Read-MycoConfig
    $workspaces = @($registry.workspaces)

    if ($workspaces.Count -eq 0) {
        Write-MycoLine ''
        Write-MycoLine 'No workspaces yet. Run "myco start" inside a project folder.'
        Write-MycoLine ''
        return (New-MycoResult 0)
    }

    $glyphs = Get-MycoGlyphSet
    $width = Get-MycoConsoleWidth

    # Gathered up front so the summary can lead with the running count.
    $rendered = New-Object System.Collections.ArrayList
    $activeTotal = 0
    foreach ($workspace in $workspaces) {
        $sessions = @()
        $note = ''
        if (-not (Test-Path -LiteralPath $workspace.path -PathType Container)) {
            $note = 'folder is missing - run "myco prune" to clean up'
        } else {
            $sessions = @(Get-MycoSessions -CopilotHome (Join-Path $workspace.path '.copilot') -Max $config.maxSessions)
            if ($sessions.Count -eq 0) { $note = 'no sessions yet' }
            $activeTotal += @($sessions | Where-Object { $_.Active }).Count
        }
        [void]$rendered.Add([pscustomobject]@{ Workspace = $workspace; Sessions = $sessions; Note = $note })
    }

    $workspaceWord = 'workspaces'
    if ($workspaces.Count -eq 1) { $workspaceWord = 'workspace' }
    $sep = ' ' + [string]$glyphs.Separator + ' '
    Write-MycoLine ''
    Write-MycoLine ('  myco' + $sep + $workspaces.Count + ' ' + $workspaceWord + $sep +
        $activeTotal + ' active') 'Cyan'
    Write-MycoLine ''

    foreach ($entry in $rendered) {
        if ($entry.Note) {
            $colour = 'DarkGray'
            if ($entry.Note -like 'folder is missing*') { $colour = 'DarkYellow' }
            Show-MycoWorkspaceNote -Workspace $entry.Workspace -Note $entry.Note `
                -Glyphs $glyphs -Width $width -Colour $colour
        } else {
            Show-MycoWorkspaceTable -Workspace $entry.Workspace -Sessions $entry.Sessions `
                -Glyphs $glyphs -Width $width
        }
        Write-MycoLine ''
    }

    Write-MycoLine ('  ' + [string]$glyphs.Dot + ' active = a Copilot process is running.  ' +
        'Resume with: myco resume <id>') 'DarkGray'
    Write-MycoLine ''
    return (New-MycoResult 0)
}

function Invoke-MycoResume {
    param([string]$Directory, [string[]]$ResumeArgs)

    if (-not $ResumeArgs -or @($ResumeArgs).Count -eq 0) {
        Write-MycoError 'usage: myco resume <id>   (see "myco sessions" for ids)'
        return (New-MycoResult 2)
    }

    $token = [string]$ResumeArgs[0]
    $extra = @()
    if (@($ResumeArgs).Count -gt 1) { $extra = @($ResumeArgs[1..(@($ResumeArgs).Count - 1)]) }

    $normalised = $token -replace '[.\-_/]', ''
    if ($normalised -notmatch '^(\d{3})(\d{3})?$') {
        return (Invoke-MycoResumeRaw -Directory $Directory -Token $token -ExtraArgs $extra)
    }

    $workspaceId = $Matches[1]
    $sessionIndex = $Matches[2]

    $registry = Read-MycoRegistry
    $workspace = Find-MycoWorkspaceById -Registry $registry -Id $workspaceId
    if (-not $workspace) {
        Write-MycoError ('unknown workspace id ' + $workspaceId + '. Run "myco sessions" to see the ids.')
        return (New-MycoResult 2)
    }
    if (-not (Test-Path -LiteralPath $workspace.path -PathType Container)) {
        Write-MycoError ('workspace ' + $workspaceId + ' is missing from disk. Run "myco prune" to clean up.')
        return (New-MycoResult 2)
    }

    $copilotHome = Join-Path $workspace.path '.copilot'
    $copilotArgs = @('--yolo')

    if ($sessionIndex) {
        $config = Read-MycoConfig
        $sessions = @(Get-MycoSessions -CopilotHome $copilotHome -Max $config.maxSessions)
        $index = [int]$sessionIndex
        if ($index -lt 1 -or $index -gt $sessions.Count) {
            Write-MycoError ('workspace ' + $workspaceId + ' has only ' + $sessions.Count +
                ' listed session(s), so there is no session ' + $token + '.')
            return (New-MycoResult 2)
        }
        $copilotArgs += ('--resume=' + $sessions[$index - 1].Id)
    } else {
        $copilotArgs += '--continue'
    }
    $copilotArgs += $extra

    Update-MycoWorkspaceUsage -Path $workspace.path
    Write-MycoLine ('myco [' + $workspace.id + '] ' + (Split-Path -Leaf $workspace.path)) 'DarkCyan'

    return (New-MycoResult 0 (New-MycoPlan -WorkDir $workspace.path -CopilotHome $copilotHome -CopilotArgs $copilotArgs))
}

function Invoke-MycoResumeRaw {
    <#  Anything that is not a myco id is handed to copilot as-is, so session
        uuids, id prefixes and session names keep working. #>
    param([string]$Directory, [string]$Token, [string[]]$ExtraArgs)
    $copilotHome = Join-Path $Directory '.copilot'
    if (-not (Test-Path -LiteralPath $copilotHome -PathType Container)) {
        Write-MycoError ('"' + $Token + '" is not a myco id, and this folder has no .copilot to search. ' +
            'Run "myco sessions" for ids.')
        return (New-MycoResult 2)
    }
    $copilotArgs = @('--yolo', ('--resume=' + $Token)) + @($ExtraArgs)
    Update-MycoWorkspaceUsage -Path $Directory
    return (New-MycoResult 0 (New-MycoPlan -WorkDir $Directory -CopilotHome $copilotHome -CopilotArgs $copilotArgs))
}

function Get-MycoDefaultRecoverHours { 2 }
function Get-MycoDefaultRecoverMax { 12 }

function Read-MycoRecoverOptions {
    <#  Parses recover's flags. Returns an object with an Error string set when
        something is wrong, so the caller can report and stop. #>
    param([string[]]$Arguments)
    $options = [pscustomobject]@{
        Hours     = Get-MycoDefaultRecoverHours
        Max       = Get-MycoDefaultRecoverMax
        DryRun    = $false
        Here      = $false
        Error     = ''
    }

    $argv = @($Arguments)
    for ($i = 0; $i -lt $argv.Count; $i++) {
        $arg = [string]$argv[$i]
        $name = $arg
        $value = $null
        if ($arg -match '^(--[a-zA-Z-]+)=(.*)$') {
            $name = $Matches[1]
            $value = $Matches[2]
        }

        switch ($name.ToLowerInvariant()) {
            '--hours' {
                if ($null -eq $value) {
                    if ($i + 1 -ge $argv.Count) {
                        $options.Error = '--hours needs a number, for example: myco recover --hours=6'
                        return $options
                    }
                    $i++
                    $value = [string]$argv[$i]
                }
                $parsed = 0.0
                if (-not [double]::TryParse($value, [System.Globalization.NumberStyles]::Float,
                        [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed) -or
                    $parsed -le 0 -or $parsed -gt 8760) {
                    $options.Error = ('--hours must be a positive number of hours, got "' + $value + '"')
                    return $options
                }
                $options.Hours = $parsed
            }
            '--max' {
                if ($null -eq $value) {
                    if ($i + 1 -ge $argv.Count) {
                        $options.Error = '--max needs a number, for example: myco recover --max=20'
                        return $options
                    }
                    $i++
                    $value = [string]$argv[$i]
                }
                $parsed = 0
                if (-not [int]::TryParse($value, [ref]$parsed) -or $parsed -lt 1) {
                    $options.Error = ('--max must be a whole number of tabs, got "' + $value + '"')
                    return $options
                }
                $options.Max = $parsed
            }
            '--dry-run' { $options.DryRun = $true }
            '--here' { $options.Here = $true }
            '--all' {
                $options.Error = ('--all is no longer accepted. recover never reopens a session that ' +
                    'already has a live Copilot process, because a second process would contend for ' +
                    'the same session. Use "myco sessions" to see them, or "myco resume <id>".')
                return $options
            }
            default {
                $options.Error = ('unknown option "' + $arg +
                    '". recover accepts --hours, --max, --dry-run and --here.')
                return $options
            }
        }
    }
    return $options
}

function Get-MycoRecoverCandidates {
    <#  Every session across every workspace that was touched inside the window,
        newest first, together with a count of those left alone because they
        are still running. A session with a live Copilot process is never
        reopened: it did not need recovering, and a second process would
        contend for the same session state. #>
    param($Registry, [double]$Hours, [int]$PerWorkspace)
    $cutoff = [DateTime]::UtcNow.AddHours(-$Hours)
    $found = New-Object System.Collections.ArrayList
    $running = 0

    foreach ($workspace in @($Registry.workspaces)) {
        if (-not (Test-Path -LiteralPath $workspace.path -PathType Container)) { continue }
        $sessions = @(Get-MycoSessions -CopilotHome (Join-Path $workspace.path '.copilot') -Max $PerWorkspace)
        $index = 0
        foreach ($session in $sessions) {
            $index++
            if ($session.UpdatedAt.ToUniversalTime() -lt $cutoff) { continue }
            if ($session.Active) { $running++; continue }
            [void]$found.Add([pscustomobject]@{
                    WorkspaceId = $workspace.id
                    Path        = $workspace.path
                    ShortId     = $workspace.id + ('{0:000}' -f $index)
                    SessionId   = $session.Id
                    Name        = $session.Name
                    UpdatedAt   = $session.UpdatedAt
                })
        }
    }

    return [pscustomobject]@{
        Sessions = @($found.ToArray() | Sort-Object -Property UpdatedAt -Descending)
        Running  = $running
    }
}

function Get-MycoTabShell {
    <#  The PowerShell used inside a recovered tab. pwsh when present, because
        it is the better terminal, falling back to the one every box has. #>
    if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { return 'pwsh.exe' }
    return 'powershell.exe'
}

function Format-MycoTabTitle {
    <#  Windows Terminal splits its command line on ';' wherever it appears, so
        a title carrying one would start a second, broken tab. Nothing else
        needs escaping, because arguments are passed as argv rather than
        through a shell. #>
    param([string]$Text)
    if (-not $Text) { return '' }
    return (($Text -replace ';', ',') -replace '[\r\n\t]', ' ').Trim()
}

function New-MycoRecoverTabArgs {
    <#  Builds the Windows Terminal argument list: one new-tab per session,
        separated by the literal ';' that wt uses to chain subcommands. No
        other argument may contain a semicolon. #>
    param($Candidates, [bool]$Here)

    $launcher = Get-MycoLauncherPath
    $shell = Get-MycoTabShell
    $wtArgs = New-Object System.Collections.ArrayList

    if ($Here) {
        # 0 is the current window; tabs join it instead of opening a new one.
        [void]$wtArgs.Add('-w'); [void]$wtArgs.Add('0')
    } else {
        [void]$wtArgs.Add('-w'); [void]$wtArgs.Add('new')
    }

    $first = $true
    foreach ($candidate in $Candidates) {
        if (-not $first) { [void]$wtArgs.Add(';') }
        $first = $false

        $title = Format-MycoTabTitle $candidate.Name
        if (-not $title) { $title = Split-Path -Leaf $candidate.Path }

        # Run the launcher as a script file rather than an inline command: it
        # defines the myco function and then runs the arguments it was given,
        # so no statement separator is needed and nothing can be split. The
        # session is resumed by uuid, never by a list position.
        [void]$wtArgs.Add('new-tab')
        [void]$wtArgs.Add('--title')
        [void]$wtArgs.Add($title)
        [void]$wtArgs.Add('-d')
        [void]$wtArgs.Add($candidate.Path)
        [void]$wtArgs.Add($shell)
        [void]$wtArgs.Add('-NoExit')
        [void]$wtArgs.Add('-File')
        [void]$wtArgs.Add($launcher)
        [void]$wtArgs.Add('resume')
        [void]$wtArgs.Add($candidate.SessionId)
    }

    return @($wtArgs.ToArray())
}

function Invoke-MycoRecover {
    param([string[]]$RecoverArgs)

    $options = Read-MycoRecoverOptions -Arguments $RecoverArgs
    if ($options.Error) {
        Write-MycoError $options.Error
        return (New-MycoResult 2)
    }

    $registry = Read-MycoRegistry
    if (@($registry.workspaces).Count -eq 0) {
        Write-MycoLine ''
        Write-MycoLine 'No workspaces yet, so there is nothing to recover.'
        Write-MycoLine ''
        return (New-MycoResult 0)
    }

    $config = Read-MycoConfig
    $scan = Get-MycoRecoverCandidates -Registry $registry -Hours $options.Hours `
        -PerWorkspace $config.maxSessions
    $candidates = @($scan.Sessions)
    $running = [int]$scan.Running

    $glyphs = Get-MycoGlyphSet
    $window = Format-MycoHours $options.Hours
    $runningNote = ''
    if ($running -gt 0) {
        $word = 'sessions are'
        if ($running -eq 1) { $word = 'session is' }
        $runningNote = '  ' + $running + ' ' + $word + ' still running and already open, so left alone.'
    }

    if ($candidates.Count -eq 0) {
        Write-MycoLine ''
        Write-MycoLine ('  Nothing to recover from the last ' + $window + '.') 'Cyan'
        if ($runningNote) { Write-MycoLine $runningNote 'DarkGray' }
        Write-MycoLine ''
        return (New-MycoResult 0)
    }

    Write-MycoLine ''
    $verb = 'Recovering'
    if ($options.DryRun) { $verb = 'Would recover' }
    Write-MycoLine ('  ' + $verb + ' ' + $candidates.Count + ' session(s) from the last ' + $window) 'Cyan'
    if ($runningNote) { Write-MycoLine $runningNote 'DarkGray' }
    Write-MycoLine ''
    foreach ($candidate in $candidates) {
        $name = $candidate.Name
        if (-not $name) { $name = '(unnamed)' }
        $folder = Split-Path -Leaf $candidate.Path
        $nameWidth = (Get-MycoConsoleWidth) - 34 - $folder.Length
        if ($nameWidth -lt 16) { $nameWidth = 16 }
        Write-MycoLine ('   ' + [string]$glyphs.Separator + ' ' + $candidate.ShortId + '  ' +
            (Format-MycoCell (Format-MycoRelativeTime $candidate.UpdatedAt) 12) + '  ' +
            $folder + '  ' + (Format-MycoCell $name $nameWidth $glyphs.Ellipsis).TrimEnd())
    }
    Write-MycoLine ''

    if ($candidates.Count -gt $options.Max) {
        Write-MycoError ('that is ' + $candidates.Count + ' tabs, more than the cap of ' + $options.Max +
            '. Narrow it with --hours, or raise the cap with --max=' + $candidates.Count + '.')
        return (New-MycoResult 2)
    }

    if ($options.DryRun) {
        Write-MycoLine '  Dry run: nothing was opened.' 'DarkGray'
        Write-MycoLine ''
        return (New-MycoResult 0)
    }

    if (-not (Get-Command wt -ErrorAction SilentlyContinue)) {
        Write-MycoError ('Windows Terminal (wt) was not found on PATH, so tabs cannot be opened. ' +
            'Install it from the Microsoft Store, use "myco recover --dry-run" to see the list, ' +
            'or reopen one at a time with "myco resume <id>".')
        return (New-MycoResult 3)
    }

    $wtArgs = New-MycoRecoverTabArgs -Candidates $candidates -Here $options.Here
    try {
        & wt @wtArgs
    } catch {
        Write-MycoError ('could not launch Windows Terminal: ' + $_.Exception.Message)
        return (New-MycoResult 1)
    }

    $where = 'a new window'
    if ($options.Here) { $where = 'this window' }
    Write-MycoLine ('  Opened ' + $candidates.Count + ' tab(s) in ' + $where + '.') 'Green'
    Write-MycoLine ''
    return (New-MycoResult 0)
}

function Format-MycoHours {
    param([double]$Hours)
    if ([Math]::Abs($Hours - [Math]::Round($Hours)) -lt 0.001) {
        $whole = [int][Math]::Round($Hours)
        $unit = ' hours'
        if ($whole -eq 1) { $unit = ' hour' }
        return ([string]$whole + $unit)
    }
    return ($Hours.ToString('0.##', [System.Globalization.CultureInfo]::InvariantCulture) + ' hours')
}

function Show-MycoStatus {
    param([string]$Directory)
    $config = Read-MycoConfig
    $registry = Read-MycoRegistry
    $workspace = Find-MycoWorkspaceByPath -Registry $registry -Path $Directory
    $copilotHome = Join-Path $Directory '.copilot'

    Write-MycoLine ''
    Write-MycoLine ('myco ' + (Get-MycoVersion)) 'Cyan'
    Write-MycoLine ('  state        ' + (Get-MycoHome))
    Write-MycoLine ('  seed         ' + $config.seed)
    Write-MycoLine ('  maxSessions  ' + $config.maxSessions)
    Write-MycoLine ('  workspaces   ' + @($registry.workspaces).Count)
    Write-MycoLine ''
    Write-MycoLine ('  folder       ' + $Directory)

    $problem = Assert-MycoManageableFolder -Directory $Directory
    if ($workspace) {
        Write-MycoLine ('  workspace    [' + $workspace.id + ']  (' + $workspace.origin + ')') 'White'
    } elseif ($problem) {
        Write-MycoLine ('  workspace    not available here - ' + $problem) 'DarkYellow'
    } elseif (Test-Path -LiteralPath $copilotHome -PathType Container) {
        Write-MycoLine '  workspace    not registered yet - run "myco start" here to adopt it'
    } else {
        Write-MycoLine '  workspace    none - run "myco start" here to create one'
    }

    if (Test-MycoGlobalCopilotFolder -Directory $Directory) {
        Write-MycoLine '  note         this folder holds your global Copilot home' 'DarkYellow'
    }

    if (Test-Path -LiteralPath $copilotHome -PathType Container) {
        $sessions = @(Get-MycoSessions -CopilotHome $copilotHome -Max $config.maxSessions)
        $active = @($sessions | Where-Object { $_.Active }).Count
        Write-MycoLine ('  sessions     ' + $sessions.Count + ' listed, ' + $active + ' active')
    }
    Write-MycoLine ''
    return (New-MycoResult 0)
}

function Invoke-MycoConfig {
    param([string[]]$ConfigArgs)
    $config = Read-MycoConfig
    $count = @($ConfigArgs).Count

    if ($count -eq 0) {
        Write-MycoLine ''
        Write-MycoLine 'myco config' 'Cyan'
        Write-MycoLine ('  seed         ' + $config.seed + '    (none | config | full)')
        Write-MycoLine ('  maxSessions  ' + $config.maxSessions)
        Write-MycoLine ''
        Write-MycoLine '  none   a new .copilot starts empty'
        Write-MycoLine '  config copies settings.json and mcp-config.json from your global Copilot home'
        Write-MycoLine '  full   also copies skills, instructions and installed plugins'
        Write-MycoLine ''
        return (New-MycoResult 0)
    }

    $key = ([string]$ConfigArgs[0]).ToLowerInvariant()
    if ($count -lt 2) {
        Write-MycoError 'usage: myco config <seed|maxSessions> <value>'
        return (New-MycoResult 2)
    }
    $value = [string]$ConfigArgs[1]

    switch ($key) {
        'seed' {
            $normalised = $value.ToLowerInvariant()
            if (@('none', 'config', 'full') -notcontains $normalised) {
                Write-MycoError 'seed must be one of: none, config, full'
                return (New-MycoResult 2)
            }
            $config.seed = $normalised
        }
        'maxsessions' {
            $parsed = 0
            if (-not [int]::TryParse($value, [ref]$parsed) -or $parsed -lt 1 -or $parsed -gt 999) {
                Write-MycoError 'maxSessions must be a whole number between 1 and 999'
                return (New-MycoResult 2)
            }
            $config.maxSessions = $parsed
        }
        default {
            Write-MycoError ('unknown setting "' + $ConfigArgs[0] + '". Known settings: seed, maxSessions')
            return (New-MycoResult 2)
        }
    }

    Write-MycoConfig $config
    Write-MycoLine ('myco config ' + $key + ' = ' + $value)
    return (New-MycoResult 0)
}

function Invoke-MycoForget {
    param([string[]]$ForgetArgs)
    if (-not $ForgetArgs -or @($ForgetArgs).Count -eq 0) {
        Write-MycoError 'usage: myco forget <workspace-id>'
        return (New-MycoResult 2)
    }
    $wanted = ([string]$ForgetArgs[0]) -replace '[.\-_/]', ''
    $removed = Invoke-MycoWithRegistryLock {
        $registry = Read-MycoRegistry
        $workspace = Find-MycoWorkspaceById -Registry $registry -Id $wanted
        if (-not $workspace) { return $null }
        $registry.workspaces = @(@($registry.workspaces) | Where-Object { $_.id -ne $workspace.id })
        Write-MycoRegistry $registry
        return $workspace
    }
    if (-not $removed) {
        Write-MycoError ('unknown workspace id ' + $wanted + '. Run "myco sessions" to see the ids.')
        return (New-MycoResult 2)
    }
    Write-MycoLine ('myco forgot [' + $removed.id + '] ' + (Split-Path -Leaf $removed.path) +
        '  (the folder itself was left untouched)')
    return (New-MycoResult 0)
}

function Invoke-MycoPrune {
    $removed = Invoke-MycoWithRegistryLock {
        $registry = Read-MycoRegistry
        $gone = @(@($registry.workspaces) | Where-Object {
                -not (Test-Path -LiteralPath $_.path -PathType Container)
            })
        if ($gone.Count -gt 0) {
            $keep = @(@($registry.workspaces) | Where-Object {
                    Test-Path -LiteralPath $_.path -PathType Container
                })
            $registry.workspaces = @($keep)
            Write-MycoRegistry $registry
        }
        return $gone
    }
    $count = @($removed).Count
    if ($count -eq 0) {
        Write-MycoLine 'myco prune: nothing to remove.'
    } else {
        foreach ($workspace in @($removed)) {
            Write-MycoLine ('myco prune: dropped [' + $workspace.id + '] ' + (Split-Path -Leaf $workspace.path))
        }
    }
    return (New-MycoResult 0)
}

# --------------------------------------------------------------- dispatcher

function Invoke-MycoCore {
    param(
        [string[]]$Arguments = @(),
        [string]$CurrentDirectory = ''
    )

    if (-not $CurrentDirectory) { $CurrentDirectory = (Get-Location).Path }
    $directory = Resolve-MycoDirectory $CurrentDirectory

    $argv = @()
    foreach ($a in @($Arguments)) { if ($null -ne $a) { $argv += [string]$a } }

    if ($argv.Count -eq 0) {
        Show-MycoHelp
        return (New-MycoResult 0)
    }

    $command = $argv[0]
    $rest = @()
    if ($argv.Count -gt 1) { $rest = @($argv[1..($argv.Count - 1)]) }

    try {
        switch ($command.ToLowerInvariant()) {
            'start' { return (Invoke-MycoLaunch -Directory $directory -ExtraArgs $rest) }
            'continue' { return (Invoke-MycoLaunch -Directory $directory -ExtraArgs $rest -Continue) }
            'sessions' { return (Show-MycoSessions) }
            'list' { return (Show-MycoSessions) }
            'ls' { return (Show-MycoSessions) }
            'resume' { return (Invoke-MycoResume -Directory $directory -ResumeArgs $rest) }
            'recover' { return (Invoke-MycoRecover -RecoverArgs $rest) }
            'status' { return (Show-MycoStatus -Directory $directory) }
            'config' { return (Invoke-MycoConfig -ConfigArgs $rest) }
            'forget' { return (Invoke-MycoForget -ForgetArgs $rest) }
            'prune' { return (Invoke-MycoPrune) }
            'help' { Show-MycoHelp; return (New-MycoResult 0) }
            '-h' { Show-MycoHelp; return (New-MycoResult 0) }
            '--help' { Show-MycoHelp; return (New-MycoResult 0) }
            'version' { Write-MycoLine ('myco ' + (Get-MycoVersion)); return (New-MycoResult 0) }
            '-v' { Write-MycoLine ('myco ' + (Get-MycoVersion)); return (New-MycoResult 0) }
            '--version' { Write-MycoLine ('myco ' + (Get-MycoVersion)); return (New-MycoResult 0) }
            default {
                Write-MycoError ('unknown command "' + $command + '". Run "myco help" to see what is available.')
                return (New-MycoResult 2)
            }
        }
    } catch {
        Write-MycoError $_.Exception.Message
        return (New-MycoResult 1)
    }
}
