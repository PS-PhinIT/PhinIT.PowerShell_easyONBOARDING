#Requires -Version 7.2
<#
.SYNOPSIS
    Eigenständiges lokales Handout-Studio für Windows PowerShell 7.2+ (STA).
.PARAMETER Path
    Optionale lokale HTML-/TXT-Vorlage. Ohne Angabe wird die deutsche Vorlage geladen.
.PARAMETER Language
    Sprache der anfänglich geladenen ausgelieferten Vorlage (de/en).
.EXAMPLE
    pwsh -NoProfile -STA -File ./Start-easyONBOARDING.ReportEditor.ps1 -Language en
#>
[CmdletBinding()]
param(
    [Alias('TemplatePath')][string]$Path,
    [ValidateSet('de', 'en')][string]$Language = 'de'
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) { throw 'Das Handout-Studio benötigt Windows mit PowerShell 7.2 oder neuer.' }
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    throw 'Bitte mit pwsh -NoProfile -STA -File ./Start-easyONBOARDING.ReportEditor.ps1 starten.'
}
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
. (Join-Path $PSScriptRoot 'Modules/Editors/easyONB.ReportEditor.ps1')
Initialize-EobReportEditor -Root $PSScriptRoot

$xmlSettings = [Xml.XmlReaderSettings]::new()
$xmlSettings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
$xmlSettings.XmlResolver = $null
$reader = [Xml.XmlReader]::Create((Join-Path $PSScriptRoot 'GUI/Editors/ReportEditor.xaml'), $xmlSettings)
try { $script:EditorWindow = [Windows.Markup.XamlReader]::Load($reader) }
finally { $reader.Dispose() }
$script:EditorControls = @{}
foreach ($name in @('GermanButton', 'EnglishButton', 'NewButton', 'OpenButton', 'SaveButton', 'StyleButton', 'InsertButton',
        'PreviewButton', 'SourceInput', 'TitleInput', 'AccentInput', 'FontInput', 'SizeInput', 'MarginInput',
        'PlaceholderInput', 'PreviewTitle', 'PreviewText', 'PreviewAccent', 'PreviewSheet', 'WarningsText', 'StatusLabel', 'FileLabel')) {
    $control = $script:EditorWindow.FindName('ReportEd' + $name)
    if ($null -eq $control) { throw "Steuerelement fehlt: $name" }
    $script:EditorControls[$name] = $control
}
$script:EditorState = @{ Path = ''; Baseline = ''; Loading = $false }

function Show-EobEditorError {
    param([string]$Message)
    $script:EditorControls.StatusLabel.Text = 'Aktion fehlgeschlagen; Vorlage bleibt erhalten.'
    $null = [Windows.MessageBox]::Show($script:EditorWindow, $Message, 'Handout-Studio · Fehler', 'OK', 'Error')
}

function Update-EobEditorPreview {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Aktualisiert nur WPF-Texte im Speicher, keine Systemänderung.')]
    [CmdletBinding()]
    param()
    try {
        $preview = ConvertTo-EobEditorPreview -Template $script:EditorControls.SourceInput.Text
        $style = Get-EobEditorPreviewStyle -Template $script:EditorControls.SourceInput.Text
        $font = [Windows.Media.FontFamily]::new($style.Font)
        $accent = [Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString($style.Accent))
        $script:EditorControls.PreviewTitle.Text = $preview.Title
        $script:EditorControls.PreviewText.Text = $preview.Text
        $script:EditorControls.PreviewTitle.FontFamily = $font
        $script:EditorControls.PreviewTitle.FontSize = $style.TitleSizeDip
        $script:EditorControls.PreviewTitle.Foreground = $accent
        $script:EditorControls.PreviewText.FontFamily = $font
        $script:EditorControls.PreviewText.FontSize = $style.FontSizeDip
        $script:EditorControls.PreviewText.LineHeight = $style.LineHeightDip
        $script:EditorControls.PreviewAccent.BorderBrush = $accent
        $script:EditorControls.PreviewSheet.Padding = [Windows.Thickness]::new($style.Margin)
        $script:EditorControls.WarningsText.Text = $preview.Warnings -join "`n"
        $script:EditorControls.StatusLabel.Text = 'Vorschau aktualisiert · ausschließlich erfundene Beispielwerte.'
    }
    catch {
        $script:EditorControls.PreviewTitle.Text = ''
        $script:EditorControls.PreviewText.Text = ''
        $script:EditorControls.WarningsText.Text = 'Vorschau fehlgeschlagen: ' + $_.Exception.Message
    }
}

