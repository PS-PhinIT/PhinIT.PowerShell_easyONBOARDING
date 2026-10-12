#Requires -Version 7.2
<#
.SYNOPSIS
    Lokale, testbare Dokumentfunktionen und WPF-Oberfläche des Konfigurationseditors.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Editorfunktionen ändern nur Speicher und WPF; Speichern hat ShouldProcess.')]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Test-EobEditorSecret {
    <#
    .SYNOPSIS
        Erkennt Secret-Felder und offensichtlich eingebettete Zugangsdaten ohne Werte auszugeben.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$Key, [AllowEmptyString()][string]$Value, [AllowNull()][hashtable]$Definition)

    if ($null -ne $Definition) {
        if ($Definition.ContainsKey('Secret') -and $Definition.Secret) { return $true }
    }
    elseif ($Key -match '(?i)(password|passwort|kennwort|secret|token|apikey|api_key|webhook|credential|connectionstring|privatekey)') {
        return $true
    }
    return $Value -match '(?i)(://[^/\s:@]+:[^/\s@]+@|(?:password|passwort|kennwort|secret|token|api[_-]?key|pwd)[ \t]*[:=][ \t]*\S+|Bearer[ \t]+\S+|-----BEGIN .*PRIVATE KEY-----|eyJ[\w-]+\.[\w-]+\.[\w-]+)'
}

function Test-EobEditorSourceSecret {
    <#
    .SYNOPSIS
        Prüft jede Quellzeile, einschließlich doppelter Schlüssel und Kommentare, schemaabhängig.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][hashtable]$Schema)

    $section = 'Global'
    foreach ($line in ($Text -split '\r?\n')) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^\[(.+)\]$') { $section = $Matches[1].Trim(); continue }
        if ($trimmed -match '^([^;#][^=]*?)=(.*)$') {
            $key = $Matches[1].Trim()
            $value = $Matches[2].Trim()
            $sd = Get-EobSchemaSectionDefinition -Schema $Schema -Name $section
            $kd = if ($null -ne $sd) { Get-EobSchemaKeyDefinition -SectionDefinition $sd -Key $key } else { $null }
            if ($value -and (Test-EobEditorSecret -Key $key -Value $value -Definition $kd)) { return $true }
        }
        elseif (Test-EobEditorSecret -Value $line) { return $true }
    }
    return $false
}

function Get-EobEditorField {
    <#
    .SYNOPSIS
        Liefert Schemafelder und alle dynamischen, freien und unbekannten geladenen Schlüssel.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Document)

    $config = $Document.Config
    $sections = @(@($config.Schema.Sections.Keys) + @($config.Sections.Keys) | Sort-Object -Unique)
    foreach ($section in $sections) {
        $sectionDefinition = Get-EobSchemaSectionDefinition -Schema $config.Schema -Name $section
        $keys = @()
        if ($null -ne $sectionDefinition -and $sectionDefinition.ContainsKey('Keys')) { $keys += @($sectionDefinition.Keys.Keys) }
        if ($config.Sections.Contains($section)) { $keys += @($config.Sections[$section].Keys) }
        foreach ($key in @($keys | Sort-Object -Unique)) {
            $definition = if ($null -ne $sectionDefinition) { Get-EobSchemaKeyDefinition -SectionDefinition $sectionDefinition -Key $key } else { $null }
            $value = ''
            $present = $config.Sections.Contains($section) -and $config.Sections[$section].Contains($key)
            if ($present) { $value = [string]$config.Sections[$section][$key] }
            if (Test-EobEditorSecret -Key $key -Value $value -Definition $definition) { continue }
            $type = 'String'
            $description = 'Eigener Schlüssel: bleibt erhalten und kann frei bearbeitet werden.'
            $options = @()
            if ($null -ne $definition) {
                if ($definition.ContainsKey('Type')) { $type = $definition.Type }
                if ($definition.ContainsKey('Description')) { $description = $definition.Description }
                if ($definition.ContainsKey('Values')) { $options = @($definition.Values) }
                if ($definition.ContainsKey('Default') -and -not $present) {
                    $description += " Standard bei fehlendem Schlüssel: $($definition.Default)."
                }
                if ($definition.ContainsKey('Required') -and $definition.Required) { $description += ' Pflichtfeld.' }
            }
            elseif ($null -ne $sectionDefinition -and $sectionDefinition.ContainsKey('ValueType')) { $type = $sectionDefinition.ValueType }
            [pscustomobject]@{ Section = $section; Key = $key; Type = $type; Description = $description; Options = $options; Value = $value; Present = $present }
        }
    }
}

