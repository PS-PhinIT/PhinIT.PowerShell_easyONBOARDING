#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.3.0' }

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath '../TestHelpers.ps1')
    Import-EobTestModule

    $script:OnbModule = 'easyONB.Onboarding'
    $script:AdModule = 'easyONB.ActiveDirectory'

    $script:BaseIni = @'
[ADUserDefaults]
DefaultOU=OU=Mitarbeiter,DC=example,DC=local
AccountDisabled=True
MustChangePasswordAtLogon=True
[Company]
CompanyNameFirma=Example GmbH
CompanyActiveDirectoryDomain=example.com
CompanyMailDomain=@example.com
CompanyMS365Domain=@example.onmicrosoft.com
CompanyStrasse=Beispielstraße 1
CompanyPLZ=12345
CompanyOrt=Musterstadt
CompanyCountry=DE
[MailEndungen]
Domain1=@example.com
Domain2=@example.net
[UserCreationDefaults]
InitialGroupMembership=GRP-Alle
[LicensesGroups]
KEINE=
MS365_E3=GRP-Lizenz-E3
[TLGroups]
IT=GRP-TL-IT
[ADGroups]
Vertrieb=GRP-Vertrieb
Admins=Domain Admins
[ActivateUserMS365ADSync]
ADSync=1
ADSyncADGroup=GRP-M365-Sync
[Report]
CreateWelcomeDocument=0
[Bulk]
ConfirmationThreshold=2
[RoleTemplate.Vertrieb]
DisplayName=Vertrieb
Groups=GRP-Vertrieb;GRP-CRM
License=MS365_E3
Title=Vertriebsmitarbeiter
'@

    function script:New-TestConfig {
        param([string]$Extra = '')
        $path = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.ini')
        Set-Content -LiteralPath $path -Value ($script:BaseIni + "`n" + $Extra) -Encoding utf8
        $config = Import-EobConfiguration -Path $path -NoIncludes
        $config.Sections['Report']['ReportPath'] = Join-Path $TestDrive 'reports'
        if (-not $config.Sections['Report'].Contains('TemplatePathHTML')) {
            $template = Join-Path $TestDrive 'handout.html'
            Set-Content -LiteralPath $template -Value '<html lang="de"><body>{{Vorname}} {{Nachname}}: {{LoginName}}</body></html>' -Encoding utf8
            $config.Sections['Report']['TemplatePathHTML'] = $template
        }
        return $config
    }

    function script:New-TestRequest {
        param([hashtable]$Data = @{}, [pscustomobject]$Config = $script:Config)
        $defaults = @{ GivenName = 'Max'; Surname = 'Mustermann' }
        foreach ($key in $Data.Keys) { $defaults[$key] = $Data[$key] }
        return ConvertTo-EobOnboardingRequest -InputObject $defaults -Config $Config
    }

    function script:Set-DirectoryMock {
        Mock -ModuleName $script:OnbModule Get-EobAdIdentityConflict { @() }
        Mock -ModuleName $script:OnbModule Test-EobAdOrganizationalUnit { $true }
        Mock -ModuleName $script:OnbModule Test-EobAdNameInContainer { $false }
        Mock -ModuleName $script:OnbModule Get-EobAdConnectionInfo { [pscustomobject]@{ Connected = $true; Domain = [pscustomobject]@{ NetBiosName = 'EXAMPLE' } } }
        Mock -ModuleName $script:OnbModule Resolve-EobAdUserReference {
            [pscustomobject]@{ SamAccountName = 'chefin'; DisplayName = 'Chefin'; DistinguishedName = 'CN=Chefin,OU=Mitarbeiter,DC=example,DC=local' }
        }
        Mock -ModuleName $script:OnbModule Get-EobAdGroupProtection {
            $isProtected = $Identity -in @('Domain Admins', 'GRP-Geschuetzt')
            [pscustomobject]@{
                Group = $Identity; IsProtected = $isProtected; Reasons = @(if ($isProtected) { 'Privilegierte Gruppe.' })
                GroupObject = [pscustomobject]@{ Name = $Identity; DistinguishedName = "CN=$Identity,OU=Gruppen,DC=example,DC=local" }
            }
        }
    }

    $script:Config = New-TestConfig
    $null = Initialize-EobLogging -Directory (Join-Path $TestDrive 'logs')
}

Describe 'Transliteration und Namensbestandteile' {
    It 'wandelt Umlaute, Sonderbuchstaben und Akzente um' {
        ConvertTo-EobAsciiName -Text 'Jürgen Łukasz Dvořák Straße Åse Ørsted José' -Config $script:Config |
            Should -BeExactly 'Juergen Lukasz Dvorak Strasse Aase Orsted Jose'
    }

    It 'unterscheidet Groß- und Kleinschreibung bei Umlauten' {
        ConvertTo-EobAsciiName -Text 'Äpfel äpfel Öl öl Übel übel' -Config $script:Config | Should -BeExactly 'Aepfel aepfel Oel oel Uebel uebel'
    }

    It 'übernimmt konfigurierte und Legacy-Ersetzungen' {
        $config = New-TestConfig -Extra "[NameNormalization]`nTransliteration=å=a`nReplaceSpecialChars=ß=sz"
        ConvertTo-EobAsciiName -Text 'Åse Weiß' -Config $config | Should -BeExactly 'Ase Weisz'
    }

    It 'bereinigt Namensbestandteile für Kontonamen: <Text> -> <Expected>' -ForEach @(
        @{ Text = "O'Brien"; Expected = 'OBrien' }, @{ Text = 'van der Berg'; Expected = 'vanderBerg' }
        @{ Text = 'Anna-Lena'; Expected = 'Anna-Lena' }, @{ Text = '--Müller--Lüdenscheidt--'; Expected = 'Mueller-Luedenscheidt' }
    ) {
        ConvertTo-EobIdentifierPart -Text $Text -Config $script:Config | Should -BeExactly $Expected
    }

    It 'entfernt Bindestriche, wenn KeepHyphen=0' {
        $config = New-TestConfig -Extra "[NameNormalization]`nKeepHyphen=0"
        ConvertTo-EobIdentifierPart -Text 'Anna-Lena' -Config $config | Should -BeExactly 'AnnaLena'
    }
}

