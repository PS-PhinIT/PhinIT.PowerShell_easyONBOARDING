# Umstieg von Version 1.3.10 / 1.4.x

Version 3 ersetzt die Versionen 1.3.10 und 1.4.x vollständig. Die alten Ordner `V1.3.10` und
`V1.4.XX` sind nicht mehr im Repository (bei Bedarf über die Git-Historie erreichbar). Eine bestehende
1.x-Installation bleibt als Rückfallebene unverändert; Version 3 liest von ihr nur die INI-Datei, die
bei der Migration als Quelle dient.

## Vorgehen

1. **Parallel installieren** ([INSTALLATION.md](INSTALLATION.md)). Die bisherige Installation nicht
   überschreiben.
2. **Konfiguration übernehmen** – in der Oberfläche unter *Tools › Konfiguration migrieren* oder per
   Skript:

   ```powershell
   pwsh -File .\Scripts\Convert-LegacyConfiguration.ps1 -SourcePath 'D:\easyIT\easyONBOARDING\easyONB.ini' -WhatIf
   pwsh -File .\Scripts\Convert-LegacyConfiguration.ps1 -SourcePath 'D:\easyIT\easyONBOARDING\easyONB.ini'
   ```

   Ziel ist standardmäßig `Config\easyONB.ini` (dort werden auch `Config\templates` und
   `Config\companies` gefunden). Die Quelle bleibt unverändert. Die Migration
   * entfernt Klartext-Secrets (`fixPassword`, `CompanyVPNPassword`, `JiraToken`, SMTP-Kennwort,
     Webhooks) und hinterlässt einen Kommentar ohne Wert,
   * kommentiert `SyncCommand` aus,
   * ergänzt die neuen Abschnitte (`[Security]`, `[Identity]`, `[Offboarding]`, `[Bulk]`, `[UI]`,
     `[Paths]`, `[FileServer]`, `[Exchange]`, `[Graph]` …) aus der Vorlage,
   * lässt alle übrigen Zeilen, Kommentare und unbekannten Schlüssel unverändert.
3. **Anpassen:** absolute Pfade der alten Installation (`C:\easyIT\…`) auf die neue Ablage ändern oder
   leeren (Standard: relativ zu `V3.0.0`), `[Report] TemplatePathHTML` auf `ReportTemplates/HTMLTemplate.txt`
   bzw. eine eigene Vorlage setzen, die neuen Abschnitte ausfüllen – insbesondere `[Offboarding]
   DisabledUsersOU`, `[FileServer] AllowedRoots` und die Schutzlisten in `[Security]`.
4. **Prüfen:** `pwsh -File .\Start-easyONBOARDING.ps1 -CheckOnly`. Fehler beheben; Warnungen und
   Hinweise lesen – veraltete Schlüssel werden mit ihrem Ersatz genannt.
