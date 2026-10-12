#Requires -Version 7.2
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.3.0' }
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:EditorRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $script:EditorRoot 'Modules/Editors/easyONB.ReportEditor.ps1')
    Initialize-EobReportEditor -Root $script:EditorRoot
}

Describe 'Handout-Studio: Vorlagendateien' {
    It 'liest UTF-8 mit und ohne BOM sowie UTF-16 BOM verlustfrei' {
        foreach ($encoding in @([Text.UTF8Encoding]::new($true), [Text.UTF8Encoding]::new($false), [Text.Encoding]::Unicode)) {
            $path = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.txt')
            [IO.File]::WriteAllText($path, '<p>Grüße für {{Vorname}} — €</p>', $encoding)
            Read-EobEditorTemplate -Path $path | Should -BeExactly '<p>Grüße für {{Vorname}} — €</p>'
        }
    }

    It 'schreibt nur Quelltext in UTF-8 BOM und verlangt explizites Überschreiben' {
        $path = Join-Path $TestDrive 'Vorlage.html'
        $template = '<p>Grüße {{Vorname}}</p>'
        Save-EobEditorTemplate -Path $path -Template $template -Confirm:$false
        $bytes = [IO.File]::ReadAllBytes($path)
        ($bytes[0..2] -join ',') | Should -BeExactly '239,187,191'
        Read-EobEditorTemplate -Path $path | Should -BeExactly $template
        { Save-EobEditorTemplate -Path $path -Template 'ersetzt' -Confirm:$false } | Should -Throw '*bestätigt*'
        Save-EobEditorTemplate -Path $path -Template 'ersetzt' -Overwrite -Confirm:$false
        Read-EobEditorTemplate -Path $path | Should -BeExactly 'ersetzt'
        @(Get-ChildItem $TestDrive -Filter '*.new').Count | Should -Be 0
    }

    It 'respektiert WhatIf und verweigert Netzwerkpfade und übergroße Inhalte' {
        $path = Join-Path $TestDrive 'whatif.html'
        Save-EobEditorTemplate -Path $path -Template 'Text' -WhatIf
        Test-Path $path | Should -BeFalse
        { Read-EobEditorTemplate -Path '\\example.com\share\template.html' } | Should -Throw '*lokale*'
        { Save-EobEditorTemplate -Path '\\example.com\share\template.html' -Template 'Text' } | Should -Throw '*lokale*'
        { ConvertTo-EobEditorPreview -Template ('x' * (1MB + 1)) } | Should -Throw '*1 MiB*'
    }

    It 'verweigert ungültiges UTF-8 ohne BOM, fehlende und zu große Dateien' {
        $path = Join-Path $TestDrive 'invalid.txt'
        [IO.File]::WriteAllBytes($path, [byte[]]@(255, 255, 255))
        { Read-EobEditorTemplate -Path $path } | Should -Throw
        { Read-EobEditorTemplate -Path (Join-Path $TestDrive 'missing.html') } | Should -Throw
        [IO.File]::WriteAllText($path, ('x' * (1MB + 1)))
        { Read-EobEditorTemplate -Path $path } | Should -Throw '*1 MiB*'
    }

    It 'verweigert symbolische Vorlagendateien vor dem Lesen oder Überschreiben' -Skip:$IsWindows {
        $target = Join-Path $TestDrive 'target.html'
        $link = Join-Path $TestDrive 'link.html'
        [IO.File]::WriteAllText($target, 'unverändert')
        $null = New-Item -ItemType SymbolicLink -Path $link -Target $target
        { Read-EobEditorTemplate -Path $link } | Should -Throw '*Reparse*'
        { Save-EobEditorTemplate -Path $link -Template 'ersetzt' -Overwrite -Confirm:$false } | Should -Throw '*Reparse*'
        [IO.File]::ReadAllText($target) | Should -BeExactly 'unverändert'
    }
}

