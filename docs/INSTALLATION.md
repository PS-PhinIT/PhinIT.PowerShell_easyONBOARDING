# Installation und Betrieb

## Voraussetzungen

| Komponente | Anforderung | Hinweis |
|---|---|---|
| Betriebssystem | Windows 10/11 oder Windows Server 2019+ | für die Oberfläche (WPF); `-CheckOnly` und Tests auch unter Linux/macOS |
| PowerShell | 7.2 oder höher | [Installation](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows) durch die IT |
| Active Directory | Modul `ActiveDirectory` (RSAT) | Windows 10/11: `Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0`; Server: `Install-WindowsFeature RSAT-AD-PowerShell` |
| PDF (optional) | Microsoft Edge, alternativ wkhtmltopdf | ohne PDF-Engine werden HTML-Berichte erzeugt |
| Exchange Online (optional) | Modul `ExchangeOnlineManagement` | interaktiv oder Zertifikat (`[Exchange] AppId`, `CertificateThumbprint`, `Organization`) |
| Exchange Server (optional) | Remote-PowerShell-Endpunkt, Kerberos | `[Exchange] OnPremisesUri` |
| Exchange Hybrid (optional) | beides: Exchange-Server-Endpunkt **und** `ExchangeOnlineManagement` | `OnPremisesUri`, `RemoteRoutingDomain` |
| Microsoft Graph (optional) | `Microsoft.Graph.Authentication`, `Microsoft.Graph.Users.Actions` | delegiert: `User.Read.All`, `User.RevokeSessions.All`; Zertifikat: `[Graph] ClientId`, `CertificateThumbprint`, `TenantId` |
| Entra Connect Sync (optional) | WinRM zum Synchronisationsserver | Mitgliedschaft in `ADSyncOperators` auf dem Server |

easyONBOARDING installiert keine Module und ändert keine Systemeinstellungen. Fehlende Komponenten
zeigt das Dashboard bzw. `-CheckOnly` mit Hinweis an. Optionale Module installiert die IT bei
Bedarf gezielt, z. B. mit `Install-PSResource <Name> -Scope CurrentUser`.

### Voraussetzungen einrichten (Install-PS7_PDF.ps1, optional)

Das Hilfsskript prüft PowerShell 7, das ActiveDirectory-Modul, die PDF-Erzeugung (Edge/wkhtmltopdf)
und die Ausführungsrichtlinie und richtet Fehlendes **nur auf Auswahl** ein. Es läuft auch unter
Windows PowerShell 5.1, also bevor PowerShell 7 installiert ist:

```powershell
# nur prüfen, nichts ändern (Exitcode 1, wenn Pflichtvoraussetzungen fehlen)
powershell.exe -NoProfile -File .\Install-PS7_PDF.ps1 -CheckOnly

# Oberfläche: Punkte auswählen und "Auswahl ausführen"
powershell.exe -STA -NoProfile -File .\Install-PS7_PDF.ps1

# ohne Oberfläche aus einer Administrator-PowerShell; -WhatIf simuliert
& .\Install-PS7_PDF.ps1 -Install PowerShell7,ActiveDirectory
```

* Installationen erfordern eine als Administrator gestartete PowerShell; das Skript erhöht sich nicht
  selbst. Ohne Administratorrechte sind die Installationspunkte gesperrt.
* PowerShell 7 wird per winget installiert, sonst als MSI (`-PowerShellMsiUrl`, nur https), das nur
  ausgeführt wird, wenn es gültig von Microsoft signiert ist. RSAT kommt auf Clients als
  Windows-Funktion, auf Servern als Windows-Feature. wkhtmltopdf nur per winget und nur, wenn Edge fehlt.
* Die Ausführungsrichtlinie wird nur nach Rückfrage (bzw. mit `-Install ExecutionPolicy`) und nur für
  den aktuellen Benutzer auf `RemoteSigned` gesetzt; per Gruppenrichtlinie festgelegt bleibt sie
  unverändert.
