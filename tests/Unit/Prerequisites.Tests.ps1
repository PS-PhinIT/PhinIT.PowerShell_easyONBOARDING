#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.3.0' }
<#
    Tests des Voraussetzungs-Skripts Install-PS7_PDF.ps1.
    - Plattformunabhängig: Prüflogik, Simulation (-WhatIf), Schutz vor ungewollten Änderungen,
      Kopieren ohne Überschreiben der Konfiguration (Installationsschritte gemockt).
    - Nur Windows: Signaturprüfung; mit STA-Thread zusätzlich das Fenster über WPF ohne Anzeige.
#>

BeforeDiscovery {
    $script:CanLoadWpf = $IsWindows -and [System.Threading.Thread]::CurrentThread.GetApartmentState() -eq [System.Threading.ApartmentState]::STA
}

BeforeAll {
    $script:PrereqScript = Join-Path -Path $PSScriptRoot -ChildPath '../../Install-PS7_PDF.ps1'
    . $script:PrereqScript

    function script:Set-EobPrereqTestEnvironment {
        param([object]$PowerShell = [pscustomobject]@{ Path = 'C:\Program Files\PowerShell\7\pwsh.exe'; Version = [version]'7.4.6' },
            [string]$Policy = 'RemoteSigned', [bool]$Managed = $false)
        $script:TestPowerShell = $PowerShell
        $script:TestPolicy = [pscustomobject]@{ Effective = $Policy; Managed = $Managed }
        Mock Test-EobPrereqWinget { $true }
        Mock Get-EobPrereqWindowsKind { 'Client' }
        Mock Get-EobPrereqPowerShell7 { $script:TestPowerShell }
        Mock Get-EobPrereqPdfEngine { [pscustomobject]@{ Edge = 'C:\Edge\msedge.exe'; Wkhtmltopdf = '' } }
        Mock Get-EobPrereqExecutionPolicy { $script:TestPolicy }
    }
}

Describe 'Skript Install-PS7_PDF.ps1' {
    It 'bleibt mit Windows PowerShell 5.1 kompatibel (keine Operatoren ab PowerShell 7)' {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $script:PrereqScript).Path, [ref]$tokens, [ref]$errors)
        $errors | Should -BeNullOrEmpty
        $ast.ParamBlock | Should -Not -BeNullOrEmpty
        @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.TernaryExpressionAst] -or $node -is [System.Management.Automation.Language.PipelineChainAst] }, $true)) | Should -HaveCount 0
        @($tokens | Where-Object { $_.Kind -in @('QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'QuestionLBracket') }) | Should -HaveCount 0
        @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.VariableExpressionAst] -and $node.VariablePath.UserPath -eq 'IsWindows' }, $true)) | Should -HaveCount 0
    }

    It 'ändert die Ausführungsrichtlinie nur für den aktuellen Benutzer und nur an einer Stelle' {
        $content = Get-Content -LiteralPath $script:PrereqScript -Raw
        @([regex]::Matches($content, 'Set-ExecutionPolicy -')) | Should -HaveCount 1
        $content | Should -Match 'Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser'
    }

    It 'lädt beim Dot-Sourcing nur die Funktionen' {
        Get-Command -Name 'Get-EobPrerequisiteStatus' -CommandType Function | Should -Not -BeNullOrEmpty
        $script:PrereqUi | Should -BeNullOrEmpty
    }
}