function Import-EobEditorDocument {
    <#
    .SYNOPSIS
        Öffnet ausschließlich die gewählte Datei, ohne Includes oder Verbindungen.
    .PARAMETER Fragment
        Kennzeichnet eine Include-Datei; nur anwendungsweite Abhängigkeiten werden zurückgestellt.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [switch]$AsTemplate, [switch]$Fragment)

    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    $config = Import-EobConfiguration -Path $resolved -NoIncludes
    $source = (Get-EobTextFileContent -Path $resolved).Text
    foreach ($section in $config.Sections.Keys) {
        $sd = Get-EobSchemaSectionDefinition -Schema $config.Schema -Name $section
        foreach ($key in $config.Sections[$section].Keys) {
            $kd = if ($null -ne $sd) { Get-EobSchemaKeyDefinition -SectionDefinition $sd -Key $key } else { $null }
            $value = [string]$config.Sections[$section][$key]
            if ($value -and (Test-EobEditorSecret -Key $key -Value $value -Definition $kd)) {
                throw "[$section] $key enthält möglicherweise Zugangsdaten. Entfernen Sie den Wert außerhalb des Editors und öffnen Sie die Datei erneut."
            }
        }
    }
    # Auch überschriebene doppelte Schlüssel und Kommentare dürfen keine Secrets in die Ausgabe schleusen.
    if (Test-EobEditorSourceSecret -Text $source -Schema $config.Schema) {
        throw 'Die Quelldatei enthält möglicherweise eingebettete Zugangsdaten (auch in Kommentaren). Entfernen Sie diese vor dem Öffnen.'
    }
    [pscustomobject]@{
        Config = $config
        SourceText = $source
        Path = $(if ($AsTemplate) { '' } else { $resolved })
        Dirty = [bool]$AsTemplate
        Fragment = [bool]$Fragment
        InputErrors = @{}
        SourceFindings = @($config.Findings | Where-Object Code -In @('CFG_DUPLICATE_KEY', 'CFG_INVALID_LINE'))
    }
}

function Set-EobEditorValue {
    <#
    .SYNOPSIS
        Ändert einen INI-Wert im Speicher; fehlende Schlüssel bleiben bis zur Änderung unangetastet.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Document, [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][string]$Key, [AllowEmptyString()][string]$Value)

    $fieldId = "$Section.$Key"
    if ($Section -match '[\r\n\[\]]' -or $Key -match '[\r\n=]' -or $Value -match '[\r\n\x00]') {
        $Document.InputErrors[$fieldId] = 'Zeilenumbrüche und ungültige INI-Zeichen entfernen.'
        $Document.Dirty = $true
        throw 'Abschnitt, Schlüssel und Wert müssen eine einzelne gültige INI-Zeile bilden.'
    }
    $sd = Get-EobSchemaSectionDefinition -Schema $Document.Config.Schema -Name $Section
    $kd = if ($null -ne $sd) { Get-EobSchemaKeyDefinition -SectionDefinition $sd -Key $Key } else { $null }
    if (Test-EobEditorSecret -Key $Key -Value $Value -Definition $kd) {
        $Document.InputErrors[$fieldId] = 'Zugangsdaten entfernen; einen normalen Konfigurationswert eingeben.'
        $Document.Dirty = $true
        throw 'Zugangsdaten sind im Konfigurationseditor nicht zulässig.'
    }
    $Document.InputErrors.Remove($fieldId)
    $sections = $Document.Config.Sections
    if (-not $sections.Contains($Section)) {
        $sections[$Section] = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::OrdinalIgnoreCase)
    }
    if (-not $sections[$Section].Contains($Key) -or [string]$sections[$Section][$Key] -cne $Value) {
        $sections[$Section][$Key] = $Value
        $Document.Dirty = $true
    }
}

