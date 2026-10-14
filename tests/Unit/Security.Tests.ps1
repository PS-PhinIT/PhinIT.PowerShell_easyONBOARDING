#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.3.0' }

# Hinweis: Kennwörter werden ausschließlich über boolesche Ausdrücke geprüft. Dadurch enthalten auch
# Fehlermeldungen von Pester niemals einen Kennwortwert.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath '../TestHelpers.ps1')
    Import-EobTestModule

    function New-TestConfig {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Testhilfe im TestDrive bzw. im Speicher.')]
        param([string]$Content)
        $path = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.ini')
        Set-Content -LiteralPath $path -Value $Content -Encoding utf8
        return Import-EobConfiguration -Path $path -NoIncludes
    }

    $script:DefaultConfig = New-TestConfig -Content "[Company]`nCompanyActiveDirectoryDomain=example.com"
}

Describe 'Kennwortgenerierung' {
    It 'liefert standardmäßig einen SecureString' {
        New-EobPassword | Should -BeOfType [System.Security.SecureString]
    }

    It 'erfüllt die Richtlinie bei 200 Kennwörtern und erzeugt keine Duplikate' {
        $policy = Get-EobPasswordPolicy -Config $script:DefaultConfig
        $seen = [System.Collections.Generic.HashSet[string]]::new()
        $allValid = $true
        $duplicates = 0
        for ($i = 0; $i -lt 200; $i++) {
            $pw = ConvertTo-EobPlainText -SecureString (New-EobPassword -Policy $policy)
            $checks = @(
                ($pw.Length -eq $policy.Length)
                (([regex]::Matches($pw, '[A-Z]')).Count -ge $policy.MinUpperCase)
                (([regex]::Matches($pw, '[a-z]')).Count -ge $policy.MinLowerCase)
                (([regex]::Matches($pw, '[0-9]')).Count -ge $policy.MinDigits)
                (([regex]::Matches($pw, '[^A-Za-z0-9]')).Count -ge $policy.MinSpecialChars)
                (([regex]::Matches($pw, '[^A-Za-z]')).Count -ge $policy.MinNonAlpha)
            )
            if ($checks -contains $false) { $allValid = $false }
            if (-not $seen.Add($pw)) { $duplicates++ }
        }
        $allValid | Should -BeTrue
        $duplicates | Should -Be 0
    }

    It 'vermeidet verwechselbare Zeichen' {
        $policy = Get-EobPasswordPolicy -Config $script:DefaultConfig
        $policy.ExcludeAmbiguous | Should -BeTrue
        $found = $false
        for ($i = 0; $i -lt 100; $i++) {
            if ((ConvertTo-EobPlainText -SecureString (New-EobPassword -Policy $policy)) -cmatch '[Il1O0o]') { $found = $true }
        }
        $found | Should -BeFalse
    }

    It 'verzichtet auf Sonderzeichen, wenn sie deaktiviert sind' {
        $config = New-TestConfig -Content "[PasswordFixGenerate]`nIncludeSpecialChars=False"
        $policy = Get-EobPasswordPolicy -Config $config
        $found = $false
        for ($i = 0; $i -lt 50; $i++) {
            if ((ConvertTo-EobPlainText -SecureString (New-EobPassword -Policy $policy)) -match '[^A-Za-z0-9]') { $found = $true }
        }
        $found | Should -BeFalse
    }

    It 'verweigert unerfüllbare Richtlinien' {
        $policy = [pscustomobject]@{ Length = 12; MinUpperCase = 5; MinLowerCase = 5; MinDigits = 5; MinSpecialChars = 0; MinNonAlpha = 0
            IncludeSpecialChars = $false; SpecialCharacters = ''; ExcludeAmbiguous = $false
        }
        { New-EobPassword -Policy $policy } | Should -Throw '*Mindestanzahlen*'
    }

    It 'verwendet ausschließlich einen kryptografisch sicheren Zufallsgenerator' {
        $source = Get-Content -LiteralPath (Join-Path (Get-EobTestRepoRoot) 'Modules/Security/easyONB.Security.psm1') -Raw
        $source | Should -Match 'RandomNumberGenerator'
        $source | Should -Not -Match 'Get-Random|System\.Random'
    }

    It 'berücksichtigt eine strengere Domänenrichtlinie' {
        $policy = Get-EobPasswordPolicy -Config $script:DefaultConfig -DomainPolicy ([pscustomobject]@{ MinPasswordLength = 24; ComplexityEnabled = $true })
        $policy.Length | Should -Be 24
        $policy.MinManualLength | Should -Be 24
        $policy.Source | Should -Match 'Domäne'
    }

    It 'schwächt die Komplexitätsprüfung durch die Domänenrichtlinie nicht ab' {
        $policy = Get-EobPasswordPolicy -Config $script:DefaultConfig -DomainPolicy ([pscustomobject]@{ MinPasswordLength = 7; ComplexityEnabled = $false })
        $policy.ComplexityEnabled | Should -BeTrue
        $policy.Length | Should -BeGreaterOrEqual 16
    }

    It 'wandelt SecureStrings für die einmalige Anzeige verlustfrei um' {
        $secure = New-EobPassword
        $plain = ConvertTo-EobPlainText -SecureString $secure
        $plain.Length | Should -Be $secure.Length
        ((ConvertTo-EobPlainText -SecureString (New-EobTestSecureString -Value $plain)) -ceq $plain) | Should -BeTrue
    }

    It 'bietet keine Klartextausgabe bei der Kennwortgenerierung an' {
        (Get-Command -Name 'New-EobPassword').Parameters.Keys | Should -Not -Contain 'AsPlainText'
        (Get-Command -Name 'Test-EobPasswordPolicy').Parameters['Password'].ParameterType | Should -Be ([System.Security.SecureString])
    }
}