Describe 'Auswahl der Voraussetzungen' {
    BeforeEach {
        $timer = [pscustomobject]@{ Started = $false }
        $timer | Add-Member -MemberType ScriptMethod -Name Start -Value { $this.Started = $true }
        $script:PrereqUi = @{
            Running = $false; Headless = $false; Queue = $null; Timer = $timer
            Items = @([pscustomobject]@{ Id = 'ExecutionPolicy' })
            Checks = @{ ExecutionPolicy = [pscustomobject]@{ IsChecked = $true } }
            C = @{
                PrereqCopyCheck = [pscustomobject]@{ IsChecked = $false }
                PrereqInstallButton = [pscustomobject]@{ IsEnabled = $true }
                PrereqRefreshButton = [pscustomobject]@{ IsEnabled = $true }
                PrereqProgressText = [pscustomobject]@{ Text = '' }
            }
        }
        Mock Confirm-EobPrereqPolicyChange { $false }
        Mock Add-EobPrereqLog {}
    }

    AfterEach { $script:PrereqUi = $null }

    It 'startet nach abgelehnter Richtlinienänderung keine leere Warteschlange' {
        { Start-EobPrereqSelection } | Should -Not -Throw
        $script:PrereqUi.Running | Should -BeFalse
        $script:PrereqUi.Timer.Started | Should -BeFalse
        $script:PrereqUi.C.PrereqInstallButton.IsEnabled | Should -BeTrue
        $script:PrereqUi.C.PrereqRefreshButton.IsEnabled | Should -BeTrue
        Should -Invoke Add-EobPrereqLog -Times 1 -Exactly -ParameterFilter { $Text -eq 'Nichts ausgewählt.' }
    }

    It 'behält andere Aktionen nach abgelehnter Richtlinienänderung bei' {
        $script:PrereqUi.C.PrereqCopyCheck.IsChecked = $true
        Start-EobPrereqSelection
        $script:PrereqUi.Queue.ToArray() | Should -Be @('Copy')
        $script:PrereqUi.Running | Should -BeTrue
        $script:PrereqUi.Timer.Started | Should -BeTrue
        $script:PrereqUi.C.PrereqProgressText.Text | Should -Match 'Copy'
    }
}

Describe 'Prüfung der Voraussetzungen' {
    It 'meldet ein fehlendes PowerShell 7 als Pflicht und installierbar' {
        Set-EobPrereqTestEnvironment -PowerShell $null
        $item = Get-EobPrerequisiteStatus | Where-Object Id -EQ 'PowerShell7'
        $item.State | Should -Be 'Missing'
        $item.Required | Should -BeTrue
        $item.Installable | Should -BeTrue
    }

    It 'meldet ein zu altes PowerShell 7 als fehlend' {
        Set-EobPrereqTestEnvironment -PowerShell ([pscustomobject]@{ Path = 'pwsh.exe'; Version = [version]'7.1.0' })
        $item = Get-EobPrerequisiteStatus | Where-Object Id -EQ 'PowerShell7'
        $item.State | Should -Be 'Missing'
        $item.Detail | Should -Match '7\.1\.0'
    }

    It 'meldet ein aktuelles PowerShell 7 als in Ordnung' {
        Set-EobPrereqTestEnvironment
        $item = Get-EobPrerequisiteStatus | Where-Object Id -EQ 'PowerShell7'
        $item.State | Should -Be 'Ok'
        $item.Installable | Should -BeFalse
    }

    It 'liefert alle Punkte mit Hinweistext' {
        Set-EobPrereqTestEnvironment
        $items = @(Get-EobPrerequisiteStatus)
        $items.Id | Should -Be @('PowerShell7', 'ActiveDirectory', 'PdfEngine', 'Wkhtmltopdf', 'ExecutionPolicy')
        foreach ($item in $items) { $item.Hint | Should -Not -BeNullOrEmpty -Because $item.Id }
    }

    It 'bietet eine restriktive Richtlinie nur optional an' {
        Set-EobPrereqTestEnvironment -Policy 'Restricted'
        $item = Get-EobPrerequisiteStatus | Where-Object Id -EQ 'ExecutionPolicy'
        $item.State | Should -Be 'Warning'
        $item.Required | Should -BeFalse
        $item.Installable | Should -BeTrue
    }

    It 'bietet eine per Gruppenrichtlinie festgelegte Richtlinie nicht zur Änderung an' {
        Set-EobPrereqTestEnvironment -Policy 'Restricted' -Managed $true
        $item = Get-EobPrerequisiteStatus | Where-Object Id -EQ 'ExecutionPolicy'
        $item.Installable | Should -BeFalse
        $item.Detail | Should -Match 'Gruppenrichtlinie'
    }

    It 'bietet wkhtmltopdf ohne winget nicht zur Installation an' {
        Set-EobPrereqTestEnvironment
        Mock Test-EobPrereqWinget { $false }
        $item = Get-EobPrerequisiteStatus | Where-Object Id -EQ 'Wkhtmltopdf'
        $item.Installable | Should -BeFalse
        $item.Required | Should -BeFalse
    }
}

