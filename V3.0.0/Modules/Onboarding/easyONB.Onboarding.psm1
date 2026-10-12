#Requires -Version 7.2
<#
    easyONB.Onboarding
    Identitäten (Transliteration, Vorlagen, Kollisionen), Onboarding-Anfragen und -Pläne,
    Benutzer-Update, Kennwort-Reset, Home-Verzeichnisse und CSV-Massenverarbeitung.
#>

Set-StrictMode -Version 3.0

#region Konstanten

# Case-sensitiv (Ordinal): Hashtable-Literale wären case-insensitiv und würden ä/Ä zusammenfassen.
$script:DefaultTransliteration = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
foreach ($pair in @(
        @('ä', 'ae'), @('ö', 'oe'), @('ü', 'ue'), @('Ä', 'Ae'), @('Ö', 'Oe'), @('Ü', 'Ue'), @('ß', 'ss'), @('ẞ', 'SS'),
        @('æ', 'ae'), @('Æ', 'Ae'), @('ø', 'o'), @('Ø', 'O'), @('å', 'aa'), @('Å', 'Aa'), @('œ', 'oe'), @('Œ', 'Oe'),
        @('ł', 'l'), @('Ł', 'L'), @('đ', 'd'), @('Đ', 'D'), @('ð', 'd'), @('Ð', 'D'), @('þ', 'th'), @('Þ', 'Th'), @('ı', 'i')
    )) {
    $script:DefaultTransliteration[$pair[0]] = $pair[1]
}

$script:LegacyTemplateMap = @{
    'FIRSTNAME.LASTNAME'    = '{first}.{last}'
    'F.LASTNAME'            = '{f}.{last}'
    'FIRSTINITIAL.LASTNAME' = '{f}.{last}'
    'FIRSTNAMELASTNAME'     = '{first}{last}'
    'FLASTNAME'             = '{f}{last}'
    'FIRSTINITIALLASTNAME'  = '{f}{last}'
    'LASTNAME.FIRSTNAME'    = '{last}.{first}'
    'LASTNAMEFIRSTNAME'     = '{last}{first}'
    'FIRSTNAME.LASTINITIAL' = '{first}.{l}'
    'FIRSTNAMELASTINITIAL'  = '{first}{l}'
    'FIRSTNAME_LASTNAME'    = '{first}_{last}'
    'LASTNAME_FIRSTNAME'    = '{last}_{first}'
    'FIRSTINITIAL_LASTNAME' = '{f}_{last}'
    'FIRSTNAME_LASTINITIAL' = '{first}_{l}'
}

# Maximallängen gemäß AD-Schema
$script:AttributeLimits = @{
    GivenName = 64; Surname = 64; DisplayName = 256; Title = 128; Department = 64; Company = 64; Office = 128
    OfficePhone = 64; MobilePhone = 64; Description = 1024; EmployeeId = 16; EmployeeNumber = 512; EmployeeType = 256
    Ticket = 128; Notes = 2048
}

# CSV-Spalten (Legacy und neu) → Feldnamen der Anfrage
$script:CsvColumnMap = @{
    'firstname' = 'GivenName'; 'givenname' = 'GivenName'; 'vorname' = 'GivenName'
    'lastname' = 'Surname'; 'surname' = 'Surname'; 'nachname' = 'Surname'
    'displayname' = 'DisplayName'; 'anzeigename' = 'DisplayName'
    'description' = 'Description'; 'beschreibung' = 'Description'
    'officeroom' = 'Office'; 'office' = 'Office'; 'buero' = 'Office'; 'büro' = 'Office'
    'phonenumber' = 'OfficePhone'; 'officephone' = 'OfficePhone'; 'telefon' = 'OfficePhone'
    'mobilenumber' = 'MobilePhone'; 'mobilephone' = 'MobilePhone'; 'mobil' = 'MobilePhone'
    'position' = 'Title'; 'title' = 'Title'; 'jobtitle' = 'Title'
    'departmentfield' = 'Department'; 'department' = 'Department'; 'abteilung' = 'Department'
    'emailaddress' = 'MailLocalPart'; 'email' = 'MailLocalPart'; 'mail' = 'MailLocalPart'
    'maildomain' = 'MailDomain'; 'company' = 'CompanyId'; 'companyid' = 'CompanyId'
    'ablaufdatum' = 'ExpirationDate'; 'expirationdate' = 'ExpirationDate'; 'enddate' = 'ExpirationDate'
    'startdate' = 'StartDate'; 'eintrittsdatum' = 'StartDate'; 'startdatum' = 'StartDate'
    'external' = 'IsExternal'; 'extern' = 'IsExternal'
    'tl' = 'IsTeamLead'; 'teamlead' = 'IsTeamLead'; 'tlgroup' = 'TeamLeadGroupKey'
    'al' = 'IsDepartmentHead'; 'departmenthead' = 'IsDepartmentHead'
    'accountdisabled' = 'AccountDisabled'; 'enabled' = 'Enabled'
    'adgroup' = 'Groups'; 'adgroups' = 'Groups'; 'groups' = 'Groups'; 'gruppen' = 'Groups'
    'license' = 'LicenseKey'; 'lizenz' = 'LicenseKey'
    'ou' = 'TargetOU'; 'targetou' = 'TargetOU'
    'manager' = 'Manager'; 'vorgesetzter' = 'Manager'; 'fuehrungskraft' = 'Manager'
    'employeeid' = 'EmployeeId'; 'personalnummer' = 'EmployeeId'
    'employeenumber' = 'EmployeeNumber'; 'employeetype' = 'EmployeeType'
    'roletemplate' = 'RoleTemplate'; 'rolle' = 'RoleTemplate'
    'samaccountname' = 'SamAccountName'; 'upnprefix' = 'UserPrincipalNamePrefix'
    'ticket' = 'Ticket'; 'notes' = 'Notes'; 'bemerkung' = 'Notes'
}

#endregion

#region Namen und Vorlagen

function Get-EobTransliterationMap {
    <#
    .SYNOPSIS
        Liefert die wirksame Transliterationstabelle (Standard + [NameNormalization]).
    #>
    [CmdletBinding()]
    param([AllowNull()][pscustomobject]$Config)

    $map = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    foreach ($key in $script:DefaultTransliteration.Keys) { $map[$key] = $script:DefaultTransliteration[$key] }

    $configured = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    foreach ($source in @('Transliteration', 'ReplaceSpecialChars')) {
        $raw = [string](Get-EobConfigValue -Config $Config -Section 'NameNormalization' -Key $source)
        foreach ($pair in ($raw -split ';')) {
            if ($pair.Trim() -match '^(.+?)=(.*)$') { $configured[$Matches[1]] = $Matches[2] }
        }
    }
    foreach ($key in @($configured.Keys)) {
        $value = $configured[$key]
        $map[$key] = $value
        # Für einzelne Kleinbuchstaben wird die Großschreibung ergänzt (å=a -> Å=A), sofern nicht explizit konfiguriert.
        $upper = $key.ToUpperInvariant()
        if ($key.Length -eq 1 -and $upper -cne $key -and -not $configured.ContainsKey($upper)) {
            $map[$upper] = if ($value.Length -gt 0) { $value.Substring(0, 1).ToUpperInvariant() + $value.Substring(1) } else { '' }
        }
    }
    return , $map
}

function ConvertTo-EobAsciiName {
    <#
    .SYNOPSIS
        Transliteriert Umlaute und Sonderbuchstaben und entfernt diakritische Zeichen.
    .EXAMPLE
        ConvertTo-EobAsciiName -Text 'Jürgen Łukasz Dvořák'   # Juergen Lukasz Dvorak
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [AllowNull()][pscustomobject]$Config
    )

    if ($Text -eq '') { return '' }
    $result = $Text
    $map = Get-EobTransliterationMap -Config $Config
    foreach ($key in ($map.Keys | Sort-Object -Property Length -Descending)) {
        $result = $result.Replace([string]$key, [string]$map[$key])
    }
    $decomposed = $result.Normalize([System.Text.NormalizationForm]::FormD)
    $builder = [System.Text.StringBuilder]::new()
    foreach ($c in $decomposed.ToCharArray()) {
        if ([System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($c) -ne [System.Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$builder.Append($c)
        }
    }
    return $builder.ToString().Normalize([System.Text.NormalizationForm]::FormC)
}

function ConvertTo-EobIdentifierPart {
    <#
    .SYNOPSIS
        Erzeugt einen Namensbestandteil für Kontonamen (ASCII, ohne Leerzeichen/Apostrophe).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [AllowNull()][pscustomobject]$Config
    )

    $ascii = ConvertTo-EobAsciiName -Text $Text -Config $Config
    $keepHyphen = Get-EobConfigValue -Config $Config -Section 'NameNormalization' -Key 'KeepHyphen' -As Bool
    $pattern = if ($keepHyphen) { '[^A-Za-z0-9\-]' } else { '[^A-Za-z0-9]' }
    $clean = [regex]::Replace($ascii, $pattern, '')
    $clean = [regex]::Replace($clean, '-{2,}', '-').Trim('-')
    return $clean
}

function ConvertFrom-EobLegacyTemplate {
    <#
    .SYNOPSIS
        Übersetzt Legacy-Schlüsselwörter (FIRSTNAME.LASTNAME ...) in Platzhaltervorlagen.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Template)

    $key = $Template.Trim().ToUpperInvariant()
    if ($script:LegacyTemplateMap.ContainsKey($key)) {
        return $script:LegacyTemplateMap[$key]
    }
    return $Template.Trim()
}

function Format-EobIdentityTemplate {
    <#
    .SYNOPSIS
        Wendet eine Vorlage für Kontonamen an ({first}, {last}, {f}, {l}, {first:N}, {last:N}, {firstfull}, {employeeid}).
    .DESCRIPTION
        {first} ist der erste Vorname, {firstfull} alle Vornamen. Alle Werte werden transliteriert
        und von Leerzeichen/Apostrophen befreit. Legacy-Schlüsselwörter werden übersetzt.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Template,
        [Parameter(Mandatory)][string]$GivenName,
        [Parameter(Mandatory)][string]$Surname,
        [string]$EmployeeId = '',
        [AllowNull()][pscustomobject]$Config
    )

    $resolved = ConvertFrom-EobLegacyTemplate -Template $Template
    $firstToken = (($GivenName.Trim() -split '\s+') | Select-Object -First 1)
    $first = ConvertTo-EobIdentifierPart -Text $firstToken -Config $Config
    $firstFull = ConvertTo-EobIdentifierPart -Text $GivenName -Config $Config
    $last = ConvertTo-EobIdentifierPart -Text $Surname -Config $Config
    $employee = ConvertTo-EobIdentifierPart -Text $EmployeeId -Config $Config

    $result = [regex]::Replace($resolved, '\{(?<name>[A-Za-z]+)(?::(?<len>\d+))?\}', {
            param($match)
            $name = $match.Groups['name'].Value.ToLowerInvariant()
            $value = switch ($name) {
                'first' { $first }
                'firstfull' { $firstFull }
                'last' { $last }
                'f' { if ($first.Length -gt 0) { $first.Substring(0, 1) } else { '' } }
                'l' { if ($last.Length -gt 0) { $last.Substring(0, 1) } else { '' } }
                'employeeid' { $employee }
                default { $match.Value }
            }
            if ($match.Groups['len'].Success) {
                $length = [int]$match.Groups['len'].Value
                if ($value.Length -gt $length) { $value = $value.Substring(0, $length) }
            }
            return $value
        })
    $result = $result.Trim('.', '_', '-')
    $result = [regex]::Replace($result, '([._\-])\1+', '$1')
    if (Get-EobConfigValue -Config $Config -Section 'Identity' -Key 'LowerCaseIdentifiers' -As Bool) {
        $result = $result.ToLowerInvariant()
    }
    return $result
}

function Get-EobDisplayNameTemplate {
    <#
    .SYNOPSIS
        Liefert die Anzeigenamen-Vorlagen aus [DisplayNameUPNTemplates] ("Bezeichnung|Vorlage").
    #>
    [CmdletBinding()]
    param([AllowNull()][pscustomobject]$Config)

    $default = [string](Get-EobConfigValue -Config $Config -Section 'DisplayNameUPNTemplates' -Key 'DefaultDisplayNameFormat')
    [pscustomobject]@{ Id = 'Default'; Label = "Standard ($default)"; Template = $default; IsDefault = $true }
    $section = Get-EobConfigSection -Config $Config -Name 'DisplayNameUPNTemplates'
    $keys = @($section.Keys | Where-Object { $_ -match '^DisplayNameTemplate(\d+)$' } | Sort-Object -Property { [int]($_ -replace '\D', '') })
    foreach ($key in $keys) {
        $value = [string]$section[$key]
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        $label = $value
        $template = $value
        $separator = $value.IndexOf('|')
        if ($separator -ge 0) {
            $label = $value.Substring(0, $separator).Trim()
            $template = $value.Substring($separator + 1).Trim()
        }
        if ($template -ieq $default) { continue }
        [pscustomobject]@{ Id = $key; Label = if ($label -ne $template) { "$label ($template)" } else { $template }; Template = $template; IsDefault = $false }
    }
}

