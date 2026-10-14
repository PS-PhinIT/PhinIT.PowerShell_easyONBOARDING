#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.3.0' }
<#
    Tests des Installers (easyONB.Setup, Install-easyONBOARDING.ps1).
    - Plattformunabhängig: Felddefinitionen gegen das Schema, INI-Erzeugung, Prüfung der Eingaben,
      Vorbelegung aus dem Active Directory (Stubs/Mocks).
    - Nur Windows mit STA-Thread: Laden des Installer-Fensters über WPF ohne Anzeige.
#>

BeforeDiscovery {
    $script:CanLoadWpf = $IsWindows -and [System.Threading.Thread]::CurrentThread.GetApartmentState() -eq [System.Threading.ApartmentState]::STA
}

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath '../TestHelpers.ps1')
    Import-EobTestModule
    $script:Setup = 'easyONB.Setup'
    $null = Initialize-EobLogging -Directory (Join-Path $TestDrive 'logs')

    function script:Get-ValidSetupValue {
        $values = Get-EobSetupDefaultValue
        $values['CompanyName'] = 'Example GmbH'
        $values['UpnSuffix'] = 'example.com'
        $values['MailDomain'] = 'example.com'
        $values['DefaultOU'] = 'OU=Mitarbeiter,DC=example,DC=local'
        $values['HelpdeskMail'] = 'helpdesk@example.com'
        $values['Website'] = 'https://www.example.com/'
        return $values
    }
}

Describe 'Felder des Installers' {
    It 'verweist nur auf Schlüssel des Konfigurationsschemas' {
        $schema = Get-EobConfigSchema
        foreach ($field in Get-EobSetupField) {
            $section = Get-EobSchemaSectionDefinition -Schema $schema -Name $field.Section
            $section | Should -Not -BeNullOrEmpty -Because "[$($field.Section)]"
            Get-EobSchemaKeyDefinition -SectionDefinition $section -Key $field.Key | Should -Not -BeNullOrEmpty -Because "[$($field.Section)] $($field.Key)"
        }
    }

    It 'hat eindeutige Namen und zu jedem Feld einen kurzen Hinweistext' {
        $fields = @(Get-EobSetupField)
        @($fields | Group-Object -Property Name | Where-Object Count -GT 1) | Should -BeNullOrEmpty
        foreach ($field in $fields) {
            $field.Hint | Should -Not -BeNullOrEmpty
            $field.Hint.Length | Should -BeLessOrEqual 160
            $field.Page | Should -BeIn @(Get-EobSetupPage).Id
        }
    }
}

Describe 'INI-Erzeugung' {
    It 'ersetzt Werte, ergänzt fehlende Schlüssel und Abschnitte und erhält Kommentare' {
        $template = "; Kopf`r`n[A]`r`n; Kommentar`r`nX=1`r`nY=2`r`n`r`n[B]`r`nZ=alt`r`nW=weg`r`n"
        $values = [ordered]@{ A = [ordered]@{ X = 'neu'; N = 'zusatz' }; B = [ordered]@{ Z = 'z' }; C = [ordered]@{ K = 'v' } }
        $text = ConvertTo-EobSetupIniText -TemplateText $template -Values $values -RemoveSection @('B')
        $text | Should -Be "; Kopf`r`n[A]`r`n; Kommentar`r`nX=neu`r`nY=2`r`nN=zusatz`r`n`r`n[B]`r`nZ=z`r`n`r`n[C]`r`nK=v`r`n"
    }

    It 'lehnt mehrzeilige Werte ab' {
        { ConvertTo-EobSetupIniText -TemplateText "[A]`nX=1" -Values ([ordered]@{ A = [ordered]@{ X = "a`nb" } }) } | Should -Throw '*Zeilenumbruch*'
    }

    It 'meldet Pflichtfelder, ungültige Formate und fehlende Exchange-Angaben' {
        $empty = @(Test-EobSetupFieldValue -FieldValues (Get-EobSetupDefaultValue))
        @($empty | Where-Object Code -EQ 'SETUP_REQUIRED').Field | Should -Be @('CompanyName', 'UpnSuffix', 'MailDomain', 'DefaultOU')
        $values = Get-ValidSetupValue
        $values['AccentColor'] = 'blau'
        $values['ExchangeMode'] = 'Hybrid'
        $codes = @(Test-EobSetupFieldValue -FieldValues $values | ForEach-Object Code)
        $codes | Should -Contain 'SETUP_INVALID'
        $codes | Should -Contain 'SETUP_EXCHANGE_URI'
        @(Test-EobSetupFieldValue -FieldValues (Get-ValidSetupValue) | Where-Object Severity -EQ 'Error') | Should -BeNullOrEmpty
    }

    It 'erstellt eine ladbare Konfiguration ohne Fehler und ohne Beispieldaten' {
        $path = Join-Path $TestDrive 'Config/easyONB.ini'
        $result = New-EobSetupConfiguration -FieldValues (Get-ValidSetupValue) -Path $path -RemoveSamples -Confirm:$false
        @($result.Config.Findings | Where-Object Severity -EQ 'Error') | Should -BeNullOrEmpty
        $text = Get-Content -LiteralPath $path -Raw
        $text | Should -Match '(?m)^CompanyNameFirma=Example GmbH\r?$'
        $text | Should -Match '(?m)^CompanyMailDomain=@example.com\r?$'
        $text | Should -Match '(?m)^CompanyDomain=www.example.com\r?$'
        $text | Should -Match '(?m)^LogoURL=https://www.example.com\r?$'
        $text | Should -Match '(?m)^AccountDisabled=True\r?$'
        $text | Should -Match '(?m)^SimulationByDefault=1\r?$'
        $text | Should -Match 'Bitte wenden Sie sich an helpdesk@example.com'
        $text | Should -Match '; Neue Vorgänge starten im Simulationsmodus'
        $text | Should -Not -Match 'GRP-Vertrieb|EXAMPLE-CORP|(?m)^Domain2='
        [System.IO.File]::ReadAllBytes($path)[0] | Should -Be 0xEF
    }

    It 'ersetzt eine vorhandene Datei nur mit -Force und sichert sie vorher' {
        $path = Join-Path $TestDrive 'force.ini'
        $null = New-EobSetupConfiguration -FieldValues (Get-ValidSetupValue) -Path $path -Confirm:$false
        { New-EobSetupConfiguration -FieldValues (Get-ValidSetupValue) -Path $path -Confirm:$false } | Should -Throw '*existiert bereits*'
        $result = New-EobSetupConfiguration -FieldValues (Get-ValidSetupValue) -Path $path -Force -Confirm:$false
        Test-Path -LiteralPath $result.Backup | Should -BeTrue
        $null = New-EobSetupConfiguration -FieldValues (Get-ValidSetupValue) -Path (Join-Path $TestDrive 'whatif.ini') -WhatIf
        Test-Path -LiteralPath (Join-Path $TestDrive 'whatif.ini') | Should -BeFalse
    }

    It 'verweigert das Schreiben bei ungültigen Eingaben' {
        { New-EobSetupConfiguration -FieldValues (Get-EobSetupDefaultValue) -Path (Join-Path $TestDrive 'leer.ini') -Confirm:$false } | Should -Throw '*Pflichtfeld*'
    }
}

