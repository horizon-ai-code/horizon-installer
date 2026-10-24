#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Auto', 'Cpu', 'Gpu')]
    [string]$Mode = 'Auto',
    [switch]$Yes,
    [switch]$DryRun,
    [switch]$NoOpen,
    [switch]$NoColor,
    [switch]$NoTui,
    [switch]$NoAnimation,
    [switch]$ForceGpu,
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:AppName = 'Horizon AI'
$script:AppTagline = 'Multi-Agent Glassbox Refactoring Studio'
$script:MinVramMb = 4096
$script:Esc = [char]27
$script:BackendImageGpu = 'ghcr.io/horizon-ai-code/horizon-backend:latest'
$script:BackendImageCpu = 'ghcr.io/horizon-ai-code/horizon-backend:cpu'
$script:FrontendImageDefault = 'ghcr.io/horizon-ai-code/horizon-frontend:latest'
$script:NetworkName = 'horizon_default'
$script:ContainerBackend = 'horizon-backend'
$script:ContainerFrontend = 'horizon-frontend'
$script:VolumeName = 'horizon_data'

$script:Mode = $Mode.ToLowerInvariant()
$script:Yes = [bool]$Yes
$script:DryRun = [bool]$DryRun
$script:NoOpen = [bool]$NoOpen
$script:NoColorFlag = [bool]$NoColor
$script:NoTui = [bool]$NoTui
$script:NoAnimation = [bool]$NoAnimation
$script:ForceGpu = [bool]$ForceGpu
$script:HorizonHome = $env:HORIZON_HOME
$script:HorizonDocker = if ([string]::IsNullOrWhiteSpace($env:HORIZON_DOCKER)) { 'docker' } else { $env:HORIZON_DOCKER }
$script:HorizonNvidiaSmi = if ([string]::IsNullOrWhiteSpace($env:HORIZON_NVIDIA_SMI)) { 'nvidia-smi' } else { $env:HORIZON_NVIDIA_SMI }

$script:OnWindows = ($env:OS -eq 'Windows_NT')
$script:OnMacOS = (-not $script:OnWindows) -and (Test-Path '/System/Library/CoreServices')
$script:OnWsl = (-not $script:OnWindows) -and (Test-Path '/proc/version') -and ((Get-Content '/proc/version' -Raw) -match 'microsoft')
$script:BackendImage = ''
$script:FrontendImage = ''
$script:LogFile = ''
$script:ExistingContainers = ''
$script:HttpTool = ''
$script:BrowseAvailable = $false

$script:DockerBin = ''
$script:DockerOk = $false
$script:DockerState = 'missing'
$script:DockerVersion = ''
$script:DockerDetail = ''
$script:GpuPresent = $false
$script:GpuName = ''
$script:GpuVramMb = 0
$script:GpuList = ''
$script:GpuRuntimeOk = $false
$script:GpuRuntimeDetail = ''
$script:GpuAvailable = $false
$script:GpuReason = ''
$script:RecommendedMode = 'cpu'
$script:ForceGpuWarning = $false

$script:TuiActive = $false
$script:Vt = $false
$script:Width = 80
$script:Height = 24
$script:ColorMode = 'none'
$script:Unicode = $false
$script:SpinnerIndex = 0
$script:InstallError = ''
$script:FailedStep = ''
$script:ModeIndex = 0
$script:MenuIndex = 0
$script:SuccessIndex = 0
$script:FailureIndex = 0
$script:StepPullBackend = 0
$script:StepPullFrontend = 0
$script:StepResources = 0
$script:StepStart = 0
$script:StepHealth = 0

$script:FgText = ''
$script:FgMuted = ''
$script:FgBlue = ''
$script:FgCyan = ''
$script:FgGreen = ''
$script:FgAmber = ''
$script:FgRed = ''
$script:FgWhite = ''
$script:FgBorder = ''
$script:BgMain = ''
$script:BgPanel = ''
$script:BgBlue = ''
$script:Bold = ''
$script:BoldOff = ''
$script:FgReset = ''
$script:AllReset = ''
$script:SymOk = ''
$script:SymWarn = ''
$script:SymFail = ''
$script:SymDot = ''
$script:SymCircle = ''
$script:SymArrow = ''
$script:SymGpu = ''
$script:SymCpu = ''
$script:SymH = ''
$script:SymV = ''
$script:BoxTl = ''
$script:BoxTr = ''
$script:BoxBl = ''
$script:BoxBr = ''
$script:BoxH = ''
$script:BoxV = ''
$script:KeyUpDown = ''
$script:Spinner = @()
$script:OriginalOutputEncoding = $null

function Write-Usage {
    @'
Usage: install.ps1 [options]

Options:
  -Mode Auto|Cpu|Gpu   Select the runtime mode
  -Yes                 Skip confirmation prompts
  -DryRun              Run checks and print the plan without installing
  -NoOpen              Do not open the browser after installation
  -NoColor             Disable ANSI colors
  -NoTui               Use plain terminal prompts
  -NoAnimation         Disable spinner animation
  -ForceGpu            Allow GPU mode below the 4 GB recommendation
  -Help                Show this help

Requirements:
  Docker Engine or Docker Desktop must be installed and running with Linux containers.
  Internet access is required for the first install; images are pulled from GHCR.

Environment:
  HORIZON_HOME         Install log directory
'@ | Write-Host
}

function Fail {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [int]$Code = 1
    )
    [Console]::Error.WriteLine($Message)
    exit $Code
}

function Test-Command {
    param([Parameter(Mandatory = $true)][string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @()
    )
    $output = & $FilePath @Arguments 2>&1 | Out-String
    return [pscustomobject]@{
        Output = $output.Trim()
        ExitCode = $LASTEXITCODE
    }
}

function Set-DefaultHome {
    if (-not [string]::IsNullOrWhiteSpace($script:HorizonHome)) {
        return
    }
    if ($script:OnWindows) {
        if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
            $script:HorizonHome = Join-Path $env:LOCALAPPDATA 'Horizon'
        } else {
            $script:HorizonHome = Join-Path $HOME 'Horizon'
        }
    } elseif ($script:OnMacOS) {
        $script:HorizonHome = Join-Path $HOME 'Library/Application Support/Horizon'
    } else {
        if (-not [string]::IsNullOrWhiteSpace($env:XDG_CONFIG_HOME)) {
            $script:HorizonHome = Join-Path $env:XDG_CONFIG_HOME 'horizon'
        } else {
            $script:HorizonHome = Join-Path $HOME '.config/horizon'
        }
    }
}

function Get-VisibleWidth {
    param([string]$Text)
    $plain = $Text -replace "$($script:Esc)\[[0-9;]*m", ''
    return $plain.Length
}

function Fit-Plain {
    param(
        [string]$Text,
        [int]$Max
    )
    if ($Text.Length -gt $Max) {
        return $Text.Substring(0, $Max)
    }
    return $Text
}

function Pad-Plain {
    param(
        [string]$Text,
        [int]$Width
    )
    $value = Fit-Plain -Text $Text -Max $Width
    return $value + (' ' * ($Width - $value.Length))
}

function Repeat-Char {
    param(
        [string]$Char,
        [int]$Count
    )
    if ($Count -le 0) {
        return ''
    }
    return $Char * $Count
}

