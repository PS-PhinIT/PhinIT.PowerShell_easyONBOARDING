#Requires -Version 5.1
<#
.SYNOPSIS
    Prüft die Voraussetzungen von easyONBOARDING und installiert fehlende Komponenten auf Wunsch.

.DESCRIPTION
    Läuft unter Windows PowerShell 5.1 und PowerShell 7, damit PowerShell 7 selbst installiert
    werden kann. Geprüft werden:
    - PowerShell 7.2 oder höher (Installation per winget, sonst signiertes MSI von Microsoft)
    - ActiveDirectory-Modul (RSAT; Client: Windows-Funktion, Server: Windows-Feature)
    - PDF-Erzeugung (Microsoft Edge; optional wkhtmltopdf per winget)
    - Ausführungsrichtlinie (nur auf ausdrücklichen Wunsch RemoteSigned für den aktuellen Benutzer)
    Optional wird der Anwendungsordner an einen festen Ort kopiert; eine vorhandene Konfiguration
    (Config\easyONB.ini) wird dabei nie überschrieben.

    Sicherheitsgrundsätze
    - Es wird nur ausgeführt, was im Fenster ausgewählt wurde (bzw. mit -Install angegeben ist).
    - Keine Selbst-Elevation: Installationen benötigen eine Sitzung mit Administratorrechten.
    - Heruntergeladene MSI-Pakete werden nur ausgeführt, wenn die Authenticode-Signatur gültig und
      von Microsoft ist. wkhtmltopdf wird nur über winget installiert (kein ungeprüfter Download).
    - Die Ausführungsrichtlinie wird nie automatisch geändert; Gruppenrichtlinien haben Vorrang.

.PARAMETER CheckOnly
    Prüft nur und gibt das Ergebnis aus (Exitcode 0 = alle Pflichtvoraussetzungen erfüllt, sonst 1).

.PARAMETER Install
    Ohne Oberfläche installieren: PowerShell7, ActiveDirectory, Wkhtmltopdf, ExecutionPolicy.

.PARAMETER TargetPath
    Zielordner für "Anwendung kopieren" (Standard: C:\easyIT\easyONBOARDING).

.PARAMETER PowerShellMsiUrl
    MSI für PowerShell 7, falls winget fehlt (Standard: PowerShell 7.4 LTS von GitHub).

.EXAMPLE
    powershell.exe -NoProfile -File .\Install-PS7_PDF.ps1

.EXAMPLE
    powershell.exe -NoProfile -File .\Install-PS7_PDF.ps1 -CheckOnly

.NOTES
    Autor: Andreas Hepp (PHINIT.DE)
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Oberflächenfunktionen ändern nur den Zustand des Fensters; Systemänderungen laufen über Funktionen mit ShouldProcess.')]
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$CheckOnly,
    [ValidateSet('PowerShell7', 'ActiveDirectory', 'Wkhtmltopdf', 'ExecutionPolicy')][string[]]$Install = @(),
    [string]$TargetPath = 'C:\easyIT\easyONBOARDING',
    [string]$PowerShellMsiUrl = 'https://github.com/PowerShell/PowerShell/releases/download/v7.4.6/PowerShell-7.4.6-win-x64.msi'
)

Set-StrictMode -Version 3.0

$script:AppRoot = $PSScriptRoot
$script:TargetPath = $TargetPath
$script:PowerShellMsiUrl = $PowerShellMsiUrl
$script:MinimumPowerShell = [version]'7.2'
$script:PrereqUi = $null
$script:ExcludedFolders = @('Logs', 'Reports', 'Data', 'TestResults', '.git')

#region Prüfung

