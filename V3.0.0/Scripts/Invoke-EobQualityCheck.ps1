#Requires -Version 7.2
<#
.SYNOPSIS
    Statische Qualitätsprüfungen für easyONBOARDING 3 (lokal und in der CI).

.DESCRIPTION
    Prüfungen (Parameter -Check, Standard: alle):
    - Parser     PowerShell-Dateien ohne Syntaxfehler.
    - Encoding   PowerShell-Dateien in UTF-8 mit BOM, ohne Tabulatoren und Leerzeichen am Zeilenende.
    - Xaml       XAML-Dateien wohlgeformt, ohne x:Class und ohne Ereignisattribute (Code-Behind).
    - Analyzer   PSScriptAnalyzer mit PSScriptAnalyzerSettings.psd1; jeder Befund zählt als Fehler.
    - Secrets    Keine Schlüssel, Tokens oder Kennwörter im Repository, keine Platzhalter wie
                 "yourdomain", in Beispieldateien nur reservierte Domains (example.com usw.).
    - Docs       Pflichtdokumente vorhanden, relative Markdown-Links gültig, keine offenen Platzhalter.
    - Version    VERSION = ModuleVersion aller Manifeste = oberster CHANGELOG-Eintrag = README.

    Projektdateien (README.md, CHANGELOG.md, SECURITY.md, CONTRIBUTING.md, VERSION) dürfen im
    Anwendungsverzeichnis oder im Repository-Stamm (-RepositoryRoot) liegen.

    Das Skript ändert keine Dateien und benötigt außer PSScriptAnalyzer (nur für -Check Analyzer)
    keine weiteren Module. In GitHub Actions werden Befunde zusätzlich als Annotationen ausgegeben.

.PARAMETER Check
    Auszuführende Prüfungen (Parser, Encoding, Xaml, Analyzer, Secrets, Docs, Version), auch als
    kommagetrennte Liste.

.PARAMETER Root
    Anwendungsverzeichnis (Standard: übergeordnetes Verzeichnis von Scripts).

.PARAMETER RepositoryRoot
    Repository-Stamm für die Projektdateien (Standard: übergeordnetes Verzeichnis von -Root).

.PARAMETER PassThru
    Gibt die Befunde als Objekte zurück, statt sie auszugeben und den Exitcode zu setzen.

.EXAMPLE
    pwsh -File ./Scripts/Invoke-EobQualityCheck.ps1

.EXAMPLE
    pwsh -File ./Scripts/Invoke-EobQualityCheck.ps1 -Check Secrets,Version

.NOTES
    Autor: Andreas Hepp (PHINIT.DE)
    Exitcode: 0 = keine Befunde, 1 = Befunde vorhanden.