Describe 'Handout-Studio: Geheimnisse und echte Template-API' {
    It 'verweigert Secret-Platzhalter einschließlich Labels: <Name>' -ForEach @(
        @{ Name = 'Passwort' }, @{ Name = 'Password' }, @{ Name = 'CustomPWLabel1' },
        @{ Name = 'CompanyVPNPassword' }, @{ Name = 'Kennwort' }, @{ Name = 'ClientSecret' },
        @{ Name = 'AccessToken' }, @{ Name = 'ApiKey' }, @{ Name = 'pwd' }
    ) {
        $template = '<p>{{ ' + $Name + ' }}</p>'
        (Test-EobEditorTemplate -Template $template).IsValid | Should -BeFalse
        { Save-EobEditorTemplate -Path (Join-Path $TestDrive 'secret.html') -Template $template -Confirm:$false } | Should -Throw '*verweigert*'
        Test-Path (Join-Path $TestDrive 'secret.html') | Should -BeFalse
    }

    It 'erlaubt Kennwortkriterien, meldet echte fehlende und Secret-Platzhalter' {
        $preview = ConvertTo-EobEditorPreview -Template '<title>{{ReportTitle}}</title><p>{{Vorname}} {{Missing}} {{Password}}</p><ul>{{PasswordPolicyList}}</ul>'
        $preview.Text | Should -Match 'Alex'
        $preview.Text | Should -Match 'mindestens 12 Zeichen'
        ($preview.Warnings -join ' ') | Should -Match 'Missing'
        ($preview.Warnings -join ' ') | Should -Match 'Password'
        $preview.CanSave | Should -BeFalse
        (Test-EobEditorTemplate -Template '<ul>{{PasswordPolicyList}}</ul>').IsValid | Should -BeTrue
    }

    It 'blockiert erkennbare Klartext-Zugangsdaten und zeigt sie nicht in der Vorschau' {
        $value = [guid]::NewGuid().ToString('N')
        $template = '<p>password=' + $value + '</p>'
        (Test-EobEditorTemplate -Template $template).HasSensitiveText | Should -BeTrue
        (ConvertTo-EobEditorPreview -Template $template).Text | Should -Not -Match $value
        { Save-EobEditorTemplate -Path (Join-Path $TestDrive 'literal.html') -Template $template -Confirm:$false } | Should -Throw
    }

    It 'prüft auch Attribute und HTML-kodierte Zugangsdaten ohne sie zu speichern' {
        $value = [guid]::NewGuid().ToString('N')
        $attribute = '<div data-password=' + [char]34 + $value + [char]34 + '>Text</div>'
        (Test-EobEditorTemplate -Template $attribute).IsValid | Should -BeFalse
        $encoded = '<p>password&#61;' + $value + '</p>'
        (Test-EobEditorTemplate -Template $encoded).IsValid | Should -BeFalse
        (ConvertTo-EobEditorPreview -Template $encoded).Text | Should -Not -Match $value
    }

    It 'verweigert inline formatierte und entity-kodierte Zugangsdaten ohne vorhandene Dateien zu verändern' {
        $value = [guid]::NewGuid().ToString('N')
        $encodedValue = ($value.ToCharArray() | ForEach-Object { '&#' + [int][char]$_ + ';' }) -join ''
        $templates = @(
            '<p>Passwort: <strong>' + $value + '</strong></p>'
            '<p><span>Pa&#115;swort</span>&#58; <em>' + $encodedValue + '</em></p>'
            '<div><span>Pass</span><b>wort</b>:<span>' + $value + '</span></div>'
            '<p>Token&#61;<i>' + $encodedValue + '</i></p>'
        )
        $path = Join-Path $TestDrive 'styled-credentials.html'
        Save-EobEditorTemplate -Path $path -Template '<p>Unverändert</p>' -Confirm:$false
        foreach ($template in $templates) {
            $check = Test-EobEditorTemplate -Template $template
            $check.HasSensitiveText | Should -BeTrue
            $check.IsValid | Should -BeFalse
            (ConvertTo-EobEditorPreview -Template $template).CanSave | Should -BeFalse
            { Save-EobEditorTemplate -Path $path -Template $template -Overwrite -Confirm:$false } | Should -Throw '*verweigert*'
            Read-EobEditorTemplate -Path $path | Should -BeExactly '<p>Unverändert</p>'
        }
        @(Get-ChildItem $TestDrive -Filter '*.new').Count | Should -Be 0
    }

    It 'erlaubt leere Zugangsdaten-Beschriftungen an Blockgrenzen ohne den Folgeabsatz als Wert zu behandeln' {
        $template = '<p>Passwort: <strong></strong></p><p>Nächster Hinweis ohne Zugangsdaten.</p><div>Token: <em>&nbsp;</em></div><div>Weitere Informationen.</div>'
        $check = Test-EobEditorTemplate -Template $template
        $check.HasSensitiveText | Should -BeFalse
        $check.IsValid | Should -BeTrue
        $path = Join-Path $TestDrive 'blank-labels.html'
        Save-EobEditorTemplate -Path $path -Template $template -Confirm:$false
        Read-EobEditorTemplate -Path $path | Should -BeExactly $template
    }

    It 'nutzt die bestehende HTML-Kodierung und ersetzt niemals Regex-Dollarzeichen im Titel' {
        $expanded = Expand-EobTemplate -Template '<p>{{Name}}</p>' -Values @{ Name = '<>&"$1' }
        $expanded.Content | Should -BeExactly '<p>&lt;&gt;&amp;&quot;$1</p>'
        $styled = Set-EobEditorStyle -Template '<head><title>Alt</title></head><p>{{Vorname}}</p>' -Title '<&$1>'
        $styled | Should -Match '<title>&lt;&amp;\$1&gt;</title>'
        (ConvertTo-EobEditorPreview -Template $styled).Title | Should -BeExactly '<&$1>'
    }

    It 'rendert beide ausgelieferten Vorlagen ohne fehlende Beispielwerte oder echte Identität' {
        foreach ($name in @('HTMLTemplate.txt', 'HTMLTemplateENG.txt')) {
            $preview = ConvertTo-EobEditorPreview -Template (Read-EobEditorTemplate -Path (Join-Path $script:EditorRoot "ReportTemplates/$name"))
            $preview.Text | Should -Match 'Alex'
            $preview.Text | Should -Match 'example.com'
            $preview.CanSave | Should -BeTrue
            ($preview.Warnings -join ' ') | Should -Not -Match 'Fehlende|Secret'
        }
    }

    It 'bietet UPN und Ablaufdatum mit erfundenen Beispielwerten an' {
        $values = Get-EobEditorPlaceholder
        $values.UPN | Should -BeExactly 'alex.beispiel@example.com'
        $values.Ablaufdatum | Should -BeExactly '31.12.2026'
        $preview = ConvertTo-EobEditorPreview -Template '<p>{{UPN}} · {{Ablaufdatum}}</p>'
        $preview.Text | Should -BeExactly 'alex.beispiel@example.com · 31.12.2026'
        $preview.Warnings | Should -BeNullOrEmpty
    }
}