5. **Testen** in der Simulation und anschließend in einer Test-OU ([TESTING.md](TESTING.md#manuelle-prüfung)).
6. **Altlasten bereinigen:** Logs und Berichte der Version 1.x enthalten möglicherweise Kennwörter
   ([SECURITY.md](../../SECURITY.md#hinweise-für-bestehende-installationen-1x)).
7. **Umstellen:** Verknüpfungen auf `Start-easyONBOARDING.ps1` ändern, die alte Version archivieren.

Ein Rückweg ist jederzeit möglich: Version 3 verändert die alten Ordner nicht; im Active Directory
angelegte oder geänderte Objekte bleiben davon unberührt.

## Was bleibt kompatibel

* INI-Format, Abschnitts- und Schlüsselnamen der Version 1.x (auch Unternehmensabschnitte `[Company1]`
  mit nummerierten Schlüsseln wie `CompanyMailDomain1`), Kodierung UTF-8 oder Windows-1252.
* UPN-Schlüsselwörter (`FIRSTNAME.LASTNAME`, `F.LASTNAME`, `FLASTNAME` …) und Anzeigenamen-Vorlagen.
* HTML-Vorlagen des Willkommensdokuments mit ihren Platzhaltern
  ([ReportTemplates/README.md](../ReportTemplates/README.md)).
* CSV-Spalten der alten Importdateien (`FirstName`, `LastName`, `PhoneNumber`, `DepartmentField`,
  `ADGroup` …), siehe [ONBOARDING.md](ONBOARDING.md#massenverarbeitung-csv).

## Ersetzte Schlüssel

| Version 1.x | Version 3 |
|---|---|
| `[Logging] ExtraFile` | `[Logging] AuditDirectory` |
| `[RemoteExecution] DefaultDCServerName` | `[ActiveDirectory] PreferredDomainController` (wird weiter gelesen) |
| `[WPFGUI] ThemeColor` | `[UI] AccentColor` |
| `[WPFGUILogos] OnboardingLogo` | `[UI] LogoPath` (wird weiter gelesen) |
| `[Report] UserOnboardingCreateTXT` | `[Report] Formats` (wird abgebildet) |
| `[OnboardingExtensions] GenerateDetailedReport` | `[Report] Formats` |
| `[NameNormalization] NormalizeCase` | `[Identity] LowerCaseIdentifiers` |
| `[ValidateUPN] AppendRandomOnConflict` | `[Identity] CollisionStrategy` (Nummerierung statt Zufall) |
| `[EmailSettings] From` | `[EmailSettings] FromAddress` |
| `[ADSync] ADSyncGroup` | `[ActivateUserMS365ADSync] ADSyncADGroup` |

Vollständige Liste mit allen veralteten und wirkungslosen Schlüsseln:
[CONFIGURATION-REFERENCE.md](CONFIGURATION-REFERENCE.md).

## Geänderte und entfallene Funktionen (Breaking Changes)

| Bisher | Version 3 |
|---|---|
| Start über `easyONBOARDING_V1.x.ps1`, Selbst-Elevation, `-ExecutionPolicy Bypass` | Start über `Start-easyONBOARDING.ps1`, keine Administratorrechte, Ausführungsrichtlinie unverändert |
| fester Standardkennwortwert `fixPassword` | nur generierte oder manuell je Vorgang eingegebene Kennwörter |
| Kennwort in Report, TXT/PDF, Welcome-Mail und Log | Kennwort nur einmalig im Dialog; Platzhalter `{{Passwort}}` und `{{CustomPW1..5}}` werden nie befüllt |
| Onboarding eines vorhandenen Anmeldenamens überschreibt das Konto | Kollision wird erkannt, Name nummeriert oder Vorgang angehalten |
| "Benutzer aktualisieren" setzt immer ein neues Kennwort | Kennwort-Reset nur als eigene, bestätigte Aktion |
| Gruppen aus INI/CSV/Freitext ungeprüft | privilegierte Gruppen werden nie zugewiesen |
| `SyncCommand` aus der INI wird ausgeführt | nur `Start-ADSyncSyncCycle` mit `[ADSync] PolicyType` |
| CSV-Import übernimmt nur den ersten Datensatz | Massenverarbeitung aller Zeilen mit Vorschau |
| Lizenzzuweisung per Graph (`Directory.ReadWrite.All`) | gruppenbasierte Lizenzierung über `[LicensesGroups]`; Graph nur `User.Read.All`, `User.RevokeSessions.All` |
| Jira-, Teams-Anbindung (nicht funktionsfähig) | entfallen; Schlüssel werden als wirkungslos gemeldet |
| SMTP mit Benutzername/Kennwort aus der INI | Relay ohne Anmeldung oder Windows-Konto (`UseDefaultCredentials`) |
| wkhtmltopdf über Windows PowerShell 5.1 | Microsoft Edge (headless), alternativ wkhtmltopdf, sonst HTML |
| PowerShell 5.1/7 gemischt | PowerShell 7.2 oder höher |

Neu hinzugekommen sind unter anderem das mehrstufige Offboarding, die Warteschlange mit geplanter
Ausführung, Audit-Log, Simulation als Standard und das helle/dunkle Farbschema
([CHANGELOG.md](../../CHANGELOG.md)).
