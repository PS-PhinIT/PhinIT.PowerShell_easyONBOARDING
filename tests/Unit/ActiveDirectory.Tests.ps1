#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.3.0' }

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath '../TestHelpers.ps1')
    Import-EobTestModule

    $script:ModuleName = 'easyONB.ActiveDirectory'
    $iniPath = Join-Path $TestDrive 'ad.ini'
    Set-Content -LiteralPath $iniPath -Encoding utf8 -Value @'
[ActiveDirectory]
PreferredDomainController=dc01.example.local
[Company]
CompanyActiveDirectoryDomain=example.com
[Security]
ServiceAccountPatterns=svc_*
'@
    $script:Config = Import-EobConfiguration -Path $iniPath -NoIncludes
    $null = Initialize-EobLogging -Directory (Join-Path $TestDrive 'logs')

    function script:New-MockAdUser {
        param(
            [string]$Sam = 'mmuster', [string]$Sid = 'S-1-5-21-1-2-3-1500', [bool]$Enabled = $true,
            [string]$Dn = 'CN=Max Muster,OU=Mitarbeiter,DC=example,DC=local', [int]$AdminCount = 0,
            [string]$Guid = '11111111-2222-3333-4444-555555555555', [bool]$ProtectedFromDeletion = $false,
            [string[]]$MemberOf = @('CN=GRP-Vertrieb,OU=Gruppen,DC=example,DC=local'), [string]$Manager = ''
        )
        [pscustomobject]@{
            SamAccountName = $Sam; SID = $Sid; Enabled = $Enabled; DistinguishedName = $Dn; adminCount = $AdminCount
            ObjectGUID = $Guid; ProtectedFromAccidentalDeletion = $ProtectedFromDeletion; ObjectClass = 'user'
            DisplayName = 'Max Muster'; GivenName = 'Max'; Surname = 'Muster'; UserPrincipalName = "$Sam@example.com"
            mail = "$Sam@example.com"; memberOf = $MemberOf; primaryGroupID = 513; manager = $Manager; directReports = @()
        }
    }

    function script:Connect-TestAd {
        Mock -ModuleName $script:ModuleName Get-ADDomain {
            [pscustomobject]@{ DNSRoot = 'example.local'; NetBIOSName = 'EXAMPLE'; DistinguishedName = 'DC=example,DC=local'; DomainSID = 'S-1-5-21-1-2-3'; PDCEmulator = 'dc01.example.local' }
        }
        $null = Initialize-EobAdConnection -Config $script:Config
    }
}

Describe 'Verbindung' {
    It 'verwendet den konfigurierten Domänencontroller für alle Operationen' {
        Connect-TestAd
        $info = Get-EobAdConnectionInfo
        $info.Connected | Should -BeTrue
        $info.Server | Should -Be 'dc01.example.local'
        $info.Domain.DomainSid | Should -Be 'S-1-5-21-1-2-3'
        Should -Invoke -ModuleName $script:ModuleName Get-ADDomain -ParameterFilter { $Server -eq 'dc01.example.local' }
    }

    It 'ermittelt ohne Konfiguration automatisch einen beschreibbaren DC' {
        Mock -ModuleName $script:ModuleName Get-ADDomainController { [pscustomobject]@{ HostName = @('dc02.example.local') } }
        Mock -ModuleName $script:ModuleName Get-ADDomain { [pscustomobject]@{ DNSRoot = 'example.local'; NetBIOSName = 'EXAMPLE'; DistinguishedName = 'DC=example,DC=local'; DomainSID = 'S-1-5-21-1-2-3' } }
        (Initialize-EobAdConnection -Config $null).Server | Should -Be 'dc02.example.local'
        Should -Invoke -ModuleName $script:ModuleName Get-ADDomainController -ParameterFilter { $Discover -and $Writable }
    }

    It 'liefert bei Verbindungsfehlern einen Status statt einer Exception' {
        Mock -ModuleName $script:ModuleName Get-ADDomain { throw 'Unable to contact the server' }
        $info = Initialize-EobAdConnection -Config $script:Config
        $info.Connected | Should -BeFalse
        $info.LastError | Should -Match 'Unable to contact'
        (Get-EobAdStatus -Config $script:Config).State | Should -Be 'NotConnected'
        { Find-EobAdUser -SearchText 'max' } | Should -Throw '*Keine Active-Directory-Verbindung*'
    }

    It 'meldet ein fehlendes AD-Modul mit Installationshinweis' {
        Mock -ModuleName $script:ModuleName Test-EobAdModuleAvailable { $false }
        InModuleScope $script:ModuleName { $script:AdState.ModuleAvailable = $false }
        $status = Get-EobAdStatus -Config $script:Config
        $status.State | Should -Be 'NotInstalled'
        $status.Hint | Should -Match 'Rsat'
        InModuleScope $script:ModuleName { $script:AdState.ModuleAvailable = $true }
    }
}