#>
[CmdletBinding()]
param(
    [string[]]$Check = @('Parser', 'Encoding', 'Xaml', 'Analyzer', 'Secrets', 'Docs', 'Version'),
    [string]$Root = (Split-Path -Parent $PSScriptRoot),
    [string]$RepositoryRoot,
    [switch]$PassThru
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$Root = (Resolve-Path -LiteralPath $Root).ProviderPath
if (-not $RepositoryRoot) { $RepositoryRoot = Split-Path -Parent $Root }
$script:ProjectFiles = @('README.md', 'CHANGELOG.md', 'SECURITY.md', 'CONTRIBUTING.md', 'VERSION')
# pwsh -File übergibt "-Check A,B" als einen String; Listen daher selbst zerlegen.
$allowedChecks = @('Parser', 'Encoding', 'Xaml', 'Analyzer', 'Secrets', 'Docs', 'Version')
$Check = @($Check | ForEach-Object { $_ -split '[,;\s]+' } | Where-Object { $_ })
$unknown = @($Check | Where-Object { $_ -notin $allowedChecks })
if ($unknown.Count -gt 0) {
    throw "Unbekannte Prüfung(en): $($unknown -join ', '). Erlaubt: $($allowedChecks -join ', ')."
}
$script:PowerShellExtensions = @('.ps1', '.psm1', '.psd1')
$script:TextExtensions = @('.ps1', '.psm1', '.psd1', '.xaml', '.ini', '.template', '.example', '.txt', '.md', '.html', '.htm',
    '.css', '.json', '.csv', '.yml', '.yaml', '.xml', '.config', '.gitignore')
# Laufzeitverzeichnisse (siehe .gitignore) werden nie geprüft.
$script:IgnoredDirectories = @('.git', 'Logs', 'Reports', 'Data', 'TestResults')

function New-QualityFinding {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Erzeugt nur ein Objekt im Speicher.')]
    param([string]$Check, [string]$File, [int]$Line = 0, [string]$Message)
    [pscustomobject]@{
        PSTypeName = 'Eob.QualityFinding'
        Check      = $Check
        File       = $File
        Line       = $Line
        Message    = $Message
    }
}

function Get-ProjectFilePath {
    <#
        Projektdatei im Anwendungsverzeichnis, sonst im Repository-Stamm (Pfad im Anwendungsverzeichnis, falls keine existiert).
    #>
    param([string]$Name)
    $local = Join-Path -Path $Root -ChildPath $Name
    if (Test-Path -LiteralPath $local -PathType Leaf) { return $local }
    if ($RepositoryRoot) {
        $shared = Join-Path -Path $RepositoryRoot -ChildPath $Name
        if (Test-Path -LiteralPath $shared -PathType Leaf) { return $shared }
    }
    return $local
}

function Get-RelativePath {
    param([string]$Path)
    return [System.IO.Path]::GetRelativePath($Root, $Path).Replace('\', '/')
}

function Get-RepositoryFile {
    param([string[]]$Extension)
    Get-ChildItem -LiteralPath $Root -Recurse -File -Force | Where-Object {
        $relative = Get-RelativePath -Path $_.FullName
        $first = ($relative -split '/')[0]
        $first -notin $script:IgnoredDirectories -and
        ($_.Extension -in $Extension -or ($_.Name -eq '.gitignore' -and '.gitignore' -in $Extension))
    } | Sort-Object -Property FullName
}

function Test-ParserCheck {
    foreach ($file in Get-RepositoryFile -Extension $script:PowerShellExtensions) {
        $tokens = $null
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
        foreach ($parseError in @($errors)) {
            New-QualityFinding -Check 'Parser' -File (Get-RelativePath -Path $file.FullName) -Line $parseError.Extent.StartLineNumber -Message $parseError.Message
        }
    }
}

function Test-EncodingCheck {
    foreach ($file in Get-RepositoryFile -Extension $script:PowerShellExtensions) {
        $relative = Get-RelativePath -Path $file.FullName
        $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
        if ($bytes.Length -lt 3 -or $bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF) {
            New-QualityFinding -Check 'Encoding' -File $relative -Message 'Datei ist nicht in UTF-8 mit BOM gespeichert.'
        }
        try {
            $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes)
        }
        catch {
            New-QualityFinding -Check 'Encoding' -File $relative -Message 'Datei enthält ungültige UTF-8-Zeichen.'
            continue
        }
        $number = 0
        foreach ($line in ($text -split '\r?\n')) {
            $number++
            if ($line.Contains("`t")) {
                New-QualityFinding -Check 'Encoding' -File $relative -Line $number -Message 'Tabulator gefunden (Einrückung mit 4 Leerzeichen).'
            }
            if ($line -match '[ \t]+$') {
                New-QualityFinding -Check 'Encoding' -File $relative -Line $number -Message 'Leerzeichen am Zeilenende.'
            }
        }
    }
}

function Test-XamlCheck {
    foreach ($file in Get-RepositoryFile -Extension @('.xaml')) {
        $relative = Get-RelativePath -Path $file.FullName
        $text = [System.IO.File]::ReadAllText($file.FullName)
        try {
            $document = [System.Xml.XmlDocument]::new()
            $document.LoadXml($text)
        }
        catch {
            New-QualityFinding -Check 'Xaml' -File $relative -Message "XAML ist nicht wohlgeformt: $($_.Exception.Message)"
            continue
        }
        if ($text -match '\bx:Class\s*=') {
            New-QualityFinding -Check 'Xaml' -File $relative -Message 'x:Class ist nicht erlaubt (kein Code-Behind).'
        }
        foreach ($match in [regex]::Matches($text, '\s(Click|Checked|Unchecked|Loaded|SelectionChanged|TextChanged|KeyDown|MouseDoubleClick)\s*=')) {
            New-QualityFinding -Check 'Xaml' -File $relative -Message "Ereignisattribut '$($match.Groups[1].Value)' ist nicht erlaubt; Ereignisse werden im Modul verbunden."
        }
    }
}

function Test-AnalyzerCheck {
    if (-not (Get-Module -ListAvailable -Name 'PSScriptAnalyzer')) {
        New-QualityFinding -Check 'Analyzer' -File '' -Message 'PSScriptAnalyzer ist nicht installiert (Install-PSResource PSScriptAnalyzer -Scope CurrentUser).'
        return
    }
    # In der CI wird die Version über EOB_PSSA_VERSION festgelegt (reproduzierbare Ergebnisse).
    if ($env:EOB_PSSA_VERSION) {
        Import-Module -Name 'PSScriptAnalyzer' -RequiredVersion $env:EOB_PSSA_VERSION -ErrorAction Stop
    }
    else {
        Import-Module -Name 'PSScriptAnalyzer' -ErrorAction Stop
    }
    $settings = Join-Path -Path $Root -ChildPath 'PSScriptAnalyzerSettings.psd1'
    $analyzerErrors = @()
    $records = Invoke-ScriptAnalyzer -Path $Root -Recurse -Settings $settings -ErrorVariable analyzerErrors -ErrorAction SilentlyContinue
    if (@($analyzerErrors).Count -gt 0) {
        # PSScriptAnalyzer führt Regeln parallel aus und stürzt dabei sporadisch intern ab (z. B.
        # NullReferenceException), ohne dass der Code einen Befund hat. Ein solcher Lauf ist
        # unvollständig und wird genau einmal vollständig wiederholt; tritt der Fehler erneut auf,
        # zählt er als Befund. Regelbefunde werden nie wiederholt oder verworfen.
        Write-Warning ('PSScriptAnalyzer meldete {0} interne(n) Fehler ({1}); die Analyse wird einmal wiederholt.' -f @($analyzerErrors).Count, $analyzerErrors[0].Exception.Message)
        $analyzerErrors = @()
        $records = Invoke-ScriptAnalyzer -Path $Root -Recurse -Settings $settings -ErrorVariable analyzerErrors -ErrorAction SilentlyContinue
    }
    foreach ($record in @($records)) {
        $file = if ($record.ScriptPath) { Get-RelativePath -Path $record.ScriptPath } else { '' }
        New-QualityFinding -Check 'Analyzer' -File $file -Line ([int]$record.Line) -Message ('{0} ({1}): {2}' -f $record.RuleName, $record.Severity, $record.Message)
    }
    foreach ($analyzerError in @($analyzerErrors)) {
        New-QualityFinding -Check 'Analyzer' -File '' -Message "Interner Fehler von PSScriptAnalyzer: $($analyzerError.Exception.Message)"
    }
}

function Test-SecretCheck {
    # Muster mit hoher Trefferwahrscheinlichkeit für echte Geheimnisse.
    $secretPatterns = [ordered]@{
        'Privater Schlüssel'           = '-----BEGIN [A-Z ]*PRIVATE KEY-----'
        'AWS-Zugriffsschlüssel'        = '\bAKIA[0-9A-Z]{16}\b'
        'GitHub-Token'                 = '\b(gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,})'
        'Slack-Token'                  = '\bxox[abprs]-[A-Za-z0-9-]{10,}'
        'Azure-Speicherschlüssel'      = 'AccountKey=[A-Za-z0-9+/=]{40,}'
        'JSON Web Token'               = '\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
        'Kennwort in Verbindungsdaten' = '(?i)\b(password|pwd)=[^;\s"''$]{4,};'
    }
    # CHANGEME nur in Großbuchstaben (Platzhalterkonvention); "changeme" steht in der Liste schwacher Kennwörter.
    $placeholderPattern = '(?i)\byour(user(name)?|domain|company|server|tenant|github)\b|support@your|(?-i:\bCHANGEME\b)'
    # Beispiel- und Vorlagendateien: nur reservierte Domains (RFC 2606) bzw. .local.
    $exampleRoots = @('Config/', 'ReportTemplates/', 'Tests/Fixtures/')
    $allowedDomain = '(?i)^([a-z0-9-]+\.)*example\.(com|net|org|local)$|\.(invalid|test|example|localhost)$'
    # Dokumente, die den Altstand zitieren (Bestandsaufnahme, Änderungsprotokoll), und dieses Skript
    # selbst (enthält die Suchmuster). Die Muster für echte Geheimnisse gelten für alle Dateien.
    $self = Get-RelativePath -Path $PSCommandPath
    $placeholderExceptions = @('docs/ANALYSIS.md', 'CHANGELOG.md', $self)

    foreach ($file in Get-RepositoryFile -Extension $script:TextExtensions) {
        $relative = Get-RelativePath -Path $file.FullName
        $lines = [System.IO.File]::ReadAllLines($file.FullName)
        $isIni = $file.Extension -in @('.ini', '.template', '.example')
        $isExample = @($exampleRoots | Where-Object { $relative.StartsWith($_) }).Count -gt 0
        $isPowerShell = $file.Extension -in $script:PowerShellExtensions
        $isTest = $relative.StartsWith('Tests/')
        for ($index = 0; $index -lt $lines.Length; $index++) {
            $line = $lines[$index]
            $number = $index + 1
            foreach ($name in $secretPatterns.Keys) {
                if ($line -match $secretPatterns[$name]) {
                    New-QualityFinding -Check 'Secrets' -File $relative -Line $number -Message "Mögliches Geheimnis: $name."
                }
            }
            if ($relative -notin $placeholderExceptions -and $line -match $placeholderPattern) {
                New-QualityFinding -Check 'Secrets' -File $relative -Line $number -Message "Platzhalter gefunden: '$($Matches[0])'."
            }
            if ($isIni -and $line -match '^\s*(?<key>[A-Za-z0-9_.]*(Password|Passwort|Kennwort|Secret|Token|ApiKey|Pwd))\s*=\s*(?<value>.*?)\s*$') {
                if ($Matches['value'] -notmatch '^(?i)(|0|1|true|false|on|off|yes|no|immediate|exitdate|retention)$') {
                    New-QualityFinding -Check 'Secrets' -File $relative -Line $number -Message "Konfigurationsschlüssel '$($Matches['key'])' enthält einen Wert; Geheimnisse gehören nicht in Konfigurationsdateien."
                }
            }
            if ($isPowerShell -and -not $isTest -and $relative -ne $self) {
                if ($line -match 'ConvertTo-SecureString\b.*-AsPlainText') {
                    New-QualityFinding -Check 'Secrets' -File $relative -Line $number -Message 'ConvertTo-SecureString -AsPlainText im Anwendungscode.'
                }
                if ($line -match '(?i)\$\w*(password|passwort|kennwort|secret|token|apikey)\s*=\s*[''"][^''"$]{4,}[''"]') {
                    New-QualityFinding -Check 'Secrets' -File $relative -Line $number -Message 'Fest codierter Kennwort- oder Tokenwert.'
                }
            }
            if ($isExample -and -not $isPowerShell) {
                foreach ($match in [regex]::Matches($line, '(?i)[a-z0-9._%+-]+@(?<domain>[a-z0-9-]+(\.[a-z0-9-]+)+)')) {
                    if ($match.Groups['domain'].Value -notmatch $allowedDomain) {
                        New-QualityFinding -Check 'Secrets' -File $relative -Line $number -Message "Beispieldatei enthält eine nicht reservierte Domain: '$($match.Groups['domain'].Value)'."
                    }
                }
                foreach ($match in [regex]::Matches($line, '(?i)\bDC=(?<part>[a-z0-9-]+)')) {
                    if ($match.Groups['part'].Value -notmatch '^(?i)(example|local|com|net|org|test|invalid)$') {
                        New-QualityFinding -Check 'Secrets' -File $relative -Line $number -Message "Beispieldatei enthält eine nicht reservierte Domänenkomponente: 'DC=$($match.Groups['part'].Value)'."
                    }
                }
            }
        }
    }
}

function Test-DocumentationCheck {
    $required = @('docs/INSTALLATION.md', 'docs/CONFIGURATION.md', 'docs/ONBOARDING.md', 'docs/OFFBOARDING.md',
        'docs/MIGRATION.md', 'docs/TESTING.md', 'docs/CONFIGURATION-REFERENCE.md', 'ReportTemplates/README.md')
    foreach ($name in $script:ProjectFiles) {
        if (-not (Test-Path -LiteralPath (Get-ProjectFilePath -Name $name) -PathType Leaf)) {
            New-QualityFinding -Check 'Docs' -File $name -Message 'Pflichtdokument fehlt.'
        }
    }
    foreach ($name in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path -Path $Root -ChildPath $name) -PathType Leaf)) {
            New-QualityFinding -Check 'Docs' -File $name -Message 'Pflichtdokument fehlt.'
        }
    }
    $architecture = Join-Path -Path $Root -ChildPath 'docs/ARCHITECTURE.md'
    $contributing = Get-ProjectFilePath -Name 'CONTRIBUTING.md'
    if (-not (Test-Path -LiteralPath $architecture -PathType Leaf) -and
        (-not (Test-Path -LiteralPath $contributing -PathType Leaf) -or
        [System.IO.File]::ReadAllText($contributing) -notmatch '(?m)^## Architektur\s*$')) {
        New-QualityFinding -Check 'Docs' -File 'CONTRIBUTING.md' -Message 'Pflichtdokument zur Architektur fehlt (docs/ARCHITECTURE.md oder Abschnitt Architektur in CONTRIBUTING.md).'
    }
    # Die Konfigurationsreferenz wird aus dem Schema erzeugt und muss aktuell sein.
    $generator = Join-Path -Path $Root -ChildPath 'Scripts/Export-EobConfigurationReference.ps1'
    $reference = Join-Path -Path $Root -ChildPath 'docs/CONFIGURATION-REFERENCE.md'
    if ((Test-Path -LiteralPath $generator -PathType Leaf) -and (Test-Path -LiteralPath $reference -PathType Leaf)) {
        $expected = (& $generator -Root $Root -PassThru) -replace '\r\n', "`n"
        $actual = ([System.IO.File]::ReadAllText($reference)) -replace '\r\n', "`n"
        if ($expected -ne $actual) {
            New-QualityFinding -Check 'Docs' -File 'docs/CONFIGURATION-REFERENCE.md' -Message 'Veraltet: mit Scripts/Export-EobConfigurationReference.ps1 neu erzeugen.'
        }
    }
    # Markdown im Anwendungsverzeichnis sowie Projektdokumente im Repository-Stamm
    $markdown = @(Get-RepositoryFile -Extension @('.md'))
    foreach ($name in @($script:ProjectFiles | Where-Object { $_ -like '*.md' })) {
        $path = Get-ProjectFilePath -Name $name
        if ((Test-Path -LiteralPath $path -PathType Leaf) -and -not $path.StartsWith($Root + [System.IO.Path]::DirectorySeparatorChar)) { $markdown += Get-Item -LiteralPath $path }
    }
    foreach ($file in $markdown) {
        $relative = Get-RelativePath -Path $file.FullName
        $lines = [System.IO.File]::ReadAllLines($file.FullName)
        $inCode = $false
        for ($index = 0; $index -lt $lines.Length; $index++) {
            $line = $lines[$index]
            if ($line.TrimStart().StartsWith('```')) {
                $inCode = -not $inCode
                continue
            }
            if ($inCode) { continue }
            if ($line -match '\b(TODO|TBD|FIXME|Lorem ipsum)\b') {
                New-QualityFinding -Check 'Docs' -File $relative -Line ($index + 1) -Message "Offener Platzhalter '$($Matches[1])'."
            }
            foreach ($match in [regex]::Matches($line, '\]\((?<target>[^)\s]+)\)')) {
                $target = $match.Groups['target'].Value
                if ($target -match '^(https?:|mailto:|#)') { continue }
                $pathPart = [System.Uri]::UnescapeDataString(($target -split '#')[0])
                if (-not $pathPart) { continue }
                $resolved = [System.IO.Path]::GetFullPath((Join-Path -Path $file.DirectoryName -ChildPath $pathPart))
                if (-not (Test-Path -LiteralPath $resolved)) {
                    New-QualityFinding -Check 'Docs' -File $relative -Line ($index + 1) -Message "Link-Ziel nicht gefunden: '$target'."
                }
            }
        }
    }
}

