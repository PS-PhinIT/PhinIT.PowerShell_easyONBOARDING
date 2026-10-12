#Requires -Version 7.2
<#
    easyONB.Offboarding
    Offboarding mit Vorlagen, Schutzprüfungen, Zustandsberichten (vorher/nachher), mehrstufigen
    Phasen, Warteschlange für spätere Phasen, abgesicherter endgültiger Löschung und
    CSV-Massenverarbeitung.

    Phasen
      Immediate      sofort bei der Ausführung
      ExitDate       ab dem Tag nach dem Austrittsdatum (= letzter Arbeitstag; passend zum
                     AD-Ablaufdatum, das auf das Ende dieses Tages gesetzt wird)
      Retention      Austrittsdatum + RetentionPhaseStartDays (frühestens nach der Austrittsphase)
      FinalDeletion  Austrittsdatum + RetentionDays. Wird NIE automatisch ausgeführt, sondern nur
                     über New-EobOffboardingDeletionPlan / Invoke-EobOffboardingFinalDeletion mit
                     Snapshot, Vorschau, Tippbestätigung und Audit.
    Eine Phase ist erst fällig, wenn alle vorherigen Phasen erledigt sind.
#>

Set-StrictMode -Version 3.0

#region Konstanten

$script:ExecutablePhases = @('Immediate', 'ExitDate', 'Retention')
$script:ActionPhaseValues = @('Immediate', 'ExitDate', 'Retention', 'FinalDeletion', 'Off')
$script:AlwaysPhase = 'Always'

# Reihenfolge innerhalb einer Phase: dokumentieren, sperren, Postfach, Gruppen, Dateien, verschieben.
# ConvertToSharedMailbox steht vor RemoveLicenseGroups (sonst droht der Verlust des Postfachs).
$script:ActionOrder = @(
    'DocumentMailboxPermissions', 'UpdateDescription', 'SetExpiration', 'DisableAccount', 'DenyLogonHours', 'ResetPassword',
    'ForcePasswordChange', 'RevokeSessions', 'SetAutoReply', 'SetForwarding', 'HideFromAddressLists', 'ConvertToSharedMailbox',
    'RemoveGroups', 'RemoveLicenseGroups', 'ClearManager', 'GrantManagerHomeAccess', 'ArchiveHomeDirectory', 'ClearProfilePath',
    'MoveToOU', 'DeleteAccount'
)

$script:ActionTitles = @{
    DisableAccount             = 'Konto deaktivieren'
    SetExpiration              = 'Ablaufdatum setzen'
    DenyLogonHours             = 'Anmeldezeiten sperren'
    UpdateDescription          = 'Beschreibung aktualisieren'
    ResetPassword              = 'Kennwort auf Zufallswert setzen'
    ForcePasswordChange        = 'Kennwortänderung erzwingen'
    RevokeSessions             = 'Anmeldesitzungen widerrufen (Entra ID)'
    RemoveGroups               = 'Gruppenmitgliedschaften entfernen'
    RemoveLicenseGroups        = 'Lizenzgruppen entfernen'
    ClearManager               = 'Führungskraft entfernen'
    MoveToOU                   = 'In Austritts-OU verschieben'
    HideFromAddressLists       = 'Aus Adresslisten ausblenden'
    SetAutoReply               = 'Abwesenheitsnotiz aktivieren'
    SetForwarding              = 'Weiterleitung einrichten'
    ConvertToSharedMailbox     = 'In freigegebenes Postfach umwandeln'
    DocumentMailboxPermissions = 'Postfachberechtigungen dokumentieren'
    ArchiveHomeDirectory       = 'Home-Verzeichnis archivieren'
    GrantManagerHomeAccess     = 'Führungskraft Lesezugriff auf das Home-Verzeichnis geben'
    ClearProfilePath           = 'Profilpfad entfernen'
    DeleteAccount              = 'Konto endgültig löschen'
}

$script:PhaseTitles = @{
    Always        = 'Dokumentation'
    Immediate     = 'Sofort'
    ExitDate      = 'Zum Austritt'
    Retention     = 'Aufbewahrung'
    FinalDeletion = 'Endgültige Löschung'
}

$script:CsvColumnMap = @{
    'identity' = 'Identity'; 'samaccountname' = 'Identity'; 'userprincipalname' = 'Identity'; 'upn' = 'Identity'
    'mail' = 'Identity'; 'email' = 'Identity'; 'benutzer' = 'Identity'; 'konto' = 'Identity'
    'exitdate' = 'ExitDate'; 'austrittsdatum' = 'ExitDate'; 'austritt' = 'ExitDate'; 'enddate' = 'ExitDate'
    'template' = 'Template'; 'vorlage' = 'Template'; 'ticket' = 'Ticket'; 'reason' = 'Reason'; 'grund' = 'Reason'
    'forwardto' = 'ForwardTo'; 'weiterleitung' = 'ForwardTo'; 'notes' = 'Notes'; 'bemerkung' = 'Notes'
    'assets' = 'Assets'; 'inventar' = 'Assets'; 'targetou' = 'TargetOU'; 'zielou' = 'TargetOU'
}

$script:DefaultAutoReply = 'Vielen Dank für Ihre Nachricht. {DisplayName} ist nicht mehr im Unternehmen tätig. Ihre Nachricht wird nicht weitergeleitet. Bitte wenden Sie sich an {ManagerName} {ManagerMail}.'

#endregion

#region Hilfsfunktionen

function New-EobNotProcessedResult {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Erzeugt nur ein Objekt im Speicher; keine Systemänderung.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Message,
        [hashtable]$Data
    )

    if ($WhatIfPreference) {
        return New-EobResult -Status Succeeded -Message ('Simulation: ' + $Message) -Data $Data
    }
    return New-EobResult -Status Skipped -Message ('Nicht bestätigt: ' + $Message) -Data $Data
}

function Write-EobJsonFile {
    <#
        Schreibt JSON atomar (temporäre Datei + Umbenennen), UTF-8 ohne BOM.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowNull()][object]$InputObject,
        [ValidateRange(2, 20)][int]$Depth = 8
    )

    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop
    }
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [System.IO.File]::WriteAllText($temporary, (ConvertTo-Json -InputObject $InputObject -Depth $Depth), [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $Path -Force -ErrorAction Stop
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Format-EobOffboardingText {
    <#
    .SYNOPSIS
        Ersetzt {Platzhalter} in Offboarding-Texten (Beschreibung, Abwesenheitsnotiz).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Template,
        [Parameter(Mandatory)][hashtable]$Values
    )

    $lookup = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($key in $Values.Keys) { $lookup[[string]$key] = [string]$Values[$key] }
    $evaluator = [System.Text.RegularExpressions.MatchEvaluator] {
        param($match)
        $name = $match.Groups[1].Value
        if ($lookup.ContainsKey($name)) { return $lookup[$name] }
        return ''
    }
    $text = [regex]::Replace($Template, '\{([A-Za-z]+)\}', $evaluator)
    return ([regex]::Replace($text, '\s{2,}', ' ')).Trim()
}

function Get-EobListValue {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return @() }
    $items = if ($Value -is [string]) { $Value -split ';' } else { @($Value) }
    return @($items | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -ne '' })
}

function Test-EobGroupReference {
    <#
        Prüft, ob eine Mitgliedschaft einem Namen, sAMAccountName, DN oder einer SID entspricht.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Membership,
        [string[]]$Names = @()
    )

    foreach ($name in $Names) {
        if (-not $name) { continue }
        foreach ($candidate in @($Membership.Name, $Membership.SamAccountName, $Membership.DistinguishedName, $Membership.SID)) {
            if ($candidate -and $candidate -ieq $name) { return $true }
        }
    }
    return $false
}

function Get-EobOffboardingDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][pscustomobject]$Config,
        [ValidateSet('Snapshot', 'Queue')][string]$Kind
    )

    if ($Kind -eq 'Snapshot') {
        $path = [string](Get-EobConfigValue -Config $Config -Section 'Paths' -Key 'SnapshotDirectory' -As Path)
        if (-not $path) { $path = Join-Path -Path (Get-EobAppRoot) -ChildPath 'Reports/Offboarding' }
        return $path
    }
    $data = [string](Get-EobConfigValue -Config $Config -Section 'Paths' -Key 'DataDirectory' -As Path)
    if (-not $data) { $data = Join-Path -Path (Get-EobAppRoot) -ChildPath 'Data' }
    return [System.IO.Path]::Combine($data, 'OffboardingQueue')
}

function Get-EobInternalMailDomain {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowNull()][pscustomobject]$Config)

    $domains = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($domain in @(Get-EobMailDomain -Config $Config)) { if ($domain) { $null = $domains.Add($domain) } }
    foreach ($company in @(Get-EobCompany -Config $Config)) {
        foreach ($domain in @($company.MailDomain, $company.MS365Domain, $company.UpnSuffix)) {
            if ($domain) { $null = $domains.Add($domain.TrimStart('@')) }
        }
    }
    return @($domains)
}

#endregion

#region Vorlagen und Anfragen

function Get-EobOffboardingTemplate {
    <#
    .SYNOPSIS
        Liefert die Offboarding-Vorlagen ([OffboardingTemplate.<Name>]) mit Phasenzuordnung je Aktion.
    .DESCRIPTION
        Nicht aufgeführte Aktionen gelten als 'Off'. Unbekannte Aktionen oder Phasen werden
        ignoriert (die Konfigurationsprüfung meldet sie).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()][pscustomobject]$Config,
        [string]$Name
    )

    foreach ($sectionName in @(Get-EobConfigSectionName -Config $Config -Pattern '^OffboardingTemplate\.[A-Za-z0-9_\-]+$' | Sort-Object)) {
        $templateName = $sectionName.Substring('OffboardingTemplate.'.Length)
        if ($Name -and $templateName -ine $Name) { continue }
        $read = { param([string]$Key, [string]$As = 'String') Get-EobConfigValue -Config $Config -Section $sectionName -Key $Key -As $As }
        $actions = [ordered]@{}
        foreach ($action in $script:ActionOrder) { $actions[$action] = 'Off' }
        $section = Get-EobConfigSection -Config $Config -Name $sectionName
        foreach ($key in $section.Keys) {
            if ($key -notmatch '^Action\.([A-Za-z]+)$') { continue }
            $action = $script:ActionOrder | Where-Object { $_ -ieq $Matches[1] } | Select-Object -First 1
            $phase = $script:ActionPhaseValues | Where-Object { $_ -ieq ([string]$section[$key]).Trim() } | Select-Object -First 1
            if ($action -and $phase) { $actions[$action] = $phase }
        }
        $displayName = [string](& $read 'DisplayName')
        [pscustomobject]@{
            PSTypeName              = 'Eob.OffboardingTemplate'
            Name                    = $templateName
            DisplayName             = if ($displayName) { $displayName } else { $templateName }
            Description             = [string](& $read 'Description')
            RetentionDays           = [int](& $read 'RetentionDays' 'Int')
            RetentionPhaseStartDays = [int](& $read 'RetentionPhaseStartDays' 'Int')
            RemoveGroupsMode        = [string](& $read 'RemoveGroupsMode')
            KeepGroups              = @(& $read 'KeepGroups' 'List')
            TargetOU                = [string](& $read 'TargetOU')
            DescriptionTemplate     = [string](& $read 'DescriptionTemplate')
            AutoReplyMessage        = [string](& $read 'AutoReplyMessage')
            ForwardToManager        = [bool](& $read 'ForwardToManager' 'Bool')
            IsTestMode              = [bool](& $read 'IsTestMode' 'Bool')
            RequireTicket           = [bool](& $read 'RequireTicket' 'Bool')
            Actions                 = $actions
        }
    }
}

function ConvertTo-EobOffboardingRequest {
    <#
    .SYNOPSIS
        Normalisiert eine Offboarding-Anfrage (GUI, CSV, Warteschlange).
    .PARAMETER InputObject
        Hashtable oder Objekt mit Identity, Template, ExitDate, Ticket, Reason, Notes, ForwardTo,
        AutoReplyMessage, TargetOU, KeepGroups, SelectedGroups, Assets, ActionPhases, AcknowledgePrivileged.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'InputObject', Justification = 'Wird im Skriptblock verwendet; die Regel wertet verschachtelte Skriptblöcke nicht aus.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][object]$InputObject,
        [AllowNull()][pscustomobject]$Config
    )

    $get = { param([string]$Name, $Default = $null) Get-EobPropertyValue -InputObject $InputObject -Name $Name -Default $Default }
    $exitRaw = & $get 'ExitDate' $null
    $exitDate = $null
    if ($exitRaw -is [datetime]) { $exitDate = $exitRaw.Date }
    elseif ($null -ne $exitRaw -and [string]$exitRaw -ne '') { $exitDate = ConvertTo-EobDate -Value ([string]$exitRaw) }

    $template = ([string](& $get 'Template' '')).Trim()
    if (-not $template) { $template = [string](Get-EobConfigValue -Config $Config -Section 'Offboarding' -Key 'DefaultTemplate') }

    $actionPhases = @{}
    $rawPhases = & $get 'ActionPhases' $null
    if ($rawPhases -is [System.Collections.IDictionary]) {
        foreach ($key in $rawPhases.Keys) { $actionPhases[[string]$key] = [string]$rawPhases[$key] }
    }
    elseif ($null -ne $rawPhases -and $rawPhases -is [pscustomobject]) {
        foreach ($property in $rawPhases.PSObject.Properties) { $actionPhases[$property.Name] = [string]$property.Value }
    }

    [pscustomobject]@{
        PSTypeName            = 'Eob.OffboardingRequest'
        Identity              = ([string](& $get 'Identity' '')).Trim()
        Template              = $template
        ExitDate              = $exitDate
        ExitDateText          = if ($null -eq $exitRaw) { '' } elseif ($exitRaw -is [datetime]) { $exitRaw.ToString('yyyy-MM-dd') } else { ([string]$exitRaw).Trim() }
        Ticket                = ([string](& $get 'Ticket' '')).Trim()
        Reason                = ([string](& $get 'Reason' '')).Trim()
        Notes                 = ([string](& $get 'Notes' '')).Trim()
        ForwardTo             = ([string](& $get 'ForwardTo' '')).Trim()
        AuthorizedHomeAccessAccount = ([string](& $get 'AuthorizedHomeAccessAccount' '')).Trim()
        AutoReplyMessage      = ([string](& $get 'AutoReplyMessage' '')).Trim()
        TargetOU              = ([string](& $get 'TargetOU' '')).Trim()
        KeepGroups            = @(Get-EobListValue -Value (& $get 'KeepGroups' $null))
        SelectedGroups        = @(Get-EobListValue -Value (& $get 'SelectedGroups' $null))
        Assets                = @(Get-EobListValue -Value (& $get 'Assets' $null))
        ActionPhases          = $actionPhases
        AcknowledgePrivileged = ConvertTo-EobBoolean -Value (& $get 'AcknowledgePrivileged' $false) -Default $false
    }
}

