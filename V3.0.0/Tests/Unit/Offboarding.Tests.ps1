#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.3.0' }
<#
    Tests der Offboarding-Engine. Das AD ist vollständig gemockt (Adapter-Interna und Cmdlets);
    es werden weder Konten noch Gruppen verändert. Dateien (Snapshots, Warteschlange, Berichte)
    entstehen ausschließlich im TestDrive.
#>

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath '../TestHelpers.ps1')
    Import-EobTestModule

    $script:Off = 'easyONB.Offboarding'
    $script:Ad = 'easyONB.ActiveDirectory'
    $script:Guid = '11111111-2222-3333-4444-555555555555'
    $null = Initialize-EobLogging -Directory (Join-Path $TestDrive 'logs')

    $script:ConfigDir = Join-Path $TestDrive 'config'
    $null = New-Item -ItemType Directory -Path (Join-Path $script:ConfigDir 'templates') -Force
    Copy-Item -LiteralPath (Join-Path (Get-EobTestRepoRoot) 'Config/templates/offboarding-templates.ini') -Destination (Join-Path $script:ConfigDir 'templates')

    function script:New-TestConfig {
        param([string]$Extra = '')
        $id = [guid]::NewGuid().ToString('N')
        $root = Join-Path $TestDrive $id
        $ini = @"
[Company]
CompanyNameFirma=Example GmbH
CompanyActiveDirectoryDomain=example.com
CompanyMailDomain=@example.com
[MailEndungen]
Domain1=@example.com
[Security]
ServiceAccountPatterns=svc_*
[Offboarding]
DisabledUsersOU=OU=Ausgeschieden,DC=example,DC=local
KeepGroups=GRP-Behalten
[LicensesGroups]
KEINE=
MS365_E3=GRP-Lizenz-E3
[ActivateUserMS365ADSync]
ADSync=1
ADSyncADGroup=GRP-M365-Sync
[Paths]
DataDirectory=$(Join-Path $root 'data')
SnapshotDirectory=$(Join-Path $root 'snapshots')
[Report]
ReportPath=$(Join-Path $root 'reports')
$Extra
"@
        $path = Join-Path $script:ConfigDir "$id.ini"
        Set-Content -LiteralPath $path -Value $ini -Encoding utf8
        $config = Import-EobConfiguration -Path $path
        Add-Member -InputObject $config -NotePropertyName 'TestRoot' -NotePropertyValue $root -Force
        return $config
    }

    function script:New-TestUser {
        param(
            [string]$Sam = 'mmuster', [bool]$Enabled = $true, [string]$Sid = 'S-1-5-21-1-2-3-1500', [int]$AdminCount = 0,
            [string]$HomeDirectory = '', [string]$ProfilePath = '\\fs01.example.local\profiles$\mmuster',
            [string]$Manager = 'CN=Chefin Beispiel,OU=Mitarbeiter,DC=example,DC=local'
        )
        ConvertTo-EobAdUserInfo -AdUser ([pscustomobject]@{
                SamAccountName = $Sam; SID = $Sid; Enabled = $Enabled; DistinguishedName = 'CN=Max Muster,OU=Mitarbeiter,DC=example,DC=local'
                adminCount = $AdminCount; ObjectGUID = $script:Guid; ObjectClass = 'user'; DisplayName = 'Max Muster'; GivenName = 'Max'; Surname = 'Muster'
                UserPrincipalName = "$Sam@example.com"; mail = "$Sam@example.com"; primaryGroupID = 513; manager = $Manager; Description = 'Vertrieb Innendienst'
                HomeDirectory = $HomeDirectory; ProfilePath = $ProfilePath
            })
    }

    function script:New-TestMembership {
        $group = { param($Name, $Rid, $Category = 'Security', $Primary = $false)
            [pscustomobject]@{ Name = $Name; SamAccountName = $Name; DistinguishedName = "CN=$Name,OU=Gruppen,DC=example,DC=local"; SID = "S-1-5-21-1-2-3-$Rid"; AdminCount = 0; GroupCategory = $Category; IsPrimary = $Primary }
        }
        @(
            (& $group 'GRP-Vertrieb' 2001), (& $group 'VL-Alle' 2002 'Distribution'), (& $group 'GRP-Lizenz-E3' 2003),
            (& $group 'GRP-M365-Sync' 2004), (& $group 'GRP-Behalten' 2005), (& $group 'Domain Users' 513 'Security' $true)
        )
    }

    function script:Set-DirectoryMock {
        param([pscustomobject]$User = (New-TestUser), [string[]]$Privileged = @())
        $script:TestUser = $User
        $script:TestPrivileged = $Privileged
        Mock -ModuleName $script:Off Get-EobAdConnectionInfo {
            [pscustomobject]@{ Connected = $true; Server = 'dc01.example.local'; Domain = [pscustomobject]@{ NetBiosName = 'EXAMPLE'; DomainSid = 'S-1-5-21-1-2-3' } }
        }
        Mock -ModuleName $script:Off Resolve-EobAdUser {
            if ($Identity -like 'CN=Chefin*') { [pscustomobject]@{ SamAccountName = 'chefin'; DisplayName = 'Chefin Beispiel'; Mail = 'chefin@example.com'; DistinguishedName = $Identity } }
            else { $script:TestUser }
        }
        Mock -ModuleName $script:Off Get-EobAdPrivilegedMembership { $script:TestPrivileged }
        Mock -ModuleName $script:Off Get-EobAdDirectReport { @() }
        Mock -ModuleName $script:Off Get-EobAdUserGroupMembership { New-TestMembership }
        Mock -ModuleName $script:Off Test-EobAdOrganizationalUnit { $true }
        Mock -ModuleName $script:Off Test-EobAdRecycleBinEnabled { $true }
        Mock -ModuleName $script:Off Get-EobCurrentIdentity { [pscustomobject]@{ Name = 'EXAMPLE\admin'; Sid = 'S-1-5-21-1-2-3-4242' } }
        Mock -ModuleName $script:Off Get-EobAdUserSnapshot {
            [pscustomobject]@{ CapturedAt = (Get-Date).ToString('o'); Server = 'dc01.example.local'; User = $script:TestUser; Groups = @(New-TestMembership); Manager = $null; DirectReports = @() }
        }
        Mock -ModuleName $script:Ad Assert-EobAdConnected { }
        Mock -ModuleName $script:Ad Assert-EobAdTargetAllowed { $script:TestUser }
        Mock -ModuleName $script:Ad Test-EobAdOrganizationalUnit { $true }
        Mock -ModuleName $script:Ad Disable-ADAccount { }
        Mock -ModuleName $script:Ad Set-ADUser { }
        Mock -ModuleName $script:Ad Set-ADAccountExpiration { }
        Mock -ModuleName $script:Ad Set-ADAccountPassword { }
        Mock -ModuleName $script:Ad Remove-ADGroupMember { }
        Mock -ModuleName $script:Ad Move-ADObject { [pscustomobject]@{ DistinguishedName = 'CN=Max Muster,OU=Ausgeschieden,DC=example,DC=local' } }
        Mock -ModuleName $script:Ad Remove-ADObject { }
    }

    function script:New-TestRequest {
        param([hashtable]$Data = @{}, [pscustomobject]$Config)
        $values = @{ Identity = 'mmuster'; Template = 'Standard'; ExitDate = '2027-03-31'; Ticket = 'CHG-1001'; Reason = 'Eigenkündigung' }
        # Fixtures without Exchange explicitly opt out of conversion before testing AD-only completion.
        if ((Get-EobConfigValue -Config $Config -Section 'Exchange' -Key 'Mode') -in @('', 'None', $null)) {
            $values['ActionPhases'] = @{ ConvertToSharedMailbox = 'Off' }
        }
        foreach ($key in $Data.Keys) { $values[$key] = $Data[$key] }
        return ConvertTo-EobOffboardingRequest -InputObject $values -Config $Config
    }

    $script:BeforeExit = [datetime]'2027-03-15 09:00'
}

AfterAll {
    Remove-EobRedactionValue -All
}

Describe 'Vorlagen und Anfragen' {
    It 'liest alle mitgelieferten Vorlagen' {
        $names = @(Get-EobOffboardingTemplate -Config (New-TestConfig)).Name
        foreach ($expected in @('Standard', 'SofortigeSperrung', 'Befristet', 'Extern', 'Ruhestand', 'InternerWechsel', 'Testmodus')) {
            $names | Should -Contain $expected
        }
    }

    It 'ordnet jeder Aktion eine Phase zu (Standard: Löschung nur in FinalDeletion)' {
        $template = Get-EobOffboardingTemplate -Config (New-TestConfig) -Name 'Standard'
        $template.Actions['DeleteAccount'] | Should -Be 'FinalDeletion'
        $template.Actions['DisableAccount'] | Should -Be 'ExitDate'
        $template.Actions['SetExpiration'] | Should -Be 'Immediate'
        $template.RetentionDays | Should -Be 180
    }

    It 'meldet Pflichtfelder und ungültige Angaben' {
        $config = New-TestConfig
        $request = ConvertTo-EobOffboardingRequest -InputObject @{ Identity = ''; Template = 'Gibtsnicht'; ExitDate = '31.02.2027' } -Config $config
        $codes = @(Test-EobOffboardingRequest -Request $request -Config $config).Code
        $codes | Should -Contain 'OFF_IDENTITY_MISSING'
        $codes | Should -Contain 'OFF_TEMPLATE_NOT_FOUND'
        $codes | Should -Contain 'OFF_EXITDATE_INVALID'
        $codes | Should -Contain 'OFF_TICKET_REQUIRED'
    }

    It 'verlangt keine Ticketnummer im Testmodus' {
        $config = New-TestConfig
        $request = New-TestRequest -Config $config -Data @{ Template = 'Testmodus'; Ticket = '' }
        @(Test-EobOffboardingRequest -Request $request -Config $config).Code | Should -Not -Contain 'OFF_TICKET_REQUIRED'
    }

    It 'lässt die Löschung nur in der Phase FinalDeletion zu' {
        $config = New-TestConfig
        $request = New-TestRequest -Config $config -Data @{ ActionPhases = @{ DeleteAccount = 'Immediate'; DisableAccount = 'FinalDeletion'; Unbekannt = 'Immediate' } }
        $codes = @(Test-EobOffboardingRequest -Request $request -Config $config).Code
        $codes | Should -Contain 'OFF_DELETE_PHASE'
        $codes | Should -Contain 'OFF_PHASE_FINALDELETION'
        $codes | Should -Contain 'OFF_ACTION_UNKNOWN'
    }

    It 'berechnet die Phasentermine (Austritt = letzter Arbeitstag)' {
        $template = Get-EobOffboardingTemplate -Config (New-TestConfig) -Name 'Standard'
        $dates = Get-EobOffboardingPhaseDate -ExitDate ([datetime]'2027-03-31') -Template $template -Now $script:BeforeExit
        $dates['ExitDate'] | Should -Be ([datetime]'2027-04-01')
        $dates['Retention'] | Should -Be ([datetime]'2027-04-30')
        $dates['FinalDeletion'] | Should -Be ([datetime]'2027-09-27')
    }
}

