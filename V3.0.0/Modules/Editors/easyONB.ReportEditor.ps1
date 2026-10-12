#Requires -Version 7.2
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Initialize-EobReportEditor {
    <#
    .SYNOPSIS
        Lädt ausschließlich die lokalen Core- und Reporting-APIs, ohne Konfiguration oder Verbindungen.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    foreach ($name in @('Core', 'Reporting')) {
        Import-Module (Join-Path $Root "Modules/$name/easyONB.$name.psd1") -ErrorAction Stop
    }
}

function Get-EobEditorPlaceholder {
    <#
    .SYNOPSIS
        Liefert unterstützte Handout-Platzhalter mit ausschließlich erfundenen Vorschauwerten.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    return @{
        ReportTitle = 'Willkommen im Team'; ReportFooter = 'Example GmbH · Dein guter Start'
        ReportDate = '01.10.2026'; Admin = 'Beispiel-Administration'
        Vorname = 'Alex'; Nachname = 'Beispiel'; DisplayName = 'Alex Beispiel'
        LoginName = 'abeispiel'; MailAddress = 'alex.beispiel@example.com'; UPN = 'alex.beispiel@example.com'
        Ablaufdatum = '31.12.2026'
        Buero = 'Raum 101'; Rufnummer = '+49 30 000000'; Mobil = 'Nicht angegeben'
        Position = 'Projektassistenz'; Abteilung = 'Organisation'; License = 'Beispiellizenz'
        CompanyName = 'Example GmbH'; CompanyStreet = 'Musterweg 1'; CompanyZIP = '00000'
        CompanyCity = 'Musterstadt'; CompanyCountry = 'Deutschland'; CompanyPhone = '+49 30 000000'
        CompanyDomain = 'example.com'; CompanyMailDomain = 'example.com'; CompanyWebsite = 'https://example.com'
        CompanyFounded = '2020'; CompanyLocations = 'Musterstadt'; CompanyEmployees = '100'
        CompanyMission = 'Gemeinsam einfach arbeiten'; CompanyHRPhone = '+49 30 000001'
        CompanyHREmail = 'personal@example.com'; CompanyHelpdeskTel = '+49 30 000002'
        CompanyHelpdeskMail = 'helpdesk@example.com'; CompanyITMitarbeiter = 'Beispiel-Team'
        CompanyWikiURL = 'https://wiki.example.com'; CompanyIntranetURL = 'https://intranet.example.com'
        ITTrainingURL = 'https://training.example.com'; FAQURL = 'https://faq.example.com'
        AdminPortalURL = 'https://admin.example.com'; CompanySSID = 'Example-Intern'
        CompanySSIDbyod = 'Example-BYOD'; CompanySSIDGuest = 'Example-Gast'
        CompanyVPNDomain = 'vpn.example.com'; CompanyVPNUser = 'abeispiel'
        PasswordPolicyList = '<li>Beispiel: mindestens 12 Zeichen</li><li>Keine persönlichen Angaben</li>'
        WebsitesHTML = '<p>Intranet: https://intranet.example.com</p>'; LogoTag = ''
    }
}

function Get-EobEditorLocalPath {
    <#
    .SYNOPSIS
        Prüft lokale Dateipfade vor Zugriff; Netzwerk-Laufwerke und Reparse-Punkte sind nicht erlaubt.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)

    if ($Path.StartsWith('\\') -or $Path.StartsWith('//')) { throw 'Nur lokale Vorlagendateien sind erlaubt.' }
    $fullPath = [IO.Path]::GetFullPath($Path)
    $rootPath = [IO.Path]::GetPathRoot($fullPath)
    if ($IsWindows -and [IO.DriveInfo]::new($rootPath).DriveType -eq [IO.DriveType]::Network) {
        throw 'Netzwerk-Laufwerke sind nicht erlaubt.'
    }
    $current = $rootPath
    foreach ($part in $fullPath.Substring($rootPath.Length).Split([IO.Path]::DirectorySeparatorChar)) {
        if (-not $part) { continue }
        $current = [IO.Path]::Combine($current, $part)
        if (([IO.File]::Exists($current) -or [IO.Directory]::Exists($current)) -and
            ([IO.File]::GetAttributes($current) -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Verknüpfungen und Reparse-Punkte sind für Vorlagen nicht erlaubt.'
        }
    }
    return $fullPath
}