function Resolve-EobDisplayNameTemplate {
    <#
    .SYNOPSIS
        Liefert eine Anzeigenamen-Vorlage aus einer Vorlagen-ID (Default, DisplayNameTemplateN) oder einem Vorlagentext.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][AllowEmptyString()][string]$Value,
        [AllowNull()][pscustomobject]$Config
    )

    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -ieq 'Default') {
        return [string](Get-EobConfigValue -Config $Config -Section 'DisplayNameUPNTemplates' -Key 'DefaultDisplayNameFormat')
    }
    if ($Value -match '^DisplayNameTemplate\d+$') {
        $match = Get-EobDisplayNameTemplate -Config $Config | Where-Object { $_.Id -ieq $Value } | Select-Object -First 1
        if ($null -ne $match) { return $match.Template }
        return [string](Get-EobConfigValue -Config $Config -Section 'DisplayNameUPNTemplates' -Key 'DefaultDisplayNameFormat')
    }
    return $Value
}

function Format-EobDisplayName {
    <#
    .SYNOPSIS
        Erzeugt den Anzeigenamen aus einer Vorlage ({first}, {last}, {f}, {l}).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Template,
        [Parameter(Mandatory)][string]$GivenName,
        [Parameter(Mandatory)][string]$Surname
    )

    $given = $GivenName.Trim()
    $sur = $Surname.Trim()
    $result = [regex]::Replace($Template, '\{(?<name>[A-Za-z]+)\}', {
            param($match)
            switch ($match.Groups['name'].Value.ToLowerInvariant()) {
                'first' { $given }
                'firstfull' { $given }
                'last' { $sur }
                'f' { if ($given.Length -gt 0) { $given.Substring(0, 1) } else { '' } }
                'l' { if ($sur.Length -gt 0) { $sur.Substring(0, 1) } else { '' } }
                default { $match.Value }
            }
        })
    return ([regex]::Replace($result, '\s{2,}', ' ')).Trim()
}

function New-EobIdentityProposal {
    <#
    .SYNOPSIS
        Erzeugt einen Vorschlag für SamAccountName, UPN, E-Mail und Anzeigename.
    .PARAMETER Attempt
        0 = Basisname; ab 1 wird eine Zahl angehängt (Kollisionsauflösung).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Erzeugt nur ein Objekt im Speicher; keine Systemänderung.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Request,
        [AllowNull()][pscustomobject]$Config,
        [Parameter(Mandatory)][pscustomobject]$Company,
        [ValidateRange(0, 99)][int]$Attempt = 0
    )

    $samTemplate = [string](Get-EobConfigValue -Config $Config -Section 'Identity' -Key 'SamAccountNameFormat')
    $upnTemplate = [string](Get-EobConfigValue -Config $Config -Section 'DisplayNameUPNTemplates' -Key 'DefaultUserPrincipalNameFormat')
    $mailTemplate = [string](Get-EobConfigValue -Config $Config -Section 'Identity' -Key 'MailFormat')
    if ([string]::IsNullOrWhiteSpace($mailTemplate)) { $mailTemplate = $upnTemplate }
    $maxSam = Get-EobConfigValue -Config $Config -Section 'Identity' -Key 'MaxSamAccountNameLength' -As Int
    $start = Get-EobConfigValue -Config $Config -Section 'Identity' -Key 'CollisionStartNumber' -As Int
    $lower = Get-EobConfigValue -Config $Config -Section 'Identity' -Key 'LowerCaseIdentifiers' -As Bool

    $format = { param($t) Format-EobIdentityTemplate -Template $t -GivenName $Request.GivenName -Surname $Request.Surname -EmployeeId $Request.EmployeeId -Config $Config }
    $sam = if ($Request.SamAccountName) { $Request.SamAccountName } else { & $format $samTemplate }
    $upnPrefix = if ($Request.UserPrincipalNamePrefix) { $Request.UserPrincipalNamePrefix } else { & $format $upnTemplate }
    $mailLocal = if ($Request.MailLocalPart) { $Request.MailLocalPart } else { & $format $mailTemplate }

    $suffix = if ($Attempt -gt 0) { [string]($start + $Attempt - 1) } else { '' }
    if ($suffix) {
        if (-not $Request.SamAccountName) {
            $baseLength = [Math]::Min($sam.Length, $maxSam - $suffix.Length)
            $sam = $sam.Substring(0, [Math]::Max(1, $baseLength)).TrimEnd('.') + $suffix
        }
        if (-not $Request.UserPrincipalNamePrefix) { $upnPrefix = $upnPrefix + $suffix }
        if (-not $Request.MailLocalPart) { $mailLocal = $mailLocal + $suffix }
    }
    if ($sam.Length -gt $maxSam) { $sam = $sam.Substring(0, $maxSam).TrimEnd('.') }
    if ($lower) {
        $sam = $sam.ToLowerInvariant()
        $upnPrefix = $upnPrefix.ToLowerInvariant()
        $mailLocal = $mailLocal.ToLowerInvariant()
    }

    $mailDomain = if ($Request.MailDomain) { $Request.MailDomain.TrimStart('@') } else { $Company.MailDomain }
    $displayTemplate = Resolve-EobDisplayNameTemplate -Value $Request.DisplayNameTemplate -Config $Config
    $displayName = if ($Request.DisplayName) { $Request.DisplayName.Trim() } else { Format-EobDisplayName -Template $displayTemplate -GivenName $Request.GivenName -Surname $Request.Surname }

    [pscustomobject]@{
        PSTypeName        = 'Eob.IdentityProposal'
        Attempt           = $Attempt
        SamAccountName    = $sam
        UserPrincipalName = if ($Company.UpnSuffix) { "$upnPrefix@$($Company.UpnSuffix)" } else { '' }
        Mail              = if ($mailDomain -and $mailLocal) { "$mailLocal@$mailDomain" } else { '' }
        DisplayName       = $displayName
        Name              = $displayName
    }
}

function Resolve-EobIdentity {
    <#
    .SYNOPSIS
        Ermittelt freie Kontonamen (deterministische Nummerierung, keine Zufallswerte).
    .DESCRIPTION
        Prüft SamAccountName, UPN und E-Mail gegen AD (Objekte aller Klassen inkl. proxyAddresses)
        und gegen bereits im Stapel reservierte Namen. Bei Strategie "Fail" oder manuellen Vorgaben
        wird nicht nummeriert, sondern ein Fehler gemeldet.
    .PARAMETER ReservedIdentities
        Im selben Stapel bereits vergebene Werte (Groß-/Kleinschreibung egal).
    .PARAMETER SkipDirectoryCheck
        Keine AD-Prüfung (Offline-Vorschau).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Request,
        [AllowNull()][pscustomobject]$Config,
        [Parameter(Mandatory)][pscustomobject]$Company,
        [System.Collections.Generic.HashSet[string]]$ReservedIdentities,
        [switch]$SkipDirectoryCheck
    )

    $strategy = Get-EobConfigValue -Config $Config -Section 'Identity' -Key 'CollisionStrategy'
    $maxAttempts = Get-EobConfigValue -Config $Config -Section 'Identity' -Key 'MaxCollisionAttempts' -As Int
    $hasOverride = [bool]($Request.SamAccountName -or $Request.UserPrincipalNamePrefix -or $Request.MailLocalPart)
    $findings = [System.Collections.Generic.List[object]]::new()
    $history = [System.Collections.Generic.List[string]]::new()

    for ($attempt = 0; $attempt -le $maxAttempts; $attempt++) {
        $proposal = New-EobIdentityProposal -Request $Request -Config $Config -Company $Company -Attempt $attempt
        $formatErrors = [System.Collections.Generic.List[object]]::new()
        if (-not (Test-EobSamAccountName -Value $proposal.SamAccountName)) {
            $formatErrors.Add((New-EobFinding -Severity Error -Code 'ONB_SAM_INVALID' -Field 'SamAccountName' -Message "Ungültiger SamAccountName '$($proposal.SamAccountName)'."))
        }
        if (-not (Test-EobUserPrincipalName -Value $proposal.UserPrincipalName)) {
            $formatErrors.Add((New-EobFinding -Severity Error -Code 'ONB_UPN_INVALID' -Field 'UserPrincipalNamePrefix' -Message "Ungültiger UPN '$($proposal.UserPrincipalName)'."))
        }
        if ($proposal.Mail -and -not (Test-EobEmailAddress -Value $proposal.Mail)) {
            $formatErrors.Add((New-EobFinding -Severity Error -Code 'ONB_MAIL_INVALID' -Field 'MailLocalPart' -Message "Ungültige E-Mail-Adresse '$($proposal.Mail)'."))
        }
        if ($formatErrors.Count -gt 0) {
            foreach ($finding in $formatErrors) { $findings.Add($finding) }
            return [pscustomobject]@{ Proposal = $proposal; Findings = $findings.ToArray(); History = $history.ToArray(); IsAvailable = $false }
        }

        $conflicts = [System.Collections.Generic.List[string]]::new()
        if ($null -ne $ReservedIdentities) {
            foreach ($value in @($proposal.SamAccountName, $proposal.UserPrincipalName, $proposal.Mail)) {
                if ($value -and $ReservedIdentities.Contains($value.ToLowerInvariant())) { $conflicts.Add("$value (im selben Stapel)") }
            }
        }
        if (-not $SkipDirectoryCheck) {
            foreach ($conflict in @(Get-EobAdIdentityConflict -SamAccountName $proposal.SamAccountName -UserPrincipalName $proposal.UserPrincipalName -Mail $proposal.Mail)) {
                $conflicts.Add("$($conflict.Attribute) '$($conflict.Value)' belegt durch $($conflict.ConflictingObject)")
            }
        }

        if ($conflicts.Count -eq 0) {
            if ($attempt -gt 0) {
                $findings.Add((New-EobFinding -Severity Information -Code 'ONB_NAME_NUMBERED' -Field 'SamAccountName' -Message (
                            "Namenskollision aufgelöst: $($proposal.SamAccountName) / $($proposal.UserPrincipalName). Belegt: " + ($history -join '; '))))
            }
            return [pscustomobject]@{ Proposal = $proposal; Findings = $findings.ToArray(); History = $history.ToArray(); IsAvailable = $true }
        }
        foreach ($conflict in $conflicts) { $history.Add($conflict) }
        if ($strategy -ieq 'Fail' -or $hasOverride) {
            $findings.Add((New-EobFinding -Severity Error -Code 'ONB_NAME_CONFLICT' -Field 'SamAccountName' -Message (
                        'Kontoname bereits vergeben: ' + ($conflicts -join '; ') + '. Bitte einen anderen Namen wählen.')))
            return [pscustomobject]@{ Proposal = $proposal; Findings = $findings.ToArray(); History = $history.ToArray(); IsAvailable = $false }
        }
    }
    $findings.Add((New-EobFinding -Severity Error -Code 'ONB_NAME_EXHAUSTED' -Field 'SamAccountName' -Message "Kein freier Kontoname nach $maxAttempts Versuchen."))
    return [pscustomobject]@{ Proposal = $proposal; Findings = $findings.ToArray(); History = $history.ToArray(); IsAvailable = $false }
}

#endregion

#region Anfrage

