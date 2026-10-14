#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.3.0' }

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath '../TestHelpers.ps1')
    Import-EobTestModule

    # Testmodul mit zulässigen Handlern (Modulname easyONB.*), um die Plan-Engine isoliert zu prüfen
    $script:HandlerModule = New-Module -Name 'easyONB.TestHandlers' -ScriptBlock {
        $script:Calls = [System.Collections.Generic.List[object]]::new()
        function Invoke-EobTestWrite {
            [CmdletBinding(SupportsShouldProcess)]
            param([string]$Name, [object]$Secret, [switch]$Fail)
            $script:Calls.Add([pscustomobject]@{ Name = $Name; WhatIf = [bool]$WhatIfPreference; SecretType = if ($null -ne $Secret) { $Secret.GetType().Name } else { $null } })
            if ($Fail) { throw "Absichtlicher Fehler fuer $Name" }
            if ($PSCmdlet.ShouldProcess($Name, 'Testaktion')) {
                return New-EobResult -Status Succeeded -Message "geschrieben: $Name" -Data @{ LastName = $Name }
            }
        }
        function Invoke-EobTestRead {
            [CmdletBinding()]
            param([string]$Name)
            $script:Calls.Add([pscustomobject]@{ Name = $Name; WhatIf = $false; SecretType = $null })
            return New-EobResult -Status Warning -Message "gelesen: $Name"
        }
        function Invoke-EobTestConfig {
            [CmdletBinding()]
            param([object]$Config)
            $script:Calls.Add([pscustomobject]@{ Name = 'Config'; WhatIf = $false; SecretType = if ($null -ne $Config) { [string]$Config.Marker } else { $null } })
            return New-EobResult -Status Succeeded -Message 'Konfiguration erhalten'
        }
        function Get-EobTestCall { return $script:Calls }
        function Clear-EobTestCall { $script:Calls.Clear() }
        Export-ModuleMember -Function *
    } | Import-Module -Global -PassThru

    $script:ForeignModule = New-Module -Name 'Fremdmodul' -ScriptBlock {
        function Invoke-ForeignHandler {
            [CmdletBinding(SupportsShouldProcess)]
            [OutputType([string])]
            param([string]$Name)
            if ($PSCmdlet.ShouldProcess($Name, 'Fremden Handler ausführen')) { 'nicht erlaubt' }
        }
        Export-ModuleMember -Function *
    } | Import-Module -Global -PassThru
}

AfterAll {
    Remove-Module -Name 'easyONB.TestHandlers', 'Fremdmodul' -Force -ErrorAction SilentlyContinue
}

Describe 'Version' {
    It 'liest die Version aus der VERSION-Datei' {
        # VERSION liegt im Anwendungsordner oder im Repository-Stamm darüber.
        $file = @((Join-Path (Get-EobTestRepoRoot) 'VERSION'), (Join-Path (Split-Path -Parent (Get-EobTestRepoRoot)) 'VERSION')) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        $expected = (Get-Content -LiteralPath $file -Raw).Trim()
        Get-EobVersion | Should -Be $expected
        Get-EobVersion | Should -Match '^\d+\.\d+\.\d+'
    }
}

