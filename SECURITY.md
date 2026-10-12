# Sicherheitsrichtlinie

## Unterstützte Versionen

| Version | Unterstützt | Hinweis |
|---|---|---|
| 3.0.x (`V3.0.0`) | ja | aktuelle Version |
| 1.x | nein | nicht mehr im Repository; sicherheitsrelevante Unterschiede siehe [Migration](V3.0.0/docs/MIGRATION.md) |

Für die Versionen 1.x werden keine Sicherheitskorrekturen mehr bereitgestellt. Bitte auf 3.0
umsteigen ([docs/MIGRATION.md](V3.0.0/docs/MIGRATION.md)).

## Schwachstellen melden

Bitte Schwachstellen **nicht** als öffentliches Issue melden, sondern vertraulich:

1. bevorzugt über GitHub: Repository → *Security* → *Report a vulnerability* (sofern aktiviert),
2. alternativ per E-Mail an den Maintainer (Kontakt siehe README im Repository-Stamm).

Hilfreich sind: betroffene Version, Schritte zur Reproduktion, erwartetes und tatsächliches
Verhalten. Bitte keine echten Kennwörter, Tokens oder personenbezogenen Daten mitsenden.

## Sicherheitskonzept (Version 3)

**Home-Zugriffe beim Offboarding.** Ein veränderbarer AD-HomeDirectory-/Manager-Eintrag ist
keine ausreichende Autorisierung für Dateiserver-ACLs. Die Anwendung verlangt das explizit
freigegebene Empfängerkonto und prüft die exakte Zuordnung `<AllowedRoot>/<SamAccountName>`.
Freigabestämme, fremde Ordner und Reparse-Point-Vorfahren werden nicht berechtigt. Änderungen
an Dateisystempfaden zwischen Prüfung und ACL-Schreibvorgang lassen sich damit nicht atomar
ausschließen; Stammpfade und Benutzerordner müssen gegen unberechtigte Umbenennungen und
Link-Erstellung geschützt bleiben.