function ConvertTo-EobOnboardingRequest {
    <#
    .SYNOPSIS
        Normalisiert Formular- oder CSV-Daten zu einer Onboarding-Anfrage (inkl. Legacy-Feldnamen).
    .PARAMETER InputObject
        Hashtable oder Objekt mit Feldern (z. B. GivenName/FirstName, Surname/LastName, ...).
    .PARAMETER Config
        Konfiguration (liefert Standardwerte).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][object]$InputObject,
        [AllowNull()][pscustomobject]$Config
    )

    $data = @{}
    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) { $data[[string]$key] = $InputObject[$key] }
    }
    else {
        foreach ($property in $InputObject.PSObject.Properties) { $data[$property.Name] = $property.Value }
    }
    $mapped = @{}
    foreach ($key in $data.Keys) {
        $normalizedKey = ($key -replace '[\s_\-]', '').ToLowerInvariant()
        $target = if ($script:CsvColumnMap.ContainsKey($normalizedKey)) { $script:CsvColumnMap[$normalizedKey] } else { $key }
        if (-not $mapped.ContainsKey($target) -or [string]::IsNullOrWhiteSpace([string]$mapped[$target])) {
            $mapped[$target] = $data[$key]
        }
    }

    $text = {
        param([string]$Name)
        $value = $mapped[$Name]
        if ($null -eq $value) { return '' }
        if ($value -is [System.Security.SecureString]) { return '' }
        return ([string]$value).Trim()
    }
    $bool = {
        param([string]$Name, [bool]$Default)
        if (-not $mapped.ContainsKey($Name) -or $null -eq $mapped[$Name] -or ([string]$mapped[$Name]).Trim() -eq '') { return $Default }
        return (ConvertTo-EobBoolean -Value $mapped[$Name] -Default $Default)
    }
    $list = {
        param([string]$Name)
        $value = $mapped[$Name]
        if ($null -eq $value) { return @() }
        if ($value -is [string]) { return @($value -split '[;|]' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }) }
        return @($value | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -ne '' })
    }

    $company = & $text 'CompanyId'
    if (-not $company) {
        $first = Get-EobCompany -Config $Config | Select-Object -First 1
        $company = if ($null -ne $first) { $first.Id } else { 'Company' }
    }
    else {
        $match = Get-EobCompany -Config $Config | Where-Object { $_.Id -ieq $company -or $_.DisplayName -ieq $company } | Select-Object -First 1
        if ($null -ne $match) { $company = $match.Id }
    }

    $defaultDisabled = Get-EobConfigValue -Config $Config -Section 'ADUserDefaults' -Key 'AccountDisabled' -As Bool
    $enabled = -not $defaultDisabled
    if ($mapped.ContainsKey('AccountDisabled') -and ([string]$mapped['AccountDisabled']).Trim() -ne '') {
        $enabled = -not (ConvertTo-EobBoolean -Value $mapped['AccountDisabled'] -Default $defaultDisabled)
    }
    $enabled = & $bool 'Enabled' $enabled

    $mailLocal = & $text 'MailLocalPart'
    $mailDomain = & $text 'MailDomain'
    if ($mailLocal -match '^(?<local>[^@]+)@(?<domain>.+)$') {
        $mailLocal = $Matches['local']
        if (-not $mailDomain) { $mailDomain = $Matches['domain'] }
    }

    $manualPassword = $mapped['ManualPassword']
    $passwordMode = & $text 'PasswordMode'
    if (-not $passwordMode) { $passwordMode = if ($manualPassword -is [System.Security.SecureString]) { 'Manual' } else { 'Generate' } }

    $licenseKey = & $text 'LicenseKey'
    if (-not $mapped.ContainsKey('LicenseKey')) {
        $licenseKey = [string](Get-EobConfigValue -Config $Config -Section 'UserCreationDefaults' -Key 'DefaultLicense')
    }

    $customAttributes = @{}
    foreach ($mappingKey in (Get-EobConfigSection -Config $Config -Name 'CustomAttributeMappings').Keys) {
        $field = [string](Get-EobConfigSection -Config $Config -Name 'CustomAttributeMappings')[$mappingKey]
        $value = & $text $field
        if ($value) { $customAttributes[$field] = $value }
    }

    [pscustomobject]@{
        PSTypeName              = 'Eob.OnboardingRequest'
        CompanyId               = $company
        GivenName               = & $text 'GivenName'
        Surname                 = & $text 'Surname'
        DisplayName             = & $text 'DisplayName'
        DisplayNameTemplate     = & $text 'DisplayNameTemplate'
        SamAccountName          = & $text 'SamAccountName'
        UserPrincipalNamePrefix = & $text 'UserPrincipalNamePrefix'
        MailLocalPart           = $mailLocal
        MailDomain              = $mailDomain.TrimStart('@')
        TargetOU                = & $text 'TargetOU'
        Title                   = & $text 'Title'
        Department              = & $text 'Department'
        Company                 = & $text 'Company'
        Office                  = & $text 'Office'
        OfficePhone             = & $text 'OfficePhone'
        MobilePhone             = & $text 'MobilePhone'
        EmployeeId              = & $text 'EmployeeId'
        EmployeeNumber          = & $text 'EmployeeNumber'
        EmployeeType            = & $text 'EmployeeType'
        Manager                 = & $text 'Manager'
        StartDate               = ConvertTo-EobDate -Value $mapped['StartDate']
        ExpirationDate          = ConvertTo-EobDate -Value $mapped['ExpirationDate']
        StartDateText           = & $text 'StartDate'
        ExpirationDateText      = & $text 'ExpirationDate'
        Description             = & $text 'Description'
        Groups                  = @(& $list 'Groups')
        LicenseKey              = $licenseKey
        RoleTemplate            = & $text 'RoleTemplate'
        ReferenceUser           = & $text 'ReferenceUser'
        IsExternal              = & $bool 'IsExternal' $false
        IsTeamLead              = & $bool 'IsTeamLead' $false
        TeamLeadGroupKey        = & $text 'TeamLeadGroupKey'
        IsDepartmentHead        = & $bool 'IsDepartmentHead' $false
        PasswordMode            = $passwordMode
        ManualPassword          = if ($manualPassword -is [System.Security.SecureString]) { $manualPassword } else { $null }
        ChangePasswordAtLogon   = & $bool 'ChangePasswordAtLogon' (Get-EobConfigValue -Config $Config -Section 'ADUserDefaults' -Key 'MustChangePasswordAtLogon' -As Bool)
        PasswordNeverExpires    = & $bool 'PasswordNeverExpires' (Get-EobConfigValue -Config $Config -Section 'ADUserDefaults' -Key 'PasswordNeverExpires' -As Bool)
        SmartcardLogonRequired  = & $bool 'SmartcardLogonRequired' (Get-EobConfigValue -Config $Config -Section 'ADUserDefaults' -Key 'SmartcardLogonRequired' -As Bool)
        Enabled                 = $enabled
        CreateHomeDirectory     = & $bool 'CreateHomeDirectory' (Get-EobConfigValue -Config $Config -Section 'OnboardingExtensions' -Key 'CreateHomeDirectory' -As Bool)
        SetProxyAddresses       = & $bool 'SetProxyAddresses' $true
        AdditionalProxyAddresses = @(& $list 'AdditionalProxyAddresses')
        SendWelcomeMail         = & $bool 'SendWelcomeMail' (Get-EobConfigValue -Config $Config -Section 'EmailSettings' -Key 'SendWelcomeEmail' -As Bool)
        CreateWelcomeDocument   = $true
        CreateMailbox           = & $bool 'CreateMailbox' (Get-EobConfigValue -Config $Config -Section 'OnboardingExtensions' -Key 'CreateMailbox' -As Bool)
        TriggerSync             = & $bool 'TriggerSync' (Get-EobConfigValue -Config $Config -Section 'ADSync' -Key 'AutoSyncNewUsers' -As Bool)
        Ticket                  = & $text 'Ticket'
        Notes                   = & $text 'Notes'
        CustomAttributes        = $customAttributes
    }
}