Describe 'Namensvorlagen' {
    It 'unterstützt das Legacy-Format <Template>' -ForEach @(
        @{ Template = 'FIRSTNAME.LASTNAME'; Expected = 'max.mustermann' }, @{ Template = 'F.LASTNAME'; Expected = 'm.mustermann' }
        @{ Template = 'FIRSTINITIAL.LASTNAME'; Expected = 'm.mustermann' }, @{ Template = 'FIRSTNAMELASTNAME'; Expected = 'maxmustermann' }
        @{ Template = 'FLASTNAME'; Expected = 'mmustermann' }, @{ Template = 'LASTNAME.FIRSTNAME'; Expected = 'mustermann.max' }
        @{ Template = 'FIRSTNAME.LASTINITIAL'; Expected = 'max.m' }, @{ Template = 'FIRSTNAME_LASTNAME'; Expected = 'max_mustermann' }
        @{ Template = 'LASTNAME_FIRSTNAME'; Expected = 'mustermann_max' }, @{ Template = 'FIRSTINITIAL_LASTNAME'; Expected = 'm_mustermann' }
        @{ Template = 'FIRSTNAME_LASTINITIAL'; Expected = 'max_m' }, @{ Template = 'firstname.lastname'; Expected = 'max.mustermann' }
    ) {
        Format-EobIdentityTemplate -Template $Template -GivenName 'Max' -Surname 'Mustermann' -Config $script:Config | Should -BeExactly $Expected
    }

    It 'unterstützt Platzhalter mit Längenbegrenzung, alle Vornamen und die Personalnummer' {
        Format-EobIdentityTemplate -Template '{first:3}{last:4}' -GivenName 'Maximilian' -Surname 'Mustermann' -Config $script:Config | Should -BeExactly 'maxmust'
        Format-EobIdentityTemplate -Template '{firstfull}.{last}' -GivenName 'Anna Maria' -Surname 'Müller' -Config $script:Config | Should -BeExactly 'annamaria.mueller'
        Format-EobIdentityTemplate -Template '{first}.{last}' -GivenName 'Anna Maria' -Surname 'Müller' -Config $script:Config | Should -BeExactly 'anna.mueller'
        Format-EobIdentityTemplate -Template 'u{employeeid}' -GivenName 'A' -Surname 'B' -EmployeeId '4711' -Config $script:Config | Should -BeExactly 'u4711'
    }

    It 'liest Anzeigenamen-Vorlagen im Format "Bezeichnung|Vorlage"' {
        $config = New-TestConfig -Extra "[DisplayNameUPNTemplates]`nDefaultDisplayNameFormat={first} {last}`nDisplayNameTemplate1=Nachname, Vorname|{last}, {first}`nDisplayNameTemplate2={last} {first}"
        $templates = @(Get-EobDisplayNameTemplate -Config $config)
        $templates.Count | Should -Be 3
        $templates[1].Template | Should -Be '{last}, {first}'
        $templates[1].Label | Should -Match 'Nachname, Vorname'
        Resolve-EobDisplayNameTemplate -Value 'DisplayNameTemplate1' -Config $config | Should -Be '{last}, {first}'
        Format-EobDisplayName -Template '{last}, {first}' -GivenName 'Max' -Surname 'Mustermann' | Should -Be 'Mustermann, Max'
    }
}