function Save-EobEditorDocument {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Speicherfunktion zeigt Dialoge und delegiert an die ShouldProcess-fähige Save-EobEditorTemplate.')]
    param()
    try {
        $check = Test-EobEditorTemplate -Template $script:EditorControls.SourceInput.Text
        if (-not $check.IsValid) { throw 'Keine Zugangsdaten eintragen. Secret-Platzhalter entfernen; PasswordPolicyList ist zulässig. Vorlagen dürfen höchstens 1 MiB groß sein.' }
        $dialog = [Microsoft.Win32.SaveFileDialog]::new()
        $dialog.Title = 'Handout-Vorlage speichern (keine Beispieldaten)'
        $dialog.Filter = 'HTML-Vorlagen (*.html;*.htm;*.txt)|*.html;*.htm;*.txt'
        $dialog.DefaultExt = '.html'
        $dialog.AddExtension = $true
        $dialog.OverwritePrompt = $true
        $dialog.FileName = if ($script:EditorState.Path) { [IO.Path]::GetFileName($script:EditorState.Path) } else { 'Willkommen.html' }
        if ($dialog.ShowDialog($script:EditorWindow) -ne $true) { return $false }
        Save-EobEditorTemplate -Path $dialog.FileName -Template $script:EditorControls.SourceInput.Text -Overwrite -Confirm:$false
        $script:EditorState.Path = $dialog.FileName
        $script:EditorState.Baseline = $script:EditorControls.SourceInput.Text
        $script:EditorControls.FileLabel.Text = $dialog.FileName
        $script:EditorWindow.Title = 'easyONBOARDING · Handout-Studio'
        $script:EditorControls.StatusLabel.Text = 'Vorlage gespeichert · UTF-8 mit BOM · keine Vorschauwerte.'
        return $true
    }
    catch { Show-EobEditorError -Message $_.Exception.Message; return $false }
}

function Confirm-EobEditorDiscard {
    if ($script:EditorControls.SourceInput.Text -ceq $script:EditorState.Baseline) { return $true }
    $answer = [Windows.MessageBox]::Show($script:EditorWindow, 'Änderungen vor dem Fortfahren speichern?', 'Ungespeicherte Vorlage', 'YesNoCancel', 'Warning')
    if ($answer -eq 'Cancel') { return $false }
    if ($answer -eq 'Yes') { return (Save-EobEditorDocument) }
    return $true
}

function Open-EobEditorDocument {
    param([string]$FilePath, [switch]$New)
    try {
        # Read before prompting so an unreadable file never replaces a valid document.
        $content = if ($New) { New-EobEditorTemplate } else { Read-EobEditorTemplate -Path $FilePath }
        if (-not (Confirm-EobEditorDiscard)) { return }
        $script:EditorState.Loading = $true
        $script:EditorState.Path = if ($New) { '' } else { [IO.Path]::GetFullPath($FilePath) }
        $script:EditorState.Baseline = if ($New) { '' } else { $content }
        $script:EditorControls.SourceInput.Text = $content
        $title = [regex]::Match($content, '(?is)<title\b[^>]*>(.*?)</title\s*>').Groups[1].Value
        $script:EditorControls.TitleInput.Text = [Net.WebUtility]::HtmlDecode($title)
        $style = Get-EobEditorStyle -Template $content
        $script:EditorControls.AccentInput.Text = $style.Accent
        $script:EditorControls.FontInput.SelectedIndex = @('Segoe UI', 'Arial', 'Calibri', 'Georgia').IndexOf($style.Font)
        $script:EditorControls.SizeInput.Text = [string]$style.FontSize
        $script:EditorControls.MarginInput.Text = [string]$style.Margin
        $script:EditorControls.FileLabel.Text = if ($New) { 'Neue Vorlage · noch nicht gespeichert' } else { $script:EditorState.Path }
        $script:EditorWindow.Title = 'easyONBOARDING · Handout-Studio' + $(if ($New) { ' · Ungespeichert *' } else { '' })
        Update-EobEditorPreview
    }
    catch { Show-EobEditorError -Message $_.Exception.Message }
    finally { $script:EditorState.Loading = $false }
}