function Test-VersionCheck {
    $versionFile = Get-ProjectFilePath -Name 'VERSION'
    if (-not (Test-Path -LiteralPath $versionFile -PathType Leaf)) {
        New-QualityFinding -Check 'Version' -File 'VERSION' -Message 'Datei VERSION fehlt.'
        return
    }
    $version = ([System.IO.File]::ReadAllText($versionFile)).Trim()
    if ($version -notmatch '^\d+\.\d+\.\d+$') {
        New-QualityFinding -Check 'Version' -File 'VERSION' -Message "Ungültige Version '$version' (erwartet: Major.Minor.Patch)."
        return
    }
    foreach ($manifest in Get-ChildItem -LiteralPath (Join-Path -Path $Root -ChildPath 'Modules') -Recurse -Filter '*.psd1' -File) {
        $data = Import-PowerShellDataFile -LiteralPath $manifest.FullName
        if ([string]$data['ModuleVersion'] -ne $version) {
            New-QualityFinding -Check 'Version' -File (Get-RelativePath -Path $manifest.FullName) -Message "ModuleVersion '$($data['ModuleVersion'])' weicht von VERSION '$version' ab."
        }
    }
    $changelog = Get-ProjectFilePath -Name 'CHANGELOG.md'
    if (Test-Path -LiteralPath $changelog -PathType Leaf) {
        $first = Select-String -LiteralPath $changelog -Pattern '^## \[(?<version>\d+\.\d+\.\d+)\]' | Select-Object -First 1
        if ($null -eq $first -or $first.Matches[0].Groups['version'].Value -ne $version) {
            New-QualityFinding -Check 'Version' -File 'CHANGELOG.md' -Message "Der oberste Eintrag im CHANGELOG entspricht nicht der Version '$version'."
        }
    }
    $readme = Get-ProjectFilePath -Name 'README.md'
    if ((Test-Path -LiteralPath $readme -PathType Leaf) -and -not (Select-String -LiteralPath $readme -SimpleMatch -Pattern $version -Quiet)) {
        New-QualityFinding -Check 'Version' -File 'README.md' -Message "README.md nennt die Version '$version' nicht."
    }
}

