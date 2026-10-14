#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.3.0' }

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath '../TestHelpers.ps1')
    Import-EobTestModule

    $script:RepModule = 'easyONB.Reporting'
    $script:TemplateIni = Join-Path (Get-EobTestRepoRoot) 'Config/easyONB.ini.template'

    function script:New-TestConfig {
        param([string]$Content = '')
        $path = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.ini')
        Set-Content -LiteralPath $path -Value $Content -Encoding utf8
        return Import-EobConfiguration -Path $path -NoIncludes
    }

    function script:New-TestPlan {
        param([pscustomobject]$Config)
        $context = New-EobOperationContext -Kind 'Onboarding'
        $plan = New-EobPlan -Kind 'Onboarding' -Context $context -Config $Config -Subject @{ SamAccountName = 'mmustermann'; DisplayName = 'Max Mustermann' }
        $plan.Summary['Anzeigename'] = 'Max Mustermann'
        $plan.Summary['Gruppen'] = '=HYPERLINK("http://boese.example")'
        $plan.Secrets['InitialPassword'] = New-EobTestSecureString -Value $script:Secret
        $step = Add-EobPlanStep -Plan $plan -Action 'CreateUser' -Title 'Benutzerkonto <script>alert(1)</script>' -Target 'mmustermann' -Handler 'New-EobAdUserAccount' `
            -Parameters @{ AccountPassword = '@Secret:InitialPassword'; SamAccountName = 'mmustermann' } -Details @('Ziel-OU: OU=Mitarbeiter,DC=example,DC=local')
        $step.Status = 'Succeeded'
        $step.Message = "Konto angelegt (Kennwort $script:Secret)"
        $step2 = Add-EobPlanStep -Plan $plan -Action 'AddGroup' -Title 'Gruppe hinzufügen: GRP-Alle' -Target 'mmustermann' -Handler 'Add-EobAdGroupMembership' -Parameters @{}
        $step2.Status = 'Failed'
        $step2.Message = '=cmd|calc'
        Add-EobPlanFinding -Plan $plan -Severity Warning -Code 'ONB_TEST' -Message 'Testhinweis'
        $plan.Status = 'Failed'
        return $plan
    }

    $script:Secret = 'Geheim!' + [guid]::NewGuid().ToString('N').Substring(0, 10)
    $null = Initialize-EobLogging -Directory (Join-Path $TestDrive 'logs')
}

AfterAll {
    Remove-EobRedactionValue -All
}

Describe 'Berichtsmodell' {
    BeforeEach {
        Add-EobRedactionValue -Value $script:Secret
        $script:Plan = New-TestPlan -Config $null
    }

    It 'enthält weder Kennwörter noch Handler-Parameter oder Konfiguration' {
        $report = New-EobPlanReport -Plan $script:Plan
        $report.PSObject.Properties.Name | Should -Not -Contain 'Secrets'
        $report.PSObject.Properties.Name | Should -Not -Contain 'Config'
        $report.Steps[0].PSObject.Properties.Name | Should -Not -Contain 'Parameters'
        $report.Steps[0].PSObject.Properties.Name | Should -Not -Contain 'Handler'
        $json = $report | ConvertTo-Json -Depth 8
        $json | Should -Not -Match ([regex]::Escape($script:Secret))
        $report.Steps[0].Message | Should -Not -Match ([regex]::Escape($script:Secret))
    }

    It 'übernimmt Ergebnis, Statistik und Befunde' {
        $report = New-EobPlanReport -Plan $script:Plan
        $report.Outcome | Should -Be 'Failed'
        $report.Statistic.Total | Should -Be 2
        $report.Statistic.Failed | Should -Be 1
        $report.Findings[0].Code | Should -Be 'ONB_TEST'
        $report.Title | Should -Match 'mmustermann'
        $report.SubjectName | Should -Be 'mmustermann'
    }
}

Describe 'Berichtsexport' {
    BeforeEach {
        Add-EobRedactionValue -Value $script:Secret
        $script:Report = New-EobPlanReport -Plan (New-TestPlan -Config $null)
        $script:OutDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    }

    It 'schreibt HTML, JSON, CSV und TXT ohne Kennwort' {
        $files = @(Export-EobReport -Report $script:Report -Format Html, Json, Csv, Txt -Directory $script:OutDir -Confirm:$false)
        $files.Format | Should -Be @('Html', 'Json', 'Csv', 'Txt')
        foreach ($file in $files) {
            Test-Path -LiteralPath $file.Path | Should -BeTrue
            Get-Content -LiteralPath $file.Path -Raw | Should -Not -Match ([regex]::Escape($script:Secret))
        }
    }

    It 'kodiert HTML-Inhalte' {
        $html = (Export-EobReport -Report $script:Report -Format Html -Directory $script:OutDir -Confirm:$false).Path
        $content = Get-Content -LiteralPath $html -Raw
        $content | Should -Not -Match '<script>alert'
        $content | Should -Match '&lt;script&gt;alert\(1\)&lt;/script&gt;'
        $content | Should -Not -Match '<link|<script src'
    }

    It 'schützt CSV-Werte vor Formel-Injektion' {
        $csv = (Export-EobReport -Report $script:Report -Format Csv -Directory $script:OutDir -Confirm:$false).Path
        $rows = @(Import-Csv -LiteralPath $csv -Delimiter ';')
        $rows.Count | Should -Be 2
        $rows[1].Meldung | Should -BeExactly '''=cmd|calc'
    }

    It 'liefert gültiges JSON' {
        $json = (Export-EobReport -Report $script:Report -Format Json -Directory $script:OutDir -Confirm:$false).Path
        $parsed = Get-Content -LiteralPath $json -Raw | ConvertFrom-Json
        $parsed.OperationId | Should -Be $script:Report.OperationId
        @($parsed.Steps).Count | Should -Be 2
    }

    It 'verwendet die Formate aus der Konfiguration' {
        $config = New-TestConfig -Content "[Report]`nFormats=Txt;Unbekannt"
        $files = @(Export-EobReport -Report $script:Report -Directory $script:OutDir -Config $config -Confirm:$false)
        $files.Format | Should -Be @('Txt')
    }

    It 'fällt ohne PDF-Engine auf HTML zurück' {
        $config = New-TestConfig -Content "[Report]`nPdfEngine=None"
        $files = @(Export-EobReport -Report $script:Report -Format Pdf -Directory $script:OutDir -Config $config -Confirm:$false)
        ($files | Where-Object Format -EQ 'Pdf').Path | Should -BeNullOrEmpty
        ($files | Where-Object Format -EQ 'Pdf').Message | Should -Match 'deaktiviert'
        $htmlFile = ($files | Where-Object Format -EQ 'Html').Path
        Test-Path -LiteralPath $htmlFile | Should -BeTrue
    }

    It 'schreibt mit -WhatIf keine Dateien' {
        $null = Export-EobReport -Report $script:Report -Format Html, Json -Directory $script:OutDir -WhatIf
        Test-Path -LiteralPath $script:OutDir | Should -BeFalse
    }

    It 'legt Berichte standardmäßig unter ReportPath\<Vorgangsart> ab' {
        $config = New-TestConfig -Content "[Report]`nReportPath=$(Join-Path $TestDrive 'rep')"
        Get-EobReportDirectory -Config $config -Kind 'Onboarding' | Should -Be (Join-Path (Join-Path $TestDrive 'rep') 'Onboarding')
    }

    It 'exportiert Plan und Bericht in einem Schritt' {
        $plan = New-TestPlan -Config $null
        $files = @(Export-EobPlanReport -Plan $plan -Format Json -Directory $script:OutDir -Confirm:$false)
        $files.Count | Should -Be 1
        Test-Path -LiteralPath $files[0].Path | Should -BeTrue
    }
}