Describe 'Kennwortprüfung' {
    BeforeAll {
        $script:Policy = Get-EobPasswordPolicy -Config $script:DefaultConfig
    }

    It 'meldet <Name> ohne das Kennwort auszugeben' -ForEach @(
        @{ Name = 'zu kurze Kennwörter'; Password = 'Ab1!'; Expected = 'mindestens' }
        @{ Name = 'fehlende Komplexität'; Password = 'nurkleinbuchstabenlang'; Expected = 'Kategorien' }
        @{ Name = 'enthaltenen Kontonamen'; Password = 'Xmmuster2026!Ab'; Expected = 'Kontonamen' }
        @{ Name = 'enthaltene Namensbestandteile'; Password = 'Mustermann#2026a'; Expected = 'Namensbestandteile' }
        @{ Name = 'verbreitete Kennwörter'; Password = 'Willkommen1!'; Expected = 'verbreitet' }
    ) {
        $secure = New-EobTestSecureString -Value $Password
        $result = Test-EobPasswordPolicy -Password $secure -Policy $script:Policy -SamAccountName 'mmuster' -DisplayName 'Max Mustermann'
        $result.IsValid | Should -BeFalse
        ($result.Violations -join ' ') | Should -Match $Expected
        (($result.Violations -join ' ').Contains($Password)) | Should -BeFalse
    }

    It 'akzeptiert generierte Kennwörter' {
        $secure = New-EobPassword -Policy $script:Policy
        (Test-EobPasswordPolicy -Password $secure -Policy $script:Policy -SamAccountName 'mmuster' -DisplayName 'Max Mustermann').IsValid | Should -BeTrue
    }

    It 'beschreibt die Richtlinie lesbar' {
        (Get-EobPasswordPolicyText -Policy $script:Policy)[0] | Should -Match 'Mindestlänge'
    }
}

Describe 'Privilegierte Gruppen' {
    It 'erkennt <Name>' -ForEach @(
        @{ Name = 'Domain Admins über die SID'; Group = 'S-1-5-21-1111-2222-3333-512' }
        @{ Name = 'Enterprise Admins über die SID'; Group = 'S-1-5-21-1111-2222-3333-519' }
        @{ Name = 'die eingebauten Administratoren'; Group = 'S-1-5-32-544' }
        @{ Name = 'deutsche Standardnamen'; Group = 'Domänen-Admins' }
        @{ Name = 'Schema Admins per DN'; Group = 'CN=Schema Admins,CN=Users,DC=example,DC=local' }
        @{ Name = 'DnsAdmins'; Group = 'DnsAdmins' }
        @{ Name = 'Exchange-Rollengruppen'; Group = 'Organization Management' }
        @{ Name = 'das Standardmuster *Admin*'; Group = 'SAP-Admins' }
    ) {
        (Test-EobPrivilegedGroup -Group $Group -Config $script:DefaultConfig).IsProtected | Should -BeTrue
    }

    It 'erkennt AdminSDHolder-geschützte Gruppenobjekte' {
        $group = [pscustomobject]@{ Name = 'Sonderrechte'; SamAccountName = 'Sonderrechte'; SID = 'S-1-5-21-1-2-3-4001'; AdminCount = 1 }
        (Test-EobPrivilegedGroup -Group $group -Config $script:DefaultConfig).IsProtected | Should -BeTrue
    }

    It 'erkennt konfigurierte Gruppen und verschachtelte Mitgliedschaften' {
        $config = New-TestConfig -Content "[Security]`nProtectedGroups=GRP-Tier0;S-1-5-21-1-2-3-9999`nProtectedGroupPatterns="
        (Test-EobPrivilegedGroup -Group 'grp-tier0' -Config $config).IsProtected | Should -BeTrue
        (Test-EobPrivilegedGroup -Group ([pscustomobject]@{ Name = 'X'; SID = 'S-1-5-21-1-2-3-9999' }) -Config $config).IsProtected | Should -BeTrue
        (Test-EobPrivilegedGroup -Group 'GRP-Helpdesk' -Config $config -NestedIn 'Domain Admins').IsProtected | Should -BeTrue
    }

    It 'lässt normale Gruppen zu und nennt Gründe nur bei Treffern' {
        $result = Test-EobPrivilegedGroup -Group 'GRP-Vertrieb' -Config $script:DefaultConfig
        $result.IsProtected | Should -BeFalse
        @($result.Reasons).Count | Should -Be 0
    }
}