function Read-EobEditorTemplate {
    <#
    .SYNOPSIS
        Liest begrenzte lokale UTF-8-Vorlagen (mit oder ohne BOM); UTF-16 mit BOM ist ebenfalls lesbar.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)

    $fullPath = Get-EobEditorLocalPath -Path $Path
    $file = Get-Item -LiteralPath $fullPath -ErrorAction Stop
    if ($file.PSIsContainer -or $file.Length -gt 1MB) { throw 'Die Vorlage muss eine Datei mit höchstens 1 MiB sein.' }
    $reader = [IO.StreamReader]::new($fullPath, [Text.UTF8Encoding]::new($false, $true), $true)
    try { return $reader.ReadToEnd() }
    finally { $reader.Dispose() }
}

function Test-EobEditorTemplate {
    <#
    .SYNOPSIS
        Prüft Vorlagen auf verbotene Secret-Platzhalter und erkennbare eingetragene Zugangsdaten.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Template)

    $secrets = @([regex]::Matches($Template, '\{\{\s*([A-Za-z][A-Za-z0-9_]*)(?:\s*:\s*[^{}]*?)?\s*\}\}') |
            ForEach-Object { $_.Groups[1].Value } |
            Where-Object { $_ -match '(?i)(passw(or)?[dt]|kennwort|custompw|secret|token|pwd|credential|apikey|api_key)' -and $_ -ine 'PasswordPolicyList' } |
            Sort-Object -Unique)
    # Delimit markup for redaction: "Passwort:</p>" is a label, but attributes are still inspected.
    $plain = [Net.WebUtility]::HtmlDecode([regex]::Replace($Template, '<[^>]*>', [Text.RegularExpressions.MatchEvaluator] {
                param($tag)
                ';' + $tag.Value.Trim('<', '>') + ';'
            }))
    $redacted = Protect-EobSensitiveText -Text $plain
    # Inline styling must not separate a credential label from its visible value.
    # Block delimiters keep an empty label from consuming text in the next paragraph.
    $visible = [regex]::Replace($Template, '(?i)</?(?:p|div|br|hr|h[1-6]|table|tr|td|th|li|ul|ol|section|article|header|footer|blockquote|pre)\b[^>]*>', ';')
    $visible = [Net.WebUtility]::HtmlDecode([regex]::Replace($visible, '<[^>]*>', ''))
    $visibleRedacted = Protect-EobSensitiveText -Text $visible
    $hasSensitiveText = ($redacted -cne $plain -or $visibleRedacted -cne $visible)
    [pscustomobject]@{
        IsValid = ($secrets.Count -eq 0 -and -not $hasSensitiveText -and $Template.Length -le 1MB)
        SecretPlaceholders = $secrets
        HasSensitiveText = $hasSensitiveText
    }
}

function Save-EobEditorTemplate {
    <#
    .SYNOPSIS
        Speichert ausschließlich den Vorlagenquelltext atomar in UTF-8 mit BOM, niemals Vorschauwerte.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Template,
        [switch]$Overwrite
    )

    $check = Test-EobEditorTemplate -Template $Template
    if (-not $check.IsValid) { throw 'Speichern verweigert: Secret-Platzhalter, erkennbare Zugangsdaten oder zu große Vorlage. Keine Zugangsdaten eintragen.' }
    $fullPath = Get-EobEditorLocalPath -Path $Path
    if ([IO.File]::Exists($fullPath) -and -not $Overwrite) { throw 'Die Datei existiert bereits. Überschreiben muss bestätigt werden.' }
    if (-not $PSCmdlet.ShouldProcess($fullPath, 'Vorlage speichern')) { return }
    $staging = $fullPath + '.' + [guid]::NewGuid().ToString('N') + '.new'
    try {
        [IO.File]::WriteAllText($staging, $Template, [Text.UTF8Encoding]::new($true))
        [IO.File]::Move($staging, $fullPath, [bool]$Overwrite)
    }
    finally {
        if ([IO.File]::Exists($staging)) { [IO.File]::Delete($staging) }
    }
}

