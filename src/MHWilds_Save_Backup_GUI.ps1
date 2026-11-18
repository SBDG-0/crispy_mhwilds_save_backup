<#
Monster Hunter Wilds - Save Backup GUI

Designed to be convertible to an .exe with PS2EXE.
Recommended conversion command:
Invoke-PS2EXE .\MHWilds_Save_Backup_GUI.ps1 .\MHWilds_Save_Backup_GUI.exe -noConsole -title "MH Wilds Save Backup"

What it does:
- Lets you configure Steam path, backup path, Steam user ID, MO2 options, and backup cleanup.
- Can optionally start Mod Organizer 2.
- Watches for Monster Hunter Wilds to start and close.
- Creates a zip backup only if the save data changed.
- Stores configuration as JSON next to the script/exe when possible, otherwise in AppData.
- Optional auto-close after a successful backup check.
- Config/options area can be hidden for a compact monitor view.
- Reviewed layout, validation, and error handling for EXE use.
- Uses .NET ZipFile instead of Compress-Archive so PS2EXE builds do not depend on Microsoft.PowerShell.Archive.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression.FileSystem

$ErrorActionPreference = 'Stop'
$culture = [System.Globalization.CultureInfo]::InvariantCulture

$script:OptionTextColor = [System.Drawing.Color]::Gainsboro
$script:OptionTextDisabledColor = [System.Drawing.Color]::FromArgb(154,154,154) # about 30% darker than Gainsboro
$script:OptionInputBackColor = [System.Drawing.Color]::FromArgb(45,45,48)
$script:OptionButtonBackColor = [System.Drawing.Color]::FromArgb(63,63,70)

# Some GUI controls need STA. If launched as a .ps1 from a non-STA host, relaunch in STA.
try {
    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA' -and $PSCommandPath) {
        $pwsh = (Get-Process -Id $PID).Path
        Start-Process -FilePath $pwsh -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', ('"{0}"' -f $PSCommandPath))
        exit
    }
} catch { }

function Get-AppBasePath {
    if ($PSScriptRoot -and (Test-Path $PSScriptRoot)) {
        return $PSScriptRoot
    }

    $processPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    if ($processPath -and (Test-Path $processPath)) {
        return Split-Path -Parent $processPath
    }

    return Join-Path $env:APPDATA 'MHWildsSaveBackup'
}

$script:AppBasePath = Get-AppBasePath
$script:ConfigFilePath = Join-Path $script:AppBasePath 'MHWilds_Save_Backup_Config.json'
$script:ValidatedBackupSourcePath = $null
$script:IsMonitoring = $false
$script:GameWasStarted = $false
$script:LastMonitorLogState = 'Idle'
$script:LogEntries = New-Object System.Collections.Generic.List[object]
$script:LastSavedPathValues = @{}


function Copy-OrderedConfig {
    param([Parameter(Mandatory = $true)]$Source)

    $copy = [ordered]@{}
    foreach ($key in $Source.Keys) {
        $copy[$key] = $Source[$key]
    }
    return $copy
}

$DefaultConfig = [ordered]@{
    StartMO2               = $false
    UseMO2Arguments        = $false
    StartGameViaSteam      = $false
    MO2ExePath             = ''
    MO2Arguments           = ''
    SteamUserId            = ''
    GameId                 = '2246340'
    SteamInstallDir        = 'C:\Program Files (x86)\Steam'
    BackupDestinationPath  = (Join-Path $env:USERPROFILE 'Documents\MH Wilds - Save Backups')
    BackupScope            = 'remote'
    KeepNewestBackups      = 50
    GameProcessName        = 'MonsterHunterWilds'
    RequireGameWasStarted  = $true
    CheckIntervalSeconds   = 5
    AutoCloseWhenFinished   = $false
}

function Get-Config {
    if (Test-Path $script:ConfigFilePath) {
        try {
            $loaded = Get-Content $script:ConfigFilePath -Raw | ConvertFrom-Json
            $config = [ordered]@{}
            foreach ($key in $DefaultConfig.Keys) {
                if ($loaded.PSObject.Properties.Name -contains $key) {
                    $config[$key] = $loaded.$key
                } else {
                    $config[$key] = $DefaultConfig[$key]
                }
            }
            return $config
        } catch {
            return (Copy-OrderedConfig -Source $DefaultConfig)
        }
    }

    return (Copy-OrderedConfig -Source $DefaultConfig)
}

function Save-Config {
    param([Parameter(Mandatory = $true)]$Config)

    if (-not (Test-Path $script:AppBasePath)) {
        New-Item -Path $script:AppBasePath -ItemType Directory -Force | Out-Null
    }

    $Config | ConvertTo-Json -Depth 5 | Out-File -FilePath $script:ConfigFilePath -Encoding UTF8 -Force
}

function Get-LogColor {
    param([ValidateSet('Info','Ok','Warn','Error')][string]$Type = 'Info')

    switch ($Type) {
        'Ok'    { return [System.Drawing.Color]::FromArgb(80, 220, 120) }
        'Warn'  { return [System.Drawing.Color]::FromArgb(255, 210, 80) }
        'Error' { return [System.Drawing.Color]::FromArgb(255, 90, 90) }
        default { return [System.Drawing.Color]::Gainsboro }
    }
}

function Get-LogPrefix {
    param([ValidateSet('Info','Ok','Warn','Error')][string]$Type = 'Info')

    switch ($Type) {
        'Info'  { return '[INFO]' }
        'Ok'    { return '[OK]  ' }
        'Warn'  { return '[WARN]' }
        'Error' { return '[ERR] ' }
    }
}


function Set-ControlFlatColor {
    param(
        [Parameter(Mandatory = $true)]$Control,
        [Parameter(Mandatory = $true)][System.Drawing.Color]$BackColor,
        [System.Drawing.Color]$ForeColor = [System.Drawing.Color]::WhiteSmoke
    )

    $Control.BackColor = $BackColor
    $Control.ForeColor = $ForeColor
    if ($Control.FlatAppearance) {
        $Control.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(230,230,230)
        $Control.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(
            [Math]::Min(255, $BackColor.R + 18),
            [Math]::Min(255, $BackColor.G + 18),
            [Math]::Min(255, $BackColor.B + 18)
        )
        $Control.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(
            [Math]::Max(0, $BackColor.R - 18),
            [Math]::Max(0, $BackColor.G - 18),
            [Math]::Max(0, $BackColor.B - 18)
        )
        # Important for CheckBox controls using Appearance = Button: keep checked state neutral.
        $Control.FlatAppearance.CheckedBackColor = $BackColor
    }
}

function Set-MonitorButtonVisual {
    param([bool]$Running)

    if (-not $script:btnStartMonitor) { return }

    if ($Running) {
        $script:btnStartMonitor.Text = 'Stop monitor'
        Set-ControlFlatColor -Control $script:btnStartMonitor -BackColor ([System.Drawing.Color]::FromArgb(150, 45, 45))
    } else {
        $script:btnStartMonitor.Text = 'Start monitor'
        Set-ControlFlatColor -Control $script:btnStartMonitor -BackColor ([System.Drawing.Color]::FromArgb(42, 120, 75))
    }
}

