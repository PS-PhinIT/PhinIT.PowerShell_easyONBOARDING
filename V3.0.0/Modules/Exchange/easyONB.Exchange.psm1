#Requires -Version 7.2
<#
    easyONB.Exchange
    Optionaler Exchange-Adapter (Exchange Online, Exchange Server, Hybrid): Status, Verbindung,
    Postfach anlegen, Abwesenheitsnotiz, Weiterleitung, Umwandlung in ein freigegebenes Postfach,
    Ausblenden aus Adresslisten und Dokumentation von Postfachberechtigungen.

    Betriebsarten
    - Online: Exchange Online (ExchangeOnlineManagement), interaktiv oder per Zertifikat (App-only).
    - OnPremises: Exchange Server über eine Kerberos-Sitzung (Befehle ohne Präfix importiert).
    - Hybrid: beide Verbindungen. Die lokalen Befehle werden mit dem Präfix 'EobOnPrem' importiert
      (z. B. Enable-EobOnPremRemoteMailbox), damit sie nicht mit Exchange Online kollidieren.
      Postfachaktionen ermitteln vorher, ob das Postfach in Exchange Online oder lokal liegt.

    Implementierungsstand: vorbereitet. Die Funktionen sind mit Mocks getestet, aber nicht gegen
    eine reale Exchange-Umgebung. Der Status meldet das über Implementation = 'Prepared'.
    Es werden keine Module installiert; ExchangeOnlineManagement muss bei Bedarf vom Administrator
    bereitgestellt werden (Install-Module ExchangeOnlineManagement -Scope CurrentUser).
    Für die unbeaufsichtigte Anmeldung (geplante Aufgabe) liegt nur der Fingerabdruck eines
    Zertifikats im Zertifikatspeicher des Kontos in der Konfiguration, kein Secret.
#>

Set-StrictMode -Version 3.0

$script:ExchangeState = @{
    Mode          = 'None'
    Session       = $null
    ImportedName  = ''
    OnlineConnected = $false
    ConnectedAt   = $null
    LastError     = ''
}

# Präfix der lokalen Befehle im Hybridbetrieb (Get-Mailbox -> Get-EobOnPremMailbox).
$script:OnPremisesPrefix = 'EobOnPrem'

# Befehle, die aus einer Exchange-Server-Sitzung importiert werden (Allowlist).
$script:OnPremisesCommands = @(
    'Get-Mailbox', 'Set-Mailbox', 'Enable-Mailbox', 'Enable-RemoteMailbox', 'Set-RemoteMailbox', 'Get-RemoteMailbox',
    'Set-MailboxAutoReplyConfiguration', 'Get-MailboxAutoReplyConfiguration', 'Get-MailboxPermission'
)

$script:NotFoundPattern = "(?i)couldn't be found|could not be found|not found|nicht gefunden|wurde nicht gefunden"

#region Hilfsfunktionen

function New-EobNotProcessedResult {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Erzeugt nur ein Objekt im Speicher; keine Systemänderung.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Message)

    if ($WhatIfPreference) {
        return New-EobResult -Status Succeeded -Message ('Simulation: ' + $Message)
    }
    return New-EobResult -Status Skipped -Message ('Nicht bestätigt: ' + $Message)
}

function Test-EobExchangeOnlineConnected {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if ($null -eq (Get-Command -Name 'Get-ConnectionInformation' -ErrorAction SilentlyContinue)) { return $false }
    try {
        $connections = @(Get-ConnectionInformation -ErrorAction Stop)
        return (@($connections | Where-Object { [string](Get-EobPropertyValue -InputObject $_ -Name 'State' -Default '') -eq 'Connected' }).Count -gt 0)
    }
    catch {
        return $false
    }
}

function Test-EobExchangeOnPremisesConnected {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $session = $script:ExchangeState.Session
    return ($null -ne $session -and [string](Get-EobPropertyValue -InputObject $session -Name 'State' -Default '') -eq 'Opened')
}