Describe 'Suche und Auflösung' {
    BeforeEach { Connect-TestAd }

    It 'maskiert Suchbegriffe im LDAP-Filter (Schutz vor LDAP-Injection)' {
        Mock -ModuleName $script:ModuleName Get-ADUser { @() }
        $null = @(Find-EobAdUser -SearchText '*)(objectClass=*')
        Should -Invoke -ModuleName $script:ModuleName Get-ADUser -Times 1 -ParameterFilter {
            $LDAPFilter -like '*\2a\29\28objectClass=\2a*' -and $LDAPFilter -notlike '*(objectClass=*)(objectClass=*' -and $Server -eq 'dc01.example.local'
        }
    }

    It 'verlangt mindestens zwei Zeichen' {
        { Find-EobAdUser -SearchText 'a' } | Should -Throw '*mindestens 2 Zeichen*'
    }

    It 'normalisiert Suchergebnisse' {
        Mock -ModuleName $script:ModuleName Get-ADUser { New-MockAdUser }
        $result = @(Find-EobAdUser -SearchText 'muster')
        $result.Count | Should -Be 1
        $result[0].SamAccountName | Should -Be 'mmuster'
        $result[0].ParentContainer | Should -Be 'OU=Mitarbeiter,DC=example,DC=local'
        $result[0].ObjectGuid | Should -Be '11111111-2222-3333-4444-555555555555'
    }

    It 'löst UPN und E-Mail über einen maskierten LDAP-Filter auf' {
        Mock -ModuleName $script:ModuleName Get-ADUser { New-MockAdUser }
        (Resolve-EobAdUser -Identity 'mmuster@example.com').SamAccountName | Should -Be 'mmuster'
        Should -Invoke -ModuleName $script:ModuleName Get-ADUser -ParameterFilter { $LDAPFilter -like '*(userPrincipalName=mmuster@example.com)*' }
    }

    It 'lehnt mehrdeutige und unbekannte Angaben ab' {
        Mock -ModuleName $script:ModuleName Get-ADUser { @((New-MockAdUser), (New-MockAdUser -Sam 'mmuster2')) }
        { Resolve-EobAdUser -Identity 'mmuster' } | Should -Throw '*nicht eindeutig*'
        Mock -ModuleName $script:ModuleName Get-ADUser { @() }
        { Resolve-EobAdUser -Identity 'niemand' } | Should -Throw '*nicht gefunden*'
    }

    It 'meldet belegte SamAccountNames, UPNs und E-Mail-Adressen einschließlich proxyAddresses' {
        Mock -ModuleName $script:ModuleName Get-ADObject {
            @(
                [pscustomobject]@{ DistinguishedName = 'CN=A,DC=example,DC=local'; sAMAccountName = 'MMUSTER'; userPrincipalName = ''; mail = ''; proxyAddresses = @() }
                [pscustomobject]@{ DistinguishedName = 'CN=Verteiler,DC=example,DC=local'; sAMAccountName = 'vt'; userPrincipalName = ''; mail = ''; proxyAddresses = @('SMTP:max.muster@example.com') }
            )
        }
        $conflicts = @(Get-EobAdIdentityConflict -SamAccountName 'mmuster' -UserPrincipalName 'max.muster@example.com' -Mail 'max.muster@example.com')
        $conflicts.Attribute | Should -Contain 'SamAccountName'
        $conflicts.Attribute | Should -Contain 'Mail'
        $conflicts.Attribute | Should -Not -Contain 'UserPrincipalName'
    }

    It 'ermittelt privilegierte Mitgliedschaften über LDAP_MATCHING_RULE_IN_CHAIN' {
        Mock -ModuleName $script:ModuleName Get-ADGroup {
            @(
                [pscustomobject]@{ Name = 'GRP-Vertrieb'; SamAccountName = 'GRP-Vertrieb'; DistinguishedName = 'CN=GRP-Vertrieb,DC=example,DC=local'; SID = 'S-1-5-21-1-2-3-3001'; adminCount = 0 }
                [pscustomobject]@{ Name = 'Domänen-Admins'; SamAccountName = 'Domänen-Admins'; DistinguishedName = 'CN=Domänen-Admins,DC=example,DC=local'; SID = 'S-1-5-21-1-2-3-512'; adminCount = 1 }
            )
        }
        $result = @(Get-EobAdPrivilegedMembership -DistinguishedName 'CN=Max (Test),DC=example,DC=local')
        $result | Should -Be @('Domänen-Admins')
        Should -Invoke -ModuleName $script:ModuleName Get-ADGroup -ParameterFilter { $LDAPFilter -like '*1.2.840.113556.1.4.1941*' -and $LDAPFilter -like '*CN=Max \28Test\29*' }
    }
}