Describe 'Pfadbehandlung' {
    It 'löst relative Pfade gegen die Anwendungswurzel auf' {
        $result = Resolve-EobPath -Path 'Logs'
        $result | Should -Be ([System.IO.Path]::GetFullPath((Join-Path (Get-EobAppRoot) 'Logs')))
    }

    It 'löst relative Pfade gegen einen angegebenen BasePath auf' {
        Resolve-EobPath -Path 'Reports' -BasePath $TestDrive | Should -Be (Join-Path $TestDrive 'Reports')
    }

    It 'expandiert Umgebungsvariablen im Format $env:NAME und %NAME%' {
        $env:EOB_TEST_DIR = $TestDrive
        try {
            Resolve-EobPath -Path '$env:EOB_TEST_DIR/a' | Should -Be (Join-Path $TestDrive 'a')
            Resolve-EobPath -Path '${env:EOB_TEST_DIR}/b' | Should -Be (Join-Path $TestDrive 'b')
            Resolve-EobPath -Path '%EOB_TEST_DIR%/c' | Should -Be (Join-Path $TestDrive 'c')
        }
        finally {
            Remove-Item Env:\EOB_TEST_DIR -ErrorAction SilentlyContinue
        }
    }

    It 'liefert für leere Pfade einen Leerstring' {
        Resolve-EobPath -Path '' | Should -Be ''
        Resolve-EobPath -Path '   ' | Should -Be ''
    }

    It 'behält Windows- und UNC-Pfade bei' -Skip:$IsWindows {
        Resolve-EobPath -Path 'C:\easyIT\Logs' | Should -Be 'C:\easyIT\Logs'
        Resolve-EobPath -Path '\\fs01\home$\user' | Should -Be '\\fs01\home$\user'
    }

    It 'erkennt Pfade innerhalb eines Wurzelverzeichnisses' {
        Test-EobPathWithin -Path (Join-Path $TestDrive 'a/b') -Root $TestDrive | Should -BeTrue
        Test-EobPathWithin -Path $TestDrive -Root $TestDrive | Should -BeTrue
    }

    It 'verhindert Path-Traversal und Präfix-Verwechslungen' {
        Test-EobPathWithin -Path (Join-Path $TestDrive '../x') -Root $TestDrive | Should -BeFalse
        Test-EobPathWithin -Path ($TestDrive + '2/x') -Root $TestDrive | Should -BeFalse
        Test-EobPathWithin -Path 'a/../../b' -Root $TestDrive | Should -BeFalse
    }

    It 'prüft UNC-Pfade ohne Groß-/Kleinschreibung' {
        Test-EobPathWithin -Path '\\FS01\Home$\max' -Root '\\fs01\home$' | Should -BeTrue
        Test-EobPathWithin -Path '\\fs01\home$\..\admin$\x' -Root '\\fs01\home$' | Should -BeFalse
        Test-EobPathWithin -Path '\\fs01\home$archiv\x' -Root '\\fs01\home$' | Should -BeFalse
    }

    It 'erzeugt sichere Dateinamen' {
        Get-EobSafeFileName -Name '..\..\evil:name?.txt' | Should -Not -Match '[\\/:?]'
        Get-EobSafeFileName -Name 'CON' | Should -Be '_CON'
        Get-EobSafeFileName -Name '' | Should -Be 'unbenannt'
        (Get-EobSafeFileName -Name ('x' * 300) -MaxLength 40).Length | Should -Be 40
    }
}

