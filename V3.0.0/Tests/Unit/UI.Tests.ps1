#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.3.0' }
<#
    Tests der Oberfläche.
    - Plattformunabhängig: XAML-Regeln, Ressourcen, Farbschemata, Abgleich der im Code verwendeten
      Steuerelementnamen und Datenbindungen mit den XAML-Dateien, reine Hilfsfunktionen.
    - Nur Windows mit STA-Thread (z. B. GitHub-Runner windows-latest): echtes Laden aller XAML-Dateien
      über WPF und Initialisieren jeder Ansicht ohne Anzeige des Fensters.
#>

BeforeDiscovery {
    $script:CanLoadWpf = $IsWindows -and [System.Threading.Thread]::CurrentThread.GetApartmentState() -eq [System.Threading.ApartmentState]::STA
    $guiRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'GUI'
    $script:XamlFiles = @(Get-ChildItem -Path $guiRoot -Filter '*.xaml' -Recurse | ForEach-Object {
            @{ Name = $_.FullName.Substring($guiRoot.Length + 1).Replace('\', '/'); Path = $_.FullName }
        })
}

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath '../TestHelpers.ps1')
    Import-EobTestModule -Exclude @()

    $script:GuiRoot = Join-Path (Get-EobTestRepoRoot) 'GUI'
    $script:UiSource = Get-Content -LiteralPath (Join-Path (Get-EobTestRepoRoot) 'Modules/UI/easyONB.UI.psm1') -Raw
    $script:ControlFiles = @(Get-ChildItem -Path $script:GuiRoot -Filter '*.xaml' -Recurse | Where-Object { $_.FullName -notmatch '[\\/]Styles[\\/]' })
    $script:AllNames = @(foreach ($file in $script:ControlFiles) { Get-EobXamlElementName -Xaml (Get-Content -LiteralPath $file.FullName -Raw) })
    $script:ResourceKeys = @(foreach ($file in @('Styles/Theme.Light.xaml', 'Styles/Controls.xaml')) {
            [regex]::Matches((Get-Content -LiteralPath (Join-Path $script:GuiRoot $file) -Raw), 'x:Key="([^"]+)"') | ForEach-Object { $_.Groups[1].Value }
        })
}