Describe 'Vorbelegung auf einem Domänencontroller' {
    It 'liest Server und Mandant aus der Beschreibung des Entra-Connect-Kontos' {
        $info = ConvertFrom-EobEntraConnectAccountDescription -Description 'Account created by Microsoft Azure Active Directory Connect with installation identifier 3c4f running on computer SYNC01 configured to synchronize to tenant example.onmicrosoft.com. This account must have permissions.'
        $info.Computer | Should -Be 'SYNC01'
        $info.Tenant | Should -Be 'example.onmicrosoft.com'
        ConvertFrom-EobEntraConnectAccountDescription -Description 'Beliebiger Text' | Should -BeNullOrEmpty
    }

    It 'ermittelt Exchange-Servernamen und passende OUs' {
        Get-EobSetupExchangeServerName -NetworkAddress @('ncacn_vns_spp:EX01', 'ncacn_ip_tcp:ex01.example.local') | Should -Be 'ex01.example.local'
        Select-EobSetupOu -DistinguishedName @('OU=Gruppen,DC=example,DC=local', 'OU=Mitarbeiter,OU=Firma,DC=example,DC=local') -Pattern '^(Mitarbeiter|Users)$' -Fallback 'CN=Users' |
            Should -Be 'OU=Mitarbeiter,OU=Firma,DC=example,DC=local'
    }

    It 'belegt Domäne, OUs, Entra Connect und Exchange aus dem AD vor' {
        Mock -ModuleName $script:Setup Import-Module { }
        Mock -ModuleName $script:Setup Get-ADDomain { [pscustomobject]@{ DNSRoot = 'example.local'; DistinguishedName = 'DC=example,DC=local'; UsersContainer = 'CN=Users,DC=example,DC=local'; PDCEmulator = 'dc01.example.local' } }
        Mock -ModuleName $script:Setup Get-ADForest { [pscustomobject]@{ UPNSuffixes = @('example.com') } }
        Mock -ModuleName $script:Setup Get-ADDomainController { [pscustomobject]@{ HostName = 'dc01.example.local' } }
        Mock -ModuleName $script:Setup Get-ADOrganizationalUnit {
            [pscustomobject]@{ DistinguishedName = 'OU=Mitarbeiter,DC=example,DC=local'; CanonicalName = 'example.local/Mitarbeiter' }
            [pscustomobject]@{ DistinguishedName = 'OU=Ausgeschieden,DC=example,DC=local'; CanonicalName = 'example.local/Ausgeschieden' }
        }
        Mock -ModuleName $script:Setup Get-ADUser { [pscustomobject]@{ Description = 'Account created by Microsoft Azure Active Directory Connect with installation identifier x running on computer SYNC01 configured to synchronize to tenant example.onmicrosoft.com. More.' } }
        Mock -ModuleName $script:Setup Get-ADRootDSE { [pscustomobject]@{ configurationNamingContext = 'CN=Configuration,DC=example,DC=local' } }
        Mock -ModuleName $script:Setup Get-ADObject { [pscustomobject]@{ networkAddress = @('ncacn_ip_tcp:ex01.example.local') } }

        $defaults = Get-EobSetupDirectoryDefault
        $defaults.Values['UpnSuffix'] | Should -Be 'example.com'
        $defaults.Values['MailDomain'] | Should -Be '@example.com'
        $defaults.Values['DefaultOU'] | Should -Be 'OU=Mitarbeiter,DC=example,DC=local'
        $defaults.Values['DisabledUsersOU'] | Should -Be 'OU=Ausgeschieden,DC=example,DC=local'
        $defaults.Values['SyncServer'] | Should -Be 'SYNC01.example.local'
        $defaults.Values['TenantId'] | Should -Be 'example.onmicrosoft.com'
        $defaults.Values['ExchangeMode'] | Should -Be 'Hybrid'
        $defaults.Values['ExchangeUri'] | Should -Be 'http://ex01.example.local/PowerShell/'
        $defaults.Values['RoutingDomain'] | Should -Be 'example.mail.onmicrosoft.com'
        @($defaults.Options['UpnSuffix']) | Should -Be @('example.local', 'example.com')

        $values = Get-EobSetupDefaultValue
        foreach ($key in $defaults.Values.Keys) { $values[$key] = $defaults.Values[$key] }
        $values['CompanyName'] = 'Example GmbH'
        @(Test-EobSetupFieldValue -FieldValues $values | Where-Object Severity -EQ 'Error') | Should -BeNullOrEmpty
    }

    It 'erkennt außerhalb von Windows keinen Domänencontroller' -Skip:$IsWindows {
        (Get-EobSetupEnvironment).IsDomainController | Should -BeFalse
    }
}