function Test-EobOnboardingRequest {
    <#
    .SYNOPSIS
        Validiert eine Onboarding-Anfrage feldbezogen (für Live-Validierung in der GUI).
    .OUTPUTS
        Befunde (Field = Feldname der Anfrage).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Request,
        [AllowNull()][pscustomobject]$Config
    )

    $minFirst = Get-EobConfigValue -Config $Config -Section 'ValidationRules' -Key 'FirstNameMinLength' -As Int
    $maxFirst = Get-EobConfigValue -Config $Config -Section 'ValidationRules' -Key 'FirstNameMaxLength' -As Int
    $minLast = Get-EobConfigValue -Config $Config -Section 'ValidationRules' -Key 'LastNameMinLength' -As Int
    $maxLast = Get-EobConfigValue -Config $Config -Section 'ValidationRules' -Key 'LastNameMaxLength' -As Int
    $phonePattern = [string](Get-EobConfigValue -Config $Config -Section 'ValidationRules' -Key 'PhonePattern')
    $emailPattern = [string](Get-EobConfigValue -Config $Config -Section 'ValidationRules' -Key 'EmailPattern')

    if ([string]::IsNullOrWhiteSpace($Request.GivenName)) {
        New-EobFinding -Severity Error -Code 'ONB_REQUIRED' -Field 'GivenName' -Message 'Vorname ist ein Pflichtfeld.'
    }
    elseif (-not (Test-EobPersonName -Value $Request.GivenName -MinLength $minFirst -MaxLength ([Math]::Min($maxFirst, 64)))) {
        New-EobFinding -Severity Error -Code 'ONB_NAME_FORMAT' -Field 'GivenName' -Message "Vorname: nur Buchstaben, Leerzeichen, Bindestrich, Apostroph ($minFirst-$maxFirst Zeichen)."
    }
    if ([string]::IsNullOrWhiteSpace($Request.Surname)) {
        New-EobFinding -Severity Error -Code 'ONB_REQUIRED' -Field 'Surname' -Message 'Nachname ist ein Pflichtfeld.'
    }
    elseif (-not (Test-EobPersonName -Value $Request.Surname -MinLength $minLast -MaxLength ([Math]::Min($maxLast, 64)))) {
        New-EobFinding -Severity Error -Code 'ONB_NAME_FORMAT' -Field 'Surname' -Message "Nachname: nur Buchstaben, Leerzeichen, Bindestrich, Apostroph ($minLast-$maxLast Zeichen)."
    }

    $company = Get-EobCompany -Config $Config -Id $Request.CompanyId | Select-Object -First 1
    if ($null -eq $company) {
        New-EobFinding -Severity Error -Code 'ONB_COMPANY_UNKNOWN' -Field 'CompanyId' -Message "Unternehmen '$($Request.CompanyId)' ist nicht konfiguriert."
    }
    elseif (-not $company.UpnSuffix) {
        New-EobFinding -Severity Error -Code 'ONB_COMPANY_NO_UPN' -Field 'CompanyId' -Message "Für '$($company.DisplayName)' ist kein UPN-Suffix konfiguriert."
    }

    if ($Request.TargetOU -and -not (Test-EobDistinguishedName -Value $Request.TargetOU)) {
        New-EobFinding -Severity Error -Code 'ONB_OU_FORMAT' -Field 'TargetOU' -Message 'Die Ziel-OU ist kein gültiger Distinguished Name.'
    }
    if (-not $Request.TargetOU -and $null -ne $company -and -not $company.DefaultOU) {
        New-EobFinding -Severity Error -Code 'ONB_OU_MISSING' -Field 'TargetOU' -Message 'Keine Ziel-OU angegeben und keine Standard-OU konfiguriert.'
    }

    if ($Request.MailDomain) {
        $allowed = @(Get-EobMailDomain -Config $Config -CompanyId $Request.CompanyId)
        if (@($allowed | Where-Object { $_ -ieq $Request.MailDomain }).Count -eq 0) {
            New-EobFinding -Severity Error -Code 'ONB_MAILDOMAIN_UNKNOWN' -Field 'MailDomain' -Message "Die E-Mail-Domäne '$($Request.MailDomain)' ist nicht freigegeben ([MailEndungen])."
        }
    }
    if ($Request.MailLocalPart -and $Request.MailLocalPart -notmatch "^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]{1,64}$") {
        New-EobFinding -Severity Error -Code 'ONB_MAIL_FORMAT' -Field 'MailLocalPart' -Message 'Der lokale Teil der E-Mail-Adresse enthält unzulässige Zeichen.'
    }
    if ($Request.MailLocalPart -and $emailPattern -and $Request.MailDomain -and "$($Request.MailLocalPart)@$($Request.MailDomain)" -notmatch $emailPattern) {
        New-EobFinding -Severity Error -Code 'ONB_MAIL_PATTERN' -Field 'MailLocalPart' -Message 'Die E-Mail-Adresse entspricht nicht dem konfigurierten Muster.'
    }
    if ($Request.SamAccountName -and -not (Test-EobSamAccountName -Value $Request.SamAccountName)) {
        New-EobFinding -Severity Error -Code 'ONB_SAM_FORMAT' -Field 'SamAccountName' -Message 'SamAccountName: max. 20 Zeichen, keine Leer- oder Sonderzeichen wie " / \ [ ] : ; | = , + * ? < > @.'
    }

    foreach ($phone in @(@{ Field = 'OfficePhone'; Label = 'Telefon' }, @{ Field = 'MobilePhone'; Label = 'Mobil' })) {
        $value = [string]$Request.($phone.Field)
        if ($value -and -not (Test-EobPhoneNumber -Value $value -Pattern $phonePattern)) {
            New-EobFinding -Severity Error -Code 'ONB_PHONE_FORMAT' -Field $phone.Field -Message "$($phone.Label): ungültiges Format."
        }
    }

    foreach ($field in @('Title', 'Department', 'Company', 'Office', 'OfficePhone', 'MobilePhone', 'Description', 'EmployeeId', 'EmployeeNumber', 'EmployeeType', 'DisplayName', 'Ticket', 'Notes')) {
        $value = [string]$Request.$field
        if (-not $value) { continue }
        $limit = if ($script:AttributeLimits.ContainsKey($field)) { $script:AttributeLimits[$field] } else { 256 }
        if (-not (Test-EobSafeText -Value $value -MaxLength $limit)) {
            New-EobFinding -Severity Error -Code 'ONB_TEXT_INVALID' -Field $field -Message "${field}: maximal $limit Zeichen, keine Steuerzeichen."
        }
    }

    if ($Request.StartDateText -and $null -eq $Request.StartDate) {
        New-EobFinding -Severity Error -Code 'ONB_DATE_FORMAT' -Field 'StartDate' -Message 'Startdatum: Format TT.MM.JJJJ oder JJJJ-MM-TT.'
    }
    if ($Request.ExpirationDateText -and $null -eq $Request.ExpirationDate) {
        New-EobFinding -Severity Error -Code 'ONB_DATE_FORMAT' -Field 'ExpirationDate' -Message 'Ablaufdatum: Format TT.MM.JJJJ oder JJJJ-MM-TT.'
    }
    if ($null -ne $Request.ExpirationDate -and $Request.ExpirationDate.Date -lt (Get-Date).Date) {
        New-EobFinding -Severity Error -Code 'ONB_DATE_PAST' -Field 'ExpirationDate' -Message 'Das Ablaufdatum liegt in der Vergangenheit.'
    }
    if ($null -ne $Request.StartDate -and $null -ne $Request.ExpirationDate -and $Request.StartDate -gt $Request.ExpirationDate) {
        New-EobFinding -Severity Error -Code 'ONB_DATE_ORDER' -Field 'ExpirationDate' -Message 'Das Ablaufdatum liegt vor dem Startdatum.'
    }
    if ($Request.IsExternal -and $null -eq $Request.ExpirationDate) {
        New-EobFinding -Severity Warning -Code 'ONB_EXTERNAL_NO_EXPIRY' -Field 'ExpirationDate' -Message 'Externe Konten sollten ein Ablaufdatum erhalten.'
    }

    if ($Request.PasswordMode -eq 'Manual') {
        if (-not (Get-EobConfigValue -Config $Config -Section 'Security' -Key 'AllowManualPassword' -As Bool)) {
            New-EobFinding -Severity Error -Code 'ONB_MANUAL_PASSWORD_DISABLED' -Field 'ManualPassword' -Message 'Manuelle Kennwörter sind in der Konfiguration deaktiviert.'
        }
        elseif ($null -eq $Request.ManualPassword -or $Request.ManualPassword.Length -eq 0) {
            New-EobFinding -Severity Error -Code 'ONB_PASSWORD_MISSING' -Field 'ManualPassword' -Message 'Bitte ein Kennwort eingeben oder die Generierung wählen.'
        }
    }
    elseif ($Request.PasswordMode -ne 'Generate') {
        New-EobFinding -Severity Error -Code 'ONB_PASSWORD_MODE' -Field 'PasswordMode' -Message "Unbekannter Kennwortmodus '$($Request.PasswordMode)'."
    }

    $licenses = Get-EobConfigSection -Config $Config -Name 'LicensesGroups'
    if ($Request.LicenseKey -and -not $licenses.Contains($Request.LicenseKey)) {
        New-EobFinding -Severity Error -Code 'ONB_LICENSE_UNKNOWN' -Field 'LicenseKey' -Message "Lizenz '$($Request.LicenseKey)' ist nicht in [LicensesGroups] definiert."
    }
    if ($Request.RoleTemplate -and -not (Get-EobConfigSection -Config $Config -Name "RoleTemplate.$($Request.RoleTemplate)").Count) {
        New-EobFinding -Severity Error -Code 'ONB_ROLE_UNKNOWN' -Field 'RoleTemplate' -Message "Rollenvorlage '$($Request.RoleTemplate)' existiert nicht."
    }
    if ($Request.IsTeamLead) {
        $tlGroups = Get-EobConfigSection -Config $Config -Name 'TLGroups'
        if (-not $Request.TeamLeadGroupKey) {
            New-EobFinding -Severity Error -Code 'ONB_TL_GROUP_MISSING' -Field 'TeamLeadGroupKey' -Message 'Bitte eine Teamleitergruppe auswählen.'
        }
        elseif (-not $tlGroups.Contains($Request.TeamLeadGroupKey) -and @($tlGroups.Values | Where-Object { $_ -ieq $Request.TeamLeadGroupKey }).Count -eq 0) {
            New-EobFinding -Severity Error -Code 'ONB_TL_GROUP_UNKNOWN' -Field 'TeamLeadGroupKey' -Message "Teamleitergruppe '$($Request.TeamLeadGroupKey)' ist nicht konfiguriert."
        }
    }
    foreach ($group in $Request.Groups) {
        if ((Test-EobPrivilegedGroup -Group (Resolve-EobConfiguredGroupName -Name $group -Config $Config) -Config $Config).IsProtected) {
            New-EobFinding -Severity Error -Code 'ONB_GROUP_PROTECTED' -Field 'Groups' -Message "Die Gruppe '$group' ist privilegiert und kann nicht zugewiesen werden."
        }
    }
}

function Resolve-EobConfiguredGroupName {
    <#
    .SYNOPSIS
        Übersetzt eine Gruppenbezeichnung aus [ADGroups] in den AD-Gruppennamen.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][pscustomobject]$Config
    )

    $section = Get-EobConfigSection -Config $Config -Name 'ADGroups'
    if ($section.Contains($Name) -and -not [string]::IsNullOrWhiteSpace([string]$section[$Name])) {
        return ([string]$section[$Name]).Trim()
    }
    if ($Name -match '^ADGroup\d+$' -and $section.Contains($Name)) {
        return ([string]$section[$Name]).Trim()
    }
    return $Name.Trim()
}

#endregion

#region Plan

function Get-EobOnboardingGroupSet {
    <#
    .SYNOPSIS
        Stellt alle Gruppen eines Onboardings mit Herkunft zusammen (dedupliziert).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Request,
        [AllowNull()][pscustomobject]$Config,
        [hashtable]$Role,
        [string[]]$ReferenceGroups = @()
    )

    $result = [ordered]@{}
    $add = {
        param([string]$Group, [string]$Source)
        $name = $Group.Trim()
        if ($name -eq '') { return }
        $key = $name.ToLowerInvariant()
        if ($result.Contains($key)) {
            $result[$key].Sources += $Source
        }
        else {
            $result[$key] = [pscustomobject]@{ Name = $name; Sources = @($Source) }
        }
    }

    foreach ($group in @(Get-EobConfigValue -Config $Config -Section 'UserCreationDefaults' -Key 'InitialGroupMembership' -As List)) {
        & $add $group 'Standardgruppe'
    }
    if (-not $Request.IsExternal) {
        foreach ($group in $Request.Groups) { & $add (Resolve-EobConfiguredGroupName -Name $group -Config $Config) 'Auswahl' }
    }
    if ($null -ne $Role) {
        foreach ($group in @($Role.Groups)) { & $add $group "Rolle $($Role.Name)" }
    }
    foreach ($group in $ReferenceGroups) { & $add $group 'Referenzbenutzer' }

    if ($Request.LicenseKey) {
        $licenseGroup = [string](Get-EobConfigSection -Config $Config -Name 'LicensesGroups')[$Request.LicenseKey]
        if ($licenseGroup) { & $add $licenseGroup "Lizenz $($Request.LicenseKey)" }
    }
    if ($Request.IsTeamLead -and $Request.TeamLeadGroupKey) {
        $tl = Get-EobConfigSection -Config $Config -Name 'TLGroups'
        $tlGroup = if ($tl.Contains($Request.TeamLeadGroupKey)) { [string]$tl[$Request.TeamLeadGroupKey] } else { $Request.TeamLeadGroupKey }
        & $add $tlGroup 'Teamleitung'
    }
    if ($Request.IsDepartmentHead) {
        $alGroup = [string](Get-EobConfigValue -Config $Config -Section 'ALGroup' -Key 'Group')
        if ($alGroup) { & $add $alGroup 'Abteilungsleitung' }
    }
    if (Get-EobConfigValue -Config $Config -Section 'ActivateUserMS365ADSync' -Key 'ADSync' -As Bool) {
        $syncGroup = [string](Get-EobConfigValue -Config $Config -Section 'ActivateUserMS365ADSync' -Key 'ADSyncADGroup')
        if ($syncGroup) { & $add $syncGroup 'M365-Synchronisation' }
    }
    return @($result.Values)
}

function Get-EobRoleTemplate {
    <#
    .SYNOPSIS
        Liefert Rollenvorlagen ([RoleTemplate.<Name>]).
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][pscustomobject]$Config,
        [string]$Name
    )

    foreach ($sectionName in @(Get-EobConfigSectionName -Config $Config -Pattern '^RoleTemplate\.')) {
        $roleName = $sectionName.Substring('RoleTemplate.'.Length)
        if ($Name -and $roleName -ine $Name) { continue }
        $section = $Config.Sections[$sectionName]
        [pscustomobject]@{
            Name        = $roleName
            DisplayName = [string]$section['DisplayName']
            Description = [string]$section['Description']
            Groups      = @(Get-EobConfigValue -Config $Config -Section $sectionName -Key 'Groups' -As List)
            License     = [string]$section['License']
            TargetOU    = [string]$section['TargetOU']
            Title       = [string]$section['Title']
            Department  = [string]$section['Department']
        }
    }
}

