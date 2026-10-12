#Requires -Version 7.2
<#
.SYNOPSIS
    Öffnet den unabhängigen, lokalen INI-Konfigurationseditor.
.DESCRIPTION
    Windows und PowerShell 7.2+ im STA-Modus erforderlich. Keine AD-Abfragen,
    Netzwerkverbindungen, Installation oder Administratorrechte.
.PARAMETER ConfigPath
    Optionaler INI-Pfad. Ohne Pfad wird eine neue Konfiguration aus der Vorlage geöffnet.
.PARAMETER Fragment
    Bearbeitet eine einzelne Include-Datei mit Schema- und Sicherheitsprüfung,
    aber ohne Vollständigkeitsprüfung der gesamten Anwendungskonfiguration.
.EXAMPLE
    pwsh -NoProfile -STA -File .\Start-easyONBOARDING.ConfigEditor.ps1
#>
[CmdletBinding()]
param([string]$ConfigPath, [switch]$Fragment)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) { throw 'Der Konfigurationseditor benötigt Windows mit WPF.' }
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    throw 'Bitte mit pwsh -NoProfile -STA -File .\Start-easyONBOARDING.ConfigEditor.ps1 starten.'
}
foreach ($module in @('Core', 'Configuration', 'Setup')) {
    Import-Module (Join-Path $PSScriptRoot "Modules/$module/easyONB.$module.psd1") -ErrorAction Stop
}
. (Join-Path $PSScriptRoot 'Modules/Editors/easyONB.ConfigEditor.ps1')
Start-EobConfigEditor -AppRoot $PSScriptRoot -ConfigPath $ConfigPath -Fragment:$Fragment