function Test-EobOffboardingRequest {
    <#
    .SYNOPSIS
        Prüft eine Offboarding-Anfrage feldbezogen (ohne AD-Zugriff).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Request,
        [AllowNull()][pscustomobject]$Config
    )

    $add = { param($Severity, $Code, $Field, $Message) New-EobFinding -Severity $Severity -Code $Code -Field $Field -Message $Message -Source 'Offboarding' }
    if (-not $Request.Identity) {
        & $add Error 'OFF_IDENTITY_MISSING' 'Identity' 'Bitte einen Benutzer auswählen (Name, Anmeldename, UPN oder E-Mail).'
    }
    elseif (-not (Test-EobSafeText -Value $Request.Identity)) {
        & $add Error 'OFF_IDENTITY_INVALID' 'Identity' 'Die Benutzerangabe enthält unzulässige Zeichen.'
    }
    if ($null -eq $Request.ExitDate) {
        if ($Request.ExitDateText) { & $add Error 'OFF_EXITDATE_INVALID' 'ExitDate' "Ungültiges Austrittsdatum '$($Request.ExitDateText)' (Format TT.MM.JJJJ oder JJJJ-MM-TT)." }
        else { & $add Error 'OFF_EXITDATE_MISSING' 'ExitDate' 'Bitte das Austrittsdatum (letzter Arbeitstag) angeben.' }
    }
    elseif ($Request.ExitDate -lt (Get-Date).Date.AddYears(-1)) {
        & $add Warning 'OFF_EXITDATE_OLD' 'ExitDate' 'Das Austrittsdatum liegt mehr als ein Jahr zurück.'
    }

    $template = $null
    if ($Request.Template) { $template = Get-EobOffboardingTemplate -Config $Config -Name $Request.Template | Select-Object -First 1 }
    if ($null -eq $template) {
        & $add Error 'OFF_TEMPLATE_NOT_FOUND' 'Template' "Offboarding-Vorlage '$($Request.Template)' wurde nicht gefunden."
    }
    $requireTicket = (Get-EobConfigValue -Config $Config -Section 'Offboarding' -Key 'RequireTicket' -As Bool) -and ($null -eq $template -or $template.RequireTicket)
    if ($requireTicket -and -not $Request.Ticket) {
        & $add Error 'OFF_TICKET_REQUIRED' 'Ticket' 'Die Ticket-/Vorgangsnummer ist Pflicht.'
    }
    if ($Request.Ticket -and ($Request.Ticket.Length -gt 128 -or -not (Test-EobSafeText -Value $Request.Ticket))) {
        & $add Error 'OFF_TICKET_INVALID' 'Ticket' 'Die Ticketnummer ist zu lang oder enthält unzulässige Zeichen.'
    }
    if ((Get-EobConfigValue -Config $Config -Section 'Offboarding' -Key 'RequireReason' -As Bool) -and -not $Request.Reason) {
        & $add Error 'OFF_REASON_REQUIRED' 'Reason' 'Die Begründung ist Pflicht.'
    }
    if ($Request.Reason.Length -gt 512) { & $add Error 'OFF_REASON_TOO_LONG' 'Reason' 'Die Begründung ist zu lang (max. 512 Zeichen).' }
    if ($Request.Notes.Length -gt 2048) { & $add Error 'OFF_NOTES_TOO_LONG' 'Notes' 'Die Bemerkung ist zu lang (max. 2048 Zeichen).' }
    if ($Request.ForwardTo -and -not (Test-EobEmailAddress -Value $Request.ForwardTo)) {
        & $add Error 'OFF_FORWARD_INVALID' 'ForwardTo' "Ungültige Weiterleitungsadresse '$($Request.ForwardTo)'."
    }
    if ($Request.TargetOU -and -not (Test-EobDistinguishedName -Value $Request.TargetOU)) {
        & $add Error 'OFF_TARGETOU_INVALID' 'TargetOU' 'Die Ziel-OU ist kein gültiger Distinguished Name.'
    }
    foreach ($asset in $Request.Assets) {
        if ($asset.Length -gt 256) { & $add Error 'OFF_ASSET_TOO_LONG' 'Assets' 'Ein Inventareintrag ist zu lang (max. 256 Zeichen).' }
    }
    foreach ($key in $Request.ActionPhases.Keys) {
        $phase = [string]$Request.ActionPhases[$key]
        if ($key -notin $script:ActionOrder) {
            & $add Error 'OFF_ACTION_UNKNOWN' 'ActionPhases' "Unbekannte Aktion '$key'."
        }
        elseif ($phase -notin $script:ActionPhaseValues) {
            & $add Error 'OFF_PHASE_UNKNOWN' 'ActionPhases' "Unbekannte Phase '$phase' für $key."
        }
        elseif ($key -eq 'DeleteAccount' -and $phase -notin @('FinalDeletion', 'Off')) {
            & $add Error 'OFF_DELETE_PHASE' 'ActionPhases' 'Die Löschung ist nur in der Phase FinalDeletion zulässig.'
        }
        elseif ($key -ne 'DeleteAccount' -and $phase -eq 'FinalDeletion') {
            & $add Error 'OFF_PHASE_FINALDELETION' 'ActionPhases' "Die Phase FinalDeletion ist nur für DeleteAccount vorgesehen ($key)."
        }
    }
}

function Get-EobOffboardingPhaseDate {
    <#
    .SYNOPSIS
        Berechnet die Fälligkeiten der Phasen.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][datetime]$ExitDate,
        [Parameter(Mandatory)][pscustomobject]$Template,
        [datetime]$Now = (Get-Date)
    )

    $exitDue = $ExitDate.Date.AddDays(1)
    $retention = $ExitDate.Date.AddDays([Math]::Max(0, $Template.RetentionPhaseStartDays))
    if ($retention -lt $exitDue) { $retention = $exitDue }
    $deletion = $null
    if ($Template.RetentionDays -gt 0) {
        $deletion = $ExitDate.Date.AddDays($Template.RetentionDays)
        if ($deletion -lt $retention) { $deletion = $retention }
    }
    return [ordered]@{
        Immediate     = $Now
        ExitDate      = $exitDue
        Retention     = $retention
        FinalDeletion = $deletion
    }
}

#endregion

#region Planerstellung

function Get-EobOffboardingGroupClassification {
    <#
    .SYNOPSIS
        Ordnet die Gruppenmitgliedschaften für das Offboarding ein (entfernen oder behalten, mit Grund).
    .DESCRIPTION
        Nie entfernt werden: primäre Gruppe, M365-Synchronisationsgruppe (sonst würde das Cloud-Konto
        samt Postfach gelöscht), Gruppen aus KeepGroups. Lizenzgruppen entfernt nur RemoveLicenseGroups.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Membership,
        [AllowNull()][pscustomobject]$Config,
        [Parameter(Mandatory)][pscustomobject]$Template,
        [Parameter(Mandatory)][pscustomobject]$Request
    )

    $licenseGroups = @((Get-EobConfigSection -Config $Config -Name 'LicensesGroups').Values | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    $syncGroup = [string](Get-EobConfigValue -Config $Config -Section 'ActivateUserMS365ADSync' -Key 'ADSyncADGroup')
    $keep = @(@(Get-EobConfigValue -Config $Config -Section 'Offboarding' -Key 'KeepGroups' -As List) + $Template.KeepGroups + $Request.KeepGroups | Where-Object { $_ })

    foreach ($group in $Membership) {
        $category = 'Security'
        $reason = ''
        $protection = Test-EobPrivilegedGroup -Group $group -Config $Config
        if ($group.IsPrimary) { $category = 'Primary'; $reason = 'Primäre Gruppe (wird nie entfernt).' }
        elseif ($syncGroup -and (Test-EobGroupReference -Membership $group -Names @($syncGroup))) { $category = 'Sync'; $reason = 'Synchronisationsgruppe (Entfernen würde das Cloud-Konto löschen).' }
        elseif (Test-EobGroupReference -Membership $group -Names $keep) { $category = 'Keep'; $reason = 'In KeepGroups konfiguriert.' }
        elseif (Test-EobGroupReference -Membership $group -Names $licenseGroups) { $category = 'License'; $reason = 'Lizenzgruppe (nur über RemoveLicenseGroups).' }
        elseif ($protection.IsProtected) { $category = 'Privileged'; $reason = 'Privilegierte Gruppe: ' + ($protection.Reasons -join ' ') }
        elseif ([string]$group.GroupCategory -eq 'Distribution') { $category = 'Distribution'; $reason = 'Verteilergruppe.' }

        $remove = $false
        switch ($Template.RemoveGroupsMode) {
            'AllNonProtected' { $remove = $category -in @('Security', 'Distribution', 'Privileged') }
            'Selected' { $remove = ($category -in @('Security', 'Distribution', 'Privileged')) -and (Test-EobGroupReference -Membership $group -Names $Request.SelectedGroups) }
            default { $remove = $false }
        }
        [pscustomobject]@{
            Name              = if ($group.Name) { [string]$group.Name } else { [string]$group.DistinguishedName }
            DistinguishedName = [string]$group.DistinguishedName
            Category          = $category
            Reason            = $reason
            Remove            = $remove
            RemoveAsLicense   = ($category -eq 'License') -or ($Template.RemoveGroupsMode -eq 'LicenseOnly' -and $category -eq 'License')
        }
    }
}