function Set-AutoCloseCheckboxVisual {
    if (-not $script:chkAutoClose) { return }

    $script:chkAutoClose.Text = 'Auto close'
    $script:chkAutoClose.BackColor = [System.Drawing.Color]::FromArgb(30,30,30)
    $script:chkAutoClose.ForeColor = [System.Drawing.Color]::Gainsboro
}

function Set-Status {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [ValidateSet('Neutral','Ok','Warn','Danger','Error')][string]$State = 'Neutral'
    )

    if (-not $script:lblStatus) { return }

    $script:lblStatus.Text = "Status: $Text"

    switch ($State) {
        'Ok'      { $script:lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(90, 230, 130) }
        'Warn'    { $script:lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(255, 210, 80) }
        'Danger'  { $script:lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(255, 90, 90) }
        'Error'   { $script:lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(255, 90, 90) }
        default   { $script:lblStatus.ForeColor = [System.Drawing.Color]::Silver }
    }
}

function Close-WhenFinishedIfEnabled {
    param([Parameter(Mandatory = $true)]$Config)

    if ([bool]$Config.AutoCloseWhenFinished) {
        Add-Log 'Auto-close enabled. Closing tool.' 'Info'
        $script:form.Close()
    }
}

function Render-Log {
    if (-not $script:txtLog) { return }

    $script:txtLog.SuspendLayout()
    try {
        $script:txtLog.Clear()

        foreach ($entry in $script:LogEntries) {
            $line = '[{0}] {1} {2}' -f $entry.Time, (Get-LogPrefix -Type $entry.Type), $entry.Message
            $script:txtLog.SelectionStart = $script:txtLog.TextLength
            $script:txtLog.SelectionLength = 0
            $script:txtLog.SelectionColor = (Get-LogColor -Type $entry.Type)
            $script:txtLog.AppendText($line + [Environment]::NewLine)
        }

        $script:txtLog.SelectionStart = $script:txtLog.TextLength
        $script:txtLog.SelectionLength = 0
        $script:txtLog.SelectionColor = [System.Drawing.Color]::Gainsboro
        $script:txtLog.ScrollToCaret()
    } finally {
        $script:txtLog.ResumeLayout()
    }
}

function Add-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('Info','Ok','Warn','Error')][string]$Type = 'Info'
    )

    [void]$script:LogEntries.Add([pscustomobject]@{
        Time    = (Get-Date).ToString('HH:mm:ss')
        Type    = $Type
        Message = $Message
    })

    Render-Log
}

function Set-LastLogLine {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('Info','Ok','Warn','Error')][string]$Type = 'Info'
    )

    if ($script:LogEntries.Count -gt 0) {
        $lastIndex = $script:LogEntries.Count - 1
        $script:LogEntries[$lastIndex] = [pscustomobject]@{
            Time    = (Get-Date).ToString('HH:mm:ss')
            Type    = $Type
            Message = $Message
        }
    } else {
        [void]$script:LogEntries.Add([pscustomobject]@{
            Time    = (Get-Date).ToString('HH:mm:ss')
            Type    = $Type
            Message = $Message
        })
    }

    Render-Log
}

function Get-RunningProcess {
    param([Parameter(Mandatory = $true)][string]$Name)
    return Get-Process -Name $Name -ErrorAction SilentlyContinue
}

function Get-SaveRootPath {
    param([Parameter(Mandatory = $true)]$Config)

    $userdataPath = Join-Path $Config.SteamInstallDir 'userdata'

    if (-not (Test-Path $userdataPath)) {
        throw "Steam userdata folder not found: $userdataPath"
    }

    if (-not [string]::IsNullOrWhiteSpace($Config.SteamUserId)) {
        $manualRemote = Join-Path $userdataPath (Join-Path $Config.SteamUserId (Join-Path $Config.GameId 'remote'))
        if (-not (Test-Path $manualRemote)) {
            throw "Configured save folder not found: $manualRemote"
        }
        return $manualRemote
    }

    $candidates = Get-ChildItem -Path $userdataPath -Directory |
        ForEach-Object {
            $remotePath = Join-Path $_.FullName (Join-Path $Config.GameId 'remote')
            if (Test-Path $remotePath) {
                Get-Item $remotePath
            }
        } |
        Sort-Object LastWriteTime -Descending

    if (-not $candidates -or $candidates.Count -eq 0) {
        throw "No Monster Hunter Wilds save folder found under: $userdataPath"
    }

    if ($candidates.Count -gt 1) {
        Add-Log "Multiple Steam user folders with MH Wilds data found. Using newest: $($candidates[0].FullName)" 'Warn'
    }

    return $candidates[0].FullName
}

function Get-BackupSourcePath {
    param([Parameter(Mandatory = $true)]$Config)

    $remotePath = Get-SaveRootPath -Config $Config

    switch ($Config.BackupScope.ToLowerInvariant()) {
        'remote'     { return $remotePath }
        'win64_save' { return Join-Path $remotePath 'win64_save' }
        default      { throw "Invalid BackupScope '$($Config.BackupScope)'. Use 'remote' or 'win64_save'." }
    }
}