function Test-EobEditorDocument {
    <#
    .SYNOPSIS
        Prüft Fachregeln und blockiert ungültige Formate sowie Secrets vor dem Schreiben.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Document)

    if ($Document.InputErrors.Count) {
        foreach ($field in $Document.InputErrors.Keys) {
            New-EobFinding -Severity Error -Code 'EDITOR_INPUT_ERROR' -Field $field -Message $Document.InputErrors[$field]
        }
        return
    }
    foreach ($section in $Document.Config.Sections.Keys) {
        $sd = Get-EobSchemaSectionDefinition -Schema $Document.Config.Schema -Name $section
        foreach ($key in $Document.Config.Sections[$section].Keys) {
            $kd = if ($null -ne $sd) { Get-EobSchemaKeyDefinition -SectionDefinition $sd -Key $key } else { $null }
            $value = [string]$Document.Config.Sections[$section][$key]
            if (($value -and (Test-EobEditorSecret -Key $key -Value $value -Definition $kd)) -or $value -match '[\r\n\x00]') {
                New-EobFinding -Severity Error -Code 'EDITOR_UNSAFE_VALUE' -Field "$section.$key" -Message 'Unsicherer Wert: Zugangsdaten oder Zeilenumbrüche entfernen.'
                return
            }
        }
    }
    if (Test-EobEditorSourceSecret -Text $Document.SourceText -Schema $Document.Config.Schema) {
        New-EobFinding -Severity Error -Code 'EDITOR_UNSAFE_SOURCE' -Message 'Zugangsdaten aus der Quelldatei entfernen und erneut öffnen.'
        return
    }
    # Nur Anforderungen an die zusammengeführte Anwendung zurückstellen, niemals lokale
    # Schemafehler oder Sicherheitsregeln wie Löschphase und Aufbewahrungsfrist.
    $applicationRequirements = @(
        'CFG_NO_COMPANY', 'CFG_COMPANY_NO_UPN', 'CFG_COMPANY_NO_OU', 'CFG_COMPANY_NO_MAIL',
        'CFG_NO_OFFBOARDING_TEMPLATE', 'CFG_MOVE_WITHOUT_OU', 'CFG_ARCHIVE_WITHOUT_ROOT',
        'CFG_DEFAULT_TEMPLATE_MISSING', 'CFG_HOME_WITHOUT_ROOTS', 'CFG_TEMPLATE_NOT_FOUND'
    )
    foreach ($finding in @(Test-EobConfiguration -Config $Document.Config)) {
        if ($Document.Fragment -and $finding.Code -in $applicationRequirements) { continue }
        if ($finding.Code -eq 'CFG_INVALID_VALUE') { $finding.Severity = 'Error' }
        $finding
    }
    if ($Document.Fragment) {
        New-EobFinding -Severity Information -Code 'EDITOR_FRAGMENT_MODE' -Message (
            'Fragmentmodus: Schema und lokale Sicherheitsregeln geprüft. Anwendungsweite Abhängigkeiten werden erst mit der zusammengeführten Hauptkonfiguration geprüft.')
    }
    $Document.SourceFindings
}