function New-EobOffboardingPlan {
    <#
    .SYNOPSIS
        Erstellt einen Offboarding-Plan mit allen Phasen (Vorschau), Schutzprüfung und Befunden.
    .DESCRIPTION
        Liest das AD nur (Benutzer, Gruppen, Unterstellte, Ziel-OU). Blockierte Konten erhalten
        keine Schritte. Privilegierte Konten erfordern [Security] AllowPrivilegedOffboarding=1 und
        die ausdrückliche Bestätigung in der Anfrage (AcknowledgePrivileged).
    .PARAMETER Now
        Bezugszeitpunkt für Fälligkeiten (Tests, Warteschlange).
    .PARAMETER OperationId
        Vorgangs-ID eines bestehenden Offboardings (Folgephasen aus der Warteschlange).
    .PARAMETER CompletedPhases
        Bereits erledigte Phasen.
    .PARAMETER ExpectedObjectGuid
        Erwartete ObjectGUID (Folgephasen): Abweichungen blockieren den Plan.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Erzeugt nur ein Objekt im Speicher; keine Systemänderung.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Request,
        [AllowNull()][pscustomobject]$Config,
        [switch]$Simulation,
        [datetime]$Now = (Get-Date),
        [string]$OperationId,
        [string[]]$CompletedPhases = @(),
        [string]$ExpectedObjectGuid
    )

    $context = New-EobOperationContext -Kind 'Offboarding' -Simulation:$Simulation
    if ($OperationId) { $context.OperationId = $OperationId }
    $plan = New-EobPlan -Kind 'Offboarding' -Context $context -Config $Config -Simulation:$Simulation
    $details = [pscustomobject]@{
        Request             = $Request
        Template            = $null
        User                = $null
        PhaseDates          = [ordered]@{}
        CompletedPhases     = @($CompletedPhases)
        PhaseStepCount      = @{}
        Groups              = @()
        DirectReports       = @()
        Privileged          = $false
        RequiresIntegration = @()
        RequiresExchange    = @()
        RequiresGraph       = @()
        ExchangeMode        = [string](Get-EobConfigValue -Config $Config -Section 'Exchange' -Key 'Mode')
    }
    Add-Member -InputObject $plan -NotePropertyName 'Offboarding' -NotePropertyValue $details

    foreach ($finding in @(Test-EobOffboardingRequest -Request $Request -Config $Config)) { $plan.Findings.Add($finding) }
    $template = if ($Request.Template) { Get-EobOffboardingTemplate -Config $Config -Name $Request.Template | Select-Object -First 1 } else { $null }
    if ($null -eq $template -or $null -eq $Request.ExitDate -or -not $Request.Identity) { return $plan }
    $details.Template = $template
    if ($template.IsTestMode) {
        $plan.Simulation = $true
        Add-EobPlanFinding -Plan $plan -Severity Information -Code 'OFF_TEST_TEMPLATE' -Message "Die Vorlage '$($template.DisplayName)' erzwingt die Simulation."
    }

    $connection = Get-EobAdConnectionInfo
    if (-not $connection.Connected) {
        Add-EobPlanFinding -Plan $plan -Severity Error -Code 'OFF_AD_OFFLINE' -Message 'Keine Verbindung zum Active Directory. Das Offboarding benötigt die aktuellen Kontodaten.'
        return $plan
    }
    try {
        $user = Resolve-EobAdUser -Identity $Request.Identity
    }
    catch {
        Add-EobPlanFinding -Plan $plan -Severity Error -Code 'OFF_USER_NOT_FOUND' -Field 'Identity' -Message $_.Exception.Message
        return $plan
    }
    if ($ExpectedObjectGuid -and $user.ObjectGuid -ine $ExpectedObjectGuid) {
        Add-EobPlanFinding -Plan $plan -Severity Error -Code 'OFF_GUID_MISMATCH' -Message 'Das gefundene Konto hat eine andere ObjectGUID als der ursprüngliche Vorgang.'
        return $plan
    }
    $details.User = $user
    $guid = $user.ObjectGuid
    $plan.Subject = @{
        SamAccountName    = $user.SamAccountName
        UserPrincipalName = $user.UserPrincipalName
        DisplayName       = $user.DisplayName
        Mail              = $user.Mail
        ObjectGuid        = $guid
        DistinguishedName = $user.DistinguishedName
        Template          = $template.Name
        ExitDate          = $Request.ExitDate.ToString('yyyy-MM-dd')
    }

    # Schutzprüfung (erste Linie; die AD-Schreibfunktionen prüfen unmittelbar vor jeder Änderung erneut)
    $privileged = @(Get-EobAdPrivilegedMembership -DistinguishedName $user.DistinguishedName -PrimaryGroupId $user.PrimaryGroupId)
    $protection = Test-EobProtectedAccount -User $user -Config $Config -CurrentUserSid (Get-EobCurrentIdentity).Sid -PrivilegedGroups $privileged
    foreach ($reason in $protection.BlockReasons) {
        Add-EobPlanFinding -Plan $plan -Severity Error -Code 'OFF_PROTECTED' -Message "Konto geschützt: $reason"
    }
    $allowPrivileged = $false
    if ($protection.RequiresAcknowledgement) {
        $details.Privileged = $true
        $reasons = $protection.AcknowledgementReasons -join ' '
        if (-not (Get-EobConfigValue -Config $Config -Section 'Security' -Key 'AllowPrivilegedOffboarding' -As Bool)) {
            Add-EobPlanFinding -Plan $plan -Severity Error -Code 'OFF_PRIVILEGED' -Message "Privilegiertes Konto ($reasons). Offboarding privilegierter Konten ist nicht freigegeben ([Security] AllowPrivilegedOffboarding=0)."
        }
        elseif (-not $Request.AcknowledgePrivileged) {
            Add-EobPlanFinding -Plan $plan -Severity Error -Code 'OFF_PRIVILEGED_ACK_REQUIRED' -Message "Privilegiertes Konto ($reasons). Bitte die gesonderte Bestätigung setzen."
        }
        else {
            Add-EobPlanFinding -Plan $plan -Severity Warning -Code 'OFF_PRIVILEGED_ACKNOWLEDGED' -Message "Privilegiertes Konto ($reasons): Offboarding wurde ausdrücklich bestätigt."
            $allowPrivileged = $true
        }
    }
    if (@($plan.Findings | Where-Object Severity -EQ 'Error').Count -gt 0) { return $plan }

    # Phasen und Aktionen
    $actions = [ordered]@{}
    foreach ($action in $template.Actions.Keys) { $actions[$action] = $template.Actions[$action] }
    foreach ($action in $Request.ActionPhases.Keys) {
        if ($actions.Contains($action) -and $Request.ActionPhases[$action] -in $script:ActionPhaseValues) { $actions[$action] = [string]$Request.ActionPhases[$action] }
    }
    $phaseDates = Get-EobOffboardingPhaseDate -ExitDate $Request.ExitDate -Template $template -Now $Now
    $details.PhaseDates = $phaseDates
    if ($actions['DeleteAccount'] -eq 'FinalDeletion' -and $null -eq $phaseDates['FinalDeletion']) {
        $actions['DeleteAccount'] = 'Off'
        Add-EobPlanFinding -Plan $plan -Severity Information -Code 'OFF_NO_DELETION' -Message 'Keine endgültige Löschung vorgesehen (RetentionDays=0).'
    }

    $exchangeMode = $details.ExchangeMode
    $mailboxIdentity = if ($user.UserPrincipalName) { $user.UserPrincipalName } else { $user.SamAccountName }
    $mailboxAvailable = $false
    $mailboxActions = @('SetAutoReply', 'SetForwarding', 'HideFromAddressLists', 'ConvertToSharedMailbox', 'DocumentMailboxPermissions')
    $mailboxRequested = @($mailboxActions | Where-Object { $actions[$_] -ne 'Off' }).Count -gt 0
    if ($mailboxRequested) {
        if ($exchangeMode -eq 'None') {
            Add-EobPlanFinding -Plan $plan -Severity Information -Code 'OFF_EXCHANGE_DISABLED' -Message 'Exchange-Integration deaktiviert: Postfachaktionen werden nicht ausgeführt und sind manuell zu erledigen.'
        }
        elseif (-not $user.Mail) {
            Add-EobPlanFinding -Plan $plan -Severity Information -Code 'OFF_NO_MAIL' -Message 'Das Konto hat keine E-Mail-Adresse: Postfachaktionen entfallen.'
        }
        elseif (Test-EobExchangeConnected -Mode $exchangeMode) {
            try {
                $mailbox = Get-EobMailboxInfo -Identity $mailboxIdentity -Mode $exchangeMode
                if ($null -eq $mailbox) {
                    Add-EobPlanFinding -Plan $plan -Severity Information -Code 'OFF_NO_MAILBOX' -Message 'Kein Postfach gefunden: Postfachaktionen entfallen.'
                }
                else { $mailboxAvailable = $true }
            }
            catch {
                Add-EobPlanFinding -Plan $plan -Severity Warning -Code 'OFF_MAILBOX_CHECK' -Message "Postfach konnte nicht geprüft werden: $($_.Exception.Message)"
                $mailboxAvailable = $true
            }
        }
        else {
            Add-EobPlanFinding -Plan $plan -Severity Warning -Code 'OFF_EXCHANGE_NOT_CONNECTED' -Message "Exchange ($exchangeMode) ist nicht verbunden. Postfachaktionen benötigen bei der Ausführung eine Verbindung."
            $mailboxAvailable = $true
        }
    }

    $managerInfo = $null
    if ($user.Manager) {
        try {
            $managerUser = Resolve-EobAdUser -Identity $user.Manager
            $managerInfo = [pscustomobject]@{ SamAccountName = $managerUser.SamAccountName; DisplayName = $managerUser.DisplayName; Mail = $managerUser.Mail }
        }
        catch {
            Add-EobPlanFinding -Plan $plan -Severity Warning -Code 'OFF_MANAGER_UNRESOLVED' -Message "Führungskraft konnte nicht gelesen werden: $($user.Manager)"
        }
    }
    $directReports = @(Get-EobAdDirectReport -User $user)
    $details.DirectReports = $directReports
    if ($directReports.Count -gt 0) {
        $names = ($directReports | Select-Object -First 10 | ForEach-Object { if ($_.DisplayName) { $_.DisplayName } else { $_.SamAccountName } }) -join ', '
        Add-EobPlanFinding -Plan $plan -Severity Warning -Code 'OFF_DIRECT_REPORTS' -Message "$($directReports.Count) unterstellte Person(en) müssen einer neuen Führungskraft zugeordnet werden: $names"
    }
    if (-not $user.Enabled) {
        Add-EobPlanFinding -Plan $plan -Severity Information -Code 'OFF_ALREADY_DISABLED' -Message 'Das Konto ist bereits deaktiviert.'
    }

    $groups = @(Get-EobOffboardingGroupClassification -Membership @(Get-EobAdUserGroupMembership -User $user) -Config $Config -Template $template -Request $Request)
    $details.Groups = $groups
    if ($template.RemoveGroupsMode -eq 'Selected' -and $actions['RemoveGroups'] -ne 'Off' -and $Request.SelectedGroups.Count -eq 0) {
        Add-EobPlanFinding -Plan $plan -Severity Warning -Code 'OFF_NO_GROUPS_SELECTED' -Message 'Die Vorlage entfernt nur ausgewählte Gruppen, es wurde aber keine ausgewählt.'
    }

    $snapshotDirectory = Get-EobOffboardingDirectory -Config $Config -Kind Snapshot
    $actor = (Get-EobCurrentIdentity).Name
    $textValues = @{
        ExitDate = $Request.ExitDate.ToString('dd.MM.yyyy'); Ticket = $Request.Ticket; Actor = $actor; Reason = $Request.Reason
        Date = $Now.ToString('dd.MM.yyyy'); Template = $template.DisplayName; DisplayName = $user.DisplayName
        ManagerName = if ($null -ne $managerInfo) { $managerInfo.DisplayName } else { '' }
        ManagerMail = if ($null -ne $managerInfo) { $managerInfo.Mail } else { '' }
    }

    $null = Add-EobPlanStep -Plan $plan -Action 'SnapshotBefore' -Title 'Zustandsbericht vorher sichern' -Target $user.SamAccountName -Handler 'Save-EobOffboardingSnapshot' `
        -Phase $script:AlwaysPhase -Critical -Parameters @{ Identity = $guid; Label = 'vorher'; Directory = $snapshotDirectory; OperationId = $plan.OperationId; ExchangeMode = $exchangeMode } `
        -Details @('Attribute, Gruppen, Führungskraft und Unterstellte als JSON (Grundlage für Wiederherstellung und Löschfreigabe).')

    foreach ($phase in @('Immediate', 'ExitDate', 'Retention', 'FinalDeletion')) {
        $details.PhaseStepCount[$phase] = 0
        $dueDate = $phaseDates[$phase]
        $conversionDependency = @()
        $conversionRequested = $actions['ConvertToSharedMailbox'] -ne 'Off'
        $phaseHasLicenses = @($groups | Where-Object {
                $_.Category -eq 'License' -and ($actions['RemoveLicenseGroups'] -eq $phase -or ($_.Remove -and $actions['RemoveGroups'] -eq $phase))
            }).Count -gt 0
        if ($conversionRequested -and $phaseHasLicenses) {
            $conversionDependency = @("SharedMailboxConversionRequired-$phase")
            $phaseOrder = @('Immediate', 'ExitDate', 'Retention', 'FinalDeletion')
            $conversionIndex = [array]::IndexOf($phaseOrder, $actions['ConvertToSharedMailbox'])
            $phaseIndex = [array]::IndexOf($phaseOrder, $phase)
            if ($phaseIndex -lt $conversionIndex) {
                Add-EobPlanFinding -Plan $plan -Severity Error -Code 'OFF_LICENSE_BEFORE_CONVERSION' -Message "Lizenzentfernung in $phase darf nicht vor der Postfachumwandlung stattfinden."
            }
            elseif ($phaseIndex -gt $conversionIndex -and $mailboxAvailable) {
                # Queued plans have no prior runtime results: verify conversion again in this phase.
                $gate = Add-EobPlanStep -Plan $plan -Action 'ConvertToSharedMailbox' -Title 'Freigegebenes Postfach vor Lizenzentfernung erneut prüfen' -Target $user.SamAccountName `
                    -Handler 'ConvertTo-EobSharedMailbox' -Phase $phase -Risk High -Parameters @{ Identity = $mailboxIdentity; Mode = $exchangeMode; VerifyLicenseEligibility = $true }
                $conversionDependency = @($gate.Id)
                $details.PhaseStepCount[$phase]++
            }
            if (-not $mailboxAvailable) {
                Add-EobPlanFinding -Plan $plan -Severity Warning -Code 'OFF_LICENSE_CONVERSION_UNAVAILABLE' -Message 'Lizenzentfernung bleibt gesperrt, solange die angeforderte Postfachumwandlung nicht geprüft werden kann.'
            }
        }
        foreach ($action in $script:ActionOrder) {
            if ($actions[$action] -ne $phase) { continue }
            $before = $plan.Steps.Count
            $stepDetails = @("Phase: $($script:PhaseTitles[$phase])$(if ($phase -ne 'Immediate' -and $null -ne $dueDate) { ' (ab ' + $dueDate.ToString('dd.MM.yyyy') + ')' })")
            $common = @{ Plan = $plan; Action = $action; Target = $user.SamAccountName; Phase = $phase }
            if ($null -ne $dueDate) { $common['DueDate'] = $dueDate }
            switch ($action) {
                'DisableAccount' {
                    if ($user.Enabled) {
                        $null = Add-EobPlanStep @common -Title $script:ActionTitles[$action] -Handler 'Disable-EobAdUserAccount' -Risk High -Parameters @{ Identity = $guid; AllowPrivileged = $allowPrivileged } -Details $stepDetails
                    }
                }
                'SetExpiration' {
                    $expires = $Request.ExitDate.Date.AddDays(1)
                    $null = Add-EobPlanStep @common -Title $script:ActionTitles[$action] -Handler 'Set-EobAdUserExpiration' -Risk Medium -Parameters @{ Identity = $guid; ExpiresAt = $expires; AllowPrivileged = $allowPrivileged } `
                        -Details ($stepDetails + "Konto läuft ab: $($expires.ToString('dd.MM.yyyy HH:mm')) (Ende des Austrittstags)")
                }
                'DenyLogonHours' {
                    $null = Add-EobPlanStep @common -Title $script:ActionTitles[$action] -Handler 'Set-EobAdUserLogonHours' -Risk Medium -Parameters @{ Identity = $guid; AllowPrivileged = $allowPrivileged } -Details $stepDetails
                }
                'UpdateDescription' {
                    $descriptionTemplate = if ($template.DescriptionTemplate) { $template.DescriptionTemplate } else { [string](Get-EobConfigValue -Config $Config -Section 'Offboarding' -Key 'DescriptionTemplate') }
                    $text = Format-EobOffboardingText -Template $descriptionTemplate -Values $textValues
                    if ($text.Length -gt 1024) { $text = $text.Substring(0, 1024) }
                    if ($text) {
                        $null = Add-EobPlanStep @common -Title $script:ActionTitles[$action] -Handler 'Set-EobAdUserAttribute' -Risk Low -Parameters @{ Identity = $guid; Replace = @{ description = $text }; AllowPrivileged = $allowPrivileged } `
                            -Details ($stepDetails + "Bisher: '$($user.Description)'", "Neu: '$text'")
                    }
                }
                'ResetPassword' {
                    if (-not $plan.Secrets.ContainsKey('OffboardingPassword')) {
                        $plan.Secrets['OffboardingPassword'] = New-EobPassword -Policy (Get-EobPasswordPolicy -Config $Config) -Length 32
                    }
                    $null = Add-EobPlanStep @common -Title $script:ActionTitles[$action] -Handler 'Reset-EobAdUserPassword' -Risk High `
                        -Parameters @{ Identity = $guid; NewPassword = '@Secret:OffboardingPassword'; ChangePasswordAtLogon = $true; AllowPrivileged = $allowPrivileged } `
                        -Details ($stepDetails + 'Zufallskennwort mit 32 Zeichen; es wird weder angezeigt noch gespeichert.')
                }
                'ForcePasswordChange' {
                    $null = Add-EobPlanStep @common -Title $script:ActionTitles[$action] -Handler 'Set-EobAdUserPasswordChangeRequired' -Risk Low -Parameters @{ Identity = $guid; AllowPrivileged = $allowPrivileged } -Details $stepDetails
                }
                'RevokeSessions' {
                    if (-not (Get-EobConfigValue -Config $Config -Section 'Graph' -Key 'Enabled' -As Bool)) {
                        Add-EobPlanFinding -Plan $plan -Severity Information -Code 'OFF_GRAPH_DISABLED' -Message 'Microsoft Graph ist deaktiviert: Cloud-Sitzungen werden nicht widerrufen (Kennwort-Reset und Deaktivierung wirken nach der Synchronisation).'
                    }
                    elseif (-not $user.UserPrincipalName) {
                        Add-EobPlanFinding -Plan $plan -Severity Warning -Code 'OFF_NO_UPN' -Message 'Ohne UPN können Cloud-Sitzungen nicht widerrufen werden.'
                    }
                    else {
                        $null = Add-EobPlanStep @common -Title $script:ActionTitles[$action] -Handler 'Revoke-EobEntraUserSession' -Risk Medium -Parameters @{ UserPrincipalName = $user.UserPrincipalName } -Details $stepDetails
                    }
                }
                'RemoveGroups' {
                    foreach ($group in @($groups | Where-Object Remove)) {
                        $risk = if ($group.Category -eq 'Privileged') { 'High' } else { 'Medium' }
                        $groupDependencies = @()
                        if ($group.Category -eq 'License') { $groupDependencies = $conversionDependency }
                        $null = Add-EobPlanStep @common -Title "Aus Gruppe entfernen: $($group.Name)" -Handler 'Remove-EobAdGroupMembership' -Risk $risk `
                            -DependsOn $groupDependencies `
                            -Parameters @{ Identity = $guid; Group = $group.DistinguishedName; AllowPrivileged = $allowPrivileged } `
                            -Details ($stepDetails + "Kategorie: $($group.Category)$(if ($group.Reason) { ' - ' + $group.Reason })")
                    }
                }
                'RemoveLicenseGroups' {
                    foreach ($group in @($groups | Where-Object Category -EQ 'License')) {
                        $null = Add-EobPlanStep @common -Title "Lizenzgruppe entfernen: $($group.Name)" -Handler 'Remove-EobAdGroupMembership' -Risk Medium `
                            -DependsOn $conversionDependency `
                            -Parameters @{ Identity = $guid; Group = $group.DistinguishedName; AllowPrivileged = $allowPrivileged } -Details $stepDetails
                    }
                }
                'ClearManager' {
                    if ($user.Manager) {
                        $null = Add-EobPlanStep @common -Title $script:ActionTitles[$action] -Handler 'Set-EobAdUserManager' -Risk Low -Parameters @{ Identity = $guid; AllowPrivileged = $allowPrivileged } `
                            -Details ($stepDetails + "Bisher: $(if ($null -ne $managerInfo) { $managerInfo.DisplayName } else { $user.Manager })")
                    }
                }
                'MoveToOU' {
                    $targetOu = if ($Request.TargetOU) { $Request.TargetOU } elseif ($template.TargetOU) { $template.TargetOU } else { [string](Get-EobConfigValue -Config $Config -Section 'Offboarding' -Key 'DisabledUsersOU') }
                    if (-not $targetOu) {
                        Add-EobPlanFinding -Plan $plan -Severity Warning -Code 'OFF_NO_TARGET_OU' -Message 'Keine Austritts-OU konfiguriert ([Offboarding] DisabledUsersOU): Das Konto wird nicht verschoben.'
                    }
                    elseif ($user.ParentContainer -ieq $targetOu) {
                        Add-EobPlanFinding -Plan $plan -Severity Information -Code 'OFF_ALREADY_IN_OU' -Message 'Das Konto befindet sich bereits in der Austritts-OU.'
                    }
                    elseif (-not (Test-EobAdOrganizationalUnit -DistinguishedName $targetOu)) {
                        Add-EobPlanFinding -Plan $plan -Severity Warning -Code 'OFF_TARGET_OU_MISSING' -Message "Die Austritts-OU existiert nicht: $targetOu"
                    }
                    else {
                        $null = Add-EobPlanStep @common -Title "$($script:ActionTitles[$action]): $targetOu" -Handler 'Move-EobAdUserAccount' -Risk Medium -Parameters @{ Identity = $guid; TargetPath = $targetOu; AllowPrivileged = $allowPrivileged } `
                            -Details ($stepDetails + "Bisher: $($user.ParentContainer)")
                    }
                }
                'HideFromAddressLists' {
                    if ($mailboxAvailable) {
                        if ($exchangeMode -eq 'OnPremises') {
                            $null = Add-EobPlanStep @common -Title $script:ActionTitles[$action] -Handler 'Set-EobMailboxHidden' -Risk Low -Parameters @{ Identity = $mailboxIdentity; Mode = $exchangeMode } -Details $stepDetails
                        }
                        else {
                            $null = Add-EobPlanStep @common -Title $script:ActionTitles[$action] -Handler 'Set-EobAdUserAttribute' -Risk Low `
                                -Parameters @{ Identity = $guid; Replace = @{ msExchHideFromAddressLists = $true }; AllowPrivileged = $allowPrivileged } `
                                -Details ($stepDetails + 'Setzt das AD-Attribut msExchHideFromAddressLists (Exchange-Schema erforderlich); wirkt nach der Synchronisation.')
                        }
                    }
                }
                'SetAutoReply' {
                    if ($mailboxAvailable) {
                        $messageTemplate = @($Request.AutoReplyMessage, $template.AutoReplyMessage, [string](Get-EobConfigValue -Config $Config -Section 'Offboarding' -Key 'AutoReplyMessage'), $script:DefaultAutoReply) |
                            Where-Object { $_ } | Select-Object -First 1
                        $message = Format-EobOffboardingText -Template $messageTemplate -Values $textValues
                        $null = Add-EobPlanStep @common -Title $script:ActionTitles[$action] -Handler 'Set-EobMailboxAutoReply' -Risk Low -Parameters @{ Identity = $mailboxIdentity; Mode = $exchangeMode; Message = $message } `
                            -Details ($stepDetails + "Text: $message")
                    }
                }
                'SetForwarding' {
                    if ($mailboxAvailable) {
                        $forwardTo = $Request.ForwardTo
                        if (-not $forwardTo -and $template.ForwardToManager -and $null -ne $managerInfo) { $forwardTo = $managerInfo.Mail }
                        if (-not $forwardTo) {
                            Add-EobPlanFinding -Plan $plan -Severity Warning -Code 'OFF_NO_FORWARD_TARGET' -Message 'Keine Weiterleitungsadresse (Anfrage oder Führungskraft mit E-Mail-Adresse): Weiterleitung entfällt.'
                        }
                        else {
                            $null = Add-EobPlanStep @common -Title "$($script:ActionTitles[$action]): $forwardTo" -Handler 'Set-EobMailboxForwarding' -Risk Medium `
                                -Parameters @{ Identity = $mailboxIdentity; Mode = $exchangeMode; ForwardTo = $forwardTo; InternalDomains = (Get-EobInternalMailDomain -Config $Config); DeliverToMailboxAndForward = $true } `
                                -Details ($stepDetails + 'Nur an interne Domänen; Kopie bleibt im Postfach.')
                        }
                    }
                }
                'ConvertToSharedMailbox' {
                    if ($mailboxAvailable) {
                        $conversion = Add-EobPlanStep @common -Title $script:ActionTitles[$action] -Handler 'ConvertTo-EobSharedMailbox' -Risk High -Parameters @{ Identity = $mailboxIdentity; Mode = $exchangeMode; VerifyLicenseEligibility = $phaseHasLicenses } `
                            -Details ($stepDetails + 'Vor dem Entfernen der Lizenz; Größe/Archiv auf Lizenzbedarf prüfen.')
                        $conversionDependency = @($conversion.Id)
                    }
                }
                'DocumentMailboxPermissions' {
                    if ($mailboxAvailable) {
                        $null = Add-EobPlanStep @common -Title $script:ActionTitles[$action] -Handler 'Export-EobOffboardingMailboxPermission' -Risk Low `
                            -Parameters @{ Identity = $mailboxIdentity; Mode = $exchangeMode; Directory = $snapshotDirectory; SamAccountName = $user.SamAccountName; OperationId = $plan.OperationId } -Details $stepDetails
                    }
                }
                'ArchiveHomeDirectory' {
                    $roots = @(Get-EobConfigValue -Config $Config -Section 'FileServer' -Key 'AllowedRoots' -As List)
                    $archiveRoot = [string](Get-EobConfigValue -Config $Config -Section 'FileServer' -Key 'ArchiveRoot')
                    if (-not $user.HomeDirectory) {
                        Add-EobPlanFinding -Plan $plan -Severity Information -Code 'OFF_NO_HOME' -Message 'Kein Home-Verzeichnis eingetragen.'
                    }
                    elseif (-not $archiveRoot -or @($roots | Where-Object { Test-EobPathWithin -Path $user.HomeDirectory -Root $_ }).Count -eq 0 -or @($roots | Where-Object { Test-EobPathWithin -Path $archiveRoot -Root $_ }).Count -eq 0) {
                        Add-EobPlanFinding -Plan $plan -Severity Warning -Code 'OFF_HOME_NOT_ALLOWED' -Message "Home-Verzeichnis '$($user.HomeDirectory)' bzw. Archivziel liegt nicht unter [FileServer] AllowedRoots: Archivierung entfällt."
                    }
                    else {
                        $archive = Add-EobPlanStep @common -Title $script:ActionTitles[$action] -Handler 'Move-EobHomeDirectoryToArchive' -Risk High `
                            -Parameters @{ Path = $user.HomeDirectory; ArchiveRoot = $archiveRoot; AllowedRoots = $roots; SamAccountName = $user.SamAccountName } `
                            -Details ($stepDetails + "Von: $($user.HomeDirectory)", "Nach: $archiveRoot")
                        $null = Add-EobPlanStep @common -Title 'Home-Verzeichnis im Konto austragen' -Handler 'Set-EobAdUserAttribute' -Risk Low -DependsOn $archive.Id `
                            -Parameters @{ Identity = $guid; Clear = @('homeDirectory', 'homeDrive'); AllowPrivileged = $allowPrivileged } -Details $stepDetails
                    }
                }
                'GrantManagerHomeAccess' {
                    $roots = @(Get-EobConfigValue -Config $Config -Section 'FileServer' -Key 'AllowedRoots' -As List)
                    $netbios = if ($null -ne $connection.Domain) { [string](Get-EobPropertyValue -InputObject $connection.Domain -Name 'NetBiosName' -Default '') } else { '' }
                    $authorization = [string](Get-EobPropertyValue -InputObject $Request -Name 'AuthorizedHomeAccessAccount' -Default '')
                    $managerPrincipal = if ($netbios -and $null -ne $managerInfo) { "$netbios\$($managerInfo.SamAccountName)" } else { '' }
                    if (-not $user.HomeDirectory -or $null -eq $managerInfo -or -not $managerInfo.SamAccountName) {
                        Add-EobPlanFinding -Plan $plan -Severity Information -Code 'OFF_NO_HOME_ACCESS' -Message 'Lesezugriff für die Führungskraft entfällt (kein Home-Verzeichnis oder keine Führungskraft).'
                    }
                    elseif (-not $authorization -or ($authorization -ine $managerInfo.SamAccountName -and
                            (-not $managerPrincipal -or $authorization -ine $managerPrincipal))) {
                        Add-EobPlanFinding -Plan $plan -Severity Warning -Code 'OFF_HOME_ACCESS_AUTH_REQUIRED' -Message 'Home-Zugriff entfällt: das Empfängerkonto muss ausdrücklich über AuthorizedHomeAccessAccount freigegeben werden; das AD-Managerattribut ist keine Freigabe.'
                    }
                    else {
                        try {
                            Assert-EobOffboardingHomePath -Path $user.HomeDirectory -SamAccountName $user.SamAccountName -AllowedRoots $roots
                            $null = Add-EobPlanStep @common -Title "$($script:ActionTitles[$action]) ($($managerInfo.DisplayName))" -Handler 'Grant-EobHomeDirectoryAccess' -Risk High `
                                -Parameters @{ Path = $user.HomeDirectory; SamAccountName = $user.SamAccountName; Account = $managerInfo.SamAccountName; AuthorizedAccount = $Request.AuthorizedHomeAccessAccount; DomainNetBiosName = $netbios; AllowedRoots = $roots } -Details $stepDetails
                        }
                        catch {
                            Add-EobPlanFinding -Plan $plan -Severity Warning -Code 'OFF_HOME_NOT_ALLOWED' -Message "Home-Zugriff entfällt: $($_.Exception.Message)"
                        }
                    }
                }
                'ClearProfilePath' {
                    if ($user.ProfilePath) {
                        $null = Add-EobPlanStep @common -Title $script:ActionTitles[$action] -Handler 'Set-EobAdUserAttribute' -Risk Low -Parameters @{ Identity = $guid; Clear = @('profilePath'); AllowPrivileged = $allowPrivileged } `
                            -Details ($stepDetails + "Bisher: $($user.ProfilePath) (das Profilverzeichnis selbst bleibt erhalten)")
                    }
                }
                'DeleteAccount' {
                    $null = Add-EobPlanStep @common -Title $script:ActionTitles[$action] -Handler 'Remove-EobAdUserAccount' -Risk Destructive -Enabled $false `
                        -Parameters @{ Identity = $guid; ExpectedObjectGuid = $guid } `
                        -Details @("Frühestens am $($phaseDates['FinalDeletion'].ToString('dd.MM.yyyy')).", 'Nie automatisch: nur nach gesonderter Freigabe mit Vorschau, Snapshot und Tippbestätigung.')
                }
            }
            if ($action -ne 'DeleteAccount') { $details.PhaseStepCount[$phase] += ($plan.Steps.Count - $before) }
        }
    }

    $null = Add-EobPlanStep -Plan $plan -Action 'SnapshotAfter' -Title 'Zustandsbericht nachher sichern' -Target $user.SamAccountName -Handler 'Save-EobOffboardingSnapshot' `
        -Phase $script:AlwaysPhase -Parameters @{ Identity = $guid; Label = 'nachher'; Directory = $snapshotDirectory; OperationId = $plan.OperationId; ExchangeMode = $exchangeMode }

    $exchangeHandlers = @('Set-EobMailboxHidden', 'Set-EobMailboxAutoReply', 'Set-EobMailboxForwarding', 'ConvertTo-EobSharedMailbox', 'Export-EobOffboardingMailboxPermission')
    $details.RequiresExchange = @($plan.Steps | Where-Object { $_.Enabled -and $_.Handler -in $exchangeHandlers } | ForEach-Object Phase | Select-Object -Unique)
    $details.RequiresGraph = @($plan.Steps | Where-Object { $_.Enabled -and $_.Handler -eq 'Revoke-EobEntraUserSession' } | ForEach-Object Phase | Select-Object -Unique)
    $details.RequiresIntegration = @(@($details.RequiresExchange) + @($details.RequiresGraph) | Select-Object -Unique)

    $keptGroups = @($groups | Where-Object { -not $_.Remove -and $_.Category -ne 'License' })
    $plan.Summary['Konto'] = "$($user.DisplayName) ($($user.SamAccountName))"
    $plan.Summary['UPN'] = $user.UserPrincipalName
    $plan.Summary['Vorlage'] = $template.DisplayName
    $plan.Summary['Austrittsdatum'] = $Request.ExitDate.ToString('dd.MM.yyyy')
    $plan.Summary['Phase Austritt ab'] = $phaseDates['ExitDate'].ToString('dd.MM.yyyy')
    $plan.Summary['Aufbewahrung ab'] = $phaseDates['Retention'].ToString('dd.MM.yyyy')
    $plan.Summary['Endgültige Löschung'] = if ($actions['DeleteAccount'] -eq 'FinalDeletion') { 'frühestens ' + $phaseDates['FinalDeletion'].ToString('dd.MM.yyyy') + ' (nur nach Freigabe)' } else { 'nicht vorgesehen' }
    $plan.Summary['Ticket'] = $Request.Ticket
    $plan.Summary['Grund'] = $Request.Reason
    $plan.Summary['Führungskraft'] = if ($null -ne $managerInfo) { $managerInfo.DisplayName } else { '' }
    $plan.Summary['Unterstellte'] = [string]$directReports.Count
    $plan.Summary['Gruppen entfernen'] = [string]@($groups | Where-Object Remove).Count
    $plan.Summary['Gruppen behalten'] = ($keptGroups | ForEach-Object { "$($_.Name) [$($_.Category)]" }) -join ', '
    $plan.Summary['Inventar'] = $Request.Assets -join '; '
    $plan.Summary['Letzte Anmeldung'] = if ($null -ne $user.LastLogonDate) { ([datetime]$user.LastLogonDate).ToString('dd.MM.yyyy HH:mm') } else { '' }
    $plan.Summary['Konto aktiv'] = if ($user.Enabled) { 'ja' } else { 'nein' }
    return $plan
}

function Get-EobOffboardingDuePhase {
    <#
    .SYNOPSIS
        Liefert die zum Zeitpunkt -Now fälligen Phasen (in Reihenfolge, ohne FinalDeletion).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Plan,
        [datetime]$Now = (Get-Date)
    )

    $details = $Plan.Offboarding
    if ($null -eq $details -or $details.PhaseDates.Count -eq 0) { return @() }
    $due = [System.Collections.Generic.List[string]]::new()
    foreach ($phase in $script:ExecutablePhases) {
        if ($phase -in $details.CompletedPhases) { continue }
        if ($details.PhaseDates[$phase] -gt $Now) { break }
        $due.Add($phase)
    }
    return $due.ToArray()
}

#endregion

#region Ausführung und Warteschlange

function Select-EobOffboardingPhase {
    <#
    .SYNOPSIS
        Ermittelt die auszuführenden Phasen (fällig oder manuell gewählt) und prüft die Reihenfolge.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Plan,
        [ValidateSet('Immediate', 'ExitDate', 'Retention')][string[]]$Phase,
        [datetime]$Now = (Get-Date)
    )

    if ($Plan.Kind -ne 'Offboarding' -or $null -eq (Get-EobPropertyValue -InputObject $Plan -Name 'Offboarding')) { throw 'Kein Offboarding-Plan.' }
    $details = $Plan.Offboarding
    if (-not $Phase) { return @(Get-EobOffboardingDuePhase -Plan $Plan -Now $Now) }

    $selected = @($script:ExecutablePhases | Where-Object { $_ -in $Phase })
    $lastIndex = [array]::IndexOf($script:ExecutablePhases, $selected[-1])
    for ($index = 0; $index -lt $lastIndex; $index++) {
        $required = $script:ExecutablePhases[$index]
        if ($required -notin $selected -and $required -notin $details.CompletedPhases -and $details.PhaseStepCount[$required] -gt 0) {
            throw "Die Phase '$($selected[-1])' setzt die Phase '$required' voraus."
        }
    }
    Write-EobLog -Level Warning -OperationId $Plan.OperationId -Action 'OffboardingPhaseOverride' -Target ([string]$Plan.Subject['SamAccountName']) `
        -Message ('Phasen manuell ausgewählt: {0}' -f ($selected -join ', '))
    return $selected
}

