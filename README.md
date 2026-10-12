# easyONBOARDING

Version **3.0.3** · PowerShell 7.2+ · Windows 10/11, Windows Server 2019+ · Autor: Andreas Hepp (PHINIT.DE)

easyONBOARDING ist ein PowerShell-Werkzeug mit WPF-Oberfläche für den Lebenszyklus von
Benutzerkonten im Active Directory. Damit lassen sich neue Mitarbeitende anlegen, bestehende Konten
pflegen und Austritte in Phasen abwickeln. Jede Ausführung beginnt mit Vorschau und Simulation und
wird erst nach Bestätigung live ausgeführt. Audit-Log und Berichte entstehen automatisch.
Exchange (Online, Server, Hybrid), Microsoft Graph und Entra Connect lassen sich optional anbinden.

> Version 3 ist eine vollständige Neuentwicklung. Die früheren Versionen 1.x und die separaten
> Zusatzwerkzeuge sind nicht mehr Teil des Repositorys; der Umstieg ist in
> [MIGRATION.md](V3.0.0/docs/MIGRATION.md) beschrieben.

## Inhalt

- [Funktionen](#funktionen)
- [Voraussetzungen](#voraussetzungen)
- [Schnellstart](#schnellstart)
- [Die Skripte](#die-skripte)
- [Sicherheitsgrundsätze](#sicherheitsgrundsätze)
- [Aufbau des Repositorys](#aufbau-des-repositorys)
- [Dokumentation](#dokumentation)
- [Entwicklung und Qualitätssicherung](#entwicklung-und-qualitätssicherung)
- [Autor, Support und Lizenz](#autor-support-und-lizenz)

## Funktionen

| Bereich | Umfang |
|---|---|
| **Onboarding** | Assistent in 8 Schritten mit Rollenvorlagen und Kontonamen (Transliteration, Kollisionsprüfung). Gruppen und Lizenzgruppen, Vorschau und Simulation. Das Startkennwort wird genau einmal angezeigt. |
| **Benutzer aktualisieren** | Attribute, Führungskraft und Gruppen mit Vorher/Nachher-Vorschau. Kennwort-Reset nur als eigene, bestätigte Aktion. |
| **Offboarding** | 7 Vorlagen, z. B. Standardaustritt, Sofortige Sperrung, Externer Dienstleister, Ruhestand und Testmodus. Phasen: Sofort, Zum Austritt, Aufbewahrung, Endgültige Löschung. Warteschlange für geplante Phasen, Zustandsberichte vorher und nachher. |
| **Massenverarbeitung** | CSV-Import für Onboarding und Offboarding, ab einstellbarer Anzahl mit Tippbestätigung. |
| **Berichte und Audit** | HTML, PDF, JSON, CSV und TXT; verpflichtendes Onboarding-Handout aus Vorlagen (auch für Externe und CSV). Andere Handouts nur nach Auswahl. PDF über Microsoft Edge, alternativ wkhtmltopdf. Audit-Log als JSON Lines. |
| **Exchange** ¹ | Online, Server und Hybrid. Postfach anlegen (Server/Hybrid), Abwesenheitsnotiz, Weiterleitung, Ausblenden, Umwandlung in ein freigegebenes Postfach, Berechtigungsbericht. Im Hybridbetrieb wird erkannt, ob ein Postfach online oder lokal liegt. |
| **Microsoft Graph** ¹ | Anmeldesitzungen beim Offboarding widerrufen: delegiert oder als Anwendung mit Zertifikat. |
| **Entra Connect Sync** ¹ | Delta- oder Initial-Synchronisation per WinRM. Serverprüfung: Erreichbarkeit, laufender Zyklus, Stagingmodus. |
| **Unbeaufsichtigter Betrieb** | Fällige Offboarding-Phasen über eine geplante Aufgabe. Exchange Online und Graph melden sich dabei per Zertifikat (App-only) an. |
| **Einrichtung** | `Install-PS7_PDF.ps1` prüft die Voraussetzungen und richtet sie ein. `Install-easyONBOARDING.ps1` erstellt die Konfiguration; auf einem Domänencontroller sind die Felder vorbelegt. |
| **Separate Editoren** | WPF-Konfigurationseditor mit Schema-Prüfung und eigener WPF-Vorlageneditor für HTML-Handouts mit Gestaltung, Platzhaltern und sicherer Vorschau. Ohne AD-Verbindung nutzbar. |
| **Oberfläche** | Ausgelegt für 1400 x 900, helles und dunkles Design, Hinweistexte an allen Feldern. Mehrere Unternehmen über eigene Konfigurationsdateien. |

¹ Optional und standardmäßig ausgeschaltet. Implementiert und mit Mocks getestet, aber nicht gegen
reale Umgebungen geprüft. Vor dem produktiven Einsatz in einer Testumgebung prüfen
([TESTING.md](V3.0.0/docs/TESTING.md)).

## Voraussetzungen

| Komponente | Anforderung |
|---|---|
| Betriebssystem | Windows 10/11 oder Windows Server 2019+ für die Oberfläche; `-CheckOnly` und Tests laufen auch unter Linux/macOS |
| PowerShell | 7.2 oder höher |
| Active Directory | Modul `ActiveDirectory` (RSAT) und delegierte Rechte auf die benötigten OUs und Gruppen; keine Domain-Admin-Rechte nötig |
| PDF (optional) | Microsoft Edge, alternativ wkhtmltopdf; ohne Engine entstehen HTML-Berichte |
| Exchange / Graph (optional) | `ExchangeOnlineManagement`, `Microsoft.Graph.Authentication`, `Microsoft.Graph.Users.Actions` bzw. Remote-PowerShell zu Exchange Server |
| Entra Connect (optional) | WinRM zum Synchronisationsserver, Mitglied in `ADSyncOperators` |

Details zu Rechten und Modulen: [INSTALLATION.md](V3.0.0/docs/INSTALLATION.md).

## Schnellstart

Alle Befehle im Ordner `V3.0.0` ausführen. Heruntergeladene ZIP-Dateien zuerst freigeben:
`Get-ChildItem -Recurse | Unblock-File`.

```powershell
# 1. Voraussetzungen prüfen und bei Bedarf einrichten (läuft auch unter Windows PowerShell 5.1).
#    Ohne Auswahl wird nichts geändert; Installationen nur in einer Administrator-PowerShell.
powershell.exe -STA -NoProfile -File .\Install-PS7_PDF.ps1

# 2. Konfiguration mit dem Installer erstellen. Auf einem Domänencontroller werden Domäne,
#    OUs, Entra Connect und Exchange aus dem AD vorbelegt, auf Clients manuell eingetragen.
pwsh -STA -NoProfile -File .\Install-easyONBOARDING.ps1

# 3. Konfiguration und Umgebung prüfen (ohne Oberfläche, Exitcode 0 = in Ordnung)
pwsh -NoProfile -File .\Start-easyONBOARDING.ps1 -CheckOnly

# 4. Oberfläche starten. Simulation ist voreingestellt.
pwsh -NoProfile -File .\Start-easyONBOARDING.ps1
```

Ohne Installer: `Copy-Item .\Config\easyONB.ini.template .\Config\easyONB.ini` und die Datei
anpassen ([CONFIGURATION.md](V3.0.0/docs/CONFIGURATION.md)). Eine Konfiguration der Version 1.x
übernimmt *Tools › Konfiguration migrieren* bzw. `Scripts\Convert-LegacyConfiguration.ps1`.

## Die Skripte

| Skript | Zweck | Wichtige Parameter |
|---|---|---|
| `Install-PS7_PDF.ps1` | Prüft PowerShell 7, das ActiveDirectory-Modul, die PDF-Erzeugung und die Ausführungsrichtlinie. Richtet Fehlendes nur auf Auswahl ein und kopiert die Anwendung auf Wunsch in einen Zielordner. Eine vorhandene Konfiguration bleibt dabei erhalten. | `-CheckOnly`, `-Install PowerShell7, ActiveDirectory, Wkhtmltopdf, ExecutionPolicy`, `-TargetPath`, `-WhatIf` |
| `Install-easyONBOARDING.ps1` | Erstellt `Config\easyONB.ini` über eine eigene Oberfläche. Auf einem Domänencontroller werden die Werte aus dem AD vorbelegt. Prüft die Eingaben wie die Anwendung und sichert eine vorhandene Datei als `.bak`. | `-ConfigPath` |
| `Start-easyONBOARDING.ps1` | Startet die Anwendung. Mit `-CheckOnly` werden nur Konfiguration und Umgebung geprüft. | `-CheckOnly`, `-Simulation`, `-Theme Light\|Dark`, `-ConfigPath` |
| `Start-easyONBOARDING.ConfigEditor.ps1` | Separate WPF-Oberfläche zum Erstellen und Bearbeiten von INI-Konfigurationen mit Schema-Feldern und Validierung. | `-ConfigPath` |
| `Start-easyONBOARDING.ReportEditor.ps1` | Separater WPF-Editor für HTML-Handout-Vorlagen mit grafischer Gestaltung, Platzhaltern und Vorschau mit Beispieldaten. | `-TemplatePath` |

Alle Skripte haben eine Hilfe: `Get-Help .\<Skript>.ps1 -Detailed`.

### Konfiguration und Handouts grafisch bearbeiten

Die Editoren benötigen Windows und PowerShell 7.2+, aber weder Administratorrechte noch eine
AD-Verbindung. Im Ordner `V3.0.0` starten:

```powershell
pwsh -STA -NoProfile -File .\Start-easyONBOARDING.ConfigEditor.ps1
pwsh -STA -NoProfile -File .\Start-easyONBOARDING.ReportEditor.ps1
```

Die Konfiguration vor dem Speichern prüfen. Die eigene Handout-Vorlage als `.txt` oder `.html`
speichern und ihren Pfad im Konfigurationseditor unter `[Report] TemplatePathHTML` eintragen.
Relative Vorlagenpfade beziehen sich auf `V3.0.0`, nicht auf den Ordner der INI-Datei.
Die Vorschau führt kein HTML oder JavaScript aus und lädt keine externen Ressourcen; sie ist
eine sichere WPF-Darstellung, keine pixelgenaue Browseransicht.
Technische Vorgangs-/Auditberichte (HTML, JSON, CSV, TXT und PDF) werden weiterhin unabhängig
von Handout-Vorlagen erzeugt.

## Sicherheitsgrundsätze

- **Simulation zuerst.** Jede Ausführung startet als Simulation. Live geht es erst nach Vorschau und
  Bestätigung; Massenvorgänge und Löschungen verlangen eine Tippbestätigung.
- **Keine Kennwörter in Dateien.** Startkennwörter kommen aus einem kryptografischen Zufallsgenerator
  und liegen nur als `SecureString` im Speicher. Sie werden einmal angezeigt und erscheinen nie in
  Logs, Berichten, CSV/JSON oder E-Mails. Die Zwischenablage wird automatisch geleert.
- **Keine Secrets in der Konfiguration.** Kennwörter, Tokens oder Webhook-URLs in INI-Dateien werden
  als Befund gemeldet und nie verwendet. Exchange und Graph melden sich interaktiv, per Kerberos oder
  per Zertifikat an.
- **Privilegierte Gruppen und geschützte Konten sind gesperrt.** Domain Admins, Enterprise Admins und
  vergleichbare Gruppen werden nie zugewiesen; die Erkennung läuft über SID/RID, `adminCount` und
  verschachtelte Mitgliedschaft. Geschützte Konten werden nie bearbeitet.
- **Keine automatische Löschung.** Endgültig gelöscht wird nur nach Ablauf der Aufbewahrungsfrist,
  mit gesichertem Zustandsbericht und nach Eingabe von `LÖSCHEN <Konto>`.
- **Least Privilege.** Die Anwendung braucht keine Administratorrechte, erhöht sich nie selbst,
  ändert nie die Ausführungsrichtlinie und installiert keine Module. Das Hilfsskript
  `Install-PS7_PDF.ps1` ändert nur, was ausdrücklich ausgewählt wird. Downloads prüft es auf eine
  gültige Microsoft-Signatur.

Details und Meldung von Schwachstellen: [SECURITY.md](SECURITY.md).

## Aufbau des Repositorys

```
.
├── README.md, CHANGELOG.md, SECURITY.md, CONTRIBUTING.md
├── VERSION                         einzige Versionsquelle
└── V3.0.0/                         die Anwendung
    ├── Start-easyONBOARDING.ps1    Einstieg: Oberfläche oder -CheckOnly
    ├── Start-easyONBOARDING.ConfigEditor.ps1  separater INI-Editor (WPF)
    ├── Start-easyONBOARDING.ReportEditor.ps1  separater Handout-Vorlageneditor (WPF)
    ├── Install-easyONBOARDING.ps1  Installer der Konfiguration (WPF)
    ├── Install-PS7_PDF.ps1         Prüfung und Einrichtung der Voraussetzungen (WPF/Konsole)
    ├── Config/                     easyONB.ini.template, companies/, templates/ (Rollen, Offboarding), schemas/
    ├── GUI/                        MainWindow, Views/, Dialogs/, Installer/, Editors/, Styles/ (Light/Dark)
    ├── Modules/                    Core, Configuration, Security, ActiveDirectory, Exchange, Entra,
    │                               Reporting, Onboarding, Offboarding, Setup, UI
    ├── ReportTemplates/            Vorlagen des Willkommensdokuments
    ├── Assets/                     Bilder für Berichte
    ├── Scripts/                    geplante Offboarding-Phasen, Migration, Qualitätsprüfung, Doku-Generator
    ├── Tests/                      Pester: Unit, Integration, Fixtures
    └── docs/                       ausführliche Dokumentation
```

Laufzeitdaten liegen in `V3.0.0/Logs`, `Reports` und `Data`. Sie enthalten personenbezogene Daten
und sind per `.gitignore` ausgeschlossen.

## Dokumentation

| Dokument | Inhalt |
|---|---|
| [INSTALLATION.md](V3.0.0/docs/INSTALLATION.md) | Voraussetzungen, Hilfsskripte, Installation, Rechte, geplante Aufgabe |
| [CONFIGURATION.md](V3.0.0/docs/CONFIGURATION.md) | Aufbau der INI, Unternehmen, Vorlagen, Beispiele |
| [CONFIGURATION-REFERENCE.md](V3.0.0/docs/CONFIGURATION-REFERENCE.md) | alle Schlüssel, aus dem Schema erzeugt |
| [ONBOARDING.md](V3.0.0/docs/ONBOARDING.md) | Assistent, Kontonamen, Gruppen, Kennwörter, CSV |
| [OFFBOARDING.md](V3.0.0/docs/OFFBOARDING.md) | Vorlagen, Phasen, Warteschlange, Löschschutz |
| [MIGRATION.md](V3.0.0/docs/MIGRATION.md) | Umstieg von 1.3.10 / 1.4.x |
| [TESTING.md](V3.0.0/docs/TESTING.md) | automatische Tests, CI, manuelle Prüfliste |
| [Architektur](CONTRIBUTING.md#architektur) | Modulgrenzen, Plan-Ausführung, Oberfläche und Dokumente |
| [ReportTemplates/README.md](V3.0.0/ReportTemplates/README.md) | Platzhalter der Berichtsvorlagen |
| [CHANGELOG.md](CHANGELOG.md) | Änderungen je Version |
| [SECURITY.md](SECURITY.md) | Sicherheitskonzept, unterstützte Versionen, Meldung von Schwachstellen |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Entwicklungsumgebung, Konventionen, Qualitätsprüfung |

## Entwicklung und Qualitätssicherung

```powershell
Set-Location ./V3.0.0

# statische Prüfungen: Parser, Kodierung, XAML, PSScriptAnalyzer, Secrets, Doku, Version
pwsh -NoProfile -File ./Scripts/Invoke-EobQualityCheck.ps1

# Tests (Pester 5.7.1): kein Active Directory, Exchange oder Graph nötig
pwsh -NoProfile -Command "Invoke-Pester -Path ./Tests/Unit, ./Tests/Integration -Output Detailed"
```

Ein CI-Workflow ist im aktuellen Repository-Stand nicht enthalten. Die Tests laden unter Windows
zusätzlich alle WPF-Fenster ohne Anzeige und prüfen PDF mit Microsoft Edge, sofern verfügbar. Konventionen und Ablauf:
[CONTRIBUTING.md](CONTRIBUTING.md).

## Autor, Support und Lizenz

Andreas Hepp · PHINIT.DE · [www.PSscripts.de](https://www.PSscripts.de) · info@phinit.de

Fehler und Wünsche bitte als [GitHub-Issue](https://github.com/PS-easyIT/easyONBOARDING/issues)
melden. Sicherheitsrelevante Funde bitte vertraulich, siehe [SECURITY.md](SECURITY.md).