function Test-EobPrereqAdministrator {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if (-not (Test-EobPrereqWindows)) { return $false }
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        return ([System.Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    finally {
        $identity.Dispose()
    }
}

function Test-EobPrereqWindows {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    # $IsWindows gibt es erst ab PowerShell 6; Windows PowerShell 5.1 läuft immer unter Windows.
    if ($PSVersionTable.PSEdition -eq 'Desktop') { return $true }
    return [bool](Get-Variable -Name 'IsWindows' -ValueOnly -ErrorAction SilentlyContinue)
}

function Get-EobPrereqWindowsKind {
    <#
        Liefert 'Client', 'Server' oder 'DomainController' (Win32_OperatingSystem.ProductType).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    try {
        $type = [int](Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop -Verbose:$false).ProductType
        switch ($type) { 1 { return 'Client' } 2 { return 'DomainController' } default { return 'Server' } }
    }
    catch {
        return 'Client'
    }
}

function Get-EobPrereqPowerShell7 {
    <#
        Sucht pwsh.exe (PATH und Standardordner) und liefert Pfad und Version.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $candidates = [System.Collections.Generic.List[string]]::new()
    $command = Get-Command -Name 'pwsh' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) { $candidates.Add([string]$command.Source) }
    if ($env:ProgramFiles) { $candidates.Add((Join-Path -Path $env:ProgramFiles -ChildPath 'PowerShell\7\pwsh.exe')) }
    foreach ($path in $candidates) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $version = $null
        try { $version = [version](Get-Item -LiteralPath $path).VersionInfo.ProductVersion.Split(' ')[0].Split('-')[0] } catch { $version = $null }
        return [pscustomobject]@{ Path = $path; Version = $version }
    }
    return $null
}

function Get-EobPrereqPdfEngine {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $edge = ''
    $wkhtml = ''
    foreach ($base in @(${env:ProgramFiles(x86)}, $env:ProgramFiles, $env:LOCALAPPDATA)) {
        if (-not $base) { continue }
        $path = Join-Path -Path $base -ChildPath 'Microsoft\Edge\Application\msedge.exe'
        if (-not $edge -and (Test-Path -LiteralPath $path -PathType Leaf)) { $edge = $path }
    }
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $base) { continue }
        $path = Join-Path -Path $base -ChildPath 'wkhtmltopdf\bin\wkhtmltopdf.exe'
        if (-not $wkhtml -and (Test-Path -LiteralPath $path -PathType Leaf)) { $wkhtml = $path }
    }
    if (-not $wkhtml) {
        $command = Get-Command -Name 'wkhtmltopdf' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $command) { $wkhtml = [string]$command.Source }
    }
    return [pscustomobject]@{ Edge = $edge; Wkhtmltopdf = $wkhtml }
}

function Test-EobPrereqWinget {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    return ($null -ne (Get-Command -Name 'winget' -CommandType Application -ErrorAction SilentlyContinue))
}

function Get-EobPrereqExecutionPolicy {
    <#
        Wirksame Ausführungsrichtlinie und ob sie per Gruppenrichtlinie festgelegt ist.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $effective = [string](Get-ExecutionPolicy)
    $managed = $false
    # Gruppenrichtlinien gibt es nur unter Windows; andere Systeme melden für jeden Bereich Unrestricted.
    if (-not (Test-EobPrereqWindows)) { return [pscustomobject]@{ Effective = $effective; Managed = $false } }
    foreach ($entry in @(Get-ExecutionPolicy -List)) {
        if ([string]$entry.Scope -in @('MachinePolicy', 'UserPolicy') -and [string]$entry.ExecutionPolicy -ne 'Undefined') { $managed = $true }
    }
    return [pscustomobject]@{ Effective = $effective; Managed = $managed }
}