Describe 'Vorlagen und Platzhalter' {
    It 'kodiert Werte und entfernt unbekannte Platzhalter' {
        $result = Expand-EobTemplate -Template '<p>{{Name}} {{ Unbekannt }}</p>' -Values @{ Name = '<b>Max</b>' }
        $result.Content | Should -BeExactly '<p>&lt;b&gt;Max&lt;/b&gt; </p>'
        $result.MissingPlaceholders | Should -Be @('Unbekannt')
    }

    It 'befüllt Kennwort-Platzhalter nie: <Name>' -ForEach @(
        @{ Name = 'Passwort' }, @{ Name = 'Password' }, @{ Name = 'CustomPW1' }, @{ Name = 'CompanyVPNPassword' }, @{ Name = 'Kennwort' }
    ) {
        $result = Expand-EobTemplate -Template "x{{$Name}}y" -Values @{ $Name = 'Geheim123!' } -SecretHint 'separat'
        $result.Content | Should -BeExactly 'xseparaty'
        $result.SecretPlaceholders | Should -Contain $Name
    }

    It 'leert Beschriftungen der entfernten Kennworttabelle' {
        (Expand-EobTemplate -Template '[{{CustomPWLabel1}}]' -Values @{}).Content | Should -BeExactly '[]'
    }

    It 'setzt intern erzeugtes HTML unverändert ein' {
        $result = Expand-EobTemplate -Template '<ul>{{PasswordPolicyList}}</ul>' -Values @{ PasswordPolicyList = '<li>a</li>' }
        $result.Content | Should -BeExactly '<ul><li>a</li></ul>'
    }

    It 'bettet Bilder aus Assets als data-URI ein' {
        $result = Expand-EobTemplate -Template '<img src="{{AssetDataUri:Report/welcome-header.png}}">' -Values @{}
        $result.Content | Should -Match '^<img src="data:image/png;base64,[A-Za-z0-9+/=]+">$'
        $result.Warnings | Should -BeNullOrEmpty
    }

    It 'verweigert Asset-Pfade außerhalb von Assets' {
        $result = Expand-EobTemplate -Template '<img src="{{AssetDataUri:../VERSION}}">' -Values @{}
        $result.Content | Should -BeExactly '<img src="">'
        $result.Warnings[0] | Should -Match 'außerhalb|zulässigen'
    }

    It 'erzeugt Platzhalterwerte aus Konfiguration, Unternehmen und Benutzerwerten' {
        $config = Import-EobConfiguration -Path $script:TemplateIni -NoIncludes
        $values = Get-EobWelcomePlaceholderValue -Config $config -Values @{ Vorname = 'Max'; CompanyName = 'Überschrieben' }
        $values['Vorname'] | Should -Be 'Max'
        $values['CompanyName'] | Should -Be 'Überschrieben'
        $values['CompanyHelpdeskMail'] | Should -Be 'helpdesk@example.com'
        $values['CompanyCity'] | Should -Be 'Musterstadt'
        $values['CompanyWikiURL'] | Should -Be 'https://wiki.example.com'
        $values['PasswordPolicyList'] | Should -Match '^<li>Mindestlänge: 12 Zeichen</li>'
        $values['WebsitesHTML'] | Should -Match 'href="https://intranet.example.com/"'
        $values['ReportTitle'] | Should -Be 'Willkommen bei Example GmbH'
    }

    It 'übernimmt keine Secret-Werte aus der Konfiguration' {
        $config = New-TestConfig -Content "[CompanyVPN]`nCompanyVPNDomain=vpn.example.com`nCompanyVPNPassword=Geheim123!`n[ReportPlaceholders]`nWlanPasswort=Geheim456!"
        $values = Get-EobWelcomePlaceholderValue -Config $config
        $values.ContainsKey('CompanyVPNPassword') | Should -BeFalse
        $values.ContainsKey('WlanPasswort') | Should -BeFalse
        ($values.Values -join '|') | Should -Not -Match 'Geheim'
        $values['CompanyVPNDomain'] | Should -Be 'vpn.example.com'
    }

    It 'beschreibt die Kennwortkriterien auf Englisch' {
        $values = Get-EobWelcomePlaceholderValue -Config $null -Language en
        $values['PasswordPolicyList'] | Should -Match 'Minimum length'
    }
}