Describe 'Installation' {
    BeforeEach {
        Mock Invoke-EobPrereqProcess { 0 }
        Mock Invoke-WebRequest { }
        Mock Test-EobPrereqAdministrator { $true }
        Mock Test-EobPrereqWinget { $false }
    }

    It 'simuliert mit -WhatIf, ohne etwas zu starten' {
        Install-EobPowerShell7 -MsiUrl 'https://example.com/pwsh.msi' -WhatIf | Should -Match 'Simulation'
        Install-EobActiveDirectoryModule -WhatIf | Should -Match 'Simulation'
        Install-EobWkhtmltopdf -WhatIf | Should -Match 'Simulation'
        Should -Invoke Invoke-EobPrereqProcess -Times 0 -Exactly
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'verlangt Administratorrechte' {
        Mock Test-EobPrereqAdministrator { $false }
        { Install-EobPowerShell7 -MsiUrl 'https://example.com/pwsh.msi' -Confirm:$false } | Should -Throw '*Administratorrechte*'
        { Install-EobActiveDirectoryModule -Confirm:$false } | Should -Throw '*Administratorrechte*'
        Should -Invoke Invoke-EobPrereqProcess -Times 0 -Exactly
    }

    It 'installiert PowerShell 7 bevorzugt per winget' {
        Mock Test-EobPrereqWinget { $true }
        Install-EobPowerShell7 -MsiUrl 'https://example.com/pwsh.msi' -Confirm:$false | Should -Match 'winget'
        Should -Invoke Invoke-EobPrereqProcess -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'winget' -and $ArgumentList -contains 'Microsoft.PowerShell' -and $ArgumentList -contains '--exact' }
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'lädt das MSI nur über https' {
        { Install-EobPowerShell7 -MsiUrl 'http://example.com/pwsh.msi' -Confirm:$false } | Should -Throw '*https*'
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'führt ein nicht von Microsoft signiertes MSI nicht aus' {
        Mock Test-EobPrereqMicrosoftSignature { $false }
        { Install-EobPowerShell7 -MsiUrl 'https://example.com/pwsh.msi' -Confirm:$false } | Should -Throw '*signiert*'
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly
        Should -Invoke Invoke-EobPrereqProcess -Times 0 -Exactly
    }

    It 'installiert ein signiertes MSI still und meldet einen nötigen Neustart' {
        Mock Test-EobPrereqMicrosoftSignature { $true }
        Mock Invoke-EobPrereqProcess { 3010 }
        Install-EobPowerShell7 -MsiUrl 'https://example.com/pwsh.msi' -Confirm:$false | Should -Match 'Neustart'
        Should -Invoke Invoke-EobPrereqProcess -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'msiexec.exe' -and $ArgumentList -contains '/qn' }
    }

    It 'meldet einen Fehler von msiexec' {
        Mock Test-EobPrereqMicrosoftSignature { $true }
        Mock Invoke-EobPrereqProcess { 1603 }
        { Install-EobPowerShell7 -MsiUrl 'https://example.com/pwsh.msi' -Confirm:$false } | Should -Throw '*1603*'
    }

    It 'installiert wkhtmltopdf nur per winget' {
        { Install-EobWkhtmltopdf -Confirm:$false } | Should -Throw '*winget*'
        Mock Test-EobPrereqWinget { $true }
        Install-EobWkhtmltopdf -Confirm:$false | Should -Match 'installiert'
        Should -Invoke Invoke-EobPrereqProcess -Times 1 -Exactly -ParameterFilter { $ArgumentList -contains 'wkhtmltopdf.wkhtmltox' }
    }
}

Describe 'Ausführungsrichtlinie' {
    BeforeAll {
        Mock Set-ExecutionPolicy { }
    }

    It 'ändert ohne Bestätigung nichts (-WhatIf)' {
        Mock Get-EobPrereqExecutionPolicy { [pscustomobject]@{ Effective = 'Restricted'; Managed = $false } }
        Set-EobPrereqExecutionPolicy -WhatIf | Should -Match 'Simulation'
        Should -Invoke Set-ExecutionPolicy -Times 0 -Exactly
    }

    It 'setzt RemoteSigned nur für den aktuellen Benutzer' {
        Mock Get-EobPrereqExecutionPolicy { [pscustomobject]@{ Effective = 'Restricted'; Managed = $false } }
        Set-EobPrereqExecutionPolicy -Confirm:$false | Should -Match 'RemoteSigned'
        Should -Invoke Set-ExecutionPolicy -Times 1 -Exactly -ParameterFilter { $Scope -eq 'CurrentUser' -and $ExecutionPolicy -eq 'RemoteSigned' }
    }

    It 'lehnt eine per Gruppenrichtlinie festgelegte Richtlinie ab' {
        Mock Get-EobPrereqExecutionPolicy { [pscustomobject]@{ Effective = 'AllSigned'; Managed = $true } }
        { Set-EobPrereqExecutionPolicy -Confirm:$false } | Should -Throw '*Gruppenrichtlinie*'
        Should -Invoke Set-ExecutionPolicy -Times 0 -Exactly
    }
}

Describe 'Signaturprüfung' -Skip:(-not $IsWindows) {
    It 'akzeptiert nur gültige Signaturen von Microsoft' {
        $file = Join-Path $TestDrive 'paket.msi'
        Set-Content -LiteralPath $file -Value 'x'
        Mock Get-AuthenticodeSignature { [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US' } } }
        Test-EobPrereqMicrosoftSignature -Path $file | Should -BeTrue
        Mock Get-AuthenticodeSignature { [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Microsoft Corporation, O=Fake Microsoft Corporation Ltd, C=US' } } }
        Test-EobPrereqMicrosoftSignature -Path $file | Should -BeFalse
        Mock Get-AuthenticodeSignature { [pscustomobject]@{ Status = 'HashMismatch'; SignerCertificate = [pscustomobject]@{ Subject = 'O=Microsoft Corporation' } } }
        Test-EobPrereqMicrosoftSignature -Path $file | Should -BeFalse
        Mock Get-AuthenticodeSignature { [pscustomobject]@{ Status = 'NotSigned'; SignerCertificate = $null } }
        Test-EobPrereqMicrosoftSignature -Path $file | Should -BeFalse
    }
}

Describe 'Anwendung kopieren' {
    BeforeEach {
        $script:Repo = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:App = Join-Path $script:Repo 'V3.0.0'
        foreach ($relative in @('Start-easyONBOARDING.ps1', 'Config/easyONB.ini', 'Config/companies/firma.ini', 'Config/Schema.psd1', 'Logs/alt.log', 'Data/queue.json', 'Reports/bericht.html')) {
            $path = Join-Path $script:App $relative
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force
            Set-Content -LiteralPath $path -Value "neu:$relative"
        }
        Set-Content -LiteralPath (Join-Path $script:Repo 'VERSION') -Value '3.0.0'
        $script:Target = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    }

    It 'kopiert ohne Laufzeitdaten und übernimmt VERSION' {
        $result = Copy-EobApplication -Destination $script:Target -Source $script:App -Confirm:$false
        $result | Should -Match 'kopiert'
        Join-Path $script:Target 'Start-easyONBOARDING.ps1' | Should -Exist
        Join-Path $script:Target 'Config/Schema.psd1' | Should -Exist
        Join-Path $script:Target 'Config/easyONB.ini' | Should -Exist
        Join-Path $script:Target 'VERSION' | Should -Exist
        foreach ($folder in @('Logs', 'Data', 'Reports')) { Join-Path $script:Target $folder | Should -Not -Exist }
    }

    It 'überschreibt eine vorhandene Konfiguration nicht' {
        foreach ($relative in @('Config/easyONB.ini', 'Config/companies/firma.ini', 'Config/Schema.psd1')) {
            $path = Join-Path $script:Target $relative
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force
            Set-Content -LiteralPath $path -Value 'eigene'
        }
        Copy-EobApplication -Destination $script:Target -Source $script:App -Confirm:$false | Should -Match '2 vorhandene'
        (Get-Content -LiteralPath (Join-Path $script:Target 'Config/easyONB.ini') -Raw).Trim() | Should -Be 'eigene'
        (Get-Content -LiteralPath (Join-Path $script:Target 'Config/companies/firma.ini') -Raw).Trim() | Should -Be 'eigene'
        (Get-Content -LiteralPath (Join-Path $script:Target 'Config/Schema.psd1') -Raw).Trim() | Should -Be 'neu:Config/Schema.psd1'
    }

    It 'lehnt den Anwendungsordner und Unterordner davon als Ziel ab' {
        { Copy-EobApplication -Destination $script:App -Source $script:App -Confirm:$false } | Should -Throw '*Zielordner*'
        { Copy-EobApplication -Destination (Join-Path $script:App 'Kopie') -Source $script:App -Confirm:$false } | Should -Throw '*Zielordner*'
    }

    It 'simuliert mit -WhatIf, ohne Dateien anzulegen' {
        Copy-EobApplication -Destination $script:Target -Source $script:App -WhatIf | Should -Match 'Simulation'
        $script:Target | Should -Not -Exist
    }

    It 'führt Aktionen über ihre Id aus' {
        Invoke-EobPrereqAction -Id 'Copy' -Destination $script:Target -WhatIf | Should -Match 'Simulation'
        { Invoke-EobPrereqAction -Id 'Unbekannt' } | Should -Throw
    }
}

Describe 'Fenster der Voraussetzungen' -Skip:(-not $script:CanLoadWpf) {
    It 'zeigt alle Punkte mit Hinweistext und wählt nur Pflichtpunkte vor' {
        Set-EobPrereqTestEnvironment -PowerShell $null -Policy 'Restricted'
        Mock Test-EobPrereqAdministrator { $true }
        Initialize-EobPrereqWindow -Headless
        try {
            $ui = $script:PrereqUi
            $ui.Items | Should -HaveCount 5
            $ui.C.PrereqItemsGrid.Children.Count | Should -Be 20
            foreach ($child in $ui.C.PrereqItemsGrid.Children) { $child.ToolTip | Should -Not -BeNullOrEmpty }
            $ui.Checks['PowerShell7'].IsChecked | Should -BeTrue
            $ui.Checks['ExecutionPolicy'].IsEnabled | Should -BeTrue
            $ui.Checks['ExecutionPolicy'].IsChecked | Should -BeFalse
            $ui.Checks['PdfEngine'].IsEnabled | Should -BeFalse
            $ui.C.PrereqProgressText.Text | Should -Match 'Pflichtvoraussetzung'
            $ui.C.PrereqTargetText.Text | Should -Not -BeNullOrEmpty
        }
        finally {
            $script:PrereqUi.Timer.Stop()
            $script:PrereqUi.Window.Close()
        }
    }

    It 'sperrt Installationen ohne Administratorrechte' {
        Set-EobPrereqTestEnvironment -PowerShell $null
        Mock Test-EobPrereqAdministrator { $false }
        Initialize-EobPrereqWindow -Headless
        try {
            $script:PrereqUi.Checks['PowerShell7'].IsEnabled | Should -BeFalse
            $script:PrereqUi.C.PrereqAdminText.Text | Should -Match 'Ohne Administratorrechte'
        }
        finally {
            $script:PrereqUi.Timer.Stop()
            $script:PrereqUi.Window.Close()
        }
    }

    It 'arbeitet die Auswahl Schritt für Schritt ab' {
        Set-EobPrereqTestEnvironment -PowerShell $null
        Mock Test-EobPrereqAdministrator { $true }
        Mock Invoke-EobPrereqAction { "erledigt: $Id" }
        Initialize-EobPrereqWindow -Headless
        try {
            $ui = $script:PrereqUi
            Start-EobPrereqSelection
            $ui.Running | Should -BeTrue
            $ui.C.PrereqInstallButton.IsEnabled | Should -BeFalse
            $ui.Timer.Stop()
            while ($ui.Running) { Invoke-EobPrereqQueueStep; $ui.Timer.Stop() }
            $ui.C.PrereqLogText.Text | Should -Match 'erledigt: PowerShell7'
            $ui.C.PrereqInstallButton.IsEnabled | Should -BeTrue
            Should -Invoke Invoke-EobPrereqAction -ParameterFilter { $Id -eq 'ExecutionPolicy' } -Times 0 -Exactly
        }
        finally {
            $script:PrereqUi.Timer.Stop()
            $script:PrereqUi.Window.Close()
        }
    }
}