Describe 'Identitätsvorschlag und Kollisionen' {
    BeforeAll {
        $script:Company = Get-EobCompany -Config $script:Config | Select-Object -First 1
    }

    It 'erzeugt SamAccountName, UPN, E-Mail und Anzeigenamen' {
        $proposal = New-EobIdentityProposal -Request (New-TestRequest -Data @{ GivenName = 'Jürgen'; Surname = 'Müller' }) -Config $script:Config -Company $script:Company
        $proposal.SamAccountName | Should -BeExactly 'jmueller'
        $proposal.UserPrincipalName | Should -BeExactly 'juergen.mueller@example.com'
        $proposal.Mail | Should -BeExactly 'juergen.mueller@example.com'
        $proposal.DisplayName | Should -BeExactly 'Jürgen Müller'
    }

    It 'nummeriert deterministisch und kürzt auf 20 Zeichen' {
        $request = New-TestRequest -Data @{ GivenName = 'Max'; Surname = 'Mustermannsbergerhausen' }
        $proposal = New-EobIdentityProposal -Request $request -Config $script:Config -Company $script:Company -Attempt 1
        $proposal.SamAccountName | Should -BeExactly 'mmustermannsbergerh2'
        $proposal.SamAccountName.Length | Should -Be 20
        $proposal.UserPrincipalName | Should -BeExactly 'max.mustermannsbergerhausen2@example.com'
    }

    It 'nutzt die nächste freie Nummer bei Konflikten in AD' {
        Mock -ModuleName $script:OnbModule Get-EobAdIdentityConflict {
            if ($SamAccountName -eq 'mmustermann') { [pscustomobject]@{ Attribute = 'SamAccountName'; Value = 'mmustermann'; ConflictingObject = 'CN=Alt' } }
        }
        $result = Resolve-EobIdentity -Request (New-TestRequest) -Config $script:Config -Company $script:Company
        $result.IsAvailable | Should -BeTrue
        $result.Proposal.SamAccountName | Should -BeExactly 'mmustermann2'
        $result.Findings.Code | Should -Contain 'ONB_NAME_NUMBERED'
    }

    It 'meldet Konflikte bei Strategie Fail oder manueller Vorgabe als Fehler' {
        Mock -ModuleName $script:OnbModule Get-EobAdIdentityConflict { [pscustomobject]@{ Attribute = 'SamAccountName'; Value = 'x'; ConflictingObject = 'CN=Alt' } }
        $failConfig = New-TestConfig -Extra "[Identity]`nCollisionStrategy=Fail"
        (Resolve-EobIdentity -Request (New-TestRequest -Config $failConfig) -Config $failConfig -Company $script:Company).Findings.Code | Should -Contain 'ONB_NAME_CONFLICT'
        (Resolve-EobIdentity -Request (New-TestRequest -Data @{ SamAccountName = 'wunsch' }) -Config $script:Config -Company $script:Company).IsAvailable | Should -BeFalse
    }

    It 'berücksichtigt Reservierungen im selben Stapel ohne AD-Abfrage' {
        Mock -ModuleName $script:OnbModule Get-EobAdIdentityConflict { throw 'darf nicht aufgerufen werden' }
        $reserved = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $null = $reserved.Add('mmustermann')
        $result = Resolve-EobIdentity -Request (New-TestRequest) -Config $script:Config -Company $script:Company -ReservedIdentities $reserved -SkipDirectoryCheck
        $result.Proposal.SamAccountName | Should -BeExactly 'mmustermann2'
        Should -Invoke -ModuleName $script:OnbModule Get-EobAdIdentityConflict -Times 0
    }
}

Describe 'Onboarding-Anfrage' {
    It 'übernimmt Legacy-CSV-Felder' {
        $row = @{
            FirstName = 'Natalie'; LastName = 'Bärer'; Position = 'Beraterin'; DepartmentField = 'Service'; OfficeRoom = '1.OG'
            PhoneNumber = '030 1234-5'; EmailAddress = 'natalie.baerer@example.net'; Ablaufdatum = '2099-06-30'; External = 'False'
            TL = 'True'; AL = '1'; AccountDisabled = 'False'; ADGroup = 'Vertrieb'
        }
        $request = ConvertTo-EobOnboardingRequest -InputObject $row -Config $script:Config
        $request.GivenName | Should -Be 'Natalie'
        $request.Surname | Should -Be 'Bärer'
        $request.Title | Should -Be 'Beraterin'
        $request.Department | Should -Be 'Service'
        $request.MailLocalPart | Should -Be 'natalie.baerer'
        $request.MailDomain | Should -Be 'example.net'
        $request.ExpirationDate.Year | Should -Be 2099
        $request.IsTeamLead | Should -BeTrue
        $request.IsDepartmentHead | Should -BeTrue
        $request.Enabled | Should -BeTrue
        $request.Groups | Should -Be @('Vertrieb')
    }

    It 'setzt Standardwerte aus der Konfiguration' {
        $request = New-TestRequest
        $request.Enabled | Should -BeFalse
        $request.ChangePasswordAtLogon | Should -BeTrue
        $request.PasswordMode | Should -Be 'Generate'
        $request.CompanyId | Should -Be 'Company'
    }

    It 'meldet <Name> am betroffenen Feld' -ForEach @(
        @{ Name = 'fehlenden Vornamen'; Data = @{ GivenName = '' }; Field = 'GivenName' }
        @{ Name = 'ungültige Namen'; Data = @{ Surname = 'Muster<script>' }; Field = 'Surname' }
        @{ Name = 'ungültige Telefonnummern'; Data = @{ OfficePhone = 'abc' }; Field = 'OfficePhone' }
        @{ Name = 'nicht freigegebene Mail-Domänen'; Data = @{ MailDomain = 'fremd.example.org' }; Field = 'MailDomain' }
        @{ Name = 'Ablaufdaten in der Vergangenheit'; Data = @{ ExpirationDate = '01.01.2000' }; Field = 'ExpirationDate' }
        @{ Name = 'ungültige Datumswerte'; Data = @{ StartDate = '31.02.2030' }; Field = 'StartDate' }
        @{ Name = 'zu lange Personalnummern'; Data = @{ EmployeeId = ('1' * 17) }; Field = 'EmployeeId' }
        @{ Name = 'Steuerzeichen'; Data = @{ Department = "IT`u{0007}" }; Field = 'Department' }
        @{ Name = 'unbekannte Lizenzen'; Data = @{ LicenseKey = 'E99' }; Field = 'LicenseKey' }
        @{ Name = 'Teamleitung ohne Gruppe'; Data = @{ IsTeamLead = $true }; Field = 'TeamLeadGroupKey' }
        @{ Name = 'privilegierte Gruppen'; Data = @{ Groups = 'Admins' }; Field = 'Groups' }
        @{ Name = 'fehlende manuelle Kennwörter'; Data = @{ PasswordMode = 'Manual' }; Field = 'ManualPassword' }
        @{ Name = 'unbekannte Rollen'; Data = @{ RoleTemplate = 'Gibtsnicht' }; Field = 'RoleTemplate' }
    ) {
        $request = New-TestRequest -Data $Data
        $findings = @(Test-EobOnboardingRequest -Request $request -Config $script:Config | Where-Object Severity -EQ 'Error')
        $findings.Field | Should -Contain $Field
    }

    It 'akzeptiert eine vollständige, gültige Anfrage' {
        $request = New-TestRequest -Data @{ OfficePhone = '+49 30 123-45'; MailDomain = 'example.net'; ExpirationDate = '31.12.2099'; LicenseKey = 'MS365_E3'; IsTeamLead = $true; TeamLeadGroupKey = 'IT' }
        @(Test-EobOnboardingRequest -Request $request -Config $script:Config | Where-Object Severity -EQ 'Error').Count | Should -Be 0
    }
}

