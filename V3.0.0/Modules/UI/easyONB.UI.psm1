#Requires -Version 7.2
<#
    easyONB.UI
    WPF-Oberfläche von easyONBOARDING: XAML laden, Farbschemata, Navigation, Assistenten,
    kooperative Ausführung von Plänen und zentrale Dialoge. Fachliche Entscheidungen liegen
    ausschließlich in den Fachmodulen (Onboarding, Offboarding, Reporting, ...).

    Grundsätze
    - XAML enthält weder x:Class noch Ereignisattribute; Ereignisse werden hier verbunden.
    - Ereignis-Handler greifen nur über $script:Ui auf Zustand zu (keine Closures) und laufen
      über Invoke-EobUiSafely: Fehler werden protokolliert und als Dialog angezeigt.
    - Steuerelemente werden beim Laden vollständig aufgelöst; fehlende Namen führen zu einem
      Fehler statt zu stillen Null-Verweisen. Ein statischer Test gleicht die im Code
      verwendeten Namen mit den XAML-Dateien ab.
    - Pläne werden per DispatcherTimer Schritt für Schritt ausgeführt (ADR-09); Abbrechen ist
      zwischen zwei Schritten möglich. Ein laufender Schritt blockiert die Oberfläche bis
      zu seinem Abschluss; der Timer führt ihn nicht in einem Hintergrundthread aus.
    - Kennwörter werden nur im Zugangsdatendialog angezeigt, danach aus dem Speicher entfernt.
    - Die Funktionen ändern ausschließlich den Zustand der Oberfläche. Systemverändernde Aktionen
      laufen über die Fachmodule (ShouldProcess) und werden vorher im Dialog bestätigt; daher gilt
      die Analyzer-Regel PSUseShouldProcessForStateChangingFunctions hier nicht.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Nur Zustand der Oberfläche; Systemänderungen laufen über die Fachmodule.')]
param()

Set-StrictMode -Version 1.0

#region Konstanten und Zustand

$script:GuiRoot = Join-Path -Path (Get-EobAppRoot) -ChildPath 'GUI'
$script:Ui = $null

$script:ViewDefinitions = [ordered]@{
    Dashboard   = @{ File = 'Views/DashboardView.xaml'; Nav = 'NavDashboard'; Initialize = 'Initialize-EobDashboardView'; Refresh = 'Update-EobDashboardView' }
    Onboarding  = @{ File = 'Views/OnboardingView.xaml'; Nav = 'NavOnboarding'; Initialize = 'Initialize-EobOnboardingView'; Refresh = '' }
    Offboarding = @{ File = 'Views/OffboardingView.xaml'; Nav = 'NavOffboarding'; Initialize = 'Initialize-EobOffboardingView'; Refresh = 'Update-EobOffboardingQueue' }
    UserUpdate  = @{ File = 'Views/UserUpdateView.xaml'; Nav = 'NavUserUpdate'; Initialize = 'Initialize-EobUserUpdateView'; Refresh = '' }
    Bulk        = @{ File = 'Views/BulkView.xaml'; Nav = 'NavBulk'; Initialize = 'Initialize-EobBulkView'; Refresh = '' }
    Reports     = @{ File = 'Views/ReportsView.xaml'; Nav = 'NavReports'; Initialize = 'Initialize-EobReportsView'; Refresh = 'Update-EobReportList' }
    Tools       = @{ File = 'Views/ToolsView.xaml'; Nav = 'NavTools'; Initialize = 'Initialize-EobToolsView'; Refresh = 'Update-EobToolsStatus' }
    Settings    = @{ File = 'Views/SettingsView.xaml'; Nav = 'NavSettings'; Initialize = 'Initialize-EobSettingsView'; Refresh = 'Update-EobSettingsView' }
    Info        = @{ File = 'Views/InfoView.xaml'; Nav = 'NavInfo'; Initialize = 'Initialize-EobInfoView'; Refresh = 'Update-EobInfoView' }
}

$script:StatusTexts = @{
    Planned = 'Geplant'; Running = 'Läuft'; Succeeded = 'Erfolgreich'; Simulated = 'Simuliert'; Warning = 'Warnung'
    Skipped = 'Übersprungen'; Failed = 'Fehlgeschlagen'; Cancelled = 'Abgebrochen'; CompletedWithWarnings = 'Mit Warnungen'
    Scheduled = 'Geplant (Warteschlange)'; Open = 'Offen'; AwaitingDeletion = 'Wartet auf Löschfreigabe'
    Completed = 'Abgeschlossen'; Deleted = 'Gelöscht'; NotExecuted = 'Nicht ausgeführt'; Ready = 'Bereit'; Error = 'Fehler'
}
$script:SeverityTexts = @{ Error = 'Fehler'; Warning = 'Warnung'; Information = 'Hinweis' }
$script:RiskTexts = @{ Low = 'Gering'; Medium = 'Mittel'; High = 'Hoch'; Destructive = 'Destruktiv' }
$script:PhaseTexts = @{ Always = 'Dokumentation'; Main = ''; Immediate = 'Sofort'; ExitDate = 'Zum Austritt'; Retention = 'Aufbewahrung'; FinalDeletion = 'Endgültige Löschung' }
$script:StateTexts = @{
    Available = 'Verfügbar'; Connected = 'Verbunden'; NotConnected = 'Nicht verbunden'; NotConfigured = 'Nicht konfiguriert'
    NotInstalled = 'Nicht installiert'; Error = 'Fehler'; Disabled = 'Deaktiviert'
}
$script:ImplementationTexts = @{ Productive = 'Produktiv'; Prepared = 'Vorbereitet'; Simulated = 'Simuliert'; Experimental = 'Experimentell' }
$script:KindTexts = @{
    Onboarding = 'Onboarding'; Offboarding = 'Offboarding'; UserUpdate = 'Benutzer aktualisiert'; PasswordReset = 'Kennwort-Reset'
    OffboardingDeletion = 'Endgültige Löschung'; BulkOffboarding = 'Massen-Offboarding'; BulkOnboarding = 'Massen-Onboarding'
}

# Formularfeld der Onboarding-Anfrage -> Assistentenschritt und Fehleranzeige
$script:OnboardingFieldMap = [ordered]@{
    CompanyId               = @{ Step = 1; Error = 'OnbCompanyError' }
    RoleTemplate            = @{ Step = 1; Error = 'OnbCompanyError' }
    ReferenceUser           = @{ Step = 1; Error = 'OnbReferenceUserError' }
    GivenName               = @{ Step = 2; Error = 'OnbGivenNameError' }
    Surname                 = @{ Step = 2; Error = 'OnbSurnameError' }
    DisplayName             = @{ Step = 2; Error = 'OnbDisplayNameError' }
    EmployeeId              = @{ Step = 2; Error = 'OnbEmployeeIdError' }
    EmployeeNumber          = @{ Step = 2; Error = 'OnbEmployeeIdError' }
    EmployeeType            = @{ Step = 2; Error = 'OnbEmployeeIdError' }
    StartDate               = @{ Step = 2; Error = 'OnbStartDateError' }
    ExpirationDate          = @{ Step = 2; Error = 'OnbExpirationDateError' }
    SamAccountName          = @{ Step = 3; Error = 'OnbSamError' }
    UserPrincipalNamePrefix = @{ Step = 3; Error = 'OnbUpnError' }
    MailLocalPart           = @{ Step = 3; Error = 'OnbMailError' }
    MailDomain              = @{ Step = 3; Error = 'OnbMailError' }
    TargetOU                = @{ Step = 4; Error = 'OnbTargetOuError' }
    Title                   = @{ Step = 4; Error = 'OnbTitleError' }
    Department              = @{ Step = 4; Error = 'OnbDepartmentError' }
    Company                 = @{ Step = 4; Error = 'OnbDescriptionError' }
    Office                  = @{ Step = 4; Error = 'OnbDescriptionError' }
    OfficePhone             = @{ Step = 4; Error = 'OnbOfficePhoneError' }
    MobilePhone             = @{ Step = 4; Error = 'OnbMobilePhoneError' }
    Manager                 = @{ Step = 4; Error = 'OnbManagerError' }
    Description             = @{ Step = 4; Error = 'OnbDescriptionError' }
    LicenseKey              = @{ Step = 5; Error = '' }
    Groups                  = @{ Step = 5; Error = '' }
    TeamLeadGroupKey        = @{ Step = 5; Error = '' }
    PasswordMode            = @{ Step = 6; Error = 'OnbPasswordError' }
    ManualPassword          = @{ Step = 6; Error = 'OnbPasswordError' }
    Ticket                  = @{ Step = 6; Error = 'OnbTicketError' }
    Notes                   = @{ Step = 6; Error = 'OnbTicketError' }
}

$script:OffboardingFieldMap = @{
    ExitDate = 'OffExitDateError'; Ticket = 'OffTicketError'; Reason = 'OffReasonError'; ForwardTo = 'OffForwardError'; Notes = 'OffNotesError'
}

function New-EobUiState {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    @{
        Application    = $null
        Window         = $null
        Config         = $null
        ConfigPath     = ''
        C              = @{}
        Views          = @{}
        CurrentView    = ''
        Simulation     = $true
        Theme          = 'Light'
        AccentColor    = ''
        ThemeIndex     = -1
        Execution      = $null
        LogTimer       = $null
        ClipboardTimer = $null
        ClipboardHash  = $null
        Onboarding     = @{}
        Offboarding    = @{}
        Update         = @{}
        Bulk           = @{}
        # Nur für automatisierte Tests: Dialoge werden protokolliert statt modal angezeigt.
        Headless       = $false
        DialogLog      = [System.Collections.Generic.List[string]]::new()
    }
}

#endregion

#region Plattformunabhängige Hilfsfunktionen (ohne WPF testbar)

function Get-EobUiText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Map,
        [AllowNull()][AllowEmptyString()][string]$Key
    )

    if ($Key -and $Map.ContainsKey($Key)) { return [string]$Map[$Key] }
    return [string]$Key
}

function Get-EobXamlText {
    <#
    .SYNOPSIS
        Liest eine XAML-Datei der Oberfläche und prüft die Grundregeln (kein x:Class, keine Ereignisse).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$RelativePath)

    $path = Join-Path -Path $script:GuiRoot -ChildPath $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "XAML-Datei fehlt: $path"
    }
    $text = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
    $problems = @(Test-EobXamlContent -Xaml $text)
    if ($problems.Count -gt 0) {
        throw ('XAML-Datei {0} ist ungültig: {1}' -f $RelativePath, ($problems -join ' | '))
    }
    return $text
}

function Test-EobXamlContent {
    <#
    .SYNOPSIS
        Prüft XAML-Text statisch: wohlgeformt, kein x:Class, keine Ereignisattribute, eindeutige Namen.
    .OUTPUTS
        Liste der gefundenen Probleme (leer = in Ordnung).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Xaml)

    try {
        $document = [xml]$Xaml
    }
    catch {
        return "Nicht wohlgeformt: $($_.Exception.Message)"
    }
    $eventNames = 'Click|Checked|Unchecked|Loaded|Unloaded|SelectionChanged|TextChanged|KeyDown|KeyUp|PreviewKeyDown|MouseDown|MouseUp|MouseLeftButtonUp|MouseDoubleClick|Closing|Closed|GotFocus|LostFocus|ValueChanged|SelectedDateChanged|PasswordChanged|Tick'
    foreach ($node in $document.SelectNodes('//*')) {
        foreach ($attribute in @($node.Attributes)) {
            if ($attribute.LocalName -eq 'Class' -and $attribute.NamespaceURI -like '*winfx/2006/xaml') {
                'x:Class ist nicht zulässig.'
            }
            if ($attribute.NamespaceURI -eq '' -and $attribute.LocalName -match "^($eventNames)$") {
                "Ereignisattribut '$($attribute.LocalName)' an <$($node.LocalName)> ist nicht zulässig."
            }
        }
    }
    $names = @(Get-EobXamlElementName -Xaml $Xaml)
    foreach ($duplicate in @($names | Group-Object | Where-Object Count -GT 1)) {
        "Name '$($duplicate.Name)' ist mehrfach vergeben."
    }
}

function Get-EobXamlElementName {
    <#
    .SYNOPSIS
        Liefert die x:Name-Werte außerhalb von Vorlagen (Templates, Styles, Ressourcen).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Xaml)

    $document = [xml]$Xaml
    foreach ($node in $document.SelectNodes('//*')) {
        $name = $null
        foreach ($attribute in @($node.Attributes)) {
            if ($attribute.LocalName -eq 'Name' -and ($attribute.NamespaceURI -like '*winfx/2006/xaml' -or $attribute.NamespaceURI -eq '')) {
                $name = $attribute.Value
            }
        }
        if (-not $name) { continue }
        $insideTemplate = $false
        $parent = $node.ParentNode
        while ($null -ne $parent -and $parent -is [System.Xml.XmlElement]) {
            if ($parent.LocalName -match 'Template$|^Style$|\.Resources$|^ResourceDictionary$') { $insideTemplate = $true; break }
            $parent = $parent.ParentNode
        }
        if (-not $insideTemplate) { $name }
    }
}

function Get-EobAccentPalette {
    <#
    .SYNOPSIS
        Berechnet Akzent-, Hover- und Vordergrundfarbe (WCAG-Kontrast) für ein Farbschema.
    .EXAMPLE
        Get-EobAccentPalette -Color '#0F6CBD' -Theme Light
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidatePattern('^#[0-9A-Fa-f]{6}$')][string]$Color,
        [ValidateSet('Light', 'Dark')][string]$Theme = 'Light'
    )

    $rgb = @(
        [Convert]::ToInt32($Color.Substring(1, 2), 16),
        [Convert]::ToInt32($Color.Substring(3, 2), 16),
        [Convert]::ToInt32($Color.Substring(5, 2), 16)
    )
    $luminance = {
        param([int[]]$Channels)
        $linear = foreach ($channel in $Channels) {
            $value = $channel / 255.0
            if ($value -le 0.03928) { $value / 12.92 } else { [Math]::Pow(($value + 0.055) / 1.055, 2.4) }
        }
        return (0.2126 * $linear[0] + 0.7152 * $linear[1] + 0.0722 * $linear[2])
    }
    $mix = {
        param([int[]]$Channels, [int]$Target, [double]$Amount)
        return @($Channels | ForEach-Object { [int][Math]::Round($_ + ($Target - $_) * $Amount) })
    }
    $hex = { param([int[]]$Channels) '#' + (($Channels | ForEach-Object { $_.ToString('X2') }) -join '') }

    # Im dunklen Schema werden dunkle Akzentfarben aufgehellt, damit sie sich vom Hintergrund abheben.
    if ($Theme -eq 'Dark' -and (& $luminance $rgb) -lt 0.2) { $rgb = & $mix $rgb 255 0.45 }
    $hover = if ($Theme -eq 'Dark') { & $mix $rgb 255 0.15 } else { & $mix $rgb 0 0.12 }
    $l = & $luminance $rgb
    $contrastWhite = 1.05 / ($l + 0.05)
    $contrastBlack = ($l + 0.05) / 0.05
    [pscustomobject]@{
        Accent     = & $hex $rgb
        Hover      = & $hex $hover
        Foreground = if ($contrastWhite -ge $contrastBlack) { '#FFFFFF' } else { '#000000' }
        Contrast   = [Math]::Round([Math]::Max($contrastWhite, $contrastBlack), 2)
    }
}

function ConvertTo-EobUiDateText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][object]$Value,
        [switch]$WithTime
    )

    if ($null -eq $Value) { return '' }
    if ($Value -is [string] -and $Value.Trim() -eq '') { return '' }
    $date = if ($Value -is [datetime]) { $Value } else { ConvertTo-EobDate -Value ([string]$Value) }
    if ($null -eq $date) {
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) { $date = $parsed.ToLocalTime() }
    }
    if ($null -eq $date) { return [string]$Value }
    if ($WithTime) { return $date.ToString('dd.MM.yyyy HH:mm') }
    return $date.ToString('dd.MM.yyyy')
}

function ConvertTo-EobUiStepRow {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][pscustomobject]$Step)

    $status = if (-not $Step.Enabled -and $Step.Status -eq 'Planned') { 'Nur nach manueller Freigabe' } else { Get-EobUiText -Map $script:StatusTexts -Key $Step.Status }
    [pscustomobject]@{
        Id          = $Step.Id
        Phase       = [string]$Step.Phase
        PhaseText   = Get-EobUiText -Map $script:PhaseTexts -Key ([string]$Step.Phase)
        DueText     = ConvertTo-EobUiDateText -Value $Step.DueDate
        Title       = [string]$Step.Title
        Target      = [string]$Step.Target
        RiskText    = Get-EobUiText -Map $script:RiskTexts -Key ([string]$Step.Risk)
        DetailsText = (@($Step.Details) -join ' | ')
        StatusText  = $status
        Message     = [string]$Step.Message
    }
}

function ConvertTo-EobUiFindingRow {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][pscustomobject]$Finding)

    [pscustomobject]@{
        Severity     = [string]$Finding.Severity
        SeverityText = Get-EobUiText -Map $script:SeverityTexts -Key ([string]$Finding.Severity)
        Code         = [string]$Finding.Code
        Field        = [string]$Finding.Field
        Message      = [string]$Finding.Message
    }
}

function ConvertTo-EobUiSummaryRow {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowNull()][System.Collections.IDictionary]$Summary)

    if ($null -eq $Summary) { return }
    foreach ($key in $Summary.Keys) {
        [pscustomobject]@{ Key = [string]$key; Value = [string]$Summary[$key] }
    }
}

function ConvertTo-EobUiIntegrationRow {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][pscustomobject]$Status)

    [pscustomobject]@{
        Name               = [string]$Status.Name
        State              = [string]$Status.State
        StateText          = Get-EobUiText -Map $script:StateTexts -Key ([string]$Status.State)
        Detail             = [string]$Status.Detail
        Hint               = [string]$Status.Hint
        ImplementationText = Get-EobUiText -Map $script:ImplementationTexts -Key ([string]$Status.Implementation)
    }
}

function ConvertTo-EobUiQueueRow {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][pscustomobject]$Item)

    $note = ''
    if ($Item.DeletionDue) { $note = 'Löschung fällig: Freigabe erforderlich' }
    elseif ($Item.IsDue -and $Item.Privileged) { $note = 'Fällig: privilegiertes Konto, nur manuell' }
    elseif ($Item.IsDue -and @($Item.RequiresIntegration | Where-Object { $_ -eq $Item.NextPhase }).Count -gt 0) { $note = 'Fällig: benötigt Exchange/Graph' }
    elseif ($Item.IsDue) { $note = 'Fällig' }
    [pscustomobject]@{
        OperationId   = [string]$Item.OperationId
        Account       = if ($Item.DisplayName) { "$($Item.DisplayName) ($($Item.SamAccountName))" } else { [string]$Item.SamAccountName }
        Template      = [string]$Item.Template
        ExitText      = ConvertTo-EobUiDateText -Value $Item.ExitDate
        StatusText    = Get-EobUiText -Map $script:StatusTexts -Key ([string]$Item.Status)
        NextPhaseText = Get-EobUiText -Map $script:PhaseTexts -Key ([string]$Item.NextPhase)
        DueText       = ConvertTo-EobUiDateText -Value $Item.NextDueDate
        DeletionText  = ConvertTo-EobUiDateText -Value $Item.DeletionDate
        NoteText      = $note
        IsDue         = [bool]$Item.IsDue
        DeletionDue   = [bool]$Item.DeletionDue
        Item          = $Item
    }
}

function ConvertTo-EobUiUserRow {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][pscustomobject]$User)

    [pscustomobject]@{
        DisplayName       = [string]$User.DisplayName
        SamAccountName    = [string]$User.SamAccountName
        UserPrincipalName = [string]$User.UserPrincipalName
        Department        = [string]$User.Department
        EnabledText       = if ($User.Enabled) { 'ja' } else { 'nein' }
        LastLogonText     = ConvertTo-EobUiDateText -Value $User.LastLogonDate -WithTime
        User              = $User
    }
}

function Get-EobOnboardingFormRequestData {
    <#
    .SYNOPSIS
        Übersetzt Formularwerte des Onboarding-Assistenten in die Daten für ConvertTo-EobOnboardingRequest.
    .DESCRIPTION
        Kontoname, UPN-Präfix und lokaler Mailteil werden nur übergeben, wenn sie vom automatisch
        ermittelten Vorschlag abweichen (sonst ermittelt der Plan sie selbst inkl. Kollisionsprüfung).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Values,
        [hashtable]$AutoIdentity = @{}
    )

    $data = @{}
    foreach ($key in $Values.Keys) {
        if ($key -in @('SamAccountName', 'UserPrincipalNamePrefix', 'MailLocalPart')) { continue }
        $data[$key] = $Values[$key]
    }
    foreach ($key in @('SamAccountName', 'UserPrincipalNamePrefix', 'MailLocalPart')) {
        $value = ([string]$Values[$key]).Trim()
        $auto = [string]$AutoIdentity[$key]
        if ($value -and $value -cne $auto) { $data[$key] = $value }
    }
    foreach ($key in @('StartDate', 'ExpirationDate')) {
        if ($data[$key] -is [datetime]) { $data[$key] = ([datetime]$data[$key]).ToString('yyyy-MM-dd') }
    }
    return $data
}

function Get-EobOffboardingFormRequestData {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][hashtable]$Values)

    $assets = @(([string]$Values['AssetsText']) -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $exit = $Values['ExitDate']
    @{
        Identity              = [string]$Values['Identity']
        Template              = [string]$Values['Template']
        ExitDate              = if ($exit -is [datetime]) { ([datetime]$exit).ToString('yyyy-MM-dd') } else { [string]$exit }
        Ticket                = [string]$Values['Ticket']
        Reason                = [string]$Values['Reason']
        Notes                 = [string]$Values['Notes']
        ForwardTo             = [string]$Values['ForwardTo']
        AutoReplyMessage      = [string]$Values['AutoReplyMessage']
        Assets                = $assets
        AcknowledgePrivileged = [bool]$Values['AcknowledgePrivileged']
        AuthorizedHomeAccessAccount = [string]$Values['AuthorizedHomeAccessAccount']
    }
}

function Test-EobGuiEnvironment {
    <#
    .SYNOPSIS
        Prüft, ob die Oberfläche gestartet werden kann (Windows, STA-Thread).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    if (-not $IsWindows) {
        return [pscustomobject]@{ IsSupported = $false; Reason = 'Die Oberfläche benötigt Windows (WPF). Auf anderen Systemen steht nur die Prüfung mit -CheckOnly zur Verfügung.' }
    }
    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
        return [pscustomobject]@{ IsSupported = $false; Reason = 'Die Oberfläche benötigt einen STA-Thread. Bitte mit "pwsh -STA -File .\Start-easyONBOARDING.ps1" starten.' }
    }
    return [pscustomobject]@{ IsSupported = $true; Reason = '' }
}

#endregion

#region WPF-Grundlagen

function Import-EobWpfAssembly {
    [CmdletBinding()]
    param()

    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
}

function Import-EobXaml {
    <#
    .SYNOPSIS
        Lädt eine XAML-Datei der Oberfläche als WPF-Objekt.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter(Mandatory)][string]$RelativePath)

    $text = Get-EobXamlText -RelativePath $RelativePath
    try {
        return [System.Windows.Markup.XamlReader]::Parse($text)
    }
    catch {
        $inner = if ($null -ne $_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
        throw "XAML '$RelativePath' konnte nicht geladen werden: $inner"
    }
}

function Get-EobXamlControlMap {
    <#
    .SYNOPSIS
        Löst benannte Steuerelemente auf; fehlende Namen führen zu einem Fehler.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][object]$Root,
        [Parameter(Mandatory)][string[]]$Names
    )

    $map = @{}
    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $Names) {
        $control = $Root.FindName($name)
        if ($null -eq $control) { $missing.Add($name) } else { $map[$name] = $control }
    }
    if ($missing.Count -gt 0) {
        throw ('Steuerelemente nicht gefunden: ' + ($missing -join ', '))
    }
    return $map
}