function Save-EobEditorDocument {
    <#
    .SYNOPSIS
        Speichert nach Prüfung atomar mit dem bestehenden INI-Schreiber; Warnungen erfordern Zustimmung.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][pscustomobject]$Document, [Parameter(Mandatory)][string]$Path,
        [switch]$AcceptWarnings)

    $findings = @(Test-EobEditorDocument -Document $Document)
    if (@($findings | Where-Object Severity -EQ 'Error').Count) { throw 'Speichern blockiert: Fehler in der Prüfung beheben.' }
    if (-not $AcceptWarnings -and @($findings | Where-Object Severity -EQ 'Warning').Count) {
        throw 'Warnungen prüfen und ausdrücklich bestätigen (-AcceptWarnings).'
    }
    $target = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if ([IO.Path]::GetExtension($target) -ine '.ini') { throw 'Bitte eine Zieldatei mit der Endung .ini wählen.' }
    if (-not (Test-Path -LiteralPath (Split-Path -Parent $target) -PathType Container)) {
        throw 'Das Zielverzeichnis existiert nicht. Bitte zuerst anlegen oder ein anderes Verzeichnis wählen.'
    }
    # Setup behandelt Werte vor dem ersten Abschnitt nicht; ein temporärer Global-Header erhält diese ebenfalls.
    $source = $Document.SourceText
    $hasGlobal = $Document.Config.Sections.Contains('Global')
    if ($hasGlobal) { $source = "[Global]`r`n" + $source }
    $text = ConvertTo-EobSetupIniText -TemplateText $source -Values $Document.Config.Sections
    if ($hasGlobal) { $text = $text -replace '^\[Global\]\r?\n', '' }
    if (-not $PSCmdlet.ShouldProcess($target, 'Geprüfte INI atomar speichern (mit Backup)')) { return }
    & (Get-Module easyONB.Configuration) {
        param($Destination, $Content)
        Write-EobTextFileAtomic -Path $Destination -Text $Content -Confirm:$false
    } $target $text
    $Document.Path = $target
    $Document.SourceText = $text
    $Document.Dirty = $false
}

