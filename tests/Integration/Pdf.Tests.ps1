#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.3.0' }
<#
    Integrationstest der PDF-Erzeugung mit einem echten Browser.
    - Windows: Microsoft Edge aus dem Standard-Installationspfad (z. B. GitHub-Runner windows-latest).
    - Linux (Entwicklungscontainer): Chromium unter /opt/pw-browsers. Chromium verwendet dieselben
      Headless-Parameter wie Edge. Weil der Container als root läuft, startet ein Test-Wrapper
      Chromium mit --no-sandbox; der Produktivcode deaktiviert die Sandbox nie.
    Ohne Browser wird der Test übersprungen.
#>

BeforeDiscovery {
    $script:BrowserPath = ''
    if ($IsWindows) {
        foreach ($base in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
            if (-not $base) { continue }
            $candidate = Join-Path -Path $base -ChildPath 'Microsoft\Edge\Application\msedge.exe'
            if (Test-Path -LiteralPath $candidate) { $script:BrowserPath = $candidate; break }
        }
    }
    elseif (Test-Path -LiteralPath '/opt/pw-browsers/chromium') {
        $script:BrowserPath = '/opt/pw-browsers/chromium'
    }
}

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath '../TestHelpers.ps1')
    Import-EobTestModule
    $null = Initialize-EobLogging -Directory (Join-Path $TestDrive 'logs')
}

Describe 'PDF-Erzeugung mit Browser' -Tag 'Integration' {
    BeforeAll {
        $browser = $script:BrowserPath
        if (-not $browser) {
            foreach ($base in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
                if ($base -and (Test-Path -LiteralPath (Join-Path $base 'Microsoft\Edge\Application\msedge.exe'))) { $browser = Join-Path $base 'Microsoft\Edge\Application\msedge.exe' }
            }
            if (-not $browser -and (Test-Path -LiteralPath '/opt/pw-browsers/chromium')) { $browser = '/opt/pw-browsers/chromium' }
        }
        if ($browser -and -not $IsWindows) {
            $wrapper = Join-Path $TestDrive 'chromium-test.sh'
            Set-Content -LiteralPath $wrapper -Value "#!/bin/sh`nexec '$browser' --no-sandbox `"`$@`"" -Encoding ascii
            & chmod +x $wrapper
            $browser = $wrapper
        }
        $ini = Join-Path $TestDrive 'pdf.ini'
        Set-Content -LiteralPath $ini -Value "[Report]`nPdfEngine=Edge`nEdgePath=$browser`nPdfTimeoutSeconds=120" -Encoding utf8
        $script:PdfConfig = Import-EobConfiguration -Path $ini -NoIncludes

        $context = New-EobOperationContext -Kind 'Onboarding' -Simulation
        $plan = New-EobPlan -Kind 'Onboarding' -Context $context -Subject @{ SamAccountName = 'mmustermann' } -Simulation
        $step = Add-EobPlanStep -Plan $plan -Action 'CreateUser' -Title 'Benutzerkonto anlegen (Ä Ö Ü ß)' -Target 'mmustermann' -Handler 'New-EobAdUserAccount' -Parameters @{}
        $step.Status = 'Simulated'
        $script:PdfReport = New-EobPlanReport -Plan $plan
    }

    It 'erzeugt ein gültiges PDF aus einem Vorgangsbericht' -Skip:(-not $script:BrowserPath) {
        $directory = Join-Path $TestDrive 'out'
        $files = @(Export-EobReport -Report $script:PdfReport -Format Pdf -Directory $directory -Config $script:PdfConfig -Confirm:$false)
        $pdf = $files | Where-Object Format -EQ 'Pdf'
        $pdf.Message | Should -BeNullOrEmpty
        $pdf.Path | Should -Not -BeNullOrEmpty
        $bytes = [System.IO.File]::ReadAllBytes($pdf.Path)
        $bytes.Length | Should -BeGreaterThan 1000
        [System.Text.Encoding]::ASCII.GetString($bytes, 0, 5) | Should -Be '%PDF-'
    }

    It 'erzeugt ein PDF des Willkommensdokuments' -Skip:(-not $script:BrowserPath) {
        $html = Join-Path $TestDrive 'welcome.html'
        $template = Join-Path (Get-EobTestRepoRoot) 'ReportTemplates/HTMLTemplate.txt'
        $rendered = Expand-EobTemplate -Template ((Get-EobTextFileContent -Path $template).Text) -Values (Get-EobWelcomePlaceholderValue -Config $null -Values @{ Vorname = 'Max' })
        Set-Content -LiteralPath $html -Value $rendered.Content -Encoding utf8
        $result = ConvertTo-EobPdf -HtmlPath $html -PdfPath (Join-Path $TestDrive 'welcome.pdf') -Config $script:PdfConfig -Confirm:$false
        $result.Status | Should -Be 'Succeeded'
        (Get-Item -LiteralPath (Join-Path $TestDrive 'welcome.pdf')).Length | Should -BeGreaterThan 10000
    }
}