function Get-EobPrerequisiteStatus {
    <#
    .SYNOPSIS
        Prüft alle Voraussetzungen.
    .OUTPUTS
        Je Punkt: Id, Name, State (Ok, Missing, Warning, Info), Detail, Hint, Installable, Required.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $winget = Test-EobPrereqWinget
    $kind = Get-EobPrereqWindowsKind

    $pwsh = Get-EobPrereqPowerShell7
    if ($null -eq $pwsh) {
        $state = 'Missing'; $detail = 'nicht installiert'
    }
    elseif ($null -ne $pwsh.Version -and $pwsh.Version -lt $script:MinimumPowerShell) {
        $state = 'Missing'; $detail = "Version $($pwsh.Version) ist zu alt (mindestens $script:MinimumPowerShell)"
    }
    elseif ($null -ne $pwsh.Version) {
        $state = 'Ok'; $detail = "Version $($pwsh.Version)"
    }
    else {
        $state = 'Ok'; $detail = "vorhanden ($($pwsh.Path))"
    }
    [pscustomobject]@{
        Id = 'PowerShell7'; Name = 'PowerShell 7'; State = $state; Detail = $detail; Required = $true; Installable = ($state -ne 'Ok')
        Hint = 'easyONBOARDING benötigt PowerShell 7.2 oder höher. Installation per winget, sonst als von Microsoft signiertes MSI.'
    }

    $ad = $null -ne (Get-Module -ListAvailable -Name 'ActiveDirectory' -ErrorAction SilentlyContinue)
    $adSource = if ($kind -eq 'Client') { 'Windows-Funktion RSAT (Rsat.ActiveDirectory.DS-LDS.Tools)' } else { 'Windows-Feature RSAT-AD-PowerShell' }
    [pscustomobject]@{
        Id = 'ActiveDirectory'; Name = 'ActiveDirectory-Modul'; State = $(if ($ad) { 'Ok' } else { 'Missing' })
        Detail = $(if ($ad) { 'vorhanden' } else { "fehlt ($adSource)" }); Required = $true; Installable = (-not $ad)
        Hint = "Für alle Änderungen im Active Directory. Installation über $adSource."
    }

    $pdf = Get-EobPrereqPdfEngine
    $pdfState = if ($pdf.Edge -or $pdf.Wkhtmltopdf) { 'Ok' } else { 'Warning' }
    $pdfDetail = if ($pdf.Edge) { 'Microsoft Edge' } elseif ($pdf.Wkhtmltopdf) { 'wkhtmltopdf' } else { 'keine Engine: Berichte nur als HTML' }
    [pscustomobject]@{
        Id = 'PdfEngine'; Name = 'PDF-Erzeugung'; State = $pdfState; Detail = $pdfDetail; Required = $false; Installable = $false
        Hint = 'PDF-Berichte entstehen mit Microsoft Edge (empfohlen) oder wkhtmltopdf. Ohne Engine bleiben Berichte HTML.'
    }
    [pscustomobject]@{
        Id = 'Wkhtmltopdf'; Name = 'wkhtmltopdf (optional)'; State = $(if ($pdf.Wkhtmltopdf) { 'Ok' } else { 'Info' })
        Detail = $(if ($pdf.Wkhtmltopdf) { 'vorhanden' } elseif ($winget) { 'nicht installiert (nur nötig ohne Edge)' } else { 'nicht installiert; Installation nur per winget' })
        Required = $false; Installable = ((-not $pdf.Wkhtmltopdf) -and $winget)
        Hint = 'Nur nötig, wenn Microsoft Edge fehlt. Das Projekt wird nicht mehr weiterentwickelt; Edge ist vorzuziehen.'
    }

    $policy = Get-EobPrereqExecutionPolicy
    $policyOk = $policy.Effective -in @('RemoteSigned', 'Unrestricted', 'Bypass', 'AllSigned')
    $policyDetail = $policy.Effective + $(if ($policy.Managed) { ' (per Gruppenrichtlinie festgelegt)' } elseif ($policy.Effective -eq 'AllSigned') { ' (Skripte müssen signiert sein)' } else { '' })
    [pscustomobject]@{
        Id = 'ExecutionPolicy'; Name = 'Ausführungsrichtlinie'; State = $(if ($policyOk) { 'Ok' } else { 'Warning' }); Detail = $policyDetail
        Required = $false; Installable = ((-not $policyOk) -and (-not $policy.Managed))
        Hint = 'Empfohlen: RemoteSigned bzw. AllSigned mit signierten Skripten. Geändert wird nur auf Wunsch und nur für den aktuellen Benutzer.'
    }
}

#endregion

#region Installation

function Invoke-EobPrereqProcess {
    <#
        Startet ein Programm mit Argumentliste, wartet und liefert den Exitcode.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList
    )

    $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -Wait -PassThru -NoNewWindow -ErrorAction Stop
    return [int]$process.ExitCode
}