function Get-FolderContentHash {
    param([Parameter(Mandatory = $true)][string]$Path)

    $files = Get-ChildItem -Path $Path -File -Recurse | Sort-Object FullName

    if (-not $files -or $files.Count -eq 0) {
        throw "No files found to back up in: $Path"
    }

    $manifestLines = foreach ($file in $files) {
        $relativePath = $file.FullName.Substring($Path.Length).TrimStart('\')
        $fileHash = (Get-FileHash -Path $file.FullName -Algorithm SHA256).Hash
        "$relativePath|$($file.Length)|$fileHash"
    }

    $manifestText = $manifestLines -join "`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($manifestText)
    $stream = [System.IO.MemoryStream]::new($bytes)

    try {
        return (Get-FileHash -InputStream $stream -Algorithm SHA256).Hash
    } finally {
        $stream.Dispose()
    }
}

function Start-MO2IfConfigured {
    param([Parameter(Mandatory = $true)]$Config)

    if (-not [bool]$Config.StartMO2) {
        Add-Log 'MO2 start disabled. Skipping MO2 start.' 'Info'
        return
    }

    if ([string]::IsNullOrWhiteSpace($Config.MO2ExePath)) {
        Add-Log 'MO2 start is enabled, but no MO2 executable is set. Skipping MO2 start.' 'Warn'
        return
    }

    if (-not (Test-Path $Config.MO2ExePath)) {
        Add-Log "MO2 executable not found: $($Config.MO2ExePath). Continuing without starting MO2." 'Warn'
        return
    }

    Add-Log 'Starting Mod Organizer 2...' 'Info'

    $startProcessParams = @{
        FilePath         = $Config.MO2ExePath
        WorkingDirectory = (Split-Path $Config.MO2ExePath)
    }

    if ([bool]$Config.UseMO2Arguments -and -not [string]::IsNullOrWhiteSpace($Config.MO2Arguments)) {
        $startProcessParams.ArgumentList = $Config.MO2Arguments
        Add-Log 'MO2 arguments enabled.' 'Info'
    } elseif ([bool]$Config.UseMO2Arguments) {
        Add-Log 'MO2 arguments enabled, but argument field is empty.' 'Warn'
    }

    Start-Process @startProcessParams
}

function Start-GameViaSteamIfConfigured {
    param([Parameter(Mandatory = $true)]$Config)

    if (-not [bool]$Config.StartGameViaSteam) {
        Add-Log 'Steam game start disabled. Start the game however you want.' 'Info'
        return
    }

    if ([string]::IsNullOrWhiteSpace($Config.GameId)) {
        Add-Log 'Steam game start is enabled, but Game App ID is empty.' 'Warn'
        return
    }

    $steamUrl = "steam://rungameid/$($Config.GameId)"
    Add-Log "Starting Monster Hunter Wilds through Steam: $steamUrl" 'Info'
    Start-Process -FilePath $steamUrl
}

function Test-StartupRequirements {
    param([Parameter(Mandatory = $true)]$Config)

    Add-Log 'Checking startup requirements...' 'Info'

    if (-not (Test-Path $Config.SteamInstallDir)) {
        throw "Steam install folder not found: $($Config.SteamInstallDir)"
    }

    $userdataPath = Join-Path $Config.SteamInstallDir 'userdata'
    if (-not (Test-Path $userdataPath)) {
        throw "Steam userdata folder not found: $userdataPath"
    }

    $script:ValidatedBackupSourcePath = Get-BackupSourcePath -Config $Config

    if (-not (Test-Path $script:ValidatedBackupSourcePath)) {
        throw "Backup source folder not found: $script:ValidatedBackupSourcePath"
    }

    New-Item -Path $Config.BackupDestinationPath -ItemType Directory -Force | Out-Null

    Add-Log 'Steam folder found.' 'Ok'
    Add-Log "Backup source found: $script:ValidatedBackupSourcePath" 'Ok'
    Add-Log "Backup destination ready: $($Config.BackupDestinationPath)" 'Ok'
}


function New-ZipFromFolder {
    param(
        [Parameter(Mandatory = $true)][string]$SourceFolder,
        [Parameter(Mandatory = $true)][string]$DestinationZip
    )

    if (-not (Test-Path $SourceFolder)) {
        throw "Source folder not found: $SourceFolder"
    }

    if (Test-Path $DestinationZip) {
        Remove-Item -Path $DestinationZip -Force
    }

    # Do not use Compress-Archive here. In PS2EXE builds, the Microsoft.PowerShell.Archive
    # module can fail to load even though the command is detected. The .NET ZipFile API is
    # available through System.IO.Compression.FileSystem and works better in converted EXEs.
    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        $SourceFolder,
        $DestinationZip,
        [System.IO.Compression.CompressionLevel]::Optimal,
        $false
    )
}

function Backup-MHWildsSave {
    param([Parameter(Mandatory = $true)]$Config)

    Add-Log 'Preparing save backup...' 'Info'

    if (Get-RunningProcess -Name $Config.GameProcessName) {
        throw 'Monster Hunter Wilds is still running. Backup cancelled to avoid copying a save mid-write.'
    }

    $saveFolder = $script:ValidatedBackupSourcePath
    if ([string]::IsNullOrWhiteSpace($saveFolder)) {
        $saveFolder = Get-BackupSourcePath -Config $Config
    }

    if (-not (Test-Path $saveFolder)) {
        throw "Save folder not found: $saveFolder"
    }

    New-Item -Path $Config.BackupDestinationPath -ItemType Directory -Force | Out-Null

    $hashFilePath = Join-Path $Config.BackupDestinationPath 'Last save hash.txt'
    $oldHash = ''

    if (Test-Path $hashFilePath) {
        $oldHash = (Get-Content $hashFilePath -Raw).Trim()
    }

    Add-Log "Save folder: $saveFolder" 'Info'
    Add-Log "Backup folder: $($Config.BackupDestinationPath)" 'Info'
    Add-Log 'Calculating save-data hash...' 'Info'

    $newHash = Get-FolderContentHash -Path $saveFolder

    if ($oldHash -eq $newHash) {
        Add-Log 'No changes detected. Latest save is already backed up.' 'Ok'
        return
    }

    $timestamp = (Get-Date).ToLocalTime().ToString('yyyy-MM-dd_HH-mm-ss', $culture)
    $backupFileName = "MH Wilds Save Backup - $timestamp.zip"
    $backupFilePath = Join-Path $Config.BackupDestinationPath $backupFileName

    Add-Log 'Changes detected. Creating backup...' 'Info'

    New-ZipFromFolder -SourceFolder $saveFolder -DestinationZip $backupFilePath

    $newHash | Out-File -FilePath $hashFilePath -Encoding UTF8 -Force

    Add-Log "Backup created: $backupFilePath" 'Ok'
    Add-Log "New save hash: $newHash" 'Ok'

    if ([int]$Config.KeepNewestBackups -gt 0) {
        $backups = Get-ChildItem -Path $Config.BackupDestinationPath -Filter 'MH Wilds Save Backup - *.zip' -File |
            Sort-Object LastWriteTime -Descending

        $oldBackups = $backups | Select-Object -Skip ([int]$Config.KeepNewestBackups)

        foreach ($backup in $oldBackups) {
            Remove-Item -Path $backup.FullName -Force
            Add-Log "Removed old backup: $($backup.Name)" 'Info'
        }
    }
}


function Clamp-DecimalValue {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)]$Minimum,
        [Parameter(Mandatory = $true)]$Maximum
    )

    $decimalValue = [decimal]$Value
    if ($decimalValue -lt $Minimum) { return [decimal]$Minimum }
    if ($decimalValue -gt $Maximum) { return [decimal]$Maximum }
    return $decimalValue
}

function Assert-UiConfig {
    param([Parameter(Mandatory = $true)]$Config)

    if ([string]::IsNullOrWhiteSpace($Config.SteamInstallDir)) {
        throw 'Steam install folder is empty.'
    }

    if ([string]::IsNullOrWhiteSpace($Config.BackupDestinationPath)) {
        throw 'Backup destination is empty.'
    }

    if ([string]::IsNullOrWhiteSpace($Config.GameId)) {
        throw 'Game App ID is empty.'
    }

    if ([string]::IsNullOrWhiteSpace($Config.GameProcessName)) {
        throw 'Game process name is empty.'
    }

    if ($Config.BackupScope -notin @('remote', 'win64_save')) {
        throw "Invalid backup scope: $($Config.BackupScope)"
    }
}

