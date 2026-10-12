#Requires -Version 7.2
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.3.0' }
<#
.SYNOPSIS
    Headless-Tests des Konfigurationsstudios und bedingter Windows/STA-WPF-Ladetest.
#>
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

BeforeDiscovery {
    $script:CanLoadEditorWpf = $IsWindows -and [Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA'
}

BeforeAll {
    $script:EditorRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    foreach ($module in @('Core', 'Configuration', 'Setup')) {
        Import-Module (Join-Path $script:EditorRoot "Modules/$module/easyONB.$module.psd1") -Force
    }
    . (Join-Path $script:EditorRoot 'Modules/Editors/easyONB.ConfigEditor.ps1')

    function New-TestEditorDocument {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Erzeugt ausschließlich Testdateien im isolierten Pester-TestDrive.')]
        [CmdletBinding()]
        param([string]$Extra = '')
        $path = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.ini')
        $text = "; Kommentar bleibt`n[Company]`nCompanyNameFirma=Example GmbH`nCompanyActiveDirectoryDomain=example.com`nCompanyMailDomain=@example.com`n[ADUserDefaults]`nDefaultOU=OU=People,DC=example,DC=com`n" + $Extra
        [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($true))
        Import-EobEditorDocument -Path $path
    }
}

Describe 'Konfigurationsstudio – Dokumente und Schema' {
    It 'öffnet die echte Vorlage ohne Includes und markiert neue Dokumente als ungespeichert' {
        $document = Import-EobEditorDocument -Path (Join-Path $script:EditorRoot 'Config/easyONB.ini.template') -AsTemplate
        $document.Path | Should -Be ''
        $document.Dirty | Should -BeTrue
        $document.Config.Sources.Count | Should -Be 1
        @(Get-EobEditorField -Document $document).Count | Should -BeGreaterThan 100
        @((Get-EobEditorField -Document $document) | Where-Object Key -EQ 'fixPassword').Count | Should -Be 0
        @((Test-EobEditorDocument -Document $document) | Where-Object Severity -EQ 'Error').Count | Should -Be 0
    }

    It 'zeigt boolesche, Enum- und beschriebene Felder sowie Kennwortrichtlinien ohne Secret-Eingaben' {
        $fields = @(Get-EobEditorField -Document (New-TestEditorDocument))
        ($fields | Where-Object { $_.Section -eq 'Security' -and $_.Key -eq 'AllowManualPassword' }).Type | Should -Be 'Bool'
        ($fields | Where-Object { $_.Section -eq 'UI' -and $_.Key -eq 'Theme' }).Options | Should -Contain 'Dark'
        foreach ($field in $fields) { $field.Description | Should -Not -BeNullOrEmpty }
    }

    It 'erhält und bearbeitet dynamische, freie und unbekannte Werte sowie Kommentare und globale Schlüssel' {
        $document = New-TestEditorDocument -Extra "[Company2]`nCompanyNameFirma=Example Zwei`nCompanyActiveDirectoryDomain=example.org`nCompanyMailDomain=@example.org`n[Websites]`nPortal=https://example.com/`n[EigeneErweiterung]`nWert=a=b`n"
        $document.SourceText = "VorAbschnitt=unverändert`n" + $document.SourceText
        $document.Config.Sections['Global'] = [ordered]@{ VorAbschnitt = 'unverändert' }
        Set-EobEditorValue -Document $document -Section 'EigeneErweiterung' -Key 'Wert' -Value 'neu=ja'
        Set-EobEditorValue -Document $document -Section 'Global' -Key 'VorAbschnitt' -Value 'bearbeitet'
        $fields = @(Get-EobEditorField -Document $document)
        @($fields | Where-Object Section -EQ 'Company2').Count | Should -BeGreaterThan 0
        @($fields | Where-Object Section -EQ 'Websites').Key | Should -Contain 'Portal'
        $target = Join-Path $TestDrive 'preserved.ini'
        Save-EobEditorDocument -Document $document -Path $target -AcceptWarnings -Confirm:$false
        $saved = Import-EobEditorDocument -Path $target
        $saved.Config.Sections['Company2']['CompanyNameFirma'] | Should -Be 'Example Zwei'
        $saved.Config.Sections['Websites']['Portal'] | Should -Be 'https://example.com/'
        $saved.Config.Sections['EigeneErweiterung']['Wert'] | Should -Be 'neu=ja'
        $saved.Config.Sections['Global']['VorAbschnitt'] | Should -Be 'bearbeitet'
        $saved.SourceText | Should -Match '; Kommentar bleibt'
        $saved.SourceText | Should -Not -Match '\[Global\]'
        [IO.File]::ReadAllBytes($target)[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
        $document.Dirty | Should -BeFalse
        $document.Path | Should -Be $target
    }

    It 'schreibt fehlende Schemafelder nicht automatisch und setzt Dirty nur bei Änderungen' {
        $document = New-TestEditorDocument
        Set-EobEditorValue -Document $document -Section 'Company' -Key 'CompanyNameFirma' -Value 'Example GmbH'
        $document.Dirty | Should -BeFalse
        Set-EobEditorValue -Document $document -Section 'Company' -Key 'CompanyNameFirma' -Value 'Example AG'
        $document.Dirty | Should -BeTrue
        $target = Join-Path $TestDrive 'minimal.ini'
        Save-EobEditorDocument -Document $document -Path $target -AcceptWarnings -Confirm:$false
        (Get-Content -LiteralPath $target -Raw) | Should -Not -Match '\[UI\]'
    }

    It 'öffnet keine weiteren Dateien aus companies oder templates' {
        $document = New-TestEditorDocument
        $folder = Join-Path (Split-Path -Parent $document.Path) 'companies'
        $null = New-Item -Path $folder -ItemType Directory -Force
        [IO.File]::WriteAllText((Join-Path $folder 'other.ini'), "[Company]`nCompanyNameFirma=Nicht laden")
        (Import-EobEditorDocument -Path $document.Path).Config.Sections['Company']['CompanyNameFirma'] | Should -Be 'Example GmbH'
    }
}

Describe 'Konfigurationsstudio – Prüfung und sicheres Speichern' {
    It 'blockiert ungültige Schematypen und Fachregeln vor jedem Schreibzugriff' {
        $document = New-TestEditorDocument
        Set-EobEditorValue -Document $document -Section 'Logging' -Key 'RetentionDays' -Value '0'
        Set-EobEditorValue -Document $document -Section 'Company' -Key 'CompanyActiveDirectoryDomain' -Value ''
        $findings = @(Test-EobEditorDocument -Document $document)
        @($findings | Where-Object { $_.Code -eq 'CFG_INVALID_VALUE' -and $_.Severity -eq 'Error' }).Count | Should -Be 1
        @($findings | Where-Object Code -EQ 'CFG_COMPANY_NO_UPN').Count | Should -Be 1
        $target = Join-Path $TestDrive 'invalid.ini'
        { Save-EobEditorDocument -Document $document -Path $target -AcceptWarnings -Confirm:$false } | Should -Throw '*Fehler*'
        Test-Path -LiteralPath $target | Should -BeFalse
        $document.Dirty | Should -BeTrue
    }

    It 'fordert Warnungsbestätigung an und respektiert WhatIf' {
        $document = New-TestEditorDocument
        $target = Join-Path $TestDrive 'warnings.ini'
        { Save-EobEditorDocument -Document $document -Path $target -Confirm:$false } | Should -Throw '*Warnungen*'
        Save-EobEditorDocument -Document $document -Path $target -AcceptWarnings -WhatIf
        Test-Path -LiteralPath $target | Should -BeFalse
    }

    It 'sichert vorhandene Dateien atomar und erhält das Dokument bei Schreibfehlern' {
        $document = New-TestEditorDocument
        $previous = $document.SourceText
        Set-EobEditorValue -Document $document -Section 'Company' -Key 'CompanyNameFirma' -Value 'Example AG'
        Save-EobEditorDocument -Document $document -Path $document.Path -AcceptWarnings -Confirm:$false
        $backups = @(Get-ChildItem -LiteralPath $TestDrive -Filter ((Split-Path -Leaf $document.Path) + '.*.bak'))
        $backups.Count | Should -Be 1
        (Get-Content -LiteralPath $backups[0].FullName -Raw) | Should -Be $previous
        Set-EobEditorValue -Document $document -Section 'Company' -Key 'CompanyNameFirma' -Value 'Example Neu'
        $path = $document.Path
        { Save-EobEditorDocument -Document $document -Path (Join-Path $TestDrive 'missing/out.ini') -AcceptWarnings -Confirm:$false } | Should -Throw '*Zielverzeichnis*'
        $document.Dirty | Should -BeTrue
        $document.Path | Should -Be $path
    }

    It 'meldet doppelte Schlüssel und fehlerhafte Zeilen beim Laden' {
        $document = New-TestEditorDocument -Extra "[EigeneErweiterung]`nK=alt`nK=neu`nkeine INI-Zeile`n"
        $document.Config.Sections['EigeneErweiterung']['K'] | Should -Be 'neu'
        @(Test-EobEditorDocument -Document $document).Code | Should -Contain 'CFG_DUPLICATE_KEY'
        @(Test-EobEditorDocument -Document $document).Code | Should -Contain 'CFG_INVALID_LINE'
    }

    It 'blockiert Secrets in bekannten und unbekannten Feldern sowie überschriebenen Duplikaten' {
        foreach ($extra in @(
                "[PasswordFix]`nfixPassword=$([guid]::NewGuid())`n"
                "[EigeneErweiterung]`nApiToken=$([guid]::NewGuid())`n"
                "[EigeneErweiterung]`nApiToken=$([guid]::NewGuid())`nApiToken=`n"
            )) {
            { New-TestEditorDocument -Extra $extra } | Should -Throw '*Zugangsdaten*'
        }
    }

    It 'blockiert eingebettete Secrets in URLs, Verbindungsdaten und Kommentaren' {
        foreach ($extra in @(
                "[EigeneErweiterung]`nLink=https://user:$([guid]::NewGuid())@example.com/`n"
                ("[EigeneErweiterung]`nVerbindung=Server=example.com;" + 'pwd' + '=' + [guid]::NewGuid() + ";`n")
                ('; ' + 'ApiToken' + '=' + [guid]::NewGuid())
            )) {
            { New-TestEditorDocument -Extra $extra } | Should -Throw '*Zugangsdaten*'
        }
    }

    It 'blockiert Secret-Eingaben und mehrzeilige Werte, bis die Eingabe korrigiert wird' {
        $document = New-TestEditorDocument -Extra "[EigeneErweiterung]`nWert=normal`n"
        $unsafe = 'ApiToken' + '=' + [guid]::NewGuid()
        { Set-EobEditorValue -Document $document -Section 'EigeneErweiterung' -Key 'Wert' -Value $unsafe } | Should -Throw '*Zugangsdaten*'
        @(Test-EobEditorDocument -Document $document).Code | Should -Contain 'EDITOR_INPUT_ERROR'
        { Save-EobEditorDocument -Document $document -Path (Join-Path $TestDrive 'unsafe.ini') -AcceptWarnings -Confirm:$false } | Should -Throw '*Fehler*'
        Set-EobEditorValue -Document $document -Section 'EigeneErweiterung' -Key 'Wert' -Value 'sicher'
        { Set-EobEditorValue -Document $document -Section 'EigeneErweiterung' -Key 'Wert' -Value "a`nb" } | Should -Throw '*INI-Zeile*'
        Set-EobEditorValue -Document $document -Section 'EigeneErweiterung' -Key 'Wert' -Value 'normal'
        @((Test-EobEditorDocument -Document $document) | Where-Object Severity -EQ 'Error').Count | Should -Be 0
    }

    It 'prüft direkt manipulierte Werte erneut und gibt Secrets nicht in Befunden aus' {
        $document = New-TestEditorDocument -Extra "[EigeneErweiterung]`nWert=normal`n"
        $unsafe = [guid]::NewGuid().ToString()
        $document.Config.Sections['EigeneErweiterung']['ApiToken'] = $unsafe
        $findings = @(Test-EobEditorDocument -Document $document)
        $findings.Code | Should -Contain 'EDITOR_UNSAFE_VALUE'
        ($findings.Message -join ' ') | Should -Not -Match ([regex]::Escape($unsafe))
    }

    It 'meldet fehlende Dateien und falsche Zielendungen' {
        { Import-EobEditorDocument -Path (Join-Path $TestDrive 'absent.ini') } | Should -Throw
        { Save-EobEditorDocument -Document (New-TestEditorDocument) -Path (Join-Path $TestDrive 'out.txt') -AcceptWarnings -Confirm:$false } | Should -Throw '*.ini*'
    }
}

Describe 'Konfigurationsstudio – WPF' {
    It 'hat wohlgeformte XAML ohne Code-Behind und alle benannten Bedienelemente' {
        $text = Get-Content -LiteralPath (Join-Path $script:EditorRoot 'GUI/Editors/ConfigEditor.xaml') -Raw
        { [xml]$text } | Should -Not -Throw
        $text | Should -Not -Match 'x:Class=| Click=| Loaded='
        foreach ($name in @('NewButton', 'OpenButton', 'ValidateButton', 'SaveButton', 'SaveAsButton', 'SectionList', 'SearchBox', 'FieldPanel', 'FindingsBox', 'FileLabel', 'StatusLabel')) {
            $text | Should -Match ('x:Name="ConfigEditor' + $name + '"')
        }

    }

    It 'lädt die echte WPF-Oberfläche ohne Anzeige unter Windows/STA' -Skip:(-not $script:CanLoadEditorWpf) {
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
        $window = [Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText((Join-Path $script:EditorRoot 'GUI/Editors/ConfigEditor.xaml')))
        $window.FindName('ConfigEditorFieldPanel') | Should -Not -BeNullOrEmpty
        $window.FindName('ConfigEditorSaveButton').Content | Should -Be '_Speichern'
        $window.Close()
    }
}

Describe 'Konfigurationsstudio – explizite Include-Fragmente' {
    It 'bearbeitet und speichert ausgelieferte Rollen- und Offboarding-Fragmente ohne Company hinzuzufügen' {
        foreach ($name in @('role-templates.ini', 'offboarding-templates.ini')) {
            $document = Import-EobEditorDocument -Path (Join-Path $script:EditorRoot "Config/templates/$name") -Fragment
            $document.Fragment | Should -BeTrue
            $section = @($document.Config.Sections.Keys)[0]
            Set-EobEditorValue -Document $document -Section $section -Key 'DisplayName' -Value 'Angepasste Vorlage'
            $findings = @(Test-EobEditorDocument -Document $document)
            @($findings | Where-Object Severity -EQ 'Error').Count | Should -Be 0
            $findings.Code | Should -Contain 'EDITOR_FRAGMENT_MODE'
            $target = Join-Path $TestDrive $name
            Save-EobEditorDocument -Document $document -Path $target -AcceptWarnings -Confirm:$false
            $document.Fragment | Should -BeTrue
            $saved = Import-EobEditorDocument -Path $target -Fragment
            $saved.Config.Sections.Contains('Company') | Should -BeFalse
            $saved.Config.Sections[$section]['DisplayName'] | Should -Be 'Angepasste Vorlage'
            $saved.SourceText | Should -Match ';'
        }
    }

    It 'verlangt im unveränderten Hauptmodus weiterhin Company und blockiert das Speichern' {
        $document = Import-EobEditorDocument -Path (Join-Path $script:EditorRoot 'Config/templates/role-templates.ini')
        $document.Fragment | Should -BeFalse
        @(Test-EobEditorDocument -Document $document).Code | Should -Contain 'CFG_NO_COMPANY'
        { Save-EobEditorDocument -Document $document -Path (Join-Path $TestDrive 'main.ini') -AcceptWarnings -Confirm:$false } | Should -Throw '*Fehler*'
    }

    It 'blockiert ungültige Typen und fehlende Pflichtschlüssel auch im Fragmentmodus' {
        $document = Import-EobEditorDocument -Path (Join-Path $script:EditorRoot 'Config/templates/offboarding-templates.ini') -Fragment
        Set-EobEditorValue -Document $document -Section 'OffboardingTemplate.Standard' -Key 'RetentionDays' -Value 'keine Zahl'
        Set-EobEditorValue -Document $document -Section 'OffboardingTemplate.Standard' -Key 'DisplayName' -Value ''
        $findings = @(Test-EobEditorDocument -Document $document)
        @($findings | Where-Object { $_.Code -eq 'CFG_INVALID_VALUE' -and $_.Severity -eq 'Error' }).Count | Should -BeGreaterThan 0
        $findings.Code | Should -Contain 'CFG_MISSING_KEY'
        { Save-EobEditorDocument -Document $document -Path (Join-Path $TestDrive 'invalid-fragment.ini') -AcceptWarnings -Confirm:$false } | Should -Throw '*Fehler*'
    }

    It 'behält lokale Lösch- und Aufbewahrungsregeln im Fragmentmodus bei' {
        $document = Import-EobEditorDocument -Path (Join-Path $script:EditorRoot 'Config/templates/offboarding-templates.ini') -Fragment
        Set-EobEditorValue -Document $document -Section 'OffboardingTemplate.Standard' -Key 'RetentionDays' -Value '0'
        @(Test-EobEditorDocument -Document $document).Code | Should -Contain 'CFG_DELETION_WITHOUT_RETENTION'
        Set-EobEditorValue -Document $document -Section 'OffboardingTemplate.Standard' -Key 'Action.DeleteAccount' -Value 'Immediate'
        @(Test-EobEditorDocument -Document $document).Code | Should -Contain 'CFG_DELETION_WRONG_PHASE'
    }

    It 'blockiert Secret-Felder und eingebettete Zugangsdaten auch im Fragmentmodus' {
        $path = Join-Path $TestDrive 'secret-fragment.ini'
        [IO.File]::WriteAllText($path, "[EigenerAbschnitt]`nApiToken=$([guid]::NewGuid())`n")
        { Import-EobEditorDocument -Path $path -Fragment } | Should -Throw '*Zugangsdaten*'
        $document = Import-EobEditorDocument -Path (Join-Path $script:EditorRoot 'Config/templates/role-templates.ini') -Fragment
        $document.Config.Sections['EigenerAbschnitt'] = [ordered]@{ ApiToken = [guid]::NewGuid().ToString() }
        @(Test-EobEditorDocument -Document $document).Code | Should -Contain 'EDITOR_UNSAFE_VALUE'
        { Save-EobEditorDocument -Document $document -Path (Join-Path $TestDrive 'unsafe-fragment.ini') -AcceptWarnings -Confirm:$false } | Should -Throw '*Fehler*'
    }
}