function Assert-EobPrereqAdministrator {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Action)

    if (-not (Test-EobPrereqAdministrator)) {
        throw "$Action benötigt Administratorrechte. Bitte PowerShell als Administrator starten."
    }
}

function Test-EobPrereqMicrosoftSignature {
    <#
        Prüft, ob eine Datei gültig von Microsoft signiert ist.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)

    $signature = Get-AuthenticodeSignature -FilePath $Path
    if ([string]$signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate) { return $false }
    return ([string]$signature.SignerCertificate.Subject -match '(^|,\s*)O=Microsoft Corporation(,|$)')
}

function Install-EobPowerShell7 {
    <#
    .SYNOPSIS
        Installiert PowerShell 7 per winget oder als signiertes MSI.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$MsiUrl)

    if (-not $PSCmdlet.ShouldProcess('PowerShell 7', 'Installieren')) { return 'Simulation: PowerShell 7 würde installiert.' }
    Assert-EobPrereqAdministrator -Action 'Die Installation von PowerShell 7'
    if (Test-EobPrereqWinget) {
        $code = Invoke-EobPrereqProcess -FilePath 'winget' -ArgumentList @('install', '--id', 'Microsoft.PowerShell', '--exact', '--source', 'winget', '--silent',
            '--accept-package-agreements', '--accept-source-agreements')
        if ($code -eq 0) { return 'PowerShell 7 per winget installiert.' }
    }
    if ($MsiUrl -notmatch '^https://') { throw 'Für das MSI ist eine https-Adresse erforderlich.' }
    $target = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('easyONB-pwsh-' + [guid]::NewGuid().ToString('N') + '.msi')
    try {
        Invoke-WebRequest -Uri $MsiUrl -OutFile $target -UseBasicParsing -ErrorAction Stop
        if (-not (Test-EobPrereqMicrosoftSignature -Path $target)) {
            throw 'Das heruntergeladene Paket ist nicht gültig von Microsoft signiert und wird nicht ausgeführt.'
        }
        $code = Invoke-EobPrereqProcess -FilePath 'msiexec.exe' -ArgumentList @('/i', "`"$target`"", '/qn', '/norestart', 'ADD_PATH=1')
        if ($code -notin @(0, 3010)) { throw "msiexec meldet Exitcode $code." }
        return $(if ($code -eq 3010) { 'PowerShell 7 installiert (Neustart erforderlich).' } else { 'PowerShell 7 installiert.' })
    }
    finally {
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue }
    }
}

function Install-EobActiveDirectoryModule {
    <#
    .SYNOPSIS
        Installiert das ActiveDirectory-Modul (RSAT).
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([string])]
    param()

    if (-not $PSCmdlet.ShouldProcess('ActiveDirectory-Modul (RSAT)', 'Installieren')) { return 'Simulation: RSAT würde installiert.' }
    Assert-EobPrereqAdministrator -Action 'Die Installation von RSAT'
    if ((Get-EobPrereqWindowsKind) -eq 'Client') {
        $null = Add-WindowsCapability -Online -Name 'Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0' -ErrorAction Stop
    }
    else {
        $null = Install-WindowsFeature -Name 'RSAT-AD-PowerShell' -ErrorAction Stop
    }
    return 'ActiveDirectory-Modul installiert.'
}

function Install-EobWkhtmltopdf {
    <#
    .SYNOPSIS
        Installiert wkhtmltopdf ausschließlich per winget.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([string])]
    param()

    if (-not $PSCmdlet.ShouldProcess('wkhtmltopdf', 'Installieren')) { return 'Simulation: wkhtmltopdf würde installiert.' }
    if (-not (Test-EobPrereqWinget)) { throw 'wkhtmltopdf wird nur per winget installiert. Alternativ Microsoft Edge verwenden.' }
    Assert-EobPrereqAdministrator -Action 'Die Installation von wkhtmltopdf'
    $code = Invoke-EobPrereqProcess -FilePath 'winget' -ArgumentList @('install', '--id', 'wkhtmltopdf.wkhtmltox', '--exact', '--source', 'winget', '--silent',
        '--accept-package-agreements', '--accept-source-agreements')
    if ($code -ne 0) { throw "winget meldet Exitcode $code." }
    return 'wkhtmltopdf installiert.'
}

function Set-EobPrereqExecutionPolicy {
    <#
    .SYNOPSIS
        Setzt die Ausführungsrichtlinie RemoteSigned für den aktuellen Benutzer (nur auf ausdrücklichen Wunsch).
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([string])]
    param()

    if ((Get-EobPrereqExecutionPolicy).Managed) { throw 'Die Ausführungsrichtlinie ist per Gruppenrichtlinie festgelegt und kann hier nicht geändert werden.' }
    if (-not $PSCmdlet.ShouldProcess('Ausführungsrichtlinie (CurrentUser)', 'Auf RemoteSigned setzen')) { return 'Simulation: RemoteSigned würde gesetzt.' }
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force -ErrorAction Stop
    return 'Ausführungsrichtlinie RemoteSigned für den aktuellen Benutzer gesetzt.'
}

function Copy-EobApplication {
    <#
    .SYNOPSIS
        Kopiert den Anwendungsordner ohne Laufzeitdaten; eine vorhandene Konfiguration bleibt erhalten.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Destination,
        [string]$Source = $script:AppRoot
    )

    if ([string]::IsNullOrWhiteSpace($Destination)) { throw 'Bitte einen Zielordner angeben.' }
    $sourceFull = [System.IO.Path]::GetFullPath($Source).TrimEnd('\', '/')
    $targetFull = [System.IO.Path]::GetFullPath($Destination).TrimEnd('\', '/')
    if ($targetFull -eq $sourceFull -or $targetFull.StartsWith($sourceFull + [System.IO.Path]::DirectorySeparatorChar)) {
        throw 'Der Zielordner darf nicht der Anwendungsordner oder ein Unterordner davon sein.'
    }
    if (-not $PSCmdlet.ShouldProcess($targetFull, 'Anwendung kopieren')) { return "Simulation: Anwendung würde nach $targetFull kopiert." }

    $copied = 0
    $kept = 0
    foreach ($file in Get-ChildItem -LiteralPath $sourceFull -Recurse -File -Force) {
        $relative = $file.FullName.Substring($sourceFull.Length).TrimStart('\', '/')
        $first = ($relative -split '[\\/]')[0]
        if ($first -in $script:ExcludedFolders) { continue }
        $target = Join-Path -Path $targetFull -ChildPath $relative
        # Eigene Konfiguration nie überschreiben (Haupt-INI und Unternehmensdateien)
        if ((Test-Path -LiteralPath $target -PathType Leaf) -and $relative -match '^(?i)Config[\\/](easyONB\.ini|companies[\\/].+\.ini)$') {
            $kept++
            continue
        }
        $directory = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) { $null = New-Item -ItemType Directory -Path $directory -Force }
        Copy-Item -LiteralPath $file.FullName -Destination $target -Force
        $copied++
    }
    # VERSION liegt im Repository-Stamm; mitkopieren, damit die Anwendung ihre Version kennt.
    $version = Join-Path -Path (Split-Path -Parent $sourceFull) -ChildPath 'VERSION'
    if (Test-Path -LiteralPath $version -PathType Leaf) { Copy-Item -LiteralPath $version -Destination (Join-Path -Path $targetFull -ChildPath 'VERSION') -Force }
    return "Anwendung nach $targetFull kopiert ($copied Dateien$(if ($kept -gt 0) { ", $kept vorhandene Konfigurationsdatei(en) beibehalten" }))."
}

function Invoke-EobPrereqAction {
    <#
        Führt eine Aktion anhand ihrer Id aus.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidateSet('PowerShell7', 'ActiveDirectory', 'Wkhtmltopdf', 'ExecutionPolicy', 'Copy')][string]$Id,
        [string]$MsiUrl = $script:PowerShellMsiUrl,
        [string]$Destination = $script:TargetPath
    )

    switch ($Id) {
        'PowerShell7' { return (Install-EobPowerShell7 -MsiUrl $MsiUrl -Confirm:$false) }
        'ActiveDirectory' { return (Install-EobActiveDirectoryModule -Confirm:$false) }
        'Wkhtmltopdf' { return (Install-EobWkhtmltopdf -Confirm:$false) }
        'ExecutionPolicy' { return (Set-EobPrereqExecutionPolicy -Confirm:$false) }
        'Copy' { return (Copy-EobApplication -Destination $Destination -Confirm:$false) }
    }
}

#endregion

#region Oberfläche

function Get-EobPrereqStateText {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$State)

    switch ($State) { 'Ok' { 'in Ordnung' } 'Missing' { 'fehlt' } 'Warning' { 'prüfen' } default { 'optional' } }
}

function Add-EobPrereqLog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Text)

    $box = $script:PrereqUi.C.PrereqLogText
    $line = '[{0}] {1}' -f (Get-Date).ToString('HH:mm:ss'), $Text
    $box.Text = if ($box.Text) { "$($box.Text)`n$line" } else { $line }
    $box.ScrollToEnd()
}

function Set-EobPrereqToolTip {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Element, [Parameter(Mandatory)][string]$Text)

    $Element.ToolTip = $Text
    [System.Windows.Controls.ToolTipService]::SetInitialShowDelay($Element, 250)
    [System.Windows.Controls.ToolTipService]::SetShowDuration($Element, 30000)
    [System.Windows.Controls.ToolTipService]::SetShowOnDisabled($Element, $true)
}