function Get-UiConfig {
    $config = [ordered]@{
        StartMO2               = [bool]$script:chkStartMO2.Checked
        UseMO2Arguments        = ([bool]$script:chkStartMO2.Checked -and [bool]$script:chkUseMO2Arguments.Checked)
        StartGameViaSteam      = [bool]$script:chkStartGameViaSteam.Checked
        MO2ExePath             = $script:txtMO2Path.Text.Trim()
        MO2Arguments           = $script:txtMO2Arguments.Text.Trim()
        SteamUserId            = $script:txtSteamUserId.Text.Trim()
        GameId                 = $DefaultConfig['GameId']
        SteamInstallDir        = $script:txtSteamPath.Text.Trim()
        BackupDestinationPath  = $script:txtBackupPath.Text.Trim()
        BackupScope            = $DefaultConfig['BackupScope']
        KeepNewestBackups      = [int]$script:numKeepNewest.Value
        GameProcessName        = $DefaultConfig['GameProcessName']
        RequireGameWasStarted  = [bool]$script:chkRequireStarted.Checked
        CheckIntervalSeconds   = [int]$script:numCheckInterval.Value
        AutoCloseWhenFinished  = [bool]$script:chkAutoClose.Checked
    }

    Assert-UiConfig -Config $config
    return $config
}



function Get-NormalizedConfigText {
    param($Value)

    if ($null -eq $Value) { return '' }
    return ([string]$Value).Trim()
}

function Update-SavedPathSnapshotFromConfig {
    param([Parameter(Mandatory = $true)]$Config)

    $script:LastSavedPathValues['SteamInstallDir'] = Get-NormalizedConfigText $Config.SteamInstallDir
    $script:LastSavedPathValues['BackupDestinationPath'] = Get-NormalizedConfigText $Config.BackupDestinationPath
    $script:LastSavedPathValues['MO2ExePath'] = Get-NormalizedConfigText $Config.MO2ExePath
}

function Test-PathFieldChanged {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigKey,
        [Parameter(Mandatory = $true)]$TextBox
    )

    $currentValue = Get-NormalizedConfigText $TextBox.Text
    $lastSavedValue = ''
    if ($script:LastSavedPathValues.ContainsKey($ConfigKey)) {
        $lastSavedValue = Get-NormalizedConfigText $script:LastSavedPathValues[$ConfigKey]
    }

    return (-not [string]::Equals($currentValue, $lastSavedValue, [System.StringComparison]::OrdinalIgnoreCase))
}

function Save-PathFieldIfChanged {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigKey,
        [Parameter(Mandatory = $true)]$TextBox,
        [Parameter(Mandatory = $true)][string]$Reason
    )

    if (-not (Test-PathFieldChanged -ConfigKey $ConfigKey -TextBox $TextBox)) {
        return $false
    }

    return (Save-UiConfigQuietly -Reason $Reason)
}

function Save-UiConfigQuietly {
    param([string]$Reason = 'Config auto-saved')

    try {
        $config = Get-UiConfig
        Save-Config -Config $config
        Update-SavedPathSnapshotFromConfig -Config $config
        Set-Status 'config saved' 'Ok'
        Add-Log $Reason 'Ok'
        return $true
    } catch {
        Set-Status 'config error' 'Error'
        Add-Log "Auto-save failed: $($_.Exception.Message)" 'Error'
        return $false
    }
}

function Set-UiConfig {
    param([Parameter(Mandatory = $true)]$Config)

    $script:chkStartMO2.Checked = [bool]$Config.StartMO2
    $script:chkUseMO2Arguments.Checked = [bool]$Config.UseMO2Arguments
    $script:chkStartGameViaSteam.Checked = [bool]$Config.StartGameViaSteam
    $script:txtMO2Path.Text = [string]$Config.MO2ExePath
    $script:txtMO2Arguments.Text = [string]$Config.MO2Arguments
    $script:txtSteamUserId.Text = [string]$Config.SteamUserId
    $script:txtSteamPath.Text = [string]$Config.SteamInstallDir
    $script:txtBackupPath.Text = [string]$Config.BackupDestinationPath

    $script:numKeepNewest.Value = Clamp-DecimalValue -Value $Config.KeepNewestBackups -Minimum $script:numKeepNewest.Minimum -Maximum $script:numKeepNewest.Maximum
    $script:chkRequireStarted.Checked = [bool]$Config.RequireGameWasStarted
    $script:numCheckInterval.Value = Clamp-DecimalValue -Value $Config.CheckIntervalSeconds -Minimum $script:numCheckInterval.Minimum -Maximum $script:numCheckInterval.Maximum
    $script:chkAutoClose.Checked = [bool]$Config.AutoCloseWhenFinished
}

function Select-Folder {
    param([string]$InitialPath)

    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.ShowNewFolderButton = $true
    if (-not [string]::IsNullOrWhiteSpace($InitialPath) -and (Test-Path $InitialPath)) {
        $dialog.SelectedPath = $InitialPath
    }

    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $dialog.SelectedPath
    }

    return $null
}

function Select-ExeFile {
    param([string]$InitialPath)

    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = 'Executable files (*.exe)|*.exe|All files (*.*)|*.*'
    if (-not [string]::IsNullOrWhiteSpace($InitialPath) -and (Test-Path $InitialPath)) {
        $dialog.InitialDirectory = Split-Path -Parent $InitialPath
        $dialog.FileName = Split-Path -Leaf $InitialPath
    }

    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $dialog.FileName
    }

    return $null
}

function New-Label {
    param([string]$Text, [int]$X, [int]$Y, [int]$W = 150)
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point($X, $Y)
    $label.Size = New-Object System.Drawing.Size($W, 22)
    $label.ForeColor = $script:OptionTextColor
    return $label
}

function New-TextBox {
    param([int]$X, [int]$Y, [int]$W = 480)
    $box = New-Object System.Windows.Forms.TextBox
    $box.Location = New-Object System.Drawing.Point($X, $Y)
    $box.Size = New-Object System.Drawing.Size($W, 24)
    $box.BackColor = $script:OptionInputBackColor
    $box.ForeColor = [System.Drawing.Color]::WhiteSmoke
    $box.BorderStyle = 'FixedSingle'
    return $box
}


function New-Button {
    param([string]$Text, [int]$X, [int]$Y, [int]$W = 120, [int]$H = 30)
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Location = New-Object System.Drawing.Point($X, $Y)
    $button.Size = New-Object System.Drawing.Size($W, $H)
    $button.FlatStyle = 'Flat'
    $button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(230,230,230)
    $button.BackColor = $script:OptionButtonBackColor
    $button.ForeColor = [System.Drawing.Color]::WhiteSmoke
    return $button
}