Describe 'Schutzprüfung' {
    It 'blockiert Dienstkonten ohne Schritte' {
        Set-DirectoryMock -User (New-TestUser -Sam 'svc_backup')
        $config = New-TestConfig
        $plan = New-EobOffboardingPlan -Request (New-TestRequest -Config $config -Data @{ Identity = 'svc_backup' }) -Config $config -Now $script:BeforeExit
        @($plan.Findings | Where-Object Code -EQ 'OFF_PROTECTED').Count | Should -BeGreaterThan 0
        $plan.Steps.Count | Should -Be 0
        Test-EobPlanExecutable -Plan $plan | Should -BeFalse
    }

    It 'blockiert das eigene Konto' {
        Set-DirectoryMock -User (New-TestUser -Sid 'S-1-5-21-1-2-3-4242')
        $config = New-TestConfig
        $plan = New-EobOffboardingPlan -Request (New-TestRequest -Config $config) -Config $config -Now $script:BeforeExit
        ($plan.Findings | Where-Object Code -EQ 'OFF_PROTECTED').Message | Should -Match 'eigene'
    }

    It 'blockiert privilegierte Konten, solange die Konfiguration es nicht erlaubt' {
        Set-DirectoryMock -Privileged @('Domain Admins')
        $config = New-TestConfig
        $plan = New-EobOffboardingPlan -Request (New-TestRequest -Config $config -Data @{ AcknowledgePrivileged = $true }) -Config $config -Now $script:BeforeExit
        @($plan.Findings.Code) | Should -Contain 'OFF_PRIVILEGED'
        $plan.Steps.Count | Should -Be 0
    }

    It 'verlangt für privilegierte Konten die gesonderte Bestätigung' {
        Set-DirectoryMock -Privileged @('Domain Admins')
        $config = New-TestConfig -Extra "[Security]`nAllowPrivilegedOffboarding=1"
        $plan = New-EobOffboardingPlan -Request (New-TestRequest -Config $config) -Config $config -Now $script:BeforeExit
        @($plan.Findings.Code) | Should -Contain 'OFF_PRIVILEGED_ACK_REQUIRED'
        $plan.Steps.Count | Should -Be 0
    }

    It 'plant privilegierte Konten nach Bestätigung mit AllowPrivileged' {
        Set-DirectoryMock -Privileged @('Domain Admins')
        $config = New-TestConfig -Extra "[Security]`nAllowPrivilegedOffboarding=1"
        $plan = New-EobOffboardingPlan -Request (New-TestRequest -Config $config -Data @{ AcknowledgePrivileged = $true }) -Config $config -Now $script:BeforeExit
        @($plan.Findings.Code) | Should -Contain 'OFF_PRIVILEGED_ACKNOWLEDGED'
        $disable = $plan.Steps | Where-Object Action -EQ 'DisableAccount'
        $disable.Parameters['AllowPrivileged'] | Should -BeTrue
        $plan.Offboarding.Privileged | Should -BeTrue
    }

    It 'blockiert, wenn keine AD-Verbindung besteht' {
        Mock -ModuleName $script:Off Get-EobAdConnectionInfo { [pscustomobject]@{ Connected = $false; Server = ''; Domain = $null } }
        $config = New-TestConfig
        $plan = New-EobOffboardingPlan -Request (New-TestRequest -Config $config) -Config $config -Now $script:BeforeExit
        @($plan.Findings.Code) | Should -Contain 'OFF_AD_OFFLINE'
    }
}

Describe 'Planinhalt' {
    BeforeEach {
        Set-DirectoryMock
        $script:Config = New-TestConfig
        $script:Plan = New-EobOffboardingPlan -Request (New-TestRequest -Config $script:Config) -Config $script:Config -Now $script:BeforeExit
    }

    It 'ist ohne blockierende Befunde ausführbar' {
        Test-EobPlanExecutable -Plan $script:Plan | Should -BeTrue
        $script:Plan.Subject['ObjectGuid'] | Should -Be $script:Guid
    }

    It 'sichert den Zustand vorher (kritisch) und nachher' {
        $script:Plan.Steps[0].Action | Should -Be 'SnapshotBefore'
        $script:Plan.Steps[0].Critical | Should -BeTrue
        $script:Plan.Steps[-1].Action | Should -Be 'SnapshotAfter'
    }

    It 'adressiert alle AD-Schritte über die ObjectGUID' {
        foreach ($step in @($script:Plan.Steps | Where-Object { $_.Parameters.ContainsKey('Identity') -and $_.Handler -like '*EobAd*' })) {
            $step.Parameters['Identity'] | Should -Be $script:Guid
        }
    }

    It 'ordnet die Aktionen den Phasen der Vorlage zu' {
        ($script:Plan.Steps | Where-Object Action -EQ 'SetExpiration').Phase | Should -Be 'Immediate'
        ($script:Plan.Steps | Where-Object Action -EQ 'DisableAccount').Phase | Should -Be 'ExitDate'
        ($script:Plan.Steps | Where-Object Action -EQ 'ClearProfilePath').Phase | Should -Be 'Retention'
    }

    It 'setzt das Ablaufdatum auf das Ende des Austrittstags' {
        ($script:Plan.Steps | Where-Object Action -EQ 'SetExpiration').Parameters['ExpiresAt'] | Should -Be ([datetime]'2027-04-01')
    }

    It 'erzeugt die Beschreibung aus der Vorlage' {
        $text = ($script:Plan.Steps | Where-Object Action -EQ 'UpdateDescription').Parameters['Replace']['description']
        $text | Should -Be 'Ausgetreten 31.03.2027 | Ticket CHG-1001 | EXAMPLE\admin'
    }

    It 'entfernt nie primäre Gruppe, Synchronisations-, Behalten- oder Lizenzgruppen über RemoveGroups' {
        $removed = @($script:Plan.Steps | Where-Object { $_.Action -eq 'RemoveGroups' } | ForEach-Object { $_.Parameters['Group'] })
        $removed | Should -Contain 'CN=GRP-Vertrieb,OU=Gruppen,DC=example,DC=local'
        $removed | Should -Contain 'CN=VL-Alle,OU=Gruppen,DC=example,DC=local'
        foreach ($kept in @('Domain Users', 'GRP-M365-Sync', 'GRP-Behalten', 'GRP-Lizenz-E3')) {
            $removed | Should -Not -Contain "CN=$kept,OU=Gruppen,DC=example,DC=local"
        }
        ($script:Plan.Steps | Where-Object Action -EQ 'RemoveLicenseGroups').Parameters['Group'] | Should -Be 'CN=GRP-Lizenz-E3,OU=Gruppen,DC=example,DC=local'
        ($script:Plan.Steps | Where-Object Action -EQ 'RemoveLicenseGroups').Phase | Should -Be 'Retention'
    }

    It 'verschiebt als letzte Aktion der Austrittsphase in die Austritts-OU' {
        $exitSteps = @($script:Plan.Steps | Where-Object Phase -EQ 'ExitDate')
        $exitSteps[-1].Action | Should -Be 'MoveToOU'
        $exitSteps[-1].Parameters['TargetPath'] | Should -Be 'OU=Ausgeschieden,DC=example,DC=local'
    }

    It 'setzt das Kennwort nur über einen Secret-Verweis zurück' {
        $reset = $script:Plan.Steps | Where-Object Action -EQ 'ResetPassword'
        $reset.Parameters['NewPassword'] | Should -Be '@Secret:OffboardingPassword'
        $script:Plan.Secrets['OffboardingPassword'] | Should -BeOfType [securestring]
    }

    It 'plant die Löschung nur deaktiviert und mit Termin' {
        $delete = $script:Plan.Steps | Where-Object Action -EQ 'DeleteAccount'
        $delete.Enabled | Should -BeFalse
        $delete.Phase | Should -Be 'FinalDeletion'
        $delete.DueDate | Should -Be ([datetime]'2027-09-27')
    }

    It 'meldet deaktivierte Postfach- und Graph-Funktionen' {
        @($script:Plan.Findings.Code) | Should -Contain 'OFF_EXCHANGE_DISABLED'
        @($script:Plan.Findings.Code) | Should -Contain 'OFF_GRAPH_DISABLED'
        @($script:Plan.Steps | Where-Object Handler -Like '*Mailbox*').Count | Should -Be 0
    }

    It 'fasst den Vorgang zusammen' {
        $script:Plan.Summary['Vorlage'] | Should -Be 'Standardaustritt'
        $script:Plan.Summary['Phase Austritt ab'] | Should -Be '01.04.2027'
        $script:Plan.Summary['Endgültige Löschung'] | Should -Match '27\.09\.2027'
        $script:Plan.Summary['Führungskraft'] | Should -Be 'Chefin Beispiel'
    }

    It 'ermittelt die fälligen Phasen' {
        Get-EobOffboardingDuePhase -Plan $script:Plan -Now $script:BeforeExit | Should -Be @('Immediate')
        Get-EobOffboardingDuePhase -Plan $script:Plan -Now ([datetime]'2027-04-01') | Should -Be @('Immediate', 'ExitDate')
        Get-EobOffboardingDuePhase -Plan $script:Plan -Now ([datetime]'2027-05-02') | Should -Be @('Immediate', 'ExitDate', 'Retention')
    }

    It 'entfernt bei RemoveGroupsMode=Selected nur ausgewählte Gruppen' {
        $request = New-TestRequest -Config $script:Config -Data @{ Template = 'InternerWechsel'; SelectedGroups = 'GRP-Vertrieb' }
        $plan = New-EobOffboardingPlan -Request $request -Config $script:Config -Now $script:BeforeExit
        @($plan.Steps | Where-Object Action -EQ 'RemoveGroups').Parameters.Group | Should -Be @('CN=GRP-Vertrieb,OU=Gruppen,DC=example,DC=local')
        @($plan.Steps | Where-Object Action -EQ 'DisableAccount').Count | Should -Be 0
        @($plan.Steps | Where-Object Action -EQ 'DeleteAccount').Count | Should -Be 0
    }

    It 'erzwingt die Simulation bei der Testvorlage' {
        $plan = New-EobOffboardingPlan -Request (New-TestRequest -Config $script:Config -Data @{ Template = 'Testmodus' }) -Config $script:Config -Now $script:BeforeExit
        $plan.Simulation | Should -BeTrue
        @($plan.Findings.Code) | Should -Contain 'OFF_TEST_TEMPLATE'
    }

    It 'plant Postfachaktionen bei verbundenem Exchange Online' {
        Mock -ModuleName $script:Off Test-EobExchangeConnected { $true }
        Mock -ModuleName $script:Off Get-EobMailboxInfo { [pscustomobject]@{ PrimarySmtpAddress = 'mmuster@example.com'; RecipientTypeDetails = 'UserMailbox' } }
        $config = New-TestConfig -Extra "[Exchange]`nMode=Online"
        $plan = New-EobOffboardingPlan -Request (New-TestRequest -Config $config -Data @{ Template = 'Ruhestand' }) -Config $config -Now $script:BeforeExit
        $forward = $plan.Steps | Where-Object Action -EQ 'SetForwarding'
        $forward.Parameters['ForwardTo'] | Should -Be 'chefin@example.com'
        $forward.Parameters['InternalDomains'] | Should -Contain 'example.com'
        ($plan.Steps | Where-Object Action -EQ 'SetAutoReply').Parameters['Message'] | Should -Match 'Max Muster ist nicht mehr im Unternehmen'
        ($plan.Steps | Where-Object Action -EQ 'HideFromAddressLists').Parameters['Replace']['msExchHideFromAddressLists'] | Should -BeTrue
        $convert = $plan.Steps | Where-Object Action -EQ 'ConvertToSharedMailbox'
        $license = $plan.Steps | Where-Object Action -EQ 'RemoveLicenseGroups'
        [array]::IndexOf(@($plan.Steps), $convert) | Should -BeLessThan ([array]::IndexOf(@($plan.Steps), $license))
        $plan.Offboarding.RequiresIntegration | Should -Contain 'ExitDate'
    }
}