Describe 'Geschützte Konten' {
    BeforeAll {
        $script:ProtectedConfig = New-TestConfig -Content @'
[Security]
BreakGlassAccounts=notfall1
ProtectedAccounts=S-1-5-21-1-2-3-7777
ServiceAccountPatterns=svc_*
ProtectedOUs=OU=Admins,DC=example,DC=local
'@
        function New-TestUser {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Testhilfe im TestDrive bzw. im Speicher.')]
            param([string]$Sam = 'mmuster', [string]$Sid = 'S-1-5-21-1-2-3-1500', [string]$Dn = 'CN=Max,OU=Mitarbeiter,DC=example,DC=local',
                [int]$AdminCount = 0, [object]$ObjectClass = 'user', [bool]$Critical = $false)
            [pscustomobject]@{ SamAccountName = $Sam; SID = $Sid; DistinguishedName = $Dn; AdminCount = $AdminCount; ObjectClass = $ObjectClass; IsCriticalSystemObject = $Critical }
        }
    }

    It 'sperrt <Name>' -ForEach @(
        @{ Name = 'das eigene Konto'; User = @{ Sid = 'S-1-5-21-1-2-3-4242' }; Current = 'S-1-5-21-1-2-3-4242' }
        @{ Name = 'das eingebaute Administratorkonto'; User = @{ Sid = 'S-1-5-21-1-2-3-500'; Sam = 'Administrator' }; Current = '' }
        @{ Name = 'krbtgt'; User = @{ Sid = 'S-1-5-21-1-2-3-502'; Sam = 'krbtgt' }; Current = '' }
        @{ Name = 'Break-Glass-Konten'; User = @{ Sam = 'Notfall1' }; Current = '' }
        @{ Name = 'konfigurierte SIDs'; User = @{ Sid = 'S-1-5-21-1-2-3-7777' }; Current = '' }
        @{ Name = 'Dienstkonten'; User = @{ Sam = 'svc_backup' }; Current = '' }
        @{ Name = 'Konten in geschützten OUs'; User = @{ Dn = 'CN=A,OU=Admins,DC=example,DC=local' }; Current = '' }
        @{ Name = 'Computerobjekte'; User = @{ ObjectClass = @('top', 'person', 'user', 'computer') }; Current = '' }
        @{ Name = 'kritische Systemobjekte'; User = @{ Critical = $true }; Current = '' }
    ) {
        $user = New-TestUser @User
        $result = Test-EobProtectedAccount -User $user -Config $script:ProtectedConfig -CurrentUserSid $Current
        $result.IsBlocked | Should -BeTrue
        @($result.BlockReasons).Count | Should -BeGreaterThan 0
    }

    It 'verlangt eine gesonderte Bestätigung für privilegierte Konten' {
        $result = Test-EobProtectedAccount -User (New-TestUser -AdminCount 1) -Config $script:ProtectedConfig -PrivilegedGroups 'Domain Admins'
        $result.IsBlocked | Should -BeFalse
        $result.RequiresAcknowledgement | Should -BeTrue
        @($result.AcknowledgementReasons).Count | Should -Be 2
    }

    It 'lässt normale Benutzerkonten zu' {
        $result = Test-EobProtectedAccount -User (New-TestUser) -Config $script:ProtectedConfig -CurrentUserSid 'S-1-5-21-1-2-3-4242'
        $result.IsBlocked | Should -BeFalse
        $result.RequiresAcknowledgement | Should -BeFalse
    }
}

