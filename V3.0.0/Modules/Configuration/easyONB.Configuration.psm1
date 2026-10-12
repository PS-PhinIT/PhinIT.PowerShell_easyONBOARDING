#Requires -Version 7.2
<#
    easyONB.Configuration
    Kompatibler INI-Parser, Schema-Validierung, Zusammenführung (templates → companies → Haupt-INI),
    typisierter Zugriff, Company-Auflösung, kommentarerhaltendes Schreiben und Legacy-Migration.
#>

Set-StrictMode -Version 3.0

$script:SchemaCache = @{}
$script:DefaultSchemaPath = Join-Path -Path (Get-EobAppRoot) -ChildPath (Join-Path -Path 'Config' -ChildPath (Join-Path -Path 'schemas' -ChildPath 'easyONB.schema.psd1'))

#region Hilfsfunktionen

function New-EobDictionary {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Erzeugt nur ein Objekt im Speicher; keine Systemänderung.')]
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()

    return [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
}

function Get-EobTextFileContent {
    <#
    .SYNOPSIS
        Liest eine Textdatei mit Kodierungserkennung (BOM, UTF-8 strikt, sonst Windows-1252).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $encodingName = 'utf-8'
    $hasBom = $false
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $text = [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
        $encodingName = 'utf-8'
        $hasBom = $true
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $text = [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
        $encodingName = 'utf-16le'
        $hasBom = $true
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $text = [System.Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2)
        $encodingName = 'utf-16be'
        $hasBom = $true
    }
    else {
        try {
            $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes)
        }
        catch [System.Text.DecoderFallbackException] {
            $text = [System.Text.Encoding]::GetEncoding(1252).GetString($bytes)
            $encodingName = 'windows-1252'
        }
    }
    [pscustomobject]@{
        Text     = $text
        Encoding = $encodingName
        HasBom   = $hasBom
    }
}

function Write-EobTextFileAtomic {
    <#
        Schreibt Text atomar (temporäre Datei + Replace) als UTF-8 mit BOM und legt ein Backup an.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [int]$KeepBackups = 5
    )

    $directory = Split-Path -Parent $Path
    $temp = Join-Path -Path $directory -ChildPath ('.{0}.{1}.tmp' -f [System.IO.Path]::GetFileName($Path), [guid]::NewGuid().ToString('N'))
    if (-not $PSCmdlet.ShouldProcess($Path, 'Datei schreiben')) {
        return
    }
    [System.IO.File]::WriteAllText($temp, $Text, [System.Text.UTF8Encoding]::new($true))
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $backup = '{0}.{1}.bak' -f $Path, (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
            [System.IO.File]::Replace($temp, $Path, $backup)
            $pattern = [System.IO.Path]::GetFileName($Path) + '.*.bak'
            $backups = @(Get-ChildItem -LiteralPath $directory -Filter $pattern -File | Sort-Object -Property Name -Descending)
            if ($backups.Count -gt $KeepBackups) {
                $backups | Select-Object -Skip $KeepBackups | Remove-Item -Force -ErrorAction SilentlyContinue
            }
        }
        else {
            [System.IO.File]::Move($temp, $Path)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temp) {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
    }
}

#endregion

#region INI lesen

function Read-EobIniFile {
    <#
    .SYNOPSIS
        Liest eine INI-Datei kompatibel zum Legacy-Format.
    .DESCRIPTION
        Unterstützt Kommentare mit ; und #, Werte mit '=', Schlüssel vor dem ersten Abschnitt
        (Abschnitt "Global"), BOM und Windows-1252. Doppelte Schlüssel werden gemeldet (letzter gewinnt).
        Abschnitte und Schlüssel sind unabhängig von Groß-/Kleinschreibung.
    .PARAMETER Path
        Pfad zur INI-Datei.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "INI-Datei nicht gefunden: $Path"
    }
    $content = Get-EobTextFileContent -Path $Path
    $sections = New-EobDictionary
    $lines = @{}
    $duplicates = [System.Collections.Generic.List[object]]::new()
    $invalid = [System.Collections.Generic.List[object]]::new()
    $current = 'Global'
    $lineNumber = 0

    foreach ($rawLine in ($content.Text -split "`r?`n")) {
        $lineNumber++
        $line = $rawLine.Trim()
        if ($line -eq '' -or $line.StartsWith(';') -or $line.StartsWith('#')) {
            continue
        }
        if ($line -match '^\[(.+)\]$') {
            $current = $Matches[1].Trim()
            if (-not $sections.Contains($current)) {
                $sections[$current] = New-EobDictionary
            }
            continue
        }
        $separator = $line.IndexOf('=')
        if ($separator -gt 0) {
            $key = $line.Substring(0, $separator).Trim()
            $value = $line.Substring($separator + 1).Trim()
            if (-not $sections.Contains($current)) {
                $sections[$current] = New-EobDictionary
            }
            if ($sections[$current].Contains($key)) {
                $duplicates.Add([pscustomobject]@{ Section = $current; Key = $key; Line = $lineNumber })
            }
            $sections[$current][$key] = $value
            $lines["$current|$key"] = $lineNumber
        }
        else {
            $invalid.Add([pscustomobject]@{ Line = $lineNumber; Text = $line })
        }
    }

    [pscustomobject]@{
        PSTypeName   = 'Eob.IniFile'
        Path         = $Path
        Encoding     = $content.Encoding
        Sections     = $sections
        LineNumbers  = $lines
        Duplicates   = $duplicates
        InvalidLines = $invalid
    }
}

#endregion

#region Schema

function Get-EobConfigSchema {
    <#
    .SYNOPSIS
        Lädt das Konfigurationsschema (zwischengespeichert).
    .PARAMETER Path
        Pfad zur Schemadatei (Standard: Config/schemas/easyONB.schema.psd1).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string]$Path = $script:DefaultSchemaPath)

    if (-not $script:SchemaCache.ContainsKey($Path)) {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            throw "Konfigurationsschema nicht gefunden: $Path"
        }
        $script:SchemaCache[$Path] = Import-PowerShellDataFile -LiteralPath $Path
    }
    return $script:SchemaCache[$Path]
}

function Get-EobSchemaSectionDefinition {
    <#
    .SYNOPSIS
        Liefert die Schemadefinition eines Abschnitts (exakt oder über Muster).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Schema,
        [Parameter(Mandatory)][string]$Name
    )

    foreach ($sectionName in $Schema.Sections.Keys) {
        if ($sectionName -ieq $Name) {
            return $Schema.Sections[$sectionName]
        }
    }
    foreach ($patternDefinition in $Schema.SectionPatterns) {
        if ($Name -match $patternDefinition.Pattern) {
            return $patternDefinition
        }
    }
    return $null
}

