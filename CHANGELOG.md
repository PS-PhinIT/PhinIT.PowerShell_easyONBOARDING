# Änderungsprotokoll

Alle nennenswerten Änderungen an easyONBOARDING, neueste Version zuerst. Das Format ist an
[Keep a Changelog](https://keepachangelog.com/de/1.1.0/) angelehnt. Einzige Versionsquelle ist die
Datei `VERSION` im Repository-Stamm.

| Reihe | Stand | Ordner bzw. Quelle |
|---|---|---|
| **3.0.x** | aktuell, unterstützt | `V3.0.0/` |

## [3.0.3] - 2026-10-12 Audit

- Separate WPF-Skripte zum Erstellen und Bearbeiten von Konfigurationsdateien und HTML-Handout-
  Vorlagen: schema-basierte Eingaben, Validierung, grafische Gestaltung, Platzhalter und sichere
  Vorschau ohne Browserausführung. Die Editoren benötigen keine AD-Verbindung.
- Onboarding-Handout verpflichtend für Mitarbeitende, Externe und CSV-Zeilen; fehlende Vorlage
  sperrt den Plan. Legacy-Opt-out wird ignoriert; Simulation schreibt kein Handout.
- Andere Handouts nur auf ausdrückliche Auswahl, unabhängig von technischen Berichten und Audit.
- Bemerkungen werden in den redigierten Onboarding-Vorgangsbericht übernommen.
- Offboarding: Home-Zugriffe enger begrenzt, Lizenzentzug an erfolgreiche Postfachumwandlung
  gekoppelt und unvollständige Phasen für Wiederholung in der Warteschlange gehalten.
  Ein erfolgreich archiviertes Home-Verzeichnis wird für Wiederholungen nach fehlgeschlagener
  AD-Bereinigung nachgewiesen, statt den Vorgang dauerhaft zu blockieren.
- Offboarding ohne Exchange-Integration (`[Exchange] Mode=None`) oder ohne Dateiserver
  (`[FileServer]`) bleibt nicht mehr dauerhaft unvollständig: Lizenzgruppen werden ohne mögliche
  Postfachumwandlung nicht eingeplant (Warnung `OFF_LICENSE_CONVERSION_UNAVAILABLE`, Lizenzen
  bleiben erhalten); Konten ohne E-Mail-Adresse oder Postfach werden ohne Umwandlung
  lizenzbereinigt. Ein fehlender Dateiserver ist nur noch der Hinweis `OFF_FILESERVER_NOT_CONFIGURED`.
- Oberfläche und Installer: Protokollierung beim Neuladen aktualisiert, Stapelanzeige effizienter
  und abgelehnte Ausführungsrichtlinienänderung ohne blockierte Installationswarteschlange.
- Defekte Dokumentationsverweise korrigiert; Architektur im bestehenden Beitragsleitfaden
  dokumentiert und weiterhin durch die Qualitätsprüfung vorgeschrieben.

## [3.0.2] - 2026-10-04

### Hinzugefügt

- `Install-PS7_PDF.ps1` vollständig neu geschrieben, mit WPF-Oberfläche
  (`GUI/Installer/PrerequisitesWindow.xaml`) und Konsolenbetrieb (`-CheckOnly`, `-Install`, `-WhatIf`).
  Das Skript läuft auch unter Windows PowerShell 5.1, also bevor PowerShell 7 installiert ist.
  - Es prüft PowerShell 7, das ActiveDirectory-Modul, die PDF-Erzeugung und die Ausführungsrichtlinie
    und richtet Fehlendes nur auf Auswahl ein.
  - PowerShell 7 wird per winget installiert, sonst als MSI. Das MSI wird nur über https geladen und
    nur mit gültiger Microsoft-Signatur ausgeführt.
  - RSAT wird auf Clients als Windows-Funktion installiert, auf Servern als Windows-Feature;
    wkhtmltopdf nur per winget.
  - Installationen nur in einer als Administrator gestarteten PowerShell; das Skript erhöht sich nie
    selbst.
  - Die Ausführungsrichtlinie ändert es nur nach Bestätigung und nur für den aktuellen Benutzer.
  - Beim optionalen Kopieren der Anwendung bleibt eine vorhandene Konfiguration erhalten.
- Tests für das Voraussetzungs-Skript (`Tests/Unit/Prerequisites.Tests.ps1`), einschließlich
  Kompatibilität mit Windows PowerShell 5.1 und Laden des Fensters unter Windows.

### Geändert

- Repository neu gegliedert: `README.md`, `CHANGELOG.md`, `SECURITY.md`, `CONTRIBUTING.md` und
  `VERSION` liegen im Repository-Stamm, die Anwendung im Ordner `V3.0.0`.
- Qualitätsprüfung, `Get-EobVersion` und CI berücksichtigen die Dateien im Stamm. Findet
  `Get-EobVersion` keine `VERSION`-Datei, gilt die Modulversion.
- README vollständig überarbeitet; SECURITY, CONTRIBUTING, INSTALLATION und MIGRATION an den neuen
  Aufbau angepasst.
- CHANGELOG neu geordnet: Versionen 3.0.1 und 3.0.2 ausgewiesen, ältere Versionen aus der
  Git-Historie nachgetragen.

### Entfernt

- Ordner der Versionen 1.3.10 und 1.4.x, das Archiv der Vorversionen sowie die separaten
  Zusatzwerkzeuge (CSV-Generator, INI-Editor, HR-/AL-Werkzeug, Prüfskripte, Web-Prototyp). Sie sind
  über die Git-Historie weiterhin erreichbar (letzter Stand: Commit `e395922`).
- Umsetzungsplan `docs/PLAN.md` (abgeschlossen).

## [3.0.1] - 2026-10-04

### Hinzugefügt

- Installer `Install-easyONBOARDING.ps1` mit eigener WPF-Oberfläche (Modul `easyONB.Setup`). Er
  erstellt `Config\easyONB.ini` aus der Vorlage.
  - Auf einem Domänencontroller werden Domäne, UPN-Suffixe, Domänencontroller, OUs sowie Entra
    Connect und Exchange aus dem AD vorbelegt; auf Clients werden die Werte manuell eingetragen.
  - Jedes Feld und jeder Bereich hat einen Hinweistext, der nach 250 ms erscheint.
  - Die erzeugte Datei wird wie in der Anwendung geprüft; eine vorhandene Datei wird vorher als
    `.bak` gesichert.
- Exchange Hybrid: Verbindung zu Exchange Server **und** Exchange Online. Lokale Befehle werden mit
  dem Präfix `EobOnPrem` importiert; Postfachaktionen ermitteln, ob das Postfach online oder lokal
  liegt. Cloud-Postfächer werden nach dem Microsoft-Verfahren in freigegebene Postfächer umgewandelt
  (Exchange Online, danach `Set-RemoteMailbox -Type Shared` lokal).
- Zertifikatsanmeldung (App-only) für Exchange Online (`[Exchange] AppId`, `CertificateThumbprint`,
  `Organization`) und Microsoft Graph (`[Graph] ClientId`, `CertificateThumbprint`).
  - Die geplante Aufgabe verbindet damit Exchange Online und Graph unbeaufsichtigt; ohne Zertifikat
    bleiben diese Phasen manuell.
  - Neue Schematypen `Guid` und `Thumbprint`, Befund `CFG_CERTIFICATE_AUTH_INCOMPLETE` bei
    unvollständigen Angaben.
- Entra Connect: Serverprüfung über `Get-ADSyncScheduler` (Erreichbarkeit, laufender Zyklus,
  Stagingmodus), in der Oberfläche unter *Tools › Entra Connect prüfen*.

### Geändert

- Oberfläche auf 1400 x 900 ausgelegt: Navigation, Kopf, Abstände, Schriftgrößen und Tabellenhöhen
  so angepasst, dass Assistenten und Ansichten ohne unnötiges Scrollen passen.
  - Das Dashboard zeigt die vier Kennzahlen in einer Zeile; in *Benutzer aktualisieren* stehen die
    Attribute zweispaltig.
  - Hinweistexte in Ansichten, Dialogen und Bannern sind gekürzt.
  - Auf kleineren Arbeitsflächen (z. B. 1366 x 768) wird das Fenster beim Start auf die
    Arbeitsfläche begrenzt.
- Audit: `Get-EobAuditEntry` liest nur noch die Monatsdateien des angefragten Zeitraums (plus einen
  Monat Puffer) und filtert eine Operation-ID vor dem JSON-Parsen. Das Dashboard las bisher bei jedem
  Aufruf das gesamte Audit-Archiv.

### Behoben

- Exchange Hybrid: Postfächer in Exchange Online wurden über die lokale Sitzung nicht gefunden;
  dadurch entfielen alle Postfachaktionen des Offboardings („Kein Postfach gefunden“).
- Microsoft Graph: Der Status meldete „Verbunden“, obwohl `Microsoft.Graph.Users.Actions`
  (`Revoke-MgUserSignInSession`) fehlte; der Schritt scheiterte erst bei der Ausführung.
- Bestätigungsdialog: Lange Detaillisten, z. B. vor der endgültigen Löschung, konnten das Feld für
  die Tippbestätigung aus dem sichtbaren Bereich schieben, lange Zeilen wurden abgeschnitten. Die
  Details scrollen jetzt in einem eigenen Bereich und brechen um.
- Massenverarbeitung: Ein Fehler außerhalb der Zeilenverarbeitung (z. B. beim Aktualisieren der
  Ergebnistabelle) ließ die Ausführungssperre bestehen; Ansichtswechsel und Schließen des Fensters
  waren danach blockiert. Der Stapel wird jetzt geordnet beendet, die Moduswahl ist während der
  Ausführung gesperrt.
- Audit-Ansicht: Filtertexte mit `[` oder `]` führten zu einem Fehler (Platzhaltermuster). Gefiltert
  wird jetzt als Teilzeichenfolge ohne Beachtung der Groß-/Kleinschreibung.
- Offboarding-Warteschlange: Eine leere oder unvollständige JSON-Datei brach das Lesen der gesamten
  Warteschlange ab (Dashboard, Offboarding-Ansicht, geplante Aufgabe). Defekte Einträge werden jetzt
  protokolliert und übersprungen.

### Sicherheit

- Massenverarbeitung: Kennwörter nicht ausgeführter Zeilen (Fehler, Abbruch, verworfener oder neu
  importierter Stapel) blieben samt Klartext-Redaktionswert bis zum Programmende im Speicher. Sie
  werden jetzt beim Abschluss, beim Moduswechsel, beim Neuimport und beim Beenden verworfen;
  Fehlerzeilen in `Invoke-EobOnboardingBatch` sofort.

## [3.0.0] - 2026-09-27

Vollständige Neuentwicklung im Ordner `V3.0.0`. Die Versionen 1.3.10 und 1.4.x lagen zu diesem
Zeitpunkt unverändert in `V1.3.10` bzw. `V1.4.XX` (entfernt mit 3.0.2). Die Befund-IDs (C-xx, H-xx,
M-xx, F-xx) beziehen sich auf die damalige Bestandsaufnahme, die nicht mehr im Repository enthalten
ist. Die sicherheitsrelevanten Änderungen am Altstand sind in der
[Migration](V3.0.0/docs/MIGRATION.md) zusammengefasst.

### Hinzugefügt

- Modulare Architektur mit zehn Modulen (Präfix `Eob`, Manifeste mit expliziten Exporten) und
  Einstieg `Start-easyONBOARDING.ps1`, inklusive `-CheckOnly` für Prüfungen ohne Oberfläche.
- Plan-Engine: Jeder Vorgang wird als Plan mit Schritten, Risiken und Befunden erzeugt, in der
  Vorschau angezeigt, simuliert (`-WhatIf`) oder nach Bestätigung ausgeführt. Handler kommen nur aus
  `easyONB.*`-Modulen, Kennwörter nur als Laufzeitverweis.
- Neue WPF-Oberfläche: linke Navigation (Dashboard, Onboarding, Offboarding, Benutzer aktualisieren,
  Massenverarbeitung, Reports und Audit, Tools, Einstellungen, Info), Onboarding-Assistent mit
  8 Schritten, helles und dunkles Farbschema, Akzentfarbe, zentrale Dialoge, Tastenkürzel Strg+1…9,
  schrittweise Ausführung mit Abbruch zwischen zwei Schritten.
- Mehrstufiges Offboarding mit 7 Vorlagen, Phasen (Sofort, Zum Austritt, Aufbewahrung, Endgültige
  Löschung), Warteschlange, Zustandsberichten vorher/nachher, Dokumentation von
  Postfachberechtigungen, Archivierung von Home-Verzeichnissen und abgesicherter Löschung.
- `Scripts/Invoke-DueOffboardingPhases.ps1` für fällige Phasen per geplanter Aufgabe (nie Löschung,
  nie privilegierte Konten).
- Massenverarbeitung per CSV für Onboarding und Offboarding: alle Zeilen, Vorschau je Zeile,
  Tippbestätigung ab `[Bulk] ConfirmationThreshold`.
- Konfigurationsschema mit Typen, Standardwerten, Validierung und Hinweisen; kommentarerhaltendes
  Schreiben; Migration von 1.x-Konfigurationen (Oberfläche und
  `Scripts/Convert-LegacyConfiguration.ps1`).
- Strukturiertes Logging mit Operation-ID, Akteur, Aktion, Ziel, Ergebnis und Dauer; Audit-Log als
  JSON Lines; Redaktion sensibler Werte vor jedem Schreibvorgang; Ausweichverzeichnis.
- Berichte als HTML, JSON, CSV, TXT und PDF (Microsoft Edge headless, alternativ wkhtmltopdf, sonst
  HTML); Willkommensdokument aus den bisherigen HTML-Vorlagen mit eingebetteten Bildern.
- Integrationsstatus im Dashboard für AD, Exchange, Microsoft Graph, Entra Connect Sync, SMTP,
  Dateiserver und PDF-Erzeugung. Exchange, Graph und Entra Connect waren vorbereitet, aber nicht gegen
  reale Umgebungen verifiziert.
- Qualitätssicherung:
  - Pester-Tests (Unit und Integration, externe Systeme ausschließlich über Stubs/Mocks) und
    `PSScriptAnalyzerSettings.psd1`.
  - `Scripts/Invoke-EobQualityCheck.ps1` mit den Prüfungen Parser, Kodierung, XAML,
    PSScriptAnalyzer, Secret-/Platzhalter-Scan, Doku und Version.
  - GitHub-Workflow `.github/workflows/v3-ci.yml` (Windows und Linux, Actions per Commit-SHA, nur
    Lesezugriff).
- Dokumentation: README, SECURITY, CONTRIBUTING, Installation, Konfiguration (inklusive aus dem
  Schema erzeugter Referenz), Onboarding, Offboarding, Migration, Tests, Architektur.

### Geändert

- Laufzeit: PowerShell 7.2 oder höher. Die Oberfläche benötigt Windows; `-CheckOnly`, Tests und
  Skripte laufen auch unter Linux/macOS.
- Onboarding überschreibt nie ein bestehendes Konto: Kollisionen werden erkannt und je nach
  `[Identity] CollisionStrategy` nummeriert oder als Fehler gemeldet (C-05).
- UPN- und Anzeigenamen-Vorlagen werden korrekt ausgewertet; Legacy-Schlüsselwörter wie
  `FIRSTNAME.LASTNAME` bleiben gültig (F-09).
- *Benutzer aktualisieren* ändert nur tatsächlich geänderte Werte und setzt nie nebenbei ein
  Kennwort (C-04). Der Kennwort-Reset ist eine eigene, bestätigte Aktion. Deaktiviert angelegte
  Konten werden dort bei der Übergabe aktiviert.
- AD-Suchen und Filter werden maskiert (H-05); Führungskräfte werden eindeutig aufgelöst (H-12).
- Welcome-Mail über `System.Net.Mail` statt `Send-MailMessage`, Absender einheitlich
  `[EmailSettings] FromAddress` (M-09).
- Berichte sind HTML-kodiert, CSV-Exporte gegen Formel-Injection geschützt (H-06).

### Sicherheit

- Keine Kennwörter mehr in Logs, Debug-Ausgaben, Berichten, CSV-/JSON-Dateien, Willkommensdokumenten
  oder E-Mails (C-01, C-02, C-03, C-07, C-08). Kennwort-Platzhalter in Vorlagen werden nie befüllt.
- Kennwörter mit kryptografischem Zufallsgenerator (H-01); `New-EobPassword` liefert ausschließlich
  `SecureString`, `Test-EobPasswordPolicy` akzeptiert keinen Klartext.
- Privilegierte Gruppen werden nie zugewiesen; Erkennung über SIDs/RIDs, Namen (deutsch/englisch),
  `adminCount` und verschachtelte Mitgliedschaft (H-03). Geschützte Konten (eigenes Konto,
  eingebaute Konten, Notfall-, Dienst- und konfigurierte Konten/OUs) werden nie bearbeitet.
- Live-Ausführungen verlangen eine Bestätigung (`ConfirmImpact High`), destruktive Aktionen eine
  Tippbestätigung; Simulation ist Standard.
- Keine Selbst-Elevation und kein `-ExecutionPolicy Bypass` mehr (H-09); keine Downloads ohne
  Prüfung (H-10). Ein Installer war nicht Bestandteil von 3.0.0.
- Graph mit minimalen Scopes `User.Read.All` und `User.RevokeSessions.All` statt
  `Directory.ReadWrite.All` (M-08).
- PDF-Erzeugung ohne `--enable-local-file-access` (wkhtmltopdf); Microsoft Edge läuft headless mit
  temporärem Profil, ohne Erweiterungen und ohne Hintergrundnetzwerkzugriffe.

### Entfernt

- Fester Standardkennwortwert `fixPassword` (C-06) und Klartext-Secrets in der Konfiguration
  (`CompanyVPNPassword`, `JiraToken`, SMTP-Kennwort, Webhooks; H-11). Sie werden erkannt, gemeldet
  und ignoriert.
- Frei konfigurierbarer `SyncCommand` (Codeausführung über die Konfiguration, H-04); Entra Connect
  Sync startet nur noch `Start-ADSyncSyncCycle`.
- Zusatzkennwörter `{{CustomPW1..5}}` und die Graph-Lizenzverwaltung (stattdessen gruppenbasierte
  Lizenzierung über `[LicensesGroups]`).

### Veraltet

- Versionen 1.3.10 und 1.4.x.
- Legacy-Konfigurationsschlüssel werden weiter gelesen und im Prüfbericht mit Ersatz genannt
  (Übersicht: [CONFIGURATION-REFERENCE.md](V3.0.0/docs/CONFIGURATION-REFERENCE.md)).

### Bekannte Einschränkungen

- Die Oberfläche wurde automatisiert nur statisch geprüft (XAML-Prüfung, Abgleich Code/XAML) und in
  der CI unter Windows ohne Anzeige geladen. Vor dem produktiven Einsatz ist ein manueller Test nach
  [TESTING.md](V3.0.0/docs/TESTING.md) erforderlich.
- Exchange-, Graph- und Entra-Connect-Funktionen sind nicht gegen reale Umgebungen verifiziert.
- Die Dateien der Version 3 sind nicht Authenticode-signiert (Zertifikat des Maintainers
  erforderlich).

---

## Version 1 und Vorversionen (veraltet)

Die folgenden Einträge sind veraltet und zeigen den Entwicklungsstand

## [1.4.23] - 2025-07-12 (Entwicklungsstand, nicht freigegeben)

Letzter Stand der Reihe 1.4 (`V1.4.XX/easyONBOARDING_V1.4.23.ps1`, Commit `e395922`). Begonnen am
2025-03-20 als 1.4.1.

- Aufteilung des Monolithen in PowerShell-Module (u. a. Prüfungen, Kernfunktionen, Validierung,
  Benachrichtigung, Lizenzen, Reporting).
- Geplante Erweiterungen wie Einstellungsoberfläche, Postfachanlage, Profilbild, Home-Verzeichnis und
  Willkommens-E-Mail; laut Bestandsaufnahme war der GUI-Onboarding-Pfad nicht funktionsfähig.
- 2025-04-05: neue Berichtsvorlagen, zusätzlich auf Englisch (`HTMLTemplateENG.txt`).
- 2025-07-12: alle Skripte Authenticode-signiert.

## [1.3.10] - 2025-03-30

Letzte als final markierte Version der Reihe 1 (`V1.3.10`, Commit `bd6cef8`).

- WPF-Oberfläche mit den Registerkarten *easyONBOARDING* und *easyADUserUpdate*, Konfiguration über
  `easyONB.ini` (Design, Texte, Logos, UPN- und Anzeigenamen-Vorlagen).
- AD-Benutzeranlage mit UPN-Logik, Gruppen, Berichten als HTML/TXT/PDF und CSV-Import.
- Begleitwerkzeuge: INI-Editor, PDF-Erzeugung (`PDFCreator.ps1`), Installationsskript
  `INSTALL-PS7_PDF.ps1` und CSV-Generator für die Personalabteilung.

## [1.3.9] - 2025-03-22

- Getestete Version mit überarbeiteter Oberfläche.
- 2025-03-23: CSV-Generator für die Personalabteilung, Designkorrekturen, neues
  Installationsskript `INSTALL-PS7_PDF.ps1` (PowerShell 7 und PDF-Komponenten), geändertes Öffnen
  der PDF-Berichte.

## [1.3.8] - 2025-03-20

- Fehlerkorrekturen; parallel Beginn der Reihe 1.4 mit PowerShell-Modulen.

## [1.3.7] - 2025-03-18

- Registerkarten *easyONBOARDING* (Anlage) und *easyADUserUpdate* (Pflege bestehender Konten)
  fertiggestellt.

## [1.3.5] - 2025-03-18

- Fehlerkorrekturen; Konfiguration als `easyONB.ini`, Textvorlage für Berichte.

## [1.3.3] - 2025-03-17

- Umstieg auf eine XAML-basierte WPF-Oberfläche (`MainGUI.xaml`); Fehlerkorrekturen und
  Erweiterungen bei Benutzeranlage und Berichten.

## [1.1.4] - 2025-03-16

- Erste WPF-Oberfläche; flexibler Log-Pfad, Ausweichwert für den Anzeigenamen; Berichte als HTML,
  TXT und optional PDF.

## [1.0.1] - 2025-03-15

Erste Version im Repository (Commit `0bab756`, zusammen mit dem Paket `VERSION_1.0.0-FINAL.zip`).

- Windows-Forms-Oberfläche mit drei Bereichen (Eingabe, Erweiterte Einstellungen, Info & Tools),
  PowerShell 7, Prüfung der Windows-Version, Konfiguration per INI-Datei, HTML-Berichtsvorlage,
  Installations- und PDF-Skript.

## [0.9] - 2025-02-01

- 0.9 und 0.9.7: Umstieg auf PowerShell 7 (`#requires -Version 7.0`), Prüfung auf Windows 10 bzw.
  Windows Server 2016 oder höher.

## [0.1.0 – 0.8] - 2024-12-27

- Erste Skriptversionen für Windows PowerShell 5.1 mit Windows-Forms-Oberfläche,
  INI-Konfiguration und HTML-/PDF-Berichten (0.1.0 bis 0.1.5, 0.5, 0.6, 0.7, 0.8).