function Import-EobXamlWithControl {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$RelativePath)

    $root = Import-EobXaml -RelativePath $RelativePath
    $names = @(Get-EobXamlElementName -Xaml (Get-EobXamlText -RelativePath $RelativePath))
    [pscustomobject]@{ Root = $root; Controls = (Get-EobXamlControlMap -Root $root -Names $names) }
}

function Get-EobResource {
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter(Mandatory)][string]$Key)

    return [System.Windows.Application]::Current.FindResource($Key)
}

function Set-EobBrush {
    <#
    .SYNOPSIS
        Setzt eine Farbeigenschaft als dynamische Ressource (folgt dem Farbschema).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Element,
        [Parameter(Mandatory)][ValidateSet('Background', 'Foreground', 'BorderBrush', 'Fill')][string]$Property,
        [Parameter(Mandatory)][string]$Key
    )

    $field = $Element.GetType().GetField("${Property}Property", [System.Reflection.BindingFlags]'Public, Static, FlattenHierarchy')
    if ($null -eq $field) { throw "Eigenschaft $Property wird von $($Element.GetType().Name) nicht unterstützt." }
    $Element.SetResourceReference($field.GetValue($null), $Key)
}

function Initialize-EobApplication {
    <#
    .SYNOPSIS
        Legt die WPF-Anwendung an (einmal je Sitzung) und lädt Farbschema und Styles.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Light', 'Dark')][string]$Theme = 'Light',
        [string]$AccentColor
    )

    $application = [System.Windows.Application]::Current
    if ($null -eq $application) {
        $application = [System.Windows.Application]::new()
        $application.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
    }
    $application.Resources.MergedDictionaries.Clear()
    $application.Resources.MergedDictionaries.Add((Import-EobXaml -RelativePath "Styles/Theme.$Theme.xaml"))
    $application.Resources.MergedDictionaries.Add((Import-EobXaml -RelativePath 'Styles/Controls.xaml'))
    $script:Ui.Application = $application
    $script:Ui.ThemeIndex = 0
    Set-EobTheme -Theme $Theme -AccentColor $AccentColor
}

function Set-EobTheme {
    <#
    .SYNOPSIS
        Wechselt das Farbschema zur Laufzeit und setzt die Akzentfarbe.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Light', 'Dark')][string]$Theme = 'Light',
        [string]$AccentColor
    )

    $dictionary = Import-EobXaml -RelativePath "Styles/Theme.$Theme.xaml"
    if ($AccentColor -match '^#[0-9A-Fa-f]{6}$') {
        $palette = Get-EobAccentPalette -Color $AccentColor -Theme $Theme
        $convert = { param([string]$Hex) [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString($Hex)) }
        $dictionary['AccentBrush'] = & $convert $palette.Accent
        $dictionary['AccentHoverBrush'] = & $convert $palette.Hover
        $dictionary['AccentForegroundBrush'] = & $convert $palette.Foreground
    }
    $merged = $script:Ui.Application.Resources.MergedDictionaries
    $merged[$script:Ui.ThemeIndex] = $dictionary
    $script:Ui.Theme = $Theme
    $script:Ui.AccentColor = $AccentColor
}

function Invoke-EobUiSafely {
    <#
    .SYNOPSIS
        Führt eine Oberflächenaktion aus; Fehler werden protokolliert und angezeigt statt abzustürzen.
    .PARAMETER Quiet
        Nur protokollieren (z. B. für Zeitgeber).
    .PARAMETER Busy
        Wartecursor während der Aktion.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action,
        [object]$Argument,
        [switch]$Quiet,
        [switch]$Busy
    )

    $cursorSet = $false
    try {
        if ($Busy -and $null -eq [System.Windows.Input.Mouse]::OverrideCursor) {
            [System.Windows.Input.Mouse]::OverrideCursor = [System.Windows.Input.Cursors]::Wait
            $cursorSet = $true
            [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([System.Action] {}, [System.Windows.Threading.DispatcherPriority]::Render)
        }
        if ($PSBoundParameters.ContainsKey('Argument')) { $null = & $Action $Argument } else { $null = & $Action }
    }
    catch {
        $message = Protect-EobSensitiveText -Text $_.Exception.Message
        Write-EobLog -Level Error -Action 'UI' -Target $Name -Message "Fehler bei '$Name': $message" -ErrorRecord $_
        if ($cursorSet) { [System.Windows.Input.Mouse]::OverrideCursor = $null; $cursorSet = $false }
        if (-not $Quiet) {
            try {
                $null = Show-EobDialog -Title 'Fehler' -Message "Bei der Aktion '$Name' ist ein Fehler aufgetreten." -Details @($message) -Kind Error
            }
            catch {
                $null = [System.Windows.MessageBox]::Show("$Name`n`n$message", 'easyONBOARDING', 'OK', 'Error')
            }
        }
    }
    finally {
        if ($cursorSet) { [System.Windows.Input.Mouse]::OverrideCursor = $null }
    }
}

function Set-EobComboSource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Combo,
        [AllowEmptyCollection()][object[]]$Items = @(),
        [AllowNull()][AllowEmptyString()][string]$SelectedValue
    )

    $Combo.Items.Clear()
    foreach ($item in $Items) {
        $entry = [System.Windows.Controls.ComboBoxItem]::new()
        $entry.Content = [string]$item.Text
        $entry.Tag = $item.Value
        if ($item.PSObject.Properties['ToolTip'] -and $item.ToolTip) { $entry.ToolTip = [string]$item.ToolTip }
        $null = $Combo.Items.Add($entry)
        if ($null -ne $SelectedValue -and [string]$item.Value -eq $SelectedValue) { $Combo.SelectedItem = $entry }
    }
    if ($null -eq $Combo.SelectedItem -and $Combo.Items.Count -gt 0) { $Combo.SelectedIndex = 0 }
}

function Get-EobComboValue {
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter(Mandatory)][object]$Combo)

    if ($null -ne $Combo.SelectedItem) { return $Combo.SelectedItem.Tag }
    return $null
}

function Set-EobListSource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$List,
        [AllowEmptyCollection()][object[]]$Items = @()
    )

    $List.Items.Clear()
    foreach ($item in $Items) {
        $entry = [System.Windows.Controls.ListBoxItem]::new()
        $entry.Content = [string]$item.Text
        $entry.Tag = $item.Value
        if ($item.PSObject.Properties['ToolTip'] -and $item.ToolTip) { $entry.ToolTip = [string]$item.ToolTip }
        $null = $List.Items.Add($entry)
    }
}

function Get-EobListSelection {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][object]$List)

    return @($List.SelectedItems | ForEach-Object { $_.Tag })
}

function Set-EobFieldError {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Control,
        [AllowEmptyString()][string]$Message = ''
    )

    if ($null -eq $Control) { return }
    $Control.Text = $Message
    $Control.Visibility = if ($Message) { 'Visible' } else { 'Collapsed' }
}

function Set-EobBanner {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Border,
        [Parameter(Mandatory)][object]$TextBlock,
        [ValidateSet('Info', 'Warning', 'Error', 'Success')][string]$Kind = 'Info',
        [AllowEmptyString()][string]$Text = ''
    )

    $Border.Style = Get-EobResource -Key "$($Kind)BannerStyle"
    $TextBlock.Text = $Text
    $Border.Visibility = if ($Text) { 'Visible' } else { 'Collapsed' }
}

function Set-EobGridSource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Grid,
        [AllowEmptyCollection()][AllowNull()][object[]]$Items = @()
    )

    $Grid.ItemsSource = $null
    $Grid.ItemsSource = @($Items | Where-Object { $null -ne $_ })
}

function Open-EobPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { throw "Pfad nicht gefunden: $Path" }
    Invoke-Item -LiteralPath $Path
}

function Open-EobUrl {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Url)

    if ($Url -notmatch '^https://[^\s]+$') { throw 'Es werden nur https-Links geöffnet.' }
    Start-Process -FilePath $Url
}

function Select-EobOpenFile {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$Filter = 'Alle Dateien (*.*)|*.*',
        [string]$Title = 'Datei auswählen',
        [string]$InitialDirectory
    )

    $dialog = [Microsoft.Win32.OpenFileDialog]::new()
    $dialog.Filter = $Filter
    $dialog.Title = $Title
    $dialog.CheckFileExists = $true
    if ($InitialDirectory -and (Test-Path -LiteralPath $InitialDirectory)) { $dialog.InitialDirectory = $InitialDirectory }
    if ($dialog.ShowDialog($script:Ui.Window)) { return $dialog.FileName }
    return ''
}

function Select-EobSaveFile {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$Filter = 'Alle Dateien (*.*)|*.*',
        [string]$Title = 'Speichern unter',
        [string]$FileName = '',
        [string]$InitialDirectory
    )

    $dialog = [Microsoft.Win32.SaveFileDialog]::new()
    $dialog.Filter = $Filter
    $dialog.Title = $Title
    $dialog.FileName = $FileName
    $dialog.OverwritePrompt = $true
    if ($InitialDirectory -and (Test-Path -LiteralPath $InitialDirectory)) { $dialog.InitialDirectory = $InitialDirectory }
    if ($dialog.ShowDialog($script:Ui.Window)) { return $dialog.FileName }
    return ''
}

#endregion

#region Dialoge

function Show-EobDialog {
    <#
    .SYNOPSIS
        Zentraler Meldungs- und Bestätigungsdialog.
    .PARAMETER TypedConfirmation
        Text, der zur Bestätigung exakt eingegeben werden muss (z. B. "LÖSCHEN mmuster").
    .PARAMETER InputPrompt
        Fordert eine Pflichteingabe an (z. B. Begründung); der Text wird zurückgegeben.
    .OUTPUTS
        Objekt mit Confirmed (bool) und Text.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ValidateSet('Info', 'Warning', 'Error', 'Question', 'Danger', 'Success')][string]$Kind = 'Info',
        [AllowEmptyCollection()][string[]]$Details = @(),
        [string]$ConfirmText = 'OK',
        [string]$CancelText = '',
        [string]$TypedConfirmation = '',
        [string]$InputPrompt = ''
    )

    if ($null -ne $script:Ui -and $script:Ui.Headless) {
        $script:Ui.DialogLog.Add("[$Kind] $($Title): $Message $($Details -join ' | ')".TrimEnd())
        return [pscustomobject]@{ Confirmed = $false; Text = '' }
    }
    $loaded = Import-EobXamlWithControl -RelativePath 'Dialogs/ConfirmDialog.xaml'
    $dialog = $loaded.Root
    $c = $loaded.Controls
    if ($null -ne $script:Ui -and $null -ne $script:Ui.Window -and $script:Ui.Window.IsLoaded) { $dialog.Owner = $script:Ui.Window }
    else { $dialog.WindowStartupLocation = 'CenterScreen' }
    $dialog.Title = "easyONBOARDING - $Title"
    $c.DlgTitleText.Text = $Title
    $c.DlgMessageText.Text = $Message

    $glyph = @{ Info = [char]0xE946; Warning = [char]0xE7BA; Error = [char]0xEA39; Question = [char]0xE9CE; Danger = [char]0xE7BA; Success = [char]0xE930 }
    $brush = @{ Info = 'InfoBrush'; Warning = 'WarningBrush'; Error = 'ErrorBrush'; Question = 'AccentBrush'; Danger = 'ErrorBrush'; Success = 'SuccessBrush' }
    $c.DlgIcon.Text = [string]$glyph[$Kind]
    Set-EobBrush -Element $c.DlgIcon -Property Foreground -Key $brush[$Kind]

    if ($Details.Count -gt 0) {
        $c.DlgDetailsList.ItemsSource = @($Details | ForEach-Object { [char]0x2022 + ' ' + $_ })
        $c.DlgDetailsList.Visibility = 'Visible'
    }
    $c.DlgConfirmButton.Content = $ConfirmText
    if ($Kind -eq 'Danger') { $c.DlgConfirmButton.Style = Get-EobResource -Key 'DangerButtonStyle' }
    if ($CancelText) {
        $c.DlgCancelButton.Content = $CancelText
    }
    else {
        $c.DlgCancelButton.Visibility = 'Collapsed'
        $c.DlgCancelButton.IsDefault = $false
        $c.DlgCancelButton.IsCancel = $false
        $c.DlgConfirmButton.IsDefault = $true
        $dialog.Add_PreviewKeyDown({
                param($source, $e)
                if ($e.Key -eq [System.Windows.Input.Key]::Escape) { $e.Handled = $true; $source.Close() }
            })
    }

    $state = @{ Mode = 'None'; Expected = '' }
    if ($TypedConfirmation) {
        $state = @{ Mode = 'Typed'; Expected = $TypedConfirmation }
        $c.DlgTypedHintText.Text = "Zur Bestätigung bitte exakt eingeben:  $TypedConfirmation"
    }
    elseif ($InputPrompt) {
        $state = @{ Mode = 'Input'; Expected = '' }
        $c.DlgTypedHintText.Text = $InputPrompt
    }
    if ($state.Mode -ne 'None') {
        $c.DlgTypedPanel.Visibility = 'Visible'
        $c.DlgConfirmButton.IsEnabled = $false
        $c.DlgTypedText.Add_TextChanged({
                $window = [System.Windows.Window]::GetWindow($this)
                $mode = $window.Tag
                $button = $window.FindName('DlgConfirmButton')
                if ($mode.Mode -eq 'Typed') { $button.IsEnabled = ($this.Text -ceq $mode.Expected) }
                else { $button.IsEnabled = -not [string]::IsNullOrWhiteSpace($this.Text) }
            })
        $dialog.Add_Loaded({ $null = $this.FindName('DlgTypedText').Focus() })
    }
    $dialog.Tag = $state
    $c.DlgConfirmButton.Add_Click({ [System.Windows.Window]::GetWindow($this).DialogResult = $true })

    $result = $dialog.ShowDialog()
    [pscustomobject]@{ Confirmed = [bool]$result; Text = [string]$c.DlgTypedText.Text }
}

function Get-EobTextHash {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string]$Text)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return [Convert]::ToHexString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))) }
    finally { $sha.Dispose() }
}

function Set-EobClipboardSecret {
    <#
    .SYNOPSIS
        Kopiert ein Kennwort in die Zwischenablage (ohne Verlauf/Cloud-Synchronisation) und leert sie zeitgesteuert.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Text,
        [ValidateRange(5, 600)][int]$Seconds = 30
    )

    $data = [System.Windows.DataObject]::new()
    $data.SetText($Text)
    $zero = [BitConverter]::GetBytes([int]0)
    $data.SetData('ExcludeClipboardContentFromMonitorProcessing', [System.IO.MemoryStream]::new($zero))
    $data.SetData('CanIncludeInClipboardHistory', [System.IO.MemoryStream]::new($zero))
    $data.SetData('CanUploadToCloudClipboard', [System.IO.MemoryStream]::new($zero))
    [System.Windows.Clipboard]::SetDataObject($data, $true)
    $script:Ui.ClipboardHash = Get-EobTextHash -Text $Text

    if ($null -ne $script:Ui.ClipboardTimer) { $script:Ui.ClipboardTimer.Stop() }
    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromSeconds($Seconds)
    $timer.Add_Tick({ Invoke-EobUiSafely -Name 'Zwischenablage leeren' -Quiet -Action { Clear-EobClipboardSecret } })
    $script:Ui.ClipboardTimer = $timer
    $timer.Start()
    Write-EobLog -Level Information -Action 'CredentialCopied' -Message "Kennwort in die Zwischenablage kopiert (Leerung nach $Seconds s)."
}

function Clear-EobClipboardSecret {
    [CmdletBinding()]
    param()

    if ($null -eq $script:Ui) { return }
    if ($null -ne $script:Ui.ClipboardTimer) {
        $script:Ui.ClipboardTimer.Stop()
        $script:Ui.ClipboardTimer = $null
    }
    if (-not $script:Ui.ClipboardHash) { return }
    try {
        if ([System.Windows.Clipboard]::ContainsText() -and (Get-EobTextHash -Text ([System.Windows.Clipboard]::GetText())) -eq $script:Ui.ClipboardHash) {
            [System.Windows.Clipboard]::Clear()
        }
    }
    catch {
        Write-EobLog -Level Warning -Action 'ClipboardClear' -Message "Zwischenablage konnte nicht geleert werden: $($_.Exception.Message)"
    }
    $script:Ui.ClipboardHash = $null
}

function Invoke-EobCredentialPrint {
    <#
    .SYNOPSIS
        Druckt Zugangsdatenblätter direkt aus dem Speicher (keine Datei, kein Protokoll des Kennworts).
    .PARAMETER Entries
        Objekte mit Name, SamAccountName, UserPrincipalName und Password (SecureString).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][object[]]$Entries)

    $printDialog = [System.Windows.Controls.PrintDialog]::new()
    if (-not $printDialog.ShowDialog()) { return $false }
    $document = [System.Windows.Documents.FlowDocument]::new()
    $document.FontFamily = [System.Windows.Media.FontFamily]::new('Segoe UI')
    $document.FontSize = 14
    $document.PagePadding = [System.Windows.Thickness]::new(64)
    $document.PageWidth = $printDialog.PrintableAreaWidth
    $document.PageHeight = $printDialog.PrintableAreaHeight
    $document.ColumnWidth = $printDialog.PrintableAreaWidth
    $first = $true
    foreach ($entry in $Entries) {
        $heading = [System.Windows.Documents.Paragraph]::new([System.Windows.Documents.Run]::new('Zugangsdaten'))
        $heading.FontSize = 24
        $heading.FontWeight = [System.Windows.FontWeights]::SemiBold
        if (-not $first) { $heading.BreakPageBefore = $true }
        $document.Blocks.Add($heading)
        foreach ($line in @("Name: $($entry.Name)", "Anmeldename: $($entry.SamAccountName)", "Anmeldung: $($entry.UserPrincipalName)")) {
            $document.Blocks.Add([System.Windows.Documents.Paragraph]::new([System.Windows.Documents.Run]::new($line)))
        }
        $passwordParagraph = [System.Windows.Documents.Paragraph]::new()
        $passwordParagraph.Inlines.Add([System.Windows.Documents.Run]::new('Kennwort: '))
        $passwordRun = [System.Windows.Documents.Run]::new((ConvertTo-EobPlainText -SecureString $entry.Password))
        $passwordRun.FontFamily = [System.Windows.Media.FontFamily]::new('Consolas')
        $passwordRun.FontSize = 18
        $passwordParagraph.Inlines.Add($passwordRun)
        $document.Blocks.Add($passwordParagraph)
        $hint = [System.Windows.Documents.Paragraph]::new([System.Windows.Documents.Run]::new('Bitte ändern Sie das Kennwort bei der ersten Anmeldung. Dieses Blatt nach der Übergabe sicher vernichten.'))
        $hint.FontSize = 12
        $document.Blocks.Add($hint)
        $first = $false
    }
    $paginator = ([System.Windows.Documents.IDocumentPaginatorSource]$document).DocumentPaginator
    $printDialog.PrintDocument($paginator, 'easyONBOARDING Zugangsdaten')
    $document.Blocks.Clear()
    Write-EobLog -Level Audit -Action 'CredentialPrinted' -Target (($Entries | ForEach-Object SamAccountName) -join ', ') `
        -Message "$(@($Entries).Count) Zugangsdatenblatt/-blätter gedruckt (ohne Speicherung)."
    return $true
}

function Show-EobCredentialDialog {
    <#
    .SYNOPSIS
        Zeigt Zugangsdaten einmalig an (Kopieren mit automatischer Leerung, Drucken aus dem Speicher).
    #>
    [CmdletBinding()]
    param(
        [string]$DisplayName = '',
        [string]$SamAccountName = '',
        [string]$UserPrincipalName = '',
        [Parameter(Mandatory)][System.Security.SecureString]$Password
    )

    if ($script:Ui.Headless) {
        $script:Ui.DialogLog.Add("[Credential] Zugangsdaten für $SamAccountName (Anzeige im Testmodus unterdrückt)")
        return
    }
    $config = $script:Ui.Config
    $clearSeconds = [int](Get-EobConfigValue -Config $config -Section 'Security' -Key 'ClipboardClearSeconds' -As Int)
    $allowPrint = [bool](Get-EobConfigValue -Config $config -Section 'Security' -Key 'AllowCredentialPrint' -As Bool)
    $loaded = Import-EobXamlWithControl -RelativePath 'Dialogs/CredentialDialog.xaml'
    $dialog = $loaded.Root
    $c = $loaded.Controls
    if ($null -ne $script:Ui.Window -and $script:Ui.Window.IsLoaded) { $dialog.Owner = $script:Ui.Window }
    $c.CredNameText.Text = $DisplayName
    $c.CredUserText.Text = $SamAccountName
    $c.CredUpnText.Text = $UserPrincipalName
    $c.CredPasswordText.Text = ConvertTo-EobPlainText -SecureString $Password
    $c.CredHintText.Text = 'Nach dem Schließen ist das Kennwort nicht mehr abrufbar.'
    if ($clearSeconds -le 0) {
        $c.CredCopyButton.Visibility = 'Collapsed'
    }
    else {
        $c.CredClipboardText.Text = "Zwischenablage wird nach $clearSeconds s geleert (ohne Verlauf)."
    }
    if (-not $allowPrint) { $c.CredPrintButton.Visibility = 'Collapsed' }
    $dialog.Tag = @{ ClearSeconds = [Math]::Max(5, $clearSeconds); Password = $Password; Name = $DisplayName; Sam = $SamAccountName; Upn = $UserPrincipalName }

    $c.CredCopyButton.Add_Click({
            Invoke-EobUiSafely -Name 'Kennwort kopieren' -Argument ([System.Windows.Window]::GetWindow($this)) -Action {
                param($window)
                Set-EobClipboardSecret -Text $window.FindName('CredPasswordText').Text -Seconds $window.Tag.ClearSeconds
                $window.FindName('CredClipboardText').Text = "Kopiert. Die Zwischenablage wird in $($window.Tag.ClearSeconds) Sekunden geleert."
            }
        })
    $c.CredPrintButton.Add_Click({
            Invoke-EobUiSafely -Name 'Zugangsdaten drucken' -Argument ([System.Windows.Window]::GetWindow($this)) -Action {
                param($window)
                $tag = $window.Tag
                $null = Invoke-EobCredentialPrint -Entries @([pscustomobject]@{ Name = $tag.Name; SamAccountName = $tag.Sam; UserPrincipalName = $tag.Upn; Password = $tag.Password })
            }
        })
    try {
        $null = $dialog.ShowDialog()
    }
    finally {
        $c.CredPasswordText.Text = ''
        $dialog.Tag = $null
    }
    Write-EobLog -Level Audit -Action 'CredentialDisplayed' -Target $SamAccountName -Message 'Zugangsdaten einmalig angezeigt.'
}

#endregion

#region Hauptfenster, Navigation und Status

function Start-EobGui {
    <#
    .SYNOPSIS
        Startet die Oberfläche (blockiert bis zum Schließen des Fensters).
    .PARAMETER ForceSimulation
        Startet unabhängig von der Konfiguration im Simulationsmodus.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [string]$ConfigPath,
        [switch]$ForceSimulation,
        [ValidateSet('', 'Light', 'Dark')][string]$Theme = ''
    )

    $environment = Test-EobGuiEnvironment
    if (-not $environment.IsSupported) { throw $environment.Reason }
    Import-EobWpfAssembly

    $script:Ui = New-EobUiState
    $script:Ui.Config = $Config
    $script:Ui.ConfigPath = if ($ConfigPath) { $ConfigPath } else { [string]$Config.Path }
    # Mit Fehlern in der Konfiguration startet die Oberfläche immer in der Simulation.
    $script:Ui.Simulation = [bool]$ForceSimulation -or [bool](Get-EobConfigValue -Config $Config -Section 'Security' -Key 'SimulationByDefault' -As Bool) -or
    @(Get-EobUiConfigError -Config $Config).Count -gt 0
    if (-not $Theme) { $Theme = [string](Get-EobConfigValue -Config $Config -Section 'UI' -Key 'Theme') }
    if ($Theme -notin @('Light', 'Dark')) { $Theme = 'Light' }
    Initialize-EobApplication -Theme $Theme -AccentColor ([string](Get-EobConfigValue -Config $Config -Section 'UI' -Key 'AccentColor'))

    $loaded = Import-EobXamlWithControl -RelativePath 'MainWindow.xaml'
    $script:Ui.Window = $loaded.Root
    $script:Ui.C = $loaded.Controls
    Set-EobWindowBound -Window $script:Ui.Window
    Initialize-EobMainWindow
    Show-EobView -Name 'Dashboard'
    Start-EobLogPump
    Write-EobLog -Level Information -Action 'GuiStarted' -Message ('Oberfläche gestartet (Simulation: {0}, Farbschema: {1}).' -f $script:Ui.Simulation, $Theme)
    try {
        $null = $script:Ui.Window.ShowDialog()
    }
    finally {
        Stop-EobUi
    }
}

function Get-EobWindowBound {
    <#
    .SYNOPSIS
        Begrenzt Fenster- und Mindestgröße auf die Arbeitsfläche (Bildschirm ohne Taskleiste).
    .DESCRIPTION
        Ausgelegt ist die Oberfläche auf 1400 x 900. Auf kleineren Arbeitsflächen (z. B. 1366 x 768
        oder bei Anzeigeskalierung) wird das Fenster verkleinert, damit es vollständig sichtbar bleibt.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][double]$Width,
        [Parameter(Mandatory)][double]$Height,
        [Parameter(Mandatory)][double]$MinWidth,
        [Parameter(Mandatory)][double]$MinHeight,
        [Parameter(Mandatory)][double]$WorkAreaWidth,
        [Parameter(Mandatory)][double]$WorkAreaHeight
    )

    $newWidth = [Math]::Min($Width, $WorkAreaWidth)
    $newHeight = [Math]::Min($Height, $WorkAreaHeight)
    [pscustomobject]@{
        Width     = $newWidth
        Height    = $newHeight
        MinWidth  = [Math]::Min($MinWidth, $newWidth)
        MinHeight = [Math]::Min($MinHeight, $newHeight)
    }
}

function Set-EobWindowBound {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Window)

    $workArea = [System.Windows.SystemParameters]::WorkArea
    if ($workArea.Width -le 0 -or $workArea.Height -le 0) { return }
    $bound = Get-EobWindowBound -Width $Window.Width -Height $Window.Height -MinWidth $Window.MinWidth -MinHeight $Window.MinHeight `
        -WorkAreaWidth $workArea.Width -WorkAreaHeight $workArea.Height
    $Window.MinWidth = $bound.MinWidth
    $Window.MinHeight = $bound.MinHeight
    $Window.Width = $bound.Width
    $Window.Height = $bound.Height
}