function Enable-VirtualTerminal {
    if (-not $script:OnWindows) {
        $script:Vt = $true
        return
    }
    try {
        if (-not ('Horizon.ConsoleNative' -as [type])) {
            Add-Type -Namespace Horizon -Name ConsoleNative -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
[DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
'@ -ErrorAction Stop
        }
        $handle = [Horizon.ConsoleNative]::GetStdHandle(-11)
        $mode = [uint32]0
        [void][Horizon.ConsoleNative]::GetConsoleMode($handle, [ref]$mode)
        [void][Horizon.ConsoleNative]::SetConsoleMode($handle, $mode -bor 0x0004)
        $script:Vt = $true
    } catch {
        $script:Vt = $false
    }
}

function Set-Symbols {
    if ($script:Unicode) {
        $script:SymOk = '✓'
        $script:SymWarn = '!'
        $script:SymFail = '×'
        $script:SymDot = '●'
        $script:SymCircle = '○'
        $script:SymArrow = '▸'
        $script:SymGpu = '◈'
        $script:SymCpu = '▤'
        $script:SymH = '━'
        $script:SymV = '┃'
        $script:BoxTl = '╭'
        $script:BoxTr = '╮'
        $script:BoxBl = '╰'
        $script:BoxBr = '╯'
        $script:BoxH = '─'
        $script:BoxV = '│'
        $script:KeyUpDown = '↑↓'
        $script:Spinner = @('⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏')
    } else {
        $script:SymOk = '[OK]'
        $script:SymWarn = '[!]'
        $script:SymFail = '[X]'
        $script:SymDot = '*'
        $script:SymCircle = 'o'
        $script:SymArrow = '>'
        $script:SymGpu = '[G]'
        $script:SymCpu = '[C]'
        $script:SymH = '='
        $script:SymV = '|'
        $script:BoxTl = '+'
        $script:BoxTr = '+'
        $script:BoxBl = '+'
        $script:BoxBr = '+'
        $script:BoxH = '-'
        $script:BoxV = '|'
        $script:KeyUpDown = 'Up/Down'
        $script:Spinner = @('|', '/', '-', '\')
    }
}

function Set-ColorTokens {
    $e = $script:Esc
    $script:FgText = ''
    $script:FgMuted = ''
    $script:FgBlue = ''
    $script:FgCyan = ''
    $script:FgGreen = ''
    $script:FgAmber = ''
    $script:FgRed = ''
    $script:FgWhite = ''
    $script:FgBorder = ''
    $script:BgMain = ''
    $script:BgPanel = ''
    $script:BgBlue = ''
    $script:Bold = ''
    $script:BoldOff = ''
    $script:FgReset = ''
    $script:AllReset = ''

    switch ($script:ColorMode) {
        'truecolor' {
            $script:FgText = "$e[38;2;223;225;229m"
            $script:FgMuted = "$e[38;2;111;115;122m"
            $script:FgBlue = "$e[38;2;84;138;247m"
            $script:FgCyan = "$e[38;2;61;214;200m"
            $script:FgGreen = "$e[38;2;97;197;84m"
            $script:FgAmber = "$e[38;2;244;191;79m"
            $script:FgRed = "$e[38;2;249;62;62m"
            $script:FgWhite = "$e[38;2;255;255;255m"
            $script:FgBorder = "$e[38;2;57;59;64m"
            $script:BgMain = "$e[48;2;30;31;34m"
            $script:BgPanel = "$e[48;2;43;45;48m"
            $script:BgBlue = "$e[48;2;84;138;247m"
            $script:Bold = "$e[1m"
            $script:BoldOff = "$e[22m"
            $script:FgReset = "$e[39m"
            $script:AllReset = "$e[0m"
        }
        '256' {
            $script:FgText = "$e[38;5;253m"
            $script:FgMuted = "$e[38;5;243m"
            $script:FgBlue = "$e[38;5;69m"
            $script:FgCyan = "$e[38;5;80m"
            $script:FgGreen = "$e[38;5;77m"
            $script:FgAmber = "$e[38;5;221m"
            $script:FgRed = "$e[38;5;203m"
            $script:FgWhite = "$e[38;5;231m"
            $script:FgBorder = "$e[38;5;238m"
            $script:BgMain = "$e[48;5;234m"
            $script:BgPanel = "$e[48;5;236m"
            $script:BgBlue = "$e[48;5;69m"
            $script:Bold = "$e[1m"
            $script:BoldOff = "$e[22m"
            $script:FgReset = "$e[39m"
            $script:AllReset = "$e[0m"
        }
        '16' {
            $script:FgText = "$e[37m"
            $script:FgMuted = "$e[90m"
            $script:FgBlue = "$e[94m"
            $script:FgCyan = "$e[96m"
            $script:FgGreen = "$e[92m"
            $script:FgAmber = "$e[93m"
            $script:FgRed = "$e[91m"
            $script:FgWhite = "$e[97m"
            $script:FgBorder = "$e[90m"
            $script:BgMain = ''
            $script:BgPanel = ''
            $script:BgBlue = "$e[44m"
            $script:Bold = "$e[1m"
            $script:BoldOff = "$e[22m"
            $script:FgReset = "$e[39m"
            $script:AllReset = "$e[0m"
        }
    }
}

function Set-TerminalCaps {
    Enable-VirtualTerminal

    if ($script:NoColorFlag -or (-not [string]::IsNullOrWhiteSpace($env:NO_COLOR)) -or $env:TERM -eq 'dumb') {
        $script:ColorMode = 'none'
    } elseif ($script:Vt -and ((-not [string]::IsNullOrWhiteSpace($env:COLORTERM)) -or (-not [string]::IsNullOrWhiteSpace($env:WT_SESSION)))) {
        $script:ColorMode = 'truecolor'
    } elseif ($script:Vt) {
        $script:ColorMode = '256'
    } else {
        $script:ColorMode = 'none'
    }

    $script:Unicode = $false
    if (-not $script:OnWindows) {
        $script:Unicode = $true
    } elseif ((-not [string]::IsNullOrWhiteSpace($env:WT_SESSION)) -or ($PSVersionTable.PSVersion.Major -ge 7)) {
        $script:Unicode = $true
    } elseif ([Console]::OutputEncoding.CodePage -eq 65001) {
        $script:Unicode = $true
    }

    Set-Symbols
    Set-ColorTokens
}

function Get-TerminalSize {
    try {
        $script:Width = [Console]::WindowWidth
        $script:Height = [Console]::WindowHeight
    } catch {
        $script:Width = 80
        $script:Height = 24
    }
    if ($script:Width -lt 60 -or $script:Height -lt 18) {
        $script:NoTui = $true
    }
}

function Clear-Tui {
    if ($script:Vt) {
        Write-Host "$($script:Esc)[2J$($script:Esc)[H" -NoNewline
    } else {
        Clear-Host
    }
}

function Initialize-Tui {
    if ($script:NoTui -or [Console]::IsOutputRedirected) {
        $script:TuiActive = $false
        return $false
    }
    Get-TerminalSize
    if ($script:NoTui) {
        $script:TuiActive = $false
        return $false
    }
    try {
        $script:OriginalOutputEncoding = [Console]::OutputEncoding
        if ($script:OnWindows) {
            [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        }
    } catch {
        $script:OriginalOutputEncoding = $null
    }
    try {
        [Console]::Title = 'Horizon AI Setup'
    } catch {
    }
    try {
        [Console]::CursorVisible = $false
    } catch {
    }
    if ($script:Vt) {
        Write-Host "$($script:Esc)[?1049h$($script:Esc)[?25l" -NoNewline
    }
    $script:TuiActive = $true
    Clear-Tui
    return $true
}

function Restore-Tui {
    if (-not $script:TuiActive) {
        return
    }
    try {
        [Console]::CursorVisible = $true
    } catch {
    }
    if ($script:Vt) {
        Write-Host "$($script:Esc)[?25h$($script:Esc)[?1049l$($script:Esc)[0m" -NoNewline
    }
    if ($null -ne $script:OriginalOutputEncoding) {
        try {
            [Console]::OutputEncoding = $script:OriginalOutputEncoding
        } catch {
        }
    }
    $script:TuiActive = $false
}

function Write-TuiLine {
    param([string]$Text = '')
    $visible = Get-VisibleWidth $Text
    if ($visible -gt $script:Width) {
        Write-Host "$($script:BgMain)$Text$($script:AllReset)"
        return
    }
    $padding = $script:Width - $visible
    Write-Host "$($script:BgMain)$Text$($script:BgMain)$(' ' * $padding)$($script:AllReset)"
}

function Draw-HorizonLine {
    $left = [int]($script:Width / 2)
    $right = $script:Width - $left
    Write-TuiLine "$($script:FgBlue)$(Repeat-Char $script:SymH $left)$($script:FgCyan)$(Repeat-Char $script:SymH $right)$($script:FgReset)"
}

function Draw-Header {
    $mark1 = "$($script:FgBlue)$($script:SymV)$($script:FgReset)   $($script:FgBlue)$($script:SymV)$($script:FgReset)"
    $mark2 = "$($script:FgBlue)$($script:SymV)$($script:FgCyan)$($script:SymH)$($script:SymH)$($script:SymH)$($script:FgBlue)$($script:SymV)$($script:FgReset)"
    $mark3 = "$($script:FgBlue)$($script:SymV)$($script:FgReset)   $($script:FgBlue)$($script:SymV)$($script:FgReset)"
    $word = "$($script:Bold)$($script:FgText)Horizon$($script:FgReset)$($script:BoldOff) $($script:Bold)$($script:FgCyan)AI$($script:FgReset)$($script:BoldOff)"
    $tagline = "$($script:FgMuted)$($script:AppTagline)$($script:FgReset)"
    $status = "$($script:FgGreen)$($script:SymDot)$($script:FgReset) $($script:FgMuted)LOCAL$($script:FgReset)"
    $left = "  $mark1  $word"
    $right = $status
    $spaces = $script:Width - (Get-VisibleWidth $left) - (Get-VisibleWidth $right) - 2
    if ($spaces -lt 1) {
        $spaces = 1
    }
    Write-TuiLine "$($script:BgPanel)$left$(' ' * $spaces)$right"
    Write-TuiLine "$($script:BgPanel)  $mark2  $tagline"
    Write-TuiLine "$($script:BgPanel)  $mark3"
    Draw-HorizonLine
}

function Draw-Steps {
    param([int]$Current)
    $labels = @('SYSTEM', 'MODE', 'INSTALL', 'READY')
    $line = ''
    for ($i = 0; $i -lt 4; $i++) {
        if ($i -lt $Current) {
            $symbol = $script:SymOk
            $color = $script:FgGreen
        } elseif ($i -eq $Current) {
            $symbol = $script:SymDot
            $color = $script:FgCyan
        } else {
            $symbol = $script:SymCircle
            $color = $script:FgMuted
        }
        $label = "0$($i + 1) $($labels[$i])"
        $line += "$color$symbol$($script:FgReset) $($script:FgMuted)$label$($script:FgReset)"
        if ($i -lt 3) {
            $line += "  $($script:FgBorder)──$($script:FgReset)  "
        }
    }
    Write-TuiLine $line
}

function Draw-Footer {
    param([string]$Hints)
    Write-TuiLine "$($script:FgBorder)$(Repeat-Char $script:SymH $script:Width)$($script:FgReset)"
    Write-TuiLine "$($script:FgMuted)$Hints$($script:FgReset)"
}

function Draw-Frame {
    param(
        [int]$Current,
        [string]$Title,
        [string]$Subtitle,
        [string]$Footer,
        [string[]]$Body = @()
    )
    if ($script:Vt) {
        Write-Host "$($script:Esc)[H" -NoNewline
    } else {
        Clear-Host
    }
    Draw-Header
    Draw-Steps -Current $Current
    Write-TuiLine ''
    if (-not [string]::IsNullOrWhiteSpace($Title)) {
        Write-TuiLine "$($script:Bold)$($script:FgText)$Title$($script:FgReset)$($script:BoldOff)"
    }
    if (-not [string]::IsNullOrWhiteSpace($Subtitle)) {
        Write-TuiLine "$($script:FgMuted)$Subtitle$($script:FgReset)"
    }
    Write-TuiLine ''
    foreach ($line in $Body) {
        Write-TuiLine $line
    }
    Write-TuiLine ''
    Draw-Footer -Hints $Footer
    if ($script:Vt) {
        Write-Host "$($script:Esc)[J" -NoNewline
    }
}

function Get-Spinner {
    if ($script:NoAnimation) {
        return $script:SymCircle
    }
    if ($script:Spinner.Count -eq 0) {
        return $script:SymCircle
    }
    $value = $script:Spinner[$script:SpinnerIndex % $script:Spinner.Count]
    $script:SpinnerIndex++
    return $value
}

function Write-StatusRow {
    param(
        [string]$Label,
        [string]$Value,
        [string]$Detail,
        [string]$State
    )
    switch ($State) {
        'ok' {
            $symbol = $script:SymOk
            $color = $script:FgGreen
        }
        'warn' {
            $symbol = $script:SymWarn
            $color = $script:FgAmber
        }
        'fail' {
            $symbol = $script:SymFail
            $color = $script:FgRed
        }
        default {
            $symbol = $script:SymCircle
            $color = $script:FgMuted
        }
    }
    $detailWidth = [Math]::Max(8, $script:Width - 44)
    $detail = Fit-Plain -Text $Detail -Max $detailWidth
    return "$color$symbol$($script:FgReset)  $($Label.PadRight(20)) $($Value.PadRight(16)) $($script:FgMuted)$detail$($script:FgReset)"
}

function New-Card {
    param(
        [int]$Width,
        [string]$Border,
        [string]$Title,
        [string]$Subtitle,
        [string]$LineOne,
        [string]$LineTwo,
        [string]$Badge,
        [string]$BadgeColor,
        [string]$TextColor
    )
    $inner = $Width - 4
    $lines = @()
    $lines += "$($script:BgPanel)$Border$($script:BoxTl)$(Repeat-Char $script:BoxH ($Width - 2))$($script:BoxTr)$($script:AllReset)"
    $lines += "$($script:BgPanel)$Border$($script:BoxV) $TextColor$(Pad-Plain -Text $Title -Width $inner)$Border $($script:BoxV)$($script:AllReset)"
    $lines += "$($script:BgPanel)$Border$($script:BoxV) $($script:FgMuted)$(Pad-Plain -Text $Subtitle -Width $inner)$Border $($script:BoxV)$($script:AllReset)"
    $lines += "$($script:BgPanel)$Border$($script:BoxV) $TextColor$(Pad-Plain -Text '' -Width $inner)$Border $($script:BoxV)$($script:AllReset)"
    $lines += "$($script:BgPanel)$Border$($script:BoxV) $TextColor$(Pad-Plain -Text $LineOne -Width $inner)$Border $($script:BoxV)$($script:AllReset)"
    $lines += "$($script:BgPanel)$Border$($script:BoxV) $($script:FgMuted)$(Pad-Plain -Text $LineTwo -Width $inner)$Border $($script:BoxV)$($script:AllReset)"
    $lines += "$($script:BgPanel)$Border$($script:BoxV) $BadgeColor$(Pad-Plain -Text $Badge -Width $inner)$Border $($script:BoxV)$($script:AllReset)"
    $lines += "$($script:BgPanel)$Border$($script:BoxBl)$(Repeat-Char $script:BoxH ($Width - 2))$($script:BoxBr)$($script:AllReset)"
    return $lines
}

function Write-MenuLine {
    param(
        [string]$Label,
        [bool]$Selected
    )
    if ($Selected) {
        return "$($script:BgBlue)$($script:FgWhite)$(Pad-Plain -Text "  $($script:SymArrow) $Label" -Width $script:Width)$($script:AllReset)"
    }
    return "$($script:BgMain)  $Label$($script:AllReset)"
}

function Write-KvLine {
    param(
        [string]$Key,
        [string]$Value
    )
    return "$($script:FgMuted)$($Key.PadRight(12))$($script:FgReset)$Value$($script:FgReset)"
}

function Write-ProgressBar {
    param(
        [int]$Done,
        [int]$Total,
        [int]$Width
    )
    $fill = [int](($Width * $Done) / $Total)
    $empty = $Width - $fill
    if ($fill -lt 0) { $fill = 0 }
    if ($empty -lt 0) { $empty = 0 }
    return "$($script:FgBlue)$(Repeat-Char $script:SymH $fill)$($script:FgBorder)$(Repeat-Char $script:SymH $empty)$($script:FgReset)"
}

function Write-StepRow {
    param(
        [string]$State,
        [string]$Label,
        [string]$Detail
    )
    switch ($State) {
        'done' {
            $symbol = $script:SymOk
            $color = $script:FgGreen
        }
        'active' {
            $symbol = Get-Spinner
            $color = $script:FgCyan
        }
        'fail' {
            $symbol = $script:SymFail
            $color = $script:FgRed
        }
        default {
            $symbol = $script:SymCircle
            $color = $script:FgMuted
        }
    }
    $line = "$color$symbol$($script:FgReset)  $($script:FgText)$Label$($script:FgReset)"
    if (-not [string]::IsNullOrWhiteSpace($Detail)) {
        $line += "  $($script:FgMuted)$Detail$($script:FgReset)"
    }
    return $line
}

function Get-LogTail {
    param([int]$Count)
    $maxWidth = [Math]::Max(10, $script:Width - 6)
    $lines = @()
    foreach ($path in @($script:LogFile, "$($script:LogFile).out", "$($script:LogFile).err")) {
        if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path $path)) {
            $lines += @(Get-Content -Path $path -Tail $Count -ErrorAction SilentlyContinue)
        }
    }
    if ($lines.Count -eq 0) {
        return @('Waiting for output...')
    }
    return @($lines | Select-Object -Last $Count | ForEach-Object { Fit-Plain -Text $_ -Max $maxWidth })
}

function Get-WrappedLines {
    param(
        [string]$Text,
        [int]$Width
    )
    $words = $Text -split '\s+'
    $lines = @()
    $current = ''
    foreach ($word in $words) {
        if ($current.Length -eq 0) {
            $current = $word
        } elseif (($current.Length + $word.Length + 1) -le $Width) {
            $current = "$current $word"
        } else {
            $lines += $current
            $current = $word
        }
    }
    if ($current.Length -gt 0) {
        $lines += $current
    }
    return $lines
}

function Get-DockerStatus {
    $script:DockerBin = $script:HorizonDocker
    $script:DockerOk = $false
    $script:DockerState = 'missing'
    $script:DockerVersion = ''
    $script:DockerDetail = ''

    if ($script:DockerBin -eq 'none' -or -not (Test-Command $script:DockerBin)) {
        $script:DockerState = 'missing'
        $script:DockerDetail = 'Install Docker Engine or Docker Desktop.'
        return
    }

    $versionResult = Invoke-Native -FilePath $script:DockerBin -Arguments @('--version')
    if ([string]::IsNullOrWhiteSpace($versionResult.Output)) {
        $script:DockerState = 'error'
        $script:DockerDetail = 'Docker is installed but not responding.'
        return
    }
    $versionMatch = [regex]::Match($versionResult.Output, 'Docker version ([^,]+)')
    if ($versionMatch.Success) {
        $script:DockerVersion = $versionMatch.Groups[1].Value.Trim()
    } else {
        $script:DockerVersion = $versionResult.Output
    }

    $infoResult = Invoke-Native -FilePath $script:DockerBin -Arguments @('info')
    if ($infoResult.ExitCode -ne 0) {
        $script:DockerState = 'down'
        if ($infoResult.Output -match 'permission denied|Permission denied') {
            $script:DockerState = 'permission'
            $script:DockerDetail = 'Add your user to the docker group or run with the right permissions.'
        } elseif ($infoResult.Output -match 'Cannot connect|Is the docker daemon running|is the docker daemon running') {
            $script:DockerDetail = 'Start Docker Desktop or the Docker daemon, then re-check.'
        } else {
            $script:DockerDetail = 'Docker is installed but the daemon is not reachable.'
        }
        return
    }

    $osTypeResult = Invoke-Native -FilePath $script:DockerBin -Arguments @('info', '--format', '{{.OSType}}')
    $osType = $osTypeResult.Output.Trim()
    if (-not [string]::IsNullOrWhiteSpace($osType) -and $osType -ne 'linux') {
        $script:DockerState = 'windows-containers'
        $script:DockerOk = $false
        $script:DockerDetail = 'Docker Desktop is using Windows containers. Switch to Linux containers.'
        return
    }

    $script:DockerState = 'running'
    $script:DockerOk = $true
    $script:DockerDetail = 'linux containers'
}

function Get-GpuStatus {
    $script:GpuPresent = $false
    $script:GpuName = ''
    $script:GpuVramMb = 0
    $script:GpuList = ''
    $script:GpuRuntimeOk = $false
    $script:GpuRuntimeDetail = ''
    $script:GpuAvailable = $false
    $script:GpuReason = ''

    if ($script:OnMacOS) {
        $script:GpuReason = 'NVIDIA GPU acceleration is not supported on macOS.'
        return
    }

    $nvidia = $script:HorizonNvidiaSmi
    if ($nvidia -eq 'none' -or -not (Test-Command $nvidia)) {
        if ($script:OnWindows) {
            $candidate = Join-Path $env:WINDIR 'System32/nvidia-smi.exe'
            if (Test-Path $candidate) {
                $nvidia = $candidate
            }
        }
    }
    if ($nvidia -eq 'none' -or -not (Test-Command $nvidia)) {
        $script:GpuReason = 'No NVIDIA GPU detected.'
        return
    }

    $gpuResult = Invoke-Native -FilePath $nvidia -Arguments @('--query-gpu=name,memory.total', '--format=csv,noheader,nounits')
    if ($gpuResult.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($gpuResult.Output)) {
        if ($script:OnWindows) {
            try {
                $controller = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'NVIDIA' } | Select-Object -First 1
                if ($null -ne $controller) {
                    $script:GpuPresent = $true
                    $script:GpuName = $controller.Name
                    $script:GpuVramMb = 0
                    $script:GpuList = "$($controller.Name) (VRAM unavailable)"
                    $script:GpuReason = 'NVIDIA GPU detected, but VRAM could not be read.'
                } else {
                    $script:GpuReason = 'No NVIDIA GPU detected.'
                }
            } catch {
                $script:GpuReason = 'No NVIDIA GPU detected.'
            }
        } else {
            $script:GpuReason = 'No NVIDIA GPU detected.'
        }
        return
    }

    $lines = $gpuResult.Output -split "`r?`n"
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        $parts = $line -split ','
        if ($parts.Count -lt 2) {
            continue
        }
        $name = $parts[0].Trim()
        $memoryText = $parts[1].Trim()
        $memory = 0
        if (-not [int]::TryParse($memoryText, [ref]$memory)) {
            continue
        }
        $script:GpuPresent = $true
        if (-not [string]::IsNullOrWhiteSpace($script:GpuList)) {
            $script:GpuList += ', '
        }
        $script:GpuList += "$name ($memory MB)"
        if ($memory -gt $script:GpuVramMb) {
            $script:GpuVramMb = $memory
            $script:GpuName = $name
        }
    }

    if (-not $script:GpuPresent) {
        $script:GpuReason = 'No NVIDIA GPU detected.'
        return
    }

    if ($script:DockerOk) {
        $runtimeResult = Invoke-Native -FilePath $script:DockerBin -Arguments @('info', '--format', '{{json .Runtimes}}')
        if ($runtimeResult.Output -match '"nvidia"') {
            $script:GpuRuntimeOk = $true
            $script:GpuRuntimeDetail = 'nvidia'
        } else {
            $script:GpuRuntimeOk = $false
            $script:GpuRuntimeDetail = 'missing'
        }
    } else {
        $script:GpuRuntimeDetail = 'Docker is not running'
    }

    if ($script:GpuVramMb -lt $script:MinVramMb) {
        $script:GpuReason = "GPU has $($script:GpuVramMb) MB VRAM; $($script:MinVramMb) MB minimum."
    } elseif (-not $script:GpuRuntimeOk) {
        $script:GpuReason = 'NVIDIA Container Toolkit is required for GPU mode.'
    } else {
        $script:GpuReason = 'GPU acceleration is ready.'
        $script:GpuAvailable = $true
    }
}

