# Tests und Qualitätssicherung

## Automatische Tests

```powershell
# einmalig (Benutzerbereich)
Install-PSResource -Name Pester -Version 5.7.1 -Scope CurrentUser
Install-PSResource -Name PSScriptAnalyzer -Version 1.24.0 -Scope CurrentUser

# statische Prüfungen
pwsh -NoProfile -File ./Scripts/Invoke-EobQualityCheck.ps1

# Pester
pwsh -NoProfile -Command "Invoke-Pester -Path ./Tests/Unit, ./Tests/Integration -Output Detailed"
```

| Bereich | Datei | Inhalt |
|---|---|---|
| Core | `Tests/Unit/Core.Tests.ps1` | Version, Pfade (Path-Traversal, UNC), Konvertierungen, Redaktion, Logging/Audit inkl. Ausweichverzeichnis, Plan-Engine inkl. Handler-Allowlist, HTML-/CSV-Schutz |
| Konfiguration | `Tests/Unit/Configuration.Tests.ps1` | INI-Parser (Kodierungen, Duplikate), Schema, Zusammenführung, Validierung, kommentarerhaltendes Schreiben, Migration (Funktion und Skript) |
| Sicherheit | `Tests/Unit/Security.Tests.ps1` | Kennwortgenerierung (Richtlinie, Zufall, keine Duplikate), Kennwortprüfung ohne Ausgabe, privilegierte Gruppen, geschützte Konten, Eingabeformate, Bestätigungspflicht kritischer Befehle |
| Active Directory | `Tests/Unit/ActiveDirectory.Tests.ps1` | Adapter mit gemockten AD-Cmdlets, Maskierung von Filtern, ShouldProcess, Schutzprüfungen |
| Onboarding | `Tests/Unit/Onboarding.Tests.ps1` | Transliteration, Namensvorlagen, Kollisionen, Anfrageprüfung, Plan, Ausführung, CSV, Benutzer aktualisieren, Kennwort-Reset |
| Offboarding | `Tests/Unit/Offboarding.Tests.ps1` | Vorlagen, Phasen und Termine, Schutzprüfung, Plan, Warteschlange, geplante Ausführung, Löschschutz (Frist, Sicherung mit Prüfsumme, Tippbestätigung), Home-Verzeichnisse, CSV |
| Berichte | `Tests/Unit/Reporting.Tests.ps1` | Berichte ohne Secrets, HTML-Kodierung, Willkommensdokument, Welcome-Mail, PDF-Auswahl |
| Separate Editoren | `Tests/Unit/ConfigEditor.Tests.ps1`, `Tests/Unit/ReportEditor.Tests.ps1` | Konfigurations-/Vorlagenbearbeitung ohne Oberfläche, Validierung und Sicherheitsregeln; WPF-Laden unter Windows |
| Integrationen | `Tests/Unit/Integrations.Tests.ps1` | Exchange, Graph, Entra Connect mit Mocks |
| Oberfläche | `Tests/Unit/UI.Tests.ps1` | XAML-Regeln, Ressourcen, Farbschemata, Abgleich Code/XAML, Hilfsfunktionen, Testmodus der Dialoge; unter Windows zusätzlich echtes Laden aller XAML-Dateien und Initialisieren aller Ansichten ohne Anzeige |
| Qualitätsprüfung | `Tests/Unit/QualityCheck.Tests.ps1` | Erkennung von Syntaxfehlern, Kodierung, Secrets, Platzhaltern, Code-Behind, defekten Links; das Repository selbst besteht die Prüfungen |
| PDF | `Tests/Integration/Pdf.Tests.ps1` | echte PDF-Erzeugung mit Edge (Windows) bzw. Chromium; ohne Browser übersprungen |

**Grundsätze:** Tests sprechen keine echten Systeme an. AD-, Exchange- und Graph-Cmdlets sind in
`Tests/Fixtures/ExternalCommandStubs.ps1` als globale Stubs definiert, die ohne Mock eine Ausnahme
auslösen. Alle Dateien entstehen im Pester-`TestDrive`. Kennwörter in Tests sind künstliche Werte
und werden über `New-EobTestSecureString` erzeugt.

## CI und Prüfgrenzen

Im aktuellen Repository-Stand ist kein CI-Workflow enthalten. Die oben genannten lokalen
Prüfungen sind die verfügbare automatisierte Qualitätssicherung. Tests mit Mocks ersetzen
keine Prüfung gegen eine Testdomäne, Exchange, Graph oder Entra Connect.

Der Audit vom 12.10.2026 ergänzt Regressionstests für verpflichtende Onboarding-Handouts,
fehlende Vorlagen, Berichtsbemerkungen, optionale Handouts anderer Vorgänge, Logging-Neuladen,
Installer-Abbruch, Stapelanzeige und Offboarding-Schutz-/Wiederholungslogik.
Parser, XAML-Struktur und fachliche Mocks laufen unter Linux. Echtes WPF-Laden, Windows-ACLs,
Windows PowerShell 5.1 und die echte PDF-Erzeugung benötigen weiterhin Windows beziehungsweise
eine verfügbare PDF-Engine und können hier übersprungen werden.