Describe 'Onboarding-Plan' {
    BeforeEach { Set-DirectoryMock }

    It 'erstellt einen ausführbaren Plan mit allen Schritten und Gruppen' {
        $request = New-TestRequest -Data @{ Groups = 'Vertrieb'; LicenseKey = 'MS365_E3'; Manager = 'chefin'; IsTeamLead = $true; TeamLeadGroupKey = 'IT' }
        $plan = New-EobOnboardingPlan -Request $request -Config $script:Config
        Test-EobPlanExecutable -Plan $plan | Should -BeTrue
        $plan.Steps[0].Action | Should -Be 'CreateUser'
        $plan.Steps[0].Critical | Should -BeTrue
        $plan.Steps.Action | Should -Contain 'SetManager'
        $groups = @($plan.Steps | Where-Object Action -EQ 'AddGroup' | ForEach-Object { $_.Parameters.Group })
        $groups | Should -Contain 'GRP-Alle'
        $groups | Should -Contain 'GRP-Vertrieb'
        $groups | Should -Contain 'GRP-Lizenz-E3'
        $groups | Should -Contain 'GRP-TL-IT'
        $groups | Should -Contain 'GRP-M365-Sync'
        $plan.Subject.SamAccountName | Should -Be 'mmustermann'
        $plan.Summary['UPN'] | Should -Be 'max.mustermann@example.com'
    }

    It 'speichert das Kennwort nur als SecureString und nie in den Schrittparametern' {
        $plan = New-EobOnboardingPlan -Request (New-TestRequest) -Config $script:Config
        $plan.Secrets['InitialPassword'] | Should -BeOfType [System.Security.SecureString]
        $plan.Steps[0].Parameters['AccountPassword'] | Should -Be '@Secret:InitialPassword'
        $json = $plan.Steps | ConvertTo-Json -Depth 6
        $plain = ConvertTo-EobPlainText -SecureString $plan.Secrets['InitialPassword']
        $json.Contains($plain) | Should -BeFalse
        Clear-EobPlanSecret -Plan $plan -Confirm:$false
    }

    It 'setzt E-Mail, Proxyadressen und Firmendaten' {
        $plan = New-EobOnboardingPlan -Request (New-TestRequest) -Config $script:Config
        $parameters = $plan.Steps[0].Parameters
        $parameters.OtherAttributes['mail'] | Should -Be 'max.mustermann@example.com'
        $parameters.OtherAttributes['proxyAddresses'] | Should -Be @('SMTP:max.mustermann@example.com', 'smtp:max.mustermann@example.onmicrosoft.com')
        $parameters.Attributes['Company'] | Should -Be 'Example GmbH'
        $parameters.Attributes['Country'] | Should -Be 'DE'
        $parameters.Enabled | Should -BeFalse
        $parameters.Path | Should -Be 'OU=Mitarbeiter,DC=example,DC=local'
    }

    It 'plant das Handout trotz Opt-out für interne und externe Konten (Extern=<External>)' -ForEach @(
        @{ External = $false }, @{ External = $true }
    ) {
        $request = New-TestRequest -Data @{ CreateWelcomeDocument = $false; IsExternal = $External }
        $request.CreateWelcomeDocument | Should -BeTrue
        $request.CreateWelcomeDocument = $false
        $plan = New-EobOnboardingPlan -Request $request -Config $script:Config
        @($plan.Steps | Where-Object Action -EQ 'WelcomeDocument').Count | Should -Be 1
    }

    It 'sperrt Onboarding bei fehlender Handout-Vorlage vor dem Anlegen eines Kontos' {
        $config = New-TestConfig
        $config.Sections['Report']['TemplatePathHTML'] = Join-Path $TestDrive 'missing-handout.html'
        $plan = New-EobOnboardingPlan -Request (New-TestRequest -Config $config) -Config $config
        $plan.Findings.Code | Should -Contain 'ONB_HANDOUT_TEMPLATE_MISSING'
        Test-EobPlanExecutable -Plan $plan | Should -BeFalse
    }

    It 'übernimmt die Bemerkung in den redigierten Vorgangsbericht' {
        $plan = New-EobOnboardingPlan -Request (New-TestRequest -Data @{ Notes = 'Laptop bei Übergabe bereitstellen' }) -Config $script:Config
        (New-EobPlanReport -Plan $plan).Summary['Bemerkung'] | Should -Be 'Laptop bei Übergabe bereitstellen'
    }

    It 'übernimmt Rollenvorlagen (Gruppen, Lizenz, Position)' {
        $plan = New-EobOnboardingPlan -Request (New-TestRequest -Data @{ RoleTemplate = 'Vertrieb'; LicenseKey = '' }) -Config $script:Config
        $groups = @($plan.Steps | Where-Object Action -EQ 'AddGroup' | ForEach-Object { $_.Parameters.Group })
        $groups | Should -Contain 'GRP-CRM'
        $groups | Should -Contain 'GRP-Lizenz-E3'
        $plan.Steps[0].Parameters.Attributes['Title'] | Should -Be 'Vertriebsmitarbeiter'
    }

    It 'blockiert privilegierte Gruppen aus jeder Quelle' {
        $config = New-TestConfig -Extra "[RoleTemplate.Kritisch]`nDisplayName=K`nGroups=GRP-Geschuetzt"
        $plan = New-EobOnboardingPlan -Request (New-TestRequest -Data @{ RoleTemplate = 'Kritisch' } -Config $config) -Config $config
        Test-EobPlanExecutable -Plan $plan | Should -BeFalse
        $plan.Findings.Code | Should -Contain 'ONB_GROUP_PROTECTED'
        @($plan.Steps | Where-Object { $_.Action -eq 'AddGroup' -and $_.Parameters.Group -eq 'GRP-Geschuetzt' }).Count | Should -Be 0
    }

    It 'überschreibt nie ein bestehendes Konto' {
        $config = New-TestConfig -Extra "[Identity]`nCollisionStrategy=Fail"
        Mock -ModuleName $script:OnbModule Get-EobAdIdentityConflict { [pscustomobject]@{ Attribute = 'SamAccountName'; Value = 'mmustermann'; ConflictingObject = 'CN=Bestehend' } }
        $plan = New-EobOnboardingPlan -Request (New-TestRequest -Config $config) -Config $config
        Test-EobPlanExecutable -Plan $plan | Should -BeFalse
        $plan.Steps.Handler | Should -Not -Contain 'Set-EobAdUserAttribute'
        $plan.Steps.Handler | Should -Not -Contain 'Reset-EobAdUserPassword'
    }

    It 'meldet fehlende OU und nicht auflösbare Führungskraft' {
        Mock -ModuleName $script:OnbModule Test-EobAdOrganizationalUnit { $false }
        Mock -ModuleName $script:OnbModule Resolve-EobAdUserReference { throw "Die Angabe 'x' ist nicht eindeutig (2 Treffer)." }
        $plan = New-EobOnboardingPlan -Request (New-TestRequest -Data @{ Manager = 'x' }) -Config $script:Config
        $plan.Findings.Code | Should -Contain 'ONB_OU_NOT_FOUND'
        $plan.Findings.Code | Should -Contain 'ONB_MANAGER_UNRESOLVED'
    }

    It 'passt den Objektnamen bei belegtem CN an' {
        Mock -ModuleName $script:OnbModule Test-EobAdNameInContainer { $true }
        $plan = New-EobOnboardingPlan -Request (New-TestRequest) -Config $script:Config
        $plan.Steps[0].Parameters.Name | Should -Be 'Max Mustermann (mmustermann)'
    }

    It 'prüft manuelle Kennwörter ohne sie auszugeben' {
        $secret = 'mustermann'
        $request = New-TestRequest -Data @{ PasswordMode = 'Manual'; ManualPassword = (New-EobTestSecureString -Value $secret) }
        $plan = New-EobOnboardingPlan -Request $request -Config $script:Config
        $plan.Findings.Code | Should -Contain 'ONB_PASSWORD_POLICY'
        (($plan.Findings.Message -join ' ').Contains($secret)) | Should -BeFalse
    }

    It 'erzwingt ohne AD-Prüfung die Simulation' {
        $plan = New-EobOnboardingPlan -Request (New-TestRequest) -Config $script:Config -SkipDirectoryCheck
        $plan.Simulation | Should -BeTrue
        $plan.Findings.Code | Should -Contain 'ONB_OFFLINE'
        Should -Invoke -ModuleName $script:OnbModule Get-EobAdIdentityConflict -Times 0
    }
}