function Stop-EobUi {
    [CmdletBinding()]
    param()

    if ($null -eq $script:Ui) { return }
    foreach ($timer in @($script:Ui.LogTimer, $script:Ui.ClipboardTimer)) { if ($null -ne $timer) { $timer.Stop() } }
    if ($null -ne $script:Ui.Execution -and $null -ne $script:Ui.Execution.Timer) { $script:Ui.Execution.Timer.Stop() }
    Clear-EobClipboardSecret
    foreach ($state in @($script:Ui.Onboarding, $script:Ui.Offboarding, $script:Ui.Update)) {
        if ($state -is [hashtable] -and $null -ne $state['Plan']) {
            try { Clear-EobPlanSecret -Plan $state['Plan'] -Confirm:$false } catch { Write-Verbose $_.Exception.Message }
        }
    }
    Clear-EobUiBulkSecret
    if ($script:Ui.Bulk -is [hashtable] -and $null -ne $script:Ui.Bulk['Credentials']) {
        foreach ($entry in @($script:Ui.Bulk['Credentials'])) { if ($entry.Password -is [securestring]) { $entry.Password.Dispose() } }
        $script:Ui.Bulk['Credentials'] = $null
    }
    Write-EobLog -Level Information -Action 'GuiClosed' -Message 'Oberfläche beendet.'
}