Describe 'Installer-Fenster (Windows)' -Tag 'Windows' {
    It 'erzeugt alle Felder mit Hinweistext, prüft Eingaben und erstellt die Datei' -Skip:(-not $script:CanLoadWpf) {
        $target = Join-Path $TestDrive 'gui/easyONB.ini'
        InModuleScope 'easyONB.Setup' -Parameters @{ Target = $target } {
            param($Target)
            Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
            $script:SetupUi = @{ Application = $null; Window = $null; C = @{}; Fields = @{}; Environment = $null; Headless = $true; DialogLog = [System.Collections.Generic.List[string]]::new() }
            $client = [pscustomobject]@{ IsWindows = $true; IsDomainController = $false; PartOfDomain = $true; Domain = 'example.local'; ComputerName = 'PC01'; AdModuleAvailable = $false; Detail = 'Domänenmitglied PC01' }
            Initialize-EobSetupWindow -ConfigPath $Target -Environment $client

            $script:SetupUi.Fields.Count | Should -Be @(Get-EobSetupField).Count
            $script:SetupUi.C.SetupTabs.Items.Count | Should -Be (@(Get-EobSetupPage).Count + 1)
            $script:SetupUi.C.SetupReloadButton.IsEnabled | Should -BeFalse
            $script:SetupUi.C.SetupEnvironmentText.Text | Should -Match 'manuell'
            foreach ($control in $script:SetupUi.Fields.Values) {
                [string]$control.ToolTip | Should -Not -BeNullOrEmpty
                [System.Windows.Controls.ToolTipService]::GetInitialShowDelay($control) | Should -BeLessOrEqual 300
            }
            [System.Windows.Controls.ToolTipService]::GetInitialShowDelay($script:SetupUi.Window) | Should -Be 250
            $script:SetupUi.Fields['SimulationByDefault'].IsChecked | Should -BeTrue

            (Invoke-EobSetupCheck) | Should -BeFalse
            $script:SetupUi.C.SetupFindingsList.Items.Count | Should -BeGreaterThan 0

            Set-EobSetupFieldValue -Name 'CompanyName' -Value 'Example GmbH'
            Set-EobSetupFieldValue -Name 'UpnSuffix' -Value 'example.com'
            Set-EobSetupFieldValue -Name 'MailDomain' -Value '@example.com'
            Set-EobSetupFieldValue -Name 'DefaultOU' -Value 'OU=Mitarbeiter,DC=example,DC=local'
            Set-EobSetupFieldValue -Name 'ExchangeMode' -Value 'Online'
            (Get-EobSetupFormValue)['ExchangeMode'] | Should -Be 'Online'
            Invoke-EobSetupCreate
            Test-Path -LiteralPath $Target | Should -BeTrue
            $script:SetupUi.C.SetupResultText.Text | Should -Match 'Konfiguration erstellt'
            @($script:SetupUi.DialogLog) | Should -BeNullOrEmpty
            $script:SetupUi.Window.Close()
        }
    }
}