function New-EobOnboardingPlan {
    <#
    .SYNOPSIS
        Erstellt einen Onboarding-Plan (Vorschau) inklusive aller Prüfungen.
    .DESCRIPTION
        Führt nur lesende AD-Abfragen aus: Namenskollisionen, Ziel-OU, Führungskraft,
        Referenzbenutzer, Gruppenschutz (inkl. Verschachtelung). Bestehende Konten werden nie
        überschrieben. Generierte Kennwörter liegen ausschließlich als SecureString im Plan.
    .PARAMETER Request
        Anfrage (ConvertTo-EobOnboardingRequest).
    .PARAMETER Config
        Konfiguration.
    .PARAMETER Simulation
        Plan als Simulation kennzeichnen.
    .PARAMETER SkipDirectoryCheck
        Ohne AD-Prüfungen planen (Offline-Vorschau; Ausführung ist dann gesperrt).
    .PARAMETER ReservedIdentities
        Bereits im Stapel vergebene Namen (Massenverarbeitung).
    .PARAMETER DomainPasswordPolicy
        Domänenrichtlinie (Get-EobAdPasswordPolicy).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Erzeugt nur ein Objekt im Speicher; keine Systemänderung.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Request,
        [AllowNull()][pscustomobject]$Config,
        [switch]$Simulation,
        [switch]$SkipDirectoryCheck,
        [System.Collections.Generic.HashSet[string]]$ReservedIdentities,
        [AllowNull()][pscustomobject]$DomainPasswordPolicy
    )

    $context = New-EobOperationContext -Kind 'Onboarding' -Simulation:$Simulation
    $plan = New-EobPlan -Kind 'Onboarding' -Context $context -Config $Config -Simulation:$Simulation
    foreach ($finding in @(Test-EobOnboardingRequest -Request $Request -Config $Config)) {
        $plan.Findings.Add($finding)
    }
    $company = Get-EobCompany -Config $Config -Id $Request.CompanyId | Select-Object -First 1
    if ($null -eq $company -or @($plan.Findings | Where-Object { $_.Severity -eq 'Error' -and $_.Field -in @('GivenName', 'Surname', 'CompanyId') }).Count -gt 0) {
        return $plan
    }
    if ($SkipDirectoryCheck) {
        Add-EobPlanFinding -Plan $plan -Severity Warning -Code 'ONB_OFFLINE' -Message 'Offline-Vorschau ohne AD-Prüfung: Kollisionen, OU, Führungskraft und Gruppen wurden nicht geprüft. Ausführung nur als Simulation.'
        $plan.Simulation = $true
    }

    $role = $null
    if ($Request.RoleTemplate) {
        $roleObject = Get-EobRoleTemplate -Config $Config -Name $Request.RoleTemplate | Select-Object -First 1
        if ($null -ne $roleObject) {
            $role = @{ Name = $roleObject.Name; Groups = $roleObject.Groups }
            if (-not $Request.Title -and $roleObject.Title) { $Request.Title = $roleObject.Title }
            if (-not $Request.Department -and $roleObject.Department) { $Request.Department = $roleObject.Department }
            if (-not $Request.TargetOU -and $roleObject.TargetOU) { $Request.TargetOU = $roleObject.TargetOU }
            if (-not $Request.LicenseKey -and $roleObject.License) { $Request.LicenseKey = $roleObject.License }
        }
    }

    # Identität
    $identity = Resolve-EobIdentity -Request $Request -Config $Config -Company $company -ReservedIdentities $ReservedIdentities -SkipDirectoryCheck:$SkipDirectoryCheck
    foreach ($finding in $identity.Findings) { $plan.Findings.Add($finding) }
    $proposal = $identity.Proposal
    $targetOu = if ($Request.TargetOU) { $Request.TargetOU } else { $company.DefaultOU }

    if (-not $SkipDirectoryCheck) {
        if ($targetOu -and -not (Test-EobAdOrganizationalUnit -DistinguishedName $targetOu)) {
            Add-EobPlanFinding -Plan $plan -Severity Error -Code 'ONB_OU_NOT_FOUND' -Field 'TargetOU' -Message "Die Ziel-OU existiert nicht: $targetOu"
        }
        elseif ($targetOu -and $identity.IsAvailable -and (Test-EobAdNameInContainer -Name $proposal.Name -Path $targetOu)) {
            $proposal.Name = "$($proposal.DisplayName) ($($proposal.SamAccountName))"
            Add-EobPlanFinding -Plan $plan -Severity Information -Code 'ONB_CN_ADJUSTED' -Field 'DisplayName' -Message "Objektname in der OU belegt; verwendet wird '$($proposal.Name)'."
        }
    }

    # Führungskraft und Referenzbenutzer
    $managerDn = ''
    $managerInfo = ''
    if ($Request.Manager -and -not $SkipDirectoryCheck) {
        try {
            $manager = Resolve-EobAdUserReference -Identity $Request.Manager
            $managerDn = $manager.DistinguishedName
            $managerInfo = "$($manager.DisplayName) ($($manager.SamAccountName))"
        }
        catch {
            Add-EobPlanFinding -Plan $plan -Severity Error -Code 'ONB_MANAGER_UNRESOLVED' -Field 'Manager' -Message "Führungskraft: $($_.Exception.Message)"
        }
    }
    $referenceGroups = @()
    if ($Request.ReferenceUser -and -not $SkipDirectoryCheck) {
        try {
            $reference = Resolve-EobAdUserReference -Identity $Request.ReferenceUser
            $referenceGroups = @(Get-EobAdUserGroupMembership -User $reference | Where-Object { -not $_.IsPrimary } | ForEach-Object { if ($_.SamAccountName) { $_.SamAccountName } else { $_.Name } })
        }
        catch {
            Add-EobPlanFinding -Plan $plan -Severity Error -Code 'ONB_REFERENCE_UNRESOLVED' -Field 'ReferenceUser' -Message "Referenzbenutzer: $($_.Exception.Message)"
        }
    }

    # Gruppen mit Schutzprüfung
    $groups = [System.Collections.Generic.List[object]]::new()
    foreach ($group in (Get-EobOnboardingGroupSet -Request $Request -Config $Config -Role $role -ReferenceGroups $referenceGroups)) {
        $sources = $group.Sources -join ', '
        try {
            $protection = if ($SkipDirectoryCheck) { Test-EobPrivilegedGroup -Group $group.Name -Config $Config } else { Get-EobAdGroupProtection -Identity $group.Name }
        }
        catch {
            Add-EobPlanFinding -Plan $plan -Severity Warning -Code 'ONB_GROUP_NOT_FOUND' -Field 'Groups' -Message "Gruppe '$($group.Name)' ($sources) wurde nicht gefunden und wird übersprungen."
            continue
        }
        if ($protection.IsProtected) {
            Add-EobPlanFinding -Plan $plan -Severity Error -Code 'ONB_GROUP_PROTECTED' -Field 'Groups' -Message ("Gruppe '$($group.Name)' ($sources) ist privilegiert und darf nicht automatisch zugewiesen werden: " + ($protection.Reasons -join ' '))
            continue
        }
        $groups.Add($group)
    }
    if ($Request.IsExternal -and @($Request.Groups).Count -gt 0) {
        Add-EobPlanFinding -Plan $plan -Severity Information -Code 'ONB_EXTERNAL_GROUPS' -Field 'Groups' -Message 'Externe Benutzer erhalten die ausgewählten Gruppen nicht (Legacy-Verhalten); Standard-, Lizenz- und Rollengruppen gelten weiterhin.'
    }

    # Kennwort
    $policy = Get-EobPasswordPolicy -Config $Config -DomainPolicy $DomainPasswordPolicy
    if ($Request.PasswordMode -eq 'Manual' -and $null -ne $Request.ManualPassword) {
        $check = Test-EobPasswordPolicy -Password $Request.ManualPassword -Policy $policy -SamAccountName $proposal.SamAccountName -DisplayName @($Request.GivenName, $Request.Surname)
        foreach ($violation in $check.Violations) {
            Add-EobPlanFinding -Plan $plan -Severity Error -Code 'ONB_PASSWORD_POLICY' -Field 'ManualPassword' -Message $violation
        }
        $plan.Secrets['InitialPassword'] = $Request.ManualPassword
        $plan.Secrets['PasswordGenerated'] = $false
    }
    else {
        $plan.Secrets['InitialPassword'] = New-EobPassword -Policy $policy
        $plan.Secrets['PasswordGenerated'] = $true
    }
    Add-EobRedactionValue -Value $plan.Secrets['InitialPassword']

    # Attribute
    $attributes = @{
        Title                  = $Request.Title
        Department             = $Request.Department
        Company                = if ($Request.Company) { $Request.Company } else { $company.DisplayName }
        Office                 = $Request.Office
        OfficePhone            = $Request.OfficePhone
        MobilePhone            = $Request.MobilePhone
        EmployeeID             = $Request.EmployeeId
        EmployeeNumber         = $Request.EmployeeNumber
        Description            = $Request.Description
        StreetAddress          = $company.Street
        City                   = $company.City
        PostalCode             = $company.PostalCode
        PasswordNeverExpires   = [bool]$Request.PasswordNeverExpires
        SmartcardLogonRequired = [bool]$Request.SmartcardLogonRequired
    }
    if ($company.Country -match '^[A-Za-z]{2}$') {
        $attributes['Country'] = $company.Country.ToUpperInvariant()
    }
    elseif ($company.Country) {
        Add-EobPlanFinding -Plan $plan -Severity Warning -Code 'ONB_COUNTRY_FORMAT' -Message "CompanyCountry '$($company.Country)' ist kein ISO-Ländercode (z. B. DE) und wird nicht gesetzt."
    }
    if ($null -ne $Request.ExpirationDate) {
        $attributes['AccountExpirationDate'] = $Request.ExpirationDate.Date.AddDays(1)
    }
    $homeDirectoryTemplate = [string](Get-EobConfigValue -Config $Config -Section 'ADUserDefaults' -Key 'HomeDirectory')
    if ($Request.CreateHomeDirectory) {
        $homeDirectoryTemplate = [string](Get-EobConfigValue -Config $Config -Section 'OnboardingExtensions' -Key 'HomeDirectoryPath')
    }
    $homeDirectory = $homeDirectoryTemplate -replace '(?i)%username%', $proposal.SamAccountName
    if ($homeDirectory) {
        $attributes['HomeDirectory'] = $homeDirectory
        $letter = ([string](Get-EobConfigValue -Config $Config -Section 'ADUserDefaults' -Key 'HomeLWLetter')).TrimEnd(':')
        if ($letter -match '^[D-Zd-z]$') { $attributes['HomeDrive'] = $letter.ToUpperInvariant() + ':' }
    }
    $profilePath = ([string](Get-EobConfigValue -Config $Config -Section 'ADUserDefaults' -Key 'ProfilePath')) -replace '(?i)%username%', $proposal.SamAccountName
    if ($profilePath) { $attributes['ProfilePath'] = $profilePath }
    $logonScript = [string](Get-EobConfigValue -Config $Config -Section 'ADUserDefaults' -Key 'LogonScript')
    if ($logonScript) { $attributes['ScriptPath'] = $logonScript }
    if ($company.Website) { $attributes['HomePage'] = $company.Website }

    $otherAttributes = @{}
    if ($proposal.Mail) {
        $otherAttributes['mail'] = $proposal.Mail
        if ($Request.SetProxyAddresses) {
            $proxies = [System.Collections.Generic.List[string]]::new()
            $proxies.Add("SMTP:$($proposal.Mail)")
            if ($company.MS365Domain) {
                $local = $proposal.Mail.Substring(0, $proposal.Mail.IndexOf('@'))
                $proxies.Add("smtp:$local@$($company.MS365Domain)")
            }
            foreach ($additional in $Request.AdditionalProxyAddresses) {
                $address = ($additional -replace '^(?i)smtp:', '').Trim()
                if (Test-EobEmailAddress -Value $address) { $proxies.Add("smtp:$address") }
                else { Add-EobPlanFinding -Plan $plan -Severity Warning -Code 'ONB_PROXY_INVALID' -Field 'AdditionalProxyAddresses' -Message "Ungültige Zusatzadresse '$additional' wird ignoriert." }
            }
            $otherAttributes['proxyAddresses'] = [string[]]@($proxies | Select-Object -Unique)
        }
    }
    else {
        Add-EobPlanFinding -Plan $plan -Severity Warning -Code 'ONB_NO_MAIL' -Field 'MailDomain' -Message 'Es wird keine E-Mail-Adresse gesetzt (keine Mail-Domäne konfiguriert).'
    }
    if ($Request.EmployeeType) { $otherAttributes['employeeType'] = $Request.EmployeeType }
    $mappings = Get-EobConfigSection -Config $Config -Name 'CustomAttributeMappings'
    foreach ($attributeName in $mappings.Keys) {
        $field = [string]$mappings[$attributeName]
        if ($Request.CustomAttributes.ContainsKey($field)) {
            $otherAttributes[$attributeName] = $Request.CustomAttributes[$field]
        }
    }

    # Schritte
    $sam = $proposal.SamAccountName
    $create = Add-EobPlanStep -Plan $plan -Action 'CreateUser' -Title 'Benutzerkonto anlegen' -Target $sam -Handler 'New-EobAdUserAccount' -Risk Medium -Critical -Parameters @{
        SamAccountName        = $sam
        UserPrincipalName     = $proposal.UserPrincipalName
        Name                  = $proposal.Name
        DisplayName           = $proposal.DisplayName
        GivenName             = $Request.GivenName
        Surname               = $Request.Surname
        Path                  = $targetOu
        AccountPassword       = '@Secret:InitialPassword'
        Enabled               = [bool]$Request.Enabled
        ChangePasswordAtLogon = [bool]$Request.ChangePasswordAtLogon
        Attributes            = $attributes
        OtherAttributes       = $otherAttributes
    } -Details @(
        "SamAccountName: $sam", "UPN: $($proposal.UserPrincipalName)", "E-Mail: $($proposal.Mail)", "Anzeigename: $($proposal.DisplayName)",
        "Ziel-OU: $targetOu", "Konto: $(if ($Request.Enabled) { 'aktiviert' } else { 'deaktiviert' })",
        "Kennwortänderung bei Anmeldung: $(if ($Request.ChangePasswordAtLogon) { 'ja' } else { 'nein' })"
    )

    if ($managerDn) {
        $null = Add-EobPlanStep -Plan $plan -Action 'SetManager' -Title "Führungskraft setzen: $managerInfo" -Target $sam -Handler 'Set-EobAdUserManager' -DependsOn $create.Id -Parameters @{
            Identity = $sam; ManagerDistinguishedName = $managerDn; SkipTargetCheck = $true
        }
    }
    foreach ($group in $groups) {
        $null = Add-EobPlanStep -Plan $plan -Action 'AddGroup' -Title "Gruppe hinzufügen: $($group.Name)" -Target $sam -Handler 'Add-EobAdGroupMembership' -DependsOn $create.Id -Parameters @{
            Identity = $sam; Group = $group.Name
        } -Details @("Herkunft: $($group.Sources -join ', ')")
    }

    if ($Request.CreateHomeDirectory -and $homeDirectory) {
        $allowedRoots = @(Get-EobConfigValue -Config $Config -Section 'FileServer' -Key 'AllowedRoots' -As List)
        if (@($allowedRoots | Where-Object { Test-EobPathWithin -Path $homeDirectory -Root $_ }).Count -eq 0) {
            Add-EobPlanFinding -Plan $plan -Severity Warning -Code 'ONB_HOME_NOT_ALLOWED' -Message "Home-Verzeichnis '$homeDirectory' liegt nicht unter [FileServer] AllowedRoots und wird nicht angelegt."
        }
        else {
            $netbios = ''
            if (-not $SkipDirectoryCheck) {
                $connection = Get-EobAdConnectionInfo
                if ($null -ne $connection.Domain) { $netbios = $connection.Domain.NetBiosName }
            }
            $null = Add-EobPlanStep -Plan $plan -Action 'CreateHomeDirectory' -Title "Home-Verzeichnis anlegen: $homeDirectory" -Target $sam -Handler 'New-EobHomeDirectory' -DependsOn $create.Id -Parameters @{
                Path = $homeDirectory; SamAccountName = $sam; DomainNetBiosName = $netbios; AllowedRoots = $allowedRoots
            }
        }
    }

    if (Get-EobConfigValue -Config $Config -Section 'OnboardingExtensions' -Key 'SetUserPhoto' -As Bool) {
        $photoDir = Get-EobConfigValue -Config $Config -Section 'OnboardingExtensions' -Key 'DefaultPhotoPath' -As Path
        $photo = if ($photoDir) { [System.IO.Path]::Combine($photoDir, "$sam.jpg") } else { '' }
        if ($photo -and (Test-Path -LiteralPath $photo -PathType Leaf)) {
            $null = Add-EobPlanStep -Plan $plan -Action 'SetPhoto' -Title 'Profilbild setzen' -Target $sam -Handler 'Set-EobUserPhoto' -DependsOn $create.Id -Parameters @{ Identity = $sam; Path = $photo }
        }
        else {
            Add-EobPlanFinding -Plan $plan -Severity Information -Code 'ONB_PHOTO_MISSING' -Message "Kein Profilbild gefunden ($sam.jpg)."
        }
    }

    $exchangeMode = Get-EobConfigValue -Config $Config -Section 'Exchange' -Key 'Mode'
    if ($Request.CreateMailbox) {
        if ($exchangeMode -in @('OnPremises', 'Hybrid')) {
            $null = Add-EobPlanStep -Plan $plan -Action 'CreateMailbox' -Title "Postfach anlegen ($exchangeMode)" -Target $sam -Handler 'Enable-EobExchangeMailbox' -DependsOn $create.Id -Risk Medium -Parameters @{
                Identity = $sam; Mode = $exchangeMode; Database = [string](Get-EobConfigValue -Config $Config -Section 'OnboardingExtensions' -Key 'MailboxDatabase')
                RemoteRoutingDomain = [string](Get-EobConfigValue -Config $Config -Section 'Exchange' -Key 'RemoteRoutingDomain')
            }
        }
        else {
            Add-EobPlanFinding -Plan $plan -Severity Information -Code 'ONB_MAILBOX_LICENSE' -Message 'Exchange Online: Das Postfach entsteht über die Lizenzzuweisung (Gruppe) nach der Synchronisation.'
        }
    }

    $templatePath = Get-EobConfigValue -Config $Config -Section 'Report' -Key 'TemplatePathHTML' -As Path
    if (-not $templatePath -or -not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
        Add-EobPlanFinding -Plan $plan -Severity Error -Code 'ONB_HANDOUT_TEMPLATE_MISSING' -Field 'Report.TemplatePathHTML' -Message 'Die Vorlage für das verpflichtende Onboarding-Handout fehlt. Bitte vor der Ausführung eine gültige HTML-Vorlage konfigurieren.'
    }
    else {
        $null = Add-EobPlanStep -Plan $plan -Action 'WelcomeDocument' -Title 'Onboarding-Handout erzeugen (ohne Kennwort)' -Target $sam -Handler 'New-EobWelcomeDocument' -DependsOn $create.Id -Parameters @{
            SamAccountName = $sam; TemplatePath = $templatePath; OperationId = $plan.OperationId; Config = '@Config'
            Values = @{
                Vorname = $Request.GivenName; Nachname = $Request.Surname; DisplayName = $proposal.DisplayName; LoginName = $sam
                UPN = $proposal.UserPrincipalName; MailAddress = $proposal.Mail; Position = $Request.Title; Abteilung = $Request.Department
                Buero = $Request.Office; Rufnummer = $Request.OfficePhone; Mobil = $Request.MobilePhone; Description = $Request.Description
                Ablaufdatum = if ($null -ne $Request.ExpirationDate) { $Request.ExpirationDate.ToString('dd.MM.yyyy') } else { '' }
                License = $Request.LicenseKey; CompanyId = $company.Id
            }
        }
    }
    if ($Request.SendWelcomeMail -and $proposal.Mail) {
        $null = Add-EobPlanStep -Plan $plan -Action 'WelcomeMail' -Title "Welcome-Mail senden (ohne Kennwort) an $($proposal.Mail)" -Target $sam -Handler 'Send-EobWelcomeMail' -DependsOn $create.Id -Parameters @{
            To = $proposal.Mail; DisplayName = $proposal.DisplayName; SamAccountName = $sam; UserPrincipalName = $proposal.UserPrincipalName
            StartDate = $Request.StartDate; CompanyId = $company.Id; Config = '@Config'
        }
    }
    if ($Request.TriggerSync -and (Get-EobConfigValue -Config $Config -Section 'ADSync' -Key 'EnableADSync' -As Bool)) {
        $server = [string](Get-EobConfigValue -Config $Config -Section 'ADSync' -Key 'ADSyncServer')
        if ($server) {
            $null = Add-EobPlanStep -Plan $plan -Action 'EntraSync' -Title "Entra Connect Sync auslösen ($server)" -Target $server -Handler 'Start-EobEntraConnectSync' -DependsOn $create.Id -Parameters @{
                Server = $server; PolicyType = [string](Get-EobConfigValue -Config $Config -Section 'ADSync' -Key 'PolicyType')
            }
        }
    }

    $plan.Subject = @{
        SamAccountName    = $sam
        UserPrincipalName = $proposal.UserPrincipalName
        DisplayName       = $proposal.DisplayName
        Mail              = $proposal.Mail
        TargetOU          = $targetOu
        Company           = $company.DisplayName
    }
    $plan.Summary['Unternehmen'] = $company.DisplayName
    $plan.Summary['Anzeigename'] = $proposal.DisplayName
    $plan.Summary['SamAccountName'] = $sam
    $plan.Summary['UPN'] = $proposal.UserPrincipalName
    $plan.Summary['E-Mail'] = $proposal.Mail
    $plan.Summary['Ziel-OU'] = $targetOu
    $plan.Summary['Führungskraft'] = $managerInfo
    $plan.Summary['Gruppen'] = ($groups | ForEach-Object Name) -join ', '
    $plan.Summary['Lizenz'] = $Request.LicenseKey
    $plan.Summary['Konto'] = if ($Request.Enabled) { 'aktiviert' } else { 'deaktiviert (Aktivierung bei Übergabe)' }
    $plan.Summary['Kennwort'] = if ($plan.Secrets['PasswordGenerated']) { "generiert ($($policy.Length) Zeichen), einmalige Anzeige nach Ausführung" } else { 'manuell vorgegeben' }
    $plan.Summary['Ablaufdatum'] = if ($null -ne $Request.ExpirationDate) { $Request.ExpirationDate.ToString('dd.MM.yyyy') } else { '' }
    $plan.Summary['Ticket'] = $Request.Ticket
    $plan.Summary['Bemerkung'] = $Request.Notes
    return $plan
}

