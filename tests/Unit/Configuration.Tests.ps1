#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.3.0' }

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath '../TestHelpers.ps1')
    Import-EobTestModule

    $script:AppRoot = Get-EobTestRepoRoot
    $script:TemplatePath = Join-Path $script:AppRoot 'Config/easyONB.ini.template'

    function New-TestConfigDirectory {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Testhilfe im TestDrive bzw. im Speicher.')]
        param([string]$MainContent, [hashtable]$Templates = @{}, [hashtable]$Companies = @{})
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'templates') -Force
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'companies') -Force
        foreach ($name in $Templates.Keys) { Set-Content -LiteralPath (Join-Path $root "templates/$name") -Value $Templates[$name] -Encoding utf8 }
        foreach ($name in $Companies.Keys) { Set-Content -LiteralPath (Join-Path $root "companies/$name") -Value $Companies[$name] -Encoding utf8 }
        $main = Join-Path $root 'easyONB.ini'
        if ($null -ne $MainContent) { Set-Content -LiteralPath $main -Value $MainContent -Encoding utf8 }
        return $main
    }

    $script:MinimalIni = @'
[ADUserDefaults]
DefaultOU=OU=Users,DC=example,DC=local

[Company]
CompanyNameFirma=Example GmbH
CompanyActiveDirectoryDomain=example.com
CompanyMailDomain=@example.com
'@
}

Describe 'INI-Parser (Legacy-kompatibel)' {
    It 'liest Abschnitte, Schlüssel und Werte mit Gleichheitszeichen' {
        $path = Join-Path $TestDrive 'a.ini'
        Set-Content -LiteralPath $path -Encoding utf8 -Value @'
; Kommentar
# Kommentar
[Websites]
EmployeeLink1=Intranet | https://intranet.example.com/?a=b | Portal
[Leer]
'@
        $ini = Read-EobIniFile -Path $path
        $ini.Sections['Websites']['EmployeeLink1'] | Should -Be 'Intranet | https://intranet.example.com/?a=b | Portal'
        $ini.Sections.Contains('Leer') | Should -BeTrue
        $ini.Sections['websites']['employeelink1'] | Should -Not -BeNullOrEmpty
    }

    It 'ordnet Schlüssel vor dem ersten Abschnitt dem Abschnitt Global zu' {
        $path = Join-Path $TestDrive 'b.ini'
        Set-Content -LiteralPath $path -Value "Frei=1`n[A]`nx=2" -Encoding utf8
        (Read-EobIniFile -Path $path).Sections['Global']['Frei'] | Should -Be '1'
    }

    It 'meldet doppelte Schlüssel und ungültige Zeilen' {
        $path = Join-Path $TestDrive 'c.ini'
        Set-Content -LiteralPath $path -Value "[A]`nx=1`nx=2`nkein schluessel" -Encoding utf8
        $ini = Read-EobIniFile -Path $path
        $ini.Sections['A']['x'] | Should -Be '2'
        @($ini.Duplicates).Count | Should -Be 1
        @($ini.InvalidLines).Count | Should -Be 1
    }

    It 'erkennt BOM, UTF-16 und Windows-1252' {
        $utf8Bom = Join-Path $TestDrive 'bom.ini'
        [System.IO.File]::WriteAllText($utf8Bom, "[Company]`nCompanyOrt=München", [System.Text.UTF8Encoding]::new($true))
        (Read-EobIniFile -Path $utf8Bom).Sections['Company']['CompanyOrt'] | Should -Be 'München'

        $utf16 = Join-Path $TestDrive 'utf16.ini'
        [System.IO.File]::WriteAllText($utf16, "[Company]`nCompanyOrt=Köln", [System.Text.UnicodeEncoding]::new($false, $true))
        (Read-EobIniFile -Path $utf16).Sections['Company']['CompanyOrt'] | Should -Be 'Köln'

        $ansi = Join-Path $TestDrive 'ansi.ini'
        [System.IO.File]::WriteAllBytes($ansi, [System.Text.Encoding]::GetEncoding(1252).GetBytes("[Company]`r`nCompanyOrt=Düsseldorf"))
        $ini = Read-EobIniFile -Path $ansi
        $ini.Encoding | Should -Be 'windows-1252'
        $ini.Sections['Company']['CompanyOrt'] | Should -Be 'Düsseldorf'
    }
}