function Get-EobSchemaKeyDefinition {
    <#
    .SYNOPSIS
        Liefert die Schemadefinition eines Schlüssels innerhalb einer Abschnittsdefinition.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$SectionDefinition,
        [Parameter(Mandatory)][string]$Key
    )

    if ($SectionDefinition.ContainsKey('Keys')) {
        foreach ($keyName in $SectionDefinition.Keys.Keys) {
            if ($keyName -ieq $Key) {
                return $SectionDefinition.Keys[$keyName]
            }
        }
    }
    if ($SectionDefinition.ContainsKey('KeyPatterns')) {
        foreach ($patternDefinition in $SectionDefinition.KeyPatterns) {
            if ($Key -match $patternDefinition.Pattern) {
                return $patternDefinition
            }
        }
    }
    return $null
}

function Test-EobConfigValueType {
    <#
    .SYNOPSIS
        Prüft einen Wert gegen einen Schematyp. Liefert $null (gültig) oder eine Fehlermeldung.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Definition,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value
    )

    if ($Value -eq '') { return $null }
    $type = if ($Definition.ContainsKey('Type')) { $Definition.Type } else { 'String' }
    switch ($type) {
        'Int' {
            $number = 0
            if (-not [int]::TryParse($Value, [ref]$number)) { return "Ganzzahl erwartet, gefunden '$Value'." }
            if ($Definition.ContainsKey('Min') -and $number -lt $Definition.Min) { return "Wert $number unterschreitet das Minimum $($Definition.Min)." }
            if ($Definition.ContainsKey('Max') -and $number -gt $Definition.Max) { return "Wert $number überschreitet das Maximum $($Definition.Max)." }
        }
        'Bool' {
            if (-not (Test-EobBooleanText -Value $Value)) { return "Boolean erwartet (1/0, True/False), gefunden '$Value'." }
        }
        'Enum' {
            if (@($Definition.Values | Where-Object { $_ -ieq $Value }).Count -eq 0) {
                return "Ungültiger Wert '$Value'. Zulässig: $($Definition.Values -join ', ')."
            }
        }
        'Dn' {
            if (-not (Test-EobDistinguishedName -Value $Value)) { return "Kein gültiger Distinguished Name: '$Value'." }
        }
        'Domain' {
            if (-not (Test-EobDomainName -Value $Value.TrimStart('@'))) { return "Kein gültiger Domänenname: '$Value'." }
        }
        'MailDomain' {
            $domain = $Value.Trim().TrimStart('@')
            if (-not (Test-EobDomainName -Value $domain) -or -not $domain.Contains('.')) { return "Keine gültige E-Mail-Domäne: '$Value'." }
        }
        'Email' {
            if (-not (Test-EobEmailAddress -Value $Value)) { return "Keine gültige E-Mail-Adresse: '$Value'." }
        }
        'Url' {
            $uri = $null
            if (-not [System.Uri]::TryCreate($Value, [System.UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('http', 'https')) {
                return "Keine gültige URL (http/https): '$Value'."
            }
        }
        'Guid' {
            $guid = [guid]::Empty
            if (-not [guid]::TryParse($Value, [ref]$guid)) { return "GUID erwartet, gefunden '$Value'." }
        }
        'Thumbprint' {
            if ($Value -notmatch '^[0-9A-Fa-f]{40}$') { return "Zertifikatsfingerabdruck (40 Hexadezimalzeichen) erwartet, gefunden '$Value'." }
        }
        'Color' {
            if ($Value -notmatch '^#([0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$') { return "Farbe im Format #RRGGBB erwartet, gefunden '$Value'." }
        }
        'Regex' {
            try { $null = [regex]::new($Value) } catch { return "Ungültiger regulärer Ausdruck: $($_.Exception.Message)" }
        }
        'Path' {
            if ($Value.IndexOfAny([char[]]@('<', '>', '|', '"', [char]0)) -ge 0) { return "Pfad enthält ungültige Zeichen: '$Value'." }
        }
    }
    return $null
}

#endregion

#region Konfiguration laden

function Get-EobDefaultConfigurationPath {
    <#
    .SYNOPSIS
        Ermittelt den Standardpfad der Konfiguration (EASYONB_CONFIG oder Config/easyONB.ini).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if (-not [string]::IsNullOrWhiteSpace($env:EASYONB_CONFIG)) {
        return Resolve-EobPath -Path $env:EASYONB_CONFIG
    }
    return Join-Path -Path (Join-Path -Path (Get-EobAppRoot) -ChildPath 'Config') -ChildPath 'easyONB.ini'
}

function Import-EobConfiguration {
    <#
    .SYNOPSIS
        Lädt, vereinigt und validiert die Konfiguration.
    .DESCRIPTION
        Reihenfolge: Config/templates/*.ini → Config/companies/*.ini → Haupt-INI (höchste Priorität).
        Fehlt die Haupt-INI, wird ein Konfigurationsobjekt mit Error-Befund geliefert (kein Abbruch).
    .PARAMETER Path
        Pfad der Haupt-INI (Standard: EASYONB_CONFIG bzw. Config/easyONB.ini).
    .PARAMETER SchemaPath
        Alternativer Schemapfad.
    .PARAMETER NoIncludes
        Keine Dateien aus templates/ und companies/ einbeziehen.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$Path,
        [string]$SchemaPath = $script:DefaultSchemaPath,
        [switch]$NoIncludes
    )

    $configPath = if ([string]::IsNullOrWhiteSpace($Path)) { Get-EobDefaultConfigurationPath } else { Resolve-EobPath -Path $Path }
    $configRoot = Split-Path -Parent $configPath
    $schema = Get-EobConfigSchema -Path $SchemaPath
    $findings = [System.Collections.Generic.List[object]]::new()
    $sources = [System.Collections.Generic.List[string]]::new()
    $origins = @{}
    $merged = New-EobDictionary
    $exists = Test-Path -LiteralPath $configPath -PathType Leaf

    if (-not $exists) {
        $findings.Add((New-EobFinding -Severity Error -Code 'CFG_FILE_NOT_FOUND' -Source $configPath -Message (
                    "Konfigurationsdatei nicht gefunden: $configPath. Vorlage: Config\easyONB.ini.template kopieren und anpassen.")))
    }

    $files = [System.Collections.Generic.List[string]]::new()
    if (-not $NoIncludes) {
        foreach ($includeDir in @('templates', 'companies')) {
            $dir = Join-Path -Path $configRoot -ChildPath $includeDir
            if (Test-Path -LiteralPath $dir -PathType Container) {
                foreach ($file in (Get-ChildItem -LiteralPath $dir -Filter '*.ini' -File | Sort-Object -Property Name)) {
                    $files.Add($file.FullName)
                }
            }
        }
    }
    if ($exists) {
        $files.Add($configPath)
    }

    foreach ($file in $files) {
        try {
            $ini = Read-EobIniFile -Path $file
        }
        catch {
            $findings.Add((New-EobFinding -Severity Error -Code 'CFG_PARSE_ERROR' -Source $file -Message "Datei konnte nicht gelesen werden: $($_.Exception.Message)"))
            continue
        }
        $sources.Add($file)
        $fileName = [System.IO.Path]::GetFileName($file)
        foreach ($duplicate in $ini.Duplicates) {
            $findings.Add((New-EobFinding -Severity Warning -Code 'CFG_DUPLICATE_KEY' -Source $fileName -Field "$($duplicate.Section).$($duplicate.Key)" -Message (
                        "Schlüssel [$($duplicate.Section)] $($duplicate.Key) mehrfach definiert (Zeile $($duplicate.Line)); der letzte Wert gilt.")))
        }
        foreach ($invalidLine in $ini.InvalidLines) {
            $findings.Add((New-EobFinding -Severity Warning -Code 'CFG_INVALID_LINE' -Source $fileName -Message (
                        "Zeile $($invalidLine.Line) ist weder Abschnitt, Schlüssel noch Kommentar und wird ignoriert.")))
        }
        foreach ($sectionName in $ini.Sections.Keys) {
            if (-not $merged.Contains($sectionName)) {
                $merged[$sectionName] = New-EobDictionary
            }
            foreach ($key in $ini.Sections[$sectionName].Keys) {
                $originKey = "$sectionName|$key"
                if ($merged[$sectionName].Contains($key) -and $origins.ContainsKey($originKey) -and $origins[$originKey] -ne $fileName) {
                    $findings.Add((New-EobFinding -Severity Information -Code 'CFG_OVERRIDDEN' -Source $fileName -Field "$sectionName.$key" -Message (
                                "[$sectionName] $key aus '$($origins[$originKey])' wird durch '$fileName' überschrieben.")))
                }
                $merged[$sectionName][$key] = $ini.Sections[$sectionName][$key]
                $origins[$originKey] = $fileName
            }
        }
    }

    $config = [pscustomobject]@{
        PSTypeName = 'Eob.Configuration'
        Path       = $configPath
        ConfigRoot = $configRoot
        AppRoot    = Get-EobAppRoot
        Exists     = $exists
        Sources    = $sources
        Origins    = $origins
        Sections   = $merged
        Schema     = $schema
        Findings   = $findings
        LoadedAt   = Get-Date
    }
    foreach ($finding in @(Test-EobConfiguration -Config $config)) {
        $config.Findings.Add($finding)
    }
    return $config
}

function Test-EobConfiguration {
    <#
    .SYNOPSIS
        Validiert eine geladene Konfiguration gegen Schema und fachliche Regeln.
    .OUTPUTS
        Befundobjekte (Eob.Finding).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Config)

    $schema = $Config.Schema
    $results = [System.Collections.Generic.List[object]]::new()

    foreach ($sectionName in $Config.Sections.Keys) {
        $section = $Config.Sections[$sectionName]
        if ($sectionName -eq 'Global') {
            if ($section.Count -gt 0) {
                $results.Add((New-EobFinding -Severity Information -Code 'CFG_KEYS_OUTSIDE_SECTION' -Field 'Global' -Message 'Schlüssel vor dem ersten Abschnitt werden nicht ausgewertet.'))
            }
            continue
        }
        $sectionDefinition = Get-EobSchemaSectionDefinition -Schema $schema -Name $sectionName
        if ($null -eq $sectionDefinition) {
            $results.Add((New-EobFinding -Severity Information -Code 'CFG_UNKNOWN_SECTION' -Field $sectionName -Message "Unbekannter Abschnitt [$sectionName] wird beibehalten, aber nicht ausgewertet."))
            foreach ($key in $section.Keys) {
                if ($key -match $script:SensitiveNamePattern -and ([string]$section[$key]) -ne '') {
                    $results.Add((New-EobFinding -Severity Warning -Code 'CFG_SECRET_IN_FILE' -Field "$sectionName.$key" -Message "[$sectionName] $key sieht nach einem Secret aus. Secrets gehören nicht in die Konfiguration."))
                }
            }
            continue
        }
        if ($sectionDefinition.ContainsKey('Deprecated') -and $sectionDefinition.Deprecated -and $section.Count -gt 0) {
            $results.Add((New-EobFinding -Severity Information -Code 'CFG_DEPRECATED_SECTION' -Field $sectionName -Message "[$sectionName]: $($sectionDefinition.Description)"))
        }

        if ($sectionDefinition.ContainsKey('Keys')) {
            foreach ($requiredKey in $sectionDefinition.Keys.Keys) {
                $keyDefinition = $sectionDefinition.Keys[$requiredKey]
                if ($keyDefinition.ContainsKey('Required') -and $keyDefinition.Required -and ([string]$section[$requiredKey]) -eq '') {
                    $results.Add((New-EobFinding -Severity Error -Code 'CFG_MISSING_KEY' -Field "$sectionName.$requiredKey" -Message "Pflichtschlüssel [$sectionName] $requiredKey fehlt."))
                }
            }
        }

        foreach ($key in $section.Keys) {
            $value = [string]$section[$key]
            $keyDefinition = Get-EobSchemaKeyDefinition -SectionDefinition $sectionDefinition -Key $key
            if ($null -eq $keyDefinition) {
                if ($sectionDefinition.ContainsKey('FreeForm') -and $sectionDefinition.FreeForm) {
                    $valueType = if ($sectionDefinition.ContainsKey('ValueType')) { $sectionDefinition.ValueType } else { 'String' }
                    $problem = Test-EobConfigValueType -Definition @{ Type = $valueType } -Value $value
                    if ($problem) {
                        $results.Add((New-EobFinding -Severity Warning -Code 'CFG_INVALID_VALUE' -Field "$sectionName.$key" -Message "[$sectionName] ${key}: $problem"))
                    }
                    if ($key -match $script:SensitiveNamePattern -and $value -ne '') {
                        $results.Add((New-EobFinding -Severity Warning -Code 'CFG_SECRET_IN_FILE' -Field "$sectionName.$key" -Message "[$sectionName] $key sieht nach einem Secret aus. Secrets gehören nicht in die Konfiguration."))
                    }
                    continue
                }
                $severity = if ($key -match $script:SensitiveNamePattern -and $value -ne '') { 'Warning' } else { 'Information' }
                $code = if ($severity -eq 'Warning') { 'CFG_SECRET_IN_FILE' } else { 'CFG_UNKNOWN_KEY' }
                $results.Add((New-EobFinding -Severity $severity -Code $code -Field "$sectionName.$key" -Message "Unbekannter Schlüssel [$sectionName] $key wird beibehalten, aber nicht ausgewertet."))
                continue
            }
            if ($keyDefinition.ContainsKey('Secret') -and $keyDefinition.Secret) {
                if ($value -ne '') {
                    $results.Add((New-EobFinding -Severity Warning -Code 'CFG_SECRET_IN_FILE' -Field "$sectionName.$key" -Message (
                                "[$sectionName] $key enthält ein Klartext-Secret. Der Wert wird ignoriert und sollte aus der Datei entfernt werden. $($keyDefinition.Description)")))
                }
                continue
            }
            if ($value -eq '') { continue }
            if ($keyDefinition.ContainsKey('Deprecated') -and $keyDefinition.Deprecated) {
                $replacement = if ($keyDefinition.ContainsKey('Replacement')) { " Ersatz: $($keyDefinition.Replacement)." } else { '' }
                $results.Add((New-EobFinding -Severity Information -Code 'CFG_DEPRECATED_KEY' -Field "$sectionName.$key" -Message "[$sectionName] $key ist veraltet.$replacement $($keyDefinition.Description)"))
            }
            elseif ($keyDefinition.ContainsKey('Unused') -and $keyDefinition.Unused -and -not ($sectionDefinition.ContainsKey('Deprecated') -and $sectionDefinition.Deprecated)) {
                $results.Add((New-EobFinding -Severity Information -Code 'CFG_UNUSED_KEY' -Field "$sectionName.$key" -Message "[$sectionName] ${key}: $($keyDefinition.Description)"))
            }
            $problem = Test-EobConfigValueType -Definition $keyDefinition -Value $value
            if ($problem) {
                $results.Add((New-EobFinding -Severity Warning -Code 'CFG_INVALID_VALUE' -Field "$sectionName.$key" -Message "[$sectionName] ${key}: $problem Standardwert wird verwendet."))
            }
        }
    }

    foreach ($finding in @(Test-EobConfigurationRule -Config $Config)) {
        $results.Add($finding)
    }
    return $results.ToArray()
}

$script:SensitiveNamePattern = '(?i)(password|passwort|kennwort|secret|token|apikey|api_key|webhook)'

function Test-EobConfigurationRule {
    <#
        Fachliche Querprüfungen über mehrere Schlüssel.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Config)

    if (-not $Config.Exists -and $Config.Sections.Count -eq 0) {
        return
    }

    $companies = @(Get-EobCompany -Config $Config)
    if ($companies.Count -eq 0) {
        New-EobFinding -Severity Error -Code 'CFG_NO_COMPANY' -Field 'Company' -Message 'Kein [Company]-Abschnitt vorhanden. Onboarding ist nicht möglich.'
    }
    foreach ($company in $companies) {
        if ([string]::IsNullOrWhiteSpace($company.UpnSuffix)) {
            New-EobFinding -Severity Error -Code 'CFG_COMPANY_NO_UPN' -Field $company.Id -Message "[$($company.Id)] CompanyActiveDirectoryDomain (UPN-Suffix) fehlt."
        }
        if ([string]::IsNullOrWhiteSpace($company.DefaultOU)) {
            New-EobFinding -Severity Error -Code 'CFG_COMPANY_NO_OU' -Field $company.Id -Message "[$($company.Id)] Keine Ziel-OU: CompanyActiveDirectoryOU oder [ADUserDefaults] DefaultOU setzen."
        }
        if ([string]::IsNullOrWhiteSpace($company.MailDomain)) {
            New-EobFinding -Severity Warning -Code 'CFG_COMPANY_NO_MAIL' -Field $company.Id -Message "[$($company.Id)] CompanyMailDomain fehlt; E-Mail-Adressen können nicht erzeugt werden."
        }
    }

    $length = Get-EobConfigValue -Config $Config -Section 'PasswordFixGenerate' -Key 'DefaultPasswordLength' -As Int
    $minimum = 0
    foreach ($key in @('MinUpperCase', 'MinLowerCase', 'MinDigits', 'MinSpecialChars')) {
        $minimum += Get-EobConfigValue -Config $Config -Section 'PasswordFixGenerate' -Key $key -As Int
    }
    if ($minimum -gt $length) {
        New-EobFinding -Severity Error -Code 'CFG_PASSWORD_POLICY' -Field 'PasswordFixGenerate' -Message "Die Summe der Mindestanzahlen ($minimum) übersteigt die Kennwortlänge ($length)."
    }

    $allowedActions = @($Config.Schema.OffboardingActions)
    $templateSections = @(Get-EobConfigSectionName -Config $Config -Pattern '^OffboardingTemplate\.')
    if ($templateSections.Count -eq 0) {
        New-EobFinding -Severity Warning -Code 'CFG_NO_OFFBOARDING_TEMPLATE' -Field 'OffboardingTemplate' -Message 'Keine Offboarding-Vorlage definiert (Config\templates\offboarding-templates.ini).'
    }
    $disabledOu = Get-EobConfigValue -Config $Config -Section 'Offboarding' -Key 'DisabledUsersOU'
    $archiveRoot = Get-EobConfigValue -Config $Config -Section 'FileServer' -Key 'ArchiveRoot'
    foreach ($templateSection in $templateSections) {
        $section = $Config.Sections[$templateSection]
        foreach ($key in $section.Keys) {
            if ($key -match '^Action\.(.+)$') {
                $action = $Matches[1]
                if (@($allowedActions | Where-Object { $_ -ieq $action }).Count -eq 0) {
                    New-EobFinding -Severity Warning -Code 'CFG_UNKNOWN_ACTION' -Field "$templateSection.$key" -Message "[$templateSection] Unbekannte Aktion '$action' wird ignoriert."
                }
            }
        }
        $phaseOf = { param($name) [string]$section["Action.$name"] }
        $retention = 0
        $null = [int]::TryParse([string]$section['RetentionDays'], [ref]$retention)
        if ((& $phaseOf 'DeleteAccount') -ieq 'FinalDeletion' -and $retention -le 0) {
            New-EobFinding -Severity Error -Code 'CFG_DELETION_WITHOUT_RETENTION' -Field $templateSection -Message "[$templateSection] Endgültige Löschung erfordert RetentionDays > 0."
        }
        $deleteMisplaced = & $phaseOf 'DeleteAccount'
        if ($deleteMisplaced -and $deleteMisplaced -notin @('FinalDeletion', 'Off')) {
            New-EobFinding -Severity Error -Code 'CFG_DELETION_WRONG_PHASE' -Field $templateSection -Message "[$templateSection] DeleteAccount ist nur in der Phase FinalDeletion zulässig."
        }
        $moveTo = & $phaseOf 'MoveToOU'
        if ($moveTo -and $moveTo -ine 'Off' -and [string]::IsNullOrWhiteSpace([string]$section['TargetOU']) -and [string]::IsNullOrWhiteSpace($disabledOu)) {
            New-EobFinding -Severity Error -Code 'CFG_MOVE_WITHOUT_OU' -Field $templateSection -Message "[$templateSection] MoveToOU benötigt TargetOU oder [Offboarding] DisabledUsersOU."
        }
        $archive = & $phaseOf 'ArchiveHomeDirectory'
        if ($archive -and $archive -ine 'Off' -and [string]::IsNullOrWhiteSpace($archiveRoot)) {
            New-EobFinding -Severity Warning -Code 'CFG_ARCHIVE_WITHOUT_ROOT' -Field $templateSection -Message "[$templateSection] ArchiveHomeDirectory benötigt [FileServer] ArchiveRoot; die Aktion wird übersprungen."
        }
    }
    $defaultTemplate = Get-EobConfigValue -Config $Config -Section 'Offboarding' -Key 'DefaultTemplate'
    if ($templateSections.Count -gt 0 -and $defaultTemplate -and @($templateSections | Where-Object { $_ -ieq "OffboardingTemplate.$defaultTemplate" }).Count -eq 0) {
        New-EobFinding -Severity Warning -Code 'CFG_DEFAULT_TEMPLATE_MISSING' -Field 'Offboarding.DefaultTemplate' -Message "Standardvorlage '$defaultTemplate' existiert nicht."
    }

    $allowedRoots = @(Get-EobConfigValue -Config $Config -Section 'FileServer' -Key 'AllowedRoots' -As List)
    if ($archiveRoot -and $allowedRoots.Count -gt 0 -and @($allowedRoots | Where-Object { Test-EobPathWithin -Path $archiveRoot -Root $_ }).Count -eq 0) {
        New-EobFinding -Severity Warning -Code 'CFG_ARCHIVE_OUTSIDE_ROOTS' -Field 'FileServer.ArchiveRoot' -Message 'ArchiveRoot liegt nicht unter FileServer.AllowedRoots.'
    }
    if ((Get-EobConfigValue -Config $Config -Section 'OnboardingExtensions' -Key 'CreateHomeDirectory' -As Bool) -and $allowedRoots.Count -eq 0) {
        New-EobFinding -Severity Warning -Code 'CFG_HOME_WITHOUT_ROOTS' -Field 'FileServer.AllowedRoots' -Message 'CreateHomeDirectory ist aktiv, aber [FileServer] AllowedRoots ist leer; Home-Verzeichnisse werden nicht angelegt.'
    }
    if ((Get-EobConfigValue -Config $Config -Section 'EmailSettings' -Key 'SendWelcomeEmail' -As Bool) -and -not (Get-EobConfigValue -Config $Config -Section 'EmailSettings' -Key 'SMTPServer')) {
        New-EobFinding -Severity Warning -Code 'CFG_SMTP_MISSING' -Field 'EmailSettings.SMTPServer' -Message 'Welcome-Mail ist aktiviert, aber kein SMTPServer konfiguriert.'
    }
    if ((Get-EobConfigValue -Config $Config -Section 'ADSync' -Key 'EnableADSync' -As Bool) -and -not (Get-EobConfigValue -Config $Config -Section 'ADSync' -Key 'ADSyncServer')) {
        New-EobFinding -Severity Warning -Code 'CFG_ADSYNC_SERVER_MISSING' -Field 'ADSync.ADSyncServer' -Message 'Entra Connect Sync ist aktiviert, aber kein ADSyncServer konfiguriert.'
    }
    $exchangeMode = Get-EobConfigValue -Config $Config -Section 'Exchange' -Key 'Mode'
    if ($exchangeMode -in @('OnPremises', 'Hybrid') -and -not (Get-EobConfigValue -Config $Config -Section 'Exchange' -Key 'OnPremisesUri')) {
        New-EobFinding -Severity Warning -Code 'CFG_EXCHANGE_URI_MISSING' -Field 'Exchange.OnPremisesUri' -Message "Exchange-Modus $exchangeMode benötigt OnPremisesUri."
    }
    # Zertifikatsanmeldung: nur vollständig wirksam; teilweise Angaben fallen sonst unbemerkt auf interaktiv zurück.
    foreach ($certificateAuth in @(
            @{ Section = 'Exchange'; Keys = @('AppId', 'CertificateThumbprint', 'Organization') }
            @{ Section = 'Graph'; Keys = @('ClientId', 'CertificateThumbprint', 'TenantId') }
        )) {
        $set = @($certificateAuth.Keys | Where-Object { [string](Get-EobConfigValue -Config $Config -Section $certificateAuth.Section -Key $_) })
        $relevant = if ($certificateAuth.Section -eq 'Graph') { @($set | Where-Object { $_ -ne 'TenantId' }).Count -gt 0 } else { $set.Count -gt 0 }
        if ($relevant -and $set.Count -lt $certificateAuth.Keys.Count) {
            $missing = @($certificateAuth.Keys | Where-Object { $_ -notin $set }) -join ', '
            New-EobFinding -Severity Warning -Code 'CFG_CERTIFICATE_AUTH_INCOMPLETE' -Field "$($certificateAuth.Section).$missing" `
                -Message "[$($certificateAuth.Section)] Zertifikatsanmeldung unvollständig (es fehlt: $missing); es wird interaktiv angemeldet."
        }
    }
    $templatePath = Get-EobConfigValue -Config $Config -Section 'Report' -Key 'TemplatePathHTML' -As Path
    if (-not $templatePath -or -not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
        New-EobFinding -Severity Warning -Code 'CFG_TEMPLATE_NOT_FOUND' -Field 'Report.TemplatePathHTML' -Message "Vorlage für das verpflichtende Onboarding-Handout nicht gefunden: $templatePath. Onboarding bleibt bis zur Korrektur gesperrt."
    }
}

#endregion

#region Zugriff

function Get-EobConfigValue {
    <#
    .SYNOPSIS
        Liest einen Konfigurationswert typisiert (mit Schema-Standardwert).
    .PARAMETER Config
        Konfigurationsobjekt.
    .PARAMETER Section
        Abschnitt.
    .PARAMETER Key
        Schlüssel.
    .PARAMETER Default
        Standardwert (überschreibt den Schema-Standard).
    .PARAMETER As
        String, Int, Bool, Path, List oder Date.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][pscustomobject]$Config,
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][string]$Key,
        [AllowNull()][object]$Default,
        [ValidateSet('String', 'Int', 'Bool', 'Path', 'List', 'Date')][string]$As = 'String'
    )

    $hasExplicitDefault = $PSBoundParameters.ContainsKey('Default')
    $raw = $null
    if ($null -ne $Config -and $Config.Sections.Contains($Section)) {
        $sectionData = $Config.Sections[$Section]
        if ($sectionData.Contains($Key)) {
            $raw = [string]$sectionData[$Key]
        }
    }

    $schemaDefinition = $null
    $schema = if ($null -ne $Config) { $Config.Schema } else { Get-EobConfigSchema }
    $sectionDefinition = Get-EobSchemaSectionDefinition -Schema $schema -Name $Section
    if ($null -ne $sectionDefinition) {
        $schemaDefinition = Get-EobSchemaKeyDefinition -SectionDefinition $sectionDefinition -Key $Key
    }

    if ($null -ne $schemaDefinition -and $schemaDefinition.ContainsKey('Secret') -and $schemaDefinition.Secret) {
        $raw = $null
    }
    if ($null -ne $raw -and $null -ne $schemaDefinition -and (Test-EobConfigValueType -Definition $schemaDefinition -Value $raw)) {
        $raw = $null
    }

    if ([string]::IsNullOrEmpty($raw)) {
        if ($hasExplicitDefault) {
            if ($As -eq 'Path' -and $Default -is [string]) {
                return Resolve-EobPath -Path $Default
            }
            return $Default
        }
        $raw = if ($null -ne $schemaDefinition -and $schemaDefinition.ContainsKey('Default')) { [string]$schemaDefinition.Default } else { '' }
    }

    switch ($As) {
        'Int' {
            $number = 0
            if ([int]::TryParse($raw, [ref]$number)) { return $number }
            return 0
        }
        'Bool' { return (ConvertTo-EobBoolean -Value $raw -Default $false) }
        'Path' { return (Resolve-EobPath -Path $raw) }
        'List' {
            if ([string]::IsNullOrWhiteSpace($raw)) { return }
            return ($raw -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
        }
        'Date' { return (ConvertTo-EobDate -Value $raw) }
        default { return $raw }
    }
}

function Get-EobConfigSection {
    <#
    .SYNOPSIS
        Liefert eine Kopie eines Abschnitts als geordnetes Dictionary (leer, falls nicht vorhanden).
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][pscustomobject]$Config,
        [Parameter(Mandatory)][string]$Name
    )

    $copy = New-EobDictionary
    if ($null -ne $Config -and $Config.Sections.Contains($Name)) {
        foreach ($key in $Config.Sections[$Name].Keys) {
            $copy[$key] = $Config.Sections[$Name][$key]
        }
    }
    return , $copy
}

function Get-EobConfigSectionName {
    <#
    .SYNOPSIS
        Liefert Abschnittsnamen, die einem regulären Ausdruck entsprechen.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][pscustomobject]$Config,
        [Parameter(Mandatory)][string]$Pattern
    )

    if ($null -eq $Config) { return }
    foreach ($name in $Config.Sections.Keys) {
        if ($name -match $Pattern) { $name }
    }
}

function Get-EobCompany {
    <#
    .SYNOPSIS
        Liefert Unternehmensdefinitionen aus [Company], [Company1], ... (Legacy-kompatibel).
    .DESCRIPTION
        Schlüssel dürfen die Abschnittsnummer als Suffix tragen (z. B. CompanyActiveDirectoryDomain1);
        ohne Suffix gilt der Schlüssel ohne Nummer. Fehlt eine firmenspezifische OU, wird
        [ADUserDefaults] DefaultOU verwendet.
    .PARAMETER Config
        Konfigurationsobjekt.
    .PARAMETER Id
        Abschnittsname (z. B. Company1). Ohne Angabe werden alle Unternehmen geliefert.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][pscustomobject]$Config,
        [string]$Id
    )

    if ($null -eq $Config) { return }
    $names = @(Get-EobConfigSectionName -Config $Config -Pattern '^Company\d*$' |
            Sort-Object -Property @{ Expression = { if ($_ -match '(\d+)$') { [int]$Matches[1] } else { -1 } } })
    $defaultOu = [string](Get-EobConfigValue -Config $Config -Section 'ADUserDefaults' -Key 'DefaultOU')

    foreach ($name in $names) {
        if ($Id -and $name -ine $Id) { continue }
        $section = $Config.Sections[$name]
        $suffix = $name.Substring(7)
        $read = {
            param([string]$BaseKey)
            foreach ($candidate in @("$BaseKey$suffix", $BaseKey)) {
                if ($section.Contains($candidate) -and -not [string]::IsNullOrWhiteSpace([string]$section[$candidate])) {
                    return ([string]$section[$candidate]).Trim()
                }
            }
            return ''
        }
        $ou = & $read 'CompanyActiveDirectoryOU'
        if ([string]::IsNullOrWhiteSpace($ou)) { $ou = $defaultOu }
        $displayName = & $read 'CompanyNameFirma'
        [pscustomobject]@{
            PSTypeName  = 'Eob.Company'
            Id          = $name
            Suffix      = $suffix
            DisplayName = if ($displayName) { $displayName } else { $name }
            UpnSuffix   = (& $read 'CompanyActiveDirectoryDomain').TrimStart('@')
            MailDomain  = (& $read 'CompanyMailDomain').TrimStart('@')
            MS365Domain = (& $read 'CompanyMS365Domain').TrimStart('@')
            Website     = & $read 'CompanyDomain'
            Street      = & $read 'CompanyStrasse'
            PostalCode  = & $read 'CompanyPLZ'
            City        = & $read 'CompanyOrt'
            Country     = & $read 'CompanyCountry'
            Phone       = & $read 'CompanyTelefon'
            DefaultOU   = $ou
        }
    }
}

function Get-EobMailDomain {
    <#
    .SYNOPSIS
        Liefert die zulässigen E-Mail-Domänen (Firmendomäne zuerst, dann [MailEndungen]).
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][pscustomobject]$Config,
        [string]$CompanyId
    )

    $domains = [System.Collections.Generic.List[string]]::new()
    $company = if ($CompanyId) { Get-EobCompany -Config $Config -Id $CompanyId | Select-Object -First 1 } else { Get-EobCompany -Config $Config | Select-Object -First 1 }
    if ($null -ne $company -and $company.MailDomain) {
        $domains.Add($company.MailDomain.ToLowerInvariant())
    }
    $section = Get-EobConfigSection -Config $Config -Name 'MailEndungen'
    foreach ($key in $section.Keys) {
        $domain = ([string]$section[$key]).Trim().TrimStart('@').ToLowerInvariant()
        if ($domain -and -not $domains.Contains($domain) -and (Test-EobDomainName -Value $domain)) {
            $domains.Add($domain)
        }
    }
    return $domains.ToArray()
}

function Get-EobLoggingParameter {
    <#
    .SYNOPSIS
        Liefert Parameter für Initialize-EobLogging aus der Konfiguration.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([AllowNull()][pscustomobject]$Config)

    $directory = Get-EobConfigValue -Config $Config -Section 'Logging' -Key 'LogFile' -As Path
    $audit = Get-EobConfigValue -Config $Config -Section 'Logging' -Key 'AuditDirectory' -As Path
    $level = Get-EobConfigValue -Config $Config -Section 'Logging' -Key 'MinimumLevel'
    if (Get-EobConfigValue -Config $Config -Section 'Logging' -Key 'DebugMode' -As Bool) {
        $level = 'Debug'
    }
    $parameters = @{
        Directory          = $directory
        MinimumLevel       = $level
        RetentionDays      = Get-EobConfigValue -Config $Config -Section 'Logging' -Key 'RetentionDays' -As Int
        AuditRetentionDays = Get-EobConfigValue -Config $Config -Section 'Logging' -Key 'AuditRetentionDays' -As Int
        MaxFileSizeMB      = Get-EobConfigValue -Config $Config -Section 'Logging' -Key 'MaxFileSizeMB' -As Int
    }
    if ($audit) { $parameters['AuditDirectory'] = $audit }
    return $parameters
}

function Get-EobConfigFindingSummary {
    <#
    .SYNOPSIS
        Zählt Konfigurationsbefunde nach Schweregrad.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][pscustomobject]$Config)

    $all = @($Config.Findings)
    [pscustomobject]@{
        Errors       = @($all | Where-Object Severity -EQ 'Error').Count
        Warnings     = @($all | Where-Object Severity -EQ 'Warning').Count
        Informations = @($all | Where-Object Severity -EQ 'Information').Count
        IsUsable     = $Config.Exists -and @($all | Where-Object Severity -EQ 'Error').Count -eq 0
    }
}

#endregion

#region Schreiben und Migration

function Set-EobIniValue {
    <#
    .SYNOPSIS
        Setzt einen INI-Wert unter Erhalt aller Kommentare, Reihenfolge und unbekannten Schlüssel.
    .DESCRIPTION
        Schreibt atomar (temporäre Datei + Replace) und legt ein Backup an. Secrets (laut Schema)
        werden nicht geschrieben.
    .PARAMETER Path
        INI-Datei.
    .PARAMETER Section
        Abschnitt (wird angelegt, falls nicht vorhanden).
    .PARAMETER Key
        Schlüssel.
    .PARAMETER Value
        Neuer Wert (einzeilig).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidatePattern('^[^\[\]\r\n]+$')][string]$Section,
        [Parameter(Mandatory)][ValidatePattern('^[^=\[\];#\r\n][^=\r\n]*$')][string]$Key,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [ValidateRange(0, 50)][int]$KeepBackups = 5
    )

    if ($Value -match '[\r\n]') {
        throw 'Mehrzeilige Werte sind nicht zulässig.'
    }
    $sectionDefinition = Get-EobSchemaSectionDefinition -Schema (Get-EobConfigSchema) -Name $Section
    if ($null -ne $sectionDefinition) {
        $keyDefinition = Get-EobSchemaKeyDefinition -SectionDefinition $sectionDefinition -Key $Key
        if ($null -ne $keyDefinition -and $keyDefinition.ContainsKey('Secret') -and $keyDefinition.Secret) {
            throw "[$Section] $Key ist als Secret klassifiziert und wird nicht in die Konfiguration geschrieben."
        }
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $content = Get-EobTextFileContent -Path $Path
        foreach ($line in ($content.Text -split "`r?`n")) { $lines.Add($line) }
        if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') { $lines.RemoveAt($lines.Count - 1) }
    }

    $sectionStart = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -match '^\[(.+)\]$' -and $Matches[1].Trim() -ieq $Section) {
            $sectionStart = $i
            break
        }
    }

    if ($sectionStart -lt 0) {
        if ($lines.Count -gt 0 -and $lines[$lines.Count - 1].Trim() -ne '') { $lines.Add('') }
        $lines.Add("[$Section]")
        $lines.Add("$Key=$Value")
    }
    else {
        $sectionEnd = $lines.Count
        for ($i = $sectionStart + 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i].Trim() -match '^\[.+\]$') { $sectionEnd = $i; break }
        }
        $updated = $false
        $lastContent = $sectionStart
        for ($i = $sectionStart + 1; $i -lt $sectionEnd; $i++) {
            $trimmed = $lines[$i].Trim()
            if ($trimmed -eq '' -or $trimmed.StartsWith(';') -or $trimmed.StartsWith('#')) { continue }
            $lastContent = $i
            $separator = $trimmed.IndexOf('=')
            if ($separator -gt 0 -and $trimmed.Substring(0, $separator).Trim() -ieq $Key) {
                $indent = $lines[$i].Substring(0, $lines[$i].Length - $lines[$i].TrimStart().Length)
                $lines[$i] = '{0}{1}={2}' -f $indent, $trimmed.Substring(0, $separator).Trim(), $Value
                $updated = $true
                break
            }
        }
        if (-not $updated) {
            $lines.Insert($lastContent + 1, "$Key=$Value")
        }
    }

    Write-EobTextFileAtomic -Path $Path -Text (($lines -join "`r`n") + "`r`n") -KeepBackups $KeepBackups
}

function Copy-EobConfigurationTemplate {
    <#
    .SYNOPSIS
        Kopiert die Beispielkonfiguration an den Zielpfad (überschreibt nie).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [string]$Destination = (Get-EobDefaultConfigurationPath),
        [string]$TemplatePath = (Join-Path -Path (Join-Path -Path (Get-EobAppRoot) -ChildPath 'Config') -ChildPath 'easyONB.ini.template')
    )

    if (Test-Path -LiteralPath $Destination) {
        throw "Die Zieldatei existiert bereits und wird nicht überschrieben: $Destination"
    }
    if (-not (Test-Path -LiteralPath $TemplatePath -PathType Leaf)) {
        throw "Vorlage nicht gefunden: $TemplatePath"
    }
    if ($PSCmdlet.ShouldProcess($Destination, 'Beispielkonfiguration kopieren')) {
        Copy-Item -LiteralPath $TemplatePath -Destination $Destination -ErrorAction Stop
    }
    return $Destination
}

function Get-EobIniBlock {
    <#
        Zerlegt INI-Text in Abschnittsblöcke inklusive vorangestellter Kommentare.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $blocks = [System.Collections.Generic.List[object]]::new()
    $pending = [System.Collections.Generic.List[string]]::new()
    $current = $null
    foreach ($line in ($Text -split "`r?`n")) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^\[(.+)\]$') {
            $current = [pscustomobject]@{ Name = $Matches[1].Trim(); Lines = [System.Collections.Generic.List[string]]::new() }
            foreach ($p in $pending) { $current.Lines.Add($p) }
            $pending.Clear()
            $current.Lines.Add($line)
            $blocks.Add($current)
        }
        elseif ($trimmed -eq '' -or $trimmed.StartsWith(';') -or $trimmed.StartsWith('#')) {
            $pending.Add($line)
        }
        elseif ($null -ne $current) {
            foreach ($p in $pending) { $current.Lines.Add($p) }
            $pending.Clear()
            $current.Lines.Add($line)
        }
    }
    if ($null -ne $current) {
        foreach ($p in $pending) { $current.Lines.Add($p) }
    }
    return $blocks.ToArray()
}

function Convert-EobLegacyConfiguration {
    <#
    .SYNOPSIS
        Migriert eine INI-Datei aus Version 1.3/1.4 in eine 3.0-kompatible Datei.
    .DESCRIPTION
        - Entfernt Klartext-Secrets (fixPassword, CompanyVPNPassword, JiraToken, SMTP-Kennwort, Webhooks)
          und ersetzt sie durch einen Kommentar ohne Wert.
        - Kommentiert SyncCommand aus (Codeausführung über Konfiguration wird nicht mehr unterstützt).
        - Ergänzt fehlende neue Abschnitte aus der Vorlage (Kommentare bleiben erhalten).
        - Alle übrigen Zeilen, Kommentare und unbekannten Schlüssel bleiben unverändert.
    .PARAMETER SourcePath
        Legacy-INI.
    .PARAMETER DestinationPath
        Ziel (wird nur mit -Force überschrieben).
    .PARAMETER TemplatePath
        Vorlage mit neuen Abschnitten.
    .OUTPUTS
        Liste der Änderungen.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$DestinationPath,
        [string]$TemplatePath = (Join-Path -Path (Join-Path -Path (Get-EobAppRoot) -ChildPath 'Config') -ChildPath 'easyONB.ini.template'),
        [switch]$Force
    )

    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
        throw "Quelldatei nicht gefunden: $SourcePath"
    }
    if ((Test-Path -LiteralPath $DestinationPath) -and -not $Force) {
        throw "Zieldatei existiert bereits: $DestinationPath (mit -Force überschreiben)."
    }

    $schema = Get-EobConfigSchema
    $changes = [System.Collections.Generic.List[object]]::new()
    $source = Get-EobTextFileContent -Path $SourcePath
    $output = [System.Collections.Generic.List[string]]::new()
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm')
    $output.Add("; Migriert mit easyONBOARDING $(Get-EobVersion) am $stamp aus '$([System.IO.Path]::GetFileName($SourcePath))'.")
    $output.Add('; Hinweise zur Migration: docs\MIGRATION.md')

    $currentSection = 'Global'
    $presentSections = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $lineNumber = 0
    foreach ($line in ($source.Text -split "`r?`n")) {
        $lineNumber++
        $trimmed = $line.Trim()
        if ($trimmed -match '^\[(.+)\]$') {
            $currentSection = $Matches[1].Trim()
            $null = $presentSections.Add($currentSection)
            $output.Add($line)
            continue
        }
        $separator = $trimmed.IndexOf('=')
        if ($trimmed -ne '' -and -not $trimmed.StartsWith(';') -and -not $trimmed.StartsWith('#') -and $separator -gt 0) {
            $key = $trimmed.Substring(0, $separator).Trim()
            $value = $trimmed.Substring($separator + 1).Trim()
            $sectionDefinition = Get-EobSchemaSectionDefinition -Schema $schema -Name $currentSection
            $keyDefinition = if ($null -ne $sectionDefinition) { Get-EobSchemaKeyDefinition -SectionDefinition $sectionDefinition -Key $key } else { $null }
            $isSecret = ($null -ne $keyDefinition -and $keyDefinition.ContainsKey('Secret') -and $keyDefinition.Secret)
            if ($isSecret) {
                if ($value -ne '') {
                    $output.Add("; [Migration $stamp] $key entfernt: Klartext-Secrets werden nicht mehr unterstützt.")
                    $changes.Add([pscustomobject]@{ Line = $lineNumber; Section = $currentSection; Key = $key; Action = 'Removed'; Message = 'Klartext-Secret entfernt.' })
                }
                else {
                    $output.Add("; [Migration $stamp] $key entfernt (nicht mehr unterstützt).")
                    $changes.Add([pscustomobject]@{ Line = $lineNumber; Section = $currentSection; Key = $key; Action = 'Removed'; Message = 'Leerer Secret-Schlüssel entfernt.' })
                }
                continue
            }
            if ($currentSection -ieq 'ADSync' -and $key -ieq 'SyncCommand') {
                $output.Add("; [Migration $stamp] SyncCommand wird nicht mehr ausgeführt (fester Befehl Start-ADSyncSyncCycle, siehe PolicyType).")
                $output.Add("; $trimmed")
                $changes.Add([pscustomobject]@{ Line = $lineNumber; Section = $currentSection; Key = $key; Action = 'CommentedOut'; Message = 'Konfigurierbarer Befehl deaktiviert.' })
                continue
            }
        }
        $output.Add($line)
    }

    if (Test-Path -LiteralPath $TemplatePath -PathType Leaf) {
        $template = Get-EobTextFileContent -Path $TemplatePath
        foreach ($block in (Get-EobIniBlock -Text $template.Text)) {
            if (-not $presentSections.Contains($block.Name)) {
                $output.Add('')
                $output.Add("; [Migration $stamp] Neuer Abschnitt aus der Vorlage ergänzt.")
                foreach ($blockLine in $block.Lines) { $output.Add($blockLine) }
                $changes.Add([pscustomobject]@{ Line = $null; Section = $block.Name; Key = $null; Action = 'AddedSection'; Message = 'Abschnitt aus Vorlage ergänzt.' })
            }
        }
    }

    if ($PSCmdlet.ShouldProcess($DestinationPath, 'Migrierte Konfiguration schreiben')) {
        $directory = Split-Path -Parent $DestinationPath
        if ($directory -and -not (Test-Path -LiteralPath $directory)) {
            $null = New-Item -ItemType Directory -Path $directory -Force
        }
        [System.IO.File]::WriteAllText($DestinationPath, (($output -join "`r`n") + "`r`n"), [System.Text.UTF8Encoding]::new($true))
    }
    return $changes.ToArray()
}

#endregion