function Get-Recommendation {
    if ($script:GpuAvailable) {
        $script:RecommendedMode = 'gpu'
    } else {
        $script:RecommendedMode = 'cpu'
    }
}

function Resolve-Mode {
    if ($script:Mode -eq 'auto') {
        $script:Mode = $script:RecommendedMode
    }
    if ($script:Mode -eq 'cpu') {
        return 0
    }
    if ($script:Mode -eq 'gpu') {
        if (-not $script:GpuPresent) {
            [Console]::Error.WriteLine('No NVIDIA GPU detected. CPU mode works on this machine.')
            return 4
        }
        if (($script:GpuVramMb -lt $script:MinVramMb) -and (-not $script:ForceGpu)) {
            [Console]::Error.WriteLine("GPU has $($script:GpuVramMb) MB VRAM; $($script:MinVramMb) MB minimum. Use -ForceGpu to override.")
            return 4
        }
        if (-not $script:GpuRuntimeOk) {
            [Console]::Error.WriteLine('NVIDIA Container Toolkit is required for GPU mode.')
            return 4
        }
        if (($script:GpuVramMb -lt $script:MinVramMb) -and $script:ForceGpu) {
            $script:ForceGpuWarning = $true
        }
        return 0
    }
    [Console]::Error.WriteLine("Unknown mode: $($script:Mode)")
    return 2
}