Describe 'Willkommensdokument' {
    BeforeAll {
        $script:Config = Import-EobConfiguration -Path $script:TemplateIni -NoIncludes
        $script:UserValues = @{
            Vorname = 'Max'; Nachname = 'Mustermann'; DisplayName = 'Max Mustermann'; LoginName = 'mmustermann'; UPN = 'max.mustermann@example.com'
            MailAddress = 'max.mustermann@example.com'; Position = 'Vertrieb'; Abteilung = 'Vertrieb'; Buero = '1.01'; Rufnummer = '+49 30 1'
            Mobil = ''; Description = ''; Ablaufdatum = ''; License = 'MS365_E3'; CompanyId = 'Company'
        }
    }

    It 'rendert die mitgelieferte Vorlage vollständig und ohne Kennwort' {
        $out = Join-Path $TestDrive 'welcome1'
        $template = Join-Path (Get-EobTestRepoRoot) 'ReportTemplates/HTMLTemplate.txt'
        $result = New-EobWelcomeDocument -SamAccountName 'mmustermann' -TemplatePath $template -Values $script:UserValues -Config $script:Config -OutputDirectory $out -Confirm:$false
        $result.Status | Should -Be 'Succeeded'
        $content = Get-Content -LiteralPath $result.Data['WelcomeDocumentPath'] -Raw
        $content | Should -Not -Match '\{\{'
        $content | Should -Match 'mmustermann'
        $content | Should -Match 'data:image/png;base64'
        $content | Should -Not -Match 'C:\\easyIT'
    }

    It 'rendert die englische Vorlage mit englischen Kennwortkriterien' {
        $out = Join-Path $TestDrive 'welcome-en'
        $template = Join-Path (Get-EobTestRepoRoot) 'ReportTemplates/HTMLTemplateENG.txt'
        $result = New-EobWelcomeDocument -SamAccountName 'mmustermann' -TemplatePath $template -Values $script:UserValues -Config $script:Config -OutputDirectory $out -Confirm:$false
        $content = Get-Content -LiteralPath $result.Data['WelcomeDocumentPath'] -Raw
        $content | Should -Match 'Minimum length'
        $content | Should -Not -Match '\{\{'
    }

    It 'neutralisiert Kennwort-Platzhalter eigener Vorlagen und meldet sie' {
        $template = Join-Path $TestDrive 'eigene.html'
        Set-Content -LiteralPath $template -Value '<html lang="de"><body>{{LoginName}} / {{Passwort}} / {{Fehlt}}</body></html>' -Encoding utf8
        $out = Join-Path $TestDrive 'welcome2'
        $values = $script:UserValues.Clone()
        $values['Passwort'] = 'Geheim123!'
        $result = New-EobWelcomeDocument -SamAccountName 'mmustermann' -TemplatePath $template -Values $values -Config $script:Config -OutputDirectory $out -Confirm:$false
        $result.Status | Should -Be 'Warning'
        $result.Message | Should -Match 'Passwort'
        $result.Message | Should -Match 'Fehlt'
        $content = Get-Content -LiteralPath $result.Data['WelcomeDocumentPath'] -Raw
        $content | Should -Not -Match 'Geheim123'
        $content | Should -Match 'separat'
    }

    It 'schreibt in der Simulation keine Datei' {
        $out = Join-Path $TestDrive 'welcome3'
        $template = Join-Path (Get-EobTestRepoRoot) 'ReportTemplates/HTMLTemplate.txt'
        $result = New-EobWelcomeDocument -SamAccountName 'mmustermann' -TemplatePath $template -Values $script:UserValues -Config $script:Config -OutputDirectory $out -WhatIf
        $result.Message | Should -Match '^Simulation'
        Test-Path -LiteralPath $out | Should -BeFalse
    }

    It 'bricht bei fehlender Vorlage mit einer klaren Meldung ab' {
        { New-EobWelcomeDocument -SamAccountName 'x' -TemplatePath (Join-Path $TestDrive 'fehlt.html') -Config $script:Config -Confirm:$false } | Should -Throw '*nicht gefunden*'
    }
}