Describe 'Schema' {
    It 'definiert für jeden Schlüssel Typ und Beschreibung und gültige Standardwerte' {
        $schema = Get-EobConfigSchema
        $definitions = foreach ($sectionName in $schema.Sections.Keys) {
            $section = $schema.Sections[$sectionName]
            if ($section.ContainsKey('Keys')) {
                foreach ($key in $section.Keys.Keys) { [pscustomobject]@{ Name = "$sectionName.$key"; Definition = $section.Keys[$key] } }
            }
        }
        foreach ($pattern in $schema.SectionPatterns) {
            if ($pattern.ContainsKey('Keys')) {
                foreach ($key in $pattern.Keys.Keys) { [pscustomobject]@{ Name = "$($pattern.Name).$key"; Definition = $pattern.Keys[$key] } }
            }
        }
        foreach ($item in $definitions) {
            $item.Definition.ContainsKey('Type') | Should -BeTrue -Because $item.Name
            $item.Definition.ContainsKey('Description') | Should -BeTrue -Because $item.Name
            if ($item.Definition.Type -eq 'Enum') { $item.Definition.ContainsKey('Values') | Should -BeTrue -Because $item.Name }
            if ($item.Definition.ContainsKey('Default')) {
                Test-EobConfigValueType -Definition $item.Definition -Value ([string]$item.Definition.Default) | Should -BeNullOrEmpty -Because "Standardwert von $($item.Name)"
            }
        }
    }
}

Describe 'Beispielkonfiguration' {
    It 'lädt die mitgelieferte Vorlage ohne Fehler und Warnungen' {
        $config = Import-EobConfiguration -Path $script:TemplatePath
        $config.Exists | Should -BeTrue
        # Die Befunde erscheinen bei einem Fehlschlag direkt in der Pester-Meldung.
        @($config.Findings | Where-Object { $_.Severity -in @('Error', 'Warning') } | ForEach-Object { "[$($_.Severity)] $($_.Code) $($_.Message)" }) | Should -BeNullOrEmpty
    }

    It 'enthält die sieben geforderten Offboarding-Vorlagen' {
        $config = Import-EobConfiguration -Path $script:TemplatePath
        $names = @(Get-EobConfigSectionName -Config $config -Pattern '^OffboardingTemplate\.')
        foreach ($expected in 'Standard', 'SofortigeSperrung', 'Befristet', 'Extern', 'Ruhestand', 'InternerWechsel', 'Testmodus') {
            $names | Should -Contain "OffboardingTemplate.$expected"
        }
    }

    It 'enthält keine realen Domänen des Legacy-Beispiels' {
        $content = Get-Content -LiteralPath $script:TemplatePath -Raw
        $content | Should -Not -Match '(?i)phinit|psscripts|phscripts|servertrends|ms365insights'
        $content | Should -Not -Match '(?im)^\s*fixPassword\s*='
    }
}

Describe 'Kompatibilität mit Legacy-Konfigurationen' {
    It 'liest die INI der Version <Version> ohne Abbruch und ignoriert das feste Kennwort' -ForEach @(
        @{ Version = '1.3.10'; RelativePath = '../V1.3.10/easyONB.ini' }
        @{ Version = '1.4.23'; RelativePath = '../V1.4.XX/assets/easyONB.ini' }
    ) {
        $legacyPath = Join-Path $script:AppRoot $RelativePath
        if (-not (Test-Path -LiteralPath $legacyPath)) {
            Set-ItResult -Skipped -Because 'Legacy-Ordner nicht vorhanden'
            return
        }
        $config = Import-EobConfiguration -Path $legacyPath -NoIncludes
        $config.Exists | Should -BeTrue
        @($config.Findings | Where-Object Code -EQ 'CFG_SECRET_IN_FILE' | Where-Object Field -Like 'PasswordFixGenerate.fixPassword').Count | Should -Be 1
        Get-EobConfigValue -Config $config -Section 'PasswordFixGenerate' -Key 'fixPassword' | Should -BeNullOrEmpty
        $company = Get-EobCompany -Config $config | Select-Object -First 1
        $company.UpnSuffix | Should -Not -BeNullOrEmpty
        $company.DefaultOU | Should -Match 'DC='
        @(Get-EobConfigSection -Config $config -Name 'ADGroups').Count | Should -BeGreaterThan 0
    }
}