function Invoke-Preflight {
    Get-DockerStatus
    Get-GpuStatus
    Get-Recommendation

    if (Test-Command 'curl') {
        $script:HttpTool = 'curl'
    } elseif (Test-Command 'wget') {
        $script:HttpTool = 'wget'
    } else {
        $script:HttpTool = 'none'
    }

    $script:BrowseAvailable = $false
    if (-not $script:NoOpen) {
        if ($script:OnWindows) {
            $script:BrowseAvailable = $true
        } elseif ($script:OnMacOS -and (Test-Command 'open')) {
            $script:BrowseAvailable = $true
        } elseif ($script:OnWsl -and ((Test-Command 'cmd.exe') -or (Test-Command 'wslview'))) {
            $script:BrowseAvailable = $true
        } elseif ((-not [string]::IsNullOrWhiteSpace($env:DISPLAY)) -or (-not [string]::IsNullOrWhiteSpace($env:WAYLAND_DISPLAY))) {
            $script:BrowseAvailable = [bool](Test-Command 'xdg-open')
        }
    }
}

function Show-PreflightPlain {
    Write-Host "$($script:AppName) Setup"
    $dockerText = $script:DockerState
    if (-not [string]::IsNullOrWhiteSpace($script:DockerVersion)) {
        $dockerText += " ($($script:DockerVersion))"
    }
    Write-Host "Docker: $dockerText"
    if ($script:GpuPresent) {
        Write-Host "NVIDIA GPU: $($script:GpuName) ($($script:GpuVramMb) MB VRAM)"
        if ($script:GpuRuntimeOk) {
            Write-Host 'GPU container support: ready'
        } else {
            Write-Host 'GPU container support: missing'
        }
    } else {
        Write-Host 'NVIDIA GPU: none'
        Write-Host 'GPU container support: unavailable'
    }
    Write-Host "Recommended: $($script:RecommendedMode.ToUpperInvariant())"
    if ($script:GpuPresent -and -not $script:GpuAvailable) {
        Write-Host "GPU mode is unavailable: $($script:GpuReason)"
    }
}

function Show-PreflightError {
    switch ($script:DockerState) {
        'missing' {
            Write-Host 'Docker is not installed. Install Docker Engine or Docker Desktop, then re-run.'
        }
        'down' {
            Write-Host 'Docker is installed but not running. Start Docker Desktop or the Docker daemon, then re-run.'
        }
        'permission' {
            Write-Host 'Docker is running, but this user cannot access it. Add your user to the docker group or run with the right permissions.'
        }
        'windows-containers' {
            Write-Host 'Docker Desktop is using Windows containers. Switch it to Linux containers, then re-run.'
        }
        default {
            Write-Host "Docker is not ready. $($script:DockerDetail)"
        }
    }
}

function Show-SummaryPlain {
    Write-Host "Mode: $($script:Mode.ToUpperInvariant())"
    Write-Host "Backend image: $($script:BackendImage)"
    Write-Host "Frontend image: $($script:FrontendImage)"
    Write-Host 'Ports: 3000 (UI), 8000 (API)'
    Write-Host "Data: $($script:VolumeName) (persisted)"
    Write-Host "Network: $($script:NetworkName)"
    Write-Host 'Internet: required for the first install'
    if (-not [string]::IsNullOrWhiteSpace($script:ExistingContainers)) {
        Write-Host "Existing containers will be recreated: $($script:ExistingContainers)"
    }
    if ($script:ForceGpuWarning) {
        Write-Host "Warning: GPU mode forced below the $($script:MinVramMb) MB recommendation."
    }
    if ($script:DryRun) {
        Write-Host 'Dry run: no changes made.'
    }
}