function New-OptionCheckBox {
    param([string]$Text, [int]$X, [int]$Y, [int]$W = 180)

    $checkBox = New-Object System.Windows.Forms.CheckBox
    $checkBox.Text = $Text
    $checkBox.Location = New-Object System.Drawing.Point($X, $Y)
    $checkBox.Size = New-Object System.Drawing.Size($W, 24)
    $checkBox.ForeColor = $script:OptionTextColor
    $checkBox.BackColor = [System.Drawing.Color]::FromArgb(30,30,30)
    return $checkBox
}

function Set-OptionControlActiveVisual {
    param(
        [Parameter(Mandatory = $true)]$Control,
        [Parameter(Mandatory = $true)][bool]$Active,
        [ValidateSet('Text','Input','Button','CheckBox')][string]$Kind = 'Text'
    )

    $fore = if ($Active) { $script:OptionTextColor } else { $script:OptionTextDisabledColor }

    switch ($Kind) {
        'Input' {
            $Control.ReadOnly = -not $Active
            $Control.BackColor = $script:OptionInputBackColor
            $Control.ForeColor = if ($Active) { [System.Drawing.Color]::WhiteSmoke } else { $script:OptionTextDisabledColor }
        }
        'Button' {
            # Keep the button enabled so WinForms does not apply its inconsistent disabled colors.
            # Click handlers ignore clicks while inactive.
            $Control.Enabled = $true
            Set-ControlFlatColor -Control $Control -BackColor $script:OptionButtonBackColor -ForeColor $fore
        }
        'CheckBox' {
            # Keep the checkbox enabled so text color stays under our control.
            # AutoCheck prevents toggling while unavailable.
            $Control.AutoCheck = $Active
            $Control.ForeColor = $fore
            $Control.BackColor = [System.Drawing.Color]::FromArgb(30,30,30)
        }
        default {
            $Control.ForeColor = $fore
        }
    }
}

function Set-OptionCheckboxVisual {
    param(
        [Parameter(Mandatory = $true)]$Control,
        [Parameter(Mandatory = $true)][bool]$Checked,
        [bool]$CanToggle = $true
    )

    # Keep checkboxes technically enabled so WinForms does not apply its native disabled styling.
    # Use AutoCheck to block unavailable dependent options, and ForeColor for our own muted state.
    $Control.Enabled = $true
    $Control.AutoCheck = $CanToggle
    $Control.BackColor = [System.Drawing.Color]::FromArgb(30,30,30)
    $Control.ForeColor = if ($Checked) { $script:OptionTextColor } else { $script:OptionTextDisabledColor }
}

function Update-OptionEnabledStates {
    $startMo2 = ($script:chkStartMO2 -and [bool]$script:chkStartMO2.Checked)
    $useMo2Args = ($startMo2 -and $script:chkUseMO2Arguments -and [bool]$script:chkUseMO2Arguments.Checked)
    $startGameViaSteam = ($script:chkStartGameViaSteam -and [bool]$script:chkStartGameViaSteam.Checked)

    if (-not $startMo2 -and $script:chkUseMO2Arguments) {
        $script:chkUseMO2Arguments.Checked = $false
        $useMo2Args = $false
    }

    if ($script:chkStartMO2) {
        Set-OptionCheckboxVisual -Control $script:chkStartMO2 -Checked $startMo2 -CanToggle $true
    }
    if ($script:chkUseMO2Arguments) {
        Set-OptionCheckboxVisual -Control $script:chkUseMO2Arguments -Checked $useMo2Args -CanToggle $startMo2
    }
    if ($script:chkStartGameViaSteam) {
        Set-OptionCheckboxVisual -Control $script:chkStartGameViaSteam -Checked $startGameViaSteam -CanToggle $true
    }
    if ($script:txtMO2Path) {
        Set-OptionControlActiveVisual -Control $script:txtMO2Path -Active $startMo2 -Kind 'Input'
    }
    if ($script:btnBrowseMO2) {
        Set-OptionControlActiveVisual -Control $script:btnBrowseMO2 -Active $startMo2 -Kind 'Button'
    }
    if ($script:txtMO2Arguments) {
        Set-OptionControlActiveVisual -Control $script:txtMO2Arguments -Active $useMo2Args -Kind 'Input'
    }
    if ($script:lblMO2ArgsOptional) {
        Set-OptionControlActiveVisual -Control $script:lblMO2ArgsOptional -Active $useMo2Args -Kind 'Text'
    }
}


function Update-LogLayout {
    if (-not $script:txtLog -or -not $script:form) { return }

    $bottomPadding = 20
    $newHeight = [Math]::Max(90, $script:form.ClientSize.Height - $script:txtLog.Location.Y - $bottomPadding)
    $script:txtLog.Size = New-Object System.Drawing.Size(($script:form.ClientSize.Width - 40), $newHeight)
}

function Set-OptionsVisible {
    param([Parameter(Mandatory = $true)][bool]$Visible)

    $script:OptionsVisible = $Visible

    if ($script:OptionControls) {
        foreach ($control in $script:OptionControls) {
            $control.Visible = $Visible
        }
    }

    $targetY = if ($Visible) { $script:ButtonsExpandedY } else { $script:ButtonsCollapsedY }
    $delta = $targetY - $script:ButtonsExpandedY

    foreach ($control in $script:MovableBottomControls) {
        $key = [string]$control.GetHashCode()
        if ($script:OriginalControlLocations.ContainsKey($key)) {
            $original = $script:OriginalControlLocations[$key]
            # Only restore the vertical compact/expanded position here.
            # Do NOT restore X: right-anchored controls may have moved because the window was resized.
            # Resetting X caused buttons/checkboxes to overlap after Hide/Show options.
            $control.Location = New-Object System.Drawing.Point($control.Location.X, ($original.Y + $delta))
        }
    }

    if ($script:btnToggleOptions) {
        $script:btnToggleOptions.Text = if ($Visible) { 'Hide options' } else { 'Show options' }
    }

    if ($script:form -and $script:ExpandedClientHeight -and $script:CollapsedClientHeight) {
        $targetHeight = if ($Visible) { $script:ExpandedClientHeight } else { $script:CollapsedClientHeight }
        if ($script:form.ClientSize.Height -ne $targetHeight) {
            $script:form.ClientSize = New-Object System.Drawing.Size($script:form.ClientSize.Width, $targetHeight)
        }
    }

    if ($script:form) { $script:form.PerformLayout() }
    Update-LogLayout
}