function Update-EobPrereqView {
    <#
        Prüft erneut und baut die Zeilen der Prüfung neu auf.
    #>
    [CmdletBinding()]
    param()

    $ui = $script:PrereqUi
    $grid = $ui.C.PrereqItemsGrid
    $grid.Children.Clear()
    $grid.RowDefinitions.Clear()
    $ui.Checks = @{}
    $ui.Items = @(Get-EobPrerequisiteStatus)
    $admin = Test-EobPrereqAdministrator
    $row = 0
    foreach ($item in $ui.Items) {
        $definition = [System.Windows.Controls.RowDefinition]::new()
        $definition.Height = [System.Windows.GridLength]::Auto
        $grid.RowDefinitions.Add($definition)
        $check = [System.Windows.Controls.CheckBox]::new()
        $needsAdmin = $item.Id -in @('PowerShell7', 'ActiveDirectory', 'Wkhtmltopdf')
        $check.IsEnabled = $item.Installable -and ($admin -or -not $needsAdmin)
        # Pflichtvoraussetzungen sind vorausgewählt; Richtlinie und wkhtmltopdf nur auf ausdrücklichen Wunsch.
        $check.IsChecked = $check.IsEnabled -and $item.Required
        $check.Margin = [System.Windows.Thickness]::new(0, 6, 0, 0)
        $hint = $item.Hint
        if ($item.Installable -and $needsAdmin -and -not $admin) { $hint += ' Installation nur mit Administratorrechten.' }
        foreach ($pair in @(@{ Element = $check; Column = 0 }, @{ Element = [System.Windows.Controls.TextBlock]::new(); Column = 1; Text = $item.Name },
                @{ Element = [System.Windows.Controls.TextBlock]::new(); Column = 2; Text = (Get-EobPrereqStateText -State $item.State); State = $item.State },
                @{ Element = [System.Windows.Controls.TextBlock]::new(); Column = 3; Text = $item.Detail })) {
            $element = $pair.Element
            if ($pair.ContainsKey('Text')) {
                $element.Text = $pair.Text
                $element.TextWrapping = 'Wrap'
                $element.Margin = [System.Windows.Thickness]::new(0, 6, 12, 0)
                $element.VerticalAlignment = 'Center'
            }
            if ($pair.ContainsKey('State')) {
                $key = switch ($pair.State) { 'Ok' { 'SuccessBrush' } 'Missing' { 'ErrorBrush' } 'Warning' { 'WarningBrush' } default { 'TextSecondaryBrush' } }
                $element.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $key)
                $element.FontWeight = [System.Windows.FontWeights]::SemiBold
            }
            Set-EobPrereqToolTip -Element $element -Text $hint
            [System.Windows.Controls.Grid]::SetRow($element, $row)
            [System.Windows.Controls.Grid]::SetColumn($element, $pair.Column)
            $null = $grid.Children.Add($element)
        }
        $ui.Checks[$item.Id] = $check
        $row++
    }
    $kind = Get-EobPrereqWindowsKind
    $ui.C.PrereqSubtitleText.Text = "Windows PowerShell/PowerShell $($PSVersionTable.PSVersion)  ·  $kind  ·  $([Environment]::MachineName)"
    $ui.C.PrereqAdminText.Text = if ($admin) { 'Mit Administratorrechten gestartet: Installationen sind möglich.' } else { 'Ohne Administratorrechte gestartet: Installationen sind gesperrt. Für Installationen PowerShell als Administrator starten.' }
    $ui.C.PrereqAdminBanner.Style = $ui.Application.FindResource($(if ($admin) { 'InfoBannerStyle' } else { 'WarningBannerStyle' }))
    $missing = @($ui.Items | Where-Object { $_.Required -and $_.State -ne 'Ok' }).Count
    $ui.C.PrereqProgressText.Text = if ($missing -gt 0) { "$missing Pflichtvoraussetzung(en) fehlen." } else { 'Alle Pflichtvoraussetzungen sind erfüllt.' }
}

