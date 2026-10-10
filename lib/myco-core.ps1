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

function Get-MycoVersion { '2.4.0' }
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

function Move-MycoFileAtomic {
    <#  Replaces Destination with Source as close to atomically as Windows
        allows. File::Replace needs a real backup path: passing $null throws
        "The path is empty" on PowerShell 7, which silently downgraded every
        registry write to a plain copy. #>
    param([string]$Source, [string]$Destination)
    if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) {
        [System.IO.File]::Move($Source, $Destination)
        return
    }
    $backup = $Destination + '.myco-bak'
    try {
        [System.IO.File]::Replace($Source, $Destination, $backup)
    } catch {
        Move-Item -LiteralPath $Source -Destination $Destination -Force
    } finally {
        Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
    }
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
        Move-MycoFileAtomic -Source $tmp -Destination $Path
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
    $harness = Get-MycoDefaultHarness
    if ($data -and $data -isnot [string]) {
        $names = @($data.PSObject.Properties.Name)
        if ($names -contains 'seed' -and $data.seed) { $seed = [string]$data.seed }
        if ($names -contains 'harness' -and $data.harness) { $harness = [string]$data.harness }
        if ($names -contains 'maxSessions' -and $data.maxSessions) {
            $parsed = 0
            if ([int]::TryParse([string]$data.maxSessions, [ref]$parsed) -and $parsed -gt 0) {
                $maxSessions = $parsed
            }
        }
    }
    if (@('none', 'config', 'full') -notcontains $seed) { $seed = Get-MycoDefaultSeed }
    if ((Get-MycoHarnessNames) -notcontains $harness) { $harness = Get-MycoDefaultHarness }
    return [pscustomobject]@{
        schemaVersion = Get-MycoSchemaVersion
        seed          = $seed
        maxSessions   = $maxSessions
        harness       = $harness
    }
}