Describe 'Laden und Zusammenführen' {
    It 'liefert bei fehlender Datei ein Objekt mit Fehlerbefund statt einer Exception' {
        $config = Import-EobConfiguration -Path (Join-Path $TestDrive 'fehlt/easyONB.ini')
        $config.Exists | Should -BeFalse
        $config.Findings.Code | Should -Contain 'CFG_FILE_NOT_FOUND'
    }

    It 'führt templates, companies und Haupt-INI in dieser Reihenfolge zusammen' {
        $main = New-TestConfigDirectory -MainContent ($script:MinimalIni + "`n[Offboarding]`nDefaultTemplate=Eigen`n") `
            -Templates @{ 't.ini' = "[Offboarding]`nDefaultTemplate=Vorlage`nRequireTicket=0" } `
            -Companies @{ 'c1.ini' = "[Company1]`nCompanyNameFirma=Zweite GmbH`nCompanyActiveDirectoryDomain1=zweite.example.com" }
        $config = Import-EobConfiguration -Path $main
        Get-EobConfigValue -Config $config -Section 'Offboarding' -Key 'DefaultTemplate' | Should -Be 'Eigen'
        Get-EobConfigValue -Config $config -Section 'Offboarding' -Key 'RequireTicket' -As Bool | Should -BeFalse
        @(Get-EobCompany -Config $config).Count | Should -Be 2
        $config.Findings.Code | Should -Contain 'CFG_OVERRIDDEN'
    }

    It 'meldet unbekannte Abschnitte und Schlüssel, verwirft sie aber nicht' {
        $main = New-TestConfigDirectory -MainContent ($script:MinimalIni + "`n[EigenerAbschnitt]`nFoo=Bar`n[Logging]`nUnbekannt=1`n")
        $config = Import-EobConfiguration -Path $main
        $config.Findings.Code | Should -Contain 'CFG_UNKNOWN_SECTION'
        $config.Findings.Code | Should -Contain 'CFG_UNKNOWN_KEY'
        $config.Sections['EigenerAbschnitt']['Foo'] | Should -Be 'Bar'
    }

    It 'prüft die Zertifikatsanmeldung auf Format und Vollständigkeit, ohne sie als Secret zu werten' {
        $complete = "`n[Exchange]`nMode=Online`nAppId=11111111-2222-3333-4444-555555555555`nCertificateThumbprint=0123456789ABCDEF0123456789ABCDEF01234567`nOrganization=example.onmicrosoft.com`n"
        $config = Import-EobConfiguration -Path (New-TestConfigDirectory -MainContent ($script:MinimalIni + $complete))
        @($config.Findings | Where-Object { $_.Field -like 'Exchange.*' }) | Should -BeNullOrEmpty

        # Gültige, aber unvollständige Angaben: Warnung statt stillem Rückfall auf die interaktive Anmeldung.
        $partial = "`n[Graph]`nEnabled=1`nClientId=11111111-2222-3333-4444-555555555555`n"
        $config = Import-EobConfiguration -Path (New-TestConfigDirectory -MainContent ($script:MinimalIni + $partial))
        @($config.Findings | Where-Object { $_.Field -like 'Graph.*' } | ForEach-Object Code) | Should -Contain 'CFG_CERTIFICATE_AUTH_INCOMPLETE'

        # Ungültige Formate werden als ungültiger Wert gemeldet, nicht als Secret.
        $invalid = "`n[Graph]`nEnabled=1`nClientId=keine-guid`nCertificateThumbprint=1234`n"
        $config = Import-EobConfiguration -Path (New-TestConfigDirectory -MainContent ($script:MinimalIni + $invalid))
        $codes = @($config.Findings | Where-Object { $_.Field -like 'Graph.*' } | ForEach-Object Code)
        @($codes | Where-Object { $_ -eq 'CFG_INVALID_VALUE' }).Count | Should -Be 2
        $codes | Should -Not -Contain 'CFG_SECRET_IN_FILE'
    }

    It 'meldet Secrets, auch in unbekannten Schlüsseln' {
        $main = New-TestConfigDirectory -MainContent ($script:MinimalIni + "`n[CompanyVPN]`nCompanyVPNPassword=Geheim!1`n[Eigen]`nApiToken=abc123456`n")
        $config = Import-EobConfiguration -Path $main
        @($config.Findings | Where-Object Code -EQ 'CFG_SECRET_IN_FILE').Count | Should -Be 2
        ($config.Findings.Message -join ' ') | Should -Not -Match 'Geheim!1|abc123456'
    }
}