**Least Privilege.** easyONBOARDING benötigt weder lokale Administratorrechte noch Domain-Admin-Rechte.
Das ausführende Konto erhält delegierte Rechte nur für die benötigten OUs und Gruppen
([docs/INSTALLATION.md](V3.0.0/docs/INSTALLATION.md#berechtigungen)). Die Anwendung verändert
die Ausführungsrichtlinie nie, es gibt keine Selbst-Elevation und keine automatische Installation von
Modulen.

**Hilfsskripte zur Einrichtung.** `Install-PS7_PDF.ps1` (Voraussetzungen) und
`Install-easyONBOARDING.ps1` (Konfiguration) sind optional und laufen nur auf ausdrücklichen Aufruf.
Das Voraussetzungs-Skript prüft zunächst nur und ändert nichts ohne Auswahl:

* Installationen (PowerShell 7, RSAT-ActiveDirectory, wkhtmltopdf) nur nach Auswahl und nur, wenn
  PowerShell bereits als Administrator gestartet wurde – das Skript erhöht sich nie selbst.
* PowerShell 7 bevorzugt über winget; das MSI-Fallback wird nur über https geladen und nur ausgeführt,
  wenn es gültig von Microsoft signiert ist (Authenticode). wkhtmltopdf nur per winget.
* Die Ausführungsrichtlinie wird nur nach ausdrücklicher Bestätigung und nur für den aktuellen
  Benutzer auf `RemoteSigned` gesetzt; eine per Gruppenrichtlinie festgelegte Richtlinie bleibt
  unberührt.
* Beim Kopieren des Anwendungsordners bleiben eine vorhandene `Config\easyONB.ini` und
  Unternehmensdateien erhalten; Logs, Berichte und Daten werden nicht kopiert.
* `-CheckOnly` prüft ohne jede Änderung, `-WhatIf` simuliert die gewählten Schritte.

**Kennwörter.** Startkennwörter entstehen mit `System.Security.Cryptography.RandomNumberGenerator`,
liegen nur als `SecureString` im Speicher und werden genau einmal angezeigt. Kopieren in die
Zwischenablage schließt Verlauf und Cloud-Synchronisation aus und leert die Zwischenablage nach
`[Security] ClipboardClearSeconds`. Gedruckt wird aus dem Speicher, ohne Datei. Kennwörter erscheinen
nie in Logs, Audit, Berichten, CSV-/JSON-Dateien, Willkommensdokumenten oder E-Mails; bekannte Werte
werden zusätzlich vor jedem Schreibvorgang maskiert. Ein fester Standardkennwortwert wird nicht
unterstützt.

**Keine Secrets in Dateien.** Die Konfiguration enthält keine Kennwörter, Tokens oder Webhook-URLs.
Entsprechende Legacy-Schlüssel werden erkannt, als Befund gemeldet und nie verwendet. SMTP nutzt ein
Relay ohne Anmeldung oder das Windows-Konto (`UseDefaultCredentials`). Exchange Server wird per
Kerberos, Exchange Online und Microsoft Graph interaktiv verbunden.

**Privilegierte Gruppen und geschützte Konten.** Domain Admins, Enterprise Admins, Schema Admins,
Administratoren, Konten-/Server-/Sicherungs-/Druck-Operatoren, Key Admins, Group Policy Creator Owners,
Domänencontroller-Gruppen, DnsAdmins, Exchange-Verwaltungsgruppen sowie konfigurierte Gruppen und
Muster (`[Security] ProtectedGroups`, `ProtectedGroupPatterns`) werden nie automatisch zugewiesen –
weder über Vorlagen, CSV noch manuelle Auswahl. Erkennung über SIDs/RIDs (sprachunabhängig), Namen,
`adminCount` und verschachtelte Mitgliedschaft. Nie bearbeitet werden: das eigene Konto, eingebaute
Konten (RID 500–504), Notfall- und Dienstkonten sowie konfigurierte Konten und OUs. Das Offboarding
privilegierter Konten ist nur mit `[Security] AllowPrivilegedOffboarding=1` und gesonderter
Bestätigung möglich und läuft nie unbeaufsichtigt.

**Destruktive Aktionen.** Simulation ist Standard. Jede Live-Ausführung zeigt vorher eine Vorschau
und verlangt eine Bestätigung; Massenvorgänge ab `[Bulk] ConfirmationThreshold` und Löschungen eine
Tippbestätigung. Eine endgültige Kontolöschung erfolgt nie automatisch, sondern nur nach Ablauf der
Aufbewahrungsfrist, mit gesichertem Zustandsbericht (Hash-Prüfung), Vorschau und Eingabe
`LÖSCHEN <Konto>`. Alle Schritte werden im Audit-Log festgehalten.

**Eingaben und Ausgaben.** LDAP-/AD-Filterwerte werden maskiert, Pfade gegen Path-Traversal geprüft
(`[FileServer] AllowedRoots`), Berichte HTML-kodiert und CSV-Exporte gegen Formel-Injection geschützt.
Die Plan-Engine ruft nur Funktionen aus `easyONB.*`-Modulen auf; die Konfiguration kann keinen Code
ausführen.

**Protokollierung.** Text- und Audit-Logs enthalten Operation-ID, Akteur, Aktion, Ziel, Ergebnis und
Dauer. Vor Live-Ausführungen wird geprüft, ob das Audit-Log beschreibbar ist.

## Hinweise für bestehende Installationen (1.x)

Die Versionen 1.x (zuletzt 1.3.10 und 1.4.x) haben Kennwörter in Logdateien, Berichte und Welcome-Mails geschrieben
und einen festen Standardkennwortwert vorgesehen (Befunde C-01 bis C-08). Nach dem Umstieg:

1. vorhandene Logdateien (`Logs\*.log`) und Berichte (`Reports\*.html|*.txt|*.pdf`) der Version 1.x
   auf Kennwörter prüfen und gemäß Aufbewahrungsvorgaben sicher löschen,
2. Kennwörter von Konten, deren Startkennwort in solchen Dateien steht, zurücksetzen bzw. die
   Kennwortänderung bei der nächsten Anmeldung erzwingen,
3. `fixPassword`, `CompanyVPNPassword`, `JiraToken`, SMTP-Kennwörter und Webhook-URLs aus allen
   INI-Dateien entfernen (`Scripts/Convert-LegacyConfiguration.ps1`) und betroffene Geheimnisse
   austauschen.

## Code-Signatur

Die Skripte der Version 3 sind im Repository nicht signiert. Für Umgebungen mit `AllSigned` müssen
sie mit dem Codesignaturzertifikat der Organisation signiert werden (nach jeder Änderung erneut).