Describe 'Lizenzentfernung nach bestätigter Postfachumwandlung' {
    BeforeEach {
        Set-DirectoryMock
        $script:LicenseConfig = New-TestConfig -Extra "[Exchange]`nMode=Online"
        Mock -ModuleName $script:Off Test-EobExchangeConnected { $true }
        Mock -ModuleName $script:Off Get-EobMailboxInfo { [pscustomobject]@{ RecipientTypeDetails = 'UserMailbox'; PrimarySmtpAddress = 'mmuster@example.com' } }
        Mock -ModuleName $script:Off Get-EobMailboxPermissionReport { @() }
        Mock -ModuleName 'easyONB.Exchange' Assert-EobExchangeConnected { }
        Mock -ModuleName 'easyONB.Exchange' Get-EobMailboxLocation { 'Online' }
        Mock -ModuleName 'easyONB.Exchange' Get-EobMailboxInfo { [pscustomobject]@{ RecipientTypeDetails = 'SharedMailbox' } }
        Mock -ModuleName 'easyONB.Exchange' Set-Mailbox { }
        $script:LicenseActions = @{
            ConvertToSharedMailbox = 'Immediate'; RemoveLicenseGroups = 'Immediate'
            UpdateDescription = 'Off'; SetExpiration = 'Off'; DocumentMailboxPermissions = 'Off'
        }
    }

    It 'verknüpft die Lizenzentfernung in derselben Phase mit der Umwandlung' {
        $request = New-TestRequest -Config $script:LicenseConfig -Data @{ ActionPhases = $script:LicenseActions }
        $plan = New-EobOffboardingPlan -Request $request -Config $script:LicenseConfig -Now $script:BeforeExit
        $convert = $plan.Steps | Where-Object Action -EQ 'ConvertToSharedMailbox'
        $license = $plan.Steps | Where-Object Action -EQ 'RemoveLicenseGroups'
        $license.DependsOn | Should -Be @($convert.Id)
        [array]::IndexOf(@($plan.Steps), $convert) | Should -BeLessThan ([array]::IndexOf(@($plan.Steps), $license))
    }

    It 'behält Lizenzen bei fehlgeschlagener Umwandlung und entfernt sie erst beim erfolgreichen Queue-Retry' {
        Mock -ModuleName 'easyONB.Exchange' Set-Mailbox { throw 'Exchange nicht erreichbar.' }
        $request = New-TestRequest -Config $script:LicenseConfig -Data @{ ActionPhases = $script:LicenseActions }
        $plan = New-EobOffboardingPlan -Request $request -Config $script:LicenseConfig -Now $script:BeforeExit
        $null = Invoke-EobOffboardingPlan -Plan $plan -Now $script:BeforeExit -Confirm:$false
        ($plan.Steps | Where-Object Action -EQ 'ConvertToSharedMailbox').Status | Should -Be 'Failed'
        ($plan.Steps | Where-Object Action -EQ 'RemoveLicenseGroups').Status | Should -Be 'Skipped'
        Should -Invoke -ModuleName $script:Ad Remove-ADGroupMember -Times 0
        @(Get-EobOffboardingQueue -Config $script:LicenseConfig -Now $script:BeforeExit)[0].NextPhase | Should -Be 'Immediate'
        Mock -ModuleName 'easyONB.Exchange' Set-Mailbox { }
        $retry = @(Invoke-EobDueOffboardingPhase -Config $script:LicenseConfig -Now $script:BeforeExit -AllowIntegration -Confirm:$false)
        $retry[0].Outcome | Should -Be 'Succeeded'
        Should -Invoke -ModuleName $script:Ad Remove-ADGroupMember -Times 1 -ParameterFilter { $Identity -eq 'CN=GRP-Lizenz-E3,OU=Gruppen,DC=example,DC=local' }
    }

    It 'behält Lizenzen solange der neue Postfachtyp noch nicht bestätigt ist' {
        Mock -ModuleName 'easyONB.Exchange' Get-EobMailboxInfo { [pscustomobject]@{ RecipientTypeDetails = 'UserMailbox' } }
        $request = New-TestRequest -Config $script:LicenseConfig -Data @{ ActionPhases = $script:LicenseActions }
        $plan = New-EobOffboardingPlan -Request $request -Config $script:LicenseConfig -Now $script:BeforeExit
        $null = Invoke-EobOffboardingPlan -Plan $plan -Now $script:BeforeExit -Confirm:$false
        ($plan.Steps | Where-Object Action -EQ 'ConvertToSharedMailbox').Status | Should -Be 'Failed'
        Should -Invoke -ModuleName $script:Ad Remove-ADGroupMember -Times 0
    }

    It 'behält Lizenzen bei Litigation Hold oder aktivem Archiv' -ForEach @(
        @{ Held = $true; Archive = 'None' }, @{ Held = $false; Archive = 'Active' }
    ) {
        Mock -ModuleName 'easyONB.Exchange' Get-EobMailboxInfo {
            [pscustomobject]@{ RecipientTypeDetails = 'SharedMailbox'; LitigationHoldEnabled = $Held; ArchiveStatus = $Archive }
        }
        $request = New-TestRequest -Config $script:LicenseConfig -Data @{ ActionPhases = $script:LicenseActions }
        $plan = New-EobOffboardingPlan -Request $request -Config $script:LicenseConfig -Now $script:BeforeExit
        $null = Invoke-EobOffboardingPlan -Plan $plan -Now $script:BeforeExit -Confirm:$false
        ($plan.Steps | Where-Object Action -EQ 'ConvertToSharedMailbox').Status | Should -Be 'Failed'
        ($plan.Steps | Where-Object Action -EQ 'RemoveLicenseGroups').Status | Should -Be 'Skipped'
        $plan.Offboarding.CompletedPhases | Should -Not -Contain 'Immediate'
        Should -Invoke -ModuleName $script:Ad Remove-ADGroupMember -Times 0
    }

    It 'prüft die Umwandlung in späteren Queue-Phasen erneut bevor Lizenzen entfernt werden' {
        $script:LicenseActions.RemoveLicenseGroups = 'ExitDate'
        $script:LicenseActions.RemoveGroups = 'Off'
        $script:LicenseActions.DisableAccount = 'Off'
        $script:LicenseActions.DenyLogonHours = 'Off'
        $script:LicenseActions.ResetPassword = 'Off'
        $script:LicenseActions.RevokeSessions = 'Off'
        $script:LicenseActions.SetAutoReply = 'Off'
        $script:LicenseActions.HideFromAddressLists = 'Off'
        $script:LicenseActions.MoveToOU = 'Off'
        $request = New-TestRequest -Config $script:LicenseConfig -Data @{ ActionPhases = $script:LicenseActions }
        $plan = New-EobOffboardingPlan -Request $request -Config $script:LicenseConfig -Now $script:BeforeExit
        $null = Invoke-EobOffboardingPlan -Plan $plan -Now $script:BeforeExit -Confirm:$false
        $item = @(Get-EobOffboardingQueue -Config $script:LicenseConfig -Now ([datetime]'2027-04-01'))[0]
        $queuedPlan = New-EobOffboardingPlanFromQueue -QueueEntry $item -Config $script:LicenseConfig -Now ([datetime]'2027-04-01')
        $gate = $queuedPlan.Steps | Where-Object { $_.Action -eq 'ConvertToSharedMailbox' -and $_.Phase -eq 'ExitDate' }
        ($queuedPlan.Steps | Where-Object Action -EQ 'RemoveLicenseGroups').DependsOn | Should -Be @($gate.Id)
        Mock -ModuleName 'easyONB.Exchange' Set-Mailbox { throw 'Noch nicht verifiziert.' }
        $null = Invoke-EobOffboardingPlan -Plan $queuedPlan -Now ([datetime]'2027-04-01') -Confirm:$false
        Should -Invoke -ModuleName $script:Ad Remove-ADGroupMember -Times 0
        $queuedPlan.Offboarding.CompletedPhases | Should -Not -Contain 'ExitDate'
    }

    It 'schützt auch als RemoveGroups klassifizierte Lizenzgruppen' {
        Mock -ModuleName $script:Off Get-EobOffboardingGroupClassification {
            @([pscustomobject]@{ Name = 'Lizenz'; Category = 'License'; Remove = $true; DistinguishedName = 'CN=Lizenz,DC=example,DC=local'; Reason = '' })
        }
        $script:LicenseActions.RemoveGroups = 'Immediate'
        $script:LicenseActions.RemoveLicenseGroups = 'Off'
        $request = New-TestRequest -Config $script:LicenseConfig -Data @{ ActionPhases = $script:LicenseActions }
        $plan = New-EobOffboardingPlan -Request $request -Config $script:LicenseConfig -Now $script:BeforeExit
        ($plan.Steps | Where-Object Action -EQ 'RemoveGroups').DependsOn | Should -Be @(($plan.Steps | Where-Object Action -EQ 'ConvertToSharedMailbox').Id)
        Mock -ModuleName 'easyONB.Exchange' Set-Mailbox { throw 'Umwandlung fehlgeschlagen.' }
        $null = Invoke-EobOffboardingPlan -Plan $plan -Now $script:BeforeExit -Confirm:$false
        Should -Invoke -ModuleName $script:Ad Remove-ADGroupMember -Times 0
    }

    It 'blockiert Lizenzentfernung vor einer später angeforderten Umwandlung' {
        $script:LicenseActions.ConvertToSharedMailbox = 'Retention'
        $request = New-TestRequest -Config $script:LicenseConfig -Data @{ ActionPhases = $script:LicenseActions }
        $plan = New-EobOffboardingPlan -Request $request -Config $script:LicenseConfig -Now $script:BeforeExit
        @($plan.Findings.Code) | Should -Contain 'OFF_LICENSE_BEFORE_CONVERSION'
        Test-EobPlanExecutable -Plan $plan | Should -BeFalse
    }

    It 'behält Lizenzen wenn die angeforderte Umwandlung ohne Exchange nicht ausführbar ist' {
        $config = New-TestConfig
        $request = New-TestRequest -Config $config -Data @{ ActionPhases = $script:LicenseActions }
        $plan = New-EobOffboardingPlan -Request $request -Config $config -Now $script:BeforeExit
        $null = Invoke-EobOffboardingPlan -Plan $plan -Now $script:BeforeExit -Confirm:$false
        ($plan.Steps | Where-Object Action -EQ 'RemoveLicenseGroups').Status | Should -Be 'Skipped'
        $plan.Offboarding.CompletedPhases | Should -Not -Contain 'Immediate'
        Should -Invoke -ModuleName $script:Ad Remove-ADGroupMember -Times 0
    }
}