Describe 'Onboarding-Ausführung' {
    BeforeEach {
        Set-DirectoryMock
        Mock -ModuleName $script:AdModule Get-ADDomain { [pscustomobject]@{ DNSRoot = 'example.local'; NetBIOSName = 'EXAMPLE'; DistinguishedName = 'DC=example,DC=local'; DomainSID = 'S-1-5-21-1-2-3' } }
        $null = Initialize-EobAdConnection -Config $script:Config -Server 'dc01.example.local'
    }

    It 'simuliert mit -WhatIf ohne ein AD-Cmdlet aufzurufen' {
        $plan = New-EobOnboardingPlan -Request (New-TestRequest -Data @{ Groups = 'Vertrieb' }) -Config $script:Config
        $result = Invoke-EobOnboardingPlan -Plan $plan -WhatIf
        $result.Status | Should -Be 'Simulated'
        @($result.Steps | Where-Object Status -NE 'Simulated').Count | Should -Be 0
        Get-EobPlanCredential -Plan $result | Should -BeNullOrEmpty
        $result.Runtime.ContainsKey('WelcomeDocumentPath') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $TestDrive 'reports/Welcome') | Should -BeFalse
    }

    It 'führt den Plan live aus und protokolliert das Kennwort nicht' {
        Mock -ModuleName $script:AdModule New-ADUser { [pscustomobject]@{ DistinguishedName = 'CN=Max Mustermann,OU=Mitarbeiter,DC=example,DC=local'; ObjectGUID = 'aaaaaaaa-0000-0000-0000-000000000001' } }
        Mock -ModuleName $script:AdModule Add-ADGroupMember { }
        Mock -ModuleName $script:AdModule Get-ADGroup {
            if ($LDAPFilter) { return @() }
            [pscustomobject]@{ Name = [string]$Identity; SamAccountName = [string]$Identity; DistinguishedName = "CN=$Identity,DC=example,DC=local"; SID = 'S-1-5-21-1-2-3-3001'; adminCount = 0 }
        }
        $plan = New-EobOnboardingPlan -Request (New-TestRequest -Data @{ Groups = 'Vertrieb' }) -Config $script:Config
        $plain = ConvertTo-EobPlainText -SecureString $plan.Secrets['InitialPassword']
        $result = Invoke-EobOnboardingPlan -Plan $plan -Confirm:$false
        $result.Status | Should -Be 'Succeeded'
        Test-Path -LiteralPath $result.Runtime['WelcomeDocumentPath'] -PathType Leaf | Should -BeTrue
        Should -Invoke -ModuleName $script:AdModule New-ADUser -Times 1 -ParameterFilter { $SamAccountName -eq 'mmustermann' -and $AccountPassword -is [securestring] }
        Should -Invoke -ModuleName $script:AdModule Add-ADGroupMember -Times 3
        (Get-EobPlanCredential -Plan $result) | Should -BeOfType [System.Security.SecureString]
        $logText = (Get-ChildItem (Join-Path $TestDrive 'logs') -Recurse -File | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join ''
        $logText.Contains($plain) | Should -BeFalse
        @(Get-EobAuditEntry -OperationId $plan.OperationId | Where-Object Action -EQ 'CreateUser').Count | Should -Be 1
        Clear-EobPlanSecret -Plan $result -Confirm:$false
        $result.Secrets.Count | Should -Be 0
    }

    It 'überspringt alle Folgeschritte, wenn das Anlegen fehlschlägt' {
        Mock -ModuleName $script:AdModule New-ADUser { throw 'Zugriff verweigert' }
        Mock -ModuleName $script:AdModule Add-ADGroupMember { }
        $plan = New-EobOnboardingPlan -Request (New-TestRequest -Data @{ Groups = 'Vertrieb' }) -Config $script:Config
        $result = Invoke-EobOnboardingPlan -Plan $plan -Confirm:$false
        $result.Status | Should -Be 'Failed'
        @($result.Steps | Select-Object -Skip 1 | Where-Object Status -NE 'Skipped').Count | Should -Be 0
        Should -Invoke -ModuleName $script:AdModule Add-ADGroupMember -Times 0
    }
}