Describe 'Konvertierungen' {
    It 'interpretiert Boolean-Werte aus INI und CSV' -ForEach @(
        @{ Value = '1'; Expected = $true }, @{ Value = 'True'; Expected = $true }, @{ Value = 'ja'; Expected = $true },
        @{ Value = 'Yes'; Expected = $true }, @{ Value = '0'; Expected = $false }, @{ Value = 'nein'; Expected = $false },
        @{ Value = 'FALSE'; Expected = $false }
    ) {
        ConvertTo-EobBoolean -Value $Value | Should -Be $Expected
    }

    It 'nutzt den Standardwert für leere oder unbekannte Werte' {
        ConvertTo-EobBoolean -Value '' -Default $true | Should -BeTrue
        ConvertTo-EobBoolean -Value 'vielleicht' -Default $false | Should -BeFalse
        ConvertTo-EobBoolean -Value $null -Default $true | Should -BeTrue
    }

    It 'parst Datumswerte kulturunabhängig' -ForEach @(
        @{ Value = '2027-06-30' }, @{ Value = '30.06.2027' }, @{ Value = '30.6.2027' }
    ) {
        $date = ConvertTo-EobDate -Value $Value
        $date | Should -BeOfType [datetime]
        $date.Year | Should -Be 2027
        $date.Month | Should -Be 6
        $date.Day | Should -Be 30
    }

    It 'liefert $null für ungültige Datumswerte' {
        ConvertTo-EobDate -Value '31.02.2027' | Should -BeNullOrEmpty
        ConvertTo-EobDate -Value 'morgen' | Should -BeNullOrEmpty
        ConvertTo-EobDate -Value '' | Should -BeNullOrEmpty
    }

    It 'kodiert HTML-Sonderzeichen' {
        ConvertTo-EobHtmlEncoded -Value '<script>alert("x")</script> & Co' | Should -BeExactly '&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt; &amp; Co'
        ConvertTo-EobHtmlEncoded -Value $null | Should -BeExactly ''
    }

    It 'schützt CSV-Werte vor Formel-Injektion: <Value>' -ForEach @(
        @{ Value = '=HYPERLINK("http://x")'; Expected = '''=HYPERLINK("http://x")' }, @{ Value = '+1'; Expected = '''+1' }
        @{ Value = '-2'; Expected = '''-2' }, @{ Value = '@SUM(A1)'; Expected = '''@SUM(A1)' }, @{ Value = "`tx"; Expected = "'`tx" }
        @{ Value = 'Max Mustermann'; Expected = 'Max Mustermann' }, @{ Value = ''; Expected = '' }
    ) {
        ConvertTo-EobCsvSafeValue -Value $Value | Should -BeExactly $Expected
    }

    It 'lässt Nicht-Texte in CSV-Objekten unverändert' {
        $row = [pscustomobject]@{ Name = '=1+1'; Count = -5; Flag = $true } | ConvertTo-EobCsvSafeObject
        $row.Name | Should -BeExactly '''=1+1'
        $row.Count | Should -Be -5
        $row.Flag | Should -BeTrue
    }

    It 'liest Eigenschaften sicher unter StrictMode' {
        Get-EobPropertyValue -InputObject @{ a = 1 } -Name 'a' | Should -Be 1
        Get-EobPropertyValue -InputObject @{ a = 1 } -Name 'b' -Default 'x' | Should -Be 'x'
        Get-EobPropertyValue -InputObject ([pscustomobject]@{ a = 2 }) -Name 'a' | Should -Be 2
        Get-EobPropertyValue -InputObject ([pscustomobject]@{ a = 2 }) -Name 'z' -Default 3 | Should -Be 3
        Get-EobPropertyValue -InputObject $null -Name 'a' -Default 4 | Should -Be 4
    }
}

Describe 'Redaktion sensibler Werte' {
    AfterEach {
        Remove-EobRedactionValue -All
    }

    It 'maskiert Schlüssel-Wert-Paare mit Kennwörtern, Tokens und Secrets' -ForEach @(
        @{ Text = 'fixPassword=Geheim123!'; Secret = 'Geheim123!' }
        @{ Text = 'CompanyVPNPassword = abc987xyz'; Secret = 'abc987xyz' }
        @{ Text = 'JiraToken:tok_12345678'; Secret = 'tok_12345678' }
        @{ Text = '{"InitialPassword":"Sehr$Geheim1"}'; Secret = 'Sehr$Geheim1' }
        @{ Text = 'Authorization: Bearer eyAbc.def.ghi123'; Secret = 'eyAbc.def.ghi123' }
        @{ Text = 'client_secret=s3cr3tvalue'; Secret = 's3cr3tvalue' }
    ) {
        $result = Protect-EobSensitiveText -Text $Text
        $result | Should -Not -BeLike "*$Secret*"
        $result | Should -BeLike '****'
    }

    It 'lässt harmlose Schlüssel wie PasswordNeverExpires unverändert' {
        Protect-EobSensitiveText -Text 'PasswordNeverExpires=True ChangePasswordAtLogon=1' |
            Should -Be 'PasswordNeverExpires=True ChangePasswordAtLogon=1'
    }

    It 'maskiert JWT-artige Tokens' {
        # Künstliches Token (Header {"alg":"HS256"}, Nutzlast {"sub":"1234567890"}); zur Laufzeit
        # zusammengesetzt, damit der Secret-Scan (Scripts/Invoke-EobQualityCheck.ps1) nicht anschlägt.
        $jwt = @('eyJhbGciOiJIUzI1NiJ9', 'eyJzdWIiOiIxMjM0NTY3ODkwIn0', 'abcdefghijk') -join '.'
        Protect-EobSensitiveText -Text "token $jwt ende" | Should -Not -Match 'eyJhbGci'
    }

    It 'maskiert registrierte Werte, auch wenn sie als SecureString registriert wurden' {
        $secure = New-EobTestSecureString -Value 'Xy7!unbekanntesMuster'
        Add-EobRedactionValue -Value $secure
        Protect-EobSensitiveText -Text 'Ausgabe: Xy7!unbekanntesMuster fertig' | Should -Be 'Ausgabe: *** fertig'
    }

    It 'redigiert verschachtelte Datenstrukturen' {
        $data = @{
            User   = 'max'
            Nested = @{ AccountPassword = 'x'; Note = 'token=abcdefgh' }
            Secure = New-EobTestSecureString
            List   = @('password=abcdefg', 'ok')
        }
        $result = Protect-EobSensitiveData -InputObject $data
        $result.User | Should -Be 'max'
        $result.Nested.AccountPassword | Should -Be '***'
        $result.Nested.Note | Should -Be 'token=***'
        $result.Secure | Should -Be '***'
        $result.List[0] | Should -Be 'password=***'
    }
}

Describe 'Logging und Audit' {
    BeforeEach {
        $script:LogDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = Initialize-EobLogging -Directory $script:LogDir -MinimumLevel Information -EnableQueue
        $null = Receive-EobLogEntry
    }

    It 'weicht bei einem nicht vorhandenen Laufwerk auf das Ausweichverzeichnis aus, ohne abzubrechen' {
        $fallbackRoot = Join-Path $TestDrive 'fallback'
        $status = Initialize-EobLogging -Directory 'Q:\gibt-es-nicht\Logs' -FallbackRoot $fallbackRoot -WarningAction SilentlyContinue
        $status.FallbackActive | Should -BeTrue
        $status.Directory | Should -BeLike "$fallbackRoot*"
        Test-Path -LiteralPath (Join-Path $fallbackRoot 'easyONBOARDING/Logs/audit') | Should -BeTrue
        Test-EobPathWithin -Path 'max' -Root 'Q:\Home' | Should -BeTrue
    }

    It 'schreibt Einträge mit Operation-ID, Akteur, Aktion, Ziel, Ergebnis und Dauer' {
        Write-EobLog -Message 'Test' -Level Information -OperationId 'op-1' -Action 'CreateUser' -Target 'mmuster' -Result 'Succeeded' -DurationMs 42
        $file = Get-ChildItem -LiteralPath $script:LogDir -Filter 'easyONB_*.log' | Select-Object -First 1
        $content = Get-Content -LiteralPath $file.FullName -Raw
        $content | Should -Match '\[Information\]'
        $content | Should -Match '\[op:op-1\]'
        $content | Should -Match '\[actor:'
        $content | Should -Match 'Action=CreateUser'
        $content | Should -Match 'Target=mmuster'
        $content | Should -Match 'Result=Succeeded'
        $content | Should -Match 'DurationMs=42'
    }

    It 'redigiert Kennwörter in Nachricht, Daten und Fehlern' {
        $err = [System.Management.Automation.ErrorRecord]::new([Exception]::new('password=Fehler123'), 'x', 'NotSpecified', $null)
        Write-EobLog -Message 'Kennwort=Gehe1mWert' -Data @{ AccountPassword = 'DatenGeheim'; ok = 'ja' } -ErrorRecord $err -Level Error
        $content = Get-Content -LiteralPath (Get-ChildItem -LiteralPath $script:LogDir -Filter '*.log').FullName -Raw
        $content | Should -Not -Match 'Gehe1mWert'
        $content | Should -Not -Match 'DatenGeheim'
        $content | Should -Not -Match 'Fehler123'
    }

    It 'schreibt Audit-Einträge zusätzlich als JSON Lines' {
        Write-EobLog -Message 'Audit-Test' -Level Audit -OperationId 'op-2' -Action 'DisableAccount' -Target 'x'
        $auditFile = Get-ChildItem -LiteralPath (Join-Path $script:LogDir 'audit') -Filter 'easyONB_audit_*.jsonl'
        $entry = Get-Content -LiteralPath $auditFile.FullName | Select-Object -First 1 | ConvertFrom-Json
        $entry.Level | Should -Be 'Audit'
        $entry.OperationId | Should -Be 'op-2'
        $entry.Action | Should -Be 'DisableAccount'
        @(Get-EobAuditEntry -OperationId 'op-2').Count | Should -Be 1
    }

    It 'liest nur Audit-Monatsdateien im Zeitraum und filtert die Operation-ID vor' {
        $auditDir = Join-Path $TestDrive ('audit-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $auditDir
        $write = {
            param([datetime]$Time, [string]$Id, [string]$File)
            $line = [ordered]@{ Timestamp = $Time.ToString('o'); Level = 'Audit'; OperationId = $Id; Action = 'X' } | ConvertTo-Json -Compress
            Add-Content -LiteralPath (Join-Path $auditDir $File) -Value $line
        }
        & $write ([datetime]'2026-08-31 23:30') 'aug' 'easyONB_audit_202608.jsonl'
        & $write ([datetime]'2026-09-15') 'sep' 'easyONB_audit_202609.jsonl'
        # Absichtlich falsch einsortiert: liegt die Datei mehr als einen Monat außerhalb, wird sie nicht gelesen.
        & $write ([datetime]'2026-09-16') 'alt' 'easyONB_audit_202401.jsonl'
        @(Get-EobAuditEntry -Directory $auditDir -From ([datetime]'2026-09-01') -To ([datetime]'2026-09-30')).OperationId | Should -Be @('sep')
        @(Get-EobAuditEntry -Directory $auditDir -From ([datetime]'2026-08-31') -To ([datetime]'2026-09-30')).OperationId | Should -Be @('aug', 'sep')
        @(Get-EobAuditEntry -Directory $auditDir).Count | Should -Be 3
        @(Get-EobAuditEntry -Directory $auditDir -OperationId 'sep').OperationId | Should -Be @('sep')
        @(Get-EobAuditEntry -Directory $auditDir -OperationId 'se"p').Count | Should -Be 0
    }

    It 'filtert Einträge unterhalb des Mindestlevels' {
        Write-EobLog -Message 'nur Debug' -Level Debug
        Get-ChildItem -LiteralPath $script:LogDir -Filter '*.log' | Should -BeNullOrEmpty
        Write-EobLog -Message 'Audit immer' -Level Audit
        Get-ChildItem -LiteralPath $script:LogDir -Filter '*.log' | Should -Not -BeNullOrEmpty
    }

    It 'stellt Einträge in die GUI-Warteschlange' {
        Write-EobLog -Message 'Queue-Test' -Level Warning
        $entries = @(Receive-EobLogEntry)
        $entries.Count | Should -Be 1
        $entries[0].Message | Should -Be 'Queue-Test'
    }

    It 'wirft bei Schreibfehlern nicht, meldet sie aber sichtbar' {
        Remove-Item -LiteralPath $script:LogDir -Recurse -Force
        Set-Content -LiteralPath $script:LogDir -Value 'kein Verzeichnis'
        { Write-EobLog -Message 'geht nicht' -Level Warning -WarningAction SilentlyContinue } | Should -Not -Throw
        $status = Get-EobLogStatus
        $status.Healthy | Should -BeFalse
        $status.FailureCount | Should -BeGreaterThan 0
    }

    It 'wechselt bei Überschreiten der Maximalgröße auf eine Folgedatei' {
        $null = Initialize-EobLogging -Directory $script:LogDir -MaxFileSizeMB 1
        $first = Join-Path $script:LogDir ('easyONB_{0}.log' -f (Get-Date).ToString('yyyyMMdd'))
        [System.IO.File]::WriteAllBytes($first, [byte[]]::new(1MB + 10))
        Write-EobLog -Message 'Folgedatei' -Level Information
        Test-Path (Join-Path $script:LogDir ('easyONB_{0}_1.log' -f (Get-Date).ToString('yyyyMMdd'))) | Should -BeTrue
    }

    It 'löscht Logdateien außerhalb der Aufbewahrungsfrist' {
        $old = Join-Path $script:LogDir 'easyONB_20000101.log'
        Set-Content -LiteralPath $old -Value 'alt'
        (Get-Item $old).LastWriteTime = (Get-Date).AddDays(-400)
        $null = Initialize-EobLogging -Directory $script:LogDir -RetentionDays 30
        Test-Path $old | Should -BeFalse
    }

    It 'meldet die Beschreibbarkeit des Audit-Logs' {
        Test-EobAuditWritable | Should -BeTrue
    }
}

Describe 'Plan-Engine' {
    BeforeEach {
        $null = Initialize-EobLogging -Directory (Join-Path $TestDrive 'planlogs')
        Clear-EobTestCall
        $script:Context = New-EobOperationContext -Kind 'Test'
        $script:Plan = New-EobPlan -Kind 'Test' -Context $script:Context -Subject @{ SamAccountName = 'mmuster' }
    }

    It 'führt Schritte in Reihenfolge aus und übernimmt Laufzeitdaten' {
        $null = Add-EobPlanStep -Plan $script:Plan -Action 'A' -Title 'Schritt A' -Handler 'Invoke-EobTestWrite' -Parameters @{ Name = 'A' }
        $null = Add-EobPlanStep -Plan $script:Plan -Action 'B' -Title 'Schritt B' -Handler 'Invoke-EobTestRead' -Parameters @{ Name = 'B' } -DependsOn 'S01'
        $result = Invoke-EobPlan -Plan $script:Plan -Confirm:$false
        $result.Steps[0].Status | Should -Be 'Succeeded'
        $result.Steps[1].Status | Should -Be 'Warning'
        $result.Runtime['LastName'] | Should -Be 'A'
        $result.Status | Should -Be 'CompletedWithWarnings'
        (Get-EobTestCall).Name | Should -Be @('A', 'B')
    }

    It 'simuliert mit -WhatIf und reicht WhatIf an die Handler weiter' {
        $null = Add-EobPlanStep -Plan $script:Plan -Action 'A' -Title 'Schritt A' -Handler 'Invoke-EobTestWrite' -Parameters @{ Name = 'A' }
        $result = Invoke-EobPlan -Plan $script:Plan -WhatIf
        $result.Simulation | Should -BeTrue
        $result.Steps[0].Status | Should -Be 'Simulated'
        (Get-EobTestCall)[0].WhatIf | Should -BeTrue
        $result.Status | Should -Be 'Simulated'
    }

    It 'überspringt abhängige Schritte nach einem Fehler' {
        $null = Add-EobPlanStep -Plan $script:Plan -Action 'A' -Title 'A' -Handler 'Invoke-EobTestWrite' -Parameters @{ Name = 'A'; Fail = $true }
        $null = Add-EobPlanStep -Plan $script:Plan -Action 'B' -Title 'B' -Handler 'Invoke-EobTestWrite' -Parameters @{ Name = 'B' } -DependsOn 'S01'
        $null = Add-EobPlanStep -Plan $script:Plan -Action 'C' -Title 'C' -Handler 'Invoke-EobTestWrite' -Parameters @{ Name = 'C' }
        $result = Invoke-EobPlan -Plan $script:Plan -Confirm:$false
        $result.Steps[0].Status | Should -Be 'Failed'
        $result.Steps[1].Status | Should -Be 'Skipped'
        $result.Steps[2].Status | Should -Be 'Succeeded'
        $result.Status | Should -Be 'Failed'
    }

    It 'bricht nach einem kritischen Fehler alle folgenden Schritte ab' {
        $null = Add-EobPlanStep -Plan $script:Plan -Action 'A' -Title 'A' -Handler 'Invoke-EobTestWrite' -Parameters @{ Name = 'A'; Fail = $true } -Critical
        $null = Add-EobPlanStep -Plan $script:Plan -Action 'B' -Title 'B' -Handler 'Invoke-EobTestWrite' -Parameters @{ Name = 'B' }
        $result = Invoke-EobPlan -Plan $script:Plan -Confirm:$false
        $result.Aborted | Should -BeTrue
        $result.Steps[1].Status | Should -Be 'Skipped'
        @(Get-EobTestCall).Count | Should -Be 1
    }

    It 'löst Secret-Verweise zur Laufzeit auf, ohne sie im Plan zu speichern' {
        $script:Plan.Secrets['InitialPassword'] = New-EobTestSecureString
        $step = Add-EobPlanStep -Plan $script:Plan -Action 'A' -Title 'A' -Handler 'Invoke-EobTestWrite' -Parameters @{ Name = 'A'; Secret = '@Secret:InitialPassword' }
        $step.Parameters['Secret'] | Should -Be '@Secret:InitialPassword'
        $null = Invoke-EobPlan -Plan $script:Plan -Confirm:$false
        (Get-EobTestCall)[0].SecretType | Should -Be 'SecureString'
    }

    It 'übergibt die Plan-Konfiguration an Parameter mit dem Wert @Config' {
        $plan = New-EobPlan -Kind 'Test' -Context $script:Context -Config ([pscustomobject]@{ Marker = 'cfg-1' })
        $null = Add-EobPlanStep -Plan $plan -Action 'C' -Title 'C' -Handler 'Invoke-EobTestConfig' -Parameters @{ Config = '@Config' }
        $null = Invoke-EobPlan -Plan $plan -Confirm:$false
        (Get-EobTestCall)[0].SecretType | Should -Be 'cfg-1'
    }

    It 'lässt den Schritt fehlschlagen, wenn ein Secret fehlt' {
        $null = Add-EobPlanStep -Plan $script:Plan -Action 'A' -Title 'A' -Handler 'Invoke-EobTestWrite' -Parameters @{ Name = 'A'; Secret = '@Secret:Fehlt' }
        $result = Invoke-EobPlan -Plan $script:Plan -Confirm:$false
        $result.Steps[0].Status | Should -Be 'Failed'
        @(Get-EobTestCall).Count | Should -Be 0
    }

    It 'führt keine Handler außerhalb von easyONB-Modulen aus' {
        $null = Add-EobPlanStep -Plan $script:Plan -Action 'X' -Title 'X' -Handler 'Invoke-ForeignHandler' -Parameters @{ Name = 'X' }
        $null = Add-EobPlanStep -Plan $script:Plan -Action 'Y' -Title 'Y' -Handler 'Remove-Item' -Parameters @{ Path = '/tmp/x' }
        $result = Invoke-EobPlan -Plan $script:Plan -Confirm:$false
        $result.Steps[0].Status | Should -Be 'Failed'
        $result.Steps[0].Message | Should -Match 'nicht zulässig'
        $result.Steps[1].Status | Should -Be 'Failed'
    }

    It 'verweigert die Ausführung bei blockierenden Befunden' {
        $null = Add-EobPlanStep -Plan $script:Plan -Action 'A' -Title 'A' -Handler 'Invoke-EobTestWrite' -Parameters @{ Name = 'A' }
        Add-EobPlanFinding -Plan $script:Plan -Severity Error -Code 'TEST' -Message 'blockiert'
        Test-EobPlanExecutable -Plan $script:Plan | Should -BeFalse
        { Invoke-EobPlan -Plan $script:Plan -Confirm:$false } | Should -Throw '*blockiert*'
        @(Get-EobTestCall).Count | Should -Be 0
    }

    It 'sperrt Live-Ausführungen ohne beschreibbares Audit-Log' {
        $null = Add-EobPlanStep -Plan $script:Plan -Action 'A' -Title 'A' -Handler 'Invoke-EobTestWrite' -Parameters @{ Name = 'A' }
        Mock -ModuleName easyONB.Core Test-EobAuditWritable { $false }
        { Invoke-EobPlan -Plan $script:Plan -Confirm:$false } | Should -Throw '*Audit*'
        @(Get-EobTestCall).Count | Should -Be 0
    }

    It 'bricht nach Anforderung vor dem nächsten Schritt ab' {
        $null = Add-EobPlanStep -Plan $script:Plan -Action 'A' -Title 'A' -Handler 'Invoke-EobTestWrite' -Parameters @{ Name = 'A' }
        $null = Add-EobPlanStep -Plan $script:Plan -Action 'B' -Title 'B' -Handler 'Invoke-EobTestWrite' -Parameters @{ Name = 'B' }
        $null = Invoke-EobPlanStep -Plan $script:Plan -Step $script:Plan.Steps[0]
        Stop-EobPlan -Plan $script:Plan -Confirm:$false
        $second = Invoke-EobPlanStep -Plan $script:Plan -Step $script:Plan.Steps[1]
        $second.Status | Should -Be 'Skipped'
        Get-EobPlanOutcome -Plan $script:Plan | Should -Be 'Cancelled'
    }

    It 'führt nur die angeforderten Phasen aus' {
        $null = Add-EobPlanStep -Plan $script:Plan -Action 'A' -Title 'A' -Handler 'Invoke-EobTestWrite' -Parameters @{ Name = 'A' } -Phase 'Immediate'
        $null = Add-EobPlanStep -Plan $script:Plan -Action 'B' -Title 'B' -Handler 'Invoke-EobTestWrite' -Parameters @{ Name = 'B' } -Phase 'Retention'
        $result = Invoke-EobPlan -Plan $script:Plan -IncludePhase 'Immediate' -Confirm:$false
        $result.Steps[0].Status | Should -Be 'Succeeded'
        $result.Steps[1].Status | Should -Be 'Planned'
        $result.Status | Should -Be 'Succeeded'
    }

    It 'protokolliert Live-Schritte im Audit-Log' {
        $null = Add-EobPlanStep -Plan $script:Plan -Action 'CreateUser' -Title 'A' -Handler 'Invoke-EobTestWrite' -Parameters @{ Name = 'A' } -Target 'mmuster'
        $null = Invoke-EobPlan -Plan $script:Plan -Confirm:$false
        $entries = @(Get-EobAuditEntry -OperationId $script:Plan.OperationId)
        $entries.Action | Should -Contain 'CreateUser'
        $entries.Action | Should -Contain 'TestStarted'
        $entries.Action | Should -Contain 'TestCompleted'
    }
}

Describe 'Integrationsstatus' {
    It 'meldet fehlende Statusfunktionen als NotInstalled statt abzubrechen' {
        $result = @(Get-EobIntegrationStatus -Config $null)
        $result.Count | Should -BeGreaterThan 0
        $result | ForEach-Object { $_.State | Should -BeIn @('Available', 'Connected', 'NotConnected', 'NotConfigured', 'NotInstalled', 'Error', 'Disabled') }
    }
}