Describe 'Ausführung und Warteschlange' {
    BeforeEach {
        Set-DirectoryMock
        $script:Config = New-TestConfig
    }

    It 'behält Warning, Skipped und Planned als wiederholbare Phase' -ForEach @(
        @{ StepStatus = 'Warning' }, @{ StepStatus = 'Skipped' }, @{ StepStatus = 'Planned' }
    ) {
        $plan = New-EobOffboardingPlan -Request (New-TestRequest -Config $script:Config) -Config $script:Config -Now $script:BeforeExit
        foreach ($step in $plan.Steps | Where-Object { $_.Phase -in @('Immediate', 'Always') }) { $step.Status = 'Succeeded' }
        ($plan.Steps | Where-Object Action -EQ 'SetExpiration').Status = $StepStatus
        $null = Complete-EobOffboardingRun -Plan $plan -SelectedPhase Immediate -NoQueue -Confirm:$false
        $plan.Offboarding.CompletedPhases | Should -Not -Contain 'Immediate'
    }

    It 'verlangt in Simulation Simulated statt Live-Erfolg' {
        $plan = New-EobOffboardingPlan -Request (New-TestRequest -Config $script:Config) -Config $script:Config -Now $script:BeforeExit -Simulation
        foreach ($step in $plan.Steps | Where-Object { $_.Phase -in @('Immediate', 'Always') }) { $step.Status = 'Succeeded' }
        $null = Complete-EobOffboardingRun -Plan $plan -SelectedPhase Immediate -NoQueue -Confirm:$false
        $plan.Offboarding.CompletedPhases | Should -Not -Contain 'Immediate'
        foreach ($step in $plan.Steps | Where-Object { $_.Phase -in @('Immediate', 'Always') }) { $step.Status = 'Simulated' }
        $null = Complete-EobOffboardingRun -Plan $plan -SelectedPhase Immediate -NoQueue -Confirm:$false
        $plan.Offboarding.CompletedPhases | Should -Contain 'Immediate'
    }

    It 'entfernt eine alte Phasenfreigabe wenn eine erneute Ausführung unvollständig bleibt' {
        $plan = New-EobOffboardingPlan -Request (New-TestRequest -Config $script:Config) -Config $script:Config -Now $script:BeforeExit
        $plan.Offboarding.CompletedPhases = @('Immediate')
        foreach ($step in $plan.Steps | Where-Object { $_.Phase -in @('Immediate', 'Always') }) { $step.Status = 'Succeeded' }
        ($plan.Steps | Where-Object Action -EQ 'SetExpiration').Status = 'Skipped'
        $null = Complete-EobOffboardingRun -Plan $plan -SelectedPhase Immediate -NoQueue -Confirm:$false
        $plan.Offboarding.CompletedPhases | Should -Not -Contain 'Immediate'
    }

    It 'speichert eine fehlgeschlagene Sofortphase als sofort fällig und wiederholt sie erfolgreich' {
        Mock -ModuleName $script:Ad Set-ADAccountExpiration { throw 'Vorübergehend nicht erreichbar.' }
        $plan = New-EobOffboardingPlan -Request (New-TestRequest -Config $script:Config) -Config $script:Config -Now $script:BeforeExit
        $null = Invoke-EobOffboardingPlan -Plan $plan -Now $script:BeforeExit -Confirm:$false
        $item = @(Get-EobOffboardingQueue -Config $script:Config -Now $script:BeforeExit)[0]
        $item.NextPhase | Should -Be 'Immediate'
        $item.IsDue | Should -BeTrue
        $item.Entry.PhaseStepCount.Immediate | Should -BeGreaterThan 0
        $item.Entry.CompletedPhases | Should -Not -Contain 'Immediate'
        Mock -ModuleName $script:Ad Set-ADAccountExpiration { }
        $retry = @(Invoke-EobDueOffboardingPhase -Config $script:Config -Now $script:BeforeExit -Confirm:$false)
        $retry[0].Outcome | Should -Be 'Succeeded'
        $item = @(Get-EobOffboardingQueue -Config $script:Config -Now $script:BeforeExit)[0]
        $item.Entry.CompletedPhases | Should -Contain 'Immediate'
        $item.NextPhase | Should -Be 'ExitDate'
    }

    It 'plant leere Sofortphasen nicht erneut ein' {
        $request = New-TestRequest -Config $script:Config -Data @{ ActionPhases = @{ UpdateDescription = 'Off'; SetExpiration = 'Off'; ConvertToSharedMailbox = 'Off' } }
        $plan = New-EobOffboardingPlan -Request $request -Config $script:Config -Now $script:BeforeExit
        $null = Save-EobOffboardingQueueEntry -Plan $plan -Confirm:$false
        $item = @(Get-EobOffboardingQueue -Config $script:Config -Now $script:BeforeExit)[0]
        $item.Entry.PhaseStepCount.Immediate | Should -Be 0
        $item.NextPhase | Should -Be 'ExitDate'
    }

    It 'führt nur die fällige Sofortphase aus und legt den Vorgang in die Warteschlange' {
        $plan = New-EobOffboardingPlan -Request (New-TestRequest -Config $script:Config) -Config $script:Config -Now $script:BeforeExit
        $result = Invoke-EobOffboardingPlan -Plan $plan -Now $script:BeforeExit -Confirm:$false
        $result.Status | Should -Be 'Succeeded'
        Should -Invoke -ModuleName $script:Ad Set-ADAccountExpiration -Times 1 -ParameterFilter { $DateTime -eq [datetime]'2027-04-01' }
        Should -Invoke -ModuleName $script:Ad Set-ADUser -Times 1 -ParameterFilter { $Replace['description'] -like 'Ausgetreten 31.03.2027*' }
        Should -Invoke -ModuleName $script:Ad Disable-ADAccount -Times 0
        ($result.Steps | Where-Object Action -EQ 'DisableAccount').Status | Should -Be 'Planned'

        $queue = @(Get-EobOffboardingQueue -Config $script:Config -Now $script:BeforeExit)
        $queue.Count | Should -Be 1
        $queue[0].Status | Should -Be 'Open'
        $queue[0].NextPhase | Should -Be 'ExitDate'
        $queue[0].NextDueDate | Should -Be ([datetime]'2027-04-01')
        $queue[0].IsDue | Should -BeFalse
        @($queue[0].Entry['CompletedPhases']) | Should -Be @('Immediate')
        @($queue[0].Entry['SnapshotPaths']).Count | Should -Be 2
        Test-Path -LiteralPath @($queue[0].Entry['SnapshotPaths'])[0] | Should -BeTrue
        foreach ($snapshot in @($queue[0].Entry['SnapshotPaths'])) {
            $queue[0].Entry['SnapshotHashes'][$snapshot] | Should -Be (Get-FileHash -LiteralPath $snapshot -Algorithm SHA256).Hash
        }
    }

    It 'speichert weder Kennwörter noch Secrets in Warteschlange, Snapshots, Logs oder Berichten' {
        $plan = New-EobOffboardingPlan -Request (New-TestRequest -Config $script:Config -Data @{ Template = 'SofortigeSperrung' }) -Config $script:Config -Now $script:BeforeExit
        $secret = ConvertTo-EobPlainText -SecureString $plan.Secrets['OffboardingPassword']
        $result = Invoke-EobOffboardingPlan -Plan $plan -Now $script:BeforeExit -Confirm:$false
        Should -Invoke -ModuleName $script:Ad Set-ADAccountPassword -Times 1 -ParameterFilter { $NewPassword -is [securestring] -and $Reset }
        $null = Export-EobPlanReport -Plan $result -Config $script:Config -Format Html, Json, Csv, Txt -Confirm:$false
        $files = Get-ChildItem -LiteralPath $script:Config.TestRoot -Recurse -File
        $files.Count | Should -BeGreaterThan 3
        foreach ($file in $files) {
            (Get-Content -LiteralPath $file.FullName -Raw) | Should -Not -Match ([regex]::Escape($secret))
        }
        foreach ($log in Get-ChildItem -LiteralPath (Join-Path $TestDrive 'logs') -Recurse -File) {
            (Get-Content -LiteralPath $log.FullName -Raw) | Should -Not -Match ([regex]::Escape($secret))
        }
        (Get-Content -LiteralPath @(Get-EobOffboardingQueue -Config $script:Config)[0].Path -Raw) | Should -Not -Match 'Secret|Password"'
    }

    It 'simuliert ohne Änderungen und ohne Warteschlangeneintrag' {
        $plan = New-EobOffboardingPlan -Request (New-TestRequest -Config $script:Config -Data @{ Template = 'SofortigeSperrung' }) -Config $script:Config -Now $script:BeforeExit
        $result = Invoke-EobOffboardingPlan -Plan $plan -Now $script:BeforeExit -WhatIf
        $result.Status | Should -Be 'Simulated'
        Should -Invoke -ModuleName $script:Ad Disable-ADAccount -Times 0
        Should -Invoke -ModuleName $script:Ad Set-ADUser -Times 0
        @(Get-EobOffboardingQueue -Config $script:Config).Count | Should -Be 0
    }

    It 'verarbeitet Folgephasen aus der Warteschlange bis zur Löschfreigabe' {
        $plan = New-EobOffboardingPlan -Request (New-TestRequest -Config $script:Config) -Config $script:Config -Now $script:BeforeExit
        $null = Invoke-EobOffboardingPlan -Plan $plan -Now $script:BeforeExit -Confirm:$false

        $exitRun = @(Invoke-EobDueOffboardingPhase -Config $script:Config -Now ([datetime]'2027-04-01 06:00') -Confirm:$false)
        $exitRun.Count | Should -Be 1
        $exitRun[0].Phases | Should -Be @('ExitDate')
        $exitRun[0].Outcome | Should -Be 'Succeeded'
        Should -Invoke -ModuleName $script:Ad Disable-ADAccount -Times 1
        Should -Invoke -ModuleName $script:Ad Move-ADObject -Times 1 -ParameterFilter { $TargetPath -eq 'OU=Ausgeschieden,DC=example,DC=local' }
        Should -Invoke -ModuleName $script:Ad Remove-ADGroupMember -Times 2
        Should -Invoke -ModuleName $script:Ad Remove-ADGroupMember -Times 0 -ParameterFilter { $Identity -match 'GRP-M365-Sync|GRP-Behalten|GRP-Lizenz-E3|Domain Users' }

        $retentionRun = @(Invoke-EobDueOffboardingPhase -Config $script:Config -Now ([datetime]'2027-05-02') -Confirm:$false)
        $retentionRun[0].Phases | Should -Be @('Retention')
        Should -Invoke -ModuleName $script:Ad Remove-ADGroupMember -Times 1 -ParameterFilter { $Identity -eq 'CN=GRP-Lizenz-E3,OU=Gruppen,DC=example,DC=local' }
        Should -Invoke -ModuleName $script:Ad Set-ADUser -Times 1 -ParameterFilter { $Clear -contains 'profilePath' }

        $entry = @(Get-EobOffboardingQueue -Config $script:Config)[0]
        $entry.Status | Should -Be 'AwaitingDeletion'
        @($entry.Entry['CompletedPhases']) | Should -Be @('Immediate', 'ExitDate', 'Retention')
        @(Get-ChildItem -LiteralPath (Join-Path $script:Config.TestRoot 'reports') -Recurse -Filter '*.html').Count | Should -Be 2

        $noop = @(Invoke-EobDueOffboardingPhase -Config $script:Config -Now ([datetime]'2027-06-01') -Confirm:$false)
        $noop.Count | Should -Be 0
        Should -Invoke -ModuleName $script:Ad Remove-ADObject -Times 0
    }

    It 'meldet fällige Löschungen nur, statt sie auszuführen' {
        $plan = New-EobOffboardingPlan -Request (New-TestRequest -Config $script:Config -Data @{ Template = 'Extern' }) -Config $script:Config -Now $script:BeforeExit
        $null = Invoke-EobOffboardingPlan -Plan $plan -Now ([datetime]'2027-04-10') -Confirm:$false
        $result = @(Invoke-EobDueOffboardingPhase -Config $script:Config -Now ([datetime]'2027-05-15') -Confirm:$false)
        $result[0].Action | Should -Be 'DeletionDue'
        $result[0].Outcome | Should -Be 'ManualApprovalRequired'
        Should -Invoke -ModuleName $script:Ad Remove-ADObject -Times 0
    }

    It 'führt privilegierte Konten nicht unbeaufsichtigt weiter' {
        Set-DirectoryMock -Privileged @('Domain Admins')
        $config = New-TestConfig -Extra "[Security]`nAllowPrivilegedOffboarding=1"
        $plan = New-EobOffboardingPlan -Request (New-TestRequest -Config $config -Data @{ AcknowledgePrivileged = $true }) -Config $config -Now $script:BeforeExit
        $null = Invoke-EobOffboardingPlan -Plan $plan -Now $script:BeforeExit -Confirm:$false
        $result = @(Invoke-EobDueOffboardingPhase -Config $config -Now ([datetime]'2027-04-02') -Confirm:$false)
        $result[0].Outcome | Should -Be 'ManualRequired'
        Should -Invoke -ModuleName $script:Ad Disable-ADAccount -Times 0
    }

    It 'führt Phasen mit Exchange-Aktionen ohne Verbindung nicht unbeaufsichtigt aus' {
        Mock -ModuleName $script:Off Test-EobExchangeConnected { $true }
        Mock -ModuleName $script:Off Get-EobMailboxInfo { [pscustomobject]@{ PrimarySmtpAddress = 'mmuster@example.com' } }
        Mock -ModuleName $script:Off Get-EobMailboxPermissionReport { @() }
        $config = New-TestConfig -Extra "[Exchange]`nMode=Online"
        $plan = New-EobOffboardingPlan -Request (New-TestRequest -Config $config) -Config $config -Now $script:BeforeExit
        $null = Invoke-EobOffboardingPlan -Plan $plan -Now $script:BeforeExit -Confirm:$false
        Mock -ModuleName $script:Off Test-EobExchangeConnected { $false }
        $result = @(Invoke-EobDueOffboardingPhase -Config $config -Now ([datetime]'2027-04-02') -Confirm:$false)
        $result[0].Outcome | Should -Be 'ManualRequired'
        Should -Invoke -ModuleName $script:Ad Disable-ADAccount -Times 0
    }

    It 'führt Phasen mit Sitzungswiderruf ohne Graph-Verbindung nicht unbeaufsichtigt aus' {
        Mock -ModuleName $script:Off Get-EobGraphStatus { [pscustomobject]@{ State = 'NotConnected' } }
        $config = New-TestConfig -Extra "[Graph]`nEnabled=1"
        $plan = New-EobOffboardingPlan -Request (New-TestRequest -Config $config) -Config $config -Now $script:BeforeExit
        $plan.Offboarding.RequiresGraph | Should -Be @('ExitDate')
        $null = Invoke-EobOffboardingPlan -Plan $plan -Now $script:BeforeExit -Confirm:$false
        $result = @(Invoke-EobDueOffboardingPhase -Config $config -Now ([datetime]'2027-04-02') -AllowIntegration -Confirm:$false)
        $result[0].Outcome | Should -Be 'ManualRequired'
        $result[0].Message | Should -Match 'Microsoft Graph'
        Should -Invoke -ModuleName $script:Ad Disable-ADAccount -Times 0
    }

    It 'erzwingt beim Vorziehen von Phasen die Reihenfolge' {
        $plan = New-EobOffboardingPlan -Request (New-TestRequest -Config $script:Config) -Config $script:Config -Now $script:BeforeExit
        { Invoke-EobOffboardingPlan -Plan $plan -Phase ExitDate -Now $script:BeforeExit -Confirm:$false } | Should -Throw '*setzt die Phase*Immediate*'
        { Invoke-EobOffboardingPlan -Plan $plan -Phase Immediate, Retention -Now $script:BeforeExit -Confirm:$false } | Should -Throw '*setzt die Phase*ExitDate*'
        $result = Invoke-EobOffboardingPlan -Plan $plan -Phase Immediate, ExitDate -Now $script:BeforeExit -Confirm:$false
        Should -Invoke -ModuleName $script:Ad Disable-ADAccount -Times 1
        @($result.Offboarding.CompletedPhases) | Should -Be @('Immediate', 'ExitDate')
    }

    It 'überspringt defekte Warteschlangeneinträge, statt das Lesen abzubrechen' {
        $plan = New-EobOffboardingPlan -Request (New-TestRequest -Config $script:Config) -Config $script:Config -Now $script:BeforeExit
        $null = Invoke-EobOffboardingPlan -Plan $plan -Now $script:BeforeExit -Confirm:$false
        $directory = Split-Path -Parent @(Get-EobOffboardingQueue -Config $script:Config)[0].Path
        Set-Content -LiteralPath (Join-Path $directory '0-leer.json') -Value '' -NoNewline
        Set-Content -LiteralPath (Join-Path $directory '1-liste.json') -Value '[1, 2]'
        Set-Content -LiteralPath (Join-Path $directory '2-ohne-phasen.json') -Value '{"OperationId":"x","Status":"Open"}'
        $queue = @(Get-EobOffboardingQueue -Config $script:Config -WarningAction SilentlyContinue)
        $queue.Count | Should -Be 1
        $queue[0].OperationId | Should -Be $plan.OperationId
    }

    It 'bricht einen Vorgang in der Warteschlange ab' {
        $plan = New-EobOffboardingPlan -Request (New-TestRequest -Config $script:Config) -Config $script:Config -Now $script:BeforeExit
        $null = Invoke-EobOffboardingPlan -Plan $plan -Now $script:BeforeExit -Confirm:$false
        $null = Stop-EobOffboardingQueueEntry -Config $script:Config -OperationId $plan.OperationId -Reason 'Kündigung zurückgenommen' -Confirm:$false
        @(Get-EobOffboardingQueue -Config $script:Config)[0].Status | Should -Be 'Cancelled'
        @(Invoke-EobDueOffboardingPhase -Config $script:Config -Now ([datetime]'2027-04-02') -Confirm:$false).Count | Should -Be 0
        Should -Invoke -ModuleName $script:Ad Disable-ADAccount -Times 0
    }

    It 'bricht Folgephasen ab, wenn das Konto eine andere ObjectGUID hat' {
        $plan = New-EobOffboardingPlan -Request (New-TestRequest -Config $script:Config) -Config $script:Config -Now $script:BeforeExit
        $null = Invoke-EobOffboardingPlan -Plan $plan -Now $script:BeforeExit -Confirm:$false
        $script:TestUser = ConvertTo-EobAdUserInfo -AdUser ([pscustomobject]@{ SamAccountName = 'mmuster'; SID = 'S-1-5-21-1-2-3-9999'; ObjectGUID = '99999999-2222-3333-4444-555555555555'; Enabled = $true; DistinguishedName = 'CN=Max Muster,OU=Mitarbeiter,DC=example,DC=local'; ObjectClass = 'user' })
        $result = @(Invoke-EobDueOffboardingPhase -Config $script:Config -Now ([datetime]'2027-04-02') -Confirm:$false)
        $result[0].Outcome | Should -Be 'Blocked'
        $result[0].Message | Should -Match 'ObjectGUID'
        Should -Invoke -ModuleName $script:Ad Disable-ADAccount -Times 0
    }
}

