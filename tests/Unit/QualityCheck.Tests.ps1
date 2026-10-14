#Requires -Version 7.2
BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath '../TestHelpers.ps1')
    $script:AppRoot = Get-EobTestRepoRoot
    $script:QualityScript = Join-Path -Path $script:AppRoot -ChildPath 'Scripts/Invoke-EobQualityCheck.ps1'

    function New-QualityTestRoot {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Testhilfe im TestDrive.')]
        param()
        $root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        foreach ($folder in @('Modules/Demo', 'Config', 'docs', 'GUI')) {
            $null = New-Item -ItemType Directory -Path (Join-Path -Path $root -ChildPath $folder) -Force
        }
        Set-Content -LiteralPath (Join-Path $root 'VERSION') -Value '3.0.0' -Encoding utf8NoBOM
        return $root
    }

    function Write-QualityTestFile {
        param([string]$Root, [string]$Path, [string]$Content, [switch]$NoBom)
        $encoding = [System.Text.UTF8Encoding]::new(-not $NoBom)
        [System.IO.File]::WriteAllText((Join-Path -Path $Root -ChildPath $Path), $Content, $encoding)
    }
}

Describe 'Qualitätsprüfung (Scripts/Invoke-EobQualityCheck.ps1)' {
    It 'erkennt Syntaxfehler, fehlendes BOM, Tabulatoren und abweichende Versionen' {
        $root = New-QualityTestRoot
        Write-QualityTestFile -Root $root -Path 'Modules/Demo/Demo.psm1' -Content "function Test-Demo {`n    if (`$true) {`n}`n"
        Write-QualityTestFile -Root $root -Path 'Modules/Demo/Ohne.ps1' -Content "Write-Output 'Umlaut: ä'`n`tWrite-Output 'x'`n" -NoBom
        Write-QualityTestFile -Root $root -Path 'Modules/Demo/Demo.psd1' -Content ("@{ ModuleVersion = '2.9.0'; RootModule = 'Demo.psm1' }" + [System.Environment]::NewLine)
        $findings = @(& $script:QualityScript -Root $root -Check Parser, Encoding, Version -PassThru)
        @($findings | Where-Object { $_.Check -eq 'Parser' -and $_.File -eq 'Modules/Demo/Demo.psm1' }).Count | Should -BeGreaterThan 0
        @($findings | Where-Object { $_.Check -eq 'Encoding' -and $_.Message -match 'BOM' }).File | Should -Contain 'Modules/Demo/Ohne.ps1'
        @($findings | Where-Object { $_.Check -eq 'Encoding' -and $_.Message -match 'Tabulator' }).Line | Should -Contain 2
        ($findings | Where-Object Check -EQ 'Version').Message | Should -Match '2\.9\.0'
    }

    It 'erkennt Geheimnisse, Platzhalter und reale Domains in Beispieldateien' {
        $root = New-QualityTestRoot
        # Die Testinhalte werden zusammengesetzt, damit der Scan dieses Repositorys nicht anschlägt.
        $keyHeader = '-----BEGIN ' + 'RSA PRIVATE KEY-----'
        $placeholder = 'support@yo' + 'urdomain.com'
        Write-QualityTestFile -Root $root -Path 'Config/demo.ini.template' -Content ("[EmailSettings]`nSMTP" + "Password=Geheim123`nAllowManualPassword=1`nAction.ResetPassword=ExitDate`nFromAddress=it@firma-beispiel.de`n")
        Write-QualityTestFile -Root $root -Path 'docs/Hinweis.md' -Content "# Hinweis`n`nKontakt: $placeholder`n"
        Write-QualityTestFile -Root $root -Path 'Modules/Demo/Key.txt' -Content "$keyHeader`nabc`n"
        Write-QualityTestFile -Root $root -Path 'Modules/Demo/Code.ps1' -Content ("`$smtp" + "Password = 'Sommer2026!'`n`$x = ConvertTo-" + "SecureString -String 'a' -AsPlainText -Force`n")
        $findings = @(& $script:QualityScript -Root $root -Check Secrets -PassThru)
        $messages = $findings | ForEach-Object { "$($_.File)|$($_.Message)" }
        ($messages -join "`n") | Should -Match 'demo\.ini\.template\|Konfigurationsschlüssel .SMTPPassword.'
        ($messages -join "`n") | Should -Match 'demo\.ini\.template\|Beispieldatei enthält eine nicht reservierte Domain: .firma-beispiel\.de.'
        ($messages -join "`n") | Should -Match 'Hinweis\.md\|Platzhalter gefunden'
        ($messages -join "`n") | Should -Match 'Key\.txt\|Mögliches Geheimnis: Privater Schlüssel'
        ($messages -join "`n") | Should -Match 'Code\.ps1\|Fest codierter Kennwort'
        ($messages -join "`n") | Should -Match 'Code\.ps1\|ConvertTo-SecureString -AsPlainText'
        # Schalter wie AllowManualPassword=1 oder Action.ResetPassword=ExitDate sind keine Geheimnisse.
        @($findings | Where-Object { $_.Message -match 'AllowManualPassword|Action\.ResetPassword' }).Count | Should -Be 0
    }

    It 'erkennt Code-Behind in XAML und ungültige Markdown-Links' {
        $root = New-QualityTestRoot
        Write-QualityTestFile -Root $root -Path 'GUI/Test.xaml' -Content '<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" x:Class="A.B"><Button Click="OnClick" /></Window>'
        Write-QualityTestFile -Root $root -Path 'docs/Links.md' -Content "# Links`n`n[fehlt](Nicht/Vorhanden.md) [ok](../VERSION) [extern](https://example.com)`n"
        $findings = @(& $script:QualityScript -Root $root -Check Xaml, Docs -PassThru)
        ($findings | Where-Object Check -EQ 'Xaml').Message -join ' ' | Should -Match 'x:Class'
        ($findings | Where-Object Check -EQ 'Xaml').Message -join ' ' | Should -Match 'Click'
        @($findings | Where-Object { $_.Check -eq 'Docs' -and $_.Message -match 'Link-Ziel' }).Count | Should -Be 1
        @($findings | Where-Object { $_.Check -eq 'Docs' -and $_.Message -match 'Pflichtdokument' }).Count | Should -BeGreaterThan 5
    }

    It 'lehnt unbekannte Prüfungen ab und akzeptiert kommagetrennte Listen' {
        { & $script:QualityScript -Root (New-QualityTestRoot) -Check 'Parser,Unbekannt' -PassThru } | Should -Throw '*Unbekannt*'
        @(& $script:QualityScript -Root (New-QualityTestRoot) -Check 'Parser,Version' -PassThru).Count | Should -Be 0
    }

    It 'verlangt Architektur als eigenes Dokument oder Abschnitt im Beitragsleitfaden' {
        $root = New-QualityTestRoot
        Write-QualityTestFile -Root $root -Path 'CONTRIBUTING.md' -Content "# Beiträge`n"
        $findings = @(& $script:QualityScript -Root $root -Check Docs -PassThru)
        @($findings | Where-Object Message -Match 'Pflichtdokument zur Architektur').Count | Should -Be 1
        Write-QualityTestFile -Root $root -Path 'CONTRIBUTING.md' -Content "# Beiträge`n`n## Architektur`n`nModulgrenzen und Ausführung.`n"
        $findings = @(& $script:QualityScript -Root $root -Check Docs -PassThru)
        @($findings | Where-Object Message -Match 'Pflichtdokument zur Architektur').Count | Should -Be 0
    }

    It 'das Repository besteht die statischen Prüfungen (ohne PSScriptAnalyzer)' {
        $findings = @(& $script:QualityScript -Root $script:AppRoot -Check Parser, Encoding, Xaml, Secrets, Docs, Version -PassThru)
        @($findings | ForEach-Object { "[$($_.Check)] $($_.File):$($_.Line) $($_.Message)" }) | Should -BeNullOrEmpty
    }
}