function Invoke-EobOnboardingPlan {
    <#
    .SYNOPSIS
        Führt einen Onboarding-Plan aus (oder simuliert ihn mit -WhatIf).
    .DESCRIPTION
        Live-Ausführungen werden einmalig bestätigt (ConfirmImpact High); die Oberfläche bestätigt
        selbst und ruft mit -Confirm:$false auf.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][pscustomobject]$Plan)

    if ($Plan.Kind -ne 'Onboarding') { throw 'Kein Onboarding-Plan.' }
    if (@($Plan.Findings | Where-Object Code -EQ 'ONB_OFFLINE').Count -gt 0) { $Plan.Simulation = $true }
    if ($WhatIfPreference) { $Plan.Simulation = $true }
    if (-not $Plan.Simulation -and (Test-EobPlanExecutable -Plan $Plan)) {
        $target = [string](Get-EobPropertyValue -InputObject $Plan.Subject -Name 'SamAccountName' -Default $Plan.OperationId)
        if (-not $PSCmdlet.ShouldProcess($target, "Onboarding ausführen ($($Plan.Steps.Count) Schritte)")) {
            $Plan.Status = 'Cancelled'
            return $Plan
        }
    }
    return Invoke-EobPlan -Plan $Plan -WhatIf:$Plan.Simulation -Confirm:$false
}

function Get-EobPlanCredential {
    <#
    .SYNOPSIS
        Liefert das Initialkennwort eines erfolgreich ausgeführten Plans (für die einmalige Anzeige).
    .OUTPUTS
        SecureString oder $null.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Plan)

    # Das Kennwort wird angezeigt, sobald das Konto angelegt bzw. das Kennwort gesetzt wurde - auch wenn
    # spätere Schritte (z. B. Gruppen) fehlschlagen; sonst wäre das Konto ohne bekanntes Kennwort.
    if ($Plan.Simulation -or $Plan.Kind -notin @('Onboarding', 'PasswordReset')) { return $null }
    $create = $Plan.Steps | Where-Object { $_.Action -in @('CreateUser', 'ResetPassword') -and $_.Status -eq 'Succeeded' } | Select-Object -First 1
    if ($null -eq $create) { return $null }
    $secretName = if ($Plan.Secrets.ContainsKey('InitialPassword')) { 'InitialPassword' } else { 'NewPassword' }
    return $Plan.Secrets[$secretName]
}

function Clear-EobPlanSecret {
    <#
    .SYNOPSIS
        Entfernt Kennwörter aus einem Plan und aus der Laufzeit-Redaktionsliste.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][pscustomobject]$Plan)

    if (-not $PSCmdlet.ShouldProcess($Plan.OperationId, 'Kennwörter aus dem Speicher entfernen')) { return }
    foreach ($key in @($Plan.Secrets.Keys)) {
        $value = $Plan.Secrets[$key]
        if ($value -is [System.Security.SecureString]) {
            Remove-EobRedactionValue -Value $value -Confirm:$false
            $value.Dispose()
        }
        $Plan.Secrets.Remove($key)
    }
}

#endregion

#region Benutzer aktualisieren und Kennwort-Reset

$script:UpdateFieldMap = [ordered]@{
    DisplayName    = @{ Attribute = 'displayName'; Label = 'Anzeigename' }
    GivenName      = @{ Attribute = 'givenName'; Label = 'Vorname' }
    Surname        = @{ Attribute = 'sn'; Label = 'Nachname' }
    Title          = @{ Attribute = 'title'; Label = 'Position' }
    Department     = @{ Attribute = 'department'; Label = 'Abteilung' }
    Company        = @{ Attribute = 'company'; Label = 'Unternehmen' }
    Office         = @{ Attribute = 'physicalDeliveryOfficeName'; Label = 'Büro' }
    OfficePhone    = @{ Attribute = 'telephoneNumber'; Label = 'Telefon' }
    MobilePhone    = @{ Attribute = 'mobile'; Label = 'Mobil' }
    Description    = @{ Attribute = 'description'; Label = 'Beschreibung' }
    EmployeeId     = @{ Attribute = 'employeeID'; Label = 'Personalnummer' }
    EmployeeNumber = @{ Attribute = 'employeeNumber'; Label = 'Mitarbeiternummer' }
}