Describe 'Endgültige Löschung' {
    BeforeEach {
        Set-DirectoryMock
        $script:Config = New-TestConfig
        $plan = New-EobOffboardingPlan -Request (New-TestRequest -Config $script:Config) -Config $script:Config -Now $script:BeforeExit
        $null = Invoke-EobOffboardingPlan -Plan $plan -Phase Immediate, ExitDate, Retention -Now $script:BeforeExit -Confirm:$false
        $script:OperationId = $plan.OperationId
        $script:TestUser = New-TestUser -Enabled $false
    }

    It 'verweigert die Löschung vor Ablauf der Aufbewahrungsfrist' {
        $deletion = New-EobOffboardingDeletionPlan -OperationId $script:OperationId -Config $script:Config -Now ([datetime]'2027-06-01')
        @($deletion.Findings.Code) | Should -Contain 'OFF_DEL_RETENTION_ACTIVE'
        { Invoke-EobOffboardingFinalDeletion -Plan $deletion -ConfirmationText 'LÖSCHEN mmuster' -Confirm:$false } | Should -Throw
        Should -Invoke -ModuleName $script:Ad Remove-ADObject -Times 0
    }

    It 'verweigert die Löschung aktivierter Konten' {
        $script:TestUser = New-TestUser -Enabled $true
        $deletion = New-EobOffboardingDeletionPlan -OperationId $script:OperationId -Config $script:Config -Now ([datetime]'2027-10-01')
        @($deletion.Findings.Code) | Should -Contain 'OFF_DEL_ENABLED'
    }

    It 'verweigert die Löschung ohne Zustandsbericht' {
        Get-ChildItem -LiteralPath (Join-Path $script:Config.TestRoot 'snapshots') -Recurse -File | Remove-Item -Force
        $deletion = New-EobOffboardingDeletionPlan -OperationId $script:OperationId -Config $script:Config -Now ([datetime]'2027-10-01')
        @($deletion.Findings.Code) | Should -Contain 'OFF_DEL_NO_BACKUP'
    }

    It 'verweigert die Löschung, wenn der Zustandsbericht verändert wurde' {
        $snapshot = @(Get-ChildItem -LiteralPath (Join-Path $script:Config.TestRoot 'snapshots') -Recurse -File -Filter '*_vorher_*')[0]
        Add-Content -LiteralPath $snapshot.FullName -Value ' '
        $deletion = New-EobOffboardingDeletionPlan -OperationId $script:OperationId -Config $script:Config -Now ([datetime]'2027-10-01')
        @($deletion.Findings.Code) | Should -Contain 'OFF_DEL_BACKUP_MODIFIED'
        Test-EobPlanExecutable -Plan $deletion | Should -BeFalse
    }

    It 'verlangt den exakten Bestätigungstext' {
        $deletion = New-EobOffboardingDeletionPlan -OperationId $script:OperationId -Config $script:Config -Now ([datetime]'2027-10-01')
        Test-EobPlanExecutable -Plan $deletion | Should -BeTrue
        $deletion.Summary['Bestätigungstext'] | Should -Be 'LÖSCHEN mmuster'
        { Invoke-EobOffboardingFinalDeletion -Plan $deletion -Confirm:$false } | Should -Throw '*LÖSCHEN mmuster*'
        { Invoke-EobOffboardingFinalDeletion -Plan $deletion -ConfirmationText 'löschen mmuster' -Confirm:$false } | Should -Throw
        Should -Invoke -ModuleName $script:Ad Remove-ADObject -Times 0
    }

    It 'simuliert die Löschung mit -WhatIf' {
        $deletion = New-EobOffboardingDeletionPlan -OperationId $script:OperationId -Config $script:Config -Now ([datetime]'2027-10-01')
        $result = Invoke-EobOffboardingFinalDeletion -Plan $deletion -WhatIf
        $result.Status | Should -Be 'Simulated'
        Should -Invoke -ModuleName $script:Ad Remove-ADObject -Times 0
        @(Get-EobOffboardingQueue -Config $script:Config)[0].Status | Should -Be 'AwaitingDeletion'
    }

    It 'löscht nach Freigabe mit Sicherung und GUID-Abgleich' {
        $deletion = New-EobOffboardingDeletionPlan -OperationId $script:OperationId -Config $script:Config -Now ([datetime]'2027-10-01')
        $deletion.Steps[0].Action | Should -Be 'SnapshotBeforeDeletion'
        $result = Invoke-EobOffboardingFinalDeletion -Plan $deletion -ConfirmationText 'LÖSCHEN mmuster' -Confirm:$false
        $result.Status | Should -Be 'Succeeded'
        Should -Invoke -ModuleName $script:Ad Remove-ADObject -Times 1 -ParameterFilter { $Identity -eq 'CN=Max Muster,OU=Mitarbeiter,DC=example,DC=local' }
        $entry = @(Get-EobOffboardingQueue -Config $script:Config)[0]
        $entry.Status | Should -Be 'Deleted'
        @($entry.Entry['SnapshotPaths'] | Where-Object { $_ -match 'vor-loeschung' }).Count | Should -Be 1
        @(Get-EobAuditEntry -OperationId $script:OperationId).Action | Should -Contain 'DeleteAccount'
    }

    It 'warnt bei deaktiviertem AD-Papierkorb und synchronisiertem Postfach' {
        Mock -ModuleName $script:Off Test-EobAdRecycleBinEnabled { $false }
        $config = New-TestConfig -Extra "[Exchange]`nMode=Hybrid"
        $plan = New-EobOffboardingPlan -Request (New-TestRequest -Config $config) -Config $config -Now $script:BeforeExit
        $null = Invoke-EobOffboardingPlan -Plan $plan -Phase Immediate, ExitDate, Retention -Now $script:BeforeExit -Confirm:$false
        $deletion = New-EobOffboardingDeletionPlan -OperationId $plan.OperationId -Config $config -Now ([datetime]'2027-10-01')
        @($deletion.Findings.Code) | Should -Contain 'OFF_DEL_NO_RECYCLEBIN'
        @($deletion.Findings.Code) | Should -Contain 'OFF_DEL_CLOUD_MAILBOX'
    }
}