function Test-EobExchangeConnected {
    <#
    .SYNOPSIS
        Prüft, ob für den Modus eine nutzbare Exchange-Verbindung besteht.
    .PARAMETER Location
        Hybrid: All (Standard) verlangt beide Verbindungen; Online bzw. OnPremises prüft nur eine.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [ValidateSet('None', 'Online', 'OnPremises', 'Hybrid')][string]$Mode = $script:ExchangeState.Mode,
        [ValidateSet('All', 'Online', 'OnPremises')][string]$Location = 'All'
    )

    switch ($Mode) {
        'Online' { return (Test-EobExchangeOnlineConnected) }
        'OnPremises' { return (Test-EobExchangeOnPremisesConnected) }
        'Hybrid' {
            switch ($Location) {
                'Online' { return (Test-EobExchangeOnlineConnected) }
                'OnPremises' { return (Test-EobExchangeOnPremisesConnected) }
                default { return ((Test-EobExchangeOnPremisesConnected) -and (Test-EobExchangeOnlineConnected)) }
            }
        }
        default { return $false }
    }
}

function Assert-EobExchangeConnected {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Mode,
        [ValidateSet('All', 'Online', 'OnPremises')][string]$Location = 'All'
    )

    if ($Mode -eq 'None') { throw 'Die Exchange-Integration ist deaktiviert ([Exchange] Mode=None).' }
    if (-not (Test-EobExchangeConnected -Mode $Mode -Location $Location)) {
        $part = if ($Mode -eq 'Hybrid' -and $Location -ne 'All') { "$Mode, $Location" } else { $Mode }
        throw "Keine Verbindung zu Exchange ($part). Bitte zuerst unter Tools verbinden."
    }
}

function Get-EobExchangeCommandName {
    <#
    .SYNOPSIS
        Liefert den Befehlsnamen für einen Endpunkt (Hybrid: lokale Befehle mit Präfix).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z]+-[A-Za-z]+$')][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Online', 'OnPremises')][string]$Location,
        [Parameter(Mandatory)][ValidateSet('Online', 'OnPremises', 'Hybrid')][string]$Mode
    )

    if ($Mode -eq 'Hybrid' -and $Location -eq 'OnPremises') {
        $verb, $noun = $Name -split '-', 2
        return "$verb-$($script:OnPremisesPrefix)$noun"
    }
    return $Name
}

function Invoke-EobExchangeCommand {
    <#
        Ruft einen Exchange-Befehl am richtigen Endpunkt auf (fester Befehlsname, Parameter als Hashtable).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Online', 'OnPremises')][string]$Location,
        [Parameter(Mandatory)][ValidateSet('Online', 'OnPremises', 'Hybrid')][string]$Mode,
        [hashtable]$Parameters = @{}
    )

    $command = Get-EobExchangeCommandName -Name $Name -Location $Location -Mode $Mode
    $arguments = @{} + $Parameters
    $arguments['ErrorAction'] = 'Stop'
    return (& $command @arguments)
}

function Find-EobMailbox {
    <#
    .SYNOPSIS
        Sucht ein Postfach; im Hybridbetrieb zuerst in Exchange Online, dann lokal.
    .OUTPUTS
        Objekt mit Location (Online/OnPremises) und Mailbox oder $null.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Identity,
        [Parameter(Mandatory)][ValidateSet('Online', 'OnPremises', 'Hybrid')][string]$Mode
    )

    $locations = switch ($Mode) { 'Hybrid' { @('Online', 'OnPremises') } default { @($Mode) } }
    foreach ($location in $locations) {
        $mailbox = $null
        try {
            $mailbox = Invoke-EobExchangeCommand -Name 'Get-Mailbox' -Location $location -Mode $Mode -Parameters @{ Identity = $Identity }
        }
        catch {
            if ($_.Exception.Message -match $script:NotFoundPattern) { continue }
            throw
        }
        if ($null -ne $mailbox) { return [pscustomobject]@{ Location = $location; Mailbox = @($mailbox)[0] } }
    }
    return $null
}

function Get-EobMailboxLocation {
    <#
        Ermittelt den Endpunkt für Postfachaktionen. Online und OnPremises sind fest; Hybrid sucht.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Identity,
        [Parameter(Mandatory)][ValidateSet('Online', 'OnPremises', 'Hybrid')][string]$Mode
    )

    if ($Mode -ne 'Hybrid') { return $Mode }
    $found = Find-EobMailbox -Identity $Identity -Mode $Mode
    if ($null -eq $found) { throw "Postfach '$Identity' wurde weder in Exchange Online noch lokal gefunden." }
    return $found.Location
}

#endregion

#region Status und Verbindung