function Write-MycoConfig {
    param($Config)
    Write-MycoJsonFile -Path (Get-MycoConfigPath) -Value ([pscustomobject]@{
            schemaVersion = Get-MycoSchemaVersion
            seed          = $Config.seed
            maxSessions   = $Config.maxSessions
            harness       = $Config.harness
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
            # The counter behind session ids. A registry written before named
            # sessions existed simply has no value yet, and starts at one.
            $nextSession = 1
            if ($wNames -contains 'nextSession') {
                $parsedNext = 0
                if ([int]::TryParse([string]$w.nextSession, [ref]$parsedNext) -and $parsedNext -gt 0) {
                    $nextSession = $parsedNext
                }
            }
            # Registries written before myco drove more than one tool have no
            # harness recorded, and those workspaces are copilot ones.
            $harness = Get-MycoDefaultHarness
            if (($wNames -contains 'harness') -and $w.harness) {
                if ((Get-MycoHarnessNames) -contains [string]$w.harness) { $harness = [string]$w.harness }
            }
            # Sessions myco minted an id for. Harnesses that keep a name of
            # their own need no such record; this is for the ones that do not,
            # where myco has to remember the mapping itself.
            $sessionMap = New-Object System.Collections.ArrayList
            if ($wNames -contains 'sessions') {
                foreach ($s in @($w.sessions)) {
                    if (-not $s) { continue }
                    $sNames = @($s.PSObject.Properties.Name)
                    if (($sNames -notcontains 'n') -or ($sNames -notcontains 'id')) { continue }
                    $number = 0
                    if (-not [int]::TryParse([string]$s.n, [ref]$number)) { continue }
                    $slug = ''
                    if (($sNames -contains 'slug') -and $s.slug) { $slug = [string]$s.slug }
                    [void]$sessionMap.Add([pscustomobject]@{ n = $number; id = [string]$s.id; slug = $slug })
                }
            }
            [void]$workspaces.Add([pscustomobject]@{
                    id          = [string]$w.id
                    path        = [string]$w.path
                    origin      = $origin
                    harness     = $harness
                    createdAt   = $createdAt
                    lastUsedAt  = $lastUsedAt
                    nextSession = $nextSession
                    sessions    = @($sessionMap.ToArray())
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

function Get-MycoDefaultHarness { 'copilot' }

function Get-MycoHarnessNames { return @('copilot', 'claude', 'opencode', 'pi') }

function Get-MycoHarness {
    <#  Everything that differs between the CLIs myco can drive, in one place,
        so adding a harness is a case here rather than a change everywhere.

        Isolation is deliberately uneven, because the tools are. copilot pools
        every session into one global directory, so it gets a per-folder
        COPILOT_HOME - that is myco's founding mechanism. claude and opencode
        already key their sessions on the working directory, so redirecting
        them would buy nothing and cost plenty: opencode keeps auth.json in the
        directory XDG_DATA_HOME moves, so isolating it means re-authenticating
        per project, or copying credentials into a folder inside the user's
        repository. pi is given an explicit session directory because that is
        the only handle it offers.

        Returns $null for a name myco does not support. #>
    param([string]$Name)

    switch ($Name) {
        'copilot' {
            return [pscustomobject]@{
                Name         = 'copilot'
                Command      = 'copilot'
                Folder       = '.copilot'
                HomeVar      = 'COPILOT_HOME'
                DirArg       = ''
                AutoArgs     = @('--yolo')
                NameArg      = '--name'
                ResumeArg    = '--resume'
                ResumeJoined = $true
                ContinueArgs = @('--continue')
                Seeds        = $true
                Trusts       = $true
                # The only client that is a terminal session a person opened.
                # Everything else in this store is a program driving Copilot.
                Client       = 'github/cli'
                ListsSessions = $true
                NewIdArg     = ''
                Reader       = 'copilot'
                Colour       = 'Blue'
            }
        }
        'claude' {
            return [pscustomobject]@{
                Name         = 'claude'
                Command      = 'claude'
                Folder       = ''
                HomeVar      = ''
                DirArg       = ''
                AutoArgs     = @('--dangerously-skip-permissions')
                # claude accepts --name but does not keep it: a session started
                # with one comes back titled cc-<hex>, and the name is nowhere
                # under ~/.claude. So myco mints the id instead and owns the
                # mapping itself.
                NameArg      = ''
                NewIdArg     = '--session-id'
                ResumeArg    = '--resume'
                ResumeJoined = $false
                ContinueArgs = @('--continue')
                Seeds        = $false
                Trusts       = $false
                Client       = ''
                ListsSessions = $true
                Reader       = 'claude'
                Colour       = 'DarkYellow'
            }
        }
        'opencode' {
            # The one harness with no way to name a session, so myco keeps the
            # id itself rather than inventing a flag opencode does not have.
            return [pscustomobject]@{
                Name         = 'opencode'
                Command      = 'opencode'
                Folder       = ''
                HomeVar      = ''
                DirArg       = ''
                AutoArgs     = @('--auto')
                NameArg      = ''
                ResumeArg    = '--session'
                ResumeJoined = $false
                ContinueArgs = @('--continue')
                Seeds        = $false
                Trusts       = $false
                Client       = ''
                ListsSessions = $false
                NewIdArg     = ''
                Reader       = ''
                Colour       = 'Magenta'
            }
        }
        'pi' {
            return [pscustomobject]@{
                Name         = 'pi'
                Command      = 'pi'
                Folder       = '.pi'
                HomeVar      = ''
                DirArg       = '--session-dir'
                AutoArgs     = @('--approve')
                NameArg      = '--name'
                ResumeArg    = '--session-id'
                ResumeJoined = $false
                ContinueArgs = @('--continue')
                Seeds        = $false
                Trusts       = $false
                Client       = ''
                ListsSessions = $false
                NewIdArg     = ''
                Reader       = ''
                Colour       = 'Cyan'
            }
        }
    }
    return $null
}

function Get-MycoSessionColour {
    <#  The colour a session row is drawn in: its harness's, so two harnesses
        in one listing are told apart at a glance, except while it is running.
        Liveness wins because it is rare and the one thing a reader must not
        miss; colouring it by harness as well would make the two signals
        compete. #>
    param($Session, $Harness)
    if ($Session.Active) { return 'Green' }
    if ($Harness -and $Harness.Colour) { return $Harness.Colour }
    return ''
}

function Get-MycoHarnessHome {
    <#  The folder this harness keeps its state in for a project, or '' when
        the harness manages that itself. #>
    param($Harness, [string]$Directory)
    if (-not $Harness.Folder) { return '' }
    return (Join-Path $Directory $Harness.Folder)
}

function New-MycoHarnessEnv {
    param($Harness, [string]$HomePath)
    $vars = @{}
    if ($Harness.HomeVar -and $HomePath) { $vars[$Harness.HomeVar] = $HomePath }
    return $vars
}

function Format-MycoHarnessList { return ((Get-MycoHarnessNames) -join ', ') }

function Get-MycoCommandNames {
    return @('start', 'continue', 'sessions', 'list', 'ls', 'resume', 'recover',
        'status', 'config', 'forget', 'prune', 'version', 'help')
}

function Resolve-MycoHarness {
    <#  Which tool to drive when the command line did not name one.

        `start` falls back to the configured default. `continue` and `resume`
        instead follow the folder, because work already lives in whichever tool
        it was begun in and sending them elsewhere would open the wrong thing. #>
    param($Harness, [string]$Directory = '')
    if ($Harness) { return $Harness }
    if ($Directory) {
        $workspace = Find-MycoWorkspaceByPath -Registry (Read-MycoRegistry) -Path $Directory
        if ($workspace -and $workspace.harness) {
            $known = Get-MycoHarness ([string]$workspace.harness)
            if ($known) { return $known }
        }
    }
    return (Get-MycoHarness (Read-MycoConfig).harness)
}

function Format-MycoWorkspaceId {
    param([int]$Number)
    if ($Number -lt 1000) { return ('{0:000}' -f $Number) }
    return ([string]$Number)
}

function Format-MycoSessionId {
    param([string]$WorkspaceId, [int]$Number)
    return ([string]$WorkspaceId + ('{0:000}' -f $Number))
}

function ConvertTo-MycoSlug {
    <#  Turns the name the user typed into the lowercase dashed form that goes
        into a session id. Returns an empty string when nothing usable is left,
        which the caller reports rather than inventing a name. #>
    param([string]$Name, [int]$MaxLength = 32)
    if (-not $Name) { return '' }
    $slug = $Name.ToLowerInvariant() -replace '[^a-z0-9]+', '-'
    $slug = $slug.Trim('-')
    if ($slug.Length -gt $MaxLength) { $slug = $slug.Substring(0, $MaxLength).Trim('-') }
    return $slug
}

<#  A session myco started carries its own id at the end of its name, which is
    the whole reason that id never shifts: it lives with the session rather
    than being recomputed from a list position every time. The match is
    case-sensitive on purpose, so only the slug form myco writes is recognised
    and a Copilot summary that happens to end in six digits is left alone. #>
$script:MycoNamedSessionPattern = '^(?<slug>[a-z0-9]+(?:-[a-z0-9]+)*)-(?<id>\d{6})$'

function Get-MycoNamedSessionId {
    param([string]$Name)
    if ($Name -cmatch $script:MycoNamedSessionPattern) { return $Matches['id'] }
    return ''
}

function Get-MycoNamedSessionLabel {
    <#  The name without the id myco appended, so the id is not printed twice. #>
    param([string]$Name)
    if ($Name -cmatch $script:MycoNamedSessionPattern) { return $Matches['slug'] }
    return $Name
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
        last-used stamp. The harness is recorded each time, because `continue`
        and `resume` have to reach the tool the work is actually in. #>
    param([string]$Path, [string]$Origin = 'created', [string]$Harness = '')
    $result = Invoke-MycoWithRegistryLock {
        $registry = Read-MycoRegistry
        $existing = Find-MycoWorkspaceByPath -Registry $registry -Path $Path
        if ($existing) {
            $existing.lastUsedAt = Get-MycoTimestamp
            if ($Harness) { $existing.harness = $Harness }
            Write-MycoRegistry $registry
            return $existing
        }
        $harnessName = $Harness
        if (-not $harnessName) { $harnessName = Get-MycoDefaultHarness }
        $workspace = [pscustomobject]@{
            id          = Format-MycoWorkspaceId $registry.nextId
            path        = $Path
            origin      = $Origin
            harness     = $harnessName
            createdAt   = Get-MycoTimestamp
            lastUsedAt  = Get-MycoTimestamp
            nextSession = 1
            sessions    = @()
        }
        $registry.nextId = [int]$registry.nextId + 1
        $registry.workspaces = @(@($registry.workspaces) + @($workspace))
        Write-MycoRegistry $registry
        return $workspace
    }
    return $result
}

function Get-MycoHighestSessionNumber {
    <#  The largest number any session in the folder already carries. It is the
        floor the counter can never drop below, so a registry that was reset or
        restored from a backup still cannot hand the same number out twice. #>
    param([string]$CopilotHome)
    if (-not $CopilotHome) { return 0 }
    $root = Join-Path $CopilotHome 'session-state'
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return 0 }
    $dirs = @()
    try { $dirs = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction Stop) } catch { return 0 }

    $highest = 0
    foreach ($dir in $dirs) {
        $metaPath = Join-Path $dir.FullName 'workspace.yaml'
        if (-not (Test-Path -LiteralPath $metaPath -PathType Leaf)) { continue }
        $meta = Read-MycoSessionMeta -Path $metaPath
        if (-not $meta.ContainsKey('name')) { continue }
        $id = Get-MycoNamedSessionId -Name ([string]$meta['name'])
        if (-not $id) { continue }
        $number = 0
        if (-not [int]::TryParse($id.Substring(3), [ref]$number)) { continue }
        if ($number -gt $highest) { $highest = $number }
    }
    return $highest
}

function Register-MycoMintedSession {
    <#  Records a session id myco generated, with the number and name it was
        given, before the harness has created anything. The harness cannot be
        asked for this later - claude discards the name it is handed - so the
        registry is the only place the mapping can live. #>
    param([string]$Path, [int]$Number, [string]$SessionId, [string]$Slug)
    [void](Invoke-MycoWithRegistryLock {
            $registry = Read-MycoRegistry
            $existing = Find-MycoWorkspaceByPath -Registry $registry -Path $Path
            if (-not $existing) { return $null }
            $existing.sessions = @(@($existing.sessions) +
                @([pscustomobject]@{ n = $Number; id = $SessionId; slug = $Slug }))
            Write-MycoRegistry $registry
            return $null
        })
}

function Reserve-MycoSessionNumber {
    <#  Hands out the next session number for a workspace and records it before
        the session exists, so deleting a session never frees its number for
        reuse. Ids a user has written down must keep meaning one session. #>
    param([string]$Path, [string]$CopilotHome)
    $floor = (Get-MycoHighestSessionNumber -CopilotHome $CopilotHome) + 1
    $result = Invoke-MycoWithRegistryLock {
        $registry = Read-MycoRegistry
        $existing = Find-MycoWorkspaceByPath -Registry $registry -Path $Path
        if (-not $existing) { return $floor }
        $next = [int]$existing.nextSession
        if ($next -lt $floor) { $next = $floor }
        $existing.nextSession = $next + 1
        Write-MycoRegistry $registry
        return $next
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
    <#  Parses the key: value metadata Copilot writes for each session.

        A value may be a block scalar - "|", ">", with an optional chomping or
        indentation indicator - in which case the text is the indented lines
        that follow. Those lines are consumed here rather than scanned, because
        a session name can quote a conversation, and a quoted line shaped like
        "id: ..." is text, not metadata. #>
    param([string]$Path)
    $meta = @{}
    $lines = $null
    try { $lines = [System.IO.File]::ReadAllLines($Path) } catch { return $meta }

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -notmatch '^(\s*)([A-Za-z0-9_]+)\s*:\s*(.*)$') { continue }
        $keyIndent = $Matches[1].Length
        $key = $Matches[2]
        $value = $Matches[3].Trim()

        if ($value -match '^([|>])([+-]?)([0-9]*)([+-]?)\s*$') {
            $folded = ($Matches[1] -eq '>')
            $chomp = $Matches[2] + $Matches[4]
            $block = New-Object System.Collections.ArrayList
            $blockIndent = -1
            $j = $i + 1
            while ($j -lt $lines.Count) {
                $next = $lines[$j]
                # A blank line belongs to the block; it does not end it.
                if ($next.Trim().Length -eq 0) { [void]$block.Add(''); $j++; continue }
                $indent = $next.Length - $next.TrimStart().Length
                if ($indent -le $keyIndent) { break }
                if ($blockIndent -lt 0) { $blockIndent = $indent }
                $take = $next
                if ($take.Length -ge $blockIndent) { $take = $take.Substring($blockIndent) }
                else { $take = $take.TrimStart() }
                [void]$block.Add($take)
                $j++
            }
            $i = $j - 1

            $text = @($block.ToArray())
            # "-" strips the trailing newline, nothing keeps one trailing blank
            # line, and "+" keeps them all. myco only ever shows one line, but
            # the distinction is cheap and keeps the value honest.
            if ($chomp -ne '+') {
                while ($text.Count -gt 0 -and $text[$text.Count - 1] -eq '') {
                    $text = @($text[0..($text.Count - 2)])
                }
            }
            $separator = if ($folded) { ' ' } else { "`n" }
            $meta[$key] = ($text -join $separator)
            continue
        }

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
    <#  Returns the workspace's sessions, most recently updated first. Only
        sessions from the given client are returned; '' returns them all. #>
    param([string]$CopilotHome, [int]$Max = 15, [string]$Client = '')
    $root = Join-Path $CopilotHome 'session-state'
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return @() }

    $found = New-Object System.Collections.ArrayList
    $dirs = @()
    try { $dirs = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction Stop) } catch { return @() }

    foreach ($dir in $dirs) {
        # The CLI keeps its own bookkeeping beside the sessions, currently
        # .session-operation-locks. A dot-prefixed folder is never a session.
        if ($dir.Name.StartsWith('.')) { continue }
        $sessionId = $dir.Name
        $name = ''
        # Not $client: PowerShell variable names are case-insensitive, so that
        # would be the $Client parameter and the filter would disable itself.
        $sessionClient = ''
        $updatedAt = $dir.LastWriteTimeUtc
        $metaPath = Join-Path $dir.FullName 'workspace.yaml'
        if (Test-Path -LiteralPath $metaPath -PathType Leaf) {
            $meta = Read-MycoSessionMeta -Path $metaPath
            if ($meta.ContainsKey('id') -and $meta['id']) { $sessionId = $meta['id'] }
            if ($meta.ContainsKey('name') -and $meta['name']) { $name = $meta['name'] }
            if ($meta.ContainsKey('client_name')) { $sessionClient = [string]$meta['client_name'] }
            if ($meta.ContainsKey('updated_at')) {
                $updatedAt = ConvertTo-MycoDate -Text $meta['updated_at'] -Fallback $dir.LastWriteTimeUtc
            }
        }
        # Programs drive Copilot through the same store - acp clients, agent
        # runners, the sdk. Those sessions were never a terminal tab, so they
        # are not myco's to list, number or reopen. An allowlist is used rather
        # than a denylist of the programs seen so far: a new one appearing and
        # being ignored is safe, whereas a new one appearing and being reopened
        # fills the screen with work nobody started.
        if ($Client -and $sessionClient -ne $Client) { continue }
        [void]$found.Add([pscustomobject]@{
                Id        = $sessionId
                Name      = $name
                UpdatedAt = $updatedAt
                Directory = $dir.FullName
                Active    = $false
                MycoId    = ''
                Label     = $name
                DisplayId = ''
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

function Get-MycoClaudeHome {
    if ($env:CLAUDE_CONFIG_DIR) { return $env:CLAUDE_CONFIG_DIR }
    $profileDir = $env:USERPROFILE
    if (-not $profileDir) { $profileDir = $HOME }
    return (Join-Path $profileDir '.claude')
}

function ConvertTo-MycoClaudeProjectName {
    <#  Claude Code names a project folder after the working directory, with
        every character that is not a letter, digit or dash replaced by a dash.
        Confirmed against the real CLI: C:\...\myco_probe.dot-bcdb09 became
        C--Users-User-AppData-Local-Temp-myco-probe-dot-bcdb09. #>
    param([string]$Path)
    return ($Path -replace '[^A-Za-z0-9-]', '-')
}

function Read-MycoClaudeLabel {
    <#  The best label a claude transcript offers.

        A session carries a "custom-title" record, but claude defaults that to
        cc-<8 hex> which tells the reader nothing, so in that case the first
        prompt is used instead. Only the head of the file is read: these
        transcripts reach tens of megabytes, and a listing must not pay for
        that. #>
    param([string]$Path, [int]$MaxLines = 400)
    $title = ''
    $prompt = ''
    $read = 0
    try {
        foreach ($line in [System.IO.File]::ReadLines($Path)) {
            if ($read -ge $MaxLines) { break }
            $read++
            # Cheap string tests first; parsing every line would be far slower.
            if ($line.Length -lt 2000 -and $line.Contains('"custom-title"')) {
                try { $title = [string]((ConvertFrom-Json $line).customTitle) } catch { }
            } elseif (-not $prompt -and $line.Length -lt 4000 -and $line.Contains('"last-prompt"')) {
                try { $prompt = [string]((ConvertFrom-Json $line).lastPrompt) } catch { }
            }
        }
    } catch { }
    if ($title -and $title -notmatch '^cc-[0-9a-f]{6,}$') { return $title }
    if ($prompt) { return $prompt }
    return ''
}

function Get-MycoClaudeSessions {
    <#  Claude keys its sessions on the working directory, one .jsonl per
        session named after the session id, so a project's sessions are simply
        the files in its project folder. #>
    param([string]$Directory, [int]$Max = 15)
    $root = Join-Path (Get-MycoClaudeHome) ('projects\' + (ConvertTo-MycoClaudeProjectName $Directory))
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return @() }

    $files = @()
    try { $files = @(Get-ChildItem -LiteralPath $root -Filter '*.jsonl' -File -ErrorAction Stop) } catch { return @() }

    $found = New-Object System.Collections.ArrayList
    foreach ($file in $files) {
        [void]$found.Add([pscustomobject]@{
                Id        = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
                Name      = ''
                UpdatedAt = $file.LastWriteTimeUtc
                Directory = $file.FullName
                Active    = $false
                MycoId    = ''
                Label     = ''
                DisplayId = ''
            })
    }

    $ordered = @($found.ToArray() | Sort-Object -Property UpdatedAt -Descending)
    if ($Max -gt 0 -and $ordered.Count -gt $Max) { $ordered = @($ordered[0..($Max - 1)]) }
    # Labels are resolved only for the sessions actually being shown, because
    # each one costs a read.
    foreach ($session in $ordered) {
        $session.Name = Read-MycoClaudeLabel -Path $session.Directory
        $session.Label = $session.Name
    }
    return $ordered
}

function Get-MycoHarnessSessions {
    <#  The raw sessions of a workspace, from whichever store its harness uses. #>
    param($Harness, [string]$Directory, [int]$Max = 15)
    switch ($Harness.Reader) {
        'copilot' {
            $store = Get-MycoHarnessHome -Harness $Harness -Directory $Directory
            return @(Get-MycoSessions -CopilotHome $store -Max $Max -Client $Harness.Client)
        }
        'claude' { return @(Get-MycoClaudeSessions -Directory $Directory -Max $Max) }
    }
    return @()
}

function Add-MycoSessionIds {
    <#  Gives every listed session the id it is shown and resumed by.

        A session myco started carries its id in its own name and keeps it for
        life, however the list is later reordered. Everything else - sessions
        from a plain copilot run, or from before myco named them - still falls
        back to its position in the list, skipping any number a named session
        already holds so no two rows can ever claim the same id. #>
    param($Sessions, [string]$WorkspaceId, $Minted = @())
    $list = @($Sessions)

    # A session myco minted an id for is matched by that id, not by its name:
    # the harness may have renamed it, or never kept the name at all.
    $byId = @{}
    foreach ($entry in @($Minted)) {
        if ($entry -and $entry.id) { $byId[[string]$entry.id] = $entry }
    }

    $taken = @{}
    foreach ($session in $list) {
        $named = Get-MycoNamedSessionId -Name $session.Name
        if ($named) { $taken[$named] = $true }
        if ($byId.ContainsKey([string]$session.Id)) {
            $taken[(Format-MycoSessionId -WorkspaceId $WorkspaceId -Number ([int]$byId[[string]$session.Id].n))] = $true
        }
    }

    $next = 1
    foreach ($session in $list) {
        $minted = $null
        if ($byId.ContainsKey([string]$session.Id)) { $minted = $byId[[string]$session.Id] }
        if ($minted) {
            $session.MycoId = Format-MycoSessionId -WorkspaceId $WorkspaceId -Number ([int]$minted.n)
            if ($minted.slug) {
                $session.Label = $minted.slug
                $session.DisplayId = $minted.slug + '-' + $session.MycoId
            }
            continue
        }
        $named = Get-MycoNamedSessionId -Name $session.Name
        if ($named) {
            $session.MycoId = $named
            $session.Label = Get-MycoNamedSessionLabel -Name $session.Name
            $session.DisplayId = $session.Name
            continue
        }
        $id = Format-MycoSessionId -WorkspaceId $WorkspaceId -Number $next
        while ($taken.ContainsKey($id)) {
            $next++
            $id = Format-MycoSessionId -WorkspaceId $WorkspaceId -Number $next
        }
        $taken[$id] = $true
        $next++
        $session.MycoId = $id
        $session.Label = $session.Name
        $session.DisplayId = $id
    }
    return $list
}

function Get-MycoWorkspaceSessions {
    <#  The sessions of one workspace, already carrying their ids. Listing and
        resuming must agree on the numbering, so both come through here.

        A harness myco cannot yet read returns nothing, and the caller is
        expected to say so rather than report an empty folder. #>
    param($Workspace, [int]$Max = 15)
    $harness = Get-MycoHarness ([string]$Workspace.harness)
    if (-not $harness) { $harness = Get-MycoHarness (Get-MycoDefaultHarness) }
    if (-not $harness.ListsSessions) { return @() }
    $sessions = @(Get-MycoHarnessSessions -Harness $harness -Directory $Workspace.path -Max $Max)
    return @(Add-MycoSessionIds -Sessions $sessions -WorkspaceId $Workspace.id -Minted $Workspace.sessions)
}

function Format-MycoSessionDisplayId {
    <#  What the ID column shows: the full name-and-id when myco named or
        minted the session, and the bare number for anything else. #>
    param($Session)
    if ($Session.DisplayId) { return $Session.DisplayId }
    return $Session.MycoId
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

function Get-MycoJsonArraySpan {
    <#  Locates the bounds of the array that follows a key, respecting string
        literals so a bracket inside a path cannot end it early. Returns the
        index of '[' and of its matching ']', or $null. #>
    param([string]$Text, [string]$Key)
    $match = [regex]::Match($Text, '"' + [regex]::Escape($Key) + '"\s*:\s*\[')
    if (-not $match.Success) { return $null }

    $open = $match.Index + $match.Length - 1
    $depth = 0
    $inString = $false
    $escaped = $false
    for ($i = $open; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        if ($inString) {
            if ($escaped) { $escaped = $false }
            elseif ($ch -eq '\') { $escaped = $true }
            elseif ($ch -eq '"') { $inString = $false }
            continue
        }
        if ($ch -eq '"') { $inString = $true; continue }
        if ($ch -eq '[') { $depth++; continue }
        if ($ch -eq ']') {
            $depth--
            if ($depth -eq 0) { return [pscustomobject]@{ Open = $open; Close = $i } }
        }
    }
    return $null
}

function ConvertTo-MycoJsonString {
    param([string]$Value)
    return ($Value -replace '\\', '\\' -replace '"', '\"')
}

function Add-MycoTrustedFolder {
    <#  Records the workspace in its own COPILOT_HOME as a trusted folder, so
        Copilot does not greet every recovered tab with a trust prompt. Running
        myco in a folder is the deliberate act of choosing it, and sessions are
        launched with --yolo already.

        The file belongs to Copilot, so it is edited surgically rather than
        reparsed and rewritten: PowerShell 7 turns ISO date strings into
        DateTime objects, and round-tripping would silently rewrite values such
        as firstLaunchAt. Only the trustedFolders array is touched.

        Failure is never fatal; the only cost is the prompt coming back. #>
    param([string]$CopilotHome, [string]$Directory)
    if (-not $CopilotHome -or -not $Directory) { return }
    if (-not (Test-Path -LiteralPath $CopilotHome -PathType Container)) { return }

    $path = Join-Path $CopilotHome 'config.json'
    try {
        $text = ''
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $text = [System.IO.File]::ReadAllText($path)
        }

        $entry = '"' + (ConvertTo-MycoJsonString $Directory) + '"'
        $wanted = ConvertTo-MycoComparablePath $Directory
        $updated = ''

        $span = $null
        if ($text.Trim()) { $span = Get-MycoJsonArraySpan -Text $text -Key 'trustedFolders' }

        if ($span) {
            $inner = $text.Substring($span.Open + 1, $span.Close - $span.Open - 1)
            foreach ($m in [regex]::Matches($inner, '"((?:[^"\\]|\\.)*)"')) {
                $existing = $m.Groups[1].Value -replace '\\\\', '\' -replace '\\"', '"'
                if ((ConvertTo-MycoComparablePath $existing) -eq $wanted) { return }
            }
            $separator = ''
            if ($inner.Trim()) { $separator = ',' }
            # Insert after the last entry rather than before the bracket, so the
            # comma does not end up alone on its own line.
            $insertAt = $span.Close
            while ($insertAt -gt ($span.Open + 1) -and [char]::IsWhiteSpace($text[$insertAt - 1])) { $insertAt-- }
            $updated = $text.Substring(0, $insertAt) +
            $separator + "`r`n    " + $entry + "`r`n  " +
            $text.Substring($span.Close)
        } elseif ($text.Trim() -and $text.Contains('{')) {
            $brace = $text.IndexOf('{')
            $updated = $text.Substring(0, $brace + 1) +
            "`r`n  `"trustedFolders`": [`r`n    " + $entry + "`r`n  ]," +
            $text.Substring($brace + 1)
        } else {
            $updated = '// User settings belong in settings.json.' + "`r`n" +
            '// This file is managed automatically.' + "`r`n" +
            '{' + "`r`n  `"trustedFolders`": [`r`n    " + $entry + "`r`n  ]`r`n}`r`n"
        }

        $tmp = $path + '.myco-tmp'
        $encoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($tmp, $updated, $encoding)
        Move-MycoFileAtomic -Source $tmp -Destination $path
    } catch {
        Write-MycoWarning ('could not record the folder as trusted: ' + $_.Exception.Message)
    }
}

function New-MycoPlan {
    param([string]$WorkDir, [string]$Command, [string[]]$CommandArgs, $EnvVars = @{})
    return [pscustomobject]@{
        WorkDir     = $WorkDir
        Command     = $Command
        CommandArgs = @($CommandArgs)
        EnvVars     = $EnvVars
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
        the directory change outlives myco. Every variable the harness needs is
        set before the call and put back afterwards, whatever the harness exits
        with - leaking one would silently redirect the user's next plain run. #>
    param([string]$PlanFile, $Plan)

    $sets = @()
    $restores = @()
    foreach ($name in @($Plan.EnvVars.Keys)) {
        $sets += ('set "' + $name + '=' + $Plan.EnvVars[$name] + '"')
        $previous = [Environment]::GetEnvironmentVariable($name)
        if ([string]::IsNullOrEmpty($previous)) {
            $restores += ('set "' + $name + '="')
        } else {
            $restores += ('set "' + $name + '=' + $previous + '"')
        }
    }

    $argLine = (@($Plan.CommandArgs) | ForEach-Object { ConvertTo-MycoCmdArg $_ }) -join ' '
    # Every element is parenthesised: inside an array literal the comma binds
    # tighter than +, which would otherwise split each line into fragments.
    $lines = @('@echo off', ('cd /d "' + $Plan.WorkDir + '"')) +
    $sets +
    @(('call ' + $Plan.Command + ' ' + $argLine),
        'set "MYCO_COPILOT_RC=%ERRORLEVEL%"') +
    $restores +
    @('set "MYCO_COPILOT_RC=" & exit /b %MYCO_COPILOT_RC%')
    [System.IO.File]::WriteAllLines($PlanFile, $lines, (Get-MycoOemEncoding))
}

# ----------------------------------------------------------------- commands

function Show-MycoHelp {
    Write-MycoLine ''
    Write-MycoLine ('myco ' + (Get-MycoVersion) + ' - per-project Copilot CLI workspaces') 'Cyan'
    Write-MycoLine ''
    Write-MycoLine 'Usage:'
    Write-MycoLine '  myco [harness] <command> [args]'
    Write-MycoLine ''
    Write-MycoLine ('  Harnesses: ' + (Format-MycoHarnessList) + '. Naming one picks the tool for that')
    Write-MycoLine '  run, as in "myco claude start fix-login". Without one, myco uses the'
    Write-MycoLine '  harness in config for start, and for continue and resume the harness the'
    Write-MycoLine '  folder was last started with.'
    Write-MycoLine ''
    Write-MycoLine '  myco start <name> [args]       Start a named session for this folder. The'
    Write-MycoLine '                                 name becomes the session id, e.g. fix-login'
    Write-MycoLine '                                 -> fix-login-001004.'
    Write-MycoLine '  myco continue [args]           Resume this folder''s most recent session.'
    Write-MycoLine '  myco sessions                  List every folder myco knows about, with'
    Write-MycoLine '                                 its id and its last 15 sessions.'
    Write-MycoLine '  myco resume <id>               Move into the folder and resume.'
    Write-MycoLine '                                 <id> is fix-login-001004, or just 001004,'
    Write-MycoLine '                                 or 001 for the latest session of folder 001.'
    Write-MycoLine '  myco recover [options]         Reopen every session touched in the last'
    Write-MycoLine '                                 2 hours, one Windows Terminal tab each.'
    Write-MycoLine '                                 --hours=<n>  widen or narrow the window'
    Write-MycoLine '                                 --dry-run    list them without opening'
    Write-MycoLine '                                 --here       add tabs to this window'
    Write-MycoLine '                                 --max=<n>    raise the tab cap'
    Write-MycoLine '                                 Sessions already running are left alone.'
    Write-MycoLine '  myco status                    Describe the current folder.'
    Write-MycoLine '  myco config [key] [value]      Show or change settings (harness, seed,'
    Write-MycoLine '                                 maxSessions).'
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
    param([string]$Directory, [string[]]$ExtraArgs, [switch]$Continue, [switch]$Named, $Harness = $null)

    if (-not $Harness) { $Harness = Get-MycoHarness (Get-MycoDefaultHarness) }

    $rest = @($ExtraArgs)
    $slug = ''
    if ($Named) {
        # Checked before anything is created, so a mistyped command leaves no
        # folder and burns no session number.
        $first = ''
        if ($rest.Count -gt 0) { $first = [string]$rest[0] }
        if (-not $first -or $first.StartsWith('-')) {
            Write-MycoError 'a name is required: myco start <name> [harness args]'
            Write-MycoLine '  the name becomes the session id, so you can come back to it:' 'DarkGray'
            Write-MycoLine '  myco start fix-login   ->   myco resume fix-login-001004' 'DarkGray'
            return (New-MycoResult 2)
        }
        $slug = ConvertTo-MycoSlug $first
        if (-not $slug) {
            Write-MycoError ('"' + $first + '" leaves nothing usable as a name. Use letters or digits, e.g. myco start fix-login')
            return (New-MycoResult 2)
        }
        if ($rest.Count -gt 1) { $rest = @($rest[1..($rest.Count - 1)]) } else { $rest = @() }
    }

    $problem = Assert-MycoManageableFolder -Directory $Directory
    if ($problem) {
        Write-MycoError $problem
        return (New-MycoResult 2)
    }

    # Only harnesses that keep project state in a folder of their own have one
    # to create; the rest key their sessions on the working directory.
    $harnessHome = Get-MycoHarnessHome -Harness $Harness -Directory $Directory
    $existed = $false
    if ($harnessHome) {
        $existed = Test-Path -LiteralPath $harnessHome -PathType Container
        if (-not $existed) {
            try {
                New-Item -ItemType Directory -Force -Path $harnessHome -ErrorAction Stop | Out-Null
            } catch {
                Write-MycoError ('could not create ' + $Harness.Folder + ' here: ' + $_.Exception.Message)
                return (New-MycoResult 1)
            }
            if ($Harness.Seeds) {
                Initialize-MycoWorkspaceSeed -CopilotHome $harnessHome -Mode (Read-MycoConfig).seed
            }
        }
    }

    $origin = if ($existed) { 'adopted' } else { 'created' }
    $workspace = Register-MycoWorkspace -Path $Directory -Origin $origin -Harness $Harness.Name
    if ($Harness.Trusts) {
        Add-MycoTrustedFolder -CopilotHome $harnessHome -Directory $Directory
    }

    $commandArgs = @($Harness.AutoArgs)
    if ($Harness.DirArg -and $harnessHome) { $commandArgs += @($Harness.DirArg, $harnessHome) }

    $sessionName = ''
    if ($slug) {
        $number = Reserve-MycoSessionNumber -Path $Directory -CopilotHome $harnessHome
        $sessionName = $slug + '-' + (Format-MycoSessionId -WorkspaceId $workspace.id -Number $number)
        if ($Harness.NameArg) {
            # The harness keeps the name, so the id travels inside it.
            $commandArgs += @($Harness.NameArg, $sessionName)
        } elseif ($Harness.NewIdArg) {
            # The harness discards names, so myco mints the session id and
            # remembers the mapping. Recorded before launching, so a session
            # that starts and crashes still holds its number.
            $sessionId = [guid]::NewGuid().ToString()
            Register-MycoMintedSession -Path $Directory -Number $number -SessionId $sessionId -Slug $slug
            $commandArgs += @($Harness.NewIdArg, $sessionId)
        }
    }
    if ($Continue) { $commandArgs += @($Harness.ContinueArgs) }
    if ($rest) { $commandArgs += @($rest) }

    $verb = if ($existed) { $workspace.origin } else { 'created' }
    $line = 'myco [' + $workspace.id + '] ' + (Split-Path -Leaf $Directory)
    if ($sessionName) { $line += '  ' + $sessionName }
    $line += '  (' + $Harness.Name
    if ($harnessHome) { $line += ', ' + $verb }
    $line += ')'
    Write-MycoLine $line 'DarkCyan'

    return (New-MycoResult 0 (New-MycoPlan -WorkDir $Directory -Command $Harness.Command `
                -CommandArgs $commandArgs -EnvVars (New-MycoHarnessEnv -Harness $Harness -HomePath $harnessHome)))
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
    foreach ($session in @($Sessions)) {
        $shown = Format-MycoSessionDisplayId -Session $session
        if ($shown.Length -gt $idWidth) { $idWidth = $shown.Length }
    }
    if ($idWidth -gt 32) { $idWidth = 32 }
    $harnessName = [string]$Workspace.harness
    if (-not $harnessName) { $harnessName = Get-MycoDefaultHarness }
    $harness = Get-MycoHarness $harnessName
    $harnessColour = 'Cyan'
    if ($harness -and $harness.Colour) { $harnessColour = $harness.Colour }
    $harnessWidth = 7
    if ($harnessName.Length -gt $harnessWidth) { $harnessWidth = $harnessName.Length }
    $statusWidth = 8
    $whenWidth = 12
    # Five columns plus their padding and six vertical rules.
    $overhead = ($idWidth + $harnessWidth + $statusWidth + $whenWidth) + (5 * 2) + 6
    $nameWidth = $Width - $overhead
    if ($nameWidth -lt 12) { $nameWidth = 12 }
    $widths = @($idWidth, $harnessWidth, $statusWidth, $whenWidth, $nameWidth)
    $innerWidth = $overhead + $nameWidth - 2

    $title = '[' + $Workspace.id + '] ' + (Split-Path -Leaf $Workspace.path) +
    ' (' + $harnessName + ', ' + $Workspace.origin + ')'
    $titleText = ([string]$Glyphs.Horizontal) + ' ' + $title + ' '
    if ($titleText.Length -gt $innerWidth) {
        $titleText = $titleText.Substring(0, $innerWidth)
    }
    $fill = [string]$Glyphs.Horizontal * ($innerWidth - $titleText.Length)
    Write-MycoLine ([string]$Glyphs.TopLeft + $titleText + $fill + [string]$Glyphs.TopRight) $harnessColour

    Write-MycoLine ([string]$Glyphs.Vertical + ' ' + (Format-MycoCell $Workspace.path ($innerWidth - 2) $Glyphs.Ellipsis) +
        ' ' + [string]$Glyphs.Vertical) 'DarkGray'

    Write-MycoTableRule -Glyphs $Glyphs -Widths $widths `
        -Left ([string]$Glyphs.TeeLeft) -Middle ([string]$Glyphs.TeeDown) -Right ([string]$Glyphs.TeeRight)

    $heading = [string]$Glyphs.Vertical + ' ' + (Format-MycoCell 'ID' $idWidth) +
    ' ' + [string]$Glyphs.Vertical + ' ' + (Format-MycoCell 'HARNESS' $harnessWidth) +
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
        $sessionId = Format-MycoSessionDisplayId -Session $session
        $status = ''
        if ($session.Active) { $status = [string]$Glyphs.Dot + ' active' }
        $name = $session.Label
        if (-not $name) { $name = '(unnamed)' }

        $row = [string]$Glyphs.Vertical + ' ' + (Format-MycoCell $sessionId $idWidth $Glyphs.Ellipsis) +
        ' ' + [string]$Glyphs.Vertical + ' ' + (Format-MycoCell $harnessName $harnessWidth $Glyphs.Ellipsis) +
        ' ' + [string]$Glyphs.Vertical + ' ' + (Format-MycoCell $status $statusWidth) +
        ' ' + [string]$Glyphs.Vertical + ' ' + (Format-MycoCell (Format-MycoRelativeTime $session.UpdatedAt) $whenWidth) +
        ' ' + [string]$Glyphs.Vertical + ' ' + (Format-MycoCell $name $nameWidth $Glyphs.Ellipsis) +
        ' ' + [string]$Glyphs.Vertical

        Write-MycoLine $row (Get-MycoSessionColour -Session $session -Harness $harness)
    }

    Write-MycoTableRule -Glyphs $Glyphs -Widths $widths `
        -Left ([string]$Glyphs.BottomLeft) -Middle ([string]$Glyphs.TeeUp) -Right ([string]$Glyphs.BottomRight)
}

function Show-MycoWorkspaceNote {
    <#  A framed one-line message for a workspace with nothing to tabulate. #>
    param($Workspace, [string]$Note, $Glyphs, [int]$Width, [string]$Colour)
    $innerWidth = $Width - 2
    $harnessName = [string]$Workspace.harness
    if (-not $harnessName) { $harnessName = Get-MycoDefaultHarness }
    $harness = Get-MycoHarness $harnessName
    $frameColour = 'Cyan'
    if ($harness -and $harness.Colour) { $frameColour = $harness.Colour }
    $title = '[' + $Workspace.id + '] ' + (Split-Path -Leaf $Workspace.path) +
    ' (' + $harnessName + ', ' + $Workspace.origin + ')'
    $titleText = ([string]$Glyphs.Horizontal) + ' ' + $title + ' '
    if ($titleText.Length -gt $innerWidth) { $titleText = $titleText.Substring(0, $innerWidth) }
    $fill = [string]$Glyphs.Horizontal * ($innerWidth - $titleText.Length)
    Write-MycoLine ([string]$Glyphs.TopLeft + $titleText + $fill + [string]$Glyphs.TopRight) $frameColour
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
        Write-MycoLine 'No workspaces yet. Run "myco start <name>" inside a project folder.'
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
            $harness = Get-MycoHarness ([string]$workspace.harness)
            if ($harness -and -not $harness.ListsSessions) {
                # Saying "no sessions yet" here would be untrue: the work is
                # there, myco just cannot read that harness's store yet.
                $note = $harness.Name + ' sessions are not listed yet - run "myco ' +
                $harness.Name + ' continue" in the folder'
            } else {
                $sessions = @(Get-MycoWorkspaceSessions -Workspace $workspace -Max $config.maxSessions)
                if ($sessions.Count -eq 0) { $note = 'no sessions yet' }
                $activeTotal += @($sessions | Where-Object { $_.Active }).Count
            }
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

    $workspaceId = ''
    $sessionIndex = ''
    if ($token -cmatch $script:MycoNamedSessionPattern) {
        # The full name-and-id form. Only the digits address the session; the
        # slug is there for the reader.
        $digits = $Matches['id']
        $workspaceId = $digits.Substring(0, 3)
        $sessionIndex = $digits.Substring(3, 3)
    } else {
        $normalised = $token -replace '[.\-_/]', ''
        if ($normalised -notmatch '^(\d{3})(\d{3})?$') {
            return (Invoke-MycoResumeRaw -Directory $Directory -Token $token -ExtraArgs $extra)
        }
        $workspaceId = $Matches[1]
        $sessionIndex = $Matches[2]
    }

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

    $harness = Get-MycoHarness ([string]$workspace.harness)
    if (-not $harness) { $harness = Get-MycoHarness (Get-MycoDefaultHarness) }
    $harnessHome = Get-MycoHarnessHome -Harness $harness -Directory $workspace.path
    $commandArgs = @($harness.AutoArgs)
    if ($harness.DirArg -and $harnessHome) { $commandArgs += @($harness.DirArg, $harnessHome) }

    if ($sessionIndex) {
        $config = Read-MycoConfig
        $sessions = @(Get-MycoWorkspaceSessions -Workspace $workspace -Max $config.maxSessions)
        $wanted = Format-MycoSessionId -WorkspaceId $workspace.id -Number ([int]$sessionIndex)
        $match = $null
        foreach ($session in $sessions) {
            if ($session.MycoId -eq $wanted) { $match = $session; break }
        }
        if (-not $match) {
            Write-MycoError ('workspace ' + $workspace.id + ' has no session ' + $wanted +
                ' among its ' + $sessions.Count + ' listed session(s). Run "myco sessions" to see the ids.')
            return (New-MycoResult 2)
        }
        $commandArgs += @(Format-MycoResumeArgs -Harness $harness -SessionId $match.Id)
    } else {
        $commandArgs += @($harness.ContinueArgs)
    }
    $commandArgs += $extra

    Update-MycoWorkspaceUsage -Path $workspace.path
    if ($harness.Trusts) {
        Add-MycoTrustedFolder -CopilotHome $harnessHome -Directory $workspace.path
    }
    Write-MycoLine ('myco [' + $workspace.id + '] ' + (Split-Path -Leaf $workspace.path) +
        '  (' + $harness.Name + ')') 'DarkCyan'

    return (New-MycoResult 0 (New-MycoPlan -WorkDir $workspace.path -Command $harness.Command `
                -CommandArgs $commandArgs -EnvVars (New-MycoHarnessEnv -Harness $harness -HomePath $harnessHome)))
}

function Format-MycoResumeArgs {
    <#  Each harness spells "resume this session" differently, and copilot is
        the only one that joins the id to the flag with an equals sign. #>
    param($Harness, [string]$SessionId)
    if ($Harness.ResumeJoined) { return @($Harness.ResumeArg + '=' + $SessionId) }
    return @($Harness.ResumeArg, $SessionId)
}

function Invoke-MycoResumeRaw {
    <#  Anything that is not a myco id is handed to the harness as-is, so
        session uuids, id prefixes and session names keep working. #>
    param([string]$Directory, [string]$Token, [string[]]$ExtraArgs)
    $harness = Resolve-MycoHarness $null -Directory $Directory
    $harnessHome = Get-MycoHarnessHome -Harness $harness -Directory $Directory
    if ($harnessHome -and -not (Test-Path -LiteralPath $harnessHome -PathType Container)) {
        Write-MycoError ('"' + $Token + '" is not a myco id, and this folder has no ' + $harness.Folder +
            ' to search. Run "myco sessions" for ids.')
        return (New-MycoResult 2)
    }
    $commandArgs = @($harness.AutoArgs)
    if ($harness.DirArg -and $harnessHome) { $commandArgs += @($harness.DirArg, $harnessHome) }
    $commandArgs += @(Format-MycoResumeArgs -Harness $harness -SessionId $Token)
    $commandArgs += @($ExtraArgs)
    Update-MycoWorkspaceUsage -Path $Directory
    if ($harness.Trusts) {
        Add-MycoTrustedFolder -CopilotHome $harnessHome -Directory $Directory
    }
    return (New-MycoResult 0 (New-MycoPlan -WorkDir $Directory -Command $harness.Command `
                -CommandArgs $commandArgs -EnvVars (New-MycoHarnessEnv -Harness $harness -HomePath $harnessHome)))
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
    $unreadable = New-Object System.Collections.ArrayList

    foreach ($workspace in @($Registry.workspaces)) {
        if (-not (Test-Path -LiteralPath $workspace.path -PathType Container)) { continue }
        # A folder whose harness myco cannot read yet is skipped outright. It
        # may still hold copilot state from before it moved, and reopening that
        # would restore work from the wrong tool.
        $harness = Get-MycoHarness ([string]$workspace.harness)
        if ($harness -and -not $harness.ListsSessions) {
            if (-not $unreadable.Contains($harness.Name)) { [void]$unreadable.Add($harness.Name) }
            continue
        }
        $sessions = @(Get-MycoWorkspaceSessions -Workspace $workspace -Max $PerWorkspace)
        foreach ($session in $sessions) {
            if ($session.UpdatedAt.ToUniversalTime() -lt $cutoff) { continue }
            if ($session.Active) { $running++; continue }
            [void]$found.Add([pscustomobject]@{
                    WorkspaceId = $workspace.id
                    Path        = $workspace.path
                    ShortId     = Format-MycoSessionDisplayId -Session $session
                    SessionId   = $session.Id
                    Name        = $session.Label
                    UpdatedAt   = $session.UpdatedAt
                })
        }
    }

    return [pscustomobject]@{
        Sessions   = @($found.ToArray() | Sort-Object -Property UpdatedAt -Descending)
        Running    = $running
        Unreadable = @($unreadable.ToArray())
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
    $unreadable = @($scan.Unreadable)

    $glyphs = Get-MycoGlyphSet
    $window = Format-MycoHours $options.Hours
    $runningNote = ''
    if ($running -gt 0) {
        $word = 'sessions are'
        if ($running -eq 1) { $word = 'session is' }
        $runningNote = '  ' + $running + ' ' + $word + ' still running and already open, so left alone.'
    }
    $skippedNote = ''
    if ($unreadable.Count -gt 0) {
        $skippedNote = '  ' + ($unreadable -join ' and ') +
        ' folders were skipped: myco cannot list those sessions yet.'
    }

    if ($candidates.Count -eq 0) {
        Write-MycoLine ''
        Write-MycoLine ('  Nothing to recover from the last ' + $window + '.') 'Cyan'
        if ($runningNote) { Write-MycoLine $runningNote 'DarkGray' }
        if ($skippedNote) { Write-MycoLine $skippedNote 'DarkGray' }
        Write-MycoLine ''
        return (New-MycoResult 0)
    }

    Write-MycoLine ''
    $verb = 'Recovering'
    if ($options.DryRun) { $verb = 'Would recover' }
    Write-MycoLine ('  ' + $verb + ' ' + $candidates.Count + ' session(s) from the last ' + $window) 'Cyan'
    if ($runningNote) { Write-MycoLine $runningNote 'DarkGray' }
    if ($skippedNote) { Write-MycoLine $skippedNote 'DarkGray' }
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
        Write-MycoLine '  workspace    not registered yet - run "myco start <name>" here to adopt it'
    } else {
        Write-MycoLine '  workspace    none - run "myco start <name>" here to create one'
    }

    if (Test-MycoGlobalCopilotFolder -Directory $Directory) {
        Write-MycoLine '  note         this folder holds your global Copilot home' 'DarkYellow'
    }

    if (Test-Path -LiteralPath $copilotHome -PathType Container) {
        $harness = Resolve-MycoHarness $null -Directory $Directory
        $sessions = @(Get-MycoSessions -CopilotHome $copilotHome -Max $config.maxSessions -Client $harness.Client)
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
        Write-MycoLine ('  harness      ' + $config.harness + '    (' + (Format-MycoHarnessList) + ')')
        Write-MycoLine ('  seed         ' + $config.seed + '    (none | config | full)')
        Write-MycoLine ('  maxSessions  ' + $config.maxSessions)
        Write-MycoLine ''
        Write-MycoLine '  harness is the tool a bare "myco start" uses; name one to override it,'
        Write-MycoLine '  as in "myco claude start fix-login".'
        Write-MycoLine ''
        Write-MycoLine '  none   a new .copilot starts empty'
        Write-MycoLine '  config copies settings.json and mcp-config.json from your global Copilot home'
        Write-MycoLine '  full   also copies skills, instructions and installed plugins'
        Write-MycoLine ''
        return (New-MycoResult 0)
    }

    $key = ([string]$ConfigArgs[0]).ToLowerInvariant()
    if ($count -lt 2) {
        Write-MycoError 'usage: myco config <harness|seed|maxSessions> <value>'
        return (New-MycoResult 2)
    }
    $value = [string]$ConfigArgs[1]

    switch ($key) {
        'harness' {
            $normalised = $value.ToLowerInvariant()
            if ((Get-MycoHarnessNames) -notcontains $normalised) {
                Write-MycoError ('harness must be one of: ' + (Format-MycoHarnessList))
                return (New-MycoResult 2)
            }
            $config.harness = $normalised
            Write-MycoConfig $config
            Write-MycoLine ('myco config: harness = ' + $normalised)
            return (New-MycoResult 0)
        }
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

    # A leading harness name selects the tool and is then out of the way, so
    # every command below sees the same argument shape it always has.
    $harness = $null
    if ((Get-MycoHarnessNames) -contains $command.ToLowerInvariant()) {
        $harness = Get-MycoHarness $command.ToLowerInvariant()
        if ($rest.Count -eq 0) {
            Write-MycoError ('usage: myco ' + $harness.Name + ' <command> [args]   (try "myco help")')
            return (New-MycoResult 2)
        }
        $command = $rest[0]
        if ($rest.Count -gt 1) { $rest = @($rest[1..($rest.Count - 1)]) } else { $rest = @() }
    }

    try {
        switch ($command.ToLowerInvariant()) {
            'start' { return (Invoke-MycoLaunch -Directory $directory -ExtraArgs $rest -Named -Harness (Resolve-MycoHarness $harness)) }
            'continue' { return (Invoke-MycoLaunch -Directory $directory -ExtraArgs $rest -Continue -Harness (Resolve-MycoHarness $harness -Directory $directory)) }
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
                # "myco gemini start x" is a harness attempt, not a typo'd
                # command, so it is worth naming what myco can actually drive.
                $looksLikeHarness = ($rest.Count -gt 0) -and
                    ((Get-MycoCommandNames) -contains ([string]$rest[0]).ToLowerInvariant())
                if ($looksLikeHarness) {
                    Write-MycoError ('"' + $command + '" is not a harness myco can drive. Supported: ' +
                        (Format-MycoHarnessList) + '.')
                    return (New-MycoResult 2)
                }
                Write-MycoError ('unknown command "' + $command + '". Run "myco help" to see what is available.')
                return (New-MycoResult 2)
            }
        }
    } catch {
        Write-MycoError $_.Exception.Message
        return (New-MycoResult 1)
    }
}