Describe 'Fachliche Validierung' {
    It 'erkennt <Name>' -ForEach @(
        @{ Name = 'fehlende Unternehmen'; Ini = "[ADUserDefaults]`nDefaultOU=OU=U,DC=example,DC=local"; Code = 'CFG_NO_COMPANY' }
        @{ Name = 'fehlenden UPN-Suffix'; Ini = "[ADUserDefaults]`nDefaultOU=OU=U,DC=example,DC=local`n[Company]`nCompanyNameFirma=X"; Code = 'CFG_COMPANY_NO_UPN' }
        @{ Name = 'fehlende Ziel-OU'; Ini = "[Company]`nCompanyActiveDirectoryDomain=example.com"; Code = 'CFG_COMPANY_NO_OU' }
        @{ Name = 'unmögliche Kennwortrichtlinie'; Ini = "[PasswordFixGenerate]`nDefaultPasswordLength=12`nMinUpperCase=5`nMinLowerCase=5`nMinDigits=5"; Code = 'CFG_PASSWORD_POLICY' }
        @{ Name = 'Löschung ohne Aufbewahrungsfrist'; Ini = "[OffboardingTemplate.X]`nDisplayName=X`nRetentionDays=0`nAction.DeleteAccount=FinalDeletion"; Code = 'CFG_DELETION_WITHOUT_RETENTION' }
        @{ Name = 'Löschung in falscher Phase'; Ini = "[OffboardingTemplate.X]`nDisplayName=X`nRetentionDays=30`nAction.DeleteAccount=Immediate"; Code = 'CFG_DELETION_WRONG_PHASE' }
        @{ Name = 'Verschieben ohne Ziel-OU'; Ini = "[OffboardingTemplate.X]`nDisplayName=X`nAction.MoveToOU=ExitDate"; Code = 'CFG_MOVE_WITHOUT_OU' }
        @{ Name = 'unbekannte Offboarding-Aktion'; Ini = "[OffboardingTemplate.X]`nDisplayName=X`nAction.Zaubern=ExitDate"; Code = 'CFG_UNKNOWN_ACTION' }
        @{ Name = 'Vorlage ohne Anzeigenamen'; Ini = "[OffboardingTemplate.X]`nAction.DisableAccount=Immediate"; Code = 'CFG_MISSING_KEY' }
        @{ Name = 'ungültigen DN'; Ini = "[ADUserDefaults]`nDefaultOU=Benutzer"; Code = 'CFG_INVALID_VALUE' }
        @{ Name = 'ungültigen Enum-Wert'; Ini = "[Identity]`nCollisionStrategy=Zufall"; Code = 'CFG_INVALID_VALUE' }
    ) {
        $main = New-TestConfigDirectory -MainContent $Ini
        $config = Import-EobConfiguration -Path $main
        $config.Findings.Code | Should -Contain $Code
    }
}