Describe 'Home-Verzeichnis-Handler' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ('fs-' + [guid]::NewGuid().ToString('N'))
        $script:HomeDir = Join-Path $script:Root 'home/mmuster'
        $script:Archive = Join-Path $script:Root 'archiv'
        $null = New-Item -ItemType Directory -Path $script:HomeDir -Force
        Set-Content -LiteralPath (Join-Path $script:HomeDir 'datei.txt') -Value 'Inhalt'
    }

    It 'verschiebt das Verzeichnis in das Archiv' {
        $result = Move-EobHomeDirectoryToArchive -Path $script:HomeDir -ArchiveRoot $script:Archive -AllowedRoots $script:Root -SamAccountName 'mmuster' -Confirm:$false
        $result.Status | Should -Be 'Succeeded'
        Test-Path -LiteralPath $script:HomeDir | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $result.Data['ArchivedHomeDirectory'] 'datei.txt') | Should -BeTrue
    }

    It 'verweigert Pfade außerhalb der Stammpfade und Stammpfade selbst' {
        { Move-EobHomeDirectoryToArchive -Path $script:HomeDir -ArchiveRoot $script:Archive -AllowedRoots (Join-Path $TestDrive 'anderes') -SamAccountName 'x' -Confirm:$false } | Should -Throw '*erlaubten Stammpfad*'
        { Move-EobHomeDirectoryToArchive -Path $script:Root -ArchiveRoot $script:Archive -AllowedRoots $script:Root -SamAccountName 'x' -Confirm:$false } | Should -Throw '*Stammpfad selbst*'
        Test-Path -LiteralPath $script:HomeDir | Should -BeTrue
    }

    It 'simuliert ohne Verschieben' {
        $result = Move-EobHomeDirectoryToArchive -Path $script:HomeDir -ArchiveRoot $script:Archive -AllowedRoots $script:Root -SamAccountName 'mmuster' -WhatIf
        $result.Message | Should -Match '^Simulation'
        Test-Path -LiteralPath $script:HomeDir | Should -BeTrue
    }

    It 'wiederholt nach erfolgreicher Archivierung nur die fehlgeschlagene AD-Bereinigung' {
        Set-DirectoryMock -User (New-TestUser -HomeDirectory $script:HomeDir)
        $config = New-TestConfig -Extra "[FileServer]`nAllowedRoots=$($script:Root)`nArchiveRoot=$($script:Archive)"
        $request = New-TestRequest -Config $config -Data @{
            ActionPhases = @{ ArchiveHomeDirectory = 'Immediate'; UpdateDescription = 'Off'; SetExpiration = 'Off'; DocumentMailboxPermissions = 'Off'; ConvertToSharedMailbox = 'Off' }
        }
        Mock -ModuleName $script:Ad Set-ADUser { throw 'AD-Bereinigung vorübergehend nicht möglich.' } -ParameterFilter { $Clear -contains 'homeDirectory' }
        $plan = New-EobOffboardingPlan -Request $request -Config $config -Now $script:BeforeExit
        $null = Invoke-EobOffboardingPlan -Plan $plan -Now $script:BeforeExit -Confirm:$false
        $archivePath = $plan.Runtime.ArchivedHomeDirectory
        Test-Path -LiteralPath $script:HomeDir | Should -BeFalse
        Test-Path -LiteralPath $archivePath -PathType Container | Should -BeTrue
        $plan.Offboarding.CompletedPhases | Should -Not -Contain 'Immediate'
        $queued = @(Get-EobOffboardingQueue -Config $config -Now $script:BeforeExit)[0]
        $queued.Entry.HomeArchiveProof.DestinationPath | Should -Be $archivePath
        $queued.Entry.HomeArchiveProof.ObjectGuid | Should -Be $script:Guid
        $queued.Entry.HomeArchiveProof.ObjectGuid = '99999999-2222-3333-4444-555555555555'
        $invalid = New-EobOffboardingPlanFromQueue -QueueEntry $queued -Config $config -Now $script:BeforeExit
        @($invalid.Findings.Code) | Should -Contain 'OFF_HOME_ARCHIVE_PROOF_INVALID'
        Test-EobPlanExecutable -Plan $invalid | Should -BeFalse
        $queued.Entry.HomeArchiveProof.ObjectGuid = $script:Guid
        $retryPlan = New-EobOffboardingPlanFromQueue -QueueEntry $queued -Config $config -Now $script:BeforeExit
        $retryPlan.Runtime.ArchivedHomeDirectory | Should -Be $archivePath
        Mock -ModuleName $script:Ad Set-ADUser { } -ParameterFilter { $Clear -contains 'homeDirectory' }
        $null = Invoke-EobOffboardingPlan -Plan $retryPlan -Now $script:BeforeExit -Confirm:$false
        ($retryPlan.Steps | Where-Object Handler -EQ 'Move-EobHomeDirectoryToArchive').Status | Should -Be 'Succeeded'
        $retryPlan.Offboarding.CompletedPhases | Should -Contain 'Immediate'
        $retryPlan.Runtime.ArchivedHomeDirectory | Should -Be $archivePath
        @(Get-ChildItem -LiteralPath $script:Archive -Directory).Count | Should -Be 1
        Test-Path -LiteralPath (Join-Path $archivePath 'datei.txt') | Should -BeTrue
        Should -Invoke -ModuleName $script:Ad Set-ADUser -Times 2 -ParameterFilter { $Clear -contains 'homeDirectory' }
    }

    It 'behält einen fehlenden Quellpfad ohne Archivnachweis als unvollständig' {
        Set-DirectoryMock -User (New-TestUser -HomeDirectory $script:HomeDir)
        Remove-Item -LiteralPath $script:HomeDir -Recurse -Force
        $config = New-TestConfig -Extra "[FileServer]`nAllowedRoots=$($script:Root)`nArchiveRoot=$($script:Archive)"
        $request = New-TestRequest -Config $config -Data @{
            ActionPhases = @{ ArchiveHomeDirectory = 'Immediate'; UpdateDescription = 'Off'; SetExpiration = 'Off'; DocumentMailboxPermissions = 'Off'; ConvertToSharedMailbox = 'Off' }
        }
        $plan = New-EobOffboardingPlan -Request $request -Config $config -Now $script:BeforeExit
        $null = Invoke-EobOffboardingPlan -Plan $plan -Now $script:BeforeExit -Confirm:$false
        ($plan.Steps | Where-Object Handler -EQ 'Move-EobHomeDirectoryToArchive').Status | Should -Be 'Skipped'
        $plan.Offboarding.CompletedPhases | Should -Not -Contain 'Immediate'
        Should -Invoke -ModuleName $script:Ad Set-ADUser -Times 0 -ParameterFilter { $Clear -contains 'homeDirectory' }
        $queued = @(Get-EobOffboardingQueue -Config $config -Now $script:BeforeExit)[0]
        $queued.Entry.HomeArchiveProof | Should -BeNullOrEmpty
        $queued.NextPhase | Should -Be 'Immediate'
    }

    It 'akzeptiert keinen Archivnachweis für fremde Verzeichnisse oder außerhalb des Archivziels' -ForEach @(
        @{ Relative = 'anderer_20261012-110000'; Parent = 'archive' }
        @{ Relative = 'mmuster_20261012-110000'; Parent = 'outside' }
    ) {
        Remove-Item -LiteralPath $script:HomeDir -Recurse -Force
        $parentPath = if ($Parent -eq 'archive') { $script:Archive } else { Join-Path $script:Root 'anderes-archiv' }
        $destination = Join-Path $parentPath $Relative
        $null = New-Item -ItemType Directory -Path $destination -Force
        { Move-EobHomeDirectoryToArchive -Path $script:HomeDir -ArchiveRoot $script:Archive -AllowedRoots $script:Root `
                -SamAccountName 'mmuster' -ArchivedHomeDirectory $destination -Confirm:$false } | Should -Throw '*Benutzerarchiv*'
    }

    It 'plant Archivierung und Austragen des Home-Verzeichnisses' {
        Set-DirectoryMock -User (New-TestUser -HomeDirectory $script:HomeDir)
        $config = New-TestConfig -Extra "[FileServer]`nAllowedRoots=$($script:Root)`nArchiveRoot=$($script:Archive)"
        $plan = New-EobOffboardingPlan -Request (New-TestRequest -Config $config) -Config $config -Now $script:BeforeExit
        $archive = $plan.Steps | Where-Object Action -EQ 'ArchiveHomeDirectory' | Select-Object -First 1
        $archive.Handler | Should -Be 'Move-EobHomeDirectoryToArchive'
        $clear = $plan.Steps | Where-Object { $_.Action -eq 'ArchiveHomeDirectory' -and $_.Handler -eq 'Set-EobAdUserAttribute' }
        $clear.DependsOn | Should -Be @($archive.Id)
        $clear.Parameters['Clear'] | Should -Be @('homeDirectory', 'homeDrive')
    }
}

Describe 'Home-Zugriff mit ausdrücklicher Freigabe' {
    BeforeEach {
        $script:AccessRoot = Join-Path $TestDrive ('access-' + [guid]::NewGuid().ToString('N'))
        $script:AccessHome = Join-Path $script:AccessRoot 'mmuster'
        $null = New-Item -ItemType Directory -Path $script:AccessHome -Force
        $script:AccessParameters = @{
            Path = $script:AccessHome; SamAccountName = 'mmuster'; Account = 'chefin'
            AuthorizedAccount = 'chefin'; DomainNetBiosName = 'EXAMPLE'; AllowedRoots = @($script:AccessRoot)
        }
    }

    It 'verweigert den gemeinsamen Stammpfad selbst' {
        $script:AccessParameters.Path = $script:AccessRoot
        { Grant-EobHomeDirectoryAccess @script:AccessParameters -WhatIf } | Should -Throw '*Stammpfad selbst*'
    }

    It 'verweigert auch einen Stammpfad der zugleich ein Benutzerordner unter einem anderen Stammpfad ist' {
        $script:AccessParameters.AllowedRoots += $script:AccessHome
        { Grant-EobHomeDirectoryAccess @script:AccessParameters -WhatIf } | Should -Throw '*Stammpfad selbst*'
    }

    It 'verweigert andere Benutzerordner und beliebige Unterordner' -ForEach @(
        @{ Child = 'anderer' }, @{ Child = 'anderer/mmuster' }, @{ Child = 'mmuster/unterordner' }, @{ Child = 'mmuster-neu' }
    ) {
        $script:AccessParameters.Path = Join-Path $script:AccessRoot $Child
        { Grant-EobHomeDirectoryAccess @script:AccessParameters -WhatIf } | Should -Throw '*exakt*'
    }

    It 'verweigert Traversal auch wenn der normalisierte Pfad dem Benutzerordner entspricht' -ForEach @(
        @{ Child = 'anderer/../mmuster' }, @{ Child = './mmuster' }, @{ Child = 'mmuster/../anderer' }
    ) {
        $script:AccessParameters.Path = Join-Path $script:AccessRoot $Child
        { Grant-EobHomeDirectoryAccess @script:AccessParameters -WhatIf } | Should -Throw '*unsichere Pfadsegmente*'
    }

    It 'verweigert fehlende oder abweichende Empfängerfreigaben' -ForEach @(
        @{ Authorization = '' }, @{ Authorization = 'anderer' }, @{ Authorization = 'OTHER\chefin' },
        @{ Authorization = 'EXAMPLE\anderer' }, @{ Authorization = 'chefin@example.com' }
    ) {
        $script:AccessParameters.AuthorizedAccount = $Authorization
        { Grant-EobHomeDirectoryAccess @script:AccessParameters -WhatIf } | Should -Throw '*nicht ausdrücklich freigegeben*'
    }

    It 'verweigert ungültige Absendernamen und Domänen' {
        $script:AccessParameters.SamAccountName = '../mmuster'
        { Grant-EobHomeDirectoryAccess @script:AccessParameters -WhatIf } | Should -Throw '*Ungültiger Home*'
        $script:AccessParameters.SamAccountName = 'mmuster'
        $script:AccessParameters.DomainNetBiosName = 'OTHER\chefin'
        { Grant-EobHomeDirectoryAccess @script:AccessParameters -WhatIf } | Should -Throw '*NetBIOS*'
    }

    It 'simuliert den legitimen Benutzerordner ohne ACL-Zugriff' -ForEach @(
        @{ Authorization = 'chefin' }, @{ Authorization = 'EXAMPLE\chefin' }, @{ Authorization = 'example\CHEFIN' }
    ) {
        $script:AccessParameters.AuthorizedAccount = $Authorization
        $result = Grant-EobHomeDirectoryAccess @script:AccessParameters -WhatIf
        $result.Message | Should -Match '^Simulation'
        Test-Path -LiteralPath $script:AccessHome -PathType Container | Should -BeTrue
    }

    It 'verweigert nicht vorhandene Home-Verzeichnisse und relative Pfade' {
        Remove-Item -LiteralPath $script:AccessHome -Recurse -Force
        { Grant-EobHomeDirectoryAccess @script:AccessParameters -WhatIf } | Should -Throw
        $script:AccessParameters.Path = 'mmuster'
        { Grant-EobHomeDirectoryAccess @script:AccessParameters -WhatIf } | Should -Throw '*exakt*'
    }

    It 'verweigert ReparsePoints im Benutzerordner und in Vorfahren' -ForEach @(
        @{ LinkLocation = 'home' }, @{ LinkLocation = 'root' }, @{ LinkLocation = 'ancestor' }
    ) {
        $blocked = switch ($LinkLocation) {
            'home' { $script:AccessHome }
            'root' { $script:AccessRoot }
            'ancestor' { Split-Path -Parent $script:AccessRoot }
        }
        Mock -ModuleName $script:Off Get-Item {
            [pscustomobject]@{
                PSProvider = [pscustomobject]@{ Name = 'FileSystem' }; PSIsContainer = $true; FullName = $LiteralPath
                Attributes = if ($LiteralPath -eq $blocked) { [IO.FileAttributes]::ReparsePoint } else { [IO.FileAttributes]::Directory }
            }
        }
        { Grant-EobHomeDirectoryAccess @script:AccessParameters -WhatIf } | Should -Throw '*ReparsePoint*'
    }

    It 'verweigert einen echten symbolischen Benutzerordner' -Skip:($IsWindows) {
        $other = Join-Path $script:AccessRoot 'anderer'
        $null = New-Item -ItemType Directory -Path $other
        Remove-Item -LiteralPath $script:AccessHome -Recurse -Force
        $null = New-Item -ItemType SymbolicLink -Path $script:AccessHome -Target $other
        { Grant-EobHomeDirectoryAccess @script:AccessParameters -WhatIf } | Should -Throw '*ReparsePoint*'
    }

    It 'plant keine Freigabe allein aufgrund des AD-Managerattributs' {
        Set-DirectoryMock -User (New-TestUser -HomeDirectory $script:AccessHome)
        $config = New-TestConfig -Extra "[FileServer]`nAllowedRoots=$($script:AccessRoot)"
        $request = New-TestRequest -Config $config -Data @{ ActionPhases = @{ GrantManagerHomeAccess = 'Immediate' } }
        $plan = New-EobOffboardingPlan -Request $request -Config $config -Now $script:BeforeExit
        @($plan.Steps | Where-Object Handler -EQ 'Grant-EobHomeDirectoryAccess').Count | Should -Be 0
        @($plan.Findings.Code) | Should -Contain 'OFF_HOME_ACCESS_AUTH_REQUIRED'
    }

    It 'bindet einen autorisierten Planschritt an den Absender und das freigegebene Empfängerkonto' -ForEach @(
        @{ Authorization = 'chefin' }, @{ Authorization = 'EXAMPLE\chefin' }
    ) {
        Set-DirectoryMock -User (New-TestUser -HomeDirectory $script:AccessHome)
        $config = New-TestConfig -Extra "[FileServer]`nAllowedRoots=$($script:AccessRoot)"
        $request = New-TestRequest -Config $config -Data @{
            AuthorizedHomeAccessAccount = $Authorization; ActionPhases = @{ GrantManagerHomeAccess = 'Immediate' }
        }
        $plan = New-EobOffboardingPlan -Request $request -Config $config -Now $script:BeforeExit
        $step = $plan.Steps | Where-Object Handler -EQ 'Grant-EobHomeDirectoryAccess'
        $step.Parameters.SamAccountName | Should -Be 'mmuster'
        $step.Parameters.AuthorizedAccount | Should -Be $Authorization
        $step.Parameters.Account | Should -Be 'chefin'
        $null = Save-EobOffboardingQueueEntry -Plan $plan -Confirm:$false
        $queued = @(Get-EobOffboardingQueue -Config $config -Now $script:BeforeExit)[0]
        $queued.Entry.Request.AuthorizedHomeAccessAccount | Should -Be $Authorization
        $restored = New-EobOffboardingPlanFromQueue -QueueEntry $queued -Config $config -Now $script:BeforeExit
        ($restored.Steps | Where-Object Handler -EQ 'Grant-EobHomeDirectoryAccess').Parameters.AuthorizedAccount | Should -Be $Authorization
    }

    It 'plant keine Empfängerfreigabe für eine andere Domäne oder einen UPN' -ForEach @(
        @{ Authorization = 'OTHER\chefin' }, @{ Authorization = 'chefin@example.com' }
    ) {
        Set-DirectoryMock -User (New-TestUser -HomeDirectory $script:AccessHome)
        $config = New-TestConfig -Extra "[FileServer]`nAllowedRoots=$($script:AccessRoot)"
        $request = New-TestRequest -Config $config -Data @{
            AuthorizedHomeAccessAccount = $Authorization; ActionPhases = @{ GrantManagerHomeAccess = 'Immediate' }
        }
        $plan = New-EobOffboardingPlan -Request $request -Config $config -Now $script:BeforeExit
        @($plan.Steps | Where-Object Handler -EQ 'Grant-EobHomeDirectoryAccess').Count | Should -Be 0
        @($plan.Findings.Code) | Should -Contain 'OFF_HOME_ACCESS_AUTH_REQUIRED'
    }

    It 'verweigert die Freigabe bei geändertem AD-Managerkonto' {
        Set-DirectoryMock -User (New-TestUser -HomeDirectory $script:AccessHome)
        Mock -ModuleName $script:Off Resolve-EobAdUser {
            if ($Identity -like 'CN=Chefin*') {
                [pscustomobject]@{ SamAccountName = 'angreifer'; DisplayName = 'Andere Person'; Mail = 'angreifer@example.com'; DistinguishedName = $Identity }
            }
            else { $script:TestUser }
        }
        $config = New-TestConfig -Extra "[FileServer]`nAllowedRoots=$($script:AccessRoot)"
        $request = New-TestRequest -Config $config -Data @{
            AuthorizedHomeAccessAccount = 'chefin'; ActionPhases = @{ GrantManagerHomeAccess = 'Immediate' }
        }
        $plan = New-EobOffboardingPlan -Request $request -Config $config -Now $script:BeforeExit
        @($plan.Steps | Where-Object Handler -EQ 'Grant-EobHomeDirectoryAccess').Count | Should -Be 0
        @($plan.Findings.Code) | Should -Contain 'OFF_HOME_ACCESS_AUTH_REQUIRED'
    }

    It 'plant auch mit Empfängerfreigabe keinen Zugriff auf fremde Home-Verzeichnisse' {
        Set-DirectoryMock -User (New-TestUser -HomeDirectory (Join-Path $script:AccessRoot 'anderer'))
        $config = New-TestConfig -Extra "[FileServer]`nAllowedRoots=$($script:AccessRoot)"
        $request = New-TestRequest -Config $config -Data @{
            AuthorizedHomeAccessAccount = 'chefin'; ActionPhases = @{ GrantManagerHomeAccess = 'Immediate' }
        }
        $plan = New-EobOffboardingPlan -Request $request -Config $config -Now $script:BeforeExit
        @($plan.Steps | Where-Object Handler -EQ 'Grant-EobHomeDirectoryAccess').Count | Should -Be 0
        @($plan.Findings.Code) | Should -Contain 'OFF_HOME_NOT_ALLOWED'
    }
}