function Set-ApplicationWindowIcon {
    param([Parameter(Mandatory = $true)][System.Windows.Forms.Form]$Form)

    try {
        # After PS2EXE conversion, this points to your compiled exe.
        # Extracting the associated icon here makes the titlebar/taskbar use the same icon
        # that was embedded with PS2EXE -iconFile.
        $processPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $processName = [System.IO.Path]::GetFileNameWithoutExtension($processPath)

        if ($processPath -and (Test-Path $processPath) -and $processName -notin @('pwsh', 'powershell', 'powershell_ise')) {
            $embeddedIcon = [System.Drawing.Icon]::ExtractAssociatedIcon($processPath)
            if ($embeddedIcon) {
                $Form.Icon = $embeddedIcon
                $Form.ShowIcon = $true
                return
            }
        }
    } catch { }

    try {
        # Fallback for running the .ps1 directly during development.
        # Put one of these .ico files next to the script if you want the window icon while testing.
        $fallbackIconNames = @(
            'MHWilds.ico',
            'MHWilds_Save_Backup.ico',
            'icon.ico',
            'app.ico'
        )

        foreach ($iconName in $fallbackIconNames) {
            $iconPath = Join-Path $script:AppBasePath $iconName
            if (Test-Path $iconPath) {
                $Form.Icon = New-Object System.Drawing.Icon($iconPath)
                $Form.ShowIcon = $true
                return
            }
        }
    } catch { }
}

# =========================
# UI
# =========================

$form = New-Object System.Windows.Forms.Form
$script:form = $form
$form.Text = 'Monster Hunter Wilds - Save Backup'
$form.StartPosition = 'CenterScreen'
$script:ExpandedClientHeight = 615
$script:CollapsedClientHeight = 360
$form.ClientSize = New-Object System.Drawing.Size(800, $script:CollapsedClientHeight)
$form.MinimumSize = New-Object System.Drawing.Size(820, 400)
$form.BackColor = [System.Drawing.Color]::FromArgb(30,30,30)
$form.ForeColor = [System.Drawing.Color]::WhiteSmoke
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
Set-ApplicationWindowIcon -Form $form

$title = New-Object System.Windows.Forms.Label
$title.Text = 'Monster Hunter Wilds - Save Backup'
$title.Location = New-Object System.Drawing.Point(18, 14)
$title.Size = New-Object System.Drawing.Size(500, 32)
$title.Font = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
$title.ForeColor = [System.Drawing.Color]::White
$form.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = 'Configure paths, optionally start MO2, then back up after the game closes.'
$subtitle.Location = New-Object System.Drawing.Point(20, 45)
$subtitle.Size = New-Object System.Drawing.Size(620, 24)
$subtitle.ForeColor = [System.Drawing.Color]::Silver
$form.Controls.Add($subtitle)

$script:btnToggleOptions = New-Button 'Hide options' 660 18 120 30
$script:btnToggleOptions.Anchor = 'Top, Right'
$form.Controls.Add($script:btnToggleOptions)
Set-ControlFlatColor -Control $script:btnToggleOptions -BackColor ([System.Drawing.Color]::FromArgb(70,70,78))

$y = 82
$form.Controls.Add((New-Label 'Steam install folder' 20 $y))
$script:txtSteamPath = New-TextBox 180 $y 490
$script:txtSteamPath.Anchor = 'Top, Left, Right'
$form.Controls.Add($script:txtSteamPath)
$btnBrowseSteam = New-Button 'Browse...' 690 ($y - 2) 90 28
$btnBrowseSteam.Anchor = 'Top, Right'
$form.Controls.Add($btnBrowseSteam)

$y += 36
$form.Controls.Add((New-Label 'Backup destination' 20 $y))
$script:txtBackupPath = New-TextBox 180 $y 490
$script:txtBackupPath.Anchor = 'Top, Left, Right'
$form.Controls.Add($script:txtBackupPath)
$btnBrowseBackup = New-Button 'Browse...' 690 ($y - 2) 90 28
$btnBrowseBackup.Anchor = 'Top, Right'
$form.Controls.Add($btnBrowseBackup)

$y += 36
$form.Controls.Add((New-Label 'Keep newest backups' 20 $y 135))
$script:numKeepNewest = New-Object System.Windows.Forms.NumericUpDown
$script:numKeepNewest.Location = New-Object System.Drawing.Point(180, $y)
$script:numKeepNewest.Size = New-Object System.Drawing.Size(80, 24)
$script:numKeepNewest.Minimum = 0
$script:numKeepNewest.Maximum = 9999
$script:numKeepNewest.BackColor = [System.Drawing.Color]::FromArgb(45,45,48)
$script:numKeepNewest.ForeColor = [System.Drawing.Color]::WhiteSmoke
$form.Controls.Add($script:numKeepNewest)

$form.Controls.Add((New-Label 'Steam user ID' 390 $y 95))
$script:txtSteamUserId = New-TextBox 500 $y 140
$form.Controls.Add($script:txtSteamUserId)
$form.Controls.Add((New-Label 'empty=auto' 650 $y 90))

$y += 36
$form.Controls.Add((New-Label 'Check interval sec.' 20 $y 125))
$script:numCheckInterval = New-Object System.Windows.Forms.NumericUpDown
$script:numCheckInterval.Location = New-Object System.Drawing.Point(180, $y)
$script:numCheckInterval.Size = New-Object System.Drawing.Size(80, 24)
$script:numCheckInterval.Minimum = 1
$script:numCheckInterval.Maximum = 120
$script:numCheckInterval.BackColor = [System.Drawing.Color]::FromArgb(45,45,48)
$script:numCheckInterval.ForeColor = [System.Drawing.Color]::WhiteSmoke
$form.Controls.Add($script:numCheckInterval)

$script:chkRequireStarted = New-Object System.Windows.Forms.CheckBox
$script:chkRequireStarted.Text = 'Require game start first'
$script:chkRequireStarted.Location = New-Object System.Drawing.Point(390, $y)
$script:chkRequireStarted.Size = New-Object System.Drawing.Size(220, 24)
$script:chkRequireStarted.ForeColor = [System.Drawing.Color]::Gainsboro
$script:chkRequireStarted.BackColor = [System.Drawing.Color]::FromArgb(30,30,30)
$form.Controls.Add($script:chkRequireStarted)

$y += 52
$separator1 = New-Object System.Windows.Forms.Label
$separator1.BorderStyle = 'Fixed3D'
$separator1.Location = New-Object System.Drawing.Point(20, $y)
$separator1.Size = New-Object System.Drawing.Size(760, 2)
$separator1.Anchor = 'Top, Left, Right'
$form.Controls.Add($separator1)
$y += 18

$script:chkStartMO2 = New-OptionCheckBox 'Start MO2' 20 $y 150
$form.Controls.Add($script:chkStartMO2)
$script:txtMO2Path = New-TextBox 180 $y 490
$script:txtMO2Path.Anchor = 'Top, Left, Right'
$form.Controls.Add($script:txtMO2Path)
$script:btnBrowseMO2 = New-Button 'Browse...' 690 ($y - 2) 90 28
$script:btnBrowseMO2.Anchor = 'Top, Right'
$form.Controls.Add($script:btnBrowseMO2)