function Show-EobEditorOpenDialog {
    try {
        $dialog = [Microsoft.Win32.OpenFileDialog]::new()
        $dialog.Title = 'Lokale Handout-Vorlage öffnen'
        $dialog.Filter = 'HTML-/Textvorlagen (*.html;*.htm;*.txt)|*.html;*.htm;*.txt|Alle Dateien (*.*)|*.*'
        if ($dialog.ShowDialog($script:EditorWindow) -eq $true) { Open-EobEditorDocument -FilePath $dialog.FileName }
    }
    catch { Show-EobEditorError -Message $_.Exception.Message }
}

foreach ($placeholder in ((Get-EobEditorPlaceholder).Keys | Sort-Object)) {
    $null = $script:EditorControls.PlaceholderInput.Items.Add('{{' + $placeholder + '}}')
}
$null = $script:EditorControls.PlaceholderInput.Items.Add('{{AssetDataUri:Report/welcome-header.png}}')
$script:EditorControls.PlaceholderInput.SelectedIndex = 0
$script:EditorControls.GermanButton.Add_Click({ Open-EobEditorDocument -FilePath (Join-Path $PSScriptRoot 'ReportTemplates/HTMLTemplate.txt') })
$script:EditorControls.EnglishButton.Add_Click({ Open-EobEditorDocument -FilePath (Join-Path $PSScriptRoot 'ReportTemplates/HTMLTemplateENG.txt') })
$script:EditorControls.NewButton.Add_Click({ Open-EobEditorDocument -New })
$script:EditorControls.OpenButton.Add_Click({ Show-EobEditorOpenDialog })
$script:EditorControls.SaveButton.Add_Click({ $null = Save-EobEditorDocument })
$script:EditorControls.PreviewButton.Add_Click({ Update-EobEditorPreview })
$script:EditorControls.InsertButton.Add_Click({
        if ($null -ne $script:EditorControls.PlaceholderInput.SelectedItem) {
            $script:EditorControls.SourceInput.SelectedText = [string]$script:EditorControls.PlaceholderInput.SelectedItem
            $null = $script:EditorControls.SourceInput.Focus()
        }
    })
$script:EditorControls.StyleButton.Add_Click({
        try {
            $script:EditorControls.SourceInput.Text = Set-EobEditorStyle -Template $script:EditorControls.SourceInput.Text `
                -Title $script:EditorControls.TitleInput.Text -Accent $script:EditorControls.AccentInput.Text `
                -Font ([string]$script:EditorControls.FontInput.SelectedItem.Content) -FontSize ([int]$script:EditorControls.SizeInput.Text) `
                -Margin ([int]$script:EditorControls.MarginInput.Text)
            Update-EobEditorPreview
        }
        catch { Show-EobEditorError -Message $_.Exception.Message }
    })
$script:EditorControls.SourceInput.Add_TextChanged({
        if (-not $script:EditorState.Loading) {
            $dirty = $script:EditorControls.SourceInput.Text -cne $script:EditorState.Baseline
            $script:EditorWindow.Title = 'easyONBOARDING · Handout-Studio' + $(if ($dirty) { ' · Ungespeichert *' } else { '' })
            $script:EditorControls.StatusLabel.Text = 'Quelltext geändert · F5 aktualisiert die Vorschau. Keine Zugangsdaten eintragen.'
        }
    })
$script:EditorWindow.Add_Closing({
        param($windowSender, $closingEvent)
        $null = $windowSender
        if (-not (Confirm-EobEditorDiscard)) { $closingEvent.Cancel = $true }
    })
$script:EditorWindow.Add_PreviewKeyDown({
        param($windowSender, $keyEvent)
        $null = $windowSender
        $modifiers = [Windows.Input.Keyboard]::Modifiers
        if ($keyEvent.Key -eq 'F5') { Update-EobEditorPreview; $keyEvent.Handled = $true }
        elseif (($modifiers -band [Windows.Input.ModifierKeys]::Control) -ne 0) {
            switch ([string]$keyEvent.Key) {
                'O' { Show-EobEditorOpenDialog; $keyEvent.Handled = $true }
                'N' { Open-EobEditorDocument -New; $keyEvent.Handled = $true }
                'S' { $null = Save-EobEditorDocument; $keyEvent.Handled = $true }
            }
        }
    })

if (-not $Path) {
    $Path = Join-Path $PSScriptRoot $(if ($Language -eq 'en') { 'ReportTemplates/HTMLTemplateENG.txt' } else { 'ReportTemplates/HTMLTemplate.txt' })
}
Open-EobEditorDocument -FilePath $Path
$null = $script:EditorWindow.ShowDialog()