* Optional kopiert das Skript den Anwendungsordner in ein Zielverzeichnis (Standard
  `C:\easyIT\easyONBOARDING`, `-TargetPath`). Logs, Berichte und Daten werden nicht kopiert, eine
  vorhandene `Config\easyONB.ini` und Unternehmensdateien bleiben erhalten.

## Installation

1. Den Ordner `V3.0.0` (mit der Datei `VERSION` aus dem Repository-Stamm) in ein Verzeichnis
   kopieren, auf das nur die IT-Administration Schreibzugriff hat, z. B.
   `D:\Tools\easyONBOARDING\V3.0.0` – manuell oder mit `Install-PS7_PDF.ps1` (siehe oben).
2. Nach dem Download einer ZIP-Datei die Dateien freigeben:
   `Get-ChildItem -Path D:\Tools\easyONBOARDING -Recurse | Unblock-File`.
3. Ausführungsrichtlinie: easyONBOARDING ändert sie nicht und benötigt kein `Bypass`. Empfohlen ist
   `RemoteSigned` (lokale, freigegebene Skripte) bzw. `AllSigned`, wenn die Skripte mit dem
   Codesignaturzertifikat der Organisation signiert werden.
4. Konfiguration anlegen, am einfachsten mit dem Installer (siehe unten):
   `pwsh -STA -NoProfile -File .\Install-easyONBOARDING.ps1`. Alternativ manuell
   `Copy-Item .\Config\easyONB.ini.template .\Config\easyONB.ini` und anpassen
   ([CONFIGURATION.md](CONFIGURATION.md)) oder eine Konfiguration der Version 1.x übernehmen
   ([MIGRATION.md](MIGRATION.md)).
5. Prüfen: `pwsh -NoProfile -File .\Start-easyONBOARDING.ps1 -CheckOnly` (Exitcode 0 = keine Fehler,
   2 = Fehler in der Konfiguration). Warnungen und Hinweise beachten.
6. Starten: `pwsh -NoProfile -File .\Start-easyONBOARDING.ps1`. Eine Verknüpfung kann auf
   `pwsh.exe -NoProfile -File "D:\Tools\easyONBOARDING\V3.0.0\Start-easyONBOARDING.ps1"` zeigen.

### Installer (Install-easyONBOARDING.ps1)

Der Installer erstellt `Config\easyONB.ini` aus der Vorlage über eine eigene Oberfläche mit den
Seiten Unternehmen, Active Directory, Dateien und E-Mail, Integrationen, Sicherheit und Darstellung
sowie Prüfen und erstellen. Zu jedem Feld und Bereich erscheint nach 250 ms ein Hinweistext.

* **Auf einem Domänencontroller** (mit ActiveDirectory-Modul) werden vorbelegt: UPN-Suffixe und
  E-Mail-Domäne, Domänencontroller, Ziel-OU und OU für ausgeschiedene Konten, Suchbasis, bei
  vorhandenem Entra Connect Server und Mandant (aus dem Konto `MSOL_…`) sowie bei vorhandener
  Exchange-Organisation Endpunkt, Betriebsart und Routingdomäne. "Werte aus dem AD laden" liest
  erneut. Alle Werte bleiben änderbar.
* **Auf einem Client oder Mitgliedsserver** werden alle Werte manuell eingetragen; Pflichtfelder
  sind mit `*` markiert.
* "Eingaben prüfen" meldet fehlende Pflichtfelder und ungültige Formate. "Konfiguration erstellen"
  schreibt die Datei (UTF-8, Kommentare der Vorlage bleiben erhalten), entfernt auf Wunsch die
  Beispieldaten der Vorlage und lädt das Ergebnis mit derselben Prüfung wie die Anwendung. Eine
  vorhandene Datei wird nur nach Rückfrage ersetzt und vorher als `.bak` gesichert.