Describe 'Welcome-Mail' {
    BeforeAll {
        $script:MailIni = @'
[EmailSettings]
SMTPServer=smtp.example.local
SMTPPort=25
UseSSL=1
FromAddress=it-service@example.com
WelcomeEmailSubject=Willkommen {{DisplayName}}
[Company]
CompanyNameFirma=Example GmbH
CompanyActiveDirectoryDomain=example.com
[CompanyHelpdesk]
CompanyHelpdeskMail=helpdesk@example.com
'@
    }

    BeforeEach {
        Mock -ModuleName $script:RepModule Send-EobSmtpMessage { }
    }

    It 'meldet eine Warnung, wenn SMTP nicht konfiguriert ist' {
        $result = Send-EobWelcomeMail -To 'max@example.com' -Config (New-TestConfig) -Confirm:$false
        $result.Status | Should -Be 'Warning'
        Should -Invoke -ModuleName $script:RepModule Send-EobSmtpMessage -Times 0
    }

    It 'sendet in der Simulation nichts' {
        $result = Send-EobWelcomeMail -To 'max@example.com' -DisplayName 'Max' -Config (New-TestConfig -Content $script:MailIni) -WhatIf
        $result.Message | Should -Match '^Simulation'
        Should -Invoke -ModuleName $script:RepModule Send-EobSmtpMessage -Times 0
    }

    It 'sendet eine kodierte Mail ohne Kennwort' {
        $result = Send-EobWelcomeMail -To 'max@example.com' -DisplayName 'Max <Mustermann>' -SamAccountName 'mmustermann' -UserPrincipalName 'max@example.com' `
            -StartDate ([datetime]'2027-01-04') -Config (New-TestConfig -Content $script:MailIni) -Confirm:$false
        $result.Status | Should -Be 'Succeeded'
        Should -Invoke -ModuleName $script:RepModule Send-EobSmtpMessage -Times 1 -ParameterFilter {
            $To -eq 'max@example.com' -and $Subject -eq 'Willkommen Max <Mustermann>' -and
            $HtmlBody -match 'Max &lt;Mustermann&gt;' -and $HtmlBody -match '04\.01\.2027' -and $HtmlBody -match 'separat und persönlich' -and
            $HtmlBody -match 'helpdesk@example.com' -and $Setting.From -eq 'it-service@example.com'
        }
    }

    It 'neutralisiert Kennwort-Platzhalter in eigenen Mailvorlagen' {
        $template = Join-Path $TestDrive 'mail.html'
        Set-Content -LiteralPath $template -Value '<p>{{LoginName}} {{Passwort}}</p>' -Encoding utf8
        $config = New-TestConfig -Content ($script:MailIni -replace 'WelcomeEmailSubject=', "WelcomeEmailTemplate=$template`nWelcomeEmailSubject=")
        $null = Send-EobWelcomeMail -To 'max@example.com' -SamAccountName 'mmustermann' -Config $config -Confirm:$false
        Should -Invoke -ModuleName $script:RepModule Send-EobSmtpMessage -Times 1 -ParameterFilter { $HtmlBody.Trim() -eq '<p>mmustermann Erhältst Du separat und persönlich.</p>' }
    }

    It 'entfernt Zeilenumbrüche aus dem Betreff' {
        $config = New-TestConfig -Content $script:MailIni
        $null = Send-EobWelcomeMail -To 'max@example.com' -DisplayName "Max`r`nBcc: x@example.net" -Config $config -Confirm:$false
        Should -Invoke -ModuleName $script:RepModule Send-EobSmtpMessage -Times 1 -ParameterFilter { $Subject -notmatch "[`r`n]" }
    }

    It 'lehnt ungültige Empfänger ab' {
        { Send-EobWelcomeMail -To 'keine-adresse' -Config (New-TestConfig -Content $script:MailIni) -Confirm:$false } | Should -Throw '*Ungültige Empfängeradresse*'
    }
}