function Initialize-EobMainWindow {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'source', Justification = 'Signatur von WPF-Ereignishandlern (Sender, EventArgs); der Sender wird nicht benötigt.')]
    [CmdletBinding()]
    param()

    $c = $script:Ui.C
    $config = $script:Ui.Config
    $appName = [string](Get-EobConfigValue -Config $config -Section 'WPFGUI' -Key 'APPName')
    if (-not $appName) { $appName = 'easyONBOARDING' }
    $c.HeaderTitle.Text = $appName
    $script:Ui.Window.Title = "$appName $(Get-EobVersion)"
    $company = Get-EobCompany -Config $config | Select-Object -First 1
    $configName = if ($script:Ui.ConfigPath) { Split-Path -Leaf $script:Ui.ConfigPath } else { '-' }
    $c.HeaderSubtitle.Text = if ($null -ne $company) { "$($company.DisplayName)  ·  Konfiguration: $configName" } else { "Konfiguration: $configName" }
    $footer = [string](Get-EobConfigValue -Config $config -Section 'WPFGUI' -Key 'FooterText')
    $c.NavFooterText.Text = (@($footer, "Version $(Get-EobVersion)") | Where-Object { $_ }) -join "`n"

    $logo = [string](Get-EobConfigValue -Config $config -Section 'UI' -Key 'LogoPath' -As Path)
    if ($logo -and (Test-Path -LiteralPath $logo -PathType Leaf) -and [System.IO.Path]::GetExtension($logo) -in @('.png', '.jpg', '.jpeg')) {
        try {
            $bitmap = [System.Windows.Media.Imaging.BitmapImage]::new()
            $bitmap.BeginInit()
            $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $bitmap.UriSource = [System.Uri]::new($logo, [System.UriKind]::Absolute)
            $bitmap.EndInit()
            $c.HeaderLogo.Source = $bitmap
            $c.HeaderLogo.Visibility = 'Visible'
            $logoUrl = [string](Get-EobConfigValue -Config $config -Section 'WPFGUI' -Key 'LogoURL')
            if ($logoUrl -match '^https://') {
                $c.HeaderLogo.Cursor = [System.Windows.Input.Cursors]::Hand
                $c.HeaderLogo.Tag = $logoUrl
                $c.HeaderLogo.Add_MouseLeftButtonUp({ Invoke-EobUiSafely -Name 'Logo-Link' -Argument ([string]$this.Tag) -Action { param($url) Open-EobUrl -Url $url } })
            }
        }
        catch {
            Write-EobLog -Level Warning -Action 'UI' -Message "Logo konnte nicht geladen werden: $($_.Exception.Message)"
        }
    }

    foreach ($name in $script:ViewDefinitions.Keys) {
        $nav = $c[$script:ViewDefinitions[$name].Nav]
        $nav.Add_Checked({ Invoke-EobUiSafely -Name 'Navigation' -Busy -Argument ([string]$this.Tag) -Action { param($view) Show-EobView -Name $view } })
    }
    $c.ModeToggleButton.Add_Click({ Invoke-EobUiSafely -Name 'Modus wechseln' -Action { Switch-EobExecutionMode } })
    $c.ThemeToggleButton.Add_Click({
            Invoke-EobUiSafely -Name 'Farbschema wechseln' -Action {
                $next = if ($script:Ui.Theme -eq 'Dark') { 'Light' } else { 'Dark' }
                Set-EobTheme -Theme $next -AccentColor $script:Ui.AccentColor
            }
        })
    $script:Ui.Window.Add_PreviewKeyDown({
            param($source, $e)
            if (([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -eq 0) { return }
            $key = [string]$e.Key
            if ($key -match '^(D|NumPad)([1-9])$') {
                $index = [int]$Matches[2] - 1
                $names = @($script:ViewDefinitions.Keys)
                if ($index -lt $names.Count) {
                    $e.Handled = $true
                    Invoke-EobUiSafely -Name 'Navigation' -Busy -Argument $names[$index] -Action { param($view) Show-EobView -Name $view }
                }
            }
        })
    $script:Ui.Window.Add_Closing({
            param($source, $e)
            if ($null -ne $script:Ui.Execution) {
                $e.Cancel = $true
                $null = Show-EobDialog -Title 'Ausführung läuft' -Kind Warning -Message 'Bitte warten Sie, bis die Ausführung abgeschlossen ist, oder brechen Sie sie zuerst ab.'
                return
            }
            if ($script:Ui.Onboarding.CredentialPending) {
                $answer = Show-EobDialog -Title 'Zugangsdaten nicht angezeigt' -Kind Warning -ConfirmText 'Trotzdem schließen' -CancelText 'Zurück' `
                    -Message 'Die Zugangsdaten des zuletzt angelegten Kontos wurden noch nicht angezeigt. Nach dem Schließen ist das Kennwort nicht mehr verfügbar und muss zurückgesetzt werden.'
                if (-not $answer.Confirmed) { $e.Cancel = $true }
            }
        })
    Update-EobModeDisplay
    Update-EobStatusBar
}

function Switch-EobExecutionMode {
    [CmdletBinding()]
    param()

    if ($null -ne $script:Ui.Execution) { return }
    if ($script:Ui.Simulation) {
        $errors = @(Get-EobUiConfigError -Config $script:Ui.Config)
        if ($errors.Count -gt 0) {
            $null = Show-EobDialog -Title 'Live-Modus nicht möglich' -Kind Error -Details $errors `
                -Message "Die Konfiguration enthält $($errors.Count) Fehler. Bitte zuerst beheben (Einstellungen bzw. Start-easyONBOARDING.ps1 -CheckOnly) und die Konfiguration neu laden."
            return
        }
        $answer = Show-EobDialog -Title 'Live-Modus aktivieren' -Kind Danger -ConfirmText '_Live-Modus aktivieren' -CancelText 'In der Simulation bleiben' `
            -Message 'Im Live-Modus werden Änderungen an Active Directory, Exchange, Microsoft 365 und Dateisystem tatsächlich ausgeführt. Jede Ausführung wird vorher als Vorschau angezeigt und muss bestätigt werden.'
        if (-not $answer.Confirmed) { return }
        $script:Ui.Simulation = $false
        Write-EobLog -Level Audit -Action 'ExecutionModeChanged' -Result 'Live' -Message 'Live-Modus aktiviert.'
    }
    else {
        $script:Ui.Simulation = $true
        Write-EobLog -Level Information -Action 'ExecutionModeChanged' -Result 'Simulation' -Message 'Simulationsmodus aktiviert.'
    }
    Update-EobModeDisplay
    if ($script:Ui.CurrentView -eq 'Dashboard') { Update-EobDashboardView }
}

function Update-EobModeDisplay {
    [CmdletBinding()]
    param()

    $c = $script:Ui.C
    if ($script:Ui.Simulation) {
        $c.ModeBadgeText.Text = 'Simulation'
        Set-EobBrush -Element $c.ModeBadge -Property Background -Key 'WarningBackgroundBrush'
        Set-EobBrush -Element $c.ModeBadge -Property BorderBrush -Key 'WarningBrush'
        $c.SimulationBanner.Visibility = 'Visible'
        $c.ModeToggleButton.Content = 'Live-Modus aktivieren'
    }
    else {
        $c.ModeBadgeText.Text = 'LIVE'
        Set-EobBrush -Element $c.ModeBadge -Property Background -Key 'ErrorBackgroundBrush'
        Set-EobBrush -Element $c.ModeBadge -Property BorderBrush -Key 'ErrorBrush'
        $c.SimulationBanner.Visibility = 'Collapsed'
        $c.ModeToggleButton.Content = 'Zur Simulation wechseln'
    }
    foreach ($button in @('OnbExecuteButton', 'OffExecuteButton')) {
        if ($null -ne $c[$button]) { $c[$button].Content = if ($script:Ui.Simulation) { 'Simulation _ausführen' } else { '_Ausführen' } }
    }
}

function Update-EobStatusBar {
    [CmdletBinding()]
    param()

    $c = $script:Ui.C
    $info = Get-EobAdConnectionInfo
    if ($info.Connected) {
        $domain = [string](Get-EobPropertyValue -InputObject $info.Domain -Name 'DnsRoot' -Default '')
        $c.StatusAdText.Text = "AD: $($info.Server)$(if ($domain) { " ($domain)" })"
        Set-EobBrush -Element $c.StatusAdIndicator -Property Fill -Key 'SuccessBrush'
    }
    else {
        $reason = if (-not $info.ModuleAvailable) { 'ActiveDirectory-Modul nicht installiert' } else { 'nicht verbunden' }
        $c.StatusAdText.Text = "AD: $reason"
        Set-EobBrush -Element $c.StatusAdIndicator -Property Fill -Key 'ErrorBrush'
    }
    $c.StatusUserText.Text = "Angemeldet: $((Get-EobCurrentIdentity).Name)"
    $summary = Get-EobConfigFindingSummary -Config $script:Ui.Config
    $c.StatusConfigText.Text = "Konfiguration: $($summary.Errors) Fehler, $($summary.Warnings) Warnungen"
    $c.StatusVersionText.Text = "easyONBOARDING $(Get-EobVersion)"
}

function Start-EobLogPump {
    [CmdletBinding()]
    param()

    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds(800)
    $timer.Add_Tick({ Invoke-EobUiSafely -Name 'Protokollanzeige' -Quiet -Action { Update-EobLogMessage } })
    $script:Ui.LogTimer = $timer
    $timer.Start()
}

function Update-EobLogMessage {
    [CmdletBinding()]
    param()

    $entries = @(Receive-EobLogEntry -MaxCount 200)
    if ($entries.Count -eq 0) { return }
    $important = @($entries | Where-Object { $_.Level -in @('Warning', 'Error', 'Critical', 'Audit') })
    $last = if ($important.Count -gt 0) { $important[-1] } else { $entries[-1] }
    $time = ConvertTo-EobUiDateText -Value $last.Timestamp -WithTime
    $c = $script:Ui.C
    $c.StatusMessageText.Text = "$time  $($last.Message)"
    $c.StatusMessageText.ToolTip = [string]$last.Message
    $key = switch ($last.Level) { 'Error' { 'ErrorBrush' } 'Critical' { 'ErrorBrush' } 'Warning' { 'WarningBrush' } default { 'TextSecondaryBrush' } }
    Set-EobBrush -Element $c.StatusMessageText -Property Foreground -Key $key
}

function Show-EobView {
    <#
    .SYNOPSIS
        Zeigt eine Ansicht an (lädt sie beim ersten Aufruf).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    if (-not $script:ViewDefinitions.Contains($Name)) { throw "Unbekannte Ansicht: $Name" }
    $c = $script:Ui.C
    if ($script:Ui.CurrentView -eq $Name -and $script:Ui.Views.ContainsKey($Name) -and $c.MainContent.Content -eq $script:Ui.Views[$Name]) { return }
    if ($null -ne $script:Ui.Execution -and $script:Ui.CurrentView) {
        $c.StatusMessageText.Text = 'Während einer Ausführung ist kein Ansichtswechsel möglich.'
        $c[$script:ViewDefinitions[$script:Ui.CurrentView].Nav].IsChecked = $true
        return
    }
    $definition = $script:ViewDefinitions[$Name]
    if (-not $script:Ui.Views.ContainsKey($Name)) {
        $loaded = Import-EobXamlWithControl -RelativePath $definition.File
        foreach ($key in $loaded.Controls.Keys) { $script:Ui.C[$key] = $loaded.Controls[$key] }
        $script:Ui.Views[$Name] = $loaded.Root
        & $definition.Initialize
    }
    $script:Ui.CurrentView = $Name
    $c.MainContent.Content = $script:Ui.Views[$Name]
    $nav = $c[$definition.Nav]
    if (-not $nav.IsChecked) { $nav.IsChecked = $true }
    Update-EobModeDisplay
    if ($definition.Refresh) { & $definition.Refresh }
}

function Reset-EobView {
    <#
    .SYNOPSIS
        Verwirft eine geladene Ansicht und zeigt sie neu an (z. B. "Neuer Vorgang").
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    $script:Ui.Views.Remove($Name)
    if ($script:Ui.CurrentView -eq $Name) {
        $script:Ui.CurrentView = ''
        Show-EobView -Name $Name
    }
}

function Set-EobUiBusy {
    [CmdletBinding()]
    param([Parameter(Mandatory)][bool]$Busy)

    $c = $script:Ui.C
    foreach ($name in $script:ViewDefinitions.Keys) {
        $nav = $c[$script:ViewDefinitions[$name].Nav]
        if ($name -ne $script:Ui.CurrentView) { $nav.IsEnabled = -not $Busy }
    }
    $c.ModeToggleButton.IsEnabled = -not $Busy
}

#endregion

#region Kooperative Ausführung

function Start-EobUiPlanExecution {
    <#
    .SYNOPSIS
        Führt einen Plan Schritt für Schritt auf dem UI-Thread aus. Die Oberfläche reagiert
        zwischen den Schritten; ein langsamer laufender Schritt blockiert sie bis zum Abschluss.
    .PARAMETER OnProgress
        Name einer Funktion (Plan, erledigt, gesamt, Schritt), die nach jedem Schritt aufgerufen wird.
    .PARAMETER OnComplete
        Name einer Funktion (Plan), die nach dem Abschluss aufgerufen wird.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Plan,
        [string[]]$IncludePhase,
        [Parameter(Mandatory)][string]$OnProgress,
        [Parameter(Mandatory)][string]$OnComplete
    )

    if ($null -ne $script:Ui.Execution) { throw 'Es läuft bereits eine Ausführung.' }
    Start-EobPlanRun -Plan $Plan
    $steps = @($Plan.Steps | Where-Object { -not $IncludePhase -or $_.Phase -in $IncludePhase })
    $timer = [System.Windows.Threading.DispatcherTimer]::new([System.Windows.Threading.DispatcherPriority]::Background)
    $timer.Interval = [TimeSpan]::FromMilliseconds(40)
    $timer.Add_Tick({ Invoke-EobUiSafely -Name 'Ausführung' -Action { Invoke-EobUiExecutionTick } })
    $script:Ui.Execution = @{
        Plan = $Plan; Steps = $steps; Index = 0; IncludePhase = $IncludePhase
        OnProgress = $OnProgress; OnComplete = $OnComplete; Timer = $timer
    }
    Set-EobUiBusy -Busy $true
    $timer.Start()
}

function Invoke-EobUiExecutionTick {
    [CmdletBinding()]
    param()

    $execution = $script:Ui.Execution
    if ($null -eq $execution) { return }
    $execution.Timer.Stop()
    $plan = $execution.Plan
    $failure = $null
    try {
        if ($execution.Index -lt $execution.Steps.Count) {
            $step = $execution.Steps[$execution.Index]
            $execution.Index++
            $null = Invoke-EobPlanStep -Plan $plan -Step $step -Simulation:$plan.Simulation
            & $execution.OnProgress $plan $execution.Index $execution.Steps.Count $step
        }
        if ($execution.Index -lt $execution.Steps.Count) {
            $execution.Timer.Start()
            return
        }
    }
    catch {
        $failure = $_
    }
    try {
        Complete-EobPlanRun -Plan $plan -IncludePhase $execution.IncludePhase
    }
    finally {
        $script:Ui.Execution = $null
        Set-EobUiBusy -Busy $false
    }
    & $execution.OnComplete $plan
    if ($null -ne $failure) { throw $failure }
}

function Stop-EobUiPlanExecution {
    [CmdletBinding()]
    param()

    if ($null -eq $script:Ui.Execution) { return }
    Stop-EobPlan -Plan $script:Ui.Execution.Plan -Confirm:$false
    $script:Ui.C.StatusMessageText.Text = 'Abbruch angefordert: Der laufende Schritt wird beendet, weitere Schritte werden übersprungen.'
}

function Export-EobUiPlanReport {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][pscustomobject]$Plan)

    try {
        $files = @(Export-EobPlanReport -Plan $Plan -Config $script:Ui.Config -Confirm:$false)
        $html = $files | Where-Object { $_.Format -eq 'Html' -and $_.Path } | Select-Object -First 1
        if ($null -ne $html) { return [string]$html.Path }
        $any = $files | Where-Object Path | Select-Object -First 1
        if ($null -ne $any) { return [string]$any.Path }
    }
    catch {
        Write-EobLog -Level Warning -OperationId $Plan.OperationId -Action 'ReportWritten' -Message "Bericht konnte nicht geschrieben werden: $($_.Exception.Message)"
    }
    return ''
}

function Get-EobOutcomeBanner {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Plan,
        [Parameter(Mandatory)][string]$Subject
    )

    switch ([string]$Plan.Status) {
        'Succeeded' { return [pscustomobject]@{ Kind = 'Success'; Text = "$Subject erfolgreich abgeschlossen." } }
        'Simulated' { return [pscustomobject]@{ Kind = 'Info'; Text = "Simulation abgeschlossen: $Subject wurde vollständig durchgespielt, es wurden keine Änderungen vorgenommen." } }
        'CompletedWithWarnings' { return [pscustomobject]@{ Kind = 'Warning'; Text = "$Subject mit Warnungen abgeschlossen. Details siehe Tabelle und Bericht." } }
        'Cancelled' { return [pscustomobject]@{ Kind = 'Warning'; Text = "$Subject wurde abgebrochen. Bereits ausgeführte Schritte bleiben bestehen." } }
        'Scheduled' { return [pscustomobject]@{ Kind = 'Info'; Text = "$Subject wurde geplant: Jetzt war keine Phase fällig, der Vorgang steht in der Warteschlange." } }
        default { return [pscustomobject]@{ Kind = 'Error'; Text = "$Subject ist fehlgeschlagen. Details siehe Tabelle und Bericht." } }
    }
}

function Export-EobUiPlanHandout {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][pscustomobject]$Plan, [switch]$Requested)

    if (-not $Requested) { return '' }
    try {
        $directory = Get-EobReportDirectory -Config $script:Ui.Config -Kind 'Handouts'
        $files = @(Export-EobPlanReport -Plan $Plan -Config $script:Ui.Config -Format Html, Pdf -Directory $directory -Confirm:$false)
        $file = $files | Where-Object { $_.Format -eq 'Html' -and $_.Path } | Select-Object -First 1
        if ($null -eq $file) { $file = $files | Where-Object Path | Select-Object -First 1 }
        if ($null -ne $file) { return [string]$file.Path }
    }
    catch {
        Write-EobLog -Level Warning -OperationId $Plan.OperationId -Action 'HandoutWritten' -Message "HandOut konnte nicht geschrieben werden: $($_.Exception.Message)"
    }
    return ''
}

#endregion

#region Dashboard

function Initialize-EobDashboardView {
    [CmdletBinding()]
    param()

    $c = $script:Ui.C
    $c.DashNewOnboardingButton.Add_Click({ Invoke-EobUiSafely -Name 'Onboarding öffnen' -Busy -Action { Show-EobView -Name 'Onboarding' } })
    $c.DashNewOffboardingButton.Add_Click({ Invoke-EobUiSafely -Name 'Offboarding öffnen' -Busy -Action { Show-EobView -Name 'Offboarding' } })
    $c.DashBulkButton.Add_Click({ Invoke-EobUiSafely -Name 'Massenverarbeitung öffnen' -Busy -Action { Show-EobView -Name 'Bulk' } })
    $c.DashRefreshButton.Add_Click({ Invoke-EobUiSafely -Name 'Dashboard aktualisieren' -Busy -Action { Update-EobStatusBar; Update-EobDashboardView } })
    $c.DashConfigDetailsButton.Add_Click({ Invoke-EobUiSafely -Name 'Einstellungen öffnen' -Busy -Action { Show-EobView -Name 'Settings' } })
}

function Update-EobDashboardView {
    [CmdletBinding()]
    param()

    $c = $script:Ui.C
    $config = $script:Ui.Config
    $mode = if ($script:Ui.Simulation) { 'Simulation' } else { 'Live' }
    $c.DashSubtitle.Text = "Angemeldet als $((Get-EobCurrentIdentity).Name)  ·  Modus: $mode  ·  Stand: $((Get-Date).ToString('dd.MM.yyyy HH:mm'))"

    $ad = Get-EobAdConnectionInfo
    if ($ad.Connected) {
        $c.DashAdState.Text = 'Verbunden'
        $c.DashAdDetail.Text = "$($ad.Server) · $([string](Get-EobPropertyValue -InputObject $ad.Domain -Name 'DnsRoot' -Default ''))"
        Set-EobBrush -Element $c.DashAdState -Property Foreground -Key 'SuccessBrush'
    }
    else {
        $c.DashAdState.Text = 'Nicht verbunden'
        $c.DashAdDetail.Text = if (-not $ad.ModuleAvailable) { 'ActiveDirectory-Modul (RSAT) nicht installiert' } else { [string]$ad.LastError }
        Set-EobBrush -Element $c.DashAdState -Property Foreground -Key 'ErrorBrush'
    }

    $queue = @(Get-EobOffboardingQueue -Config $config -Status Open, AwaitingDeletion)
    $due = @($queue | Where-Object IsDue)
    $deletions = @($queue | Where-Object DeletionDue)
    $c.DashQueueState.Text = "$($due.Count) fällig"
    $c.DashQueueDetail.Text = "$($queue.Count) offene Vorgänge · $($deletions.Count) Löschung(en) zur Freigabe"
    Set-EobBrush -Element $c.DashQueueState -Property Foreground -Key $(if ($due.Count -gt 0 -or $deletions.Count -gt 0) { 'WarningBrush' } else { 'TextPrimaryBrush' })
    Set-EobGridSource -Grid $c.DashQueueGrid -Items @($queue | Sort-Object -Property @{ Expression = { -not ($_.IsDue -or $_.DeletionDue) } }, NextDueDate | Select-Object -First 20 |
            ForEach-Object { ConvertTo-EobUiQueueRow -Item $_ })

    $summary = Get-EobAuditSummary -From (Get-Date).AddDays(-30) -To (Get-Date)
    $c.DashStatsState.Text = [string]$summary.OperationCount
    $parts = foreach ($kind in $summary.ByKind.Keys) { "$(Get-EobUiText -Map $script:KindTexts -Key $kind): $($summary.ByKind[$kind])" }
    $c.DashStatsDetail.Text = ((@($parts) + "Fehlgeschlagen: $($summary.FailedOperations)") -join ' · ')
    Set-EobGridSource -Grid $c.DashOperationsGrid -Items @($summary.LastOperations | ForEach-Object {
            [pscustomobject]@{
                TimeText   = ConvertTo-EobUiDateText -Value $_.Timestamp -WithTime
                Kind       = Get-EobUiText -Map $script:KindTexts -Key $_.Kind
                Target     = $_.Target
                ResultText = Get-EobUiText -Map $script:StatusTexts -Key $_.Result
                Actor      = $_.Actor
            }
        })

    $configSummary = Get-EobConfigFindingSummary -Config $config
    $c.DashConfigState.Text = if ($configSummary.Errors -gt 0) { "$($configSummary.Errors) Fehler" } elseif ($configSummary.Warnings -gt 0) { "$($configSummary.Warnings) Warnungen" } else { 'In Ordnung' }
    $c.DashConfigDetail.Text = if ($config.Exists) { Split-Path -Leaf $config.Path } else { 'Keine Konfigurationsdatei gefunden' }
    Set-EobBrush -Element $c.DashConfigState -Property Foreground -Key $(if ($configSummary.Errors -gt 0) { 'ErrorBrush' } elseif ($configSummary.Warnings -gt 0) { 'WarningBrush' } else { 'SuccessBrush' })
    if (-not $config.Exists) {
        Set-EobBanner -Border $c.DashConfigBanner -TextBlock $c.DashConfigBannerText -Kind Error -Text 'Es wurde keine Konfiguration gefunden. Unter Einstellungen kann sie aus der Vorlage erstellt werden.'
    }
    elseif ($configSummary.Errors -gt 0) {
        Set-EobBanner -Border $c.DashConfigBanner -TextBlock $c.DashConfigBannerText -Kind Error -Text "Die Konfiguration enthält $($configSummary.Errors) Fehler. Betroffene Funktionen sind eingeschränkt."
    }
    elseif ($configSummary.Warnings -gt 0) {
        Set-EobBanner -Border $c.DashConfigBanner -TextBlock $c.DashConfigBannerText -Kind Warning -Text "Die Konfiguration enthält $($configSummary.Warnings) Warnungen."
    }
    else {
        $c.DashConfigBanner.Visibility = 'Collapsed'
    }

    Set-EobGridSource -Grid $c.DashIntegrationGrid -Items @(Get-EobIntegrationStatus -Config $config | ForEach-Object { ConvertTo-EobUiIntegrationRow -Status $_ })
}

#endregion

#region Onboarding

function Initialize-EobOnboardingView {
    [CmdletBinding()]
    param()

    $c = $script:Ui.C
    $config = $script:Ui.Config
    $script:Ui.Onboarding = @{ Step = 1; Plan = $null; CredentialPending = $false; ReportPath = ''; AutoIdentity = @{} }

    Set-EobComboSource -Combo $c.OnbCompanyCombo -Items @(Get-EobCompany -Config $config | ForEach-Object { [pscustomobject]@{ Text = $_.DisplayName; Value = $_.Id } })
    Set-EobComboSource -Combo $c.OnbRoleTemplateCombo -Items (@([pscustomobject]@{ Text = '(keine)'; Value = '' }) + @(Get-EobRoleTemplate -Config $config | ForEach-Object {
                [pscustomobject]@{ Text = if ($_.DisplayName) { $_.DisplayName } else { $_.Name }; Value = $_.Name; ToolTip = $_.Description }
            }))
    Set-EobComboSource -Combo $c.OnbDisplayNameTemplateCombo -Items @(Get-EobDisplayNameTemplate -Config $config | ForEach-Object { [pscustomobject]@{ Text = $_.Label; Value = $_.Id } })
    $defaults = ConvertTo-EobOnboardingRequest -InputObject @{} -Config $config
    Set-EobComboSource -Combo $c.OnbLicenseCombo -SelectedValue $defaults.LicenseKey -Items @((Get-EobConfigSection -Config $config -Name 'LicensesGroups').Keys | ForEach-Object {
            [pscustomobject]@{ Text = $_; Value = $_ }
        })
    Set-EobComboSource -Combo $c.OnbTeamLeadGroupCombo -Items @((Get-EobConfigSection -Config $config -Name 'TLGroups').Keys | ForEach-Object { [pscustomobject]@{ Text = $_; Value = $_ } })

    $groups = [System.Collections.Generic.List[object]]::new()
    $hidden = 0
    $section = Get-EobConfigSection -Config $config -Name 'ADGroups'
    foreach ($key in $section.Keys) {
        $groupName = [string]$section[$key]
        if (-not $groupName) { continue }
        if ((Test-EobPrivilegedGroup -Group $groupName -Config $config).IsProtected) { $hidden++; continue }
        $groups.Add([pscustomobject]@{ Text = $key; Value = $key; ToolTip = $groupName })
    }
    Set-EobListSource -List $c.OnbGroupsList -Items $groups.ToArray()
    $c.OnbGroupsInfo.Text = if ($hidden -gt 0) { "$hidden privilegierte Gruppe(n) ausgeblendet." } else { '' }

    $c.OnbEnabledCheck.IsChecked = [bool]$defaults.Enabled
    $c.OnbChangePasswordCheck.IsChecked = [bool]$defaults.ChangePasswordAtLogon
    $c.OnbProxyCheck.IsChecked = [bool]$defaults.SetProxyAddresses
    $c.OnbHomeDirCheck.IsChecked = [bool]$defaults.CreateHomeDirectory
    $c.OnbMailboxCheck.IsChecked = [bool]$defaults.CreateMailbox
    $c.OnbWelcomeDocCheck.IsChecked = $true
    $c.OnbWelcomeDocCheck.IsEnabled = $false
    $c.OnbWelcomeMailCheck.IsChecked = [bool]$defaults.SendWelcomeMail
    $c.OnbSyncCheck.IsChecked = [bool]$defaults.TriggerSync
    $c.OnbStartDatePicker.SelectedDate = (Get-Date).Date

    $info = [System.Collections.Generic.List[string]]::new()
    $exchangeMode = [string](Get-EobConfigValue -Config $config -Section 'Exchange' -Key 'Mode')
    if ($exchangeMode -notin @('OnPremises', 'Hybrid')) { $c.OnbMailboxCheck.IsChecked = $false; $c.OnbMailboxCheck.IsEnabled = $false; $info.Add('Postfach: nur bei [Exchange] Mode=OnPremises/Hybrid.') }
    if ((Get-EobSmtpStatus -Config $config).State -eq 'NotConfigured') { $c.OnbWelcomeMailCheck.IsChecked = $false; $c.OnbWelcomeMailCheck.IsEnabled = $false; $info.Add('Welcome-Mail: SMTP nicht konfiguriert.') }
    if (-not (Get-EobConfigValue -Config $config -Section 'ADSync' -Key 'EnableADSync' -As Bool)) { $c.OnbSyncCheck.IsChecked = $false; $c.OnbSyncCheck.IsEnabled = $false; $info.Add('Synchronisation: [ADSync] EnableADSync=0.') }
    if (@(Get-EobConfigValue -Config $config -Section 'FileServer' -Key 'AllowedRoots' -As List).Count -eq 0) { $c.OnbHomeDirCheck.IsChecked = $false; $c.OnbHomeDirCheck.IsEnabled = $false; $info.Add('Home-Verzeichnis: [FileServer] AllowedRoots fehlt.') }
    $c.OnbOptionsInfo.Text = $info -join "`n"

    if (-not (Get-EobConfigValue -Config $config -Section 'Security' -Key 'AllowManualPassword' -As Bool)) {
        $c.OnbPasswordManualRadio.IsEnabled = $false
        $c.OnbPasswordManualRadio.ToolTip = 'Manuelle Kennwörter sind deaktiviert ([Security] AllowManualPassword=0).'
    }
    $c.OnbPasswordPolicyText.Text = 'Richtlinie: ' + ((Get-EobPasswordPolicyText -Policy (Get-EobPasswordPolicy -Config $config)) -join ' · ')

    $c.OnbCompanyCombo.Add_SelectionChanged({ Invoke-EobUiSafely -Name 'Unternehmen' -Action { Update-EobOnboardingCompanyDependent } })
    $c.OnbRoleTemplateCombo.Add_SelectionChanged({ Invoke-EobUiSafely -Name 'Rollenvorlage' -Action { Update-EobOnboardingRoleTemplate } })
    $c.OnbTeamLeadCheck.Add_Checked({ $script:Ui.C.OnbTeamLeadGroupCombo.IsEnabled = $true })
    $c.OnbTeamLeadCheck.Add_Unchecked({ $script:Ui.C.OnbTeamLeadGroupCombo.IsEnabled = $false })
    $c.OnbPasswordManualRadio.Add_Checked({ $script:Ui.C.OnbManualPasswordBox.IsEnabled = $true })
    $c.OnbPasswordManualRadio.Add_Unchecked({ $script:Ui.C.OnbManualPasswordBox.IsEnabled = $false; $script:Ui.C.OnbManualPasswordBox.Clear() })
    $c.OnbIdentityPreviewButton.Add_Click({ Invoke-EobUiSafely -Name 'Kontoname ermitteln' -Busy -Action { Update-EobOnboardingIdentity } })
    $c.OnbBackButton.Add_Click({ Invoke-EobUiSafely -Name 'Zurück' -Action { Set-EobOnboardingStep -Step ($script:Ui.Onboarding.Step - 1) } })
    $c.OnbNextButton.Add_Click({ Invoke-EobUiSafely -Name 'Weiter' -Busy -Action { Move-EobOnboardingNext } })
    $c.OnbExecuteButton.Add_Click({ Invoke-EobUiSafely -Name 'Onboarding ausführen' -Action { Invoke-EobOnboardingExecution } })
    $c.OnbCancelRunButton.Add_Click({ Invoke-EobUiSafely -Name 'Abbrechen' -Action { Stop-EobUiPlanExecution } })
    $c.OnbNewButton.Add_Click({ Invoke-EobUiSafely -Name 'Neuer Vorgang' -Action { Reset-EobOnboardingView } })
    $c.OnbShowCredentialButton.Add_Click({ Invoke-EobUiSafely -Name 'Zugangsdaten anzeigen' -Action { Show-EobOnboardingCredential } })
    $c.OnbOpenReportButton.Add_Click({ Invoke-EobUiSafely -Name 'Bericht öffnen' -Action { Open-EobPath -Path $script:Ui.Onboarding.ReportPath } })

    Update-EobOnboardingCompanyDependent
    Set-EobOnboardingStep -Step 1
}

function Update-EobOnboardingCompanyDependent {
    [CmdletBinding()]
    param()

    $c = $script:Ui.C
    $config = $script:Ui.Config
    $companyId = [string](Get-EobComboValue -Combo $c.OnbCompanyCombo)
    $company = Get-EobCompany -Config $config -Id $companyId | Select-Object -First 1
    Set-EobComboSource -Combo $c.OnbMailDomainCombo -Items @(Get-EobMailDomain -Config $config -CompanyId $companyId | ForEach-Object { [pscustomobject]@{ Text = "@$_"; Value = $_ } })
    $c.OnbUpnSuffixText.Text = if ($null -ne $company -and $company.UpnSuffix) { "@$($company.UpnSuffix)" } else { '' }

    $ous = [System.Collections.Generic.List[object]]::new()
    $defaultOu = if ($null -ne $company) { [string]$company.DefaultOU } else { '' }
    if ($defaultOu) { $ous.Add([pscustomobject]@{ Text = "$defaultOu (Standard)"; Value = $defaultOu }) }
    if ((Get-EobAdConnectionInfo).Connected) {
        try {
            foreach ($ou in @(Get-EobAdOrganizationalUnitList)) {
                if ($ou.DistinguishedName -ieq $defaultOu) { continue }
                $ous.Add([pscustomobject]@{ Text = $ou.CanonicalName; Value = $ou.DistinguishedName; ToolTip = $ou.DistinguishedName })
            }
        }
        catch {
            Write-EobLog -Level Warning -Action 'UI' -Message "OUs konnten nicht gelesen werden: $($_.Exception.Message)"
        }
    }
    Set-EobComboSource -Combo $c.OnbTargetOuCombo -Items $ous.ToArray() -SelectedValue $defaultOu
    $script:Ui.Onboarding.AutoIdentity = @{}
}

function Update-EobOnboardingRoleTemplate {
    [CmdletBinding()]
    param()

    $c = $script:Ui.C
    $name = [string](Get-EobComboValue -Combo $c.OnbRoleTemplateCombo)
    if (-not $name) { $c.OnbRoleTemplateInfo.Text = ''; return }
    $role = Get-EobRoleTemplate -Config $script:Ui.Config -Name $name | Select-Object -First 1
    if ($null -eq $role) { return }
    $c.OnbRoleTemplateInfo.Text = (@($role.Description, $(if ($role.Groups) { 'Gruppen: ' + ($role.Groups -join ', ') }), $(if ($role.License) { "Lizenz: $($role.License)" })) | Where-Object { $_ }) -join "`n"
    if ($role.Title -and -not $c.OnbTitleText.Text) { $c.OnbTitleText.Text = $role.Title }
    if ($role.Department -and -not $c.OnbDepartmentText.Text) { $c.OnbDepartmentText.Text = $role.Department }
    if ($role.License) {
        foreach ($item in $c.OnbLicenseCombo.Items) { if ([string]$item.Tag -eq $role.License) { $c.OnbLicenseCombo.SelectedItem = $item } }
    }
}

function Get-EobOnboardingFormValue {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $c = $script:Ui.C
    $manual = [bool]$c.OnbPasswordManualRadio.IsChecked
    @{
        CompanyId               = [string](Get-EobComboValue -Combo $c.OnbCompanyCombo)
        RoleTemplate            = [string](Get-EobComboValue -Combo $c.OnbRoleTemplateCombo)
        DisplayNameTemplate     = [string](Get-EobComboValue -Combo $c.OnbDisplayNameTemplateCombo)
        IsExternal              = [bool]$c.OnbExternalCheck.IsChecked
        ReferenceUser           = $c.OnbReferenceUserText.Text
        GivenName               = $c.OnbGivenNameText.Text
        Surname                 = $c.OnbSurnameText.Text
        DisplayName             = $c.OnbDisplayNameText.Text
        EmployeeId              = $c.OnbEmployeeIdText.Text
        EmployeeType            = $c.OnbEmployeeTypeText.Text
        StartDate               = $c.OnbStartDatePicker.SelectedDate
        ExpirationDate          = $c.OnbExpirationDatePicker.SelectedDate
        SamAccountName          = $c.OnbSamText.Text
        UserPrincipalNamePrefix = $c.OnbUpnPrefixText.Text
        MailLocalPart           = $c.OnbMailLocalText.Text
        MailDomain              = [string](Get-EobComboValue -Combo $c.OnbMailDomainCombo)
        TargetOU                = [string](Get-EobComboValue -Combo $c.OnbTargetOuCombo)
        Title                   = $c.OnbTitleText.Text
        Department              = $c.OnbDepartmentText.Text
        Office                  = $c.OnbOfficeText.Text
        OfficePhone             = $c.OnbOfficePhoneText.Text
        MobilePhone             = $c.OnbMobilePhoneText.Text
        Manager                 = $c.OnbManagerText.Text
        Description             = $c.OnbDescriptionText.Text
        LicenseKey              = [string](Get-EobComboValue -Combo $c.OnbLicenseCombo)
        IsTeamLead              = [bool]$c.OnbTeamLeadCheck.IsChecked
        TeamLeadGroupKey        = if ($c.OnbTeamLeadCheck.IsChecked) { [string](Get-EobComboValue -Combo $c.OnbTeamLeadGroupCombo) } else { '' }
        IsDepartmentHead        = [bool]$c.OnbDepartmentHeadCheck.IsChecked
        Groups                  = @(Get-EobListSelection -List $c.OnbGroupsList)
        PasswordMode            = if ($manual) { 'Manual' } else { 'Generate' }
        ManualPassword          = if ($manual) { $c.OnbManualPasswordBox.SecurePassword } else { $null }
        ChangePasswordAtLogon   = [bool]$c.OnbChangePasswordCheck.IsChecked
        Enabled                 = [bool]$c.OnbEnabledCheck.IsChecked
        SetProxyAddresses       = [bool]$c.OnbProxyCheck.IsChecked
        CreateHomeDirectory     = [bool]$c.OnbHomeDirCheck.IsChecked
        CreateMailbox           = [bool]$c.OnbMailboxCheck.IsChecked
        CreateWelcomeDocument   = $true
        SendWelcomeMail         = [bool]$c.OnbWelcomeMailCheck.IsChecked
        TriggerSync             = [bool]$c.OnbSyncCheck.IsChecked
        Ticket                  = $c.OnbTicketText.Text
        Notes                   = $c.OnbNotesText.Text
    }
}

function Get-EobOnboardingFormRequest {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $data = Get-EobOnboardingFormRequestData -Values (Get-EobOnboardingFormValue) -AutoIdentity $script:Ui.Onboarding.AutoIdentity
    return (ConvertTo-EobOnboardingRequest -InputObject $data -Config $script:Ui.Config)
}

function Set-EobOnboardingStep {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateRange(1, 8)][int]$Step)

    $c = $script:Ui.C
    $state = $script:Ui.Onboarding
    $state.Step = $Step
    for ($index = 1; $index -le 8; $index++) {
        $c["OnbPanel$index"].Visibility = if ($index -eq $Step) { 'Visible' } else { 'Collapsed' }
        $label = $c["OnbStep$index"]
        $label.FontWeight = if ($index -eq $Step) { [System.Windows.FontWeights]::SemiBold } else { [System.Windows.FontWeights]::Normal }
        Set-EobBrush -Element $label -Property Foreground -Key $(if ($index -eq $Step) { 'AccentBrush' } elseif ($index -lt $Step) { 'TextPrimaryBrush' } else { 'TextSecondaryBrush' })
    }
    $running = $null -ne $script:Ui.Execution
    $c.OnbBackButton.Visibility = if ($Step -gt 1 -and $Step -lt 8) { 'Visible' } else { 'Collapsed' }
    $c.OnbNextButton.Visibility = if ($Step -lt 7) { 'Visible' } else { 'Collapsed' }
    $c.OnbExecuteButton.Visibility = if ($Step -eq 7) { 'Visible' } else { 'Collapsed' }
    $c.OnbCancelRunButton.Visibility = if ($Step -eq 8 -and $running) { 'Visible' } else { 'Collapsed' }
    $c.OnbNewButton.Visibility = if ($Step -eq 8 -and -not $running) { 'Visible' } else { 'Collapsed' }
    $c.OnbNextButton.IsDefault = ($Step -lt 7)
    $c.OnbValidationText.Text = ''
    $c.OnbScroll.ScrollToTop()
    Update-EobModeDisplay
}

function Test-EobOnboardingStep {
    <#
    .SYNOPSIS
        Prüft die Felder eines Assistentenschritts und zeigt Fehler direkt am Feld an.
    .OUTPUTS
        Anzahl der blockierenden Fehler.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][int]$Step)

    $c = $script:Ui.C
    $fields = @($script:OnboardingFieldMap.Keys | Where-Object { $script:OnboardingFieldMap[$_].Step -eq $Step })
    foreach ($field in $fields) { Set-EobFieldError -Control $c[$script:OnboardingFieldMap[$field].Error] }
    $request = Get-EobOnboardingFormRequest
    $errors = @(Test-EobOnboardingRequest -Request $request -Config $script:Ui.Config | Where-Object { $_.Severity -eq 'Error' -and $_.Field -in $fields })
    $unassigned = [System.Collections.Generic.List[string]]::new()
    foreach ($finding in $errors) {
        $target = $c[$script:OnboardingFieldMap[$finding.Field].Error]
        if ($null -eq $target) { $unassigned.Add($finding.Message); continue }
        $text = if ($target.Text) { "$($target.Text)`n$($finding.Message)" } else { $finding.Message }
        Set-EobFieldError -Control $target -Message $text
    }
    if ($errors.Count -gt 0) {
        $c.OnbValidationText.Text = if ($unassigned.Count -gt 0) { $unassigned -join ' ' } else { 'Bitte die markierten Felder prüfen.' }
    }
    return $errors.Count
}

function Move-EobOnboardingNext {
    [CmdletBinding()]
    param()

    $state = $script:Ui.Onboarding
    if ((Test-EobOnboardingStep -Step $state.Step) -gt 0) { return }
    if ($state.Step -eq 6) {
        Show-EobOnboardingPreview
        Set-EobOnboardingStep -Step 7
        return
    }
    Set-EobOnboardingStep -Step ($state.Step + 1)
    if ($state.Step -eq 3) { Update-EobOnboardingIdentity -OnlyWhenAutomatic }
}