Describe 'XAML-Dateien' {
    It '<Name> ist wohlgeformt, ohne x:Class und ohne Ereignisattribute' -ForEach $script:XamlFiles {
        $problems = @(Test-EobXamlContent -Xaml (Get-Content -LiteralPath $Path -Raw))
        $problems | Should -BeNullOrEmpty
    }

    It '<Name> verwendet nur definierte Ressourcen' -ForEach $script:XamlFiles {
        $text = Get-Content -LiteralPath $Path -Raw
        $used = @([regex]::Matches($text, '\{(?:Static|Dynamic)Resource (?!\{)([A-Za-z0-9_.]+)\}') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
        @($used | Where-Object { $_ -notin $script:ResourceKeys }) | Should -BeNullOrEmpty
    }

    It '<Name> enthält keine fest codierten Farben' -ForEach @($script:XamlFiles | Where-Object { $_.Name -notlike 'Styles/*' }) {
        $text = Get-Content -LiteralPath $Path -Raw
        # Nur echte Farbattribute (Leerzeichen davor), nicht z. B. LastChildFill.
        [regex]::Matches($text, '(?<=\s)(?:Background|Foreground|BorderBrush|Fill|Stroke)="(?!\{)(?!Transparent")([^"]+)"').Count | Should -Be 0
    }

    It 'hat eindeutige Steuerelementnamen über alle Fenster, Ansichten und Dialoge' {
        @($script:AllNames | Group-Object | Where-Object Count -GT 1 | ForEach-Object Name) | Should -BeNullOrEmpty
    }

    It 'definiert in beiden Farbschemata dieselben Schlüssel' {
        $light = [regex]::Matches((Get-Content -LiteralPath (Join-Path $script:GuiRoot 'Styles/Theme.Light.xaml') -Raw), 'x:Key="([^"]+)"') | ForEach-Object { $_.Groups[1].Value }
        $dark = [regex]::Matches((Get-Content -LiteralPath (Join-Path $script:GuiRoot 'Styles/Theme.Dark.xaml') -Raw), 'x:Key="([^"]+)"') | ForEach-Object { $_.Groups[1].Value }
        Compare-Object -ReferenceObject @($light) -DifferenceObject @($dark) | Should -BeNullOrEmpty
    }

    It 'erkennt Verstöße gegen die XAML-Regeln' {
        $bad = '<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" x:Class="A.B"><Button x:Name="A" Click="Do" /><TextBox x:Name="A" /></Grid>'
        $problems = @(Test-EobXamlContent -Xaml $bad)
        ($problems -join ' ') | Should -Match 'x:Class'
        ($problems -join ' ') | Should -Match 'Click'
        ($problems -join ' ') | Should -Match "'A'"
        @(Test-EobXamlContent -Xaml '<Grid') | Should -Match 'wohlgeformt'
    }
}

Describe 'Abgleich Code und XAML' {
    It 'zeigt das verpflichtende Willkommens-HandOut ausgewählt und gesperrt' {
        [xml]$view = Get-Content -LiteralPath (Join-Path $script:GuiRoot 'Views/OnboardingView.xaml') -Raw
        $check = $view.SelectSingleNode('//*[@*[local-name()="Name"]="OnbWelcomeDocCheck"]')
        $check.IsChecked | Should -Be 'True'
        $check.IsEnabled | Should -Be 'False'
    }

    It 'bietet zusätzliche HandOuts nur optional und nicht vorausgewählt an' {
        foreach ($entry in @(
                @{ File = 'Views/OffboardingView.xaml'; Control = 'OffHandoutCheck' }
                @{ File = 'Views/UserUpdateView.xaml'; Control = 'UpdHandoutCheck' }
            )) {
            [xml]$view = Get-Content -LiteralPath (Join-Path $script:GuiRoot $entry.File) -Raw
            $check = $view.SelectSingleNode('//*[@*[local-name()="Name"]="' + $entry.Control + '"]')
            $check.IsChecked | Should -Be 'False'
            $check.IsEnabled | Should -Not -Be 'False'
        }
    }

    It 'verwendet im Code nur vorhandene Steuerelemente' {
        $referenced = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($pattern in @('\$c\.([A-Z][A-Za-z0-9]+)', '\$script:Ui\.C\.([A-Z][A-Za-z0-9]+)')) {
            foreach ($match in [regex]::Matches($script:UiSource, $pattern)) { $null = $referenced.Add($match.Groups[1].Value) }
        }
        # Konfigurationsschlüssel (-Key 'SimulationByDefault' usw.) sind keine Steuerelemente.
        $configKeys = @([regex]::Matches($script:UiSource, "-Key\s+'([A-Za-z0-9]+)'") | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
        $prefixes = 'Onb|Off|Upd|Bulk|Reports|Audit|Tools|Set|Info|Dash|Nav|Dlg|Cred|Header|Status|Mode|Theme|Simulation|Main'
        foreach ($match in [regex]::Matches($script:UiSource, "'((?:$prefixes)[A-Z][A-Za-z0-9]*)'")) {
            $name = $match.Groups[1].Value
            if ($name -notmatch '(Brush|Style)$' -and $name -notin $configKeys) { $null = $referenced.Add($name) }
        }
        foreach ($name in @('Keys', 'Values', 'Count')) { $null = $referenced.Remove($name) }
        @($referenced | Where-Object { $_ -notin $script:AllNames } | Sort-Object) | Should -BeNullOrEmpty
        $referenced.Count | Should -BeGreaterThan 150
    }

    It 'findet die nummerierten Schritt-Steuerelemente der Assistenten' {
        foreach ($index in 1..8) { $script:AllNames | Should -Contain "OnbPanel$index"; $script:AllNames | Should -Contain "OnbStep$index" }
        foreach ($index in 1..4) { $script:AllNames | Should -Contain "OffPanel$index"; $script:AllNames | Should -Contain "OffStep$index" }
    }

    It 'verwendet in Datenbindungen nur Eigenschaften, die der Code erzeugt' {
        $paths = foreach ($file in $script:ControlFiles) {
            [regex]::Matches((Get-Content -LiteralPath $file.FullName -Raw), 'Binding="\{Binding ([A-Za-z]+)\}"') | ForEach-Object { $_.Groups[1].Value }
        }
        $missing = @($paths | Select-Object -Unique | Where-Object { $script:UiSource -notmatch "\b$_\s*=" })
        $missing | Should -BeNullOrEmpty
    }

    It 'verweist nur auf vorhandene Ansichten und Funktionen' {
        InModuleScope 'easyONB.UI' {
            foreach ($name in $script:ViewDefinitions.Keys) {
                $definition = $script:ViewDefinitions[$name]
                Test-Path -LiteralPath (Join-Path $script:GuiRoot $definition.File) | Should -BeTrue
                Get-Command -Name $definition.Initialize -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
                if ($definition.Refresh) { Get-Command -Name $definition.Refresh -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty }
            }
        }
        foreach ($match in [regex]::Matches($script:UiSource, "-On(?:Progress|Complete) '([A-Za-z-]+)'")) {
            InModuleScope 'easyONB.UI' -Parameters @{ Name = $match.Groups[1].Value } { param($Name) Get-Command -Name $Name -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty }
        }
    }

    It 'enthält keine Ereignis-Handler ohne Fehlerbehandlung für Aktionen mit Fachlogik' {
        $handlers = [regex]::Matches($script:UiSource, '\.Add_(Click|SelectionChanged|MouseDoubleClick|Tick)\(\{([^\n]*)')
        foreach ($handler in $handlers) {
            $body = $handler.Groups[2].Value
            if ($body -match 'Invoke-EobUiSafely' -or $body.Trim() -eq '' -or $body -match 'DialogResult = \$true' -or $body -match '^\s*\$script:Ui\.Bulk\.Cancel') { continue }
            throw "Handler ohne Invoke-EobUiSafely: $($handler.Value)"
        }
    }
}

Describe 'Hilfsfunktionen der Oberfläche' {
    It 'wählt die Vordergrundfarbe nach WCAG-Kontrast' {
        (Get-EobAccentPalette -Color '#0F6CBD' -Theme Light).Foreground | Should -Be '#FFFFFF'
        (Get-EobAccentPalette -Color '#FFD700' -Theme Light).Foreground | Should -Be '#000000'
        (Get-EobAccentPalette -Color '#0F6CBD' -Theme Light).Contrast | Should -BeGreaterOrEqual 4.5
    }

    It 'hellt dunkle Akzentfarben im dunklen Schema auf' {
        $dark = Get-EobAccentPalette -Color '#102040' -Theme Dark
        $dark.Accent | Should -Not -Be '#102040'
        { Get-EobAccentPalette -Color 'blau' } | Should -Throw
    }

    It 'zeigt im Testmodus keine modalen Dialoge an' {
        InModuleScope 'easyONB.UI' {
            $script:Ui = New-EobUiState
            $script:Ui.Headless = $true
            (Show-EobDialog -Title 'Titel' -Message 'Meldung' -Details @('Detail') -Kind Warning).Confirmed | Should -BeFalse
            $script:Ui.DialogLog[0] | Should -Be '[Warning] Titel: Meldung Detail'
            Show-EobCredentialDialog -SamAccountName 'mmuster' -Password (New-Object System.Security.SecureString)
            $script:Ui.DialogLog[1] | Should -Match 'mmuster'
        }
    }

    It 'verhindert Live-Modus und Neuladen bei Fehlern in der Konfiguration' {
        $missing = Join-Path $TestDrive 'nicht-vorhanden.ini'
        $null = Initialize-EobLogging -Directory (Join-Path $TestDrive 'logs-config')
        InModuleScope 'easyONB.UI' -Parameters @{ Missing = $missing } {
            param($Missing)
            $script:Ui = New-EobUiState
            $script:Ui.Headless = $true
            $script:Ui.Config = Import-EobConfiguration -Path $Missing -NoIncludes
            (Get-EobUiConfigError -Config $script:Ui.Config) -join ' ' | Should -Match 'CFG_FILE_NOT_FOUND'
            Switch-EobExecutionMode
            $script:Ui.Simulation | Should -BeTrue
            $script:Ui.DialogLog[0] | Should -Match 'Live-Modus nicht möglich'

            $previous = [pscustomobject]@{ Findings = @(); Path = 'bisher' }
            $script:Ui.Config = $previous
            $script:Ui.ConfigPath = $Missing
            Update-EobUiConfiguration
            $script:Ui.Config.Path | Should -Be 'bisher'
            $script:Ui.DialogLog[1] | Should -Match 'nicht übernommen'
        }
    }

    It 'gibt nach einem Fehler in der Massenverarbeitung die Ausführungssperre frei und verwirft Kennwörter' {
        $null = Initialize-EobLogging -Directory (Join-Path $TestDrive 'logs-bulk')
        InModuleScope 'easyONB.UI' {
            $new = { param([string]$Property) [pscustomobject]@{ $Property = $null } }
            $script:Ui = New-EobUiState
            $script:Ui.Headless = $true
            $c = @{ BulkProgressBar = & $new 'Value'; BulkProgressText = & $new 'Text'; ModeToggleButton = & $new 'IsEnabled' }
            foreach ($name in 'BulkCancelButton', 'BulkImportButton', 'BulkExportButton', 'BulkModeOnboardingRadio', 'BulkModeOffboardingRadio') { $c[$name] = & $new 'IsEnabled' }
            foreach ($view in $script:ViewDefinitions.Values) { $c[$view.Nav] = & $new 'IsEnabled' }
            $script:Ui.C = $c
            $timer = [pscustomobject]@{ Running = $false }
            $timer | Add-Member -MemberType ScriptMethod -Name Stop -Value { $this.Running = $false }
            $timer | Add-Member -MemberType ScriptMethod -Name Start -Value { $this.Running = $true }
            $plans = foreach ($index in 1..2) {
                $plan = New-EobPlan -Kind 'Onboarding' -Context (New-EobOperationContext -Kind 'Onboarding' -Simulation) -Simulation
                $plan.Secrets['InitialPassword'] = New-EobPassword
                Add-EobRedactionValue -Value $plan.Secrets['InitialPassword']
                $plan
            }
            $plain = ConvertTo-EobPlainText -SecureString $plans[1].Secrets['InitialPassword']
            $items = @($plans | ForEach-Object { [pscustomobject]@{ RowNumber = 2; State = 'Error'; Plan = $_; Messages = @() } })
            $script:Ui.Bulk = @{ Batch = [pscustomobject]@{ Items = $items; OperationId = 'op-bulk' }; Mode = 'Onboarding'; Index = 0; Timer = $timer; Cancel = $false; Credentials = [System.Collections.Generic.List[object]]::new() }
            $script:Ui.Execution = @{ Plan = $null; Timer = $timer; Bulk = $true }
            Mock Update-EobBulkGrid { throw 'Anzeige fehlgeschlagen' }

            { Invoke-EobBulkTick } | Should -Throw 'Anzeige fehlgeschlagen'
            $script:Ui.Execution | Should -BeNullOrEmpty
            $timer.Running | Should -BeFalse
            $c.BulkModeOnboardingRadio.IsEnabled | Should -BeTrue
            @($items | ForEach-Object Outcome) | Should -Be @('NotExecuted', 'NotExecuted')
            @($plans | Where-Object { $_.Secrets.Count -gt 0 }).Count | Should -Be 0
            Protect-EobSensitiveText -Text $plain | Should -Be $plain
        }
    }

    It 'übernimmt beim Neuladen die Protokollparameter und aktiviert die Warteschlange' {
        InModuleScope 'easyONB.UI' {
            $script:Ui = New-EobUiState
            $script:Ui.ConfigPath = 'reload.ini'
            $script:ReloadConfig = [pscustomobject]@{ Findings = @(); Path = 'reload.ini' }
            Mock Import-EobConfiguration { $script:ReloadConfig }
            Mock Get-EobLoggingParameter { @{ Directory = 'new-logs'; MinimumLevel = 'Warning'; RetentionDays = 14; MaxFileSizeMB = 7 } }
            Mock Initialize-EobLogging {}
            Mock Initialize-EobAdConnection {}
            Mock Update-EobStatusBar {}
            Mock Update-EobSettingsView {}
            Mock Write-EobLog {}

            Update-EobUiConfiguration

            $script:Ui.Config | Should -Be $script:ReloadConfig
            Should -Invoke Get-EobLoggingParameter -Times 1 -Exactly -ParameterFilter { $Config -eq $script:ReloadConfig }
            Should -Invoke Initialize-EobLogging -Times 1 -Exactly -ParameterFilter {
                $Directory -eq 'new-logs' -and $MinimumLevel -eq 'Warning' -and $RetentionDays -eq 14 -and $MaxFileSizeMB -eq 7 -and $EnableQueue
            }
        }
    }

    It 'aktualisiert nur die betroffene Stapelzeile ohne die gebundene Sammlung neu aufzubauen' {
        InModuleScope 'easyONB.UI' {
            $script:Ui = New-EobUiState
            $grid = [pscustomobject]@{ ItemsSource = $null }
            $items = @(foreach ($index in 1..3) {
                    [pscustomobject]@{
                        RowNumber = $index; Request = [pscustomobject]@{ GivenName = 'Test'; Surname = "User$index" }
                        Plan = [pscustomobject]@{ Subject = @{ SamAccountName = "user$index" } }
                        State = 'Ready'; Outcome = ''; Messages = @()
                    }
                })
            $script:Ui.C = @{ BulkItemsGrid = $grid }
            $script:Ui.Bulk = @{ Mode = 'Onboarding'; Batch = [pscustomobject]@{ Items = $items } }
            Update-EobBulkGrid
            $rows = $grid.ItemsSource
            $first = $rows[0]
            $last = $rows[2]
            $change = @{ Count = 0; Action = ''; Index = -1 }
            $rows.add_CollectionChanged([System.Collections.Specialized.NotifyCollectionChangedEventHandler]({
                        param($sourceCollection, $changeArgs)
                        $sourceCollection | Should -Not -BeNullOrEmpty
                        $change.Count++
                        $change.Action = [string]$changeArgs.Action
                        $change.Index = $changeArgs.NewStartingIndex
                    }.GetNewClosure()))
            Mock ConvertTo-EobBulkRow -MockWith { [pscustomobject]@{ OutcomeText = $Item.Outcome; MessagesText = $Item.Messages -join ' | ' } }
            $items[1].Outcome = 'Failed'
            $items[1].Messages = @('Fehler')

            Update-EobBulkGrid -Index 1

            [object]::ReferenceEquals($grid.ItemsSource, $rows) | Should -BeTrue
            [object]::ReferenceEquals($rows[0], $first) | Should -BeTrue
            [object]::ReferenceEquals($rows[2], $last) | Should -BeTrue
            $rows[1].OutcomeText | Should -Be 'Failed'
            $rows[1].MessagesText | Should -Be 'Fehler'
            $change.Count | Should -Be 1
            $change.Action | Should -Be 'Replace'
            $change.Index | Should -Be 1
            Should -Invoke ConvertTo-EobBulkRow -Times 1 -Exactly -ParameterFilter { $Item.RowNumber -eq 2 }
        }
    }

    It 'filtert das Audit-Log ohne Platzhaltersyntax' {
        $null = Initialize-EobLogging -Directory (Join-Path $TestDrive 'logs-auditfilter')
        Write-EobLog -Level Audit -Action 'Test' -Target 'konto[1]' -Message 'Filtertest'
        Write-EobLog -Level Audit -Action 'Test' -Target 'anderes' -Message 'Filtertest'
        InModuleScope 'easyONB.UI' {
            $script:Ui = New-EobUiState
            $script:Ui.Headless = $true
            $script:Ui.C = @{
                AuditFilterText = [pscustomobject]@{ Text = 'KONTO[' }; AuditFromPicker = [pscustomobject]@{ SelectedDate = (Get-Date).AddDays(-1) }
                AuditToPicker = [pscustomobject]@{ SelectedDate = (Get-Date) }; AuditGrid = [pscustomobject]@{ ItemsSource = $null }; AuditSummaryText = [pscustomobject]@{ Text = '' }
            }
            { Update-EobAuditList } | Should -Not -Throw
            @($script:Ui.C.AuditGrid.ItemsSource).Target | Should -Be @('konto[1]')
        }
    }

    It 'begrenzt das Fenster (1400 x 900) auf die Arbeitsfläche' {
        InModuleScope 'easyONB.UI' {
            $full = Get-EobWindowBound -Width 1400 -Height 900 -MinWidth 1100 -MinHeight 680 -WorkAreaWidth 1920 -WorkAreaHeight 1040
            $full.Width | Should -Be 1400
            $full.Height | Should -Be 900
            $laptop = Get-EobWindowBound -Width 1400 -Height 900 -MinWidth 1100 -MinHeight 680 -WorkAreaWidth 1366 -WorkAreaHeight 728
            $laptop.Width | Should -Be 1366
            $laptop.Height | Should -Be 728
            $laptop.MinHeight | Should -Be 680
            $small = Get-EobWindowBound -Width 1400 -Height 900 -MinWidth 1100 -MinHeight 680 -WorkAreaWidth 1024 -WorkAreaHeight 600
            $small.MinWidth | Should -Be 1024
            $small.MinHeight | Should -Be 600
        }
    }

    It 'zeigt lange Detaillisten im Dialog scrollbar über der Tippbestätigung an' {
        $xaml = [xml](Get-Content -LiteralPath (Join-Path $script:GuiRoot 'Dialogs/ConfirmDialog.xaml') -Raw)
        $details = $xaml.SelectSingleNode("//*[@*[local-name()='Name']='DlgDetailsList']")
        $details.ParentNode.LocalName | Should -Be 'ScrollViewer'
        [int]$details.ParentNode.MaxHeight | Should -BeLessOrEqual 300
    }

    It 'meldet die Oberfläche außerhalb von Windows als nicht verfügbar' -Skip:$IsWindows {
        $result = Test-EobGuiEnvironment
        $result.IsSupported | Should -BeFalse
        $result.Reason | Should -Match 'Windows'
    }

    It 'übergibt automatisch ermittelte Kontonamen nicht als feste Vorgabe' {
        InModuleScope 'easyONB.UI' {
            $values = @{ GivenName = 'Max'; Surname = 'Muster'; SamAccountName = 'mmuster'; UserPrincipalNamePrefix = 'max.eigen'; MailLocalPart = ''; StartDate = [datetime]'2027-01-04' }
            $data = Get-EobOnboardingFormRequestData -Values $values -AutoIdentity @{ SamAccountName = 'mmuster'; UserPrincipalNamePrefix = 'max.muster' }
            $data.ContainsKey('SamAccountName') | Should -BeFalse
            $data['UserPrincipalNamePrefix'] | Should -Be 'max.eigen'
            $data.ContainsKey('MailLocalPart') | Should -BeFalse
            $data['StartDate'] | Should -Be '2027-01-04'
        }
    }

    It 'übersetzt das Offboarding-Formular' {
        InModuleScope 'easyONB.UI' {
            $data = Get-EobOffboardingFormRequestData -Values @{ Identity = 'guid'; Template = 'Standard'; ExitDate = [datetime]'2027-03-31'; AssetsText = "Notebook 123`r`n`r`nHandy 456 "; AcknowledgePrivileged = $true; AuthorizedHomeAccessAccount = 'chefin' }
            $data['ExitDate'] | Should -Be '2027-03-31'
            $data['Assets'] | Should -Be @('Notebook 123', 'Handy 456')
            $data['AcknowledgePrivileged'] | Should -BeTrue
            $data['AuthorizedHomeAccessAccount'] | Should -Be 'chefin'
            (Get-EobOffboardingFormRequestData -Values @{ Identity = 'guid' })['AuthorizedHomeAccessAccount'] | Should -Be ''
        }
    }

    It 'übergibt ausschließlich das ausdrücklich eingetragene Home-Zugriffskonto "<Account>"' -ForEach @(
        @{ Account = '' }
        @{ Account = 'chefin' }
    ) {
        InModuleScope 'easyONB.UI' -Parameters @{ Account = $Account } {
            param($Account)
            $script:Ui = New-EobUiState
            $script:Ui.Offboarding = @{ User = [pscustomobject]@{ ObjectGuid = [guid]::Empty; Manager = 'nicht-freigegebene-ad-fuehrungskraft' } }
            $script:Ui.C = @{
                OffTemplateCombo = [pscustomobject]@{}
                OffExitDatePicker = [pscustomobject]@{ SelectedDate = [datetime]'2027-03-31' }
                OffAcknowledgePrivilegedCheck = [pscustomobject]@{ IsChecked = $false }
                OffAuthorizedHomeAccessText = [pscustomobject]@{ Text = $Account }
            }
            foreach ($name in 'OffTicketText', 'OffReasonText', 'OffNotesText', 'OffForwardToText', 'OffAutoReplyText', 'OffAssetsText') {
                $script:Ui.C[$name] = [pscustomobject]@{ Text = '' }
            }
            Mock Get-EobComboValue { 'Standard' }
            Mock ConvertTo-EobOffboardingRequest { [pscustomobject]$InputObject }
            $request = Get-EobOffboardingFormRequest
            $request.AuthorizedHomeAccessAccount | Should -Be $Account
            $script:Ui.C.OffAuthorizedHomeAccessText.Text | Should -Be $Account
            Should -Invoke ConvertTo-EobOffboardingRequest -Times 1 -Exactly -ParameterFilter {
                $InputObject.AuthorizedHomeAccessAccount -eq $script:Ui.C.OffAuthorizedHomeAccessText.Text
            }
        }
    }

    It 'bereitet Schritte, Befunde und Warteschlangeneinträge für die Anzeige auf' {
        InModuleScope 'easyONB.UI' {
            $step = [pscustomobject]@{ Id = 'S01'; Phase = 'ExitDate'; DueDate = [datetime]'2027-04-01'; Title = 'Konto deaktivieren'; Target = 'mmuster'; Risk = 'High'; Details = @('a', 'b'); Status = 'Planned'; Message = ''; Enabled = $true }
            $row = ConvertTo-EobUiStepRow -Step $step
            $row.PhaseText | Should -Be 'Zum Austritt'
            $row.DueText | Should -Be '01.04.2027'
            $row.RiskText | Should -Be 'Hoch'
            $row.DetailsText | Should -Be 'a | b'
            $step.Enabled = $false
            (ConvertTo-EobUiStepRow -Step $step).StatusText | Should -Be 'Nur nach manueller Freigabe'
            (ConvertTo-EobUiFindingRow -Finding ([pscustomobject]@{ Severity = 'Warning'; Code = 'X'; Field = 'F'; Message = 'M' })).SeverityText | Should -Be 'Warnung'
            $queue = [pscustomobject]@{ OperationId = '1'; DisplayName = 'Max'; SamAccountName = 'mmuster'; Template = 'Standard'; ExitDate = [datetime]'2027-03-31'; Status = 'AwaitingDeletion'
                NextPhase = ''; NextDueDate = $null; DeletionDate = [datetime]'2027-09-27'; IsDue = $false; DeletionDue = $true; Privileged = $false; RequiresIntegration = @()
            }
            $queueRow = ConvertTo-EobUiQueueRow -Item $queue
            $queueRow.Account | Should -Be 'Max (mmuster)'
            $queueRow.NoteText | Should -Match 'Löschung fällig'
            $queueRow.StatusText | Should -Be 'Wartet auf Löschfreigabe'
        }
    }

    It 'formatiert ISO-Zeitstempel des Audit-Logs' {
        InModuleScope 'easyONB.UI' {
            ConvertTo-EobUiDateText -Value '2027-01-04' | Should -Be '04.01.2027'
            ConvertTo-EobUiDateText -Value ([datetime]'2027-01-04 13:05') -WithTime | Should -Be '04.01.2027 13:05'
            ConvertTo-EobUiDateText -Value '' | Should -Be ''
            ConvertTo-EobUiDateText -Value $null | Should -Be ''
            ConvertTo-EobUiDateText -Value '2027-01-04T13:05:00.0000000+00:00' -WithTime | Should -Match '^04\.01\.2027 \d\d:05$'
        }
    }
}

Describe 'Offene Offboarding-Phasen der Oberfläche' {
    It 'zeigt die Sofortphase nur mit verbleibenden Aktionen: <Case>' -ForEach @(
        @{ Case = 'fehlgeschlagen'; Completed = @(); ActionCount = 1; Expected = $true }
        @{ Case = 'abgeschlossen'; Completed = @('Immediate'); ActionCount = 1; Expected = $false }
        @{ Case = 'ohne Aktionen'; Completed = @(); ActionCount = 0; Expected = $false }
    ) {
        InModuleScope 'easyONB.UI' -Parameters @{ Completed = $Completed; ActionCount = $ActionCount; Expected = $Expected } {
            param($Completed, $ActionCount, $Expected)
            $script:Ui = New-EobUiState
            $script:Ui.Offboarding = @{ SelectedPhases = @('Immediate'); ReportPath = ''; HandoutRequested = $false }
            $script:Ui.C = @{
                OffHandoutCheck = [pscustomobject]@{ IsChecked = $false }
                OffProgressBar = [pscustomobject]@{ Value = 0 }
                OffProgressText = [pscustomobject]@{ Text = '' }
                OffResultStepsGrid = [pscustomobject]@{ ItemsSource = $null }
                OffOpenReportButton = [pscustomobject]@{ Visibility = '' }
                OffResultBanner = [pscustomobject]@{}
                OffResultText = [pscustomobject]@{ Text = '' }
            }
            $plan = [pscustomobject]@{
                OperationId = 'immediate-retry'; Status = 'Failed'; Simulation = $false; Steps = @()
                Subject = @{ SamAccountName = 'test' }
                Offboarding = @{
                    CompletedPhases = $Completed
                    PhaseStepCount = @{ Immediate = $ActionCount; ExitDate = 0; Retention = 0 }
                    PhaseDates = @{ Immediate = [datetime]'2027-03-31' }
                }
            }
            Mock Complete-EobOffboardingRun {}
            Mock Clear-EobPlanSecret {}
            Mock Export-EobUiPlanReport { '' }
            Mock Set-EobOffboardingStep {}
            Mock Update-EobOffboardingQueue {}
            Mock Set-EobBanner { $script:OffCompletionText = $Text }

            Complete-EobOffboardingExecution -Plan $plan

            ($script:OffCompletionText -match 'Offene Phasen \(Sofort ab') | Should -Be $Expected
        }
    }
}

Describe 'Optionale HandOuts der Oberfläche' {
    It 'schreibt ohne ausdrücklichen Wunsch keine zusätzlichen Dateien' {
        InModuleScope 'easyONB.UI' {
            $script:Ui = New-EobUiState
            Mock Get-EobReportDirectory { 'handouts' }
            Mock Export-EobPlanReport {}
            Export-EobUiPlanHandout -Plan ([pscustomobject]@{ OperationId = 'no-handout' }) | Should -Be ''
            Should -Invoke Get-EobReportDirectory -Times 0 -Exactly
            Should -Invoke Export-EobPlanReport -Times 0 -Exactly
        }
    }

    It 'exportiert <Status> unverändert als HTML/PDF in den HandOut-Unterordner' -ForEach @(
        @{ Status = 'Simulated'; Simulation = $true }
        @{ Status = 'Failed'; Simulation = $false }
    ) {
        InModuleScope 'easyONB.UI' -Parameters @{ Status = $Status; Simulation = $Simulation } {
            param($Status, $Simulation)
            $script:Ui = New-EobUiState
            $script:HandoutPlan = [pscustomobject]@{ OperationId = 'handout-result'; Status = $Status; Simulation = $Simulation }
            Mock Get-EobReportDirectory { 'handouts' }
            Mock Export-EobPlanReport {
                [pscustomobject]@{ Format = 'Html'; Path = 'handouts/result.html' }
                [pscustomobject]@{ Format = 'Pdf'; Path = 'handouts/result.pdf' }
            }

            Export-EobUiPlanHandout -Plan $script:HandoutPlan -Requested | Should -Be 'handouts/result.html'

            Should -Invoke Get-EobReportDirectory -Times 1 -Exactly -ParameterFilter { $Kind -eq 'Handouts' }
            Should -Invoke Export-EobPlanReport -Times 1 -Exactly -ParameterFilter {
                [object]::ReferenceEquals($Plan, $script:HandoutPlan) -and $Directory -eq 'handouts' -and
                ($Format -join ',') -eq 'Html,Pdf'
            }
            $script:HandoutPlan.Status | Should -Be $Status
            $script:HandoutPlan.Simulation | Should -Be $Simulation
        }
    }

    It 'behandelt einen HandOut-Exportfehler ohne das Vorgangsergebnis zu ändern' {
        InModuleScope 'easyONB.UI' {
            $script:Ui = New-EobUiState
            $plan = [pscustomobject]@{ OperationId = 'failed-export'; Status = 'Succeeded' }
            Mock Get-EobReportDirectory { 'handouts' }
            Mock Export-EobPlanReport { throw 'Datei gesperrt' }
            Mock Write-EobLog {}
            Export-EobUiPlanHandout -Plan $plan -Requested | Should -Be ''
            $plan.Status | Should -Be 'Succeeded'
            Should -Invoke Write-EobLog -Times 1 -Exactly -ParameterFilter { $Action -eq 'HandoutWritten' -and $Level -eq 'Warning' }
        }
    }

    It 'übergibt für <Action> den ausdrücklichen HandOut-Wunsch <Requested> erst mit dem Ergebnis' -ForEach @(
        foreach ($action in 'Offboarding', 'Update', 'PasswordReset', 'DeletionSimulation', 'DeletionLive') {
            foreach ($requested in $false, $true) { @{ Action = $action; Requested = $requested } }
        }
    ) {
        InModuleScope 'easyONB.UI' -Parameters @{ Action = $Action; Requested = $Requested } {
            param($Action, $Requested)
            $script:Ui = New-EobUiState
            $script:Ui.Simulation = $Action -ne 'DeletionLive'
            $script:HandoutPlan = [pscustomobject]@{
                OperationId = 'completed-result'; Status = 'Failed'; Simulation = $true; Findings = @(); Steps = @()
                Subject = @{ SamAccountName = 'test' }
                Summary = @{ Bestätigungstext = 'LÖSCHEN test' }
                Offboarding = @{ CompletedPhases = @(); PhaseStepCount = @{ ExitDate = 1; Retention = 0 } }
            }
            $script:RequestedHandout = $Requested
            $script:Ui.Offboarding = @{ SelectedPhases = @(); ReportPath = ''; HandoutRequested = $false; Plan = $script:HandoutPlan }
            $script:Ui.Update = @{ User = [pscustomobject]@{ ObjectGuid = [guid]::Empty; DisplayName = 'Test'; SamAccountName = 'test' }; HandoutRequested = $false; Plan = $script:HandoutPlan }
            $script:Ui.C = @{
                OffHandoutCheck = [pscustomobject]@{ IsChecked = $Requested }
                UpdHandoutCheck = [pscustomobject]@{ IsChecked = $Requested }
                OffProgressBar = [pscustomobject]@{ Value = 0 }
                OffProgressText = [pscustomobject]@{ Text = '' }
                OffResultStepsGrid = [pscustomobject]@{ ItemsSource = $null }
                OffOpenReportButton = [pscustomobject]@{ Visibility = '' }
                OffResultBanner = [pscustomobject]@{ Visibility = '' }
                OffResultText = [pscustomobject]@{ Text = '' }
                UpdPreviewStepsGrid = [pscustomobject]@{ ItemsSource = $null }
                UpdResultBanner = [pscustomobject]@{}
                UpdResultText = [pscustomobject]@{ Text = '' }
                UpdPreviewButton = [pscustomobject]@{ IsEnabled = $false }
                UpdExecuteButton = [pscustomobject]@{ IsEnabled = $true }
            }
            Mock Export-EobUiPlanReport { '' }
            Mock Get-EobReportDirectory { 'handouts' }
            Mock Export-EobPlanReport { [pscustomobject]@{ Format = 'Html'; Path = 'handouts/result.html' } }
            Mock Complete-EobOffboardingRun {}
            Mock Clear-EobPlanSecret {}
            Mock Set-EobBanner {}
            Mock Set-EobOffboardingStep {}
            Mock Update-EobOffboardingQueue {}
            Mock Test-EobPlanExecutable { $true }
            Mock Select-EobOffboardingPhase { 'ExitDate' }
            Mock Get-EobOffboardingIncludePhase { 'ExitDate' }
            Mock Start-EobUiPlanExecution {
                $script:Ui.C.OffHandoutCheck.IsChecked = -not $script:RequestedHandout
                $script:Ui.C.UpdHandoutCheck.IsChecked = -not $script:RequestedHandout
                & $OnComplete -Plan $Plan
            }
            Mock Show-EobDialog { [pscustomobject]@{ Confirmed = $true; Text = 'LÖSCHEN test' } }
            Mock Get-EobAdPasswordPolicy { $null }
            Mock New-EobPasswordResetPlan { $script:HandoutPlan }
            Mock Invoke-EobPlan {
                $script:Ui.C.UpdHandoutCheck.IsChecked = -not $script:RequestedHandout
                $script:HandoutPlan
            }
            Mock Get-EobPlanCredential { $null }
            Mock Get-EobSelectedQueueItem { [pscustomobject]@{ OperationId = 'completed-result'; DisplayName = 'Test'; SamAccountName = 'test' } }
            Mock New-EobOffboardingDeletionPlan { $script:HandoutPlan }
            Mock Invoke-EobOffboardingFinalDeletion {
                $script:Ui.C.OffHandoutCheck.IsChecked = -not $script:RequestedHandout
                $script:HandoutPlan
            }

            switch ($Action) {
                'Offboarding' {
                    Invoke-EobOffboardingExecution
                    Complete-EobOffboardingExecution -Plan $script:HandoutPlan
                    $script:Ui.C.OffHandoutCheck.IsChecked | Should -BeFalse
                }
                'Update' {
                    Invoke-EobUserUpdateExecution
                    Complete-EobUserUpdateExecution -Plan $script:HandoutPlan
                    $script:Ui.C.UpdHandoutCheck.IsChecked | Should -BeFalse
                }
                'PasswordReset' { Invoke-EobPasswordReset }
                default { Invoke-EobOffboardingDeletion }
            }

            $handoutCount = if ($Requested) { 1 } else { 0 }
            Should -Invoke Export-EobPlanReport -Times $handoutCount -Exactly -ParameterFilter {
                [object]::ReferenceEquals($Plan, $script:HandoutPlan) -and $Directory -eq 'handouts' -and ($Format -join ',') -eq 'Html,Pdf'
            }
            $reportCount = if ($Action -eq 'DeletionSimulation') { 0 } elseif ($Action -in 'Offboarding', 'Update') { 2 } else { 1 }
            Should -Invoke Export-EobUiPlanReport -Times $reportCount -Exactly
            if ($Action -eq 'PasswordReset') { $script:Ui.C.UpdHandoutCheck.IsChecked | Should -BeFalse }
            if ($Action -like 'Deletion*') { $script:Ui.C.OffHandoutCheck.IsChecked | Should -BeFalse }
        }
    }
}

Describe 'WPF-Ladeprüfung (Windows)' -Tag 'Windows' {
    BeforeAll {
        $script:TestConfigPath = Join-Path $TestDrive 'ui.ini'
        $template = Get-Content -LiteralPath (Join-Path (Get-EobTestRepoRoot) 'Config/easyONB.ini.template') -Raw
        $template = $template -replace '(?m)^LogFile=.*$', ('LogFile=' + (Join-Path $TestDrive 'logs')) -replace '(?m)^ReportPath=.*$', ('ReportPath=' + (Join-Path $TestDrive 'reports'))
        Set-Content -LiteralPath $script:TestConfigPath -Value $template -Encoding utf8
        $script:UiConfig = Import-EobConfiguration -Path $script:TestConfigPath -NoIncludes
        $null = Initialize-EobLogging -Directory (Join-Path $TestDrive 'logs') -EnableQueue
    }

    It 'lädt alle XAML-Dateien über WPF' -Skip:(-not $script:CanLoadWpf) {
        InModuleScope 'easyONB.UI' -Parameters @{ Config = $script:UiConfig } {
            param($Config)
            Import-EobWpfAssembly
            $script:Ui = New-EobUiState
            $script:Ui.Headless = $true
            $script:Ui.Config = $Config
            Initialize-EobApplication -Theme Light -AccentColor '#0F6CBD'
            foreach ($file in @('MainWindow.xaml', 'Dialogs/ConfirmDialog.xaml', 'Dialogs/CredentialDialog.xaml') + @($script:ViewDefinitions.Values | ForEach-Object File)) {
                $loaded = Import-EobXamlWithControl -RelativePath $file
                $loaded.Root | Should -Not -BeNullOrEmpty
                $loaded.Controls.Count | Should -BeGreaterThan 0
            }
            Set-EobTheme -Theme Dark -AccentColor '#0F6CBD'
            $script:Ui.Theme | Should -Be 'Dark'
            @($script:Ui.DialogLog) | Should -BeNullOrEmpty
        }
    }

    It 'initialisiert Hauptfenster und alle Ansichten ohne Anzeige' -Skip:(-not $script:CanLoadWpf) {
        InModuleScope 'easyONB.UI' -Parameters @{ Config = $script:UiConfig; Path = $script:TestConfigPath } {
            param($Config, $Path)
            Import-EobWpfAssembly
            $script:Ui = New-EobUiState
            $script:Ui.Headless = $true
            $script:Ui.Config = $Config
            $script:Ui.ConfigPath = $Path
            Initialize-EobApplication -Theme Light
            $loaded = Import-EobXamlWithControl -RelativePath 'MainWindow.xaml'
            $script:Ui.Window = $loaded.Root
            $script:Ui.C = $loaded.Controls
            $script:Ui.Window.Width | Should -Be 1400
            $script:Ui.Window.Height | Should -Be 900
            Set-EobWindowBound -Window $script:Ui.Window
            $script:Ui.Window.Width | Should -BeLessOrEqual 1400
            Initialize-EobMainWindow
            foreach ($name in $script:ViewDefinitions.Keys) {
                Show-EobView -Name $name
                $script:Ui.CurrentView | Should -Be $name
                $script:Ui.C.MainContent.Content | Should -Be $script:Ui.Views[$name]
            }
            Set-EobOnboardingStep -Step 7
            $script:Ui.C.OnbExecuteButton.Visibility | Should -Be 'Visible'
            # Fehler in Initialisierung oder Aktualisierung würden als Dialog gemeldet.
            @($script:Ui.DialogLog) | Should -BeNullOrEmpty
            Stop-EobUi
            $script:Ui.Window.Close()
        }
    }
}