function Test-EobTargetAccount {
    <#
        Prüft das Zielkonto und ergänzt Befunde im Plan. Liefert die Liste privilegierter Gruppen.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Plan,
        [Parameter(Mandatory)][pscustomobject]$User,
        [AllowNull()][pscustomobject]$Config,
        [switch]$AllowPrivileged
    )

    $privileged = @(Get-EobAdPrivilegedMembership -DistinguishedName $User.DistinguishedName -PrimaryGroupId $User.PrimaryGroupId)
    $current = Get-EobCurrentIdentity
    $protection = Test-EobProtectedAccount -User $User -Config $Config -CurrentUserSid $current.Sid -PrivilegedGroups $privileged
    foreach ($reason in $protection.BlockReasons) {
        Add-EobPlanFinding -Plan $Plan -Severity Error -Code 'ACC_PROTECTED' -Field 'Identity' -Message $reason
    }
    foreach ($reason in $protection.AcknowledgementReasons) {
        $severity = if ($AllowPrivileged) { 'Warning' } else { 'Error' }
        Add-EobPlanFinding -Plan $Plan -Severity $severity -Code 'ACC_PRIVILEGED' -Field 'Identity' -Message "$reason Gesonderte Bestätigung erforderlich."
    }
    return , $privileged
}

function New-EobUserUpdatePlan {
    <#
    .SYNOPSIS
        Plant Attribut-, Führungskraft- und Gruppenänderungen an einem bestehenden Benutzer.
    .DESCRIPTION
        Es werden nur tatsächlich geänderte Werte geschrieben (Vorher/Nachher in der Vorschau).
        Ein Kennwort wird dabei nie verändert (siehe New-EobPasswordResetPlan).
    .PARAMETER Identity
        Zielbenutzer (SamAccountName, UPN, DN, GUID).
    .PARAMETER Changes
        Hashtable mit Feldern (DisplayName, GivenName, Surname, Title, Department, Company, Office,
        OfficePhone, MobilePhone, Description, EmployeeId, EmployeeNumber, Manager). Leerer Wert = löschen.
    .PARAMETER AddGroups
        Hinzuzufügende Gruppen.
    .PARAMETER RemoveGroups
        Zu entfernende Gruppen.
    .PARAMETER EnableAccount
        Deaktiviertes Konto aktivieren (z. B. bei der Übergabe eines deaktiviert angelegten Kontos).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Erzeugt nur ein Objekt im Speicher; keine Systemänderung.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Identity,
        [hashtable]$Changes = @{},
        [string[]]$AddGroups = @(),
        [string[]]$RemoveGroups = @(),
        [AllowNull()][pscustomobject]$Config,
        [switch]$EnableAccount,
        [switch]$AllowPrivileged,
        [switch]$Simulation
    )

    $context = New-EobOperationContext -Kind 'UserUpdate' -Simulation:$Simulation
    $plan = New-EobPlan -Kind 'UserUpdate' -Context $context -Config $Config -Simulation:$Simulation
    try {
        $user = Get-EobAdUser -Identity $Identity
    }
    catch {
        Add-EobPlanFinding -Plan $plan -Severity Error -Code 'UPD_USER_NOT_FOUND' -Field 'Identity' -Message $_.Exception.Message
        return $plan
    }
    $plan.Subject = @{ SamAccountName = $user.SamAccountName; UserPrincipalName = $user.UserPrincipalName; DisplayName = $user.DisplayName; DistinguishedName = $user.DistinguishedName; ObjectGuid = $user.ObjectGuid }
    $null = Test-EobTargetAccount -Plan $plan -User $user -Config $Config -AllowPrivileged:$AllowPrivileged
    $target = if ($user.ObjectGuid) { $user.ObjectGuid } else { $user.SamAccountName }

    $replace = @{}
    $clear = [System.Collections.Generic.List[string]]::new()
    $details = [System.Collections.Generic.List[string]]::new()
    foreach ($field in $script:UpdateFieldMap.Keys) {
        if (-not $Changes.ContainsKey($field)) { continue }
        $new = ([string]$Changes[$field]).Trim()
        $old = [string]$user.$field
        if ($new -ceq $old) { continue }
        $limit = if ($script:AttributeLimits.ContainsKey($field)) { $script:AttributeLimits[$field] } else { 256 }
        if (-not (Test-EobSafeText -Value $new -MaxLength $limit)) {
            Add-EobPlanFinding -Plan $plan -Severity Error -Code 'UPD_TEXT_INVALID' -Field $field -Message "$($script:UpdateFieldMap[$field].Label): maximal $limit Zeichen, keine Steuerzeichen."
            continue
        }
        if ($field -in @('GivenName', 'Surname') -and $new -and -not (Test-EobPersonName -Value $new)) {
            Add-EobPlanFinding -Plan $plan -Severity Error -Code 'UPD_NAME_FORMAT' -Field $field -Message "$($script:UpdateFieldMap[$field].Label): ungültiges Format."
            continue
        }
        if ($field -in @('OfficePhone', 'MobilePhone') -and $new -and -not (Test-EobPhoneNumber -Value $new)) {
            Add-EobPlanFinding -Plan $plan -Severity Error -Code 'UPD_PHONE_FORMAT' -Field $field -Message "$($script:UpdateFieldMap[$field].Label): ungültiges Format."
            continue
        }
        $attribute = $script:UpdateFieldMap[$field].Attribute
        if ($new -eq '') { $clear.Add($attribute) } else { $replace[$attribute] = $new }
        $details.Add(("{0}: '{1}' → '{2}'" -f $script:UpdateFieldMap[$field].Label, $old, $new))
    }
    if ($replace.Count -gt 0 -or $clear.Count -gt 0) {
        $null = Add-EobPlanStep -Plan $plan -Action 'SetAttributes' -Title 'Attribute aktualisieren' -Target $user.SamAccountName -Handler 'Set-EobAdUserAttribute' -Risk Medium -Parameters @{
            Identity = $target; Replace = $replace; Clear = $clear.ToArray(); AllowPrivileged = [bool]$AllowPrivileged
        } -Details $details.ToArray()
    }

    if ($Changes.ContainsKey('Manager')) {
        $managerText = ([string]$Changes['Manager']).Trim()
        if (-not $managerText -and $user.Manager) {
            $null = Add-EobPlanStep -Plan $plan -Action 'ClearManager' -Title 'Führungskraft entfernen' -Target $user.SamAccountName -Handler 'Set-EobAdUserManager' -Parameters @{ Identity = $target; AllowPrivileged = [bool]$AllowPrivileged } -Details @("Bisher: $($user.Manager)")
        }
        elseif ($managerText) {
            try {
                $manager = Resolve-EobAdUserReference -Identity $managerText
                if ($manager.DistinguishedName -ine $user.Manager) {
                    $null = Add-EobPlanStep -Plan $plan -Action 'SetManager' -Title "Führungskraft setzen: $($manager.DisplayName)" -Target $user.SamAccountName -Handler 'Set-EobAdUserManager' -Parameters @{
                        Identity = $target; ManagerDistinguishedName = $manager.DistinguishedName; AllowPrivileged = [bool]$AllowPrivileged
                    } -Details @("Bisher: $($user.Manager)", "Neu: $($manager.DistinguishedName)")
                }
            }
            catch {
                Add-EobPlanFinding -Plan $plan -Severity Error -Code 'UPD_MANAGER_UNRESOLVED' -Field 'Manager' -Message "Führungskraft: $($_.Exception.Message)"
            }
        }
    }

    if ($EnableAccount) {
        if ($user.Enabled) {
            Add-EobPlanFinding -Plan $plan -Severity Information -Code 'UPD_ALREADY_ENABLED' -Field 'EnableAccount' -Message 'Das Konto ist bereits aktiviert.'
        }
        else {
            # Konten in der OU für ausgeschiedene Benutzer nur bewusst reaktivieren.
            $disabledOu = [string](Get-EobConfigValue -Config $Config -Section 'Offboarding' -Key 'DisabledUsersOU')
            if ($disabledOu -and ([string]$user.DistinguishedName).EndsWith(",$disabledOu", [System.StringComparison]::OrdinalIgnoreCase)) {
                Add-EobPlanFinding -Plan $plan -Severity Warning -Code 'UPD_ENABLE_OFFBOARDED' -Field 'EnableAccount' -Message "Das Konto liegt in der OU für ausgeschiedene Benutzer ($disabledOu). Bitte prüfen, ob ein Offboarding-Vorgang läuft."
            }
            $null = Add-EobPlanStep -Plan $plan -Action 'EnableAccount' -Title 'Konto aktivieren' -Target $user.SamAccountName -Handler 'Enable-EobAdUserAccount' -Risk Medium -Parameters @{
                Identity = $target; AllowPrivileged = [bool]$AllowPrivileged
            } -Details @('Bisher: deaktiviert')
        }
    }

    foreach ($group in $AddGroups) {
        $name = Resolve-EobConfiguredGroupName -Name $group -Config $Config
        try {
            $protection = Get-EobAdGroupProtection -Identity $name
        }
        catch {
            Add-EobPlanFinding -Plan $plan -Severity Error -Code 'UPD_GROUP_NOT_FOUND' -Field 'AddGroups' -Message "Gruppe '$name' wurde nicht gefunden."
            continue
        }
        if ($protection.IsProtected) {
            Add-EobPlanFinding -Plan $plan -Severity Error -Code 'UPD_GROUP_PROTECTED' -Field 'AddGroups' -Message ("Gruppe '$name' ist privilegiert: " + ($protection.Reasons -join ' '))
            continue
        }
        if (@($user.MemberOf | Where-Object { $_ -ieq $protection.GroupObject.DistinguishedName }).Count -gt 0) {
            Add-EobPlanFinding -Plan $plan -Severity Information -Code 'UPD_ALREADY_MEMBER' -Field 'AddGroups' -Message "Bereits Mitglied in '$name'."
            continue
        }
        $null = Add-EobPlanStep -Plan $plan -Action 'AddGroup' -Title "Gruppe hinzufügen: $name" -Target $user.SamAccountName -Handler 'Add-EobAdGroupMembership' -Parameters @{ Identity = $target; Group = $name }
    }
    foreach ($group in $RemoveGroups) {
        $null = Add-EobPlanStep -Plan $plan -Action 'RemoveGroup' -Title "Aus Gruppe entfernen: $group" -Target $user.SamAccountName -Handler 'Remove-EobAdGroupMembership' -Risk High -Parameters @{
            Identity = $target; Group = $group; AllowPrivileged = [bool]$AllowPrivileged
        }
    }

    if ($plan.Steps.Count -eq 0 -and @($plan.Findings | Where-Object Severity -EQ 'Error').Count -eq 0) {
        Add-EobPlanFinding -Plan $plan -Severity Information -Code 'UPD_NO_CHANGES' -Message 'Keine Änderungen gegenüber dem aktuellen Stand.'
    }
    $plan.Summary['Benutzer'] = "$($user.DisplayName) ($($user.SamAccountName))"
    $plan.Summary['Änderungen'] = [string]$plan.Steps.Count
    return $plan
}

function New-EobPasswordResetPlan {
    <#
    .SYNOPSIS
        Plant ein bewusstes Zurücksetzen des Kennworts (getrennt von Attributänderungen).
    .PARAMETER Identity
        Zielbenutzer.
    .PARAMETER ManualPassword
        Optional vorgegebenes Kennwort; sonst wird eines generiert.
    .PARAMETER ChangePasswordAtLogon
        Änderung bei der nächsten Anmeldung erzwingen.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Erzeugt nur ein Objekt im Speicher; keine Systemänderung.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Identity,
        [AllowNull()][System.Security.SecureString]$ManualPassword,
        [bool]$ChangePasswordAtLogon = $true,
        [AllowNull()][pscustomobject]$Config,
        [AllowNull()][pscustomobject]$DomainPasswordPolicy,
        [switch]$AllowPrivileged,
        [switch]$Simulation
    )

    $context = New-EobOperationContext -Kind 'PasswordReset' -Simulation:$Simulation
    $plan = New-EobPlan -Kind 'PasswordReset' -Context $context -Config $Config -Simulation:$Simulation
    try {
        $user = Get-EobAdUser -Identity $Identity
    }
    catch {
        Add-EobPlanFinding -Plan $plan -Severity Error -Code 'PWR_USER_NOT_FOUND' -Field 'Identity' -Message $_.Exception.Message
        return $plan
    }
    $plan.Subject = @{ SamAccountName = $user.SamAccountName; UserPrincipalName = $user.UserPrincipalName; DisplayName = $user.DisplayName; ObjectGuid = $user.ObjectGuid }
    $null = Test-EobTargetAccount -Plan $plan -User $user -Config $Config -AllowPrivileged:$AllowPrivileged

    $policy = Get-EobPasswordPolicy -Config $Config -DomainPolicy $DomainPasswordPolicy
    if ($null -ne $ManualPassword -and $ManualPassword.Length -gt 0) {
        if (-not (Get-EobConfigValue -Config $Config -Section 'Security' -Key 'AllowManualPassword' -As Bool)) {
            Add-EobPlanFinding -Plan $plan -Severity Error -Code 'PWR_MANUAL_DISABLED' -Field 'ManualPassword' -Message 'Manuelle Kennwörter sind deaktiviert.'
        }
        foreach ($violation in (Test-EobPasswordPolicy -Password $ManualPassword -Policy $policy -SamAccountName $user.SamAccountName -DisplayName @($user.DisplayName, $user.GivenName, $user.Surname)).Violations) {
            Add-EobPlanFinding -Plan $plan -Severity Error -Code 'PWR_POLICY' -Field 'ManualPassword' -Message $violation
        }
        $plan.Secrets['NewPassword'] = $ManualPassword
        $plan.Secrets['PasswordGenerated'] = $false
    }
    else {
        $plan.Secrets['NewPassword'] = New-EobPassword -Policy $policy
        $plan.Secrets['PasswordGenerated'] = $true
    }
    Add-EobRedactionValue -Value $plan.Secrets['NewPassword']
    $null = Add-EobPlanStep -Plan $plan -Action 'ResetPassword' -Title 'Kennwort zurücksetzen' -Target $user.SamAccountName -Handler 'Reset-EobAdUserPassword' -Risk High -Critical -Parameters @{
        Identity = $user.ObjectGuid; NewPassword = '@Secret:NewPassword'; ChangePasswordAtLogon = $ChangePasswordAtLogon; AllowPrivileged = [bool]$AllowPrivileged
    } -Details @("Änderung bei nächster Anmeldung: $(if ($ChangePasswordAtLogon) { 'ja' } else { 'nein' })")
    $plan.Summary['Benutzer'] = "$($user.DisplayName) ($($user.SamAccountName))"
    $plan.Summary['Kennwort'] = if ($plan.Secrets['PasswordGenerated']) { 'wird generiert und einmalig angezeigt' } else { 'manuell vorgegeben' }
    return $plan
}