function Update-EobOnboardingIdentity {
    <#
    .SYNOPSIS
        Ermittelt Kontoname, UPN und E-Mail inkl. Kollisionsprüfung und zeigt das Ergebnis an.
    .PARAMETER OnlyWhenAutomatic
        Überschreibt keine vom Benutzer geänderten Werte.
    #>
    [CmdletBinding()]
    param([switch]$OnlyWhenAutomatic)

    $c = $script:Ui.C
    $state = $script:Ui.Onboarding
    $values = Get-EobOnboardingFormValue
    $edited = @('SamAccountName', 'UserPrincipalNamePrefix', 'MailLocalPart' | Where-Object { ([string]$values[$_]).Trim() -and ([string]$values[$_]).Trim() -cne [string]$state.AutoIdentity[$_] })
    if ($OnlyWhenAutomatic -and $edited.Count -gt 0) { return }

    $data = Get-EobOnboardingFormRequestData -Values $values -AutoIdentity $(if ($OnlyWhenAutomatic) { $values } else { $state.AutoIdentity })
    $request = ConvertTo-EobOnboardingRequest -InputObject $data -Config $script:Ui.Config
    if (-not $request.GivenName -or -not $request.Surname) {
        Set-EobBanner -Border $c.OnbIdentityInfoBanner -TextBlock $c.OnbIdentityInfoText -Kind Warning -Text 'Bitte zuerst Vor- und Nachname erfassen.'
        return
    }
    $company = Get-EobCompany -Config $script:Ui.Config -Id $request.CompanyId | Select-Object -First 1
    if ($null -eq $company) { throw 'Es ist kein Unternehmen konfiguriert.' }
    $online = (Get-EobAdConnectionInfo).Connected
    $result = Resolve-EobIdentity -Request $request -Config $script:Ui.Config -Company $company -SkipDirectoryCheck:(-not $online)
    $proposal = $result.Proposal
    $upnPrefix = if ($proposal.UserPrincipalName -match '^([^@]+)@') { $Matches[1] } else { '' }
    $mailLocal = if ($proposal.Mail -match '^([^@]+)@') { $Matches[1] } else { '' }
    $c.OnbSamText.Text = $proposal.SamAccountName
    $c.OnbUpnPrefixText.Text = $upnPrefix
    $c.OnbMailLocalText.Text = $mailLocal
    $state.AutoIdentity = @{}
    if (-not $data.ContainsKey('SamAccountName')) { $state.AutoIdentity['SamAccountName'] = $proposal.SamAccountName }
    if (-not $data.ContainsKey('UserPrincipalNamePrefix')) { $state.AutoIdentity['UserPrincipalNamePrefix'] = $upnPrefix }
    if (-not $data.ContainsKey('MailLocalPart')) { $state.AutoIdentity['MailLocalPart'] = $mailLocal }

    foreach ($name in @('OnbSamError', 'OnbUpnError', 'OnbMailError')) { Set-EobFieldError -Control $c[$name] }
    foreach ($finding in @($result.Findings | Where-Object Severity -EQ 'Error')) {
        $target = $c[$script:OnboardingFieldMap[[string]$finding.Field].Error]
        Set-EobFieldError -Control $target -Message $finding.Message
    }
    $lines = [System.Collections.Generic.List[string]]::new()
    if ($result.IsAvailable) { $lines.Add("Verfügbar: $($proposal.SamAccountName)  ·  $($proposal.UserPrincipalName)$(if ($proposal.Mail) { '  ·  ' + $proposal.Mail })") }
    foreach ($finding in @($result.Findings | Where-Object Severity -NE 'Error')) { $lines.Add($finding.Message) }
    if (-not $online) { $lines.Add('Ohne AD-Verbindung wurde nicht auf Kollisionen geprüft. Die Prüfung erfolgt vor jeder Ausführung erneut.') }
    $kind = if (-not $result.IsAvailable) { 'Error' } elseif (-not $online) { 'Warning' } else { 'Success' }
    if (-not $result.IsAvailable -and $lines.Count -eq 0) { $lines.Add('Der Kontoname ist nicht verfügbar. Details siehe Felder.') }
    Set-EobBanner -Border $c.OnbIdentityInfoBanner -TextBlock $c.OnbIdentityInfoText -Kind $kind -Text ($lines -join "`n")
}

function Show-EobOnboardingPreview {
    [CmdletBinding()]
    param()

    $c = $script:Ui.C
    $state = $script:Ui.Onboarding
    if ($null -ne $state.Plan -and $state.Plan.Status -eq 'Planned') { Clear-EobPlanSecret -Plan $state.Plan -Confirm:$false }
    $request = Get-EobOnboardingFormRequest
    $online = (Get-EobAdConnectionInfo).Connected
    $domainPolicy = $null
    if ($online) { try { $domainPolicy = Get-EobAdPasswordPolicy } catch { Write-EobLog -Level Warning -Action 'UI' -Message "Domänenrichtlinie nicht lesbar: $($_.Exception.Message)" } }
    $plan = New-EobOnboardingPlan -Request $request -Config $script:Ui.Config -Simulation:$script:Ui.Simulation -SkipDirectoryCheck:(-not $online) -DomainPasswordPolicy $domainPolicy
    $state.Plan = $plan

    Set-EobGridSource -Grid $c.OnbPreviewSummaryGrid -Items @(ConvertTo-EobUiSummaryRow -Summary $plan.Summary)
    Set-EobGridSource -Grid $c.OnbPreviewStepsGrid -Items @($plan.Steps | ForEach-Object { ConvertTo-EobUiStepRow -Step $_ })
    Set-EobGridSource -Grid $c.OnbPreviewFindingsGrid -Items @($plan.Findings | Sort-Object -Property @{ Expression = { @('Error', 'Warning', 'Information').IndexOf([string]$_.Severity) } } |
            ForEach-Object { ConvertTo-EobUiFindingRow -Finding $_ })

    $errors = @($plan.Findings | Where-Object Severity -EQ 'Error')
    $offline = @($plan.Findings | Where-Object Code -EQ 'ONB_OFFLINE').Count -gt 0
    if ($errors.Count -gt 0) {
        Set-EobBanner -Border $c.OnbPreviewBanner -TextBlock $c.OnbPreviewBannerText -Kind Error -Text "$($errors.Count) blockierende(r) Befund(e): Die Ausführung ist erst nach Korrektur möglich (Zurück)."
    }
    elseif ($offline) {
        Set-EobBanner -Border $c.OnbPreviewBanner -TextBlock $c.OnbPreviewBannerText -Kind Warning -Text 'Keine AD-Verbindung: Der Vorgang kann nur simuliert werden.'
    }
    elseif ($script:Ui.Simulation) {
        Set-EobBanner -Border $c.OnbPreviewBanner -TextBlock $c.OnbPreviewBannerText -Kind Info -Text "Simulationsmodus: $($plan.Steps.Count) Schritt(e) werden geprüft und protokolliert, aber nicht ausgeführt."
    }
    else {
        Set-EobBanner -Border $c.OnbPreviewBanner -TextBlock $c.OnbPreviewBannerText -Kind Warning -Text "Live-Modus: $($plan.Steps.Count) Schritt(e) werden nach Bestätigung tatsächlich ausgeführt."
    }
    $c.OnbExecuteButton.IsEnabled = (Test-EobPlanExecutable -Plan $plan)
}

function Invoke-EobOnboardingExecution {
    [CmdletBinding()]
    param()

    $c = $script:Ui.C
    $state = $script:Ui.Onboarding
    $plan = $state.Plan
    if ($null -eq $plan -or -not (Test-EobPlanExecutable -Plan $plan)) { return }
    if ($script:Ui.Simulation -or @($plan.Findings | Where-Object Code -EQ 'ONB_OFFLINE').Count -gt 0) { $plan.Simulation = $true }
    if (-not $plan.Simulation) {
        $subject = $plan.Subject
        $answer = Show-EobDialog -Title 'Onboarding ausführen' -Kind Question -ConfirmText '_Ausführen' -CancelText 'Abbrechen' `
            -Message "Das Konto $($subject['SamAccountName']) wird jetzt mit $($plan.Steps.Count) Schritt(en) angelegt." `
            -Details @("Anzeigename: $($subject['DisplayName'])", "UPN: $($subject['UserPrincipalName'])", "Ziel-OU: $($subject['TargetOU'])")
        if (-not $answer.Confirmed) { return }
    }
    $c.OnbProgressBar.Value = 0
    $c.OnbProgressText.Text = 'Ausführung wird gestartet …'
    $c.OnbResultBanner.Visibility = 'Collapsed'
    $c.OnbShowCredentialButton.Visibility = 'Collapsed'
    $c.OnbOpenReportButton.Visibility = 'Collapsed'
    Set-EobGridSource -Grid $c.OnbResultStepsGrid -Items @($plan.Steps | ForEach-Object { ConvertTo-EobUiStepRow -Step $_ })
    Start-EobUiPlanExecution -Plan $plan -OnProgress 'Update-EobOnboardingProgress' -OnComplete 'Complete-EobOnboardingExecution'
    Set-EobOnboardingStep -Step 8
}

function Update-EobOnboardingProgress {
    [CmdletBinding()]
    param($Plan, [int]$Done, [int]$Total, $Step)

    $c = $script:Ui.C
    $c.OnbProgressBar.Value = [Math]::Round(100.0 * $Done / [Math]::Max(1, $Total))
    $c.OnbProgressText.Text = "Schritt $Done von $($Total): $($Step.Title) - $(Get-EobUiText -Map $script:StatusTexts -Key $Step.Status)"
    Set-EobGridSource -Grid $c.OnbResultStepsGrid -Items @($Plan.Steps | ForEach-Object { ConvertTo-EobUiStepRow -Step $_ })
}

function Complete-EobOnboardingExecution {
    [CmdletBinding()]
    param($Plan)

    $c = $script:Ui.C
    $state = $script:Ui.Onboarding
    $c.OnbProgressBar.Value = 100
    $c.OnbProgressText.Text = "Abgeschlossen: $(Get-EobUiText -Map $script:StatusTexts -Key $Plan.Status)"
    Set-EobGridSource -Grid $c.OnbResultStepsGrid -Items @($Plan.Steps | ForEach-Object { ConvertTo-EobUiStepRow -Step $_ })
    $state.ReportPath = Export-EobUiPlanReport -Plan $Plan
    $c.OnbOpenReportButton.Visibility = if ($state.ReportPath) { 'Visible' } else { 'Collapsed' }

    $banner = Get-EobOutcomeBanner -Plan $Plan -Subject "Onboarding von $($Plan.Subject['SamAccountName'])"
    $text = $banner.Text
    $secure = Get-EobPlanCredential -Plan $Plan
    if ($null -ne $secure) {
        if (Get-EobConfigValue -Config $script:Ui.Config -Section 'Security' -Key 'ShowPasswordOnce' -As Bool) {
            $state.CredentialPending = $true
            $c.OnbShowCredentialButton.Visibility = 'Visible'
            $text += ' Bitte jetzt die Zugangsdaten anzeigen: Sie sind nur einmal abrufbar.'
        }
        else {
            Clear-EobPlanSecret -Plan $Plan -Confirm:$false
            $text += ' Das Kennwort wird gemäß Konfiguration nicht angezeigt; bitte bei der Übergabe zurücksetzen.'
        }
    }
    else {
        Clear-EobPlanSecret -Plan $Plan -Confirm:$false
    }
    Set-EobBanner -Border $c.OnbResultBanner -TextBlock $c.OnbResultText -Kind $banner.Kind -Text $text
    Set-EobOnboardingStep -Step 8
    Update-EobStatusBar
}

function Show-EobOnboardingCredential {
    [CmdletBinding()]
    param()

    $state = $script:Ui.Onboarding
    $plan = $state.Plan
    if ($null -eq $plan) { return }
    $secure = Get-EobPlanCredential -Plan $plan
    if ($null -eq $secure) { return }
    try {
        Show-EobCredentialDialog -DisplayName ([string]$plan.Subject['DisplayName']) -SamAccountName ([string]$plan.Subject['SamAccountName']) `
            -UserPrincipalName ([string]$plan.Subject['UserPrincipalName']) -Password $secure
    }
    finally {
        Clear-EobPlanSecret -Plan $plan -Confirm:$false
        $state.CredentialPending = $false
        $script:Ui.C.OnbShowCredentialButton.Visibility = 'Collapsed'
    }
}

function Reset-EobOnboardingView {
    [CmdletBinding()]
    param()

    $state = $script:Ui.Onboarding
    if ($state.CredentialPending) {
        $answer = Show-EobDialog -Title 'Zugangsdaten nicht angezeigt' -Kind Warning -ConfirmText 'Trotzdem neu beginnen' -CancelText 'Zurück' `
            -Message 'Die Zugangsdaten wurden noch nicht angezeigt. Ohne Anzeige muss das Kennwort später zurückgesetzt werden.'
        if (-not $answer.Confirmed) { return }
    }
    if ($null -ne $state.Plan) { Clear-EobPlanSecret -Plan $state.Plan -Confirm:$false }
    Reset-EobView -Name 'Onboarding'
}

#endregion

#region Offboarding

function Initialize-EobOffboardingView {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'source', Justification = 'Signatur von WPF-Ereignishandlern (Sender, EventArgs); der Sender wird nicht benötigt.')]
    [CmdletBinding()]
    param()

    $c = $script:Ui.C
    $config = $script:Ui.Config
    $script:Ui.Offboarding = @{ Step = 1; User = $null; Plan = $null; FromQueue = $false; ReportPath = ''; SelectedPhases = @(); HandoutRequested = $false }
    $c.OffHandoutCheck.IsChecked = $false
    $default = [string](Get-EobConfigValue -Config $config -Section 'Offboarding' -Key 'DefaultTemplate')
    Set-EobComboSource -Combo $c.OffTemplateCombo -SelectedValue $default -Items @(Get-EobOffboardingTemplate -Config $config | ForEach-Object {
            [pscustomobject]@{ Text = $_.DisplayName; Value = $_.Name; ToolTip = $_.Description }
        })
    $c.OffExitDatePicker.SelectedDate = (Get-Date).Date

    $c.OffSearchButton.Add_Click({ Invoke-EobUiSafely -Name 'Benutzersuche' -Busy -Action { Invoke-EobOffboardingSearch } })
    $c.OffSearchText.Add_KeyDown({
            param($source, $e)
            if ($e.Key -eq [System.Windows.Input.Key]::Return) { $e.Handled = $true; Invoke-EobUiSafely -Name 'Benutzersuche' -Busy -Action { Invoke-EobOffboardingSearch } }
        })
    $c.OffSearchResultsGrid.Add_SelectionChanged({ Invoke-EobUiSafely -Name 'Auswahl' -Action { Select-EobOffboardingUser } })
    $c.OffSearchResultsGrid.Add_MouseDoubleClick({ Invoke-EobUiSafely -Name 'Weiter' -Busy -Action { Move-EobOffboardingNext } })
    $c.OffTemplateCombo.Add_SelectionChanged({ Invoke-EobUiSafely -Name 'Vorlage' -Action { Update-EobOffboardingTemplateInfo } })
    $c.OffBackButton.Add_Click({ Invoke-EobUiSafely -Name 'Zurück' -Action { Set-EobOffboardingStep -Step ($script:Ui.Offboarding.Step - 1) } })
    $c.OffNextButton.Add_Click({ Invoke-EobUiSafely -Name 'Weiter' -Busy -Action { Move-EobOffboardingNext } })
    $c.OffExecuteButton.Add_Click({ Invoke-EobUiSafely -Name 'Offboarding ausführen' -Action { Invoke-EobOffboardingExecution } })
    $c.OffCancelRunButton.Add_Click({ Invoke-EobUiSafely -Name 'Abbrechen' -Action { Stop-EobUiPlanExecution } })
    $c.OffNewButton.Add_Click({ Invoke-EobUiSafely -Name 'Neuer Vorgang' -Action { Reset-EobView -Name 'Offboarding' } })
    $c.OffOpenReportButton.Add_Click({ Invoke-EobUiSafely -Name 'Bericht öffnen' -Action { Open-EobPath -Path $script:Ui.Offboarding.ReportPath } })

    $c.OffQueueRefreshButton.Add_Click({ Invoke-EobUiSafely -Name 'Warteschlange' -Busy -Action { Update-EobOffboardingQueue } })
    $c.OffQueueShowClosedCheck.Add_Click({ Invoke-EobUiSafely -Name 'Warteschlange' -Busy -Action { Update-EobOffboardingQueue } })
    $c.OffQueueRunDueButton.Add_Click({ Invoke-EobUiSafely -Name 'Fällige Phase' -Busy -Action { Start-EobOffboardingQueuePhase } })
    $c.OffQueueDeletionButton.Add_Click({ Invoke-EobUiSafely -Name 'Endgültige Löschung' -Busy -Action { Invoke-EobOffboardingDeletion } })
    $c.OffQueueCancelButton.Add_Click({ Invoke-EobUiSafely -Name 'Vorgang abbrechen' -Action { Stop-EobOffboardingQueueItem } })
    $c.OffQueueOpenSnapshotButton.Add_Click({ Invoke-EobUiSafely -Name 'Zustandsberichte' -Action { Open-EobOffboardingSnapshotFolder } })

    Update-EobOffboardingTemplateInfo
    Set-EobOffboardingStep -Step 1
}

function Update-EobOffboardingTemplateInfo {
    [CmdletBinding()]
    param()

    $c = $script:Ui.C
    $name = [string](Get-EobComboValue -Combo $c.OffTemplateCombo)
    $template = Get-EobOffboardingTemplate -Config $script:Ui.Config -Name $name | Select-Object -First 1
    if ($null -eq $template) { $c.OffTemplateDescriptionText.Text = ''; return }
    $deletion = if ($template.RetentionDays -gt 0) { "Löschung frühestens $($template.RetentionDays) Tage nach dem Austritt (nur nach Freigabe)" } else { 'Keine Löschung vorgesehen' }
    $c.OffTemplateDescriptionText.Text = (@($template.Description, "Aufbewahrung ab Austritt + $($template.RetentionPhaseStartDays) Tage · $deletion",
            $(if ($template.IsTestMode) { 'Testvorlage: erzwingt die Simulation.' })) | Where-Object { $_ }) -join "`n"
}

function Set-EobOffboardingStep {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateRange(1, 4)][int]$Step)

    $c = $script:Ui.C
    $state = $script:Ui.Offboarding
    $state.Step = $Step
    for ($index = 1; $index -le 4; $index++) {
        $c["OffPanel$index"].Visibility = if ($index -eq $Step) { 'Visible' } else { 'Collapsed' }
        $label = $c["OffStep$index"]
        $label.FontWeight = if ($index -eq $Step) { [System.Windows.FontWeights]::SemiBold } else { [System.Windows.FontWeights]::Normal }
        Set-EobBrush -Element $label -Property Foreground -Key $(if ($index -eq $Step) { 'AccentBrush' } elseif ($index -lt $Step) { 'TextPrimaryBrush' } else { 'TextSecondaryBrush' })
    }
    $running = $null -ne $script:Ui.Execution
    $c.OffBackButton.Visibility = if ($Step -gt 1 -and $Step -lt 4 -and -not ($state.FromQueue -and $Step -eq 3)) { 'Visible' } else { 'Collapsed' }
    $c.OffNextButton.Visibility = if ($Step -lt 3) { 'Visible' } else { 'Collapsed' }
    $c.OffExecuteButton.Visibility = if ($Step -eq 3) { 'Visible' } else { 'Collapsed' }
    $c.OffCancelRunButton.Visibility = if ($Step -eq 4 -and $running) { 'Visible' } else { 'Collapsed' }
    $c.OffNewButton.Visibility = if (($Step -eq 4 -and -not $running) -or ($state.FromQueue -and $Step -eq 3)) { 'Visible' } else { 'Collapsed' }
    $c.OffNextButton.IsDefault = ($Step -lt 3)
    $c.OffValidationText.Text = ''
    $c.OffScroll.ScrollToTop()
    Update-EobModeDisplay
}

function Invoke-EobOffboardingSearch {
    [CmdletBinding()]
    param()

    $c = $script:Ui.C
    $text = ([string]$c.OffSearchText.Text).Trim()
    if ($text.Length -lt 2) { $c.OffSearchInfo.Text = 'Bitte mindestens 2 Zeichen eingeben.'; return }
    if (-not (Get-EobAdConnectionInfo).Connected) { throw 'Keine Verbindung zum Active Directory (siehe Tools > AD neu verbinden).' }
    $users = @(Find-EobAdUser -SearchText $text)
    Set-EobGridSource -Grid $c.OffSearchResultsGrid -Items @($users | ForEach-Object { ConvertTo-EobUiUserRow -User $_ })
    $c.OffSearchInfo.Text = if ($users.Count -eq 0) { 'Keine Treffer.' } else { "$($users.Count) Treffer. Bitte das Konto auswählen." }
    $script:Ui.Offboarding.User = $null
    $c.OffSelectedUserText.Text = ''
}

function Select-EobOffboardingUser {
    [CmdletBinding()]
    param()

    $c = $script:Ui.C
    $row = $c.OffSearchResultsGrid.SelectedItem
    if ($null -eq $row) { return }
    $script:Ui.Offboarding.User = $row.User
    $script:Ui.Offboarding.HandoutRequested = $false
    $c.OffHandoutCheck.IsChecked = $false
    $state = if ($row.User.Enabled) { 'aktiv' } else { 'deaktiviert' }
    $c.OffSelectedUserText.Text = "Ausgewählt: $($row.User.DisplayName) ($($row.User.SamAccountName)), Konto $state"
}

function Get-EobOffboardingFormRequest {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $c = $script:Ui.C
    $values = @{
        Identity              = [string]$script:Ui.Offboarding.User.ObjectGuid
        Template              = [string](Get-EobComboValue -Combo $c.OffTemplateCombo)
        ExitDate              = $c.OffExitDatePicker.SelectedDate
        Ticket                = $c.OffTicketText.Text
        Reason                = $c.OffReasonText.Text
        Notes                 = $c.OffNotesText.Text
        ForwardTo             = $c.OffForwardToText.Text
        AutoReplyMessage      = $c.OffAutoReplyText.Text
        AssetsText            = $c.OffAssetsText.Text
        AcknowledgePrivileged = [bool]$c.OffAcknowledgePrivilegedCheck.IsChecked
        AuthorizedHomeAccessAccount = $c.OffAuthorizedHomeAccessText.Text
    }
    return (ConvertTo-EobOffboardingRequest -InputObject (Get-EobOffboardingFormRequestData -Values $values) -Config $script:Ui.Config)
}

function Update-EobOffboardingProtection {
    <#
    .SYNOPSIS
        Prüft beim Wechsel zu Schritt 2 vorab, ob das Konto geschützt oder privilegiert ist.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $c = $script:Ui.C
    $user = $script:Ui.Offboarding.User
    $request = ConvertTo-EobOffboardingRequest -Config $script:Ui.Config -InputObject @{
        Identity = [string]$user.ObjectGuid; Template = [string](Get-EobComboValue -Combo $c.OffTemplateCombo); ExitDate = (Get-Date).ToString('yyyy-MM-dd'); Ticket = 'Vorabprüfung'; Reason = 'Vorabprüfung'
    }
    $probe = New-EobOffboardingPlan -Request $request -Config $script:Ui.Config -Simulation
    try {
        $codes = @($probe.Findings | ForEach-Object Code)
        $blocking = @($probe.Findings | Where-Object { $_.Code -in @('OFF_PROTECTED', 'OFF_PRIVILEGED', 'OFF_USER_NOT_FOUND', 'OFF_AD_OFFLINE') })
        if ($blocking.Count -gt 0) {
            $c.OffPrivilegedPanel.Visibility = 'Collapsed'
            $null = Show-EobDialog -Title 'Offboarding nicht möglich' -Kind Error -Message 'Dieses Konto kann nicht über easyONBOARDING ausgeschieden werden.' -Details @($blocking | ForEach-Object Message)
            return $false
        }
        if ($codes -contains 'OFF_PRIVILEGED_ACK_REQUIRED') {
            $c.OffPrivilegedText.Text = ($probe.Findings | Where-Object Code -EQ 'OFF_PRIVILEGED_ACK_REQUIRED' | Select-Object -First 1).Message
            $c.OffPrivilegedPanel.Visibility = 'Visible'
        }
        else {
            $c.OffPrivilegedPanel.Visibility = 'Collapsed'
            $c.OffAcknowledgePrivilegedCheck.IsChecked = $false
        }
        return $true
    }
    finally {
        Clear-EobPlanSecret -Plan $probe -Confirm:$false
    }
}

function Move-EobOffboardingNext {
    [CmdletBinding()]
    param()

    $c = $script:Ui.C
    $state = $script:Ui.Offboarding
    switch ($state.Step) {
        1 {
            if ($null -eq $state.User) { $c.OffValidationText.Text = 'Bitte zuerst ein Konto suchen und auswählen.'; return }
            if (-not (Update-EobOffboardingProtection)) { return }
            Set-EobOffboardingStep -Step 2
        }
        2 {
            foreach ($name in $script:OffboardingFieldMap.Values) { Set-EobFieldError -Control $c[$name] }
            $request = Get-EobOffboardingFormRequest
            $errors = @(Test-EobOffboardingRequest -Request $request -Config $script:Ui.Config | Where-Object Severity -EQ 'Error')
            $unassigned = [System.Collections.Generic.List[string]]::new()
            foreach ($finding in $errors) {
                $target = if ($script:OffboardingFieldMap.ContainsKey([string]$finding.Field)) { $c[$script:OffboardingFieldMap[[string]$finding.Field]] } else { $null }
                if ($null -eq $target) { $unassigned.Add($finding.Message) } else { Set-EobFieldError -Control $target -Message $finding.Message }
            }
            if ($errors.Count -gt 0) {
                $c.OffValidationText.Text = if ($unassigned.Count -gt 0) { $unassigned -join ' ' } else { 'Bitte die markierten Felder prüfen.' }
                return
            }
            if ($c.OffPrivilegedPanel.Visibility -eq 'Visible' -and -not $c.OffAcknowledgePrivilegedCheck.IsChecked) {
                $c.OffValidationText.Text = 'Bitte das Offboarding des privilegierten Kontos ausdrücklich bestätigen.'
                return
            }
            if ($null -ne $state.Plan) { Clear-EobPlanSecret -Plan $state.Plan -Confirm:$false }
            $state.Plan = New-EobOffboardingPlan -Request $request -Config $script:Ui.Config -Simulation:$script:Ui.Simulation
            Show-EobOffboardingPreview
            Set-EobOffboardingStep -Step 3
        }
    }
}