function Complete-EobOffboardingRun {
    <#
    .SYNOPSIS
        Vermerkt erledigte Phasen und aktualisiert nach Live-Ausführungen die Warteschlange.
    .DESCRIPTION
        Eine Phase gilt nur als erledigt, wenn alle aktivierten Phasen- und Dokumentationsschritte
        erfolgreich sind (in der Simulation: Simulated). Unvollständige Phasen bleiben wiederholbar.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Plan,
        [AllowEmptyCollection()][string[]]$SelectedPhase = @(),
        [switch]$NoQueue
    )

    $details = $Plan.Offboarding
    foreach ($phaseName in $SelectedPhase) {
        $expectedStatus = if ($Plan.Simulation) { 'Simulated' } else { 'Succeeded' }
        $incomplete = @($Plan.Steps | Where-Object {
                $_.Enabled -and ($_.Phase -eq $phaseName -or ($_.Phase -eq $script:AlwaysPhase -and $Plan.Status -ne 'Scheduled')) -and $_.Status -ne $expectedStatus
            }).Count
        $interrupted = $Plan.Aborted -or $Plan.CancelRequested
        if ($incomplete -gt 0 -or $interrupted) {
            $details.CompletedPhases = @($details.CompletedPhases | Where-Object { $_ -ne $phaseName })
        }
        if ($incomplete -eq 0 -and -not $interrupted -and $phaseName -notin $details.CompletedPhases) {
            $details.CompletedPhases += $phaseName
        }
    }
    $hasErrors = @($Plan.Findings | Where-Object Severity -EQ 'Error').Count -gt 0
    if (-not $Plan.Simulation -and -not $NoQueue -and -not $hasErrors -and $null -ne $details.User) {
        if ($PSCmdlet.ShouldProcess($Plan.OperationId, 'Offboarding-Warteschlange aktualisieren')) {
            $null = Save-EobOffboardingQueueEntry -Plan $Plan -Confirm:$false
        }
    }
    return $Plan
}