function Invoke-EobPrereqQueueStep {
    <#
        Führt den nächsten Schritt der Warteschlange aus; zwischen den Schritten wird die Oberfläche aktualisiert.
    #>
    [CmdletBinding()]
    param()

    $ui = $script:PrereqUi
    $ui.Timer.Stop()
    if ($ui.Queue.Count -eq 0) {
        $ui.Running = $false
        foreach ($name in @('PrereqInstallButton', 'PrereqRefreshButton')) { $ui.C[$name].IsEnabled = $true }
        Add-EobPrereqLog -Text 'Fertig. Prüfung wird aktualisiert.'
        Update-EobPrereqView
        return
    }
    $id = $ui.Queue[0]
    $ui.Queue.RemoveAt(0)
    try {
        Add-EobPrereqLog -Text (Invoke-EobPrereqAction -Id $id -Destination ([string]$ui.C.PrereqTargetText.Text).Trim())
    }
    catch {
        Add-EobPrereqLog -Text "Fehler bei $id`: $($_.Exception.Message)"
    }
    if ($ui.Queue.Count -gt 0) { $ui.C.PrereqProgressText.Text = "Läuft: $($ui.Queue[0]) …" }
    $ui.Timer.Start()
}

function Confirm-EobPrereqPolicyChange {
    [CmdletBinding()]
    param()

    return [System.Windows.MessageBox]::Show($script:PrereqUi.Window, 'Die Ausführungsrichtlinie des aktuellen Benutzers wird auf RemoteSigned gesetzt. Fortfahren?', 'Ausführungsrichtlinie', 'YesNo', 'Question') -eq 'Yes'
}