Describe 'Integrationsstatus (SMTP, Dateiserver, PDF)' {
    It 'meldet SMTP ohne Relay als NotConfigured' {
        (Get-EobSmtpStatus -Config (New-TestConfig)).State | Should -Be 'NotConfigured'
    }

    It 'meldet konfiguriertes SMTP als Available' {
        $status = Get-EobSmtpStatus -Config (New-TestConfig -Content "[EmailSettings]`nSMTPServer=smtp.example.local`nFromAddress=it@example.com")
        $status.State | Should -Be 'Available'
        $status.Detail | Should -Match 'smtp.example.local:25'
    }

    It 'prüft die SMTP-Verbindung per TCP' {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        try {
            $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
            $config = New-TestConfig -Content "[EmailSettings]`nSMTPServer=127.0.0.1`nSMTPPort=$port`nFromAddress=it@example.com"
            (Get-EobSmtpStatus -Config $config -TestConnection).State | Should -Be 'Connected'
        }
        finally {
            $listener.Stop()
        }
        $closed = New-TestConfig -Content "[EmailSettings]`nSMTPServer=127.0.0.1`nSMTPPort=$port`nFromAddress=it@example.com"
        (Get-EobSmtpStatus -Config $closed -TestConnection -TimeoutMilliseconds 1000).State | Should -Be 'Error'
    }

    It 'prüft Dateiserver-Stammpfade' {
        (Get-EobFileServerStatus -Config (New-TestConfig)).State | Should -Be 'NotConfigured'
        $config = New-TestConfig -Content "[FileServer]`nAllowedRoots=$TestDrive"
        (Get-EobFileServerStatus -Config $config).State | Should -Be 'Available'
        (Get-EobFileServerStatus -Config $config -TestConnection).State | Should -Be 'Connected'
        $missing = New-TestConfig -Content "[FileServer]`nAllowedRoots=$(Join-Path $TestDrive 'gibtsnicht')"
        (Get-EobFileServerStatus -Config $missing -TestConnection).State | Should -Be 'Error'
    }

    It 'meldet die PDF-Erzeugung als deaktiviert oder nicht installiert' {
        (Get-EobPdfEngineStatus -Config (New-TestConfig -Content "[Report]`nPdfEngine=None")).State | Should -Be 'Disabled'
        $config = New-TestConfig -Content "[Report]`nPdfEngine=Wkhtmltopdf`nwkhtmltopdfPath=$(Join-Path $TestDrive 'fehlt.exe')"
        (Get-EobPdfEngineStatus -Config $config).State | Should -Be 'NotInstalled'
    }

    It 'nutzt einen konfigurierten Edge-Pfad' {
        $fake = Join-Path $TestDrive 'msedge.exe'
        Set-Content -LiteralPath $fake -Value '' -Encoding utf8
        $engine = Get-EobPdfEngine -Config (New-TestConfig -Content "[Report]`nPdfEngine=Edge`nEdgePath=$fake")
        $engine.Name | Should -Be 'Edge'
        $engine.Path | Should -Be $fake
    }

    It 'wird über Get-EobIntegrationStatus eingebunden' {
        $names = @(Get-EobIntegrationStatus -Config (New-TestConfig)).Name
        $names | Should -Contain 'SMTP'
        $names | Should -Contain 'Dateiserver'
        $names | Should -Contain 'PDF-Erzeugung'
    }
}