function Test-EobExchangeAppOnlyConfigured {
    <#
    .SYNOPSIS
        Prüft, ob die Zertifikatsanmeldung an Exchange Online konfiguriert ist (AppId, Fingerabdruck, Organisation).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][object]$Config)

    $values = foreach ($key in @('AppId', 'CertificateThumbprint', 'Organization')) { [string](Get-EobConfigValue -Config $Config -Section 'Exchange' -Key $key) }
    return (@($values | Where-Object { $_ }).Count -eq 3)
}

function Get-EobExchangeOnlineModuleVersion {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $module = Get-Module -ListAvailable -Name 'ExchangeOnlineManagement' -ErrorAction SilentlyContinue | Sort-Object -Property Version -Descending | Select-Object -First 1
    if ($null -ne $module) { return [string]$module.Version }
    if ($null -ne (Get-Command -Name 'Connect-ExchangeOnline' -ErrorAction SilentlyContinue)) { return '?' }
    return ''
}

function Get-EobExchangeStatus {
    <#
    .SYNOPSIS
        Status der Exchange-Integration für Dashboard und Einstellungen.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowNull()][object]$Config)

    $mode = [string](Get-EobConfigValue -Config $Config -Section 'Exchange' -Key 'Mode')
    if ($mode -eq 'None' -or [string]::IsNullOrEmpty($mode)) {
        return New-EobIntegrationStatus -Name 'Exchange' -State Disabled -Detail 'Exchange-Integration deaktiviert ([Exchange] Mode=None).' -Implementation Prepared
    }
    $auth = if (Test-EobExchangeAppOnlyConfigured -Config $Config) { 'Zertifikat' } else { 'interaktiv' }
    $version = ''
    if ($mode -in @('Online', 'Hybrid')) {
        $version = Get-EobExchangeOnlineModuleVersion
        if (-not $version) {
            return New-EobIntegrationStatus -Name 'Exchange' -State NotInstalled -Detail 'Modul ExchangeOnlineManagement nicht gefunden.' `
                -Hint 'Install-Module ExchangeOnlineManagement -Scope CurrentUser (durch den Administrator, keine automatische Installation).' -Implementation Prepared
        }
        if ($version -eq '?') { $version = '' }
    }
    if ($mode -eq 'Online') {
        if (Test-EobExchangeOnlineConnected) {
            return New-EobIntegrationStatus -Name 'Exchange' -State Connected -Detail "Exchange Online verbunden ($auth)." -Version $version -Implementation Prepared
        }
        return New-EobIntegrationStatus -Name 'Exchange' -State NotConnected -Detail "Exchange Online nicht verbunden (Anmeldung: $auth)." -Version $version `
            -Hint 'Verbindung über Tools > Exchange verbinden herstellen.' -Implementation Prepared
    }
    $uri = [string](Get-EobConfigValue -Config $Config -Section 'Exchange' -Key 'OnPremisesUri')
    if (-not $uri) {
        return New-EobIntegrationStatus -Name 'Exchange' -State NotConfigured -Detail "Modus $mode ohne [Exchange] OnPremisesUri." `
            -Hint 'OnPremisesUri setzen, z. B. http://exchange.example.local/PowerShell/' -Implementation Prepared
    }
    if ($mode -eq 'Hybrid') {
        $local = Test-EobExchangeOnPremisesConnected
        $online = Test-EobExchangeOnlineConnected
        if ($local -and $online) {
            return New-EobIntegrationStatus -Name 'Exchange' -State Connected -Detail "Hybrid verbunden: $uri und Exchange Online ($auth)." -Version $version -Implementation Prepared
        }
        $missing = @(if (-not $local) { "Exchange Server ($uri)" }; if (-not $online) { 'Exchange Online' }) -join ' und '
        return New-EobIntegrationStatus -Name 'Exchange' -State NotConnected -Detail "Hybrid: nicht verbunden mit $missing." -Version $version `
            -Hint 'Tools > Exchange verbinden stellt beide Verbindungen her.' -Implementation Prepared
    }
    if (Test-EobExchangeOnPremisesConnected) {
        return New-EobIntegrationStatus -Name 'Exchange' -State Connected -Detail "Exchange Server verbunden: $uri" -Implementation Prepared
    }
    return New-EobIntegrationStatus -Name 'Exchange' -State NotConnected -Detail "Exchange Server nicht verbunden: $uri" `
        -Hint 'Verbindung über Tools > Exchange verbinden herstellen (Kerberos).' -Implementation Prepared
}

function Connect-EobExchangeOnlineSession {
    <#
        Verbindet Exchange Online: per Zertifikat (App-only), sofern konfiguriert, sonst interaktiv.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][pscustomobject]$Config,
        [string]$UserPrincipalName
    )

    if ($null -eq (Get-Command -Name 'Connect-ExchangeOnline' -ErrorAction SilentlyContinue)) {
        throw 'Das Modul ExchangeOnlineManagement ist nicht installiert.'
    }
    $parameters = @{ ShowBanner = $false; ErrorAction = 'Stop' }
    if (Test-EobExchangeAppOnlyConfigured -Config $Config) {
        $parameters['AppId'] = [string](Get-EobConfigValue -Config $Config -Section 'Exchange' -Key 'AppId')
        $parameters['CertificateThumbprint'] = [string](Get-EobConfigValue -Config $Config -Section 'Exchange' -Key 'CertificateThumbprint')
        $parameters['Organization'] = [string](Get-EobConfigValue -Config $Config -Section 'Exchange' -Key 'Organization')
    }
    elseif ($UserPrincipalName) {
        $parameters['UserPrincipalName'] = $UserPrincipalName
    }
    Connect-ExchangeOnline @parameters
    $script:ExchangeState.OnlineConnected = $true
}

function Connect-EobExchangeOnPremisesSession {
    <#
        Öffnet die Kerberos-Sitzung zum Exchange Server und importiert nur die Befehle der Allowlist.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][pscustomobject]$Config,
        [pscredential]$Credential,
        [AllowEmptyString()][string]$Prefix = ''
    )

    $uri = [string](Get-EobConfigValue -Config $Config -Section 'Exchange' -Key 'OnPremisesUri')
    if (-not $uri) { throw '[Exchange] OnPremisesUri ist nicht gesetzt.' }
    $parsed = $null
    if (-not [uri]::TryCreate($uri, [System.UriKind]::Absolute, [ref]$parsed) -or $parsed.Scheme -notin @('http', 'https')) {
        throw "Ungültige OnPremisesUri '$uri'."
    }
    $sessionParameters = @{
        ConfigurationName = 'Microsoft.Exchange'
        ConnectionUri     = $parsed.AbsoluteUri
        Authentication    = 'Kerberos'
        ErrorAction       = 'Stop'
    }
    if ($null -ne $Credential) { $sessionParameters['Credential'] = $Credential }
    $session = New-PSSession @sessionParameters
    try {
        $importParameters = @{ Session = $session; CommandName = $script:OnPremisesCommands; AllowClobber = $true; DisableNameChecking = $true; ErrorAction = 'Stop' }
        if ($Prefix) { $importParameters['Prefix'] = $Prefix }
        $imported = Import-PSSession @importParameters
        Import-Module -ModuleInfo $imported -Global -DisableNameChecking -ErrorAction Stop
    }
    catch {
        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
        throw
    }
    $script:ExchangeState.Session = $session
    $script:ExchangeState.ImportedName = $imported.Name
}

function Connect-EobExchange {
    <#
    .SYNOPSIS
        Stellt die Exchange-Verbindung gemäß [Exchange] Mode her.
    .DESCRIPTION
        Online: Connect-ExchangeOnline, per Zertifikat ([Exchange] AppId, CertificateThumbprint,
        Organization), sonst interaktiv mit moderner Authentifizierung.
        OnPremises: PSSession mit Kerberos zu OnPremisesUri; importiert werden nur die benötigten
        Befehle (Allowlist). Hybrid: beide Verbindungen, lokale Befehle mit Präfix 'EobOnPrem'.
        Es werden keine Kennwörter gespeichert.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()][pscustomobject]$Config,
        [string]$UserPrincipalName,
        [pscredential]$Credential
    )

    $mode = [string](Get-EobConfigValue -Config $Config -Section 'Exchange' -Key 'Mode')
    if ($mode -eq 'None') { throw 'Die Exchange-Integration ist deaktiviert ([Exchange] Mode=None).' }
    if (-not $PSCmdlet.ShouldProcess($mode, 'Exchange verbinden')) {
        return New-EobNotProcessedResult -Message "Exchange ($mode) würde verbunden."
    }

    try {
        if ($null -ne $script:ExchangeState.Session -or $script:ExchangeState.OnlineConnected) { Disconnect-EobExchange -Confirm:$false | Out-Null }
        switch ($mode) {
            'Online' { Connect-EobExchangeOnlineSession -Config $Config -UserPrincipalName $UserPrincipalName }
            'OnPremises' { Connect-EobExchangeOnPremisesSession -Config $Config -Credential $Credential }
            'Hybrid' {
                # Lokal: Bereitstellung (Remote-Postfach) und lokal verbliebene Postfächer; Online: Cloud-Postfächer.
                Connect-EobExchangeOnPremisesSession -Config $Config -Credential $Credential -Prefix $script:OnPremisesPrefix
                Connect-EobExchangeOnlineSession -Config $Config -UserPrincipalName $UserPrincipalName
            }
            default { throw "Unbekannter Exchange-Modus '$mode'." }
        }
        $script:ExchangeState.Mode = $mode
        $script:ExchangeState.ConnectedAt = Get-Date
        $script:ExchangeState.LastError = ''
        Write-EobLog -Level Information -Action 'ExchangeConnect' -Target $mode -Result 'Succeeded' -Message "Exchange ($mode) verbunden."
        return New-EobResult -Status Succeeded -Message "Exchange ($mode) verbunden."
    }
    catch {
        $script:ExchangeState.LastError = $_.Exception.Message
        Write-EobLog -Level Warning -Action 'ExchangeConnect' -Target $mode -Result 'Failed' -Message 'Exchange-Verbindung fehlgeschlagen.' -ErrorRecord $_
        throw
    }
}

function Disconnect-EobExchange {
    <#
    .SYNOPSIS
        Trennt die Exchange-Verbindung.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param()

    if (-not $PSCmdlet.ShouldProcess($script:ExchangeState.Mode, 'Exchange trennen')) {
        return New-EobNotProcessedResult -Message 'Exchange würde getrennt.'
    }
    if (($script:ExchangeState.OnlineConnected -or $script:ExchangeState.Mode -in @('Online', 'Hybrid')) -and
        $null -ne (Get-Command -Name 'Disconnect-ExchangeOnline' -ErrorAction SilentlyContinue)) {
        Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    }
    if ($script:ExchangeState.ImportedName) {
        Remove-Module -Name $script:ExchangeState.ImportedName -Force -ErrorAction SilentlyContinue
    }
    if ($null -ne $script:ExchangeState.Session) {
        Remove-PSSession -Session $script:ExchangeState.Session -ErrorAction SilentlyContinue
    }
    $script:ExchangeState.Session = $null
    $script:ExchangeState.ImportedName = ''
    $script:ExchangeState.OnlineConnected = $false
    $script:ExchangeState.Mode = 'None'
    $script:ExchangeState.ConnectedAt = $null
    return New-EobResult -Status Succeeded -Message 'Exchange-Verbindung getrennt.'
}

#endregion

#region Lesen

function Get-EobMailboxInfo {
    <#
    .SYNOPSIS
        Liest Postfachdaten für Vorschau und Offboarding-Snapshot (liefert $null ohne Postfach).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Identity,
        [Parameter(Mandatory)][ValidateSet('Online', 'OnPremises', 'Hybrid')][string]$Mode
    )

    Assert-EobExchangeConnected -Mode $Mode
    $found = Find-EobMailbox -Identity $Identity -Mode $Mode
    if ($null -eq $found) { return $null }
    $mailbox = $found.Mailbox
    [pscustomobject]@{
        PSTypeName                    = 'Eob.MailboxInfo'
        Identity                      = $Identity
        Location                      = $found.Location
        PrimarySmtpAddress            = [string](Get-EobPropertyValue -InputObject $mailbox -Name 'PrimarySmtpAddress' -Default '')
        RecipientTypeDetails          = [string](Get-EobPropertyValue -InputObject $mailbox -Name 'RecipientTypeDetails' -Default '')
        HiddenFromAddressListsEnabled = [bool](Get-EobPropertyValue -InputObject $mailbox -Name 'HiddenFromAddressListsEnabled' -Default $false)
        ForwardingSmtpAddress         = [string](Get-EobPropertyValue -InputObject $mailbox -Name 'ForwardingSmtpAddress' -Default '')
        ForwardingAddress             = [string](Get-EobPropertyValue -InputObject $mailbox -Name 'ForwardingAddress' -Default '')
        DeliverToMailboxAndForward    = [bool](Get-EobPropertyValue -InputObject $mailbox -Name 'DeliverToMailboxAndForward' -Default $false)
        LitigationHoldEnabled         = [bool](Get-EobPropertyValue -InputObject $mailbox -Name 'LitigationHoldEnabled' -Default $false)
        ArchiveStatus                 = [string](Get-EobPropertyValue -InputObject $mailbox -Name 'ArchiveStatus' -Default '')
    }
}

function Get-EobMailboxPermissionReport {
    <#
    .SYNOPSIS
        Dokumentiert explizite Postfachberechtigungen (ohne geerbte und SELF-Einträge).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Identity,
        [Parameter(Mandatory)][ValidateSet('Online', 'OnPremises', 'Hybrid')][string]$Mode
    )

    Assert-EobExchangeConnected -Mode $Mode
    $location = Get-EobMailboxLocation -Identity $Identity -Mode $Mode
    foreach ($permission in @(Invoke-EobExchangeCommand -Name 'Get-MailboxPermission' -Location $location -Mode $Mode -Parameters @{ Identity = $Identity })) {
        $user = [string](Get-EobPropertyValue -InputObject $permission -Name 'User' -Default '')
        $inherited = [bool](Get-EobPropertyValue -InputObject $permission -Name 'IsInherited' -Default $false)
        if ($inherited -or $user -match '(?i)^NT AUTHORITY\\SELF$|^S-1-5-10$') { continue }
        [pscustomobject]@{
            Mailbox      = $Identity
            User         = $user
            AccessRights = (@(Get-EobPropertyValue -InputObject $permission -Name 'AccessRights' -Default @()) | ForEach-Object { [string]$_ }) -join ', '
            Deny         = [bool](Get-EobPropertyValue -InputObject $permission -Name 'Deny' -Default $false)
        }
    }
}

#endregion

#region Schreiben (Plan-Handler)

function Enable-EobExchangeMailbox {
    <#
    .SYNOPSIS
        Legt das Postfach an: OnPremises per Enable-Mailbox, Hybrid per Enable-RemoteMailbox.
    .DESCRIPTION
        Bei Exchange Online entsteht das Postfach über die Lizenzzuweisung; dafür ist kein Aufruf nötig.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Identity,
        [Parameter(Mandatory)][ValidateSet('OnPremises', 'Hybrid')][string]$Mode,
        [string]$Database = '',
        [string]$RemoteRoutingDomain = '',
        [string]$Alias = ''
    )

    if ($Mode -eq 'Hybrid') {
        if (-not (Test-EobDomainName -Value $RemoteRoutingDomain)) {
            throw 'Für Hybrid ist [Exchange] RemoteRoutingDomain (z. B. <Mandant>.mail.onmicrosoft.com) erforderlich.'
        }
        $local = if ($Alias) { $Alias } else { $Identity }
        $routing = "$local@$RemoteRoutingDomain"
        if (-not $PSCmdlet.ShouldProcess($Identity, "Remote-Postfach aktivieren ($routing)")) {
            return New-EobNotProcessedResult -Message "Remote-Postfach würde für $Identity aktiviert ($routing)."
        }
        # Die Bereitstellung erfolgt lokal; Exchange Online wird dafür nicht benötigt.
        Assert-EobExchangeConnected -Mode $Mode -Location OnPremises
        $parameters = @{ Identity = $Identity; RemoteRoutingAddress = $routing }
        if ($Alias) { $parameters['Alias'] = $Alias }
        $null = Invoke-EobExchangeCommand -Name 'Enable-RemoteMailbox' -Location OnPremises -Mode $Mode -Parameters $parameters
        return New-EobResult -Status Succeeded -Message "Remote-Postfach für $Identity aktiviert ($routing)."
    }

    if (-not $PSCmdlet.ShouldProcess($Identity, 'Postfach aktivieren')) {
        return New-EobNotProcessedResult -Message "Postfach würde für $Identity aktiviert$(if ($Database) { " (Datenbank $Database)" })."
    }
    Assert-EobExchangeConnected -Mode $Mode
    $parameters = @{ Identity = $Identity }
    if ($Database) { $parameters['Database'] = $Database }
    if ($Alias) { $parameters['Alias'] = $Alias }
    $null = Invoke-EobExchangeCommand -Name 'Enable-Mailbox' -Location OnPremises -Mode $Mode -Parameters $parameters
    return New-EobResult -Status Succeeded -Message "Postfach für $Identity aktiviert."
}

function Set-EobMailboxAutoReply {
    <#
    .SYNOPSIS
        Aktiviert die Abwesenheitsnotiz (optional zeitgesteuert).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Identity,
        [Parameter(Mandatory)][ValidateSet('Online', 'OnPremises', 'Hybrid')][string]$Mode,
        [Parameter(Mandatory)][string]$Message,
        [string]$ExternalMessage,
        [ValidateSet('None', 'Known', 'All')][string]$ExternalAudience = 'All',
        [Nullable[datetime]]$StartTime,
        [Nullable[datetime]]$EndTime
    )

    if (-not $ExternalMessage) { $ExternalMessage = $Message }
    $html = { param($Text) '<html><body><p>' + ((ConvertTo-EobHtmlEncoded -Value $Text) -replace '\r?\n', '<br>') + '</p></body></html>' }
    if (-not $PSCmdlet.ShouldProcess($Identity, 'Abwesenheitsnotiz aktivieren')) {
        return New-EobNotProcessedResult -Message "Abwesenheitsnotiz würde für $Identity aktiviert."
    }
    Assert-EobExchangeConnected -Mode $Mode
    $location = Get-EobMailboxLocation -Identity $Identity -Mode $Mode
    $parameters = @{
        Identity         = $Identity
        InternalMessage  = (& $html $Message)
        ExternalMessage  = (& $html $ExternalMessage)
        ExternalAudience = $ExternalAudience
    }
    if ($null -ne $StartTime -and $null -ne $EndTime) {
        if ($EndTime -le $StartTime) { throw 'Das Ende der Abwesenheitsnotiz muss nach dem Beginn liegen.' }
        $parameters['AutoReplyState'] = 'Scheduled'
        $parameters['StartTime'] = $StartTime
        $parameters['EndTime'] = $EndTime
    }
    else {
        $parameters['AutoReplyState'] = 'Enabled'
    }
    $null = Invoke-EobExchangeCommand -Name 'Set-MailboxAutoReplyConfiguration' -Location $location -Mode $Mode -Parameters $parameters
    return New-EobResult -Status Succeeded -Message "Abwesenheitsnotiz für $Identity aktiviert ($($parameters['AutoReplyState']))."
}

function Set-EobMailboxForwarding {
    <#
    .SYNOPSIS
        Richtet eine Weiterleitung an eine interne Adresse ein (z. B. Führungskraft).
    .DESCRIPTION
        Externe Weiterleitungen werden nur mit -AllowExternal zugelassen, da sie häufig durch
        Richtlinien blockiert sind und ein Datenschutzrisiko darstellen.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Identity,
        [Parameter(Mandatory)][ValidateSet('Online', 'OnPremises', 'Hybrid')][string]$Mode,
        [Parameter(Mandatory)][string]$ForwardTo,
        [string[]]$InternalDomains = @(),
        [switch]$DeliverToMailboxAndForward,
        [switch]$AllowExternal
    )

    if (-not (Test-EobEmailAddress -Value $ForwardTo)) { throw "Ungültige Weiterleitungsadresse '$ForwardTo'." }
    $domain = $ForwardTo.Substring($ForwardTo.IndexOf('@') + 1)
    $isInternal = @($InternalDomains | Where-Object { $_ -and $domain -ieq $_ }).Count -gt 0
    if (-not $isInternal -and -not $AllowExternal) {
        throw "Weiterleitung an '$ForwardTo' ist extern (Domäne $domain) und nicht freigegeben."
    }
    if (-not $PSCmdlet.ShouldProcess($Identity, "Weiterleitung an $ForwardTo einrichten")) {
        return New-EobNotProcessedResult -Message "Weiterleitung von $Identity an $ForwardTo würde eingerichtet."
    }
    Assert-EobExchangeConnected -Mode $Mode
    $location = Get-EobMailboxLocation -Identity $Identity -Mode $Mode
    $null = Invoke-EobExchangeCommand -Name 'Set-Mailbox' -Location $location -Mode $Mode -Parameters @{
        Identity = $Identity; ForwardingSmtpAddress = "smtp:$ForwardTo"; DeliverToMailboxAndForward = [bool]$DeliverToMailboxAndForward
    }
    return New-EobResult -Status Succeeded -Message "Weiterleitung von $Identity an $ForwardTo eingerichtet."
}

function Set-EobMailboxHidden {
    <#
    .SYNOPSIS
        Blendet ein Postfach über Exchange (Set-Mailbox) aus den Adresslisten aus.
    .DESCRIPTION
        Für synchronisierte Benutzer (Online/Hybrid) muss das AD-Attribut msExchHideFromAddressLists
        gesetzt werden; das erledigt der Offboarding-Plan über den AD-Adapter.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Identity,
        [Parameter(Mandatory)][ValidateSet('Online', 'OnPremises', 'Hybrid')][string]$Mode
    )

    if (-not $PSCmdlet.ShouldProcess($Identity, 'Aus Adresslisten ausblenden')) {
        return New-EobNotProcessedResult -Message "$Identity würde aus den Adresslisten ausgeblendet."
    }
    Assert-EobExchangeConnected -Mode $Mode
    $location = Get-EobMailboxLocation -Identity $Identity -Mode $Mode
    $null = Invoke-EobExchangeCommand -Name 'Set-Mailbox' -Location $location -Mode $Mode -Parameters @{ Identity = $Identity; HiddenFromAddressListsEnabled = $true }
    return New-EobResult -Status Succeeded -Message "$Identity aus den Adresslisten ausgeblendet."
}

function ConvertTo-EobSharedMailbox {
    <#
    .SYNOPSIS
        Wandelt ein Benutzerpostfach in ein freigegebenes Postfach um.
    .DESCRIPTION
        Online/OnPremises: Set-Mailbox -Type Shared. Hybrid mit Postfach in Exchange Online (Verfahren
        nach Microsoft): erst in Exchange Online umwandeln, dann das lokale Objekt mit
        Set-RemoteMailbox -Type Shared angleichen (Exchange 2013 CU21 / 2016 CU10 oder neuer).
        Hybrid mit lokal verbliebenem Postfach: Set-Mailbox -Type Shared lokal.
        Hinweis: Freigegebene Postfächer über 50 GB oder mit Archiv benötigen weiterhin eine Lizenz.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Identity,
        [Parameter(Mandatory)][ValidateSet('Online', 'OnPremises', 'Hybrid')][string]$Mode,
        [switch]$VerifyLicenseEligibility
    )

    if (-not $PSCmdlet.ShouldProcess($Identity, 'In freigegebenes Postfach umwandeln')) {
        return New-EobNotProcessedResult -Message "Postfach $Identity würde in ein freigegebenes Postfach umgewandelt."
    }
    Assert-EobExchangeConnected -Mode $Mode
    $location = Get-EobMailboxLocation -Identity $Identity -Mode $Mode
    $null = Invoke-EobExchangeCommand -Name 'Set-Mailbox' -Location $location -Mode $Mode -Parameters @{ Identity = $Identity; Type = 'Shared' }
    if ($Mode -eq 'Hybrid' -and $location -eq 'Online') {
        try {
            $null = Invoke-EobExchangeCommand -Name 'Set-RemoteMailbox' -Location OnPremises -Mode $Mode -Parameters @{ Identity = $Identity; Type = 'Shared' }
        }
        catch {
            throw ("Postfach $Identity in Exchange Online umgewandelt, das lokale Objekt aber nicht angeglichen: " +
                "$($_.Exception.Message) Bitte lokal 'Set-RemoteMailbox -Identity $Identity -Type Shared' ausführen.")
        }
    }
    $verified = Get-EobMailboxInfo -Identity $Identity -Mode $Mode
    if ($null -eq $verified -or $verified.RecipientTypeDetails -ne 'SharedMailbox') {
        throw "Postfachumwandlung für $Identity ist noch nicht als SharedMailbox bestätigt; Lizenz bleibt erforderlich."
    }
    if ($VerifyLicenseEligibility -and
        ([bool](Get-EobPropertyValue -InputObject $verified -Name 'LitigationHoldEnabled' -Default $false) -or
        (Get-EobPropertyValue -InputObject $verified -Name 'ArchiveStatus' -Default '') -eq 'Active')) {
        throw "Postfach $Identity hat Litigation Hold oder ein aktives Archiv; Lizenzentfernung ist gesperrt."
    }
    return New-EobResult -Status Succeeded -Message "Postfach $Identity in ein freigegebenes Postfach umgewandelt. Lizenzbedarf prüfen (Größe/Archiv)."
}

#endregion