Describe 'Escaping' {
    It 'maskiert LDAP-Sonderzeichen nach RFC 4515' {
        ConvertTo-EobLdapFilterValue -Value '*)(uid=*))(|(uid=*' | Should -Be '\2a\29\28uid=\2a\29\29\28|\28uid=\2a'
        ConvertTo-EobLdapFilterValue -Value 'a\b' | Should -Be 'a\5cb'
        ConvertTo-EobLdapFilterValue -Value ('x' + [char]0) | Should -Be 'x\00'
        ConvertTo-EobLdapFilterValue -Value 'Müller' | Should -Be 'Müller'
    }

    It 'erzeugt sichere Literale für die AD-Filtersyntax' {
        ConvertTo-EobAdFilterLiteral -Value "O'Brien" | Should -Be "'O''Brien'"
    }
}

Describe 'Eingabeformate' {
    It 'prüft SamAccountName: <Value> -> <Expected>' -ForEach @(
        @{ Value = 'mmuster'; Expected = $true }, @{ Value = 'anna-lena.m'; Expected = $true }
        @{ Value = 'mmuster.'; Expected = $false }, @{ Value = ('a' * 21); Expected = $false }
        @{ Value = 'max muster'; Expected = $false }, @{ Value = 'max@muster'; Expected = $false }, @{ Value = ''; Expected = $false }
    ) {
        Test-EobSamAccountName -Value $Value | Should -Be $Expected
    }

    It 'prüft UPN: <Value> -> <Expected>' -ForEach @(
        @{ Value = 'max.mustermann@example.com'; Expected = $true }, @{ Value = "o'brien@example.com"; Expected = $true }
        @{ Value = '.max@example.com'; Expected = $false }, @{ Value = 'max..m@example.com'; Expected = $false }
        @{ Value = ('a' * 65 + '@example.com'); Expected = $false }, @{ Value = 'max@exa mple.com'; Expected = $false }
        @{ Value = 'max'; Expected = $false }, @{ Value = 'mäx@example.com'; Expected = $false }
    ) {
        Test-EobUserPrincipalName -Value $Value | Should -Be $Expected
    }

    It 'prüft Personennamen: <Value> -> <Expected>' -ForEach @(
        @{ Value = 'Anne-Marie'; Expected = $true }, @{ Value = "O'Brien"; Expected = $true }, @{ Value = 'Müller'; Expected = $true }
        @{ Value = 'José'; Expected = $true }, @{ Value = 'van der Berg'; Expected = $true }
        @{ Value = 'Max<script>'; Expected = $false }, @{ Value = ''; Expected = $false }, @{ Value = '123'; Expected = $false }
    ) {
        Test-EobPersonName -Value $Value | Should -Be $Expected
    }

    It 'prüft Telefonnummern: <Value> -> <Expected>' -ForEach @(
        @{ Value = '+49 (0) 30 123-45'; Expected = $true }, @{ Value = '0761/12345'; Expected = $true }
        @{ Value = 'abc'; Expected = $false }, @{ Value = '12'; Expected = $false }
    ) {
        Test-EobPhoneNumber -Value $Value | Should -Be $Expected
    }

    It 'lehnt Steuerzeichen in Freitext ab' {
        Test-EobSafeText -Value "Abteilung`u{0007}" | Should -BeFalse
        Test-EobSafeText -Value "Zeile 1`r`nZeile 2" | Should -BeTrue
        Test-EobSafeText -Value ('x' * 2000) -MaxLength 1024 | Should -BeFalse
    }
}

Describe 'Bestätigung kritischer Vorgänge' {
    It '<Name> bestätigt Live-Ausführungen (SupportsShouldProcess, ConfirmImpact High)' -ForEach @(
        @{ Name = 'Invoke-EobPlan' }
        @{ Name = 'Invoke-EobOnboardingPlan' }
        @{ Name = 'Invoke-EobOffboardingPlan' }
        @{ Name = 'Invoke-EobOffboardingFinalDeletion' }
        @{ Name = 'Remove-EobAdUserAccount' }
    ) {
        $metadata = [System.Management.Automation.CommandMetadata]::new((Get-Command -Name $Name))
        $metadata.SupportsShouldProcess | Should -BeTrue
        $metadata.ConfirmImpact | Should -Be ([System.Management.Automation.ConfirmImpact]::High)
    }
}