function Start-EobConfigEditor {
    <#
    .SYNOPSIS
        Zeigt den unabhängigen deutschen WPF-Konfigurationseditor.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AppRoot, [string]$ConfigPath, [switch]$Fragment)

    if (-not $IsWindows -or [Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
        throw 'Windows/WPF und pwsh -STA sind erforderlich.'
    }
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    $window = [Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText((Join-Path $AppRoot 'GUI/Editors/ConfigEditor.xaml')))
    $controls = @{}
    foreach ($name in @('NewButton', 'OpenButton', 'ValidateButton', 'SaveButton', 'SaveAsButton', 'SectionList', 'SearchBox', 'FieldPanel', 'FindingsBox', 'FileLabel', 'StatusLabel')) {
        $controls[$name] = $window.FindName('ConfigEditor' + $name)
    }
    $state = @{ Document = $null; Rendering = $false }
    $template = Join-Path $AppRoot 'Config/easyONB.ini.template'
    $message = {
        param([string]$Text)
        $null = [Windows.MessageBox]::Show($window, $Text, 'Konfigurationsstudio', 'OK', 'Error')
    }
    $updateTitle = {
        $file = if ($state.Document.Path) { $state.Document.Path } else { 'Neue Konfiguration aus Vorlage' }
        $mode = if ($state.Document.Fragment) { 'FRAGMENT · Teilprüfung' } else { 'HAUPTKONFIGURATION · Vollprüfung' }
        $controls.FileLabel.Text = "$mode  •  $file" + $(if ($state.Document.Dirty) { '  • Nicht gespeichert' } else { '  • Gespeichert' })
    }
    $validate = {
        $findings = @(Test-EobEditorDocument -Document $state.Document)
        $controls.FindingsBox.Text = if ($findings.Count) {
            ($findings | ForEach-Object { "$($_.Severity) · $($_.Field): $($_.Message)" }) -join "`r`n"
        }
        else { 'Keine Fehler oder Warnungen. Die Konfiguration ist bereit zum Speichern.' }
        return $findings
    }
    $onValueChanged = {
        param($control, $change)
        $null = $change
        if ($state.Rendering) { return }
        try {
            Set-EobEditorValue -Document $state.Document -Section $control.Tag.Section -Key $control.Tag.Key -Value $control.Text
            & $updateTitle
        }
        catch { & $updateTitle; & $message $_.Exception.Message }
    }
    $render = {
        if ($state.Rendering -or $null -eq $state.Document) { return }
        $state.Rendering = $true
        try {
            $controls.FieldPanel.Children.Clear()
            $query = $controls.SearchBox.Text.Trim()
            $selected = [string]$controls.SectionList.SelectedItem
            $fields = @(Get-EobEditorField -Document $state.Document)
            foreach ($field in $fields) {
                if ($query) {
                    if ("$($field.Section) $($field.Key) $($field.Description)".IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
                }
                elseif ($field.Section -ne $selected) { continue }
                $card = [Windows.Controls.Border]::new()
                $card.CornerRadius = [Windows.CornerRadius]::new(10)
                $card.Padding = [Windows.Thickness]::new(18)
                $card.Margin = [Windows.Thickness]::new(0, 0, 0, 12)
                $card.SetResourceReference([Windows.Controls.Border]::BackgroundProperty, 'SurfaceBrush')
                $panel = [Windows.Controls.StackPanel]::new()
                $title = [Windows.Controls.TextBlock]::new()
                $title.Text = "$($field.Section)  /  $($field.Key)"
                $title.FontWeight = [Windows.FontWeights]::SemiBold
                $title.TextWrapping = 'Wrap'
                $panel.Children.Add($title) | Out-Null
                $hint = [Windows.Controls.TextBlock]::new()
                $hint.Text = $field.Description
                $hint.TextWrapping = 'Wrap'
                $hint.Margin = [Windows.Thickness]::new(0, 6, 0, 12)
                $hint.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'TextSecondaryBrush')
                $panel.Children.Add($hint) | Out-Null
                if ($field.Type -in @('Bool', 'Enum')) {
                    $editorControl = [Windows.Controls.ComboBox]::new()
                    $editorControl.IsEditable = $true
                    $options = if ($field.Type -eq 'Bool') { @('', '1', '0', 'True', 'False') } else { @('') + $field.Options }
                    foreach ($option in $options) { $null = $editorControl.Items.Add([string]$option) }
                    $editorControl.Text = $field.Value
                    $editorControl.Tag = $field
                    $editorControl.AddHandler([Windows.Controls.Primitives.TextBoxBase]::TextChangedEvent, [Windows.Controls.TextChangedEventHandler]$onValueChanged)
                }
                else {
                    $editorControl = [Windows.Controls.TextBox]::new()
                    $editorControl.Text = $field.Value
                    $editorControl.Tag = $field
                    $editorControl.Add_TextChanged($onValueChanged)
                }
                $editorControl.ToolTip = $field.Description
                $panel.Children.Add($editorControl) | Out-Null
                $card.Child = $panel
                $controls.FieldPanel.Children.Add($card) | Out-Null
            }
            if ($controls.FieldPanel.Children.Count -eq 0) {
                $empty = [Windows.Controls.TextBlock]::new()
                $empty.Text = 'Keine passenden Felder. Suche leeren oder anderen Bereich wählen.'
                $controls.FieldPanel.Children.Add($empty) | Out-Null
            }
        }
        finally { $state.Rendering = $false }
    }
    $load = {
        param([string]$Path, [bool]$New, [bool]$FragmentMode)
        # Erst vollständig laden; Fehler lassen das bisherige Dokument unverändert.
        $document = Import-EobEditorDocument -Path $Path -AsTemplate:$New -Fragment:$FragmentMode
        $state.Document = $document
        $state.Rendering = $true
        try {
            $controls.SectionList.Items.Clear()
            foreach ($section in @(Get-EobEditorField -Document $document | Select-Object -ExpandProperty Section -Unique)) {
                $null = $controls.SectionList.Items.Add($section)
            }
            $controls.SearchBox.Text = ''
            $controls.SectionList.SelectedIndex = 0
        }
        finally { $state.Rendering = $false }
        & $render
        & $updateTitle
        $null = & $validate
    }
    $save = {
        param([bool]$SaveAs)
        try {
            $findings = @(& $validate)
            if (@($findings | Where-Object Severity -EQ 'Error').Count) { & $message 'Bitte zuerst die Fehler im Prüfergebnis beheben.'; return $false }
            if (@($findings | Where-Object Severity -EQ 'Warning').Count) {
                $answer = [Windows.MessageBox]::Show($window, 'Bitte Warnungen im Prüfergebnis lesen. Trotzdem speichern?', 'Warnungen bestätigen', 'YesNo', 'Warning', 'No')
                if ($answer -ne 'Yes') { return $false }
            }
            $path = $state.Document.Path
            if ($SaveAs -or -not $path) {
                $dialog = [Microsoft.Win32.SaveFileDialog]::new()
                $dialog.Filter = 'INI-Konfiguration (*.ini)|*.ini'
                $dialog.DefaultExt = '.ini'
                $dialog.FileName = 'easyONB.ini'
                $dialog.OverwritePrompt = $true
                if ($dialog.ShowDialog($window) -ne $true) { return $false }
                $path = $dialog.FileName
            }
            Save-EobEditorDocument -Document $state.Document -Path $path -AcceptWarnings -Confirm:$false
            & $updateTitle
            $controls.StatusLabel.Text = 'Gespeichert · UTF-8 mit BOM · Bei Überschreiben wurde eine Sicherung angelegt.'
            return $true
        }
        catch { & $message $_.Exception.Message; return $false }
    }
    $canLeave = {
        if ($null -eq $state.Document -or -not $state.Document.Dirty) { return $true }
        $answer = [Windows.MessageBox]::Show($window, 'Änderungen vor dem Fortfahren speichern? Nein verwirft sie; Abbrechen bleibt im Editor.', 'Nicht gespeicherte Änderungen', 'YesNoCancel', 'Question', 'Cancel')
        if ($answer -eq 'Cancel') { return $false }
        if ($answer -eq 'Yes') { return (& $save $false) }
        return $true
    }
    $controls.SectionList.Add_SelectionChanged({ $null = & $render })
    $controls.SearchBox.Add_TextChanged({ $null = & $render })
    $controls.ValidateButton.Add_Click({ try { $null = & $validate } catch { & $message $_.Exception.Message } })
    $controls.SaveButton.Add_Click({ $null = & $save $false })
    $controls.SaveAsButton.Add_Click({ $null = & $save $true })
    $controls.NewButton.Add_Click({ try { if (& $canLeave) { & $load $template $true $false } } catch { & $message $_.Exception.Message } })
    $onOpen = {
        try {
            if (-not (& $canLeave)) { return }
            $dialog = [Microsoft.Win32.OpenFileDialog]::new()
            $dialog.Filter = 'INI-Konfiguration (*.ini)|*.ini|Alle Dateien (*.*)|*.*'
            if ($dialog.ShowDialog($window) -eq $true) { & $load $dialog.FileName $false $state.Document.Fragment }
        }
        catch { & $message $_.Exception.Message }
    }
    $controls.OpenButton.Add_Click($onOpen)
    $onClosing = {
        param($control, $closing)
        $null = $control
        try { if (-not (& $canLeave)) { $closing.Cancel = $true } }
        catch { $closing.Cancel = $true; & $message $_.Exception.Message }
    }
    $window.Add_Closing($onClosing)
    if ($ConfigPath) { & $load $ConfigPath $false ([bool]$Fragment) } else { & $load $template $true $false }
    $null = $window.ShowDialog()
}