* Der Installer schreibt keine Kennwörter, ändert keine Ausführungsrichtlinie und installiert
  keine Module. Gruppen, Lizenzgruppen und Offboarding-Vorlagen danach in der INI bzw. unter
  `Config\templates` ergänzen.

Parameter von `Start-easyONBOARDING.ps1`: `-ConfigPath` (sonst `Config\easyONB.ini` bzw. Umgebungsvariable
`EASYONB_CONFIG`), `-CheckOnly`, `-Simulation` (erzwingt den Simulationsmodus), `-Theme Light|Dark`.

## Berechtigungen

easyONBOARDING benötigt **keine lokalen Administratorrechte** und **keine Domain-Admin-Rechte**. Es
arbeitet mit den Rechten des angemeldeten Kontos. Empfohlen ist ein eigenes IT-Konto mit delegierten
Rechten (Assistent "Objektverwaltung zuweisen" bzw. `dsacls`), beschränkt auf die betroffenen OUs:

| Aufgabe | Benötigte Rechte |
|---|---|
| Onboarding | Benutzerobjekte in den Ziel-OUs erstellen; Eigenschaften der angelegten Benutzer schreiben; Erweitertes Recht *Kennwort zurücksetzen*; `pwdLastSet` schreiben (Kennwortänderung bei Anmeldung) |
| Gruppen zuweisen/entfernen | *Mitglieder schreiben* (`member`) nur auf den verwendeten Gruppen |
| Benutzer aktualisieren | Eigenschaften schreiben (Attribute, `manager`); *Kennwort zurücksetzen* nur für die Reset-Funktion |
| Offboarding | `userAccountControl`, `accountExpires`, `logonHours`, `description`, `manager` schreiben; *Kennwort zurücksetzen*; Verschieben: Löschen in der Quell-OU und Erstellen in `[Offboarding] DisabledUsersOU` |
| Endgültige Löschung | Benutzerobjekte in der Ausgeschieden-OU löschen – nur für die Personen, die Löschungen freigeben |
| Home-Verzeichnisse | NTFS-Rechte unter `[FileServer] AllowedRoots` bzw. `ArchiveRoot` (Ordner anlegen, verschieben, Berechtigungen setzen) |
| Exchange | Server/Hybrid: Rollen *Mail Recipient Creation* und *Mail Recipients* (z. B. über die Rollengruppe *Recipient Management*); Online: Entra-Rolle *Exchange Recipient Administrator* oder eine gleichwertige RBAC-Rolle |
| Microsoft Graph | delegierte Berechtigungen `User.Read.All` und `User.RevokeSessions.All` mit Administratorzustimmung; für die Zertifikatsanmeldung die Anwendungsberechtigung `User.RevokeSessions.All` |
| Entra Connect Sync | WinRM-Zugriff und Mitgliedschaft in der lokalen Gruppe `ADSyncOperators` auf dem Synchronisationsserver |

Privilegierte Gruppen und geschützte Konten bearbeitet easyONBOARDING unabhängig von den Rechten nie
([SECURITY.md](../../SECURITY.md)).

## Datenablage und Schutz