function Show-EobOffboardingPreview {
    [CmdletBinding()]
    param()

    $c = $script:Ui.C
    $plan = $script:Ui.Offboarding.Plan
    $summary = [ordered]@{}
    foreach ($key in $plan.Summary.Keys) { $summary[$key] = $plan.Summary[$key] }
    $due = @()
    if ($null -ne $plan.Offboarding.Template) {
        $due = @(Get-EobOffboardingDuePhase -Plan $plan)
        $summary['Jetzt fällig'] = if ($due.Count -gt 0) { ($due | ForEach-Object { Get-EobUiText -Map $script:PhaseTexts -Key $_ }) -join ', ' } else { 'keine Phase (wird geplant)' }
    }
    Set-EobGridSource -Grid $c.OffPreviewSummaryGrid -Items @(ConvertTo-EobUiSummaryRow -Summary $summary)
    Set-EobGridSource -Grid $c.OffPreviewStepsGrid -Items @($plan.Steps | ForEach-Object { ConvertTo-EobUiStepRow -Step $_ })
    Set-EobGridSource -Grid $c.OffPreviewFindingsGrid -Items @($plan.Findings | Sort-Object -Property @{ Expression = { @('Error', 'Warning', 'Information').IndexOf([string]$_.Severity) } } |
            ForEach-Object { ConvertTo-EobUiFindingRow -Finding $_ })
    $errors = @($plan.Findings | Where-Object Severity -EQ 'Error')
    if ($errors.Count -gt 0) {
        Set-EobBanner -Border $c.OffPreviewBanner -TextBlock $c.OffPreviewBannerText -Kind Error -Text "$($errors.Count) blockierende(r) Befund(e): Eine Ausführung ist nicht möglich."
    }
    else {
        $dueText = if ($due.Count -gt 0) { 'Jetzt ausgeführt werden: ' + (($due | ForEach-Object { Get-EobUiText -Map $script:PhaseTexts -Key $_ }) -join ', ') + '.' } else { 'Jetzt ist keine Phase fällig.' }
        $modeText = if ($plan.Simulation) { 'Simulation: Es werden keine Änderungen vorgenommen.' } else { 'Live: Die Aktionen werden nach Bestätigung ausgeführt; spätere Phasen werden in die Warteschlange übernommen.' }
        Set-EobBanner -Border $c.OffPreviewBanner -TextBlock $c.OffPreviewBannerText -Kind $(if ($plan.Simulation) { 'Info' } else { 'Warning' }) -Text "$dueText $modeText"
    }
    $c.OffExecuteButton.IsEnabled = (Test-EobPlanExecutable -Plan $plan)
}

function Invoke-EobOffboardingExecution {
    [CmdletBinding()]
    param()

    $c = $script:Ui.C
    $state = $script:Ui.Offboarding
    $plan = $state.Plan
    if ($null -eq $plan -or -not (Test-EobPlanExecutable -Plan $plan)) { return }
    if ($script:Ui.Simulation) { $plan.Simulation = $true }
    $selected = @(Select-EobOffboardingPhase -Plan $plan)
    $withSteps = @($selected | Where-Object { $plan.Offboarding.PhaseStepCount[$_] -gt 0 })
    if (-not $plan.Simulation) {
        $phaseText = if ($selected.Count -gt 0) { ($selected | ForEach-Object { Get-EobUiText -Map $script:PhaseTexts -Key $_ }) -join ', ' } else { 'keine' }
        $stepCount = @($plan.Steps | Where-Object { $_.Phase -in $withSteps }).Count
        $answer = Show-EobDialog -Title 'Offboarding ausführen' -Kind Danger -ConfirmText '_Ausführen' -CancelText 'Abbrechen' `
            -Message "Offboarding von $($plan.Subject['DisplayName']) ($($plan.Subject['SamAccountName'])): Jetzt fällige Phasen: $phaseText ($stepCount Aktion(en)). Spätere Phasen werden in die Warteschlange übernommen." `
            -Details @($plan.Steps | Where-Object { $_.Phase -in $withSteps } | Select-Object -First 15 | ForEach-Object { $_.Title })
        if (-not $answer.Confirmed) { return }
    }
    $state.SelectedPhases = $selected
    $state.HandoutRequested = [bool]$c.OffHandoutCheck.IsChecked
    $c.OffHandoutCheck.IsChecked = $false
    $c.OffProgressBar.Value = 0
    $c.OffResultBanner.Visibility = 'Collapsed'
    $c.OffOpenReportButton.Visibility = 'Collapsed'
    if ($withSteps.Count -eq 0) {
        $plan.Status = 'Scheduled'
        Set-EobOffboardingStep -Step 4
        Complete-EobOffboardingExecution -Plan $plan
        return
    }
    Set-EobGridSource -Grid $c.OffResultStepsGrid -Items @($plan.Steps | ForEach-Object { ConvertTo-EobUiStepRow -Step $_ })
    Start-EobUiPlanExecution -Plan $plan -IncludePhase (Get-EobOffboardingIncludePhase -SelectedPhase $selected) -OnProgress 'Update-EobOffboardingProgress' -OnComplete 'Complete-EobOffboardingExecution'
    Set-EobOffboardingStep -Step 4
}

function Update-EobOffboardingProgress {
    [CmdletBinding()]
    param($Plan, [int]$Done, [int]$Total, $Step)

    $c = $script:Ui.C
    $c.OffProgressBar.Value = [Math]::Round(100.0 * $Done / [Math]::Max(1, $Total))
    $c.OffProgressText.Text = "Schritt $Done von $($Total): $($Step.Title) - $(Get-EobUiText -Map $script:StatusTexts -Key $Step.Status)"
    Set-EobGridSource -Grid $c.OffResultStepsGrid -Items @($Plan.Steps | ForEach-Object { ConvertTo-EobUiStepRow -Step $_ })
}

function Complete-EobOffboardingExecution {
    [CmdletBinding()]
    param($Plan)

    $c = $script:Ui.C
    $state = $script:Ui.Offboarding
    $handoutRequested = [bool]$state.HandoutRequested
    $state.HandoutRequested = $false
    $c.OffHandoutCheck.IsChecked = $false
    try {
        $null = Complete-EobOffboardingRun -Plan $Plan -SelectedPhase $state.SelectedPhases -Confirm:$false
    }
    finally {
        Clear-EobPlanSecret -Plan $Plan -Confirm:$false
    }
    $c.OffProgressBar.Value = 100
    $c.OffProgressText.Text = "Abgeschlossen: $(Get-EobUiText -Map $script:StatusTexts -Key $Plan.Status)"
    Set-EobGridSource -Grid $c.OffResultStepsGrid -Items @($Plan.Steps | Where-Object { $_.Status -ne 'Planned' -or $_.Phase -in $state.SelectedPhases } | ForEach-Object { ConvertTo-EobUiStepRow -Step $_ })
    $state.ReportPath = Export-EobUiPlanReport -Plan $Plan
    $handout = Export-EobUiPlanHandout -Plan $Plan -Requested:$handoutRequested
    $c.OffOpenReportButton.Visibility = if ($state.ReportPath) { 'Visible' } else { 'Collapsed' }
    $banner = Get-EobOutcomeBanner -Plan $Plan -Subject "Offboarding von $($Plan.Subject['SamAccountName'])"
    $open = @('Immediate', 'ExitDate', 'Retention' | Where-Object { $_ -notin $Plan.Offboarding.CompletedPhases -and $Plan.Offboarding.PhaseStepCount[$_] -gt 0 })
    $text = $banner.Text + $(if ($handout) { " HandOut: $handout" })
    if (-not $Plan.Simulation -and $open.Count -gt 0) {
        $text += ' Offene Phasen (' + (($open | ForEach-Object { "$(Get-EobUiText -Map $script:PhaseTexts -Key $_) ab $(ConvertTo-EobUiDateText -Value $Plan.Offboarding.PhaseDates[$_])" }) -join ', ') + ') stehen in der Warteschlange.'
    }
    Set-EobBanner -Border $c.OffResultBanner -TextBlock $c.OffResultText -Kind $banner.Kind -Text $text
    Set-EobOffboardingStep -Step 4
    Update-EobOffboardingQueue
}

function Update-EobOffboardingQueue {
    [CmdletBinding()]
    param()

    $c = $script:Ui.C
    $statuses = if ($c.OffQueueShowClosedCheck.IsChecked) { @('Open', 'AwaitingDeletion', 'Completed', 'Cancelled', 'Deleted') } else { @('Open', 'AwaitingDeletion') }
    $items = @(Get-EobOffboardingQueue -Config $script:Ui.Config -Status $statuses)
    Set-EobGridSource -Grid $c.OffQueueGrid -Items @($items | ForEach-Object { ConvertTo-EobUiQueueRow -Item $_ })
    $c.OffQueueInfoText.Text = "$($items.Count) Vorgang/Vorgänge · $(@($items | Where-Object IsDue).Count) fällig · $(@($items | Where-Object DeletionDue).Count) Löschung(en) zur Freigabe"
}

function Get-EobSelectedQueueItem {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $row = $script:Ui.C.OffQueueGrid.SelectedItem
    if ($null -eq $row) {
        $null = Show-EobDialog -Title 'Kein Vorgang ausgewählt' -Kind Info -Message 'Bitte zuerst einen Vorgang in der Warteschlange auswählen.'
        return $null
    }
    return $row.Item
}

function Start-EobOffboardingQueuePhase {
    [CmdletBinding()]
    param()

    $item = Get-EobSelectedQueueItem
    if ($null -eq $item) { return }
    if ($item.Status -ne 'Open') {
        $null = Show-EobDialog -Title 'Keine offene Phase' -Kind Info -Message "Der Vorgang hat den Status '$(Get-EobUiText -Map $script:StatusTexts -Key $item.Status)'."
        return
    }
    $state = $script:Ui.Offboarding
    if ($null -ne $state.Plan) { Clear-EobPlanSecret -Plan $state.Plan -Confirm:$false }
    $plan = New-EobOffboardingPlanFromQueue -QueueEntry $item -Config $script:Ui.Config -Simulation:$script:Ui.Simulation
    $state.Plan = $plan
    $state.FromQueue = $true
    $state.User = $plan.Offboarding.User
    $script:Ui.C.OffTabs.SelectedItem = $script:Ui.C.OffWizardTab
    Show-EobOffboardingPreview
    Set-EobOffboardingStep -Step 3
}

function Invoke-EobOffboardingDeletion {
    [CmdletBinding()]
    param()

    $item = Get-EobSelectedQueueItem
    if ($null -eq $item) { return }
    $plan = New-EobOffboardingDeletionPlan -OperationId $item.OperationId -Config $script:Ui.Config
    $errors = @($plan.Findings | Where-Object Severity -EQ 'Error')
    if ($errors.Count -gt 0) {
        $null = Show-EobDialog -Title 'Löschung nicht zulässig' -Kind Error -Message "Das Konto $($item.SamAccountName) kann derzeit nicht gelöscht werden:" -Details @($errors | ForEach-Object Message)
        return
    }
    $warnings = @($plan.Findings | Where-Object Severity -EQ 'Warning' | ForEach-Object Message)
    if ($script:Ui.Simulation) {
        $handoutRequested = [bool]$script:Ui.C.OffHandoutCheck.IsChecked
        $script:Ui.C.OffHandoutCheck.IsChecked = $false
        $result = Invoke-EobOffboardingFinalDeletion -Plan $plan -WhatIf
        $script:Ui.C.OffHandoutCheck.IsChecked = $false
        $handout = Export-EobUiPlanHandout -Plan $result -Requested:$handoutRequested
        $null = Show-EobDialog -Title 'Löschung simuliert' -Kind Info -Message "Simulation: Das Konto $($item.SamAccountName) würde endgültig gelöscht (Ergebnis: $(Get-EobUiText -Map $script:StatusTexts -Key $result.Status)). Für die tatsächliche Löschung in den Live-Modus wechseln." -Details (@($warnings) + @($(if ($handout) { "HandOut: $handout" })))
        return
    }
    $confirmation = [string]$plan.Summary['Bestätigungstext']
    $answer = Show-EobDialog -Title 'Konto endgültig löschen' -Kind Danger -ConfirmText 'Endgültig _löschen' -CancelText 'Abbrechen' -TypedConfirmation $confirmation `
        -Message "Das Konto $($item.DisplayName) ($($item.SamAccountName)) wird endgültig aus dem Active Directory gelöscht. Vorher wird ein letzter Zustandsbericht gesichert." `
        -Details (@($warnings) + @($plan.Steps | ForEach-Object { @($_.Details) }))
    if (-not $answer.Confirmed) { return }
    $handoutRequested = [bool]$script:Ui.C.OffHandoutCheck.IsChecked
    $script:Ui.C.OffHandoutCheck.IsChecked = $false
    $result = Invoke-EobOffboardingFinalDeletion -Plan $plan -ConfirmationText $answer.Text -Confirm:$false
    $script:Ui.C.OffHandoutCheck.IsChecked = $false
    $report = Export-EobUiPlanReport -Plan $result
    $handout = Export-EobUiPlanHandout -Plan $result -Requested:$handoutRequested
    $banner = Get-EobOutcomeBanner -Plan $result -Subject "Löschung von $($item.SamAccountName)"
    $null = Show-EobDialog -Title 'Endgültige Löschung' -Kind $(if ($banner.Kind -eq 'Success') { 'Success' } elseif ($banner.Kind -eq 'Error') { 'Error' } else { 'Warning' }) `
        -Message $banner.Text -Details (@($result.Steps | ForEach-Object { "$($_.Title): $(Get-EobUiText -Map $script:StatusTexts -Key $_.Status) $($_.Message)" }) + @($(if ($report) { "Bericht: $report" })) + @($(if ($handout) { "HandOut: $handout" })))
    Update-EobOffboardingQueue
}

function Stop-EobOffboardingQueueItem {
    [CmdletBinding()]
    param()

    $item = Get-EobSelectedQueueItem
    if ($null -eq $item) { return }
    if ($item.Status -notin @('Open', 'AwaitingDeletion')) { return }
    $answer = Show-EobDialog -Title 'Vorgang abbrechen' -Kind Warning -ConfirmText 'Vorgang _abbrechen' -CancelText 'Zurück' `
        -Message "Der Offboarding-Vorgang für $($item.SamAccountName) wird beendet. Bereits ausgeführte Aktionen werden nicht zurückgenommen (Zustandsbericht 'vorher' als Grundlage)." `
        -InputPrompt 'Begründung (Pflicht, z. B. Kündigung zurückgenommen):'
    if (-not $answer.Confirmed) { return }
    $result = Stop-EobOffboardingQueueEntry -Config $script:Ui.Config -OperationId $item.OperationId -Reason $answer.Text -Confirm:$false
    $script:Ui.C.OffQueueInfoText.Text = $result.Message
    Update-EobOffboardingQueue
}

function Open-EobOffboardingSnapshotFolder {
    [CmdletBinding()]
    param()

    $item = Get-EobSelectedQueueItem
    if ($null -eq $item) { return }
    $root = [string](Get-EobConfigValue -Config $script:Ui.Config -Section 'Paths' -Key 'SnapshotDirectory' -As Path)
    $folder = Join-Path -Path $root -ChildPath (Get-EobSafeFileName -Name $item.SamAccountName)
    Open-EobPath -Path $folder
}

#endregion

#region Benutzer aktualisieren

function Initialize-EobUserUpdateView {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'source', Justification = 'Signatur von WPF-Ereignishandlern (Sender, EventArgs); der Sender wird nicht benötigt.')]
    [CmdletBinding()]
    param()

    $c = $script:Ui.C
    $script:Ui.Update = @{ User = $null; Plan = $null; HandoutRequested = $false }
    $c.UpdHandoutCheck.IsChecked = $false
    $c.UpdSearchButton.Add_Click({ Invoke-EobUiSafely -Name 'Benutzersuche' -Busy -Action { Invoke-EobUserUpdateSearch } })
    $c.UpdSearchText.Add_KeyDown({
            param($source, $e)
            if ($e.Key -eq [System.Windows.Input.Key]::Return) { $e.Handled = $true; Invoke-EobUiSafely -Name 'Benutzersuche' -Busy -Action { Invoke-EobUserUpdateSearch } }
        })
    $c.UpdResultsGrid.Add_SelectionChanged({ Invoke-EobUiSafely -Name 'Benutzer laden' -Busy -Action { Select-EobUserUpdateUser } })
    $c.UpdPreviewButton.Add_Click({ Invoke-EobUiSafely -Name 'Vorschau' -Busy -Action { Show-EobUserUpdatePreview } })
    $c.UpdExecuteButton.Add_Click({ Invoke-EobUiSafely -Name 'Änderungen ausführen' -Action { Invoke-EobUserUpdateExecution } })
    $c.UpdResetPasswordButton.Add_Click({ Invoke-EobUiSafely -Name 'Kennwort zurücksetzen' -Busy -Action { Invoke-EobPasswordReset } })
}

function Invoke-EobUserUpdateSearch {
    [CmdletBinding()]
    param()

    $c = $script:Ui.C
    $text = ([string]$c.UpdSearchText.Text).Trim()
    if ($text.Length -lt 2) { $c.UpdSearchInfo.Text = 'Bitte mindestens 2 Zeichen eingeben.'; return }
    if (-not (Get-EobAdConnectionInfo).Connected) { throw 'Keine Verbindung zum Active Directory (siehe Tools > AD neu verbinden).' }
    $users = @(Find-EobAdUser -SearchText $text)
    Set-EobGridSource -Grid $c.UpdResultsGrid -Items @($users | ForEach-Object { ConvertTo-EobUiUserRow -User $_ })
    $c.UpdSearchInfo.Text = if ($users.Count -eq 0) { 'Keine Treffer.' } else { "$($users.Count) Treffer." }
}

function Select-EobUserUpdateUser {
    [CmdletBinding()]
    param([string]$Identity)

    $c = $script:Ui.C
    $state = $script:Ui.Update
    if (-not $Identity) {
        $row = $c.UpdResultsGrid.SelectedItem
        if ($null -eq $row) { return }
        $Identity = [string]$row.User.ObjectGuid
    }
    $user = Get-EobAdUser -Identity $Identity
    $state.User = $user
    $state.HandoutRequested = $false
    $c.UpdHandoutCheck.IsChecked = $false
    if ($null -ne $state.Plan) { Clear-EobPlanSecret -Plan $state.Plan -Confirm:$false; $state.Plan = $null }
    $c.UpdSelectedUserText.Text = "Ausgewählt: $($user.DisplayName) ($($user.SamAccountName)) · $($user.UserPrincipalName)" + $(if (-not $user.Enabled) { ' · deaktiviert' } else { '' })
    $c.UpdEnableAccountCheck.IsChecked = $false
    $c.UpdEnableAccountCheck.Visibility = if ($user.Enabled) { 'Collapsed' } else { 'Visible' }
    $c.UpdDisplayNameText.Text = $user.DisplayName
    $c.UpdTitleText.Text = $user.Title
    $c.UpdDepartmentText.Text = $user.Department
    $c.UpdCompanyText.Text = $user.Company
    $c.UpdOfficeText.Text = $user.Office
    $c.UpdOfficePhoneText.Text = $user.OfficePhone
    $c.UpdMobilePhoneText.Text = $user.MobilePhone
    $c.UpdEmployeeIdText.Text = $user.EmployeeId
    $c.UpdDescriptionText.Text = $user.Description
    $c.UpdManagerText.Text = ''
    if ($user.Manager) {
        try { $c.UpdManagerText.Text = (Resolve-EobAdUser -Identity $user.Manager).SamAccountName } catch { $c.UpdManagerText.Text = $user.Manager }
    }
    $state.ManagerText = $c.UpdManagerText.Text

    $memberships = @(Get-EobAdUserGroupMembership -User $user | Where-Object { -not $_.IsPrimary })
    Set-EobListSource -List $c.UpdCurrentGroupsList -Items @($memberships | Sort-Object -Property Name | ForEach-Object {
            $privileged = (Test-EobPrivilegedGroup -Group $_ -Config $script:Ui.Config).IsProtected
            [pscustomobject]@{ Text = if ($privileged) { "$($_.Name)  [privilegiert]" } else { $_.Name }; Value = $_.DistinguishedName; ToolTip = $_.DistinguishedName }
        })
    $memberNames = @($memberships | ForEach-Object { $_.Name; $_.SamAccountName })
    $section = Get-EobConfigSection -Config $script:Ui.Config -Name 'ADGroups'
    Set-EobListSource -List $c.UpdAddGroupsList -Items @($section.Keys | ForEach-Object {
            $groupName = [string]$section[$_]
            if ($groupName -and $groupName -notin $memberNames -and -not (Test-EobPrivilegedGroup -Group $groupName -Config $script:Ui.Config).IsProtected) {
                [pscustomobject]@{ Text = $_; Value = $_; ToolTip = $groupName }
            }
        })
    $c.UpdEditCard.IsEnabled = $true
    $c.UpdExecuteButton.IsEnabled = $false
    $c.UpdResultBanner.Visibility = 'Collapsed'
    Set-EobGridSource -Grid $c.UpdPreviewStepsGrid -Items @()
    Set-EobGridSource -Grid $c.UpdPreviewFindingsGrid -Items @()
}

function Show-EobUserUpdatePreview {
    [CmdletBinding()]
    param()

    $c = $script:Ui.C
    $state = $script:Ui.Update
    if ($null -eq $state.User) { return }
    $changes = @{
        DisplayName = $c.UpdDisplayNameText.Text; Title = $c.UpdTitleText.Text; Department = $c.UpdDepartmentText.Text; Company = $c.UpdCompanyText.Text
        Office = $c.UpdOfficeText.Text; OfficePhone = $c.UpdOfficePhoneText.Text; MobilePhone = $c.UpdMobilePhoneText.Text
        EmployeeId = $c.UpdEmployeeIdText.Text; Description = $c.UpdDescriptionText.Text
    }
    if (([string]$c.UpdManagerText.Text).Trim() -ne [string]$state.ManagerText) { $changes['Manager'] = $c.UpdManagerText.Text }
    $parameters = @{
        Identity = [string]$state.User.ObjectGuid; Changes = $changes; Config = $script:Ui.Config; Simulation = $script:Ui.Simulation
        EnableAccount = [bool]$c.UpdEnableAccountCheck.IsChecked
        AddGroups = @(Get-EobListSelection -List $c.UpdAddGroupsList); RemoveGroups = @(Get-EobListSelection -List $c.UpdCurrentGroupsList)
    }
    $plan = New-EobUserUpdatePlan @parameters
    if ($c.UpdTicketText.Text) { $plan.Summary['Ticket'] = $c.UpdTicketText.Text }
    $state.Plan = $plan
    Set-EobGridSource -Grid $c.UpdPreviewStepsGrid -Items @($plan.Steps | ForEach-Object { ConvertTo-EobUiStepRow -Step $_ })
    Set-EobGridSource -Grid $c.UpdPreviewFindingsGrid -Items @($plan.Findings | ForEach-Object { ConvertTo-EobUiFindingRow -Finding $_ })
    $executable = (Test-EobPlanExecutable -Plan $plan) -and $plan.Steps.Count -gt 0
    $c.UpdExecuteButton.IsEnabled = $executable
    $text = if (-not (Test-EobPlanExecutable -Plan $plan)) { 'Die Änderungen enthalten Fehler (siehe Prüfergebnisse).' } elseif ($plan.Steps.Count -eq 0) { 'Keine Änderungen gegenüber dem aktuellen Stand.' } else { "$($plan.Steps.Count) Änderung(en) geplant." }
    Set-EobBanner -Border $c.UpdResultBanner -TextBlock $c.UpdResultText -Kind $(if ($executable) { 'Info' } elseif ($plan.Steps.Count -eq 0 -and (Test-EobPlanExecutable -Plan $plan)) { 'Info' } else { 'Error' }) -Text $text
}

function Invoke-EobUserUpdateExecution {
    [CmdletBinding()]
    param()

    $c = $script:Ui.C
    $plan = $script:Ui.Update.Plan
    if ($null -eq $plan -or -not (Test-EobPlanExecutable -Plan $plan)) { return }
    if ($script:Ui.Simulation) { $plan.Simulation = $true }
    if (-not $plan.Simulation) {
        $answer = Show-EobDialog -Title 'Änderungen ausführen' -Kind Question -ConfirmText '_Ausführen' -CancelText 'Abbrechen' `
            -Message "Für $($plan.Subject['SamAccountName']) werden $($plan.Steps.Count) Änderung(en) ausgeführt." -Details @($plan.Steps | ForEach-Object { $_.Title })
        if (-not $answer.Confirmed) { return }
    }
    $script:Ui.Update.HandoutRequested = [bool]$c.UpdHandoutCheck.IsChecked
    $c.UpdHandoutCheck.IsChecked = $false
    $c.UpdExecuteButton.IsEnabled = $false
    $c.UpdPreviewButton.IsEnabled = $false
    Start-EobUiPlanExecution -Plan $plan -OnProgress 'Update-EobUserUpdateProgress' -OnComplete 'Complete-EobUserUpdateExecution'
}