$y += 36
$script:chkUseMO2Arguments = New-OptionCheckBox 'Use MO2 arguments' 20 $y 150
$form.Controls.Add($script:chkUseMO2Arguments)
$script:txtMO2Arguments = New-TextBox 180 $y 490
$script:txtMO2Arguments.Anchor = 'Top, Left, Right'
$form.Controls.Add($script:txtMO2Arguments)
$script:lblMO2ArgsOptional = New-Label 'optional' 690 $y 90
$script:lblMO2ArgsOptional.Anchor = 'Top, Right'
$form.Controls.Add($script:lblMO2ArgsOptional)

$y += 36
$script:chkStartGameViaSteam = New-OptionCheckBox 'Start Monster Hunter Wilds through Steam' 20 $y 330
$form.Controls.Add($script:chkStartGameViaSteam)

$y += 80
$btnSaveConfig = New-Button 'Save config' 20 $y 130 34
$form.Controls.Add($btnSaveConfig)
$btnTestPaths = New-Button 'Test paths' 160 $y 130 34
$form.Controls.Add($btnTestPaths)
$btnOpenBackup = New-Button 'Open backup folder' 300 $y 150 34
$form.Controls.Add($btnOpenBackup)
$btnManualBackup = New-Button 'Manual backup now' 480 $y 150 34
$btnManualBackup.Anchor = 'Top, Right'
$form.Controls.Add($btnManualBackup)
$script:btnStartMonitor = New-Button 'Start monitor' 640 $y 140 34
$script:btnStartMonitor.Anchor = 'Top, Right'
$form.Controls.Add($script:btnStartMonitor)

Set-ControlFlatColor -Control $btnSaveConfig -BackColor ([System.Drawing.Color]::FromArgb(70,70,78))
Set-ControlFlatColor -Control $btnTestPaths -BackColor ([System.Drawing.Color]::FromArgb(70,70,78))
Set-MonitorButtonVisual -Running $false
Set-ControlFlatColor -Control $btnManualBackup -BackColor ([System.Drawing.Color]::FromArgb(50, 95, 145))
Set-ControlFlatColor -Control $btnOpenBackup -BackColor ([System.Drawing.Color]::FromArgb(70,70,78))
Set-AutoCloseCheckboxVisual

$script:lblStatus = New-Object System.Windows.Forms.Label
Set-Status 'idle' 'Neutral'
$script:lblStatus.Location = New-Object System.Drawing.Point(20, ($y + 44))
$script:lblStatus.Size = New-Object System.Drawing.Size(600, 24)
$script:lblStatus.ForeColor = [System.Drawing.Color]::Silver
$form.Controls.Add($script:lblStatus)

$script:chkAutoClose = New-Object System.Windows.Forms.CheckBox
$script:chkAutoClose.Text = 'Auto close'
$script:chkAutoClose.Location = New-Object System.Drawing.Point(640, ($y + 43))
$script:chkAutoClose.Size = New-Object System.Drawing.Size(140, 24)
$script:chkAutoClose.Anchor = 'Top, Right'
$script:chkAutoClose.ForeColor = [System.Drawing.Color]::Gainsboro
$script:chkAutoClose.BackColor = [System.Drawing.Color]::FromArgb(30,30,30)
$form.Controls.Add($script:chkAutoClose)
Set-AutoCloseCheckboxVisual

$script:txtLog = New-Object System.Windows.Forms.RichTextBox
$script:txtLog.Location = New-Object System.Drawing.Point(20, ($y + 76))
$script:txtLog.Size = New-Object System.Drawing.Size(760, 170)
$script:txtLog.ScrollBars = 'Vertical'
$script:txtLog.DetectUrls = $false
$script:txtLog.ReadOnly = $true
$script:txtLog.BackColor = [System.Drawing.Color]::FromArgb(20,20,20)
$script:txtLog.ForeColor = [System.Drawing.Color]::Gainsboro
$script:txtLog.BorderStyle = 'FixedSingle'
$script:txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
$script:txtLog.Anchor = 'Top, Bottom, Left, Right'
$form.Controls.Add($script:txtLog)

# Controls in this Y range are the configurable options above the action buttons.
# The title/subtitle and the action buttons stay visible.
$script:ButtonsExpandedY = $btnSaveConfig.Location.Y
$script:ButtonsCollapsedY = 82
$script:OptionsVisible = $true
$script:OptionControls = @(
    $form.Controls | Where-Object {
        $_ -ne $script:btnToggleOptions -and
        $_.Location.Y -ge 78 -and
        $_.Location.Y -lt $script:ButtonsExpandedY
    }
)

$script:MovableBottomControls = @(
    $btnSaveConfig,
    $btnTestPaths,
    $btnOpenBackup,
    $btnManualBackup,
    $script:btnStartMonitor,
    $script:lblStatus,
    $script:chkAutoClose,
    $script:txtLog
)

$script:OriginalControlLocations = @{}
foreach ($control in $script:MovableBottomControls) {
    $script:OriginalControlLocations[[string]$control.GetHashCode()] = $control.Location
}

$form.Add_Resize({ Update-LogLayout })

# Start in compact mode by default.
Set-OptionsVisible -Visible $false

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 5000

$script:btnToggleOptions.Add_Click({
    Set-OptionsVisible -Visible (-not $script:OptionsVisible)
})

$btnBrowseSteam.Add_Click({
    $selected = Select-Folder -InitialPath $script:txtSteamPath.Text
    if ($selected) {
        $script:txtSteamPath.Text = $selected
        Save-PathFieldIfChanged -ConfigKey 'SteamInstallDir' -TextBox $script:txtSteamPath -Reason 'Steam path changed and config saved.' | Out-Null
    }
})

$btnBrowseBackup.Add_Click({
    $selected = Select-Folder -InitialPath $script:txtBackupPath.Text
    if ($selected) {
        $script:txtBackupPath.Text = $selected
        Save-PathFieldIfChanged -ConfigKey 'BackupDestinationPath' -TextBox $script:txtBackupPath -Reason 'Backup path changed and config saved.' | Out-Null
    }
})

$script:btnBrowseMO2.Add_Click({
    if (-not [bool]$script:chkStartMO2.Checked) { return }
    $selected = Select-ExeFile -InitialPath $script:txtMO2Path.Text
    if ($selected) {
        $script:txtMO2Path.Text = $selected
        Save-PathFieldIfChanged -ConfigKey 'MO2ExePath' -TextBox $script:txtMO2Path -Reason 'MO2 executable path changed and config saved.' | Out-Null
    }
})

$script:chkStartMO2.Add_CheckedChanged({ Update-OptionEnabledStates })
$script:chkUseMO2Arguments.Add_CheckedChanged({ Update-OptionEnabledStates })
$script:chkStartGameViaSteam.Add_CheckedChanged({ Update-OptionEnabledStates })

$script:txtSteamPath.Add_Leave({
    Save-PathFieldIfChanged -ConfigKey 'SteamInstallDir' -TextBox $script:txtSteamPath -Reason 'Steam path changed and config saved.' | Out-Null
})