$checkFunctions = @{
    Parser   = 'Test-ParserCheck'
    Encoding = 'Test-EncodingCheck'
    Xaml     = 'Test-XamlCheck'
    Analyzer = 'Test-AnalyzerCheck'
    Secrets  = 'Test-SecretCheck'
    Docs     = 'Test-DocumentationCheck'
    Version  = 'Test-VersionCheck'
}
$findings = [System.Collections.Generic.List[object]]::new()
foreach ($name in $Check) {
    $started = [System.Diagnostics.Stopwatch]::StartNew()
    $result = @(& $checkFunctions[$name])
    foreach ($finding in $result) { $findings.Add($finding) }
    if (-not $PassThru) {
        $state = if ($result.Count -eq 0) { 'OK' } else { "$($result.Count) Befund(e)" }
        Write-Information -MessageData ('{0,-9} {1} ({2:n1} s)' -f $name, $state, $started.Elapsed.TotalSeconds) -InformationAction Continue
    }
}

if ($PassThru) {
    return $findings.ToArray()
}

foreach ($finding in $findings) {
    $location = if ($finding.Line -gt 0) { "$($finding.File):$($finding.Line)" } else { $finding.File }
    Write-Information -MessageData "[$($finding.Check)] $location - $($finding.Message)" -InformationAction Continue
    if ($env:GITHUB_ACTIONS -eq 'true') {
        # Annotationen erwarten Pfade relativ zum Repository (GITHUB_WORKSPACE).
        $workspace = if ($env:GITHUB_WORKSPACE) { $env:GITHUB_WORKSPACE } else { $Root }
        $filePath = if ($finding.File) { [System.IO.Path]::GetRelativePath($workspace, (Join-Path -Path $Root -ChildPath $finding.File)).Replace('\', '/') } else { '' }
        $message = $finding.Message -replace '%', '%25' -replace "`r", '%0D' -replace "`n", '%0A'
        Write-Information -MessageData "::error file=$filePath,line=$([Math]::Max(1, $finding.Line)),title=$($finding.Check)::$message" -InformationAction Continue
    }
}
if ($findings.Count -gt 0) {
    Write-Information -MessageData "Qualitätsprüfung fehlgeschlagen: $($findings.Count) Befund(e)." -InformationAction Continue
    exit 1
}
Write-Information -MessageData 'Qualitätsprüfung bestanden.' -InformationAction Continue
exit 0