function Update-EobUserUpdateProgress {
    [CmdletBinding()]
    param($Plan, [int]$Done, [int]$Total, $Step)

    $c = $script:Ui.C
    $text = "Schritt $Done von $($Total): $($Step.Title) - $(Get-EobUiText -Map $script:StatusTexts -Key $Step.Status)"
    Set-EobBanner -Border $c.UpdResultBanner -TextBlock $c.UpdResultText -Kind Info -Text $text
    Set-EobGridSource -Grid $c.UpdPreviewStepsGrid -Items @($Plan.Steps | ForEach-Object { ConvertTo-EobUiStepRow -Step $_ })
}

function Complete-EobUserUpdateExecution {
    [CmdletBinding()]
    param($Plan)

    $c = $script:Ui.C
    $handoutRequested = [bool]$script:Ui.Update.HandoutRequested
    $script:Ui.Update.HandoutRequested = $false
    $c.UpdHandoutCheck.IsChecked = $false
    Set-EobGridSource -Grid $c.UpdPreviewStepsGrid -Items @($Plan.Steps | ForEach-Object { ConvertTo-EobUiStepRow -Step $_ })
    $report = Export-EobUiPlanReport -Plan $Plan
    $handout = Export-EobUiPlanHandout -Plan $Plan -Requested:$handoutRequested
    $banner = Get-EobOutcomeBanner -Plan $Plan -Subject "Aktualisierung von $($Plan.Subject['SamAccountName'])"
    Set-EobBanner -Border $c.UpdResultBanner -TextBlock $c.UpdResultText -Kind $banner.Kind -Text ($banner.Text + $(if ($report) { " Bericht: $report" }) + $(if ($handout) { " HandOut: $handout" }))
    $c.UpdPreviewButton.IsEnabled = $true
    if (-not $Plan.Simulation) {
        $identity = [string]$Plan.Subject['ObjectGuid']
        $keep = $c.UpdResultText.Text
        Select-EobUserUpdateUser -Identity $identity
        Set-EobBanner -Border $c.UpdResultBanner -TextBlock $c.UpdResultText -Kind $banner.Kind -Text $keep
        Set-EobGridSource -Grid $c.UpdPreviewStepsGrid -Items @($Plan.Steps | ForEach-Object { ConvertTo-EobUiStepRow -Step $_ })
    }
}

function Invoke-EobPasswordReset {
    [CmdletBinding()]
    param()

    $c = $script:Ui.C
    $user = $script:Ui.Update.User
    if ($null -eq $user) { return }
    $answer = Show-EobDialog -Title 'Kennwort zurücksetzen' -Kind Danger -ConfirmText '_Zurücksetzen' -CancelText 'Abbrechen' `
        -Message "Das Kennwort von $($user.DisplayName) ($($user.SamAccountName)) wird auf ein neues, sicheres Zufallskennwort gesetzt. Der Benutzer muss es bei der nächsten Anmeldung ändern. Das neue Kennwort wird einmalig angezeigt."
    if (-not $answer.Confirmed) { return }
    $handoutRequested = [bool]$c.UpdHandoutCheck.IsChecked
    $c.UpdHandoutCheck.IsChecked = $false
    $domainPolicy = $null
    try { $domainPolicy = Get-EobAdPasswordPolicy } catch { Write-EobLog -Level Warning -Action 'UI' -Message "Domänenrichtlinie nicht lesbar: $($_.Exception.Message)" }
    $plan = New-EobPasswordResetPlan -Identity ([string]$user.ObjectGuid) -Config $script:Ui.Config -DomainPasswordPolicy $domainPolicy -Simulation:$script:Ui.Simulation
    try {
        $errors = @($plan.Findings | Where-Object Severity -EQ 'Error')
        if ($errors.Count -gt 0) {
            $null = Show-EobDialog -Title 'Kennwort-Reset nicht möglich' -Kind Error -Message 'Der Kennwort-Reset ist für dieses Konto nicht zulässig:' -Details @($errors | ForEach-Object Message)
            return
        }
        $result = Invoke-EobPlan -Plan $plan -WhatIf:$plan.Simulation -Confirm:$false
        $null = Export-EobUiPlanReport -Plan $result
        $handout = Export-EobUiPlanHandout -Plan $result -Requested:$handoutRequested
        $banner = Get-EobOutcomeBanner -Plan $result -Subject "Kennwort-Reset für $($user.SamAccountName)"
        Set-EobBanner -Border $c.UpdResultBanner -TextBlock $c.UpdResultText -Kind $banner.Kind -Text ($banner.Text + $(if ($handout) { " HandOut: $handout" }))
        $secure = Get-EobPlanCredential -Plan $result
        if ($null -ne $secure) {
            Show-EobCredentialDialog -DisplayName $user.DisplayName -SamAccountName $user.SamAccountName -UserPrincipalName $user.UserPrincipalName -Password $secure
        }
    }
    finally {
        $c.UpdHandoutCheck.IsChecked = $false
        Clear-EobPlanSecret -Plan $plan -Confirm:$false
    }
}

#endregion

#region Massenverarbeitung

function Initialize-EobBulkView {
    [CmdletBinding()]
    param()

    $c = $script:Ui.C
    $script:Ui.Bulk = @{ Batch = $null; Mode = 'Onboarding'; Index = 0; Timer = $null; Cancel = $false; Credentials = $null }
    $c.BulkBrowseButton.Add_Click({
            Invoke-EobUiSafely -Name 'Datei auswählen' -Action {
                $file = Select-EobOpenFile -Filter 'CSV-Dateien (*.csv)|*.csv|Alle Dateien (*.*)|*.*' -Title 'CSV-Datei auswählen'
                if ($file) { $script:Ui.C.BulkFileText.Text = $file }
            }
        })
    $c.BulkImportButton.Add_Click({ Invoke-EobUiSafely -Name 'CSV prüfen' -Busy -Action { Import-EobBulkFile } })
    $c.BulkExecuteButton.Add_Click({ Invoke-EobUiSafely -Name 'Massenverarbeitung' -Action { Start-EobBulkExecution } })
    $c.BulkCancelButton.Add_Click({ $script:Ui.Bulk.Cancel = $true; $script:Ui.C.BulkProgressText.Text = 'Abbruch angefordert: Die laufende Zeile wird beendet.' })
    $c.BulkExportButton.Add_Click({ Invoke-EobUiSafely -Name 'Ergebnis exportieren' -Action { Export-EobBulkResult } })
    $c.BulkModeOnboardingRadio.Add_Checked({ Invoke-EobUiSafely -Name 'Modus' -Action { Update-EobBulkMode } })
    $c.BulkModeOffboardingRadio.Add_Checked({ Invoke-EobUiSafely -Name 'Modus' -Action { Update-EobBulkMode } })
    Update-EobBulkMode
}

function Update-EobBulkMode {
    [CmdletBinding()]
    param()

    $c = $script:Ui.C
    $state = $script:Ui.Bulk
    # Während einer Ausführung darf der Stapel nicht verworfen werden (die Auswahl ist dann gesperrt).
    if ($null -ne $script:Ui.Execution) { return }
    $state.Mode = if ($c.BulkModeOffboardingRadio.IsChecked) { 'Offboarding' } else { 'Onboarding' }
    Clear-EobUiBulkSecret
    $state.Batch = $null
    $state.Rows = $null
    Set-EobGridSource -Grid $c.BulkItemsGrid -Items @()
    $c.BulkExecuteButton.IsEnabled = $false
    $c.BulkExportButton.IsEnabled = $false
    $c.BulkSummaryBanner.Visibility = 'Collapsed'
    $c.BulkProgressBar.Value = 0
    $c.BulkProgressText.Text = ''
    if ($state.Mode -eq 'Onboarding') {
        $c.BulkFormatHint.Text = 'Pflicht: Vorname/FirstName, Nachname/LastName. Optional u. a. Department, OU, Manager, Groups, StartDate.'
        $delivery = [string](Get-EobConfigValue -Config $script:Ui.Config -Section 'Bulk' -Key 'PasswordDelivery')
        $c.BulkPasswordHint.Text = if ($delivery -eq 'Print') { 'Kennwörter werden nach Abschluss gedruckt und danach verworfen.' } else { 'Kennwörter werden nicht angezeigt; bei Übergabe per Kennwort-Reset freischalten.' }
    }
    else {
        $c.BulkFormatHint.Text = 'Pflicht: SamAccountName/UPN/Mail, ExitDate. Optional u. a. Template, Ticket, Reason, ForwardTo.'
        $c.BulkPasswordHint.Text = 'Zufallskennwörter werden weder angezeigt noch gespeichert.'
    }
}

function Import-EobBulkFile {
    [CmdletBinding()]
    param()

    $c = $script:Ui.C
    $state = $script:Ui.Bulk
    $path = ([string]$c.BulkFileText.Text).Trim()
    if (-not $path) { throw 'Bitte eine CSV-Datei auswählen.' }
    $online = (Get-EobAdConnectionInfo).Connected
    if ($state.Mode -eq 'Onboarding') {
        $import = Import-EobOnboardingCsv -Path $path -Config $script:Ui.Config
        $domainPolicy = $null
        if ($online) { try { $domainPolicy = Get-EobAdPasswordPolicy } catch { Write-EobLog -Level Warning -Action 'UI' -Message $_.Exception.Message } }
        $batch = New-EobOnboardingBatch -Import $import -Config $script:Ui.Config -Simulation:$script:Ui.Simulation -SkipDirectoryCheck:(-not $online) -DomainPasswordPolicy $domainPolicy
    }
    else {
        if (-not $online) { throw 'Für das Massen-Offboarding ist eine AD-Verbindung erforderlich.' }
        $import = Import-EobOffboardingCsv -Path $path -Config $script:Ui.Config
        $batch = New-EobOffboardingBatch -Import $import -Config $script:Ui.Config -Simulation:$script:Ui.Simulation
    }
    # Kennwörter des bisherigen Stapels erst verwerfen, wenn der neue Stapel vollständig erstellt ist.
    Clear-EobUiBulkSecret
    $state.Batch = $batch
    Update-EobBulkGrid
    $importErrors = @($batch.ImportFindings | Where-Object Severity -EQ 'Error')
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($finding in @($batch.ImportFindings)) { $lines.Add("$(Get-EobUiText -Map $script:SeverityTexts -Key $finding.Severity): $($finding.Message)") }
    $lines.Add("$(@($batch.Items).Count) Zeile(n) geprüft, $($batch.ExecutableCount) ausführbar, $(@($batch.Items | Where-Object State -EQ 'Error').Count) mit Fehlern.")
    $kind = if ($importErrors.Count -gt 0 -or $batch.IsBlocked) { 'Error' } elseif ($batch.ExecutableCount -lt @($batch.Items).Count) { 'Warning' } else { 'Info' }
    Set-EobBanner -Border $c.BulkSummaryBanner -TextBlock $c.BulkSummaryText -Kind $kind -Text ($lines -join "`n")
    $c.BulkExecuteButton.IsEnabled = (-not $batch.IsBlocked) -and $batch.ExecutableCount -gt 0
    $c.BulkExportButton.IsEnabled = $false
}

function Update-EobBulkGrid {
    [CmdletBinding()]
    param([int]$Index = -1)

    $state = $script:Ui.Bulk
    if ($null -eq $state.Batch) { return }
    if ($Index -ge 0) {
        # Der DispatcherTimer und alle Aufrufer laufen auf dem UI-Thread.
        # Replace benachrichtigt WPF nur über die betroffene Zeile.
        $state.Rows[$Index] = ConvertTo-EobBulkRow -Item $state.Batch.Items[$Index] -Mode $state.Mode
        return
    }
    $state.Rows = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
    foreach ($item in $state.Batch.Items) {
        $state.Rows.Add((ConvertTo-EobBulkRow -Item $item -Mode $state.Mode))
    }
    $script:Ui.C.BulkItemsGrid.ItemsSource = $state.Rows
}

function ConvertTo-EobBulkRow {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Item, [Parameter(Mandatory)][string]$Mode)

    $outcome = [string](Get-EobPropertyValue -InputObject $Item -Name 'Outcome' -Default '')
    $name = if ($Mode -eq 'Onboarding') { "$($Item.Request.GivenName) $($Item.Request.Surname)".Trim() } else { [string]$Item.Request.Identity }
    [pscustomobject]@{
        RowNumber    = $Item.RowNumber
        Name         = $name
        Account      = [string](Get-EobPropertyValue -InputObject $Item.Plan.Subject -Name 'SamAccountName' -Default '')
        StateText    = Get-EobUiText -Map $script:StatusTexts -Key $Item.State
        OutcomeText  = if ($outcome) { Get-EobUiText -Map $script:StatusTexts -Key $outcome } else { '' }
        MessagesText = (@($Item.Messages) -join ' | ')
    }
}