Describe 'Schreibende Operationen' {
    BeforeEach {
        Connect-TestAd
        Mock -ModuleName $script:ModuleName Get-EobCurrentIdentity { [pscustomobject]@{ Name = 'EXAMPLE\admin'; Sid = 'S-1-5-21-1-2-3-4242' } }
        Mock -ModuleName $script:ModuleName Get-ADUser { New-MockAdUser }
        Mock -ModuleName $script:ModuleName Get-ADGroup {
            if ($LDAPFilter) { return @() }
            [pscustomobject]@{ Name = [string]$Identity; SamAccountName = [string]$Identity; DistinguishedName = "CN=$Identity,OU=Gruppen,DC=example,DC=local"; SID = 'S-1-5-21-1-2-3-3001'; adminCount = 0 }
        }
        Mock -ModuleName $script:ModuleName Add-ADGroupMember { }
        Mock -ModuleName $script:ModuleName Disable-ADAccount { }
        Mock -ModuleName $script:ModuleName Remove-ADObject { }
        Mock -ModuleName $script:ModuleName New-ADUser { [pscustomobject]@{ DistinguishedName = 'CN=Neu,OU=Mitarbeiter,DC=example,DC=local'; ObjectGUID = 'aaaaaaaa-0000-0000-0000-000000000001' } }
        Mock -ModuleName $script:ModuleName Set-ADUser { }
        Mock -ModuleName $script:ModuleName Set-ADAccountPassword { }
    }

    It 'weist normale Gruppen zu' {
        (Add-EobAdGroupMembership -Identity 'mmuster' -Group 'GRP-Vertrieb' -Confirm:$false).Status | Should -Be 'Succeeded'
        Should -Invoke -ModuleName $script:ModuleName Add-ADGroupMember -Times 1
    }

    It 'blockiert privilegierte Gruppen immer' {
        Mock -ModuleName $script:ModuleName Get-ADGroup {
            if ($LDAPFilter) { return @() }
            [pscustomobject]@{ Name = 'Domain Admins'; SamAccountName = 'Domain Admins'; DistinguishedName = 'CN=Domain Admins,CN=Users,DC=example,DC=local'; SID = 'S-1-5-21-1-2-3-512'; adminCount = 1 }
        }
        { Add-EobAdGroupMembership -Identity 'mmuster' -Group 'Domain Admins' -Confirm:$false } | Should -Throw '*blockiert*'
        Should -Invoke -ModuleName $script:ModuleName Add-ADGroupMember -Times 0
    }

    It 'blockiert Gruppen, die in privilegierten Gruppen verschachtelt sind' {
        Mock -ModuleName $script:ModuleName Get-ADGroup {
            if ($LDAPFilter) { return [pscustomobject]@{ Name = 'Enterprise Admins'; SamAccountName = 'Enterprise Admins'; DistinguishedName = 'CN=Enterprise Admins,DC=example,DC=local'; SID = 'S-1-5-21-1-2-3-519'; adminCount = 1 } }
            [pscustomobject]@{ Name = 'GRP-Helpdesk'; SamAccountName = 'GRP-Helpdesk'; DistinguishedName = 'CN=GRP-Helpdesk,DC=example,DC=local'; SID = 'S-1-5-21-1-2-3-3100'; adminCount = 0 }
        }
        { Add-EobAdGroupMembership -Identity 'mmuster' -Group 'GRP-Helpdesk' -Confirm:$false } | Should -Throw '*Verschachtelt*'
        Should -Invoke -ModuleName $script:ModuleName Add-ADGroupMember -Times 0
    }

    It 'behandelt bestehende Mitgliedschaften als Erfolg' {
        Mock -ModuleName $script:ModuleName Add-ADGroupMember { throw 'The specified account name is already a member of the group' }
        (Add-EobAdGroupMembership -Identity 'mmuster' -Group 'GRP-Vertrieb' -Confirm:$false).Message | Should -Match 'Bereits Mitglied'
    }

    It 'ändert mit -WhatIf nichts' {
        $result = Add-EobAdGroupMembership -Identity 'mmuster' -Group 'GRP-Vertrieb' -WhatIf
        $result.Message | Should -Match 'Simulation'
        $null = Disable-EobAdUserAccount -Identity 'mmuster' -WhatIf
        $null = New-EobAdUserAccount -SamAccountName 'neu' -UserPrincipalName 'neu@example.com' -Name 'Neu' -DisplayName 'Neu' -GivenName 'N' -Surname 'Eu' -Path 'OU=M,DC=example,DC=local' -AccountPassword (New-EobTestSecureString) -WhatIf
        Should -Invoke -ModuleName $script:ModuleName Add-ADGroupMember -Times 0
        Should -Invoke -ModuleName $script:ModuleName Disable-ADAccount -Times 0
        Should -Invoke -ModuleName $script:ModuleName New-ADUser -Times 0
    }

    It 'schützt das eigene Konto des Administrators' {
        Mock -ModuleName $script:ModuleName Get-ADUser { New-MockAdUser -Sid 'S-1-5-21-1-2-3-4242' }
        { Disable-EobAdUserAccount -Identity 'mmuster' -Confirm:$false } | Should -Throw '*eigene*'
        Should -Invoke -ModuleName $script:ModuleName Disable-ADAccount -Times 0
    }

    It 'schützt Dienstkonten und privilegierte Konten ohne gesonderte Bestätigung' {
        Mock -ModuleName $script:ModuleName Get-ADUser { New-MockAdUser -Sam 'svc_backup' }
        { Disable-EobAdUserAccount -Identity 'svc_backup' -Confirm:$false } | Should -Throw '*Dienstkonto*'
        Mock -ModuleName $script:ModuleName Get-ADUser { New-MockAdUser -AdminCount 1 }
        { Disable-EobAdUserAccount -Identity 'mmuster' -Confirm:$false } | Should -Throw '*privilegiertes Konto*'
        (Disable-EobAdUserAccount -Identity 'mmuster' -AllowPrivileged -Confirm:$false).Status | Should -Be 'Succeeded'
    }

    It 'lässt nur zulässige Attribute und Parameter zu' {
        { Set-EobAdUserAttribute -Identity 'mmuster' -Replace @{ userAccountControl = 512 } -Confirm:$false } | Should -Throw '*Unzulässiges*'
        { Set-EobAdUserAttribute -Identity 'mmuster' -Replace @{ servicePrincipalName = 'x' } -Confirm:$false } | Should -Throw '*Unzulässiges*'
        { New-EobAdUserAccount -SamAccountName 'neu' -UserPrincipalName 'neu@example.com' -Name 'N' -DisplayName 'N' -GivenName 'N' -Surname 'N' -Path 'OU=M,DC=example,DC=local' -AccountPassword (New-EobTestSecureString) -Attributes @{ AllowReversiblePasswordEncryption = $true } -Confirm:$false } | Should -Throw '*Unzulässiger*'
        Should -Invoke -ModuleName $script:ModuleName Set-ADUser -Times 0
    }

    It 'leert Attribute mit leerem Wert statt sie auf einen Leerstring zu setzen' {
        $null = Set-EobAdUserAttribute -Identity 'mmuster' -Replace @{ title = 'Neu'; department = '' } -Confirm:$false
        Should -Invoke -ModuleName $script:ModuleName Set-ADUser -ParameterFilter { $Replace['title'] -eq 'Neu' -and $Clear -contains 'department' }
    }

    It 'legt Benutzer mit den übergebenen Werten an' {
        $result = New-EobAdUserAccount -SamAccountName 'neu' -UserPrincipalName 'neu@example.com' -Name 'Neu Mitarbeiter' -DisplayName 'Neu Mitarbeiter' -GivenName 'Neu' -Surname 'Mitarbeiter' -Path 'OU=M,DC=example,DC=local' -AccountPassword (New-EobTestSecureString) -Enabled $false -Attributes @{ Title = 'Test'; Department = '' } -OtherAttributes @{ mail = 'neu@example.com' } -Confirm:$false
        $result.Data.UserObjectGuid | Should -Be 'aaaaaaaa-0000-0000-0000-000000000001'
        Should -Invoke -ModuleName $script:ModuleName New-ADUser -ParameterFilter {
            $SamAccountName -eq 'neu' -and $Title -eq 'Test' -and -not $PSBoundParameters.ContainsKey('Department') -and $OtherAttributes['mail'] -eq 'neu@example.com' -and $Server -eq 'dc01.example.local'
        }
    }

    It 'lehnt ungültige Kontonamen ab' {
        { New-EobAdUserAccount -SamAccountName 'viel zu langer name mit leerzeichen' -UserPrincipalName 'x@example.com' -Name 'N' -DisplayName 'N' -GivenName 'N' -Surname 'N' -Path 'OU=M,DC=example,DC=local' -AccountPassword (New-EobTestSecureString) -Confirm:$false } | Should -Throw '*SamAccountName*'
    }

    It 'setzt Kennwörter zurück, ohne sie zu protokollieren' {
        $plain = 'Unverwechselbar!Kennwort2026'
        Add-EobRedactionValue -Value $plain
        $null = Reset-EobAdUserPassword -Identity 'mmuster' -NewPassword (New-EobTestSecureString -Value $plain) -ChangePasswordAtLogon $true -Confirm:$false
        Should -Invoke -ModuleName $script:ModuleName Set-ADAccountPassword -ParameterFilter { $Reset }
        Should -Invoke -ModuleName $script:ModuleName Set-ADUser -ParameterFilter { $ChangePasswordAtLogon -eq $true }
        $logText = (Get-ChildItem (Join-Path $TestDrive 'logs') -Recurse -File | Get-Content -Raw) -join ''
        $logText.Contains($plain) | Should -BeFalse
        Remove-EobRedactionValue -All
    }
}