Describe 'Benutzer aktualisieren und Kennwort zurücksetzen' {
    BeforeEach {
        Mock -ModuleName $script:OnbModule Get-EobAdUser {
            [pscustomobject]@{ SamAccountName = 'mmuster'; UserPrincipalName = 'mmuster@example.com'; DisplayName = 'Max Muster'; GivenName = 'Max'; Surname = 'Muster'
                Title = 'Alt'; Department = 'IT'; Company = ''; Office = ''; OfficePhone = ''; MobilePhone = ''; Description = 'Beschreibung'; EmployeeId = ''; EmployeeNumber = ''
                Manager = ''; MemberOf = @('CN=GRP-Vertrieb,OU=Gruppen,DC=example,DC=local'); DistinguishedName = 'CN=Max Muster,OU=Mitarbeiter,DC=example,DC=local'
                ObjectGuid = '11111111-2222-3333-4444-555555555555'; Sid = 'S-1-5-21-1-2-3-1500'; AdminCount = 0; PrimaryGroupId = 513; ObjectClass = 'user'
            }
        }
        Mock -ModuleName $script:OnbModule Get-EobAdPrivilegedMembership { @() }
        Mock -ModuleName $script:OnbModule Get-EobCurrentIdentity { [pscustomobject]@{ Name = 'EXAMPLE\admin'; Sid = 'S-1-5-21-1-2-3-4242' } }
        Set-DirectoryMock
    }

    It 'schreibt nur geänderte Felder und setzt dabei kein Kennwort' {
        $plan = New-EobUserUpdatePlan -Identity 'mmuster' -Changes @{ Title = 'Neu'; Department = 'IT'; Description = '' } -Config $script:Config
        @($plan.Steps).Count | Should -Be 1
        $plan.Steps[0].Parameters.Replace['title'] | Should -Be 'Neu'
        $plan.Steps[0].Parameters.Replace.ContainsKey('department') | Should -BeFalse
        $plan.Steps[0].Parameters.Clear | Should -Contain 'description'
        $plan.Steps[0].Details | Should -Contain "Position: 'Alt' → 'Neu'"
        $plan.Steps.Handler | Should -Not -Contain 'Reset-EobAdUserPassword'
    }

    It 'blockiert geschützte Konten und privilegierte Gruppen' {
        Mock -ModuleName $script:OnbModule Get-EobAdPrivilegedMembership { @('Domain Admins') }
        $plan = New-EobUserUpdatePlan -Identity 'mmuster' -Changes @{ Title = 'Neu' } -AddGroups 'Admins' -Config $script:Config
        Test-EobPlanExecutable -Plan $plan | Should -BeFalse
        $plan.Findings.Code | Should -Contain 'ACC_PRIVILEGED'
        $plan.Findings.Code | Should -Contain 'UPD_GROUP_PROTECTED'
    }

    It 'aktiviert ein deaktiviertes Konto nur auf ausdrücklichen Wunsch' {
        Mock -ModuleName $script:OnbModule Get-EobAdUser {
            [pscustomobject]@{ SamAccountName = 'mmuster'; UserPrincipalName = 'mmuster@example.com'; DisplayName = 'Max Muster'; Enabled = $false
                Title = 'Alt'; Department = 'IT'; Company = ''; Office = ''; OfficePhone = ''; MobilePhone = ''; Description = ''; EmployeeId = ''; EmployeeNumber = ''
                Manager = ''; MemberOf = @(); DistinguishedName = $script:UserDn; ObjectGuid = '11111111-2222-3333-4444-555555555555'
                Sid = 'S-1-5-21-1-2-3-1500'; AdminCount = 0; PrimaryGroupId = 513; ObjectClass = 'user'
            }
        }
        $script:UserDn = 'CN=Max Muster,OU=Mitarbeiter,DC=example,DC=local'
        @((New-EobUserUpdatePlan -Identity 'mmuster' -Config $script:Config).Steps).Count | Should -Be 0
        $plan = New-EobUserUpdatePlan -Identity 'mmuster' -EnableAccount -Config $script:Config
        $plan.Steps[0].Action | Should -Be 'EnableAccount'
        $plan.Steps[0].Handler | Should -Be 'Enable-EobAdUserAccount'
        $plan.Findings.Code | Should -Not -Contain 'UPD_ENABLE_OFFBOARDED'

        $script:UserDn = 'CN=Max Muster,OU=Ausgeschieden,DC=example,DC=local'
        $config = New-TestConfig -Extra "[Offboarding]`nDisabledUsersOU=OU=Ausgeschieden,DC=example,DC=local"
        $plan = New-EobUserUpdatePlan -Identity 'mmuster' -EnableAccount -Config $config
        $plan.Findings.Code | Should -Contain 'UPD_ENABLE_OFFBOARDED'
        $plan.Steps[0].Action | Should -Be 'EnableAccount'
    }

    It 'meldet bereits aktive Konten statt sie erneut zu aktivieren' {
        Mock -ModuleName $script:OnbModule Get-EobAdUser {
            [pscustomobject]@{ SamAccountName = 'mmuster'; UserPrincipalName = 'mmuster@example.com'; DisplayName = 'Max Muster'; Enabled = $true
                Manager = ''; MemberOf = @(); DistinguishedName = 'CN=Max Muster,OU=Mitarbeiter,DC=example,DC=local'; ObjectGuid = '11111111-2222-3333-4444-555555555555'
                Sid = 'S-1-5-21-1-2-3-1500'; AdminCount = 0; PrimaryGroupId = 513; ObjectClass = 'user'
            }
        }
        $plan = New-EobUserUpdatePlan -Identity 'mmuster' -EnableAccount -Config $script:Config
        $plan.Findings.Code | Should -Contain 'UPD_ALREADY_ENABLED'
        @($plan.Steps).Count | Should -Be 0
    }

    It 'meldet bestehende Mitgliedschaften statt sie erneut zu setzen' {
        $plan = New-EobUserUpdatePlan -Identity 'mmuster' -AddGroups 'Vertrieb' -Config $script:Config
        $plan.Findings.Code | Should -Contain 'UPD_ALREADY_MEMBER'
        @($plan.Steps).Count | Should -Be 0
    }

    It 'plant den Kennwort-Reset als eigenen, bestätigungspflichtigen Vorgang' {
        $plan = New-EobPasswordResetPlan -Identity 'mmuster' -Config $script:Config
        $plan.Steps[0].Handler | Should -Be 'Reset-EobAdUserPassword'
        $plan.Steps[0].Parameters.NewPassword | Should -Be '@Secret:NewPassword'
        $plan.Steps[0].Risk | Should -Be 'High'
        $plan.Secrets['NewPassword'] | Should -BeOfType [System.Security.SecureString]
        Clear-EobPlanSecret -Plan $plan -Confirm:$false
    }
}