Describe 'Massen-Offboarding' {
    BeforeEach {
        Set-DirectoryMock
        $script:Config = New-TestConfig
    }

    It 'liest die CSV und erkennt Duplikate' {
        $csv = Join-Path $TestDrive 'off.csv'
        Set-Content -LiteralPath $csv -Encoding utf8 -Value "SamAccountName;Austrittsdatum;Ticket;Grund`nmmuster;31.03.2027;CHG-1;Test`nmmuster;31.03.2027;CHG-2;Test"
        $import = Import-EobOffboardingCsv -Path $csv -Config $script:Config
        @($import.Findings | Where-Object Severity -EQ 'Error').Count | Should -Be 0
        $batch = New-EobOffboardingBatch -Import $import -Config $script:Config -Now $script:BeforeExit
        $batch.Items[0].State | Should -BeIn @('Ready', 'Warning')
        $batch.Items[1].State | Should -Be 'Error'
        @($batch.Items[1].Plan.Findings.Code) | Should -Contain 'CSV_DUPLICATE_USER'
    }

    It 'meldet fehlende Pflichtspalten' {
        $csv = Join-Path $TestDrive 'off2.csv'
        Set-Content -LiteralPath $csv -Encoding utf8 -Value "Name;Ticket`nMax;1"
        $codes = @((Import-EobOffboardingCsv -Path $csv -Config $script:Config).Findings.Code)
        $codes | Should -Contain 'CSV_MISSING_COLUMN'
        $codes | Should -Contain 'CSV_UNKNOWN_COLUMN'
    }

    It 'führt den Stapel aus und exportiert das Ergebnis mit Formelschutz' {
        $csv = Join-Path $TestDrive 'off3.csv'
        Set-Content -LiteralPath $csv -Encoding utf8 -Value "SamAccountName;ExitDate;Ticket;Reason`nmmuster;2027-03-31;=CHG-1;Test"
        $batch = New-EobOffboardingBatch -Import (Import-EobOffboardingCsv -Path $csv -Config $script:Config) -Config $script:Config -Now $script:BeforeExit
        $batch.ExecutableCount | Should -Be 1
        $null = Invoke-EobOffboardingBatch -Batch $batch -Now $script:BeforeExit -Confirm:$false
        $batch.Items[0].Outcome | Should -Be 'Succeeded'
        Should -Invoke -ModuleName $script:Ad Set-ADAccountExpiration -Times 1
        $out = Export-EobOffboardingBatchResult -Batch $batch -Path (Join-Path $TestDrive 'ergebnis.csv') -Confirm:$false
        (Import-Csv -LiteralPath $out -Delimiter ';')[0].Ticket | Should -BeExactly '''=CHG-1'
    }
}