Describe 'Löschschutz und Verschieben' {
    BeforeEach {
        Connect-TestAd
        Mock -ModuleName $script:ModuleName Get-EobCurrentIdentity { [pscustomobject]@{ Name = 'EXAMPLE\admin'; Sid = 'S-1-5-21-1-2-3-4242' } }
        Mock -ModuleName $script:ModuleName Get-ADGroup { @() }
        Mock -ModuleName $script:ModuleName Remove-ADObject { }
        Mock -ModuleName $script:ModuleName Move-ADObject { [pscustomobject]@{ DistinguishedName = 'CN=Max Muster,OU=Ausgeschieden,DC=example,DC=local' } }
        Mock -ModuleName $script:ModuleName Get-ADObject { [pscustomobject]@{ ObjectClass = 'organizationalUnit' } }
    }

    It 'löscht nicht bei abweichender ObjectGUID' {
        Mock -ModuleName $script:ModuleName Get-ADUser { New-MockAdUser -Enabled $false }
        { Remove-EobAdUserAccount -Identity 'mmuster' -ExpectedObjectGuid '99999999-0000-0000-0000-000000000000' -Confirm:$false } | Should -Throw '*ObjectGUID*'
        Should -Invoke -ModuleName $script:ModuleName Remove-ADObject -Times 0
    }

    It 'löscht keine aktiven oder vor Löschung geschützten Konten' {
        Mock -ModuleName $script:ModuleName Get-ADUser { New-MockAdUser -Enabled $true }
        { Remove-EobAdUserAccount -Identity 'mmuster' -ExpectedObjectGuid '11111111-2222-3333-4444-555555555555' -Confirm:$false } | Should -Throw '*aktiviert*'
        Mock -ModuleName $script:ModuleName Get-ADUser { New-MockAdUser -Enabled $false -ProtectedFromDeletion $true }
        { Remove-EobAdUserAccount -Identity 'mmuster' -ExpectedObjectGuid '11111111-2222-3333-4444-555555555555' -Confirm:$false } | Should -Throw '*geschützt*'
        Should -Invoke -ModuleName $script:ModuleName Remove-ADObject -Times 0
    }

    It 'löscht bei allen erfüllten Bedingungen rekursiv' {
        Mock -ModuleName $script:ModuleName Get-ADUser { New-MockAdUser -Enabled $false }
        (Remove-EobAdUserAccount -Identity 'mmuster' -ExpectedObjectGuid '11111111-2222-3333-4444-555555555555' -Confirm:$false).Status | Should -Be 'Succeeded'
        Should -Invoke -ModuleName $script:ModuleName Remove-ADObject -Times 1 -ParameterFilter { $Recursive }
    }

    It 'verschiebt Konten und überspringt, wenn das Ziel bereits erreicht ist' {
        Mock -ModuleName $script:ModuleName Get-ADUser { New-MockAdUser }
        (Move-EobAdUserAccount -Identity 'mmuster' -TargetPath 'OU=Ausgeschieden,DC=example,DC=local' -Confirm:$false).Data.UserDistinguishedName | Should -Match 'Ausgeschieden'
        (Move-EobAdUserAccount -Identity 'mmuster' -TargetPath 'OU=Mitarbeiter,DC=example,DC=local' -Confirm:$false).Status | Should -Be 'Skipped'
    }

    It 'verschiebt keine vor Löschung geschützten Konten' {
        Mock -ModuleName $script:ModuleName Get-ADUser { New-MockAdUser -ProtectedFromDeletion $true }
        { Move-EobAdUserAccount -Identity 'mmuster' -TargetPath 'OU=Ausgeschieden,DC=example,DC=local' -Confirm:$false } | Should -Throw '*geschützt*'
        Should -Invoke -ModuleName $script:ModuleName Move-ADObject -Times 0
    }
}