Describe 'Handout-Studio: inaktive Vorschau' {
    It 'lädt weder Assets noch remote/file-Ressourcen und behandelt jedes Ergebnis nur als Text' {
        Mock Get-EobAssetDataUri { throw 'Asset loader must not be called' }
        $template = @'
<head><style>@import url(https://example.com/remote.css);</style></head>
<script>throw "execute";</script>
<iframe src="file:///C:/private"></iframe>
<object data="https://example.com/payload"></object>
<svg onload="execute()"></svg>
<img src="{{AssetDataUri:../../private}}" onerror="execute()">
<img src="file:///C:/private"><img src="https://example.com/image">
<a href="javascript:execute()">Linktext</a><p onclick="execute()">Hallo {{Vorname}}</p>
<p>&lt;script&gt;inaktiver Text&lt;/script&gt;</p>
'@
        $preview = ConvertTo-EobEditorPreview -Template $template
        $preview.Text | Should -Match 'Linktext'
        $preview.Text | Should -Match 'Hallo Alex'
        $preview.Text | Should -Not -Match 'throw|private|onerror|remote.css'
        $preview.Text | Should -Match '<script>inaktiver Text</script>'
        Should -Invoke Get-EobAssetDataUri -Times 0 -Exactly
    }

    It 'verwendet im tatsächlichen Launcher keine HTML-/Browser-/Bildnavigation' {
        $source = Get-Content (Join-Path $script:EditorRoot 'Start-easyONBOARDING.ReportEditor.ps1') -Raw
        $source | Should -Not -Match 'WebBrowser|NavigateToString|Start-Process|Invoke-Expression|BitmapImage'
        $source | Should -Match 'PreviewText.Text = \$preview.Text'
        $source | Should -Not -Match 'Import-EobModuleSet|ActiveDirectory|Entra|Exchange'
        $source | Should -Match "\[Alias\('TemplatePath'\)\]"
    }
}

Describe 'Handout-Studio: grafische Gestaltung und XAML' {
    It 'aktualisiert genau einen CSS-Block idempotent und erhält Inhalte/Platzhalter' {
        $original = New-EobEditorTemplate
        $styled = Set-EobEditorStyle -Template $original -Accent '#0F766E' -Font Georgia -FontSize 15 -Margin 30
        $again = Set-EobEditorStyle -Template $styled -Accent '#0F766E' -Font Georgia -FontSize 15 -Margin 30
        $again | Should -BeExactly $styled
        [regex]::Matches($again, '<style id="easyonb-editor">').Count | Should -Be 1
        $again | Should -Match 'font-size: 15pt'
        $again | Should -Match 'margin: 30px'
        $again | Should -Match '\{\{Vorname\}\}'
        $again | Should -Match '\{\{PasswordPolicyList\}\}'
        (Test-EobEditorTemplate -Template $again).IsValid | Should -BeTrue
    }

    It 'verweigert CSS-Injektion und ungültige Gestaltungswerte' {
        { Set-EobEditorStyle -Template '' -Accent '#fff;url(example.com)' } | Should -Throw
        { Set-EobEditorStyle -Template '' -Font 'Bad; CSS' } | Should -Throw
        { Set-EobEditorStyle -Template '' -FontSize 100 } | Should -Throw
        { Set-EobEditorStyle -Template '' -Margin 0 } | Should -Throw
    }

    It 'liest gespeicherte Gestaltungswerte und ignoriert fremde oder ungültige CSS-Werte' {
        $styled = Set-EobEditorStyle -Template (New-EobEditorTemplate) -Accent '#ABCDEF' -Font Georgia -FontSize 15 -Margin 30
        $settings = Get-EobEditorStyle -Template $styled
        $settings.Accent | Should -BeExactly '#ABCDEF'
        $settings.Font | Should -BeExactly 'Georgia'
        $settings.FontSize | Should -Be 15
        $settings.Margin | Should -Be 30
        (Get-EobEditorStyle -Template '<style>font-size: 99pt; margin: 99px;</style>').FontSize | Should -Be 12
    }

    It 'wendet validierte Schrift, Größe, Akzent und Rand sichtbar auf die native WPF-Vorschau an' {
        $styled = Set-EobEditorStyle -Template (New-EobEditorTemplate) -Accent '#ABCDEF' -Font Georgia -FontSize 15 -Margin 30
        $previewStyle = Get-EobEditorPreviewStyle -Template $styled
        $previewStyle.Accent | Should -BeExactly '#ABCDEF'
        $previewStyle.Font | Should -BeExactly 'Georgia'
        $previewStyle.FontSizeDip | Should -Be 20
        $previewStyle.TitleSizeDip | Should -Be 28
        $previewStyle.LineHeightDip | Should -Be 30
        $previewStyle.Margin | Should -Be 30
        $source = Get-Content (Join-Path $script:EditorRoot 'Start-easyONBOARDING.ReportEditor.ps1') -Raw
        foreach ($assignment in @('PreviewTitle.FontFamily', 'PreviewTitle.Foreground', 'PreviewText.FontFamily', 'PreviewText.FontSize',
                'PreviewText.LineHeight', 'PreviewAccent.BorderBrush', 'PreviewSheet.Padding')) {
            $source | Should -Match ([regex]::Escape($assignment) + ' = ')
        }
    }

    It 'enthält alle Launcher-Steuerelemente, ausschließlich Ressourcenfarben und keine Ereignisse' {
        $path = Join-Path $script:EditorRoot 'GUI/Editors/ReportEditor.xaml'
        [xml]$xaml = Get-Content $path -Raw
        $names = @($xaml.SelectNodes('//*[@*[local-name()="Name"]]') | ForEach-Object { $_.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml') })
        foreach ($name in @('GermanButton', 'EnglishButton', 'NewButton', 'OpenButton', 'SaveButton', 'StyleButton', 'InsertButton',
                'PreviewButton', 'SourceInput', 'TitleInput', 'AccentInput', 'FontInput', 'SizeInput', 'MarginInput',
                'PlaceholderInput', 'PreviewTitle', 'PreviewText', 'PreviewAccent', 'PreviewSheet', 'WarningsText', 'StatusLabel', 'FileLabel')) {
            $names | Should -Contain ('ReportEd' + $name)
        }
        $xaml.OuterXml | Should -Not -Match 'x:Class=| Click=| Loaded=| Closing=| TextChanged=|WebBrowser|<Image'
        $xaml.OuterXml | Should -Not -Match '(Background|Foreground|BorderBrush)="#'
        $xaml.SelectSingleNode('//*[@*[local-name()="Name"]="ReportEdTitleInput"]').GetAttribute('Text') | Should -BeExactly '{}{{ReportTitle}}'
    }

    It 'lädt die tatsächliche XAML unter Windows in einem STA-Runspace ohne Anzeige' -Skip:(-not $IsWindows) {
        $runspace = [RunspaceFactory]::CreateRunspace()
        $runspace.ApartmentState = 'STA'
        $runspace.ThreadOptions = 'ReuseThread'
        $runspace.Open()
        $powershell = [PowerShell]::Create()
        $powershell.Runspace = $runspace
        try {
            $null = $powershell.AddScript({
                    param($path)
                    Add-Type -AssemblyName PresentationFramework
                    $reader = [Xml.XmlReader]::Create($path)
                    try {
                        $window = [Windows.Markup.XamlReader]::Load($reader)
                        $window.FindName('ReportEdPreviewText').GetType().Name
                        $window.Close()
                    }
                    finally { $reader.Dispose() }
                }).AddArgument((Join-Path $script:EditorRoot 'GUI/Editors/ReportEditor.xaml'))
            $output = $powershell.Invoke()
            $powershell.HadErrors | Should -BeFalse
            $output | Should -Contain 'TextBlock'
        }
        finally { $powershell.Dispose(); $runspace.Dispose() }
    }
}