Describe 'Typisierter Zugriff' {
    BeforeAll {
        $main = New-TestConfigDirectory -MainContent ($script:MinimalIni + @'

[Logging]
DebugMode=1
RetentionDays=abc
[Security]
ProtectedAccounts=admin1; admin2 ;
ProtectedOUs=OU=Admins,DC=example,DC=local;OU=Service,DC=example,DC=local
[Report]
ReportPath=Berichte
'@)
        $script:Config = Import-EobConfiguration -Path $main
    }

    It 'liefert Schema-Standardwerte für fehlende oder ungültige Werte' {
        Get-EobConfigValue -Config $script:Config -Section 'Logging' -Key 'RetentionDays' -As Int | Should -Be 90
        Get-EobConfigValue -Config $script:Config -Section 'Identity' -Key 'CollisionStrategy' | Should -Be 'AppendNumber'
        Get-EobConfigValue -Config $script:Config -Section 'Security' -Key 'SimulationByDefault' -As Bool | Should -BeTrue
    }

    It 'bevorzugt einen explizit übergebenen Standardwert' {
        Get-EobConfigValue -Config $script:Config -Section 'Nirgends' -Key 'X' -Default 'y' | Should -Be 'y'
    }

    It 'trennt Listen ausschließlich am Semikolon (DNs enthalten Kommas)' {
        $accounts = @(Get-EobConfigValue -Config $script:Config -Section 'Security' -Key 'ProtectedAccounts' -As List)
        $accounts | Should -Be @('admin1', 'admin2')
        $ous = @(Get-EobConfigValue -Config $script:Config -Section 'Security' -Key 'ProtectedOUs' -As List)
        $ous.Count | Should -Be 2
        $ous[0] | Should -Be 'OU=Admins,DC=example,DC=local'
    }

    It 'löst Pfade relativ zur Anwendungswurzel auf' {
        Get-EobConfigValue -Config $script:Config -Section 'Report' -Key 'ReportPath' -As Path |
            Should -Be ([System.IO.Path]::GetFullPath((Join-Path (Get-EobAppRoot) 'Berichte')))
    }

    It 'bildet DebugMode auf das Loglevel Debug ab' {
        (Get-EobLoggingParameter -Config $script:Config).MinimumLevel | Should -Be 'Debug'
    }
}

Describe 'Unternehmen und Mail-Domänen' {
    It 'löst Legacy-Schlüssel mit Abschnittssuffix und OU-Fallback auf' {
        $main = New-TestConfigDirectory -MainContent @'
[ADUserDefaults]
DefaultOU=OU=Standard,DC=example,DC=local
[Company]
CompanyNameFirma=Haupt GmbH
CompanyActiveDirectoryDomain=@example.com
CompanyMailDomain=@example.com
CompanyCountry=DE
[Company2]
CompanyNameFirma2=Tochter GmbH
CompanyActiveDirectoryDomain2=tochter.example.com
CompanyActiveDirectoryDomain=falsch.example.com
CompanyActiveDirectoryOU2=OU=Tochter,DC=example,DC=local
CompanyCountry=AT
[MailEndungen]
Domain1=@example.com
Domain2=@Example.NET
Domain3=kein domain
'@
        $config = Import-EobConfiguration -Path $main
        $companies = @(Get-EobCompany -Config $config)
        $companies.Id | Should -Be @('Company', 'Company2')
        $companies[0].UpnSuffix | Should -Be 'example.com'
        $companies[0].DefaultOU | Should -Be 'OU=Standard,DC=example,DC=local'
        $companies[1].DisplayName | Should -Be 'Tochter GmbH'
        $companies[1].UpnSuffix | Should -Be 'tochter.example.com'
        $companies[1].DefaultOU | Should -Be 'OU=Tochter,DC=example,DC=local'
        $companies[1].Country | Should -Be 'AT'
        @(Get-EobMailDomain -Config $config) | Should -Be @('example.com', 'example.net')
    }
}

Describe 'Kommentarerhaltendes Schreiben' {
    BeforeEach {
        $script:IniPath = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.ini')
        Set-Content -LiteralPath $script:IniPath -Encoding utf8 -Value @'
; Kopfkommentar
[Logging]
; Kommentar zum Level
MinimumLevel=Information
Unbekannt=bleibt

[UI]
Theme=Light
'@
    }

    It 'aktualisiert Werte und erhält Kommentare, Reihenfolge und unbekannte Schlüssel' {
        Set-EobIniValue -Path $script:IniPath -Section 'logging' -Key 'minimumlevel' -Value 'Warning' -Confirm:$false
        $content = Get-Content -LiteralPath $script:IniPath
        $content | Should -Contain '; Kopfkommentar'
        $content | Should -Contain '; Kommentar zum Level'
        $content | Should -Contain 'MinimumLevel=Warning'
        $content | Should -Contain 'Unbekannt=bleibt'
        [array]::IndexOf($content, 'MinimumLevel=Warning') | Should -BeLessThan ([array]::IndexOf($content, 'Unbekannt=bleibt'))
    }

    It 'ergänzt fehlende Schlüssel im Abschnitt und fehlende Abschnitte am Ende' {
        Set-EobIniValue -Path $script:IniPath -Section 'UI' -Key 'AccentColor' -Value '#112233' -Confirm:$false
        Set-EobIniValue -Path $script:IniPath -Section 'Bulk' -Key 'MaxRows' -Value '100' -Confirm:$false
        $config = Import-EobConfiguration -Path $script:IniPath -NoIncludes
        $config.Sections['UI']['AccentColor'] | Should -Be '#112233'
        $config.Sections['Bulk']['MaxRows'] | Should -Be '100'
    }

    It 'legt ein Backup an und schreibt mit -WhatIf nichts' {
        $before = Get-Content -LiteralPath $script:IniPath -Raw
        Set-EobIniValue -Path $script:IniPath -Section 'UI' -Key 'Theme' -Value 'Dark' -WhatIf
        Get-Content -LiteralPath $script:IniPath -Raw | Should -Be $before
        Set-EobIniValue -Path $script:IniPath -Section 'UI' -Key 'Theme' -Value 'Dark' -Confirm:$false
        @(Get-ChildItem -LiteralPath $TestDrive -Filter '*.bak').Count | Should -BeGreaterThan 0
    }

    It 'verweigert das Schreiben von Secrets und mehrzeiligen Werten' {
        { Set-EobIniValue -Path $script:IniPath -Section 'PasswordFixGenerate' -Key 'fixPassword' -Value 'x' -Confirm:$false } | Should -Throw '*Secret*'
        { Set-EobIniValue -Path $script:IniPath -Section 'UI' -Key 'Theme' -Value "a`nb" -Confirm:$false } | Should -Throw
    }
}

Describe 'Legacy-Migration' {
    BeforeEach {
        $script:Source = Join-Path $TestDrive 'legacy.ini'
        Set-Content -LiteralPath $script:Source -Encoding utf8 -Value @'
[PasswordFixGenerate]
; Standardkennwort
fixPassword=Sehr!Geheim99
DefaultPasswordLength=15
[CompanyVPN]
CompanyVPNPassword=VpnGeheim77
[ADSync]
SyncCommand=Start-ADSyncSyncCycle -PolicyType Delta; Remove-Item C:\x
[EigenerAbschnitt]
Bleibt=ja
'@
        $script:Destination = Join-Path $TestDrive ('migriert-' + [guid]::NewGuid().ToString('N') + '.ini')
    }

    It 'entfernt Klartext-Secrets vollständig und kommentiert SyncCommand aus' {
        $changes = Convert-EobLegacyConfiguration -SourcePath $script:Source -DestinationPath $script:Destination -TemplatePath $script:TemplatePath -Confirm:$false
        $content = Get-Content -LiteralPath $script:Destination -Raw
        $content | Should -Not -Match 'Sehr!Geheim99'
        $content | Should -Not -Match 'VpnGeheim77'
        $content | Should -Match '(?m)^; SyncCommand=Start-ADSyncSyncCycle'
        $content | Should -Match 'Bleibt=ja'
        @($changes | Where-Object Action -EQ 'Removed').Count | Should -Be 2
        @($changes | Where-Object Action -EQ 'CommentedOut').Count | Should -Be 1
    }

    It 'ergänzt neue Abschnitte aus der Vorlage und liefert eine ladbare Datei' {
        $null = Convert-EobLegacyConfiguration -SourcePath $script:Source -DestinationPath $script:Destination -TemplatePath $script:TemplatePath -Confirm:$false
        $config = Import-EobConfiguration -Path $script:Destination -NoIncludes
        $config.Sections.Contains('Security') | Should -BeTrue
        $config.Sections.Contains('Offboarding') | Should -BeTrue
        $config.Sections['PasswordFixGenerate']['DefaultPasswordLength'] | Should -Be '15'
        @($config.Findings | Where-Object Code -EQ 'CFG_SECRET_IN_FILE').Count | Should -Be 0
    }

    It 'überschreibt ein vorhandenes Ziel nur mit -Force' {
        Set-Content -LiteralPath $script:Destination -Value 'vorhanden'
        { Convert-EobLegacyConfiguration -SourcePath $script:Source -DestinationPath $script:Destination -TemplatePath $script:TemplatePath -Confirm:$false } | Should -Throw '*existiert bereits*'
    }

    It 'Scripts/Convert-LegacyConfiguration.ps1 simuliert mit -WhatIf und lässt die Quelle unverändert' {
        $script = Join-Path $script:AppRoot 'Scripts/Convert-LegacyConfiguration.ps1'
        $hash = (Get-FileHash -LiteralPath $script:Source).Hash
        & $script -SourcePath $script:Source -DestinationPath $script:Destination -WhatIf
        Test-Path -LiteralPath $script:Destination | Should -BeFalse
        $changes = @(& $script -SourcePath $script:Source -DestinationPath $script:Destination -InformationAction SilentlyContinue)
        $changes.Key | Should -Contain 'fixPassword'
        $changes.Key | Should -Contain 'SyncCommand'
        (Get-Content -LiteralPath $script:Destination -Raw) | Should -Not -Match 'Sehr!Geheim99'
        (Get-FileHash -LiteralPath $script:Source).Hash | Should -Be $hash
        { & $script -SourcePath $script:Source -DestinationPath $script:Source } | Should -Throw '*identisch*'
    }
}