function Invoke-EobOffboardingPlan {
    <#
    .SYNOPSIS
        Führt die fälligen Phasen eines Offboarding-Plans aus (oder simuliert sie mit -WhatIf).
    .DESCRIPTION
        Ohne -Phase werden die fälligen Phasen ausgeführt. Mit -Phase lassen sich Phasen
        vorziehen (z. B. vorzeitiger Austritt); vorherige Phasen müssen erledigt sein oder mit
        ausgeführt werden. FinalDeletion ist nie Teil dieser Ausführung. Nach einer Live-Ausführung
        wird der Vorgang in die Warteschlange übernommen, solange Phasen offen sind.
        Live-Ausführungen werden einmalig bestätigt (ConfirmImpact High); die Oberfläche und die
        geplante Ausführung bestätigen selbst und rufen mit -Confirm:$false auf.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Plan,
        [ValidateSet('Immediate', 'ExitDate', 'Retention')][string[]]$Phase,
        [datetime]$Now = (Get-Date),
        [switch]$NoQueue
    )

    $selectParameters = @{ Plan = $Plan; Now = $Now }
    if ($Phase) { $selectParameters['Phase'] = $Phase }
    $selected = @(Select-EobOffboardingPhase @selectParameters)
    if ($WhatIfPreference) { $Plan.Simulation = $true }
    $withSteps = @($selected | Where-Object { $Plan.Offboarding.PhaseStepCount[$_] -gt 0 })
    if ($withSteps.Count -eq 0) {
        $Plan.Status = 'Scheduled'
        return (Complete-EobOffboardingRun -Plan $Plan -SelectedPhase $selected -NoQueue:$NoQueue -Confirm:$false)
    }
    if (-not $Plan.Simulation -and (Test-EobPlanExecutable -Plan $Plan)) {
        $target = [string](Get-EobPropertyValue -InputObject $Plan.Subject -Name 'SamAccountName' -Default $Plan.OperationId)
        if (-not $PSCmdlet.ShouldProcess($target, "Offboarding-Phasen ausführen: $($withSteps -join ', ')")) {
            $Plan.Status = 'Cancelled'
            return $Plan
        }
    }
    $null = Invoke-EobPlan -Plan $Plan -IncludePhase (@($script:AlwaysPhase) + $selected) -WhatIf:$Plan.Simulation -Confirm:$false
    return (Complete-EobOffboardingRun -Plan $Plan -SelectedPhase $selected -NoQueue:$NoQueue -Confirm:$false)
}

function Get-EobOffboardingIncludePhase {
    <#
    .SYNOPSIS
        Liefert die Phasenliste für Invoke-EobPlan bzw. die kooperative Ausführung (inkl. Dokumentation).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowEmptyCollection()][string[]]$SelectedPhase = @())

    return @(@($script:AlwaysPhase) + $SelectedPhase)
}

function ConvertTo-EobOffboardingQueueRequest {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][pscustomobject]$Plan)

    $request = $Plan.Offboarding.Request
    [ordered]@{
        Identity              = $Plan.Offboarding.User.ObjectGuid
        Template              = $request.Template
        ExitDate              = $request.ExitDate.ToString('yyyy-MM-dd')
        Ticket                = $request.Ticket
        Reason                = $request.Reason
        Notes                 = $request.Notes
        ForwardTo             = $request.ForwardTo
        AuthorizedHomeAccessAccount = Get-EobPropertyValue -InputObject $request -Name 'AuthorizedHomeAccessAccount' -Default ''
        AutoReplyMessage      = $request.AutoReplyMessage
        TargetOU              = $request.TargetOU
        KeepGroups            = @($request.KeepGroups)
        SelectedGroups        = @($request.SelectedGroups)
        Assets                = @($request.Assets)
        ActionPhases          = $request.ActionPhases
        AcknowledgePrivileged = [bool]$request.AcknowledgePrivileged
    }
}

function Get-EobOffboardingQueueStatus {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][pscustomobject]$Plan)

    $details = $Plan.Offboarding
    foreach ($phase in $script:ExecutablePhases) {
        if ($details.PhaseStepCount[$phase] -gt 0 -and $phase -notin $details.CompletedPhases) { return 'Open' }
    }
    $deleteStep = @($Plan.Steps | Where-Object Action -EQ 'DeleteAccount')
    if ($deleteStep.Count -gt 0) { return 'AwaitingDeletion' }
    return 'Completed'
}

function Get-EobSnapshotHashTable {
    <#
    .SYNOPSIS
        Führt die SHA-256-Prüfsummen der Zustandsberichte (Pfad = Prüfsumme) aus Warteschlange und Lauf zusammen.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowNull()][System.Collections.IDictionary]$Entry,
        [AllowNull()][System.Collections.IDictionary]$Runtime
    )

    $hashes = [ordered]@{}
    if ($null -ne $Entry -and $Entry.Contains('SnapshotHashes') -and $Entry['SnapshotHashes'] -is [System.Collections.IDictionary]) {
        foreach ($key in $Entry['SnapshotHashes'].Keys) { $hashes[[string]$key] = [string]$Entry['SnapshotHashes'][$key] }
    }
    if ($null -ne $Runtime) {
        foreach ($key in @($Runtime.Keys | Where-Object { $_ -like 'Snapshot_*' })) {
            $hashKey = 'SnapshotHash_' + $key.Substring('Snapshot_'.Length)
            if ($Runtime.Contains($hashKey) -and $Runtime[$key]) { $hashes[[string]$Runtime[$key]] = [string]$Runtime[$hashKey] }
        }
    }
    return $hashes
}

function Test-EobSnapshotIntegrity {
    <#
    .SYNOPSIS
        Prüft einen Zustandsbericht gegen die in der Warteschlange gespeicherte SHA-256-Prüfsumme.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()][System.Collections.IDictionary]$Entry,
        [Parameter(Mandatory)][string]$Path
    )

    if ($null -eq $Entry -or -not $Entry.Contains('SnapshotHashes') -or $Entry['SnapshotHashes'] -isnot [System.Collections.IDictionary]) { return $false }
    $expected = [string]$Entry['SnapshotHashes'][$Path]
    if (-not $expected -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    return ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -eq $expected)
}