Describe 'Home-Verzeichnis' {
    It 'legt nur unterhalb erlaubter Stammpfade an' {
        { New-EobHomeDirectory -Path (Join-Path $TestDrive 'anderswo/x') -SamAccountName 'x' -AllowedRoots (Join-Path $TestDrive 'home') -Confirm:$false } | Should -Throw '*erlaubten Stammpfad*'
    }

    It 'verändert bestehende Verzeichnisse nicht und simuliert mit -WhatIf' {
        $root = Join-Path $TestDrive 'home'
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'vorhanden') -Force
        (New-EobHomeDirectory -Path (Join-Path $root 'vorhanden') -SamAccountName 'x' -AllowedRoots $root -Confirm:$false).Status | Should -Be 'Skipped'
        $null = New-EobHomeDirectory -Path (Join-Path $root 'neu') -SamAccountName 'x' -AllowedRoots $root -WhatIf
        Test-Path (Join-Path $root 'neu') | Should -BeFalse
    }
}

Describe 'CSV-Massenverarbeitung' {
    BeforeEach { Set-DirectoryMock }

    It 'liest Legacy-CSV (Komma) und neue CSV (Semikolon, Windows-1252)' {
        $legacy = Join-Path $TestDrive 'legacy.csv'
        Set-Content -LiteralPath $legacy -Encoding utf8 -Value @(
            'FirstName,LastName,Description,OfficeRoom,PhoneNumber,MobileNumber,Position,DepartmentField,EmailAddress,Ablaufdatum,External,TL,AL,AccountDisabled,ADGroup'
            'Erika,Beispiel,Test,1.OG,030 123,,Beraterin,Service,erika.beispiel,2099-06-30,False,False,False,True,Vertrieb'
        )
        $import = Import-EobOnboardingCsv -Path $legacy -Config $script:Config
        $import.Delimiter | Should -Be ','
        @($import.Findings | Where-Object Severity -EQ 'Error').Count | Should -Be 0
        $import.Rows[0].Data['FirstName'] | Should -Be 'Erika'

        $ansi = Join-Path $TestDrive 'neu.csv'
        [System.IO.File]::WriteAllBytes($ansi, [System.Text.Encoding]::GetEncoding(1252).GetBytes("Vorname;Nachname;Abteilung`r`nJürgen;Größe;Lager"))
        $import2 = Import-EobOnboardingCsv -Path $ansi -Config $script:Config
        $import2.Delimiter | Should -Be ';'
        $import2.Encoding | Should -Be 'windows-1252'
        $import2.Rows[0].Data['Nachname'] | Should -Be 'Größe'
    }

    It 'lehnt Dateien ohne Pflichtspalten oder mit zu vielen Zeilen ab' {
        $path = Join-Path $TestDrive 'ohne.csv'
        Set-Content -LiteralPath $path -Value "Name;Abteilung`nX;Y" -Encoding utf8
        (Import-EobOnboardingCsv -Path $path -Config $script:Config).Findings.Code | Should -Contain 'CSV_MISSING_COLUMN'
        $config = New-TestConfig -Extra "[Bulk]`nMaxRows=1"
        $path2 = Join-Path $TestDrive 'viele.csv'
        Set-Content -LiteralPath $path2 -Value "Vorname;Nachname`nA;B`nC;D" -Encoding utf8
        (Import-EobOnboardingCsv -Path $path2 -Config $config).Findings.Code | Should -Contain 'CSV_TOO_MANY_ROWS'
    }

    It 'erkennt Duplikate, reserviert Namen im Stapel und verlangt ab dem Schwellwert eine Tippbestätigung' {
        $path = Join-Path $TestDrive 'stapel.csv'
        Set-Content -LiteralPath $path -Encoding utf8 -Value @('Vorname;Nachname;Personalnummer', 'Max;Mustermann;100', 'Max;Mustermann;101', 'Erika;Muster;100')
        $batch = New-EobOnboardingBatch -Import (Import-EobOnboardingCsv -Path $path -Config $script:Config) -Config $script:Config
        $batch.Items.Count | Should -Be 3
        $batch.Items[0].Plan.Subject.SamAccountName | Should -Be 'mmustermann'
        $batch.Items[1].Plan.Subject.SamAccountName | Should -Be 'mmustermann2'
        $batch.Items[1].State | Should -Be 'Warning'
        foreach ($item in @($batch.Items | Where-Object State -NE 'Error')) {
            @($item.Plan.Steps | Where-Object Action -EQ 'WelcomeDocument').Count | Should -Be 1
        }
        $batch.Items[2].State | Should -Be 'Error'
        $batch.RequiresTypedConfirmation | Should -BeTrue
    }

    It 'verwirft die Kennwörter nicht ausführbarer Zeilen' {
        $path = Join-Path $TestDrive 'stapel3.csv'
        Set-Content -LiteralPath $path -Encoding utf8 -Value @('Vorname;Nachname;Personalnummer', 'Max;Mustermann;100', 'Erika;Muster;100')
        $batch = New-EobOnboardingBatch -Import (Import-EobOnboardingCsv -Path $path -Config $script:Config) -Config $script:Config
        $batch.Items[1].State | Should -Be 'Error'
        $plain = ConvertTo-EobPlainText -SecureString $batch.Items[1].Plan.Secrets['InitialPassword']
        $null = Invoke-EobOnboardingBatch -Batch $batch -WhatIf
        $batch.Items[1].Outcome | Should -Be 'NotExecuted'
        $batch.Items[1].Plan.Secrets.Count | Should -Be 0
        Protect-EobSensitiveText -Text "x $plain" | Should -Be "x $plain"
        foreach ($item in $batch.Items) { Clear-EobPlanSecret -Plan $item.Plan -Confirm:$false }
    }

    It 'simuliert den Stapel und exportiert Ergebnisse ohne Kennwörter' {
        $path = Join-Path $TestDrive 'stapel2.csv'
        Set-Content -LiteralPath $path -Encoding utf8 -Value @('Vorname;Nachname', 'Anna;Beispiel', 'Ben;Beispiel')
        $batch = New-EobOnboardingBatch -Import (Import-EobOnboardingCsv -Path $path -Config $script:Config) -Config $script:Config
        $secrets = @($batch.Items | ForEach-Object { ConvertTo-EobPlainText -SecureString $_.Plan.Secrets['InitialPassword'] })
        $null = Invoke-EobOnboardingBatch -Batch $batch -WhatIf
        @($batch.Items | Where-Object Outcome -NE 'Simulated').Count | Should -Be 0
        $csv = Export-EobBatchResult -Batch $batch -Path (Join-Path $TestDrive 'ergebnis.csv') -Format Csv -Confirm:$false
        $json = Export-EobBatchResult -Batch $batch -Path (Join-Path $TestDrive 'ergebnis.json') -Format Json -Confirm:$false
        $text = (Get-Content -LiteralPath $csv -Raw) + (Get-Content -LiteralPath $json -Raw)
        @($secrets | Where-Object { $text.Contains($_) }).Count | Should -Be 0
        (Import-Csv -LiteralPath $csv -Delimiter ';').Count | Should -Be 2
    }
}