function Start-EobBulkExecution {
    [CmdletBinding()]
    param()

    $c = $script:Ui.C
    $state = $script:Ui.Bulk
    $batch = $state.Batch
    if ($null -eq $batch -or $batch.IsBlocked -or $null -ne $script:Ui.Execution) { return }
    $count = $batch.ExecutableCount
    if (-not $script:Ui.Simulation) {
        $typed = if ($batch.RequiresTypedConfirmation) { "AUSFÜHREN $count" } else { '' }
        $answer = Show-EobDialog -Title "Massen-$($state.Mode) ausführen" -Kind Danger -ConfirmText '_Ausführen' -CancelText 'Abbrechen' -TypedConfirmation $typed `
            -Message "$count Zeile(n) werden jetzt nacheinander ausgeführt. Fehlerhafte Zeilen werden übersprungen, Fehler einzelner Zeilen brechen den Stapel nicht ab."
        if (-not $answer.Confirmed) { return }
    }
    $state.Index = 0
    $state.Cancel = $false
    $state.Credentials = [System.Collections.Generic.List[object]]::new()
    $level = if ($script:Ui.Simulation) { 'Information' } else { 'Audit' }
    Write-EobLog -Level $level -OperationId $batch.OperationId -Action "Bulk$($state.Mode)Started" -Message "$count von $(@($batch.Items).Count) Zeilen werden verarbeitet (Simulation: $($script:Ui.Simulation))."
    $timer = [System.Windows.Threading.DispatcherTimer]::new([System.Windows.Threading.DispatcherPriority]::Background)
    $timer.Interval = [TimeSpan]::FromMilliseconds(60)
    $timer.Add_Tick({ Invoke-EobUiSafely -Name 'Massenverarbeitung' -Action { Invoke-EobBulkTick } })
    $state.Timer = $timer
    $script:Ui.Execution = @{ Plan = $null; Timer = $timer; Bulk = $true }
    Set-EobUiBusy -Busy $true
    $c.BulkExecuteButton.IsEnabled = $false
    $c.BulkImportButton.IsEnabled = $false
    $c.BulkModeOnboardingRadio.IsEnabled = $false
    $c.BulkModeOffboardingRadio.IsEnabled = $false
    $c.BulkCancelButton.IsEnabled = $true
    $timer.Start()
}

function Invoke-EobBulkTick {
    [CmdletBinding()]
    param()

    $c = $script:Ui.C
    $state = $script:Ui.Bulk
    $batch = $state.Batch
    $state.Timer.Stop()
    $failure = $null
    try {
        $items = $batch.Items
        if ($state.Index -lt $items.Count -and -not $state.Cancel) {
            $item = $items[$state.Index]
            $state.Index++
            if ($item.State -eq 'Error') {
                Add-Member -InputObject $item -NotePropertyName 'Outcome' -NotePropertyValue 'NotExecuted' -Force
            }
            else {
                try {
                    if ($script:Ui.Simulation) { $item.Plan.Simulation = $true }
                    if ($state.Mode -eq 'Onboarding') {
                        $result = Invoke-EobOnboardingPlan -Plan $item.Plan -WhatIf:$item.Plan.Simulation -Confirm:$false
                        $secure = Get-EobPlanCredential -Plan $result
                        if ($null -ne $secure -and [string](Get-EobConfigValue -Config $script:Ui.Config -Section 'Bulk' -Key 'PasswordDelivery') -eq 'Print') {
                            $state.Credentials.Add([pscustomobject]@{
                                    Name = [string]$result.Subject['DisplayName']; SamAccountName = [string]$result.Subject['SamAccountName']
                                    UserPrincipalName = [string]$result.Subject['UserPrincipalName']; Password = $secure.Copy()
                                })
                        }
                    }
                    else {
                        $result = Invoke-EobOffboardingPlan -Plan $item.Plan -WhatIf:$item.Plan.Simulation -Confirm:$false
                    }
                    Add-Member -InputObject $item -NotePropertyName 'Outcome' -NotePropertyValue ([string]$result.Status) -Force
                }
                catch {
                    Add-Member -InputObject $item -NotePropertyName 'Outcome' -NotePropertyValue 'Failed' -Force
                    $item.Messages = @($item.Messages) + (Protect-EobSensitiveText -Text $_.Exception.Message)
                }
                finally {
                    Clear-EobPlanSecret -Plan $item.Plan -Confirm:$false
                }
            }
            $c.BulkProgressBar.Value = [Math]::Round(100.0 * $state.Index / [Math]::Max(1, $items.Count))
            $c.BulkProgressText.Text = "Zeile $($state.Index) von $($items.Count) verarbeitet."
            Update-EobBulkGrid -Index ($state.Index - 1)
            if ($state.Index -lt $items.Count -and -not $state.Cancel) { $state.Timer.Start(); return }
        }
    }
    catch {
        # Ein Fehler außerhalb der Zeilenverarbeitung (z. B. Anzeige) beendet den Stapel geordnet;
        # sonst bliebe die Ausführungssperre bestehen und das Fenster ließe sich nicht mehr schließen.
        $state.Cancel = $true
        $failure = $_
    }
    Complete-EobBulkExecution
    if ($null -ne $failure) { throw $failure }
}

function Complete-EobBulkExecution {
    [CmdletBinding()]
    param()

    $c = $script:Ui.C
    $state = $script:Ui.Bulk
    $batch = $state.Batch
    $script:Ui.Execution = $null
    Set-EobUiBusy -Busy $false
    $c.BulkCancelButton.IsEnabled = $false
    $c.BulkImportButton.IsEnabled = $true
    $c.BulkExportButton.IsEnabled = $true
    $c.BulkModeOnboardingRadio.IsEnabled = $true
    $c.BulkModeOffboardingRadio.IsEnabled = $true
    for ($index = 0; $index -lt $batch.Items.Count; $index++) {
        $item = $batch.Items[$index]
        if ($null -eq (Get-EobPropertyValue -InputObject $item -Name 'Outcome' -Default $null)) {
            Add-Member -InputObject $item -NotePropertyName 'Outcome' -NotePropertyValue 'NotExecuted' -Force
            # Ein Anzeigefehler darf Protokoll und Behandlung der Zugangsdaten nicht verhindern.
            try { Update-EobBulkGrid -Index $index } catch { Write-EobLog -Level Warning -Action 'UI' -Message "Ergebnistabelle konnte nicht aktualisiert werden: $($_.Exception.Message)" }
        }
    }
    # Nicht ausgeführte Zeilen (Fehler, Abbruch) halten sonst ihre Kennwörter bis zum Programmende.
    Clear-EobUiBulkSecret
    $failed = @($batch.Items | Where-Object { $_.Outcome -eq 'Failed' }).Count
    $level = if ($script:Ui.Simulation) { 'Information' } else { 'Audit' }
    Write-EobLog -Level $level -OperationId $batch.OperationId -Action "Bulk$($state.Mode)Completed" -Result $(if ($failed -gt 0) { 'Failed' } else { 'Succeeded' }) `
        -Message "Massenverarbeitung beendet ($failed fehlgeschlagen$(if ($state.Cancel) { ', abgebrochen' }))."
    $c.BulkProgressText.Text = "Abgeschlossen: $(@($batch.Items | Where-Object { $_.Outcome -in @('Succeeded', 'Simulated', 'CompletedWithWarnings', 'Scheduled') }).Count) erfolgreich, $failed fehlgeschlagen$(if ($state.Cancel) { ', abgebrochen' })."

    $credentials = $state.Credentials
    $state.Credentials = $null
    if ($null -ne $credentials -and $credentials.Count -gt 0) {
        try {
            $answer = Show-EobDialog -Title 'Zugangsdaten drucken' -Kind Question -ConfirmText '_Drucken' -CancelText 'Verwerfen' `
                -Message "Für $($credentials.Count) neue(s) Konto/Konten liegen Zugangsdaten vor. Sie können jetzt direkt aus dem Speicher gedruckt werden; danach werden sie verworfen."
            $printed = $false
            if ($answer.Confirmed) { $printed = Invoke-EobCredentialPrint -Entries $credentials.ToArray() }
            if (-not $printed) {
                $null = Show-EobDialog -Title 'Zugangsdaten verworfen' -Kind Warning -Message 'Die Kennwörter wurden nicht gedruckt und sind verworfen. Bitte die Konten bei der Übergabe per Kennwort-Reset freischalten.'
            }
        }
        finally {
            foreach ($entry in $credentials) { $entry.Password.Dispose() }
        }
    }
}

function Clear-EobUiBulkSecret {
    <#
    .SYNOPSIS
        Entfernt die Kennwörter aller Pläne des geladenen Stapels aus dem Speicher und der Redaktionsliste.
    #>
    [CmdletBinding()]
    param()

    if ($null -eq $script:Ui -or $script:Ui.Bulk -isnot [hashtable] -or $null -eq $script:Ui.Bulk['Batch']) { return }
    foreach ($item in @($script:Ui.Bulk['Batch'].Items)) {
        $plan = Get-EobPropertyValue -InputObject $item -Name 'Plan'
        if ($null -eq $plan) { continue }
        try { Clear-EobPlanSecret -Plan $plan -Confirm:$false } catch { Write-Verbose $_.Exception.Message }
    }
}

function Export-EobBulkResult {
    [CmdletBinding()]
    param()

    $state = $script:Ui.Bulk
    if ($null -eq $state.Batch) { return }
    $file = Select-EobSaveFile -Filter 'CSV (*.csv)|*.csv|JSON (*.json)|*.json' -Title 'Ergebnis exportieren' -FileName ('easyONB_{0}_{1}.csv' -f $state.Mode, (Get-Date).ToString('yyyyMMdd-HHmm'))
    if (-not $file) { return }
    $format = if ([System.IO.Path]::GetExtension($file) -ieq '.json') { 'Json' } else { 'Csv' }
    $path = if ($state.Mode -eq 'Onboarding') { Export-EobBatchResult -Batch $state.Batch -Path $file -Format $format -Confirm:$false } else { Export-EobOffboardingBatchResult -Batch $state.Batch -Path $file -Format $format -Confirm:$false }
    $script:Ui.C.BulkProgressText.Text = "Ergebnis exportiert: $path"
}

#endregion

#region Reports und Audit

function Initialize-EobReportsView {
    [CmdletBinding()]
    param()

    $c = $script:Ui.C
    Set-EobComboSource -Combo $c.ReportsDaysCombo -SelectedValue '30' -Items @(
        [pscustomobject]@{ Text = 'Letzte 7 Tage'; Value = '7' }, [pscustomobject]@{ Text = 'Letzte 30 Tage'; Value = '30' }
        [pscustomobject]@{ Text = 'Letzte 90 Tage'; Value = '90' }, [pscustomobject]@{ Text = 'Letztes Jahr'; Value = '365' }
    )
    $c.AuditFromPicker.SelectedDate = (Get-Date).Date.AddDays(-7)
    $c.AuditToPicker.SelectedDate = (Get-Date).Date
    $c.ReportsRefreshButton.Add_Click({ Invoke-EobUiSafely -Name 'Berichte' -Busy -Action { Update-EobReportList } })
    $c.ReportsDaysCombo.Add_SelectionChanged({ Invoke-EobUiSafely -Name 'Berichte' -Busy -Action { Update-EobReportList } })
    $c.ReportsOpenButton.Add_Click({ Invoke-EobUiSafely -Name 'Bericht öffnen' -Action { Open-EobSelectedReport } })
    $c.ReportsGrid.Add_MouseDoubleClick({ Invoke-EobUiSafely -Name 'Bericht öffnen' -Action { Open-EobSelectedReport } })
    $c.ReportsOpenFolderButton.Add_Click({ Invoke-EobUiSafely -Name 'Berichtsordner' -Action { Open-EobPath -Path (Get-EobReportDirectory -Config $script:Ui.Config) } })
    $c.AuditLoadButton.Add_Click({ Invoke-EobUiSafely -Name 'Audit laden' -Busy -Action { Update-EobAuditList } })
    $c.AuditExportCsvButton.Add_Click({ Invoke-EobUiSafely -Name 'Audit-Export' -Action { Export-EobUiAudit -Format Csv } })
    $c.AuditExportHtmlButton.Add_Click({ Invoke-EobUiSafely -Name 'Audit-Export' -Action { Export-EobUiAudit -Format Html } })
}

function Update-EobReportList {
    [CmdletBinding()]
    param()

    $c = $script:Ui.C
    $days = [int](Get-EobComboValue -Combo $c.ReportsDaysCombo)
    if ($days -le 0) { $days = 30 }
    $files = @(Get-EobReportFile -Config $script:Ui.Config -Days $days)
    Set-EobGridSource -Grid $c.ReportsGrid -Items @($files | ForEach-Object {
            [pscustomobject]@{
                Name        = $_.Name
                Kind        = $_.Directory.Name
                Format      = $_.Extension.TrimStart('.').ToUpperInvariant()
                ChangedText = $_.LastWriteTime.ToString('dd.MM.yyyy HH:mm')
                SizeText    = '{0:N0} KB' -f [Math]::Ceiling($_.Length / 1KB)
                Path        = $_.FullName
            }
        })
    $c.ReportsInfoText.Text = "$($files.Count) Datei(en) in $(Get-EobReportDirectory -Config $script:Ui.Config)"
}

function Open-EobSelectedReport {
    [CmdletBinding()]
    param()

    $row = $script:Ui.C.ReportsGrid.SelectedItem
    if ($null -eq $row) { return }
    $root = Get-EobReportDirectory -Config $script:Ui.Config
    if (-not (Test-EobPathWithin -Path $row.Path -Root $root)) { throw 'Die Datei liegt außerhalb des Berichtsverzeichnisses.' }
    Open-EobPath -Path $row.Path
}

function Get-EobUiAuditRange {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $c = $script:Ui.C
    $from = if ($c.AuditFromPicker.SelectedDate) { ([datetime]$c.AuditFromPicker.SelectedDate).Date } else { (Get-Date).Date.AddDays(-7) }
    $to = if ($c.AuditToPicker.SelectedDate) { ([datetime]$c.AuditToPicker.SelectedDate).Date.AddDays(1).AddSeconds(-1) } else { Get-Date }
    if ($to -lt $from) { throw 'Das Enddatum liegt vor dem Startdatum.' }
    [pscustomobject]@{ From = $from; To = $to }
}

function Update-EobAuditList {
    [CmdletBinding()]
    param()

    $c = $script:Ui.C
    $range = Get-EobUiAuditRange
    $filter = ([string]$c.AuditFilterText.Text).Trim()
    $entries = @(Get-EobAuditEntry -From $range.From -To $range.To)
    if ($filter) {
        # Teilzeichenfolge statt -like: Eingaben wie "[" oder "*" sind kein ungültiges Platzhaltermuster.
        $comparison = [System.StringComparison]::OrdinalIgnoreCase
        $entries = @($entries | Where-Object {
                ([string]$_.Target).IndexOf($filter, $comparison) -ge 0 -or ([string]$_.Action).IndexOf($filter, $comparison) -ge 0 -or
                ([string]$_.OperationId).IndexOf($filter, $comparison) -ge 0 -or ([string]$_.Actor).IndexOf($filter, $comparison) -ge 0
            })
    }
    $rows = @($entries | Sort-Object -Property Timestamp -Descending | Select-Object -First 2000 | ForEach-Object {
            [pscustomobject]@{
                TimeText = ConvertTo-EobUiDateText -Value $_.Timestamp -WithTime; Action = [string]$_.Action; Target = [string]$_.Target
                Result = Get-EobUiText -Map $script:StatusTexts -Key ([string]$_.Result); Actor = [string]$_.Actor; Message = [string]$_.Message; OperationId = [string]$_.OperationId
            }
        })
    Set-EobGridSource -Grid $c.AuditGrid -Items $rows
    $failed = @($entries | Where-Object { [string]$_.Result -eq 'Failed' }).Count
    $c.AuditSummaryText.Text = "$($entries.Count) Einträge$(if ($entries.Count -gt 2000) { ' (Anzeige der neuesten 2000)' }) · $failed fehlgeschlagen · Zeitraum $(ConvertTo-EobUiDateText -Value $range.From) bis $(ConvertTo-EobUiDateText -Value $range.To)"
}

function Export-EobUiAudit {
    [CmdletBinding()]
    param([ValidateSet('Csv', 'Html')][string]$Format = 'Csv')

    $range = Get-EobUiAuditRange
    $extension = $Format.ToLowerInvariant()
    $file = Select-EobSaveFile -Filter "$Format (*.$extension)|*.$extension" -Title 'Audit exportieren' -FileName ('easyONB_Audit_{0}_{1}.{2}' -f $range.From.ToString('yyyyMMdd'), $range.To.ToString('yyyyMMdd'), $extension)
    if (-not $file) { return }
    $path = Export-EobAuditReport -Path $file -From $range.From -To $range.To -Format $Format -Confirm:$false
    $script:Ui.C.AuditSummaryText.Text = "Exportiert: $path"
}

#endregion

#region Tools

function Initialize-EobToolsView {
    [CmdletBinding()]
    param()

    $c = $script:Ui.C
    $c.ToolsStatusRefreshButton.Add_Click({ Invoke-EobUiSafely -Name 'Status' -Busy -Action { Update-EobToolsStatus } })
    $c.ToolsAdReconnectButton.Add_Click({
            Invoke-EobUiSafely -Name 'AD verbinden' -Busy -Action {
                $info = Initialize-EobAdConnection -Config $script:Ui.Config
                Add-EobToolsOutput -Text $(if ($info.Connected) { "AD verbunden: $($info.Server)" } else { "AD nicht verbunden: $($info.LastError)" })
                Update-EobStatusBar
                Update-EobToolsStatus
            }
        })
    $c.ToolsExchangeConnectButton.Add_Click({ Invoke-EobUiSafely -Name 'Exchange verbinden' -Busy -Action { Add-EobToolsOutput -Text (Connect-EobExchange -Config $script:Ui.Config -Confirm:$false).Message; Update-EobToolsStatus } })
    $c.ToolsExchangeDisconnectButton.Add_Click({ Invoke-EobUiSafely -Name 'Exchange trennen' -Busy -Action { Add-EobToolsOutput -Text (Disconnect-EobExchange -Confirm:$false).Message; Update-EobToolsStatus } })
    $c.ToolsGraphConnectButton.Add_Click({ Invoke-EobUiSafely -Name 'Graph verbinden' -Busy -Action { Add-EobToolsOutput -Text (Connect-EobGraph -Config $script:Ui.Config -Confirm:$false).Message; Update-EobToolsStatus } })
    $c.ToolsGraphDisconnectButton.Add_Click({ Invoke-EobUiSafely -Name 'Graph trennen' -Busy -Action { Add-EobToolsOutput -Text (Disconnect-EobGraph -Confirm:$false).Message; Update-EobToolsStatus } })
    $c.ToolsSmtpTestButton.Add_Click({
            Invoke-EobUiSafely -Name 'SMTP prüfen' -Busy -Action {
                $status = Get-EobSmtpStatus -Config $script:Ui.Config -TestConnection
                Add-EobToolsOutput -Text "SMTP: $(Get-EobUiText -Map $script:StateTexts -Key $status.State) - $($status.Detail) $($status.Hint)"
            }
        })
    $c.ToolsFileServerTestButton.Add_Click({
            Invoke-EobUiSafely -Name 'Dateiserver prüfen' -Busy -Action {
                $status = Get-EobFileServerStatus -Config $script:Ui.Config -TestConnection
                Add-EobToolsOutput -Text "Dateiserver: $(Get-EobUiText -Map $script:StateTexts -Key $status.State) - $($status.Detail) $($status.Hint)"
            }
        })
    $c.ToolsEntraTestButton.Add_Click({
            Invoke-EobUiSafely -Name 'Entra Connect prüfen' -Busy -Action {
                $status = Get-EobEntraConnectStatus -Config $script:Ui.Config -TestConnection
                Add-EobToolsOutput -Text "Entra Connect: $(Get-EobUiText -Map $script:StateTexts -Key $status.State) - $($status.Detail) $($status.Hint)"
            }
        })
    $c.ToolsConfigCheckButton.Add_Click({ Invoke-EobUiSafely -Name 'Konfiguration prüfen' -Busy -Action { Invoke-EobToolsConfigCheck } })
    $c.ToolsMigrateButton.Add_Click({ Invoke-EobUiSafely -Name 'Konfiguration migrieren' -Action { Invoke-EobToolsMigration } })
    $c.ToolsOpenConfigFolderButton.Add_Click({ Invoke-EobUiSafely -Name 'Konfigurationsordner' -Action { Open-EobPath -Path (Split-Path -Parent (Get-EobUiConfigPath)) } })
    $c.ToolsOpenLogFolderButton.Add_Click({ Invoke-EobUiSafely -Name 'Log-Ordner' -Action { Open-EobPath -Path (Get-EobLogStatus).Directory } })
}

function Get-EobUiConfigError {
    <#
    .SYNOPSIS
        Liefert die Fehler einer Konfiguration als Anzeigetexte (höchstens 15).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][object]$Config)

    if ($null -eq $Config) { return 'Keine Konfiguration geladen.' }
    $errors = @($Config.Findings | Where-Object { $_.Severity -eq 'Error' })
    foreach ($finding in $errors | Select-Object -First 15) { '{0}: {1}' -f $finding.Code, $finding.Message }
    if ($errors.Count -gt 15) { "... und $($errors.Count - 15) weitere" }
}

function Get-EobUiConfigPath {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ($script:Ui.ConfigPath) { return $script:Ui.ConfigPath }
    return (Get-EobDefaultConfigurationPath)
}

function Add-EobToolsOutput {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text)

    $box = $script:Ui.C.ToolsOutputText
    $line = "[$((Get-Date).ToString('HH:mm:ss'))] $Text"
    $box.Text = if ($box.Text) { "$line`n$($box.Text)" } else { $line }
}

function Update-EobToolsStatus {
    [CmdletBinding()]
    param()

    Set-EobGridSource -Grid $script:Ui.C.ToolsIntegrationGrid -Items @(Get-EobIntegrationStatus -Config $script:Ui.Config | ForEach-Object { ConvertTo-EobUiIntegrationRow -Status $_ })
}

function Invoke-EobToolsConfigCheck {
    [CmdletBinding()]
    param()

    $path = Get-EobUiConfigPath
    $config = Import-EobConfiguration -Path $path
    $summary = Get-EobConfigFindingSummary -Config $config
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("Konfiguration $path : $($summary.Errors) Fehler, $($summary.Warnings) Warnungen, $($summary.Informations) Hinweise.")
    foreach ($finding in @($config.Findings | Where-Object Severity -In @('Error', 'Warning') | Select-Object -First 40)) {
        $lines.Add("  [$(Get-EobUiText -Map $script:SeverityTexts -Key $finding.Severity)] $($finding.Code) $($finding.Field): $($finding.Message)")
    }
    $lines.Add('Übernahme der geänderten Konfiguration: Einstellungen > Neu laden.')
    Add-EobToolsOutput -Text ($lines -join "`n")
}

function Invoke-EobToolsMigration {
    [CmdletBinding()]
    param()

    $source = Select-EobOpenFile -Filter 'INI-Dateien (*.ini)|*.ini|Alle Dateien (*.*)|*.*' -Title 'Konfiguration der Version 1.x auswählen'
    if (-not $source) { return }
    $configDirectory = Split-Path -Parent (Get-EobUiConfigPath)
    $target = Select-EobSaveFile -Filter 'INI-Dateien (*.ini)|*.ini' -Title 'Migrierte Konfiguration speichern' -FileName 'easyONB.ini' -InitialDirectory $configDirectory
    if (-not $target) { return }
    if ([System.IO.Path]::GetFullPath($source) -ieq [System.IO.Path]::GetFullPath($target)) { throw 'Quelle und Ziel dürfen nicht identisch sein (die Quelldatei bleibt unverändert).' }
    $changes = @(Convert-EobLegacyConfiguration -SourcePath $source -DestinationPath $target -Force:(Test-Path -LiteralPath $target) -Confirm:$false)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("Migration: $source -> $target ($($changes.Count) Änderung(en)).")
    foreach ($change in $changes | Select-Object -First 60) { $lines.Add("  $($change.Action) [$($change.Section)] $($change.Key): $($change.Message)") }
    Add-EobToolsOutput -Text ($lines -join "`n")
}

#endregion

#region Einstellungen

function Initialize-EobSettingsView {
    [CmdletBinding()]
    param()

    $c = $script:Ui.C
    Set-EobComboSource -Combo $c.SetThemeCombo -SelectedValue $script:Ui.Theme -Items @([pscustomobject]@{ Text = 'Hell'; Value = 'Light' }, [pscustomobject]@{ Text = 'Dunkel'; Value = 'Dark' })
    $c.SetAccentText.Text = if ($script:Ui.AccentColor) { $script:Ui.AccentColor } else { '#0F6CBD' }
    $c.SetReloadButton.Add_Click({ Invoke-EobUiSafely -Name 'Konfiguration neu laden' -Busy -Action { Update-EobUiConfiguration } })
    $c.SetOpenConfigButton.Add_Click({ Invoke-EobUiSafely -Name 'Konfiguration öffnen' -Action { Open-EobPath -Path (Get-EobUiConfigPath) } })
    $c.SetCreateConfigButton.Add_Click({ Invoke-EobUiSafely -Name 'Konfiguration erstellen' -Busy -Action { New-EobUiConfiguration } })
    $c.SetApplyAppearanceButton.Add_Click({ Invoke-EobUiSafely -Name 'Darstellung' -Action { Set-EobUiAppearance } })
    $c.SetSaveAppearanceButton.Add_Click({ Invoke-EobUiSafely -Name 'Darstellung speichern' -Action { Set-EobUiAppearance -Save } })
}

function Update-EobSettingsView {
    [CmdletBinding()]
    param()

    $c = $script:Ui.C
    $config = $script:Ui.Config
    $path = Get-EobUiConfigPath
    $c.SetConfigPathText.Text = if ($config.Exists) { $path } else { "$path (nicht vorhanden)" }
    $c.SetConfigSourcesText.Text = "Geladen: $(ConvertTo-EobUiDateText -Value $config.LoadedAt -WithTime)  ·  Quellen: " + ((@($config.Sources) | ForEach-Object { Split-Path -Leaf ([string]$_) }) -join ', ')
    $c.SetCreateConfigButton.IsEnabled = -not $config.Exists
    $summary = Get-EobConfigFindingSummary -Config $config
    $c.SetFindingsSummaryText.Text = "$($summary.Errors) Fehler · $($summary.Warnings) Warnungen · $($summary.Informations) Hinweise"
    Set-EobGridSource -Grid $c.SetFindingsGrid -Items @($config.Findings | Sort-Object -Property @{ Expression = { @('Error', 'Warning', 'Information').IndexOf([string]$_.Severity) } } |
            ForEach-Object { ConvertTo-EobUiFindingRow -Finding $_ })
    $read = { param([string]$Key) Get-EobConfigValue -Config $config -Section 'Security' -Key $Key }
    $c.SetSecurityInfoText.Text = @(
        "Simulation beim Start: $(& $read 'SimulationByDefault')"
        "Manuelle Kennwörter erlaubt: $(& $read 'AllowManualPassword')  ·  Einmalige Anzeige: $(& $read 'ShowPasswordOnce')  ·  Drucken erlaubt: $(& $read 'AllowCredentialPrint')"
        "Zwischenablage leeren nach: $(& $read 'ClipboardClearSeconds') s"
        "Offboarding privilegierter Konten erlaubt: $(& $read 'AllowPrivilegedOffboarding')"
        "Geschützte Gruppenmuster: $(& $read 'ProtectedGroupPatterns')  ·  Dienstkontenmuster: $(& $read 'ServiceAccountPatterns')"
        '(1 = ja, 0 = nein; Änderungen in der INI-Datei, danach "Neu laden")'
    ) -join "`n"
}

function Update-EobUiConfiguration {
    [CmdletBinding()]
    param()

    if ($null -ne $script:Ui.Execution) { throw 'Während einer Ausführung kann die Konfiguration nicht neu geladen werden.' }
    $config = Import-EobConfiguration -Path (Get-EobUiConfigPath)
    # Eine fehlerhafte Datei ersetzt die geladene Konfiguration nicht.
    $errors = @(Get-EobUiConfigError -Config $config)
    if ($errors.Count -gt 0) {
        Write-EobLog -Level Warning -Action 'ConfigReloaded' -Result 'Failed' -Target (Get-EobUiConfigPath) -Message "Konfiguration nicht übernommen: $($errors.Count) Fehler."
        $null = Show-EobDialog -Title 'Konfiguration nicht übernommen' -Kind Error -Details $errors `
            -Message "Die Datei enthält $($errors.Count) Fehler. Die bisher geladene Konfiguration bleibt aktiv."
        return
    }
    $script:Ui.Config = $config
    $logging = Get-EobLoggingParameter -Config $config
    $null = Initialize-EobLogging @logging -EnableQueue
    $null = Initialize-EobAdConnection -Config $config
    foreach ($name in @($script:Ui.Views.Keys)) {
        if ($name -ne $script:Ui.CurrentView) { $script:Ui.Views.Remove($name) }
    }
    Update-EobStatusBar
    Update-EobSettingsView
    Write-EobLog -Level Information -Action 'ConfigReloaded' -Target (Get-EobUiConfigPath) -Message 'Konfiguration neu geladen.'
}

function New-EobUiConfiguration {
    [CmdletBinding()]
    param()

    $path = Get-EobUiConfigPath
    if (Test-Path -LiteralPath $path) { throw "Die Konfiguration existiert bereits: $path" }
    $null = Copy-EobConfigurationTemplate -Destination $path -Confirm:$false
    Update-EobUiConfiguration
    $null = Show-EobDialog -Title 'Konfiguration erstellt' -Kind Success -Message "Die Beispielkonfiguration wurde nach $path kopiert. Bitte die Werte (Domänen, OUs, Gruppen) anpassen und danach neu laden."
}

function Set-EobUiAppearance {
    [CmdletBinding()]
    param([switch]$Save)

    $c = $script:Ui.C
    $theme = [string](Get-EobComboValue -Combo $c.SetThemeCombo)
    $accent = ([string]$c.SetAccentText.Text).Trim()
    Set-EobFieldError -Control $c.SetAccentError
    if ($accent -and $accent -notmatch '^#[0-9A-Fa-f]{6}$') {
        Set-EobFieldError -Control $c.SetAccentError -Message 'Bitte eine Farbe im Format #RRGGBB angeben.'
        return
    }
    Set-EobTheme -Theme $theme -AccentColor $accent
    if (-not $Save) { return }
    $path = Get-EobUiConfigPath
    if (-not (Test-Path -LiteralPath $path)) { throw 'Es ist keine Konfigurationsdatei vorhanden (Einstellungen > Aus Vorlage erstellen).' }
    Set-EobIniValue -Path $path -Section 'UI' -Key 'Theme' -Value $theme -Confirm:$false
    Set-EobIniValue -Path $path -Section 'UI' -Key 'AccentColor' -Value $accent -Confirm:$false
    Write-EobLog -Level Information -Action 'ConfigChanged' -Target $path -Message "Darstellung gespeichert (Theme=$theme, AccentColor=$accent)."
    $null = Show-EobDialog -Title 'Gespeichert' -Kind Success -Message 'Farbschema und Akzentfarbe wurden in der Konfiguration gespeichert (Sicherung der vorherigen Datei angelegt).'
}

#endregion

#region Info

function Initialize-EobInfoView {
    [CmdletBinding()]
    param()

    $c = $script:Ui.C
    $c.InfoProjectButton.Add_Click({ Invoke-EobUiSafely -Name 'Projektseite' -Action { Open-EobUrl -Url 'https://github.com/PS-easyIT/easyONBOARDING' } })
    $c.InfoDocsButton.Add_Click({ Invoke-EobUiSafely -Name 'Dokumentation' -Action { Open-EobPath -Path (Join-Path -Path (Get-EobAppRoot) -ChildPath 'docs') } })
}

function Update-EobInfoView {
    [CmdletBinding()]
    param()

    $c = $script:Ui.C
    $log = Get-EobLogStatus
    $ad = Get-EobAdConnectionInfo
    $c.InfoProductText.Text = "easyONBOARDING $(Get-EobVersion)"
    $c.InfoAuthorText.Text = 'Autor: Andreas Hepp (PHINIT.DE)'
    $c.InfoLicenseText.Text = 'Lizenz- und Nutzungshinweise: siehe README.md im Repository.'
    $c.InfoEnvironmentText.Text = @(
        "PowerShell: $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition)) · Betriebssystem: $([System.Runtime.InteropServices.RuntimeInformation]::OSDescription)"
        "Benutzer: $((Get-EobCurrentIdentity).Name) · Computer: $([Environment]::MachineName)"
        "Anwendung: $(Get-EobAppRoot)"
        "Konfiguration: $(Get-EobUiConfigPath)"
        "Logs: $($log.Directory) · Audit: $($log.AuditDirectory)$(if ($log.FallbackActive) { ' (Ersatzverzeichnis aktiv)' })"
        "Berichte: $(Get-EobReportDirectory -Config $script:Ui.Config)"
        "Domänencontroller: $(if ($ad.Connected) { $ad.Server } else { 'nicht verbunden' })"
    ) -join "`n"
    Set-EobGridSource -Grid $c.InfoModulesGrid -Items @(Get-Module -Name 'easyONB.*' | Sort-Object -Property Name | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; Version = [string]$_.Version; Description = $_.Description }
        })
}

#endregion