function Show-SuccessPlain {
    Write-Host 'Horizon AI is ready.'
    Write-Host 'Open: http://localhost:3000'
    Write-Host 'API: http://localhost:8000'
    Write-Host "Mode: $($script:Mode.ToUpperInvariant())"
    Write-Host "Logs: docker logs -f $($script:ContainerBackend)"
    Write-Host "Logs: docker logs -f $($script:ContainerFrontend)"
    Write-Host "Stop: docker stop $($script:ContainerFrontend) $($script:ContainerBackend)"
    Write-Host "Start: docker start $($script:ContainerBackend) $($script:ContainerFrontend)"
}

function Resolve-Images {
    if ($script:Mode -eq 'gpu') {
        $script:BackendImage = $script:BackendImageGpu
    } else {
        $script:BackendImage = $script:BackendImageCpu
    }
    $script:FrontendImage = $script:FrontendImageDefault
}

function Find-Volume {
    $result = Invoke-Native -FilePath $script:DockerBin -Arguments @('volume', 'ls', '--format', '{{.Name}}')
    $names = @($result.Output -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($names -contains 'horizon_data') {
        $script:VolumeName = 'horizon_data'
        return
    }
    if ($names -contains 'horizon_horizon_data') {
        $script:VolumeName = 'horizon_horizon_data'
        return
    }
    $match = $names | Where-Object { $_ -match '(^|_)horizon_data$' } | Select-Object -First 1
    if ($null -ne $match) {
        $script:VolumeName = $match
    } else {
        $script:VolumeName = 'horizon_data'
    }
}

function Detect-ExistingState {
    $result = Invoke-Native -FilePath $script:DockerBin -Arguments @('ps', '-a', '--format', '{{.Names}}|{{.Image}}')
    $names = @()
    foreach ($line in ($result.Output -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        $parts = $line -split '\|', 2
        if ($parts.Count -lt 2) {
            continue
        }
        if ($parts[0] -match '^horizon-(backend|frontend)(-1)?$' -or $parts[1] -match 'horizon-(backend|frontend)') {
            $names += $parts[0]
        }
    }
    $script:ExistingContainers = (@($names | Select-Object -Unique) -join ' ').Trim()
    Find-Volume
}

function Prepare-State {
    Resolve-Images
    Detect-ExistingState
    $script:LogFile = Join-Path $script:HorizonHome 'install.log'
    New-Item -ItemType Directory -Force -Path $script:HorizonHome | Out-Null
}

function Prepare-Resources {
    Detect-ExistingState
    if (-not [string]::IsNullOrWhiteSpace($script:ExistingContainers)) {
        foreach ($container in ($script:ExistingContainers -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
            $removed = Invoke-Native -FilePath $script:DockerBin -Arguments @('rm', '-f', $container)
            if (-not [string]::IsNullOrWhiteSpace($removed.Output)) {
                Add-Content -Path $script:LogFile -Value $removed.Output -ErrorAction SilentlyContinue
            }
        }
    }
    $network = Invoke-Native -FilePath $script:DockerBin -Arguments @('network', 'inspect', $script:NetworkName)
    if ($network.ExitCode -ne 0) {
        $created = Invoke-Native -FilePath $script:DockerBin -Arguments @('network', 'create', $script:NetworkName)
        if (-not [string]::IsNullOrWhiteSpace($created.Output)) {
            Add-Content -Path $script:LogFile -Value $created.Output -ErrorAction SilentlyContinue
        }
        if ($created.ExitCode -ne 0) {
            return $false
        }
    }
    $volume = Invoke-Native -FilePath $script:DockerBin -Arguments @('volume', 'inspect', $script:VolumeName)
    if ($volume.ExitCode -ne 0) {
        $created = Invoke-Native -FilePath $script:DockerBin -Arguments @('volume', 'create', $script:VolumeName)
        if (-not [string]::IsNullOrWhiteSpace($created.Output)) {
            Add-Content -Path $script:LogFile -Value $created.Output -ErrorAction SilentlyContinue
        }
        if ($created.ExitCode -ne 0) {
            return $false
        }
    }
    return $true
}

function Start-Containers {
    $backendArgs = @('run', '-d', '--name', $script:ContainerBackend, '--restart', 'unless-stopped', '--network', $script:NetworkName, '-p', '8000:8000', '-v', "$($script:VolumeName):/app/db")
    if ($script:Mode -eq 'gpu') {
        $backendArgs += @('--gpus', 'all')
    }
    $backendArgs += $script:BackendImage
    if ((Invoke-DockerWithProgress -StepName 'Starting backend...' -Arguments $backendArgs) -ne 0) {
        return $false
    }
    $frontendArgs = @('run', '-d', '--name', $script:ContainerFrontend, '--restart', 'unless-stopped', '--network', $script:NetworkName, '-p', '3000:3000', $script:FrontendImage)
    if ((Invoke-DockerWithProgress -StepName 'Starting frontend...' -Arguments $frontendArgs) -ne 0) {
        return $false
    }
    return $true
}

function Test-Http {
    param([string]$Url)
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec 2 -ErrorAction Stop
        return ($response.StatusCode -ge 200 -and $response.StatusCode -lt 400)
    } catch {
        return $false
    }
}

function Wait-Api {
    if ($env:HORIZON_SKIP_HEALTH -eq '1') {
        Start-Sleep -Seconds 1
        return $true
    }
    if ($script:HttpTool -eq 'none') {
        Start-Sleep -Seconds 3
        return $true
    }
    for ($i = 0; $i -lt 90; $i++) {
        if (Test-Http -Url 'http://127.0.0.1:8000/health') {
            return $true
        }
        if ($script:TuiActive) {
            Show-Progress
        }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Wait-Ui {
    if ($env:HORIZON_SKIP_HEALTH -eq '1') {
        Start-Sleep -Seconds 1
        return $true
    }
    if ($script:HttpTool -eq 'none') {
        Start-Sleep -Seconds 3
        return $true
    }
    for ($i = 0; $i -lt 90; $i++) {
        if (Test-Http -Url 'http://127.0.0.1:3000') {
            return $true
        }
        if ($script:TuiActive) {
            Show-Progress
        }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Invoke-DockerWithProgress {
    param(
        [string]$StepName,
        [string[]]$Arguments
    )
    if (-not $script:TuiActive) {
        Write-Host $StepName
        $result = Invoke-Native -FilePath $script:DockerBin -Arguments $Arguments
        if (-not [string]::IsNullOrWhiteSpace($result.Output)) {
            Add-Content -Path $script:LogFile -Value $result.Output -ErrorAction SilentlyContinue
        }
        return $result.ExitCode
    }
    $stdout = "$($script:LogFile).out"
    $stderr = "$($script:LogFile).err"
    Remove-Item -Force -ErrorAction SilentlyContinue $stdout, $stderr
    try {
        $process = Start-Process -FilePath $script:DockerBin -ArgumentList $Arguments -NoNewWindow -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr -ErrorAction Stop
    } catch {
        return 1
    }
    try {
        while (-not $process.HasExited) {
            Show-Progress
            Start-Sleep -Milliseconds 200
        }
        $process.WaitForExit()
    } finally {
        if (-not $process.HasExited) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
    }
    $exitCode = $process.ExitCode
    if (Test-Path $stdout) {
        $content = Get-Content -Path $stdout -ErrorAction SilentlyContinue
        if ($null -ne $content) {
            Add-Content -Path $script:LogFile -Value $content -ErrorAction SilentlyContinue
        }
    }
    if (Test-Path $stderr) {
        $content = Get-Content -Path $stderr -ErrorAction SilentlyContinue
        if ($null -ne $content) {
            Add-Content -Path $script:LogFile -Value $content -ErrorAction SilentlyContinue
        }
    }
    Remove-Item -Force -ErrorAction SilentlyContinue $stdout, $stderr
    return $exitCode
}

function Invoke-Install {
    $script:StepPullBackend = 1
    $script:StepPullFrontend = 0
    $script:StepResources = 0
    $script:StepStart = 0
    $script:StepHealth = 0
    $script:InstallError = ''
    $script:FailedStep = ''
    New-Item -ItemType Directory -Force -Path $script:HorizonHome | Out-Null
    Set-Content -Path $script:LogFile -Value ''

    if ((Invoke-DockerWithProgress -StepName 'Pulling backend image...' -Arguments @('pull', $script:BackendImage)) -ne 0) {
        $script:StepPullBackend = 3
        $script:FailedStep = 'Pull backend image'
        $script:InstallError = 'Could not pull the backend image. Check your internet connection.'
        return $false
    }
    $script:StepPullBackend = 2
    $script:StepPullFrontend = 1

    if ((Invoke-DockerWithProgress -StepName 'Pulling frontend image...' -Arguments @('pull', $script:FrontendImage)) -ne 0) {
        $script:StepPullFrontend = 3
        $script:FailedStep = 'Pull frontend image'
        $script:InstallError = 'Could not pull the frontend image. Check your internet connection.'
        return $false
    }
    $script:StepPullFrontend = 2
    $script:StepResources = 1

    if (-not (Prepare-Resources)) {
        $script:StepResources = 3
        $script:FailedStep = 'Prepare Docker resources'
        $script:InstallError = 'Could not create the Horizon AI Docker network or volume.'
        return $false
    }
    $script:StepResources = 2
    $script:StepStart = 1

    if (-not (Start-Containers)) {
        $script:StepStart = 3
        $script:FailedStep = 'Start containers'
        $script:InstallError = 'Docker could not start the Horizon AI containers.'
        return $false
    }
    $script:StepStart = 2
    $script:StepHealth = 1

    if (-not (Wait-Api)) {
        $script:StepHealth = 3
        $script:FailedStep = 'Wait for the API'
        $script:InstallError = 'The Horizon AI API did not become healthy in time.'
        return $false
    }
    if (-not (Wait-Ui)) {
        $script:StepHealth = 3
        $script:FailedStep = 'Wait for the UI'
        $script:InstallError = 'The Horizon AI UI did not become reachable in time.'
        return $false
    }
    $script:StepHealth = 2
    return $true
}

function Open-Browser {
    $url = 'http://localhost:3000'
    if (-not $script:BrowseAvailable -or $script:NoOpen) {
        Write-Host "Open $url in your browser."
        return
    }
    try {
        if ($script:OnWindows -or $script:OnMacOS) {
            Start-Process $url | Out-Null
        } elseif ($script:OnWsl -and (Test-Command 'wslview')) {
            Start-Process 'wslview' -ArgumentList $url | Out-Null
        } elseif ($script:OnWsl) {
            Start-Process 'cmd.exe' -ArgumentList '/c', 'start', '', $url | Out-Null
        } else {
            Start-Process 'xdg-open' -ArgumentList $url | Out-Null
        }
    } catch {
        Write-Host "Open $url in your browser."
    }
}

function Invoke-PlainMode {
    Show-PreflightPlain
    if (-not $script:DockerOk) {
        Show-PreflightError
        return 3
    }
    if ($script:Mode -eq 'auto') {
        $script:Mode = $script:RecommendedMode
    }
    $rc = Resolve-Mode
    if ($rc -ne 0) {
        return $rc
    }
    Prepare-State
    if ($script:DryRun) {
        Show-SummaryPlain
        return 0
    }
    if (-not $script:Yes) {
        if ([Console]::IsInputRedirected) {
            [Console]::Error.WriteLine('No TTY available. Re-run with -Mode and -Yes for non-interactive use.')
            return 2
        }
        $answer = Read-Host 'Install Horizon AI? [Y/n]'
        if ($answer -match '^(n|N|no|NO)$') {
            return 1
        }
    }
    if (-not (Invoke-Install)) {
        [Console]::Error.WriteLine($script:InstallError)
        if (Test-Path $script:LogFile) {
            Get-Content -Path $script:LogFile -Tail 12 | ForEach-Object { [Console]::Error.WriteLine($_) }
        }
        return 1
    }
    Show-SuccessPlain
    Open-Browser
    return 0
}

function Show-Preflight {
    $body = @()
    $dockerState = 'fail'
    $dockerValue = 'not found'
    $dockerDetail = 'install Docker Engine or Docker Desktop'
    $gpuState = 'info'
    $gpuValue = 'none'
    $gpuDetail = 'CPU mode works everywhere'
    $runtimeState = 'info'
    $runtimeValue = 'not needed'
    $runtimeDetail = ''
    $footer = 'Enter Continue   R Re-check   D Guide   Q Quit'

    if ($script:DockerOk) {
        $dockerState = 'ok'
        $dockerValue = $script:DockerVersion
        $dockerDetail = 'linux containers'
    } elseif ($script:DockerState -eq 'missing') {
        $dockerValue = 'not found'
        $dockerDetail = 'install Docker Engine or Docker Desktop'
    } else {
        $dockerValue = 'not running'
        $dockerDetail = $script:DockerDetail
    }

    if ($script:GpuPresent) {
        if ($script:GpuAvailable) {
            $gpuState = 'ok'
        } else {
            $gpuState = 'warn'
        }
        $gpuValue = "$($script:GpuVramMb) MB"
        $gpuDetail = $script:GpuName
        if ($script:GpuRuntimeOk) {
            $runtimeState = 'ok'
            $runtimeValue = $script:GpuRuntimeDetail
            $runtimeDetail = 'ready'
        } else {
            $runtimeState = 'warn'
            $runtimeValue = 'missing'
            $runtimeDetail = 'NVIDIA Container Toolkit required'
        }
    }

    $body += Write-StatusRow -Label 'Docker Engine' -Value $dockerValue -Detail $dockerDetail -State $dockerState
    $body += Write-StatusRow -Label 'NVIDIA GPU' -Value $gpuValue -Detail $gpuDetail -State $gpuState
    $body += Write-StatusRow -Label 'GPU container' -Value $runtimeValue -Detail $runtimeDetail -State $runtimeState
    $body += ''
    $body += "$($script:FgMuted)Recommended$($script:FgReset)  $($script:Bold)$($script:FgBlue)$($script:RecommendedMode.ToUpperInvariant())$($script:FgReset)$($script:BoldOff)"
    if ($script:GpuPresent -and -not $script:GpuAvailable) {
        $body += "$($script:FgAmber)$($script:GpuReason)$($script:FgReset)"
    }
    if (-not $script:DockerOk) {
        $body += ''
        $body += "$($script:FgRed)Docker must be installed and running before installation can continue.$($script:FgReset)"
    }

    Draw-Frame -Current 0 -Title 'System check' -Subtitle 'Horizon AI pulls the prebuilt stack from GitHub Container Registry.' -Footer $footer -Body $body
}

function Show-Mode {
    $body = @()
    $sideBySide = $false
    if ($script:Width -ge 92) {
        $sideBySide = $true
        $cardWidth = [int](($script:Width - 8) / 2)
        if ($cardWidth -gt 48) { $cardWidth = 48 }
        if ($cardWidth -lt 34) { $cardWidth = 34 }
    } else {
        $cardWidth = $script:Width - 6
        if ($cardWidth -gt 72) { $cardWidth = 72 }
        if ($cardWidth -lt 40) { $cardWidth = 40 }
    }

    $gpuLineOne = 'No NVIDIA GPU detected'
    $gpuLineTwo = ''
    if ($script:GpuPresent) {
        $gpuLineOne = $script:GpuName
        $gpuLineTwo = "$($script:GpuVramMb) MB VRAM"
    }

    $gpuBadge = ''
    $gpuText = $script:FgText
    if ($script:GpuAvailable) {
        if ($script:RecommendedMode -eq 'gpu') {
            $gpuBadge = '[ RECOMMENDED ]'
        }
    } else {
        $gpuText = $script:FgMuted
        if ($script:GpuPresent) {
            $gpuBadge = '[ UNAVAILABLE ]'
        }
    }
    $cpuBadge = ''
    if ($script:RecommendedMode -eq 'cpu') {
        $cpuBadge = '[ RECOMMENDED ]'
    }

    $gpuTitle = "GPU $($script:SymGpu)"
    $cpuTitle = "CPU $($script:SymCpu)"
    $gpuBorder = $script:FgBorder
    $cpuBorder = $script:FgBorder
    if ($script:ModeIndex -eq 0) {
        $gpuTitle = "$($script:SymArrow) GPU $($script:SymGpu)"
        $gpuBorder = $script:FgBlue
    }
    if ($script:ModeIndex -eq 1) {
        $cpuTitle = "$($script:SymArrow) CPU $($script:SymCpu)"
        $cpuBorder = $script:FgBlue
    }

    $gpuCard = @(New-Card -Width $cardWidth -Border $gpuBorder -Title $gpuTitle -Subtitle 'NVIDIA acceleration' -LineOne $gpuLineOne -LineTwo $gpuLineTwo -Badge $gpuBadge -BadgeColor $script:FgBlue -TextColor $gpuText)
    $cpuCard = @(New-Card -Width $cardWidth -Border $cpuBorder -Title $cpuTitle -Subtitle 'Runs on any machine' -LineOne 'No GPU required' -LineTwo 'Slower on large refactors' -Badge $cpuBadge -BadgeColor $script:FgBlue -TextColor $script:FgText)

    if ($sideBySide) {
        for ($i = 0; $i -lt $gpuCard.Count; $i++) {
            $body += "$($gpuCard[$i])$($script:BgMain)  $($cpuCard[$i])"
        }
    } else {
        foreach ($line in $gpuCard) {
            $body += $line
        }
        $body += ''
        foreach ($line in $cpuCard) {
            $body += $line
        }
    }

    $runtimeDisplay = $script:GpuRuntimeDetail
    if ([string]::IsNullOrWhiteSpace($runtimeDisplay)) {
        $runtimeDisplay = 'n/a'
    }
    $body += ''
    $body += "$($script:FgMuted)ENVIRONMENT$($script:FgReset)"
    $body += "$($script:FgGreen)$($script:SymDot)$($script:FgReset) Docker $($script:DockerVersion)   $($script:FgGreen)$($script:SymDot)$($script:FgReset) GPU runtime $runtimeDisplay   $($script:FgMuted)GHCR images$($script:FgReset)"
    if ($script:GpuPresent) {
        $body += "$($script:FgMuted)GPU$($script:FgReset) $($script:GpuName)   $($script:FgMuted)VRAM$($script:FgReset) $($script:GpuVramMb) MB"
    } else {
        $body += "$($script:FgMuted)GPU$($script:FgReset) none"
    }
    if ($script:GpuPresent -and -not $script:GpuAvailable) {
        $body += "$($script:FgAmber)$($script:GpuReason)$($script:FgReset)"
    }

    Draw-Frame -Current 1 -Title 'Choose how Horizon AI runs' -Subtitle 'GPU is recommended when supported. CPU works everywhere.' -Footer "$($script:KeyUpDown) Move   Enter Select   B Back   Q Quit" -Body $body
}

function Show-Summary {
    $body = @()
    $body += Write-KvLine -Key 'Mode' -Value $script:Mode.ToUpperInvariant()
    $body += Write-KvLine -Key 'Backend' -Value $script:BackendImage
    $body += Write-KvLine -Key 'Frontend' -Value $script:FrontendImage
    $body += Write-KvLine -Key 'Ports' -Value '3000 (UI) · 8000 (API)'
    $body += Write-KvLine -Key 'Data' -Value "$($script:VolumeName) (persisted)"
    $body += Write-KvLine -Key 'Network' -Value $script:NetworkName
    $body += ''
    $body += "$($script:FgMuted)Internet is required for the first install. Images are pulled from GHCR.$($script:FgReset)"
    if (-not [string]::IsNullOrWhiteSpace($script:ExistingContainers)) {
        $body += "$($script:FgAmber)Existing containers will be recreated: $($script:ExistingContainers)$($script:FgReset)"
    }
    if ($script:ForceGpuWarning) {
        $body += "$($script:FgAmber)GPU mode is forced below the $($script:MinVramMb) MB recommendation.$($script:FgReset)"
    }
    $body += ''
    $body += Write-MenuLine -Label 'Install Horizon AI' -Selected ($script:MenuIndex -eq 0)
    $body += Write-MenuLine -Label 'Back' -Selected ($script:MenuIndex -eq 1)
    $body += Write-MenuLine -Label 'Cancel' -Selected ($script:MenuIndex -eq 2)
    Draw-Frame -Current 2 -Title 'Ready to install' -Subtitle '' -Footer "$($script:KeyUpDown) Move   Enter Select   Q Quit" -Body $body
}

function Show-Progress {
    $body = @()
    $doneCount = 0
    if ($script:StepPullBackend -eq 2) { $doneCount++ }
    if ($script:StepPullFrontend -eq 2) { $doneCount++ }
    if ($script:StepResources -eq 2) { $doneCount++ }
    if ($script:StepStart -eq 2) { $doneCount++ }
    if ($script:StepHealth -eq 2) { $doneCount++ }

    $pullBackendState = 'pending'
    $pullFrontendState = 'pending'
    $resourcesState = 'pending'
    $startState = 'pending'
    $healthState = 'pending'
    switch ($script:StepPullBackend) { 1 { $pullBackendState = 'active' } 2 { $pullBackendState = 'done' } 3 { $pullBackendState = 'fail' } }
    switch ($script:StepPullFrontend) { 1 { $pullFrontendState = 'active' } 2 { $pullFrontendState = 'done' } 3 { $pullFrontendState = 'fail' } }
    switch ($script:StepResources) { 1 { $resourcesState = 'active' } 2 { $resourcesState = 'done' } 3 { $resourcesState = 'fail' } }
    switch ($script:StepStart) { 1 { $startState = 'active' } 2 { $startState = 'done' } 3 { $startState = 'fail' } }
    switch ($script:StepHealth) { 1 { $healthState = 'active' } 2 { $healthState = 'done' } 3 { $healthState = 'fail' } }

    $barWidth = [Math]::Max(20, $script:Width - 6)
    $body += Write-ProgressBar -Done $doneCount -Total 5 -Width $barWidth
    $body += ''
    $body += Write-StepRow -State $pullBackendState -Label 'Pull backend image' -Detail ''
    $body += Write-StepRow -State $pullFrontendState -Label 'Pull frontend image' -Detail ''
    $body += Write-StepRow -State $resourcesState -Label 'Prepare Docker resources' -Detail ''
    $body += Write-StepRow -State $startState -Label 'Start containers' -Detail ''
    $body += Write-StepRow -State $healthState -Label 'Wait for Horizon AI' -Detail ''
    $body += ''

    $logWidth = [Math]::Max(30, $script:Width - 2)
    $body += "$($script:BgPanel)$($script:FgBorder)$($script:BoxTl)$(Repeat-Char $script:BoxH ($logWidth - 2))$($script:BoxTr)$($script:AllReset)"
    foreach ($line in @(Get-LogTail -Count 4)) {
        $body += "$($script:BgPanel)$($script:FgBorder)$($script:BoxV) $($script:FgMuted)$(Pad-Plain -Text $line -Width ($logWidth - 4))$($script:FgBorder) $($script:BoxV)$($script:AllReset)"
    }
    $body += "$($script:BgPanel)$($script:FgBorder)$($script:BoxBl)$(Repeat-Char $script:BoxH ($logWidth - 2))$($script:BoxBr)$($script:AllReset)"

    Draw-Frame -Current 2 -Title 'Installing Horizon AI' -Subtitle '' -Footer 'Pulling images and starting containers. This can take a few minutes.' -Body $body
}

function Show-Failure {
    $body = @()
    $body += "$($script:FgRed)$($script:InstallError)$($script:FgReset)"
    $body += "$($script:FgMuted)Failed step: $($script:FailedStep)$($script:FgReset)"
    $body += ''
    $logWidth = [Math]::Max(30, $script:Width - 2)
    $body += "$($script:BgPanel)$($script:FgBorder)$($script:BoxTl)$(Repeat-Char $script:BoxH ($logWidth - 2))$($script:BoxTr)$($script:AllReset)"
    foreach ($line in @(Get-LogTail -Count 8)) {
        $body += "$($script:BgPanel)$($script:FgBorder)$($script:BoxV) $($script:FgMuted)$(Pad-Plain -Text $line -Width ($logWidth - 4))$($script:FgBorder) $($script:BoxV)$($script:AllReset)"
    }
    $body += "$($script:BgPanel)$($script:FgBorder)$($script:BoxBl)$(Repeat-Char $script:BoxH ($logWidth - 2))$($script:BoxBr)$($script:AllReset)"
    $body += ''

    $body += Write-MenuLine -Label 'Retry' -Selected ($script:FailureIndex -eq 0)
    if ($script:Mode -eq 'gpu') {
        $body += Write-MenuLine -Label 'Switch to CPU' -Selected ($script:FailureIndex -eq 1)
        $body += Write-MenuLine -Label 'View logs' -Selected ($script:FailureIndex -eq 2)
        $body += Write-MenuLine -Label 'Quit' -Selected ($script:FailureIndex -eq 3)
    } else {
        $body += Write-MenuLine -Label 'View logs' -Selected ($script:FailureIndex -eq 1)
        $body += Write-MenuLine -Label 'Quit' -Selected ($script:FailureIndex -eq 2)
    }

    Draw-Frame -Current 2 -Title 'Installation failed' -Subtitle 'Containers and data were left in place for inspection.' -Footer "$($script:KeyUpDown) Move   Enter Select   Q Quit" -Body $body
}

function Show-Success {
    $body = @()
    $body += Write-KvLine -Key 'Open' -Value 'http://localhost:3000'
    $body += Write-KvLine -Key 'API' -Value 'http://localhost:8000'
    $body += Write-KvLine -Key 'Mode' -Value $script:Mode.ToUpperInvariant()
    if ($script:GpuPresent -and $script:Mode -eq 'gpu') {
        $body += Write-KvLine -Key 'GPU' -Value "$($script:GpuName) · $($script:GpuVramMb) MB VRAM"
    }
    $body += ''
    $commandWidth = [Math]::Max(30, $script:Width - 2)
    $logsCommand = "docker logs -f $($script:ContainerBackend) · docker logs -f $($script:ContainerFrontend)"
    $stopCommand = "docker stop $($script:ContainerFrontend) $($script:ContainerBackend)"
    $startCommand = "docker start $($script:ContainerBackend) $($script:ContainerFrontend)"
    $body += "$($script:FgMuted)Logs$($script:FgReset)"
    foreach ($line in @(Get-WrappedLines -Text $logsCommand -Width $commandWidth)) {
        $body += "$($script:FgText)$line$($script:FgReset)"
    }
    $body += "$($script:FgMuted)Stop$($script:FgReset)"
    foreach ($line in @(Get-WrappedLines -Text $stopCommand -Width $commandWidth)) {
        $body += "$($script:FgText)$line$($script:FgReset)"
    }
    $body += "$($script:FgMuted)Start$($script:FgReset)"
    foreach ($line in @(Get-WrappedLines -Text $startCommand -Width $commandWidth)) {
        $body += "$($script:FgText)$line$($script:FgReset)"
    }
    $body += ''
    $body += Write-MenuLine -Label 'Open Horizon AI' -Selected ($script:SuccessIndex -eq 0)
    $body += Write-MenuLine -Label 'View recent logs' -Selected ($script:SuccessIndex -eq 1)
    $body += Write-MenuLine -Label 'Exit' -Selected ($script:SuccessIndex -eq 2)
    Draw-Frame -Current 3 -Title 'Horizon AI is ready' -Subtitle 'Your local refactoring studio is running.' -Footer "$($script:KeyUpDown) Move   Enter Select   Q Quit" -Body $body
}

function Show-Help {
    $body = @()
    $body += "$($script:Bold)$($script:FgText)Docker$($script:FgReset)$($script:BoldOff)"
    foreach ($line in @(Get-WrappedLines -Text 'Install Docker Engine or Docker Desktop, start it, then press R on the system check screen.' -Width ($script:Width - 2))) {
        $body += $line
    }
    $body += ''
    $body += "$($script:Bold)$($script:FgText)GPU mode$($script:FgReset)$($script:BoldOff)"
    foreach ($line in @(Get-WrappedLines -Text "GPU mode needs an NVIDIA GPU with at least $($script:MinVramMb) MB VRAM and the NVIDIA Container Toolkit." -Width ($script:Width - 2))) {
        $body += $line
    }
    foreach ($line in @(Get-WrappedLines -Text 'On Windows, enable GPU support in Docker Desktop with the WSL2 backend.' -Width ($script:Width - 2))) {
        $body += $line
    }
    $body += ''
    $body += "$($script:Bold)$($script:FgText)CPU mode$($script:FgReset)$($script:BoldOff)"
    foreach ($line in @(Get-WrappedLines -Text 'CPU mode works on any machine and does not need an NVIDIA GPU.' -Width ($script:Width - 2))) {
        $body += $line
    }
    Draw-Frame -Current 0 -Title 'Setup help' -Subtitle '' -Footer 'B Back   Q Quit' -Body $body
}

function Show-Logs {
    $body = @()
    $body += "$($script:FgMuted)$($script:LogFile)$($script:FgReset)"
    $body += ''
    if (Test-Path $script:LogFile) {
        $maxWidth = [Math]::Max(20, $script:Width - 2)
        foreach ($line in @(Get-Content -Path $script:LogFile -Tail 18 -ErrorAction SilentlyContinue)) {
            $body += "$($script:FgText)$(Fit-Plain -Text $line -Max $maxWidth)$($script:FgReset)"
        }
    } else {
        $body += "$($script:FgMuted)No log output yet.$($script:FgReset)"
    }
    Draw-Frame -Current 2 -Title 'Recent logs' -Subtitle '' -Footer 'B Back   Q Quit' -Body $body
}

function Get-TuiKey {
    if ([Console]::IsInputRedirected) {
        return $null
    }
    $keyInfo = [Console]::ReadKey($true)
    switch ($keyInfo.Key) {
        'UpArrow' { return 'UP' }
        'DownArrow' { return 'DOWN' }
        'LeftArrow' { return 'LEFT' }
        'RightArrow' { return 'RIGHT' }
        'Enter' { return 'ENTER' }
        'Escape' { return 'ESC' }
        default { return $keyInfo.KeyChar.ToString().ToUpperInvariant() }
    }
}

function Wait-ForBack {
    while ($true) {
        $key = Get-TuiKey
        if ($null -eq $key) { return }
        if ($key -in @('B', 'Q', 'ENTER')) { return }
    }
}

function Invoke-TuiPreflight {
    while ($true) {
        Show-Preflight
        $key = Get-TuiKey
        if ($null -eq $key) { return 130 }
        switch ($key) {
            'R' { Invoke-Preflight }
            'D' { Show-Help; Wait-ForBack }
            'ENTER' {
                if ($script:DockerOk) { return 0 }
            }
            'Q' { return 130 }
        }
    }
}

function Invoke-TuiMode {
    $script:ModeIndex = if ($script:RecommendedMode -eq 'cpu') { 1 } else { 0 }
    while ($true) {
        Show-Mode
        $key = Get-TuiKey
        if ($null -eq $key) { return 130 }
        switch ($key) {
            'UP' {
                $script:ModeIndex--
                if ($script:ModeIndex -lt 0) { $script:ModeIndex = 1 }
            }
            'DOWN' {
                $script:ModeIndex++
                if ($script:ModeIndex -gt 1) { $script:ModeIndex = 0 }
            }
            'ENTER' {
                if ($script:ModeIndex -eq 1) {
                    $script:Mode = 'cpu'
                    return 0
                }
                if ($script:GpuAvailable) {
                    $script:Mode = 'gpu'
                    return 0
                }
                if ($script:GpuPresent -and $script:GpuRuntimeOk -and $script:ForceGpu) {
                    $script:Mode = 'gpu'
                    $script:ForceGpuWarning = $true
                    return 0
                }
            }
            'B' { return 10 }
            'Q' { return 130 }
        }
    }
}

function Invoke-TuiSummary {
    $script:MenuIndex = 0
    while ($true) {
        Show-Summary
        $key = Get-TuiKey
        if ($null -eq $key) { return 130 }
        switch ($key) {
            'UP' {
                $script:MenuIndex--
                if ($script:MenuIndex -lt 0) { $script:MenuIndex = 2 }
            }
            'DOWN' {
                $script:MenuIndex++
                if ($script:MenuIndex -gt 2) { $script:MenuIndex = 0 }
            }
            'ENTER' {
                if ($script:MenuIndex -eq 0) { return 0 }
                if ($script:MenuIndex -eq 1) { return 10 }
                return 130
            }
            'B' { return 10 }
            'Q' { return 130 }
        }
    }
}

function Invoke-TuiFailure {
    $count = if ($script:Mode -eq 'gpu') { 4 } else { 3 }
    $logsIndex = if ($script:Mode -eq 'gpu') { 2 } else { 1 }
    $quitIndex = $count - 1
    $script:FailureIndex = 0
    while ($true) {
        Show-Failure
        $key = Get-TuiKey
        if ($null -eq $key) { return 130 }
        switch ($key) {
            'UP' {
                $script:FailureIndex--
                if ($script:FailureIndex -lt 0) { $script:FailureIndex = $count - 1 }
            }
            'DOWN' {
                $script:FailureIndex++
                if ($script:FailureIndex -ge $count) { $script:FailureIndex = 0 }
            }
            'ENTER' {
                if ($script:FailureIndex -eq 0) { return 0 }
                if ($script:Mode -eq 'gpu' -and $script:FailureIndex -eq 1) { return 10 }
                if ($script:FailureIndex -eq $logsIndex) {
                    Show-Logs
                    Wait-ForBack
                }
                if ($script:FailureIndex -eq $quitIndex) { return 130 }
            }
            'Q' { return 130 }
        }
    }
}

function Invoke-TuiSuccess {
    $script:SuccessIndex = 0
    while ($true) {
        Show-Success
        $key = Get-TuiKey
        if ($null -eq $key) { return 0 }
        switch ($key) {
            'UP' {
                $script:SuccessIndex--
                if ($script:SuccessIndex -lt 0) { $script:SuccessIndex = 2 }
            }
            'DOWN' {
                $script:SuccessIndex++
                if ($script:SuccessIndex -gt 2) { $script:SuccessIndex = 0 }
            }
            'ENTER' {
                if ($script:SuccessIndex -eq 0) { Open-Browser }
                if ($script:SuccessIndex -eq 1) { Show-Logs; Wait-ForBack }
                if ($script:SuccessIndex -eq 2) { return 0 }
            }
            'Q' { return 0 }
        }
    }
}

function Invoke-TuiInstall {
    while ($true) {
        if (Invoke-Install) {
            Invoke-TuiSuccess
            return 0
        }
        $rc = Invoke-TuiFailure
        if ($rc -eq 0) { continue }
        if ($rc -eq 10) {
            $script:Mode = 'cpu'
            Prepare-State
            continue
        }
        return $rc
    }
}

function Main {
    Set-DefaultHome
    Set-TerminalCaps
    Get-TerminalSize
    Invoke-Preflight

    if ($script:DryRun -or $script:NoTui) {
        return Invoke-PlainMode
    }

    if (-not (Initialize-Tui)) {
        return Invoke-PlainMode
    }

    $exitCode = 0
    try {
        while ($true) {
            $rc = Invoke-TuiPreflight
            if ($rc -eq 130) { $exitCode = 0; break }

            if ($script:Mode -eq 'auto') {
                $rc = Invoke-TuiMode
                if ($rc -eq 130) { $exitCode = 0; break }
                if ($rc -eq 10) { continue }
            } else {
                $rc = Resolve-Mode
                if ($rc -ne 0) {
                    Restore-Tui
                    $exitCode = $rc
                    break
                }
            }

            Prepare-State

            if (-not $script:Yes) {
                $rc = Invoke-TuiSummary
                if ($rc -eq 130) { $exitCode = 0; break }
                if ($rc -eq 10) {
                    $script:Mode = 'auto'
                    continue
                }
            }

            $rc = Invoke-TuiInstall
            if ($rc -eq 130) { $exitCode = 0 } else { $exitCode = 0 }
            break
        }
    } finally {
        Restore-Tui
    }
    return $exitCode
}

if ($Help) {
    Write-Usage
    exit 0
}

$exitCode = Main
exit $exitCode