function Save-EobOffboardingQueueEntry {
    <#
    .SYNOPSIS
        Legt einen Offboarding-Vorgang in der Warteschlange an oder aktualisiert ihn.
    .DESCRIPTION
        Gespeichert werden nur Anfragedaten, Fälligkeiten, erledigte Phasen, Snapshot-Pfade und
        eine Historie - keine Kennwörter oder sonstigen Secrets.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param([Parameter(Mandatory)][pscustomobject]$Plan)

    $details = $Plan.Offboarding
    if ($null -eq $details.User) { throw 'Der Plan enthält keinen aufgelösten Benutzer.' }
    $directory = Get-EobOffboardingDirectory -Config $Plan.Config -Kind Queue
    $path = Join-Path -Path $directory -ChildPath ('{0}.json' -f $Plan.OperationId)
    if (-not $PSCmdlet.ShouldProcess($path, 'Offboarding-Warteschlange aktualisieren')) { return $path }

    $existing = $null
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $existing = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    }
    $snapshots = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $existing -and $existing.ContainsKey('SnapshotPaths')) { foreach ($item in @($existing['SnapshotPaths'])) { if ($item) { $snapshots.Add([string]$item) } } }
    foreach ($key in @($Plan.Runtime.Keys | Where-Object { $_ -like 'Snapshot_*' -or $_ -eq 'MailboxPermissionReport' })) {
        $value = [string]$Plan.Runtime[$key]
        if ($value -and -not $snapshots.Contains($value)) { $snapshots.Add($value) }
    }
    $hashes = Get-EobSnapshotHashTable -Entry $existing -Runtime $Plan.Runtime
    $history = [System.Collections.Generic.List[object]]::new()
    if ($null -ne $existing -and $existing.ContainsKey('History')) { foreach ($item in @($existing['History'])) { $history.Add($item) } }
    $executed = @($Plan.Steps | Where-Object { $_.Status -notin @('Planned') -and $_.Phase -ne $script:AlwaysPhase } | ForEach-Object Phase | Select-Object -Unique)
    $history.Add([ordered]@{
            Timestamp = (Get-Date).ToString('o')
            Actor     = (Get-EobCurrentIdentity).Name
            Phases    = @($executed)
            Outcome   = [string]$Plan.Status
            Failed    = @($Plan.Steps | Where-Object Status -EQ 'Failed' | ForEach-Object { "$($_.Id) $($_.Title)" })
        })

    $dates = [ordered]@{}
    foreach ($phase in @('Immediate', 'ExitDate', 'Retention', 'FinalDeletion')) {
        $value = $details.PhaseDates[$phase]
        $dates[$phase] = if ($null -ne $value) { ([datetime]$value).ToString('yyyy-MM-dd') } else { $null }
    }
    $entry = [ordered]@{
        SchemaVersion     = 1
        OperationId       = $Plan.OperationId
        Status            = Get-EobOffboardingQueueStatus -Plan $Plan
        CreatedAt         = if ($null -ne $existing -and $existing.ContainsKey('CreatedAt')) { $existing['CreatedAt'] } else { (Get-Date).ToString('o') }
        CreatedBy         = if ($null -ne $existing -and $existing.ContainsKey('CreatedBy')) { $existing['CreatedBy'] } else { $Plan.CreatedBy }
        UpdatedAt         = (Get-Date).ToString('o')
        Template          = $details.Template.Name
        ObjectGuid        = $details.User.ObjectGuid
        SamAccountName    = $details.User.SamAccountName
        UserPrincipalName = $details.User.UserPrincipalName
        DisplayName       = $details.User.DisplayName
        ExitDate          = $details.Request.ExitDate.ToString('yyyy-MM-dd')
        PhaseDates        = $dates
        PhaseStepCount    = $details.PhaseStepCount
        CompletedPhases   = @($details.CompletedPhases | Select-Object -Unique)
        Privileged        = [bool]$details.Privileged
        RequiresIntegration = @($details.RequiresIntegration)
        SnapshotPaths     = $snapshots.ToArray()
        SnapshotHashes    = $hashes
        History           = $history.ToArray()
        Request           = ConvertTo-EobOffboardingQueueRequest -Plan $Plan
    }
    Write-EobJsonFile -Path $path -InputObject $entry
    Write-EobLog -Level Audit -OperationId $Plan.OperationId -Action 'OffboardingQueued' -Target $details.User.SamAccountName -Result $entry.Status `
        -Message ('Warteschlange aktualisiert (erledigt: {0})' -f (($entry.CompletedPhases) -join ', '))
    return $path
}

function Get-EobOffboardingQueue {
    <#
    .SYNOPSIS
        Liest die Offboarding-Warteschlange (mit berechneter nächster Fälligkeit).
    .PARAMETER Status
        Filter: Open, AwaitingDeletion, Completed, Cancelled.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()][pscustomobject]$Config,
        [ValidateSet('Open', 'AwaitingDeletion', 'Completed', 'Cancelled', 'Deleted')][string[]]$Status,
        [datetime]$Now = (Get-Date)
    )

    $directory = Get-EobOffboardingDirectory -Config $Config -Kind Queue
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { return }
    foreach ($file in Get-ChildItem -LiteralPath $directory -Filter '*.json' -File | Sort-Object -Property Name) {
        try {
            $entry = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
            # Leere Dateien oder JSON ohne Objekt bzw. ohne Phasendaten würden sonst das Lesen der gesamten
            # Warteschlange abbrechen (Dashboard, Offboarding-Ansicht, geplante Aufgabe).
            if ($entry -isnot [System.Collections.IDictionary]) { throw 'Kein JSON-Objekt.' }
            if ($entry['PhaseDates'] -isnot [System.Collections.IDictionary]) { throw 'PhaseDates fehlt oder ist ungültig.' }
        }
        catch {
            Write-EobLog -Level Warning -Action 'OffboardingQueueRead' -Target $file.Name -Message "Warteschlangeneintrag ist beschädigt: $($_.Exception.Message)"
            continue
        }
        if ($Status -and $entry['Status'] -notin $Status) { continue }
        $completed = @($entry['CompletedPhases'])
        $nextPhase = ''
        $nextDate = $null
        foreach ($phase in $script:ExecutablePhases) {
            if ($phase -in $completed) { continue }
            if ($entry['PhaseStepCount'] -is [System.Collections.IDictionary] -and
                $entry['PhaseStepCount'].Contains($phase) -and [int]$entry['PhaseStepCount'][$phase] -eq 0) { continue }
            $nextPhase = $phase
            $nextDate = ConvertTo-EobDate -Value ([string]$entry['PhaseDates'][$phase])
            if ($phase -eq 'Immediate' -and $null -eq $nextDate) { $nextDate = $Now.Date }
            break
        }
        $deletionDate = if ($entry['PhaseDates']['FinalDeletion']) { ConvertTo-EobDate -Value ([string]$entry['PhaseDates']['FinalDeletion']) } else { $null }
        [pscustomobject]@{
            PSTypeName          = 'Eob.OffboardingQueueEntry'
            OperationId         = [string]$entry['OperationId']
            Status              = [string]$entry['Status']
            SamAccountName      = [string]$entry['SamAccountName']
            DisplayName         = [string]$entry['DisplayName']
            Template            = [string]$entry['Template']
            ExitDate            = ConvertTo-EobDate -Value ([string]$entry['ExitDate'])
            NextPhase           = if ($entry['Status'] -eq 'Open') { $nextPhase } else { '' }
            NextDueDate         = if ($entry['Status'] -eq 'Open') { $nextDate } else { $null }
            IsDue               = ($entry['Status'] -eq 'Open' -and $null -ne $nextDate -and $nextDate -le $Now)
            DeletionDate        = $deletionDate
            DeletionDue         = ($entry['Status'] -eq 'AwaitingDeletion' -and $null -ne $deletionDate -and $deletionDate -le $Now)
            Privileged          = [bool]$entry['Privileged']
            RequiresIntegration = @($entry['RequiresIntegration'])
            Path                = $file.FullName
            Entry               = $entry
        }
    }
}

function Stop-EobOffboardingQueueEntry {
    <#
    .SYNOPSIS
        Bricht einen Offboarding-Vorgang in der Warteschlange ab (z. B. Rücknahme der Kündigung).
    .DESCRIPTION
        Bereits ausgeführte Aktionen werden nicht zurückgenommen; der Zustandsbericht "vorher"
        dient als Grundlage für die manuelle Wiederherstellung.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()][pscustomobject]$Config,
        [Parameter(Mandatory)][string]$OperationId,
        [Parameter(Mandatory)][string]$Reason
    )

    $item = Get-EobOffboardingQueue -Config $Config | Where-Object OperationId -EQ $OperationId | Select-Object -First 1
    if ($null -eq $item) { throw "Vorgang $OperationId ist nicht in der Warteschlange." }
    if (-not $PSCmdlet.ShouldProcess($item.SamAccountName, 'Offboarding-Vorgang abbrechen')) {
        return New-EobNotProcessedResult -Message "Offboarding von $($item.SamAccountName) würde abgebrochen."
    }
    $entry = $item.Entry
    $entry['Status'] = 'Cancelled'
    $entry['UpdatedAt'] = (Get-Date).ToString('o')
    $history = [System.Collections.Generic.List[object]]::new()
    foreach ($historyItem in @($entry['History'])) { $history.Add($historyItem) }
    $history.Add([ordered]@{ Timestamp = (Get-Date).ToString('o'); Actor = (Get-EobCurrentIdentity).Name; Phases = @(); Outcome = 'Cancelled'; Failed = @(); Reason = $Reason })
    $entry['History'] = $history.ToArray()
    Write-EobJsonFile -Path $item.Path -InputObject $entry
    Write-EobLog -Level Audit -OperationId $OperationId -Action 'OffboardingCancelled' -Target $item.SamAccountName -Result 'Cancelled' -Message "Vorgang abgebrochen: $Reason"
    return New-EobResult -Status Succeeded -Message "Offboarding von $($item.SamAccountName) abgebrochen. Bereits ausgeführte Aktionen bleiben bestehen."
}

function New-EobOffboardingPlanFromQueue {
    <#
    .SYNOPSIS
        Erstellt aus einem Warteschlangeneintrag einen aktuellen Plan für die Folgephasen.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Erzeugt nur ein Objekt im Speicher; keine Systemänderung.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][pscustomobject]$QueueEntry,
        [AllowNull()][pscustomobject]$Config,
        [datetime]$Now = (Get-Date),
        [switch]$Simulation
    )

    $request = ConvertTo-EobOffboardingRequest -InputObject $QueueEntry.Entry['Request'] -Config $Config
    return (New-EobOffboardingPlan -Request $request -Config $Config -Now $Now -Simulation:$Simulation -OperationId $QueueEntry.OperationId `
            -CompletedPhases @($QueueEntry.Entry['CompletedPhases']) -ExpectedObjectGuid ([string]$QueueEntry.Entry['ObjectGuid']))
}

function Invoke-EobDueOffboardingPhase {
    <#
    .SYNOPSIS
        Verarbeitet fällige Folgephasen der Warteschlange (z. B. per geplanter Aufgabe).
    .DESCRIPTION
        - Führt nie eine endgültige Löschung aus; fällige Löschungen werden nur gemeldet.
        - Privilegierte Konten und Vorgänge, deren fällige Phasen Exchange/Graph benötigen,
          werden nicht unbeaufsichtigt ausgeführt, sondern zur manuellen Ausführung gemeldet
          (außer die Verbindung besteht und -AllowIntegration ist gesetzt).
        - Pro Vorgang wird ein Bericht geschrieben.
    .OUTPUTS
        Je Vorgang ein Ergebnisobjekt (OperationId, SamAccountName, Action, Phases, Outcome, Message).
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()][pscustomobject]$Config,
        [datetime]$Now = (Get-Date),
        [switch]$AllowIntegration
    )

    foreach ($item in @(Get-EobOffboardingQueue -Config $Config -Now $Now)) {
        if ($item.DeletionDue) {
            Write-EobLog -Level Warning -OperationId $item.OperationId -Action 'OffboardingDeletionDue' -Target $item.SamAccountName -Message 'Endgültige Löschung fällig: manuelle Freigabe erforderlich.'
            [pscustomobject]@{ OperationId = $item.OperationId; SamAccountName = $item.SamAccountName; Action = 'DeletionDue'; Phases = @('FinalDeletion'); Outcome = 'ManualApprovalRequired'; Message = 'Endgültige Löschung fällig - nur nach manueller Freigabe.' }
            continue
        }
        if (-not $item.IsDue) { continue }
        if ($item.Privileged) {
            Write-EobLog -Level Warning -OperationId $item.OperationId -Action 'OffboardingManualRequired' -Target $item.SamAccountName -Message 'Privilegiertes Konto: Folgephase nur manuell.'
            [pscustomobject]@{ OperationId = $item.OperationId; SamAccountName = $item.SamAccountName; Action = 'Skipped'; Phases = @($item.NextPhase); Outcome = 'ManualRequired'; Message = 'Privilegiertes Konto: bitte manuell ausführen.' }
            continue
        }
        $plan = New-EobOffboardingPlanFromQueue -QueueEntry $item -Config $Config -Now $Now -Simulation:$WhatIfPreference
        if (-not (Test-EobPlanExecutable -Plan $plan)) {
            $messages = @($plan.Findings | Where-Object Severity -EQ 'Error' | ForEach-Object Message) -join ' | '
            Write-EobLog -Level Error -OperationId $item.OperationId -Action 'OffboardingPhaseBlocked' -Target $item.SamAccountName -Message $messages
            [pscustomobject]@{ OperationId = $item.OperationId; SamAccountName = $item.SamAccountName; Action = 'Blocked'; Phases = @($item.NextPhase); Outcome = 'Blocked'; Message = $messages }
            continue
        }
        $due = @(Get-EobOffboardingDuePhase -Plan $plan -Now $Now)
        $needsExchange = @($due | Where-Object { $_ -in $plan.Offboarding.RequiresExchange }).Count -gt 0
        $needsGraph = @($due | Where-Object { $_ -in $plan.Offboarding.RequiresGraph }).Count -gt 0
        $exchangeReady = -not $needsExchange -or ($AllowIntegration -and (Test-EobExchangeConnected -Mode $plan.Offboarding.ExchangeMode))
        $graphReady = -not $needsGraph -or ($AllowIntegration -and (Get-EobGraphStatus -Config $Config).State -eq 'Connected')
        if (-not ($exchangeReady -and $graphReady)) {
            $missing = @(if (-not $exchangeReady) { 'Exchange' }; if (-not $graphReady) { 'Microsoft Graph' }) -join ', '
            Write-EobLog -Level Warning -OperationId $item.OperationId -Action 'OffboardingManualRequired' -Target $item.SamAccountName -Message "Fällige Phase(n) $($due -join ', ') benötigen $($missing): manuell ausführen."
            [pscustomobject]@{ OperationId = $item.OperationId; SamAccountName = $item.SamAccountName; Action = 'Skipped'; Phases = $due; Outcome = 'ManualRequired'; Message = "$missing erforderlich: bitte in der Oberfläche ausführen." }
            continue
        }
        if (-not $PSCmdlet.ShouldProcess($item.SamAccountName, "Offboarding-Phase(n) $($due -join ', ') ausführen")) {
            $plan.Simulation = $true
        }
        $result = Invoke-EobOffboardingPlan -Plan $plan -Now $Now -WhatIf:($plan.Simulation) -Confirm:$false
        try {
            $null = Export-EobPlanReport -Plan $result -Config $Config -Confirm:$false
        }
        catch {
            Write-EobLog -Level Warning -OperationId $item.OperationId -Action 'ReportWritten' -Target $item.SamAccountName -Message "Bericht konnte nicht geschrieben werden: $($_.Exception.Message)"
        }
        [pscustomobject]@{ OperationId = $item.OperationId; SamAccountName = $item.SamAccountName; Action = 'Executed'; Phases = $due; Outcome = [string]$result.Status; Message = '' }
    }
}

#endregion

#region Endgültige Löschung

function Get-EobDeletionConfirmationText {
    <#
    .SYNOPSIS
        Liefert den Text, den Administratoren zur Freigabe der Löschung eintippen müssen.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$SamAccountName)

    return "LÖSCHEN $SamAccountName"
}