| Verzeichnis | Inhalt | Empfehlung |
|---|---|---|
| `Logs\` | Textlogs (täglich, `easyONB_yyyyMMdd.log`), Rotation nach `[Logging] MaxFileSizeMB` | nur IT lesend/schreibend |
| `Logs\audit\` | Audit-Log (monatlich, `easyONB_audit_yyyyMM.jsonl`) | nur IT; Aufbewahrung nach `[Logging] AuditRetentionDays` |
| `Reports\` | Vorgangsberichte, Willkommensdokumente, Zustandsberichte (`Reports\Offboarding`) | nur IT; enthält personenbezogene Daten |
| `Data\OffboardingQueue\` | Warteschlange des Offboardings (JSON je Vorgang, keine Secrets) | nur IT |

Pfade lassen sich in `[Logging]`, `[Report]` und `[Paths]` ändern. Ist ein Logverzeichnis nicht
beschreibbar (oder das konfigurierte Laufwerk nicht vorhanden), verwendet easyONBOARDING
`%LOCALAPPDATA%\easyONBOARDING\Logs` und zeigt dies in der Statusleiste an. Live-Ausführungen setzen
ein beschreibbares Audit-Log voraus.

## Geplante Aufgabe für Folgephasen des Offboardings

Phasen wie "Zum Austritt" oder "Aufbewahrung" werden zum Fälligkeitstag entweder in der Oberfläche
(Offboarding › Warteschlange) oder automatisch ausgeführt:

```powershell
pwsh.exe -NoProfile -NonInteractive -File "D:\Tools\easyONBOARDING\V3.0.0\Scripts\Invoke-DueOffboardingPhases.ps1"
```

* Konto: am besten ein gruppenverwaltetes Dienstkonto (gMSA) mit den delegierten Offboarding-Rechten
  und dem Recht "Als Batchauftrag anmelden"; keine Domain-Admin-Rechte.
* Zeitplan: täglich, z. B. 06:00 Uhr. Zuerst mit `-WhatIf` testen.
* Das Skript löscht **nie** Konten, bearbeitet **keine** privilegierten Konten und führt Phasen mit
  Exchange-/Graph-Aktionen nur mit `-AllowIntegration` und hergestellter Verbindung aus. Exchange
  Server verbindet es per Kerberos. Exchange Online (auch Hybrid) und Graph verbindet es nur mit
  Zertifikatsanmeldung (siehe unten), sonst werden diese Phasen als "manuell erforderlich" gemeldet.

### Zertifikatsanmeldung für Exchange Online und Microsoft Graph

Für den unbeaufsichtigten Betrieb meldet sich das Skript als Anwendung an. In der Konfiguration
stehen nur IDs und der Fingerabdruck; der private Schlüssel bleibt im Zertifikatspeicher des
ausführenden Kontos (`Cert:\CurrentUser\My`, bei gMSA bzw. Dienstkonto dessen Speicher).

1. In Entra ID eine App-Registrierung anlegen und das öffentliche Zertifikat hochladen.
2. Exchange Online: API-Berechtigung *Office 365 Exchange Online › Exchange.ManageAsApp*
   (Anwendung) mit Administratorzustimmung und der App die Entra-Rolle *Exchange Recipient
   Administrator* zuweisen.
3. Microsoft Graph: Anwendungsberechtigung `User.RevokeSessions.All` mit Administratorzustimmung.
4. In der INI eintragen (die Oberfläche nutzt das Zertifikat dann ebenfalls):

```ini
[Exchange]
AppId=<Anwendungs-ID>
CertificateThumbprint=<40 Hexadezimalzeichen>
Organization=<mandant>.onmicrosoft.com

[Graph]
TenantId=<mandant>.onmicrosoft.com
ClientId=<Anwendungs-ID>
CertificateThumbprint=<40 Hexadezimalzeichen>
```

Fehlt eine der drei Angaben, meldet die Konfigurationsprüfung `CFG_CERTIFICATE_AUTH_INCOMPLETE`
und es wird interaktiv angemeldet.
* Exitcodes: 0 = in Ordnung, 1 = mindestens ein Vorgang blockiert oder fehlgeschlagen,
  2 = Konfiguration oder AD-Verbindung fehlerhaft. Details stehen im Log und je Vorgang im Bericht.

## Aktualisieren und Entfernen

* **Aktualisieren:** neuen Versionsordner neben den alten legen, `Config\easyONB.ini`, `Config\companies`
  und eigene Vorlagen übernehmen, `-CheckOnly` ausführen. `Logs`, `Reports` und `Data` können
  übernommen oder über die Konfiguration an einen festen Ort gelegt werden.
* **Entfernen:** geplante Aufgabe löschen, Ordner entfernen. Logs, Berichte und Warteschlange gemäß
  den Aufbewahrungsvorgaben der Organisation archivieren oder löschen.