function Start-EobPrereqSelection {
    [CmdletBinding()]
    param()

    $ui = $script:PrereqUi
    if ($ui.Running) { return }
    $selected = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $ui.Items) {
        $check = $ui.Checks[$item.Id]
        if ($null -ne $check -and [bool]$check.IsChecked) { $selected.Add($item.Id) }
    }
    if ([bool]$ui.C.PrereqCopyCheck.IsChecked) { $selected.Add('Copy') }
    if ($selected.Count -eq 0) { Add-EobPrereqLog -Text 'Nichts ausgewählt.'; return }
    if ($selected.Contains('ExecutionPolicy') -and -not $ui.Headless) {
        if (-not (Confirm-EobPrereqPolicyChange)) { $null = $selected.Remove('ExecutionPolicy') }
    }
    if ($selected.Count -eq 0) { Add-EobPrereqLog -Text 'Nichts ausgewählt.'; return }
    $ui.Queue = $selected
    $ui.Running = $true
    foreach ($name in @('PrereqInstallButton', 'PrereqRefreshButton')) { $ui.C[$name].IsEnabled = $false }
    Add-EobPrereqLog -Text ('Ausgewählt: ' + ($selected -join ', '))
    $ui.C.PrereqProgressText.Text = "Läuft: $($selected[0]) … (einzelne Schritte können einige Minuten dauern)"
    $ui.Timer.Start()
}