Describe 'Audit-Auswertung' {
    BeforeAll {
        $script:AuditLogDir = Join-Path $TestDrive 'auditlogs'
        $null = Initialize-EobLogging -Directory $script:AuditLogDir
        $script:Op1 = [guid]::NewGuid().ToString()
        $script:Op2 = [guid]::NewGuid().ToString()
        Write-EobLog -Level Audit -OperationId $script:Op1 -Action 'CreateUser' -Target 'mmustermann' -Result 'Succeeded' -Message 'ok'
        Write-EobLog -Level Audit -OperationId $script:Op1 -Action 'OnboardingCompleted' -Target 'mmustermann' -Result 'Succeeded' -Message 'Plan abgeschlossen.'
        Write-EobLog -Level Audit -OperationId $script:Op2 -Action 'DisableAccount' -Target '=evil' -Result 'Failed' -Message 'Fehler <b>'
        Write-EobLog -Level Audit -OperationId $script:Op2 -Action 'OffboardingCompleted' -Target '=evil' -Result 'Failed' -Message 'Plan abgeschlossen.'
    }

    It 'fasst Vorgänge zusammen' {
        $summary = Get-EobAuditSummary -From (Get-Date).AddHours(-1) -To (Get-Date).AddHours(1)
        $summary.OperationCount | Should -Be 2
        $summary.FailedOperations | Should -Be 1
        $summary.FailedSteps | Should -Be 1
        $summary.ByKind['Onboarding'] | Should -Be 1
        $summary.ByKind['Offboarding'] | Should -Be 1
        $summary.LastOperations[0].OperationId | Should -BeIn @($script:Op1, $script:Op2)
    }

    It 'exportiert Audit-Einträge als CSV mit Formelschutz' {
        $path = Join-Path $TestDrive 'audit.csv'
        $null = Export-EobAuditReport -Path $path -From (Get-Date).AddHours(-1) -To (Get-Date).AddHours(1) -Format Csv -Confirm:$false
        $rows = @(Import-Csv -LiteralPath $path -Delimiter ';')
        $rows.Count | Should -Be 4
        ($rows | Where-Object Aktion -EQ 'DisableAccount').Ziel | Should -BeExactly '''=evil'
    }

    It 'exportiert Audit-Einträge als kodiertes HTML' {
        $path = Join-Path $TestDrive 'audit.html'
        $null = Export-EobAuditReport -Path $path -From (Get-Date).AddHours(-1) -To (Get-Date).AddHours(1) -Format Html -Confirm:$false
        $content = Get-Content -LiteralPath $path -Raw
        $content | Should -Match 'Fehler &lt;b&gt;'
        $content | Should -Not -Match 'Fehler <b>'
    }

    It 'filtert nach Operation-ID' {
        $path = Join-Path $TestDrive 'audit.json'
        $null = Export-EobAuditReport -Path $path -OperationId $script:Op1 -From (Get-Date).AddHours(-1) -To (Get-Date).AddHours(1) -Format Json -Confirm:$false
        $rows = @(Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
        $rows.Count | Should -Be 2
        $rows.OperationId | Should -Not -Contain $script:Op2
    }
}