#endregion

#region Dateisystem

function New-EobHomeDirectory {
    <#
    .SYNOPSIS
        Legt ein Home-Verzeichnis unterhalb eines erlaubten Stammpfads an und berechtigt den Benutzer.
    .DESCRIPTION
        Bestehende Verzeichnisse werden nicht verändert. Die Vererbung des Stammverzeichnisses bleibt
        erhalten; zusätzlich erhält der Benutzer "Ändern".
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$SamAccountName,
        [string]$DomainNetBiosName,
        [Parameter(Mandatory)][string[]]$AllowedRoots
    )

    if (@($AllowedRoots | Where-Object { Test-EobPathWithin -Path $Path -Root $_ }).Count -eq 0) {
        throw "Pfad liegt nicht unter einem erlaubten Stammpfad: $Path"
    }
    if (Test-Path -LiteralPath $Path) {
        return New-EobResult -Status Skipped -Message "Verzeichnis existiert bereits und wurde nicht verändert: $Path"
    }
    if (-not $PSCmdlet.ShouldProcess($Path, "Home-Verzeichnis für $SamAccountName anlegen")) {
        return New-EobResult -Status Succeeded -Message "Simulation: Home-Verzeichnis $Path"
    }
    $null = New-Item -ItemType Directory -Path $Path -ErrorAction Stop
    $account = if ($DomainNetBiosName) { "$DomainNetBiosName\$SamAccountName" } else { $SamAccountName }
    $acl = Get-Acl -LiteralPath $Path
    $rule = [System.Security.AccessControl.FileSystemAccessRule]::new($account, 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
    return New-EobResult -Status Succeeded -Message "Home-Verzeichnis angelegt: $Path"
}

function Set-EobUserPhoto {
    <#
    .SYNOPSIS
        Setzt das Profilbild (thumbnailPhoto, max. 100 KB).
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Identity,
        [Parameter(Mandatory)][string]$Path
    )

    $file = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($file.Length -gt 100KB) {
        throw "Profilbild ist größer als 100 KB ($([Math]::Round($file.Length / 1KB)) KB)."
    }
    if (-not $PSCmdlet.ShouldProcess($Identity, 'Profilbild setzen')) {
        return New-EobResult -Status Succeeded -Message 'Simulation: Profilbild.'
    }
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    return Set-EobAdUserAttribute -Identity $Identity -Replace @{ thumbnailPhoto = $bytes } -SkipTargetCheck -Confirm:$false
}

#endregion

#region CSV-Massenverarbeitung

function Import-EobOnboardingCsv {
    <#
    .SYNOPSIS
        Liest eine Onboarding-CSV (Legacy- und neue Spalten, Trennzeichen- und Kodierungserkennung).
    .OUTPUTS
        Objekt mit Rows, Columns, Findings. Fehler blockieren die Weiterverarbeitung.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowNull()][pscustomobject]$Config
    )

    $findings = [System.Collections.Generic.List[object]]::new()
    $result = [pscustomobject]@{
        PSTypeName = 'Eob.CsvImport'
        Path       = $Path
        Delimiter  = ''
        Encoding   = ''
        Columns    = @()
        Rows       = @()
        Findings   = $findings
    }
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
    $delimiterSetting = Get-EobConfigValue -Config $Config -Section 'Bulk' -Key 'Delimiter'
    $delimiter = switch ($delimiterSetting) {
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
    $mappedColumns = @{}
    foreach ($column in $columns) {
        $normalized = ($column -replace '[\s_\-]', '').ToLowerInvariant()
        if ($script:CsvColumnMap.ContainsKey($normalized)) {
            $mappedColumns[$script:CsvColumnMap[$normalized]] = $column
        }
        else {
            $findings.Add((New-EobFinding -Severity Warning -Code 'CSV_UNKNOWN_COLUMN' -Field $column -Message "Unbekannte Spalte '$column' wird ignoriert."))
        }
    }
    foreach ($required in @('GivenName', 'Surname')) {
        if (-not $mappedColumns.ContainsKey($required)) {
            $findings.Add((New-EobFinding -Severity Error -Code 'CSV_MISSING_COLUMN' -Field $required -Message "Pflichtspalte fehlt: $required (z. B. FirstName/GivenName bzw. LastName/Surname)."))
        }
    }
    $rows = [System.Collections.Generic.List[object]]::new()
    $number = 1
    foreach ($record in $records) {
        $number++
        $data = [ordered]@{}
        foreach ($property in $record.PSObject.Properties) {
            $data[$property.Name] = if ($null -eq $property.Value) { '' } else { ([string]$property.Value).Trim() }
        }
        $rows.Add([pscustomobject]@{ RowNumber = $number; Data = $data })
    }
    $result.Rows = $rows.ToArray()
    return $result
}

function New-EobOnboardingBatch {
    <#
    .SYNOPSIS
        Erstellt aus einem CSV-Import je Zeile einen geprüften Onboarding-Plan.
    .DESCRIPTION
        Erkennt Duplikate (gleiche Personalnummer bzw. gleicher Name) und reserviert vergebene
        Kontonamen innerhalb des Stapels. Zeilen mit Fehlern werden nicht ausgeführt.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Erzeugt nur ein Objekt im Speicher; keine Systemänderung.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Import,
        [AllowNull()][pscustomobject]$Config,
        [switch]$Simulation,
        [switch]$SkipDirectoryCheck,
        [AllowNull()][pscustomobject]$DomainPasswordPolicy
    )

    $reserved = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $employeeIds = @{}
    $names = @{}
    $items = [System.Collections.Generic.List[object]]::new()
    $blocking = @($Import.Findings | Where-Object Severity -EQ 'Error').Count -gt 0

    foreach ($row in $Import.Rows) {
        if ($blocking) { break }
        $request = ConvertTo-EobOnboardingRequest -InputObject $row.Data -Config $Config
        $plan = New-EobOnboardingPlan -Request $request -Config $Config -Simulation:$Simulation -SkipDirectoryCheck:$SkipDirectoryCheck -ReservedIdentities $reserved -DomainPasswordPolicy $DomainPasswordPolicy
        if ($request.EmployeeId) {
            if ($employeeIds.ContainsKey($request.EmployeeId)) {
                Add-EobPlanFinding -Plan $plan -Severity Error -Code 'CSV_DUPLICATE_EMPLOYEEID' -Field 'EmployeeId' -Message "Personalnummer bereits in Zeile $($employeeIds[$request.EmployeeId])."
            }
            else { $employeeIds[$request.EmployeeId] = $row.RowNumber }
        }
        $nameKey = ("$($request.GivenName)|$($request.Surname)").ToLowerInvariant()
        if ($names.ContainsKey($nameKey)) {
            Add-EobPlanFinding -Plan $plan -Severity Warning -Code 'CSV_DUPLICATE_NAME' -Message "Gleicher Name bereits in Zeile $($names[$nameKey]) - bitte prüfen, ob es sich um ein Duplikat handelt."
        }
        else { $names[$nameKey] = $row.RowNumber }

        $subject = $plan.Subject
        foreach ($value in @((Get-EobPropertyValue -InputObject $subject -Name 'SamAccountName' -Default ''), (Get-EobPropertyValue -InputObject $subject -Name 'UserPrincipalName' -Default ''), (Get-EobPropertyValue -InputObject $subject -Name 'Mail' -Default ''))) {
            if ($value) { $null = $reserved.Add([string]$value) }
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
        PSTypeName                = 'Eob.OnboardingBatch'
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

function Invoke-EobOnboardingBatch {
    <#
    .SYNOPSIS
        Führt alle ausführbaren Pläne eines Stapels aus; Einzelfehler brechen den Stapel nicht ab.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][pscustomobject]$Batch)

    if ($Batch.IsBlocked) { throw 'Der Stapel enthält Dateifehler und kann nicht ausgeführt werden.' }
    $simulate = [bool]$WhatIfPreference -or $Batch.Simulation
    if (-not $simulate -and -not $PSCmdlet.ShouldProcess($Batch.Source, "$($Batch.ExecutableCount) Onboarding(s) ausführen")) {
        return $Batch
    }
    foreach ($item in $Batch.Items) {
        if ($item.State -eq 'Error') {
            # Nicht ausführbare Zeilen: Kennwort sofort verwerfen (wird nie angezeigt oder verwendet).
            Clear-EobPlanSecret -Plan $item.Plan -WhatIf:$false -Confirm:$false
            $item | Add-Member -NotePropertyName 'Outcome' -NotePropertyValue 'NotExecuted' -Force
            continue
        }
        try {
            if ($simulate) { $item.Plan.Simulation = $true }
            $null = Invoke-EobPlan -Plan $item.Plan -Confirm:$false
            $item | Add-Member -NotePropertyName 'Outcome' -NotePropertyValue $item.Plan.Status -Force
        }
        catch {
            $item | Add-Member -NotePropertyName 'Outcome' -NotePropertyValue 'Failed' -Force
            $item.Messages = @($item.Messages) + @(Protect-EobSensitiveText -Text $_.Exception.Message)
        }
    }
    return $Batch
}

function Export-EobBatchResult {
    <#
    .SYNOPSIS
        Exportiert das Stapelergebnis maschinenlesbar (CSV oder JSON) - ohne Kennwörter.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Batch,
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('Csv', 'Json')][string]$Format = 'Csv'
    )

    $rows = foreach ($item in $Batch.Items) {
        $subject = $item.Plan.Subject
        [pscustomobject]@{
            Zeile             = $item.RowNumber
            Vorname           = $item.Request.GivenName
            Nachname          = $item.Request.Surname
            SamAccountName    = [string](Get-EobPropertyValue -InputObject $subject -Name 'SamAccountName' -Default '')
            UserPrincipalName = [string](Get-EobPropertyValue -InputObject $subject -Name 'UserPrincipalName' -Default '')
            Mail              = [string](Get-EobPropertyValue -InputObject $subject -Name 'Mail' -Default '')
            Pruefung          = $item.State
            Ergebnis          = [string](Get-EobPropertyValue -InputObject $item -Name 'Outcome' -Default 'NotExecuted')
            OperationId       = $item.Plan.OperationId
            Meldungen         = (Protect-EobSensitiveText -Text (@($item.Messages) -join ' | '))
        }
    }
    if (-not $PSCmdlet.ShouldProcess($Path, 'Stapelergebnis exportieren')) { return $Path }
    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) { $null = New-Item -ItemType Directory -Path $directory -Force }
    if ($Format -eq 'Csv') {
        $rows | ConvertTo-EobCsvSafeObject | Export-Csv -LiteralPath $Path -NoTypeInformation -Delimiter ';' -Encoding utf8BOM
    }
    else {
        [System.IO.File]::WriteAllText($Path, (@($rows) | ConvertTo-Json -Depth 4), [System.Text.UTF8Encoding]::new($false))
    }
    return $Path
}

#endregion