function Initialize-EobPrereqWindow {
    [CmdletBinding()]
    param([switch]$Headless)

    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
    $gui = Join-Path -Path $script:AppRoot -ChildPath 'GUI'
    $load = { param([string]$Relative) [System.Windows.Markup.XamlReader]::Parse([System.IO.File]::ReadAllText((Join-Path -Path $gui -ChildPath $Relative), [System.Text.Encoding]::UTF8)) }
    $application = [System.Windows.Application]::Current
    if ($null -eq $application) {
        $application = [System.Windows.Application]::new()
        $application.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
    }
    $application.Resources.MergedDictionaries.Clear()
    $application.Resources.MergedDictionaries.Add((& $load 'Styles\Theme.Light.xaml'))
    $application.Resources.MergedDictionaries.Add((& $load 'Styles\Controls.xaml'))
    $window = & $load 'Installer\PrerequisitesWindow.xaml'
    $controls = @{}
    foreach ($name in @('PrereqSubtitleText', 'PrereqRefreshButton', 'PrereqInstallButton', 'PrereqCloseButton', 'PrereqProgressText', 'PrereqAdminBanner',
            'PrereqAdminText', 'PrereqItemsGrid', 'PrereqCopyCheck', 'PrereqTargetText', 'PrereqLogText')) {
        $control = $window.FindName($name)
        if ($null -eq $control) { throw "Steuerelement fehlt: $name" }
        $controls[$name] = $control
    }
    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds(150)
    $script:PrereqUi = @{
        Application = $application; Window = $window; C = $controls; Items = @(); Checks = @{}; Queue = $null; Running = $false; Timer = $timer; Headless = [bool]$Headless
    }
    $timer.Add_Tick({ Invoke-EobPrereqQueueStep })
    $controls.PrereqTargetText.Text = $script:TargetPath
    $controls.PrereqRefreshButton.Add_Click({ Update-EobPrereqView })
    $controls.PrereqInstallButton.Add_Click({ Start-EobPrereqSelection })
    $controls.PrereqCloseButton.Add_Click({ $script:PrereqUi.Window.Close() })
    $window.Add_Closing({
            param($source, $e)
            $null = $source
            if ($script:PrereqUi.Running) {
                $e.Cancel = $true
                Add-EobPrereqLog -Text 'Bitte warten, bis die laufenden Schritte abgeschlossen sind.'
            }
        })
    Update-EobPrereqView
    Add-EobPrereqLog -Text 'Prüfung abgeschlossen. Nichts wird ohne Auswahl geändert.'
}

#endregion

# Beim Dot-Sourcing (Tests) nur die Funktionen laden.
if ($MyInvocation.InvocationName -eq '.') { return }

if (-not (Test-EobPrereqWindows)) {
    Write-Error 'Dieses Skript ist für Windows bestimmt.'
    exit 1
}

if ($CheckOnly -or $Install.Count -gt 0) {
    $status = @(Get-EobPrerequisiteStatus)
    $status | Select-Object -Property Name, @{ Name = 'Status'; Expression = { Get-EobPrereqStateText -State $_.State } }, Detail | Format-Table -AutoSize | Out-String -Width 200 | Write-Output
    foreach ($id in $Install) {
        try {
            Write-Output (Invoke-EobPrereqAction -Id $id)
        }
        catch {
            Write-Error "$id`: $($_.Exception.Message)"
        }
    }
    if ($Install.Count -gt 0) { $status = @(Get-EobPrerequisiteStatus) }
    if (@($status | Where-Object { $_.Required -and $_.State -ne 'Ok' }).Count -gt 0) { exit 1 }
    exit 0
}

Initialize-EobPrereqWindow
$null = $script:PrereqUi.Window.ShowDialog()