function New-EobEditorTemplate {
    <#
    .SYNOPSIS
        Erzeugt ein neues, eigenständiges Willkommenshandout ohne Zugangsdaten.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Erzeugt nur Text im Speicher.')]
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return @'
<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="utf-8">
<title>{{ReportTitle}}</title>
</head>
<body>
<h1>{{ReportTitle}}</h1>
<p>Hallo {{Vorname}}, herzlich willkommen bei {{CompanyName}}!</p>
<h2>Dein Arbeitsplatz</h2>
<p>{{DisplayName}} · {{Abteilung}} · {{Position}}</p>
<p>Anmeldename: {{LoginName}} · E-Mail: {{MailAddress}}</p>
<h2>Wir helfen dir</h2>
<p>{{CompanyHelpdeskMail}} · {{CompanyHelpdeskTel}}</p>
<h2>Sicher starten</h2>
<ul>{{PasswordPolicyList}}</ul>
<p>Zugangsdaten werden ausschließlich über einen separaten sicheren Weg übermittelt.</p>
<footer>{{ReportFooter}} · {{ReportDate}}</footer>
</body>
</html>
'@
}

function Set-EobEditorStyle {
    <#
    .SYNOPSIS
        Aktualisiert einen abgegrenzten CSS-Block und den Dokumenttitel ohne andere Inhalte zu verändern.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Erzeugt nur Text im Speicher.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Template,
        [string]$Title = '{{ReportTitle}}',
        [ValidatePattern('^#[0-9A-Fa-f]{6}$')][string]$Accent = '#2563EB',
        [ValidateSet('Segoe UI', 'Arial', 'Calibri', 'Georgia')][string]$Font = 'Segoe UI',
        [ValidateRange(9, 24)][int]$FontSize = 12,
        [ValidateRange(10, 48)][int]$Margin = 24
    )

    $style = @"
<!-- easyONB-editor-style:start -->
<style id="easyonb-editor">
:root { --primary-color: $Accent; --accent-color: $Accent; --font-family: '$Font', sans-serif; }
body { font-family: '$Font', sans-serif !important; font-size: ${FontSize}pt !important; margin: ${Margin}px !important; }
h1, h2, h3, .section-title { color: $Accent !important; }
</style>
<!-- easyONB-editor-style:end -->
"@
    $clean = [regex]::Replace($Template, '(?s)<!-- easyONB-editor-style:start -->.*?<!-- easyONB-editor-style:end -->\r?\n?', '')
    if ($clean -match '(?i)</head\s*>') {
        $clean = [regex]::new('(?i)</head\s*>').Replace($clean, [Text.RegularExpressions.MatchEvaluator] { param($m) $style + "`n" + $m.Value }, 1)
    }
    else { $clean = $style + "`n" + $clean }
    $encodedTitle = [Net.WebUtility]::HtmlEncode($Title)
    if ($clean -match '(?is)<title\b[^>]*>.*?</title\s*>') {
        return [regex]::new('(?is)<title\b[^>]*>.*?</title\s*>').Replace($clean, [Text.RegularExpressions.MatchEvaluator] { '<title>' + $encodedTitle + '</title>' }, 1)
    }
    return '<title>' + $encodedTitle + "</title>`n" + $clean
}

function Get-EobEditorStyle {
    <#
    .SYNOPSIS
        Liest validierte Gestaltungswerte aus dem eigenen CSS-Block, sonst sichere Standardwerte.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Template)

    $settings = @{ Accent = '#2563EB'; Font = 'Segoe UI'; FontSize = 12; Margin = 24 }
    $block = [regex]::Match($Template, '(?s)<!-- easyONB-editor-style:start -->(.*?)<!-- easyONB-editor-style:end -->').Groups[1].Value
    $accent = [regex]::Match($block, '--primary-color:\s*(#[0-9A-Fa-f]{6})\s*;').Groups[1].Value
    $font = [regex]::Match($block, "font-family:\s*'(Segoe UI|Arial|Calibri|Georgia)'").Groups[1].Value
    $size = [regex]::Match($block, 'font-size:\s*(\d{1,2})pt').Groups[1].Value
    $margin = [regex]::Match($block, 'margin:\s*(\d{1,2})px').Groups[1].Value
    if ($accent) { $settings.Accent = $accent }
    if ($font) { $settings.Font = $font }
    if ($size -and [int]$size -ge 9 -and [int]$size -le 24) { $settings.FontSize = [int]$size }
    if ($margin -and [int]$margin -ge 10 -and [int]$margin -le 48) { $settings.Margin = [int]$margin }
    return $settings
}