$script:txtBackupPath.Add_Leave({
    Save-PathFieldIfChanged -ConfigKey 'BackupDestinationPath' -TextBox $script:txtBackupPath -Reason 'Backup path changed and config saved.' | Out-Null
})

$script:txtMO2Path.Add_Leave({
    Save-PathFieldIfChanged -ConfigKey 'MO2ExePath' -TextBox $script:txtMO2Path -Reason 'MO2 executable path changed and config saved.' | Out-Null
})

$script:chkAutoClose.Add_CheckedChanged({
    Set-AutoCloseCheckboxVisual
})

$btnSaveConfig.Add_Click({
    try {
        $config = Get-UiConfig
        Save-Config -Config $config
        Update-SavedPathSnapshotFromConfig -Config $config
        Set-Status 'config saved' 'Ok'
        Add-Log "Config saved: $script:ConfigFilePath" 'Ok'
    } catch {
        Set-Status 'config error' 'Error'
        Add-Log $_.Exception.Message 'Error'
    }
})

$btnTestPaths.Add_Click({
    try {
        $config = Get-UiConfig
        Save-Config -Config $config
        Update-SavedPathSnapshotFromConfig -Config $config
        Test-StartupRequirements -Config $config
        Set-Status 'paths valid' 'Ok'
    } catch {
        Set-Status 'path/config error' 'Error'
        Add-Log $_.Exception.Message 'Error'
    }
})

$script:btnStartMonitor.Add_Click({
    try {
        if ($script:IsMonitoring) {
            $timer.Stop()
            $script:IsMonitoring = $false
            $script:GameWasStarted = $false
            $script:LastMonitorLogState = 'Idle'
            Set-MonitorButtonVisual -Running $false
            Set-Status 'idle' 'Neutral'
            Add-Log 'Monitoring stopped.' 'Warn'
            return
        }

        $config = Get-UiConfig
        Save-Config -Config $config
        Update-SavedPathSnapshotFromConfig -Config $config
        Test-StartupRequirements -Config $config
        Start-MO2IfConfigured -Config $config
        Start-GameViaSteamIfConfigured -Config $config

        $script:IsMonitoring = $true
        $script:GameWasStarted = $false
        $script:LastMonitorLogState = 'WaitingForGame'
        $timer.Interval = [Math]::Max(1, [int]$config.CheckIntervalSeconds) * 1000
        Set-MonitorButtonVisual -Running $true
        Set-Status 'waiting for Monster Hunter Wilds...' 'Neutral'
        if ([bool]$config.StartGameViaSteam) {
            Add-Log 'Waiting for Monster Hunter Wilds session after Steam launch.' 'Info'
        } else {
            Add-Log 'Waiting for Monster Hunter Wilds session. Start the game however you want.' 'Info'
        }
        $timer.Start()
    } catch {
        Set-Status 'monitor startup error' 'Error'
        Add-Log $_.Exception.Message 'Error'
    }
})

$btnManualBackup.Add_Click({
    try {
        $config = Get-UiConfig
        Save-Config -Config $config
        Update-SavedPathSnapshotFromConfig -Config $config
        Test-StartupRequirements -Config $config

        $gameRunning = [bool](Get-RunningProcess -Name $config.GameProcessName)
        if ($gameRunning) {
            Set-Status 'game is running - manual backup cancelled' 'Error'
            Add-Log 'Manual backup cancelled because Monster Hunter Wilds is currently running.' 'Warn'
            return
        }

        Set-Status 'creating manual backup...' 'Ok'
        Backup-MHWildsSave -Config $config
        Set-Status 'backup check complete - safe to close' 'Ok'
        Close-WhenFinishedIfEnabled -Config $config
    } catch {
        Set-Status 'backup error' 'Error'
        Add-Log $_.Exception.Message 'Error'
    }
})

$btnOpenBackup.Add_Click({
    try {
        $backupPath = $script:txtBackupPath.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($backupPath)) {
            throw 'Backup destination is empty.'
        }

        if (-not (Test-Path $backupPath)) {
            New-Item -Path $backupPath -ItemType Directory -Force | Out-Null
        }

        Start-Process -FilePath explorer.exe -ArgumentList ('"{0}"' -f $backupPath)
    } catch {
        Set-Status 'open folder error' 'Error'
        Add-Log $_.Exception.Message 'Error'
    }
})

$timer.Add_Tick({
    try {
        $config = Get-UiConfig
        $gameRunning = [bool](Get-RunningProcess -Name $config.GameProcessName)

        if ($gameRunning) {
            $script:GameWasStarted = $true
            Set-Status 'Monster Hunter Wilds is running...' 'Danger'

            if ($script:LastMonitorLogState -ne 'GameRunning') {
                Add-Log 'MH Wilds: running' 'Info'
                $script:LastMonitorLogState = 'GameRunning'
            }

            return
        }

        if (-not $gameRunning -and $script:GameWasStarted) {
            $timer.Stop()
            $script:IsMonitoring = $false
            Set-MonitorButtonVisual -Running $false
            Set-Status 'game closed, creating backup...' 'Ok'
            Add-Log 'Monster Hunter Wilds is closed.' 'Ok'
            $script:LastMonitorLogState = 'Idle'
            Backup-MHWildsSave -Config $config
            Set-Status 'backup check complete - safe to close' 'Ok'
            Close-WhenFinishedIfEnabled -Config $config
            return
        }

        if (-not $gameRunning -and -not $config.RequireGameWasStarted) {
            $timer.Stop()
            $script:IsMonitoring = $false
            Set-MonitorButtonVisual -Running $false
            Set-Status 'creating backup...' 'Ok'
            Add-Log 'Game was not detected, but RequireGameWasStarted is disabled.' 'Warn'
            $script:LastMonitorLogState = 'Idle'
            Backup-MHWildsSave -Config $config
            Set-Status 'backup check complete - safe to close' 'Ok'
            Close-WhenFinishedIfEnabled -Config $config
            return
        }

        Set-Status 'waiting for Monster Hunter Wilds...' 'Neutral'

        if ($script:LastMonitorLogState -eq 'GameNotDetected') {
            Set-LastLogLine 'MH Wilds: not detected yet' 'Info'
        } else {
            Add-Log 'MH Wilds: not detected yet' 'Info'
            $script:LastMonitorLogState = 'GameNotDetected'
        }
    } catch {
        $timer.Stop()
        $script:IsMonitoring = $false
        $script:LastMonitorLogState = 'Idle'
        Set-MonitorButtonVisual -Running $false
        Set-Status 'error' 'Error'
        Add-Log $_.Exception.Message 'Error'
    }
})

$form.Add_FormClosing({
    $timer.Stop()
})

$config = Get-Config
Set-UiConfig -Config $config
Update-SavedPathSnapshotFromConfig -Config $config
Update-OptionEnabledStates
Add-Log 'GUI loaded.' 'Ok'
Add-Log "Config location: $script:ConfigFilePath" 'Info'
Update-LogLayout

[void]$form.ShowDialog()