Describe 'Normalisierung und Zustandsbericht' {
    BeforeEach { Connect-TestAd }

    It 'erkennt eingeschränkte Anmeldezeiten und fehlende Eigenschaften unter StrictMode' {
        $user = [pscustomobject]@{ SamAccountName = 'x'; logonHours = [byte[]]::new(21) }
        $info = ConvertTo-EobAdUserInfo -AdUser $user
        $info.LogonHoursRestricted | Should -BeTrue
        $info.Mail | Should -Be ''
        $info.MemberOf.Count | Should -Be 0
        (ConvertTo-EobAdUserInfo -AdUser ([pscustomobject]@{ logonHours = [byte[]](@(255) * 21) })).LogonHoursRestricted | Should -BeFalse
    }

    It 'übersetzt Berechtigungsfehler verständlich' {
        $record = [System.Management.Automation.ErrorRecord]::new([Exception]::new('Access is denied'), 'x', 'PermissionDenied', $null)
        ConvertTo-EobAdErrorMessage -ErrorRecord $record | Should -Match 'Zugriff verweigert'
    }

    It 'erstellt einen Zustandsbericht mit Gruppen, Führungskraft und primärer Gruppe' {
        Mock -ModuleName $script:ModuleName Get-ADUser {
            if ($Identity -like 'CN=Chefin*' -or $LDAPFilter -like '*chefin*') {
                return [pscustomobject]@{ SamAccountName = 'chefin'; DisplayName = 'Chefin'; DistinguishedName = 'CN=Chefin,OU=M,DC=example,DC=local'; mail = 'chefin@example.com' }
            }
            New-MockAdUser -Manager 'CN=Chefin,OU=M,DC=example,DC=local'
        }
        Mock -ModuleName $script:ModuleName Get-ADGroup {
            if ([string]$Identity -eq 'S-1-5-21-1-2-3-513') { return [pscustomobject]@{ Name = 'Domain Users'; SamAccountName = 'Domain Users'; DistinguishedName = 'CN=Domain Users,CN=Users,DC=example,DC=local' } }
            [pscustomobject]@{ Name = 'GRP-Vertrieb'; SamAccountName = 'GRP-Vertrieb'; SID = 'S-1-5-21-1-2-3-3001'; adminCount = 0; GroupCategory = 'Security' }
        }
        $snapshot = Get-EobAdUserSnapshot -Identity 'mmuster'
        $snapshot.User.SamAccountName | Should -Be 'mmuster'
        @($snapshot.Groups).Name | Should -Contain 'GRP-Vertrieb'
        @($snapshot.Groups | Where-Object IsPrimary).Name | Should -Be 'Domain Users'
        $snapshot.Manager.SamAccountName | Should -Be 'chefin'
        { $snapshot | ConvertTo-Json -Depth 6 } | Should -Not -Throw
    }
}