function Get-EobEditorPreviewStyle {
    <#
    .SYNOPSIS
        Liefert validierte, browserunabhängige WPF-Vorschauwerte aus dem eigenen Gestaltungsblock.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Template)

    $style = Get-EobEditorStyle -Template $Template
    $sizeDip = [double]$style.FontSize * 96 / 72
    [pscustomobject]@{
        Accent = $style.Accent
        Font = $style.Font
        FontSizeDip = $sizeDip
        TitleSizeDip = [Math]::Max(20, $sizeDip + 8)
        LineHeightDip = $sizeDip * 1.5
        Margin = [double]$style.Margin
    }
}

function ConvertTo-EobEditorPreview {
    <#
    .SYNOPSIS
        Rendert mit Expand-EobTemplate und liefert ausschließlich inaktive Zeichenketten für WPF-Text.
    .DESCRIPTION
        Kein Browser, HTML-/XAML-Parser, Bildlader oder Link. AssetDataUri wird vor der Expansion
        entfernt: Vorschauen lesen auch keine von einer fremden Vorlage angeforderten Assets.
        CSS, Bilder und Layout werden nicht interpretiert; die Textansicht ist keine Druckvorschau.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Template)

    if ($Template.Length -gt 1MB) { throw 'Die Vorschau ist auf 1 MiB begrenzt.' }
    $safeTemplate = [regex]::Replace($Template, '(?i)\{\{\s*AssetDataUri(?:\s*:\s*[^{}]*?)?\s*\}\}', '')
    $result = Expand-EobTemplate -Template $safeTemplate -Values (Get-EobEditorPlaceholder) -SecretHint '[Zugangsdaten werden nicht angezeigt]'
    $warnings = [Collections.Generic.List[string]]::new()
    foreach ($warning in $result.Warnings) { $warnings.Add([string]$warning) }
    if ($safeTemplate -cne $Template) { $warnings.Add('Bilder/Assets werden in der sicheren Textvorschau nicht geladen.') }
    if ($result.MissingPlaceholders.Count -gt 0) { $warnings.Add('Fehlende Beispielwerte: ' + ($result.MissingPlaceholders -join ', ')) }
    if ($result.SecretPlaceholders.Count -gt 0) { $warnings.Add('Verbotene Secret-Platzhalter: ' + ($result.SecretPlaceholders -join ', ')) }
    $check = Test-EobEditorTemplate -Template $Template
    if (-not $check.IsValid) { $warnings.Add('Speichern gesperrt: keine Zugangsdaten oder Secret-Platzhalter zulässig.') }
    $html = Protect-EobSensitiveText -Text $result.Content
    $titleMatch = [regex]::Match($html, '(?is)<title\b[^>]*>(.*?)</title\s*>')
    $title = Protect-EobSensitiveText -Text ([Net.WebUtility]::HtmlDecode([regex]::Replace($titleMatch.Groups[1].Value, '<[^>]*>', '')))
    $text = [regex]::Replace($html, '(?is)<(head|script|style|iframe|object|svg)\b[^>]*>.*?</\1\s*>', '')
    $text = [regex]::Replace($text, '(?s)<!--.*?-->', '')
    $text = [regex]::Replace($text, '(?i)<\s*(?:br|hr)\b[^>]*>|</\s*(?:p|div|h[1-6]|tr|li|section|footer)\s*>', "`n")
    $text = [regex]::Replace($text, '(?i)</\s*(?:td|th)\s*>', '   ')
    $text = [regex]::Replace($text, '<[^>]*>', '')
    $text = Protect-EobSensitiveText -Text ([Net.WebUtility]::HtmlDecode($text))
    $text = [regex]::Replace($text, '[ \t]+', ' ')
    $text = [regex]::Replace($text, '(?:\r?\n\s*){3,}', "`n`n").Trim()
    [pscustomobject]@{ Title = $title; Text = $text; Warnings = $warnings.ToArray(); CanSave = $check.IsValid }
}