Die Oberfläche arbeitet weiterhin kooperativ auf dem Dispatcher: langsame Netzwerk-/AD-
Aufrufe blockieren während eines Schritts. Eine Hintergrund-Runspace-Ausführung ist nicht
implementiert; Abbruch wirkt erst nach dem laufenden Schritt beziehungsweise der Stapelzeile.

## Manuelle Prüfung

Vor dem produktiven Einsatz und nach größeren Änderungen in einer **Testdomäne oder Test-OU** prüfen
– nie mit produktiven Konten. Zuerst alles in der Simulation, dann live in der Test-OU.

**Start und Oberfläche**

- [ ] `Start-easyONBOARDING.ps1 -CheckOnly` ohne Fehler; Integrationsstatus plausibel.
- [ ] Oberfläche startet im Simulationsmodus; Banner und Modusanzeige sichtbar.
- [ ] Navigation per Maus und Strg+1…9; alle neun Ansichten laden ohne Fehlerdialog.
- [ ] Wechsel hell/dunkel und Akzentfarbe; Texte überall lesbar (auch Dialoge, Tabellen, Auswahllisten).
- [ ] Bedienung nur mit Tastatur (Tab-Reihenfolge, Enter/Esc in Dialogen) und mit 150 % Skalierung.
- [ ] Live-Modus lässt sich nur nach Bestätigung aktivieren; mit Fehlern in der Konfiguration gar nicht.

**Separate Editoren (ohne Testdomäne nutzbar)**

- [ ] Beide `Start-easyONBOARDING.*Editor.ps1` mit `pwsh -STA` starten; Oberfläche bei 150 % Skalierung
      und nur per Tastatur bedienen.
- [ ] Konfiguration neu erstellen, vorhandene INI öffnen, Abschnitte und Suche nutzen; ungültige
      Werte korrigieren, speichern und in der Anwendung erneut prüfen.
- [ ] Kommentare, unbekannte Schlüssel und Unternehmens-/Rollenvorlagen beim Bearbeiten erhalten;
      vorhandene Datei nur bewusst überschreiben.
- [ ] Deutsche/englische Handout-Vorlage öffnen, Gestaltung ändern, Platzhalter einfügen;
      Warnungen und Vorschau prüfen, eigene Vorlage speichern und `TemplatePathHTML` setzen.
- [ ] Vorschau mit aktivem HTML und externen Links testen: kein Script, kein Ressourcenabruf.
- [ ] Ungespeicherte Änderungen beim Öffnen, Neuerstellen und Schließen nicht unbemerkt verlieren.

**Onboarding**

- [ ] Assistent vollständig durchlaufen; Pflichtfelder und Feldfehler; Vorschau zeigt alle Schritte
      und Gruppen mit Herkunft.
- [ ] Name mit Umlauten und Doppelnamen; Kollision mit vorhandenem Konto → Nummerierung, kein
      Überschreiben.
- [ ] Referenzbenutzer mit privilegierter Gruppe → Gruppe blockiert und begründet.
- [ ] Live in der Test-OU: Konto, Attribute, Gruppen, Ablaufdatum korrekt; Zugangsdaten genau einmal
      angezeigt; Zwischenablage nach der eingestellten Zeit leer; Druck ohne Datei.
- [ ] Log, Audit, Bericht, Willkommensdokument und (Test-)Welcome-Mail enthalten kein Kennwort.
- [ ] Abbrechen während der Ausführung: laufender Schritt endet, weitere werden übersprungen.

**Benutzer aktualisieren**

- [ ] Vorher/Nachher-Vorschau; nur geänderte Werte werden geschrieben; kein Kennwort-Reset nebenbei.
- [ ] Kennwort-Reset mit Bestätigung und einmaliger Anzeige.

**Offboarding**

- [ ] Geschütztes Konto (eigenes Konto, Notfallkonto, Dienstkonto) wird gesperrt angezeigt.
- [ ] Vorlage "Standardaustritt" mit Austritt in der Zukunft: nur Sofort-Phase ausgeführt, Vorgang in
      der Warteschlange mit korrektem Termin.
- [ ] `Scripts/Invoke-DueOffboardingPhases.ps1 -WhatIf` und live (Testdatum in der Vergangenheit).
- [ ] Löschung: vor Fristablauf verweigert; nach Fristablauf nur mit `LÖSCHEN <Anmeldename>`;
      veränderter Zustandsbericht blockiert die Löschung.
- [ ] Vorlage "Testmodus" erzwingt Simulation.

**Massenverarbeitung, Berichte, Integrationen**

- [ ] CSV mit fehlerhaften Zeilen: Fehler je Zeile, nur gültige Zeilen ausführbar; Tippbestätigung ab
      Schwellwert; Export ohne Kennwörter.
- [ ] PDF-Bericht mit Edge; ohne Edge HTML-Fallback mit Hinweis.
- [ ] Exchange/Graph/Entra Connect (falls genutzt): Verbindung, Status im Dashboard, je eine Aktion an
      einem Testpostfach bzw. Testkonto.