function New-EobOffboardingDeletionPlan {
    <#
    .SYNOPSIS
        Erstellt den Plan für die endgültige Löschung eines Kontos aus der Warteschlange.
    .DESCRIPTION
        Voraussetzungen (sonst blockierende Befunde): Vorgang wartet auf Löschung, Aufbewahrungsfrist
        abgelaufen (RetentionDays > 0), Zustandsbericht "vorher" vorhanden, Konto per ObjectGUID
        eindeutig, deaktiviert, nicht geschützt und nicht vor Löschung geschützt. Warnt, wenn der
        AD-Papierkorb deaktiviert ist oder ein synchronisiertes Postfach mitgelöscht würde.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Erzeugt nur ein Objekt im Speicher; keine Systemänderung.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$OperationId,
        [AllowNull()][pscustomobject]$Config,
        [datetime]$Now = (Get-Date)
    )

    $item = Get-EobOffboardingQueue -Config $Config -Now $Now | Where-Object OperationId -EQ $OperationId | Select-Object -First 1
    $context = New-EobOperationContext -Kind 'Offboarding'
    $context.OperationId = $OperationId
    $plan = New-EobPlan -Kind 'OffboardingDeletion' -Context $context -Config $Config
    if ($null -eq $item) {
        Add-EobPlanFinding -Plan $plan -Severity Error -Code 'OFF_DEL_NOT_QUEUED' -Message "Vorgang $OperationId ist nicht in der Warteschlange."
        return $plan
    }
    $plan.Subject = @{ SamAccountName = $item.SamAccountName; DisplayName = $item.DisplayName; ObjectGuid = [string]$item.Entry['ObjectGuid'] }
    if ($item.Status -ne 'AwaitingDeletion') {
        Add-EobPlanFinding -Plan $plan -Severity Error -Code 'OFF_DEL_WRONG_STATUS' -Message "Der Vorgang hat den Status '$($item.Status)'; gelöscht werden können nur Vorgänge im Status 'AwaitingDeletion'."
    }
    $template = Get-EobOffboardingTemplate -Config $Config -Name $item.Template | Select-Object -First 1
    if ($null -eq $item.DeletionDate -or $null -eq $template -or $template.RetentionDays -le 0) {
        Add-EobPlanFinding -Plan $plan -Severity Error -Code 'OFF_DEL_NO_RETENTION' -Message 'Für diesen Vorgang ist keine Aufbewahrungsfrist (RetentionDays > 0) und damit keine Löschung vorgesehen.'
    }
    elseif ($item.DeletionDate -gt $Now) {
        Add-EobPlanFinding -Plan $plan -Severity Error -Code 'OFF_DEL_RETENTION_ACTIVE' -Message "Die Aufbewahrungsfrist läuft noch bis $($item.DeletionDate.ToString('dd.MM.yyyy'))."
    }
    $backups = @($item.Entry['SnapshotPaths'] | Where-Object { $_ -and ([string]$_ -match '_vorher_') -and (Test-Path -LiteralPath ([string]$_) -PathType Leaf) })
    if ($backups.Count -eq 0) {
        Add-EobPlanFinding -Plan $plan -Severity Error -Code 'OFF_DEL_NO_BACKUP' -Message 'Kein Zustandsbericht "vorher" gefunden. Ohne Sicherung ist keine Löschung zulässig.'
    }
    elseif (@($backups | Where-Object { Test-EobSnapshotIntegrity -Entry $item.Entry -Path ([string]$_) }).Count -eq 0) {
        Add-EobPlanFinding -Plan $plan -Severity Error -Code 'OFF_DEL_BACKUP_MODIFIED' -Message 'Der Zustandsbericht "vorher" wurde verändert oder hat keine gespeicherte Prüfsumme (SHA-256). Ohne unveränderte Sicherung ist keine Löschung zulässig.'
    }
    if (-not (Get-EobAdConnectionInfo).Connected) {
        Add-EobPlanFinding -Plan $plan -Severity Error -Code 'OFF_AD_OFFLINE' -Message 'Keine Verbindung zum Active Directory.'
        return $plan
    }
    $guid = [string]$item.Entry['ObjectGuid']
    try {
        $user = Resolve-EobAdUser -Identity $guid
    }
    catch {
        Add-EobPlanFinding -Plan $plan -Severity Error -Code 'OFF_DEL_USER_NOT_FOUND' -Message "Das Konto wurde nicht gefunden (bereits gelöscht?): $($_.Exception.Message)"
        return $plan
    }
    if ($user.ObjectGuid -ine $guid) {
        Add-EobPlanFinding -Plan $plan -Severity Error -Code 'OFF_GUID_MISMATCH' -Message 'Die ObjectGUID stimmt nicht mit dem Vorgang überein.'
    }
    if ($user.Enabled) {
        Add-EobPlanFinding -Plan $plan -Severity Error -Code 'OFF_DEL_ENABLED' -Message 'Das Konto ist aktiviert und kann nicht gelöscht werden.'
    }
    if ($user.ProtectedFromAccidentalDeletion) {
        Add-EobPlanFinding -Plan $plan -Severity Error -Code 'OFF_DEL_PROTECTED' -Message 'Das Konto ist vor versehentlichem Löschen geschützt.'
    }
    $privileged = @(Get-EobAdPrivilegedMembership -DistinguishedName $user.DistinguishedName -PrimaryGroupId $user.PrimaryGroupId)
    $protection = Test-EobProtectedAccount -User $user -Config $Config -CurrentUserSid (Get-EobCurrentIdentity).Sid -PrivilegedGroups $privileged
    foreach ($reason in @($protection.BlockReasons) + @($protection.AcknowledgementReasons)) {
        Add-EobPlanFinding -Plan $plan -Severity Error -Code 'OFF_PROTECTED' -Message "Konto geschützt: $reason"
    }
    if (-not (Test-EobAdRecycleBinEnabled)) {
        Add-EobPlanFinding -Plan $plan -Severity Warning -Code 'OFF_DEL_NO_RECYCLEBIN' -Message 'Der AD-Papierkorb ist nicht aktiviert: Nach der Löschung ist keine Wiederherstellung des Kontos möglich.'
    }
    $exchangeMode = [string](Get-EobConfigValue -Config $Config -Section 'Exchange' -Key 'Mode')
    if ($user.Mail -and $exchangeMode -in @('Online', 'Hybrid')) {
        Add-EobPlanFinding -Plan $plan -Severity Warning -Code 'OFF_DEL_CLOUD_MAILBOX' -Message 'Das Löschen entfernt nach der Synchronisation auch das Cloud-Konto samt Postfach (auch ein freigegebenes Postfach). Postfachdaten vorher sichern.'
    }

    $deletionText = if ($null -ne $item.DeletionDate) { $item.DeletionDate.ToString('dd.MM.yyyy') } else { '' }
    $snapshotDirectory = Get-EobOffboardingDirectory -Config $Config -Kind Snapshot
    $snapshot = Add-EobPlanStep -Plan $plan -Action 'SnapshotBeforeDeletion' -Title 'Letzten Zustand vor der Löschung sichern' -Target $user.SamAccountName -Handler 'Save-EobOffboardingSnapshot' `
        -Phase 'FinalDeletion' -Critical -Parameters @{ Identity = $guid; Label = 'vor-loeschung'; Directory = $snapshotDirectory; OperationId = $OperationId; ExchangeMode = $exchangeMode }
    $null = Add-EobPlanStep -Plan $plan -Action 'DeleteAccount' -Title $script:ActionTitles['DeleteAccount'] -Target $user.SamAccountName -Handler 'Remove-EobAdUserAccount' `
        -Phase 'FinalDeletion' -Risk Destructive -Critical -DependsOn $snapshot.Id -Parameters @{ Identity = $guid; ExpectedObjectGuid = $guid } `
        -Details @("ObjectGUID: $guid", "DN: $($user.DistinguishedName)", "Aufbewahrung bis: $deletionText", "Sicherungen: $($backups -join ', ')")
    $plan.Summary['Konto'] = "$($user.DisplayName) ($($user.SamAccountName))"
    $plan.Summary['ObjectGUID'] = $guid
    $plan.Summary['Austrittsdatum'] = if ($null -ne $item.ExitDate) { $item.ExitDate.ToString('dd.MM.yyyy') } else { '' }
    $plan.Summary['Löschung zulässig ab'] = $deletionText
    $plan.Summary['Bestätigungstext'] = Get-EobDeletionConfirmationText -SamAccountName $user.SamAccountName
    Add-Member -InputObject $plan -NotePropertyName 'QueueEntryPath' -NotePropertyValue $item.Path
    return $plan
}

function Invoke-EobOffboardingFinalDeletion {
    <#
    .SYNOPSIS
        Führt die endgültige Löschung aus - nur mit korrekt eingetipptem Bestätigungstext.
    .DESCRIPTION
        Mit -WhatIf wird die Löschung simuliert (kein Bestätigungstext nötig). Live-Ausführungen
        setzen einen fehlerfreien Löschplan, den Bestätigungstext "LÖSCHEN <SamAccountName>" und
        ein beschreibbares Audit-Log voraus.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Plan,
        [string]$ConfirmationText = ''
    )

    if ($Plan.Kind -ne 'OffboardingDeletion') { throw 'Kein Löschplan.' }
    $sam = [string]$Plan.Subject['SamAccountName']
    if (-not $WhatIfPreference) {
        $expected = Get-EobDeletionConfirmationText -SamAccountName $sam
        if ($ConfirmationText -cne $expected -and $ConfirmationText -cne ($expected -replace 'Ö', 'OE')) {
            Write-EobLog -Level Warning -OperationId $Plan.OperationId -Action 'OffboardingDeletionRefused' -Target $sam -Message 'Löschung abgelehnt: Bestätigungstext stimmt nicht.'
            throw "Löschung abgebrochen: Bitte zur Bestätigung exakt '$expected' eingeben."
        }
    }
    $result = Invoke-EobPlan -Plan $Plan -WhatIf:$WhatIfPreference -Confirm:$false
    if (-not $result.Simulation -and $result.Status -eq 'Succeeded') {
        $entryPath = [string](Get-EobPropertyValue -InputObject $Plan -Name 'QueueEntryPath' -Default '')
        if ($entryPath -and (Test-Path -LiteralPath $entryPath)) {
            $entry = Get-Content -LiteralPath $entryPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
            $entry['Status'] = 'Deleted'
            $entry['UpdatedAt'] = (Get-Date).ToString('o')
            $history = [System.Collections.Generic.List[object]]::new()
            foreach ($historyItem in @($entry['History'])) { $history.Add($historyItem) }
            $history.Add([ordered]@{ Timestamp = (Get-Date).ToString('o'); Actor = (Get-EobCurrentIdentity).Name; Phases = @('FinalDeletion'); Outcome = 'Deleted'; Failed = @() })
            $entry['History'] = $history.ToArray()
            $snapshots = [System.Collections.Generic.List[string]]::new()
            foreach ($path in @($entry['SnapshotPaths'])) { if ($path) { $snapshots.Add([string]$path) } }
            foreach ($key in @($Plan.Runtime.Keys | Where-Object { $_ -like 'Snapshot_*' })) { $snapshots.Add([string]$Plan.Runtime[$key]) }
            $entry['SnapshotPaths'] = $snapshots.ToArray()
            $entry['SnapshotHashes'] = Get-EobSnapshotHashTable -Entry $entry -Runtime $Plan.Runtime
            Write-EobJsonFile -Path $entryPath -InputObject $entry
        }
    }
    return $result
}

#endregion

#region Plan-Handler (Dateien und Dokumentation)

function Save-EobOffboardingSnapshot {
    <#
    .SYNOPSIS
        Speichert einen Zustandsbericht (Attribute, Gruppen, Führungskraft, Unterstellte, Postfach).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Identity,
        [Parameter(Mandatory)][ValidateSet('vorher', 'nachher', 'vor-loeschung')][string]$Label,
        [Parameter(Mandatory)][string]$Directory,
        [string]$OperationId = '',
        [ValidateSet('None', 'Online', 'OnPremises', 'Hybrid')][string]$ExchangeMode = 'None'
    )

    if (-not $PSCmdlet.ShouldProcess($Directory, "Zustandsbericht '$Label' speichern")) {
        return New-EobNotProcessedResult -Message "Zustandsbericht '$Label' würde gespeichert."
    }
    $snapshot = Get-EobAdUserSnapshot -Identity $Identity
    $mailbox = $null
    if ($ExchangeMode -ne 'None' -and $snapshot.User.Mail -and (Test-EobExchangeConnected -Mode $ExchangeMode)) {
        try {
            $mailboxIdentity = if ($snapshot.User.UserPrincipalName) { $snapshot.User.UserPrincipalName } else { $snapshot.User.SamAccountName }
            $mailbox = Get-EobMailboxInfo -Identity $mailboxIdentity -Mode $ExchangeMode
        }
        catch {
            Write-EobLog -Level Warning -OperationId $OperationId -Action 'Snapshot' -Target $Identity -Message "Postfachdaten nicht lesbar: $($_.Exception.Message)"
        }
    }
    $document = [ordered]@{
        SchemaVersion = 1
        Label         = $Label
        OperationId   = $OperationId
        CapturedAt    = $snapshot.CapturedAt
        CapturedBy    = (Get-EobCurrentIdentity).Name
        Tool          = "easyONBOARDING $(Get-EobVersion)"
        Server        = $snapshot.Server
        User          = $snapshot.User
        Groups        = @($snapshot.Groups)
        Manager       = $snapshot.Manager
        DirectReports = @($snapshot.DirectReports)
        Mailbox       = $mailbox
    }
    $sam = Get-EobSafeFileName -Name ([string]$snapshot.User.SamAccountName)
    $shortId = if ($OperationId) { $OperationId.Split('-')[0] } else { 'manuell' }
    $path = Join-Path -Path (Join-Path -Path $Directory -ChildPath $sam) -ChildPath ('{0}_{1}_{2}.json' -f (Get-Date).ToString('yyyyMMdd-HHmmss'), $Label, $shortId)
    Write-EobJsonFile -Path $path -InputObject $document -Depth 8
    # Die Prüfsumme wird in der Warteschlange gespeichert und vor einer Löschung abgeglichen.
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    return New-EobResult -Status Succeeded -Message "Zustandsbericht gespeichert: $path (SHA-256 $hash)" -Data @{ "Snapshot_$Label" = $path; "SnapshotHash_$Label" = $hash }
}

function Export-EobOffboardingMailboxPermission {
    <#
    .SYNOPSIS
        Dokumentiert explizite Postfachberechtigungen als JSON und CSV.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Identity,
        [Parameter(Mandatory)][ValidateSet('Online', 'OnPremises', 'Hybrid')][string]$Mode,
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$SamAccountName,
        [string]$OperationId = ''
    )

    if (-not $PSCmdlet.ShouldProcess($Identity, 'Postfachberechtigungen dokumentieren')) {
        return New-EobNotProcessedResult -Message "Postfachberechtigungen von $Identity würden dokumentiert."
    }
    $permissions = @(Get-EobMailboxPermissionReport -Identity $Identity -Mode $Mode)
    $shortId = if ($OperationId) { $OperationId.Split('-')[0] } else { 'manuell' }
    $base = Join-Path -Path (Join-Path -Path $Directory -ChildPath (Get-EobSafeFileName -Name $SamAccountName)) -ChildPath ('{0}_postfachberechtigungen_{1}' -f (Get-Date).ToString('yyyyMMdd-HHmmss'), $shortId)
    Write-EobJsonFile -Path "$base.json" -InputObject @($permissions) -Depth 4
    if ($permissions.Count -gt 0) {
        $permissions | ConvertTo-EobCsvSafeObject | Export-Csv -LiteralPath "$base.csv" -NoTypeInformation -Delimiter ';' -Encoding utf8BOM
    }
    return New-EobResult -Status Succeeded -Message "$($permissions.Count) explizite Berechtigung(en) dokumentiert: $base.json" -Data @{ MailboxPermissionReport = "$base.json" }
}

function Move-EobHomeDirectoryToArchive {
    <#
    .SYNOPSIS
        Verschiebt ein Home-Verzeichnis in das Archiv (nur innerhalb der freigegebenen Stammpfade).
    .DESCRIPTION
        Es wird nichts gelöscht. Existiert das Verzeichnis nicht, wird der Schritt übersprungen.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ArchiveRoot,
        [Parameter(Mandatory)][string[]]$AllowedRoots,
        [Parameter(Mandatory)][string]$SamAccountName
    )

    if (@($AllowedRoots | Where-Object { Test-EobPathWithin -Path $Path -Root $_ }).Count -eq 0) { throw "Home-Verzeichnis liegt nicht unter einem erlaubten Stammpfad: $Path" }
    if (@($AllowedRoots | Where-Object { Test-EobPathWithin -Path $ArchiveRoot -Root $_ }).Count -eq 0) { throw "Archivziel liegt nicht unter einem erlaubten Stammpfad: $ArchiveRoot" }
    $normalizedPath = $Path.TrimEnd('\', '/')
    if (@($AllowedRoots | Where-Object { $_.TrimEnd('\', '/') -ieq $normalizedPath }).Count -gt 0) { throw "Ein Stammpfad selbst wird nie verschoben: $Path" }
    if (Test-EobPathWithin -Path $Path -Root $ArchiveRoot) { throw "Das Verzeichnis liegt bereits im Archiv: $Path" }

    $target = [System.IO.Path]::Combine($ArchiveRoot, ('{0}_{1}' -f (Get-EobSafeFileName -Name $SamAccountName), (Get-Date).ToString('yyyyMMdd-HHmmss')))
    if (-not $PSCmdlet.ShouldProcess($Path, "Archivieren nach $target")) {
        return New-EobNotProcessedResult -Message "Home-Verzeichnis würde nach $target verschoben."
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return New-EobResult -Status Skipped -Message "Home-Verzeichnis nicht vorhanden: $Path"
    }
    if (-not (Test-Path -LiteralPath $ArchiveRoot -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $ArchiveRoot -Force -ErrorAction Stop
    }
    Move-Item -LiteralPath $Path -Destination $target -ErrorAction Stop
    return New-EobResult -Status Succeeded -Message "Home-Verzeichnis archiviert: $target" -Data @{ ArchivedHomeDirectory = $target }
}

function Assert-EobOffboardingHomePath {
    <#
        Nur der direkte Unterordner <AllowedRoot>/<SamAccountName> ist vertrauenswürdig.
        AD-HomeDirectory ist kein Eigentumsnachweis; Links werden einschließlich aller Vorfahren abgelehnt.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$SamAccountName,
        [Parameter(Mandatory)][string[]]$AllowedRoots
    )

    if (-not (Test-EobSamAccountName -Value $SamAccountName) -or
        (Get-EobSafeFileName -Name $SamAccountName) -cne $SamAccountName) {
        throw "Ungültiger Home-Verzeichnis-Anmeldename: $SamAccountName"
    }
    if ($Path -match '(^|[\\/])\.{1,2}([\\/]|$)' -or $Path -match '[. ]([\\/]|$)') {
        throw "Home-Verzeichnis enthält unsichere Pfadsegmente: $Path"
    }
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    foreach ($root in $AllowedRoots) {
        if ($root -and [IO.Path]::IsPathFullyQualified($root) -and
            [IO.Path]::GetFullPath($Path).TrimEnd('\', '/').Equals([IO.Path]::GetFullPath($root).TrimEnd('\', '/'), $comparison)) {
            throw "Ein Stammpfad selbst wird nie berechtigt: $Path"
        }
    }
    $matched = $false
    foreach ($root in $AllowedRoots) {
        if ([string]::IsNullOrWhiteSpace($root) -or
            $root -match '(^|[\\/])\.{1,2}([\\/]|$)' -or $root -match '[. ]([\\/]|$)') { continue }
        if (-not [IO.Path]::IsPathFullyQualified($root) -or -not [IO.Path]::IsPathFullyQualified($Path)) { continue }
        $expected = [IO.Path]::Combine($root, $SamAccountName)
        if ((Test-EobPathWithin -Path $Path -Root $root) -and
            [IO.Path]::GetFullPath($Path).TrimEnd('\', '/').Equals([IO.Path]::GetFullPath($expected).TrimEnd('\', '/'), $comparison)) {
            $matched = $true
            break
        }
    }
    if (-not $matched) { throw "Home-Verzeichnis muss exakt einem erlaubten Stammpfad/$SamAccountName entsprechen: $Path" }

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSProvider.Name -ne 'FileSystem' -or -not $item.PSIsContainer) { throw "Kein Dateisystem-Verzeichnis: $Path" }
    while ($null -ne $item) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "ReparsePoint im Home-Verzeichnis-Pfad: $($item.FullName)" }
        $volumeRoot = [IO.Path]::GetPathRoot($item.FullName)
        if ($item.FullName.TrimEnd('\', '/').Equals($volumeRoot.TrimEnd('\', '/'), $comparison)) { break }
        $parent = Split-Path -Path $item.FullName -Parent
        if (-not $parent -or $parent -eq $item.FullName) { break }
        $item = Get-Item -LiteralPath $parent -Force -ErrorAction Stop
    }
}

function Grant-EobHomeDirectoryAccess {
    <#
    .SYNOPSIS
        Gewährt einem Konto (z. B. der Führungskraft) Lesezugriff auf ein Home-Verzeichnis.
    .DESCRIPTION
        Nur AllowedRoot/SamAccountName ohne ReparsePoints ist zulässig. AuthorizedAccount muss
        vom aufrufenden Administrator unabhängig vom veränderbaren AD-Managerattribut freigegeben
        werden und dem Empfänger entsprechen. Ohne diese ausdrückliche Freigabe wird abgebrochen.
        Zulässig sind sAMAccountName oder DomainNetBiosName\sAMAccountName; andere Domänen und UPNs
        werden nicht durch Entfernen von Präfixen oder Suffixen akzeptiert.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$SamAccountName,
        [Parameter(Mandatory)][string]$Account,
        [string]$AuthorizedAccount = '',
        [string]$DomainNetBiosName,
        [Parameter(Mandatory)][string[]]$AllowedRoots,
        [ValidateSet('ReadAndExecute', 'Modify')][string]$Rights = 'ReadAndExecute'
    )

    if (-not (Test-EobSamAccountName -Value $Account)) { throw "Ungültiges Konto: $Account" }
    if ($DomainNetBiosName -and $DomainNetBiosName -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,14}$') { throw 'Ungültiger NetBIOS-Domänenname.' }
    $principal = if ($DomainNetBiosName) { "$DomainNetBiosName\$Account" } else { $Account }
    if (-not $AuthorizedAccount -or ($AuthorizedAccount -ine $Account -and $AuthorizedAccount -ine $principal)) { throw "Empfängerkonto ist nicht ausdrücklich freigegeben: $principal" }
    Assert-EobOffboardingHomePath -Path $Path -SamAccountName $SamAccountName -AllowedRoots $AllowedRoots
    if (-not $PSCmdlet.ShouldProcess($Path, "$Rights für $principal gewähren")) {
        return New-EobNotProcessedResult -Message "$principal würde $Rights auf $Path erhalten."
    }
    if (-not $IsWindows) { throw 'NTFS-Berechtigungen können nur unter Windows gesetzt werden.' }
    Assert-EobOffboardingHomePath -Path $Path -SamAccountName $SamAccountName -AllowedRoots $AllowedRoots
    $acl = Get-Acl -LiteralPath $Path
    $rule = [System.Security.AccessControl.FileSystemAccessRule]::new($principal, $Rights, 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $acl.AddAccessRule($rule)
    Assert-EobOffboardingHomePath -Path $Path -SamAccountName $SamAccountName -AllowedRoots $AllowedRoots
    Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
    return New-EobResult -Status Succeeded -Message "$principal hat $Rights auf $Path erhalten."
}

#endregion

#region Massenverarbeitung

function Import-EobOffboardingCsv {
    <#
    .SYNOPSIS
        Liest eine Offboarding-CSV (Spalten z. B. SamAccountName;ExitDate;Ticket;Reason;Template).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowNull()][pscustomobject]$Config
    )

    $findings = [System.Collections.Generic.List[object]]::new()
    $result = [pscustomobject]@{ PSTypeName = 'Eob.CsvImport'; Path = $Path; Delimiter = ''; Encoding = ''; Columns = @(); Rows = @(); Findings = $findings }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $findings.Add((New-EobFinding -Severity Error -Code 'CSV_NOT_FOUND' -Message "Datei nicht gefunden: $Path"))
        return $result
    }
    $content = Get-EobTextFileContent -Path $Path
    $result.Encoding = $content.Encoding
    $lines = @($content.Text -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
    if ($lines.Count -lt 2) {
        $findings.Add((New-EobFinding -Severity Error -Code 'CSV_EMPTY' -Message 'Die Datei enthält keine Datenzeilen.'))
        return $result
    }
    $delimiter = switch (Get-EobConfigValue -Config $Config -Section 'Bulk' -Key 'Delimiter') {
        'Semicolon' { ';' }
        'Comma' { ',' }
        default { if (($lines[0].Split(';').Count) -ge ($lines[0].Split(',').Count)) { ';' } else { ',' } }
    }
    $result.Delimiter = $delimiter
    $maxRows = Get-EobConfigValue -Config $Config -Section 'Bulk' -Key 'MaxRows' -As Int
    if (($lines.Count - 1) -gt $maxRows) {
        $findings.Add((New-EobFinding -Severity Error -Code 'CSV_TOO_MANY_ROWS' -Message "Die Datei enthält $($lines.Count - 1) Zeilen (Maximum: $maxRows)."))
        return $result
    }
    try {
        $records = @($lines | ConvertFrom-Csv -Delimiter $delimiter -ErrorAction Stop)
    }
    catch {
        $findings.Add((New-EobFinding -Severity Error -Code 'CSV_PARSE' -Message "CSV konnte nicht gelesen werden: $($_.Exception.Message)"))
        return $result
    }
    $columns = @($records[0].PSObject.Properties.Name)
    $result.Columns = $columns
    $map = @{}
    foreach ($column in $columns) {
        $normalized = ($column -replace '[\s_\-]', '').ToLowerInvariant()
        if ($script:CsvColumnMap.ContainsKey($normalized)) {
            if (-not $map.ContainsKey($script:CsvColumnMap[$normalized])) { $map[$script:CsvColumnMap[$normalized]] = $column }
        }
        else {
            $findings.Add((New-EobFinding -Severity Warning -Code 'CSV_UNKNOWN_COLUMN' -Field $column -Message "Unbekannte Spalte '$column' wird ignoriert."))
        }
    }
    foreach ($required in @('Identity', 'ExitDate')) {
        if (-not $map.ContainsKey($required)) {
            $findings.Add((New-EobFinding -Severity Error -Code 'CSV_MISSING_COLUMN' -Field $required -Message "Pflichtspalte fehlt: $required (z. B. SamAccountName bzw. ExitDate/Austrittsdatum)."))
        }
    }
    $rows = [System.Collections.Generic.List[object]]::new()
    $number = 1
    foreach ($record in $records) {
        $number++
        $data = @{}
        foreach ($field in $map.Keys) {
            $value = $record.($map[$field])
            $data[$field] = if ($null -eq $value) { '' } else { ([string]$value).Trim() }
        }
        $rows.Add([pscustomobject]@{ RowNumber = $number; Data = $data })
    }
    $result.Rows = $rows.ToArray()
    return $result
}

function New-EobOffboardingBatch {
    <#
    .SYNOPSIS
        Erstellt je CSV-Zeile einen geprüften Offboarding-Plan (Duplikate werden blockiert).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Erzeugt nur ein Objekt im Speicher; keine Systemänderung.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Import,
        [AllowNull()][pscustomobject]$Config,
        [switch]$Simulation,
        [datetime]$Now = (Get-Date)
    )

    $blocking = @($Import.Findings | Where-Object Severity -EQ 'Error').Count -gt 0
    $seen = @{}
    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($row in $Import.Rows) {
        if ($blocking) { break }
        $request = ConvertTo-EobOffboardingRequest -InputObject $row.Data -Config $Config
        $plan = New-EobOffboardingPlan -Request $request -Config $Config -Simulation:$Simulation -Now $Now
        $guid = [string](Get-EobPropertyValue -InputObject $plan.Subject -Name 'ObjectGuid' -Default '')
        if ($guid) {
            if ($seen.ContainsKey($guid)) {
                Add-EobPlanFinding -Plan $plan -Severity Error -Code 'CSV_DUPLICATE_USER' -Field 'Identity' -Message "Das Konto ist bereits in Zeile $($seen[$guid]) enthalten."
            }
            else { $seen[$guid] = $row.RowNumber }
        }
        $errors = @($plan.Findings | Where-Object Severity -EQ 'Error')
        $warnings = @($plan.Findings | Where-Object Severity -EQ 'Warning')
        $items.Add([pscustomobject]@{
                PSTypeName = 'Eob.BatchItem'
                RowNumber  = $row.RowNumber
                Request    = $request
                Plan       = $plan
                State      = if ($errors.Count -gt 0) { 'Error' } elseif ($warnings.Count -gt 0) { 'Warning' } else { 'Ready' }
                Messages   = @($plan.Findings | Where-Object Severity -In @('Error', 'Warning') | ForEach-Object Message)
            })
    }
    $threshold = Get-EobConfigValue -Config $Config -Section 'Bulk' -Key 'ConfirmationThreshold' -As Int
    $executable = @($items | Where-Object State -NE 'Error').Count
    [pscustomobject]@{
        PSTypeName                = 'Eob.OffboardingBatch'
        OperationId               = [guid]::NewGuid().ToString()
        Source                    = $Import.Path
        Items                     = $items.ToArray()
        ImportFindings            = @($Import.Findings)
        IsBlocked                 = $blocking
        ExecutableCount           = $executable
        RequiresTypedConfirmation = ($executable -ge $threshold)
        Simulation                = [bool]$Simulation
    }
}

function Invoke-EobOffboardingBatch {
    <#
    .SYNOPSIS
        Führt einen Offboarding-Stapel aus; fehlerhafte Zeilen werden übersprungen, Fehler einzelner
        Vorgänge brechen den Stapel nicht ab.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Batch,
        [datetime]$Now = (Get-Date)
    )

    if ($Batch.IsBlocked) { throw 'Der Stapel ist wegen Importfehlern gesperrt.' }
    if (-not $WhatIfPreference -and -not $Batch.Simulation -and -not $PSCmdlet.ShouldProcess("$($Batch.ExecutableCount) Konten", 'Massen-Offboarding ausführen')) {
        return $Batch
    }
    Write-EobLog -Level $(if ($WhatIfPreference -or $Batch.Simulation) { 'Information' } else { 'Audit' }) -OperationId $Batch.OperationId -Action 'BulkOffboardingStarted' `
        -Message "$($Batch.ExecutableCount) von $(@($Batch.Items).Count) Zeilen werden verarbeitet."
    foreach ($item in $Batch.Items) {
        if ($item.State -eq 'Error') {
            Add-Member -InputObject $item -NotePropertyName 'Outcome' -NotePropertyValue 'NotExecuted' -Force
            continue
        }
        try {
            $result = Invoke-EobOffboardingPlan -Plan $item.Plan -Now $Now -WhatIf:($WhatIfPreference -or $Batch.Simulation) -Confirm:$false
            Add-Member -InputObject $item -NotePropertyName 'Outcome' -NotePropertyValue ([string]$result.Status) -Force
        }
        catch {
            Add-Member -InputObject $item -NotePropertyName 'Outcome' -NotePropertyValue 'Failed' -Force
            $item.Messages = @($item.Messages) + (Protect-EobSensitiveText -Text $_.Exception.Message)
        }
    }
    Write-EobLog -Level $(if ($WhatIfPreference -or $Batch.Simulation) { 'Information' } else { 'Audit' }) -OperationId $Batch.OperationId -Action 'BulkOffboardingCompleted' `
        -Result ($(if (@($Batch.Items | Where-Object { (Get-EobPropertyValue -InputObject $_ -Name 'Outcome' -Default '') -eq 'Failed' }).Count -gt 0) { 'Failed' } else { 'Succeeded' })) -Message 'Massen-Offboarding abgeschlossen.'
    return $Batch
}

function Export-EobOffboardingBatchResult {
    <#
    .SYNOPSIS
        Exportiert das Ergebnis eines Offboarding-Stapels (CSV oder JSON).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Batch,
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('Csv', 'Json')][string]$Format = 'Csv'
    )

    $rows = foreach ($item in $Batch.Items) {
        [pscustomobject]@{
            Zeile          = $item.RowNumber
            Benutzer       = $item.Request.Identity
            SamAccountName = [string](Get-EobPropertyValue -InputObject $item.Plan.Subject -Name 'SamAccountName' -Default '')
            Vorlage        = $item.Request.Template
            Austrittsdatum = if ($null -ne $item.Request.ExitDate) { $item.Request.ExitDate.ToString('yyyy-MM-dd') } else { '' }
            Ticket         = $item.Request.Ticket
            Pruefung       = $item.State
            Ergebnis       = [string](Get-EobPropertyValue -InputObject $item -Name 'Outcome' -Default 'NotExecuted')
            OperationId    = $item.Plan.OperationId
            Meldungen      = (Protect-EobSensitiveText -Text (@($item.Messages) -join ' | '))
        }
    }
    if (-not $PSCmdlet.ShouldProcess($Path, 'Stapelergebnis exportieren')) { return $Path }
    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) { $null = New-Item -ItemType Directory -Path $directory -Force }
    if ($Format -eq 'Csv') {
        @($rows) | ConvertTo-EobCsvSafeObject | Export-Csv -LiteralPath $Path -NoTypeInformation -Delimiter ';' -Encoding utf8BOM
    }
    else {
        Write-EobJsonFile -Path $Path -InputObject @($rows) -Depth 4
    }
    return $Path
}

#endregion
