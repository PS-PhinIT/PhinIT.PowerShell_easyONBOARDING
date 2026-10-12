# Konfiguration

Die Konfiguration bleibt im INI-Format der Versionen 1.x. Alle Schlüssel mit Typ, Standardwert und
Beschreibung stehen in der [Konfigurationsreferenz](CONFIGURATION-REFERENCE.md), die direkt aus dem
Schema `Config/schemas/easyONB.schema.psd1` erzeugt wird.

## Separater WPF-Konfigurationseditor

`pwsh -STA -NoProfile -File .\Start-easyONBOARDING.ConfigEditor.ps1` im Anwendungsordner
`V3.0.0` startet den Editor ohne die Onboarding-Anwendung oder eine Verbindung zum AD.
Mit `-ConfigPath` lässt sich eine vorhandene INI auswählen.
Neue Konfigurationen basieren auf der mitgelieferten Vorlage. Die Oberfläche bietet
Abschnitte, Suche, Beschreibungen und typgerechte Eingaben, etwa Schalter und Auswahllisten.
Vor dem Speichern werden die Werte gegen das bestehende Schema und die fachlichen Regeln
geprüft. Geheimnisse gehören auch hier nicht in die Datei.
Der Editor bearbeitet nur die ausgewählte Datei, nicht die zusammengeführten Includes.
Unternehmens- und Rollendateien bei Bedarf einzeln öffnen. Nach dem Speichern zusätzlich
die vollständige Konfiguration in der Anwendung prüfen (`Start-easyONBOARDING.ps1 -CheckOnly`);
der Editor prüft keine Erreichbarkeit von AD oder anderen Integrationen.

Handout-Vorlagen mit `Start-easyONBOARDING.ReportEditor.ps1` gestalten und anschließend
unter `[Report] TemplatePathHTML` auswählen. Für die Anwendung gelten weiterhin die
unten beschriebenen Zusammenführungs- und Pfadregeln.

## Dateien und Zusammenführung

| Datei | Zweck |
|---|---|
| `Config/easyONB.ini` | Hauptkonfiguration (aus `easyONB.ini.template` erstellt, nicht versioniert) |
| `Config/templates/*.ini` | Vorlagen: `role-templates.ini` (Rollen für das Onboarding), `offboarding-templates.ini` (Austrittsvorlagen) |
| `Config/companies/*.ini` | weitere Unternehmen/Mandanten (Beispiel: `Company1.ini.example`, zum Aktivieren in `Company1.ini` umbenennen) |
| `Config/schemas/easyONB.schema.psd1` | Schema: Typen, Standardwerte, Pflichtangaben, veraltete Schlüssel |

Geladen wird in dieser Reihenfolge; spätere Werte überschreiben frühere:
`templates/*.ini` → `companies/*.ini` (jeweils alphabetisch) → `easyONB.ini`. Eigene Anpassungen an
Vorlagen daher am besten in `easyONB.ini` vornehmen – die mitgelieferten Vorlagen können dann bei
einem Update ersetzt werden. Der Pfad der Hauptkonfiguration kann mit `-ConfigPath` oder der
Umgebungsvariablen `EASYONB_CONFIG` festgelegt werden; `templates` und `companies` werden relativ
zu dieser Datei gesucht.

## Syntax

```ini
; Kommentar (auch mit #)
[Abschnitt]
Schluessel=Wert
Liste=Wert1;Wert2;Wert3
Schalter=1
Pfad=Reports
```

* **Kodierung:** UTF-8 (mit oder ohne BOM) oder Windows-1252 (ältere Dateien) werden erkannt.
  Beim Schreiben aus der Oberfläche bleiben Kommentare, Reihenfolge und unbekannte Schlüssel erhalten;
  gespeichert wird atomar mit Sicherungskopie.
* **Schalter:** `1`, `true`, `yes`, `ja`, `on` bzw. `0`, `false`, `no`, `nein`, `off`.
* **Listen:** durch `;` getrennt.
* **Pfade:** relativ zum Anwendungsordner `V3.0.0` oder absolut; Umgebungsvariablen
  (`%ProgramData%`, `$env:ProgramData`) sind erlaubt.
* **Doppelte Schlüssel** werden gemeldet, der letzte Wert gilt. **Unbekannte Schlüssel** werden als
  Hinweis gemeldet und nie verworfen.

## Prüfung

`pwsh -File .\Start-easyONBOARDING.ps1 -CheckOnly` bzw. die Ansicht *Einstellungen* zeigen alle
Befunde mit Schwere, Code, Feld und Meldung:

* **Fehler** (z. B. ungültige OU, widersprüchliche Kennwortrichtlinie, fehlende Pflichtangaben einer
  Vorlage): Die Oberfläche startet dann in der Simulation und lässt den Live-Modus nicht zu;
  `Scripts/Invoke-DueOffboardingPhases.ps1` bricht mit Exitcode 2 ab,
* **Warnungen** weisen auf wahrscheinliche Fehlkonfigurationen hin (z. B. Vorlage nicht gefunden),
* **Hinweise** nennen veraltete oder wirkungslose Schlüssel mit Ersatz.

"Neu laden" in den Einstellungen validiert die Datei vor der Übernahme; eine fehlerhafte Datei ersetzt
die geladene Konfiguration nicht.

## Keine Geheimnisse in der Konfiguration

Kennwörter, Tokens, Webhook-URLs oder Verbindungszeichenfolgen gehören nicht in INI-Dateien.
Schlüssel wie `fixPassword`, `CompanyVPNPassword`, `JiraToken` oder `[EmailSettings] Password`
werden erkannt, als Befund gemeldet und nie verwendet. SMTP nutzt ein Relay ohne Anmeldung oder das
Windows-Konto (`UseDefaultCredentials=1`); Exchange und Graph werden interaktiv bzw. per Kerberos
verbunden.

## Wichtige Bereiche

### Unternehmen

```ini
[Company]
CompanyNameFirma=Example GmbH
CompanyActiveDirectoryDomain=example.com
CompanyActiveDirectoryOU=OU=Mitarbeiter,DC=example,DC=local
CompanyMailDomain=@example.com
; Optional: sekundäre Proxyadresse, z. B. @<Mandant>.onmicrosoft.com
CompanyMS365Domain=
```

Weitere Unternehmen stehen in `[Company1]`, `[Company2]` … (in der Hauptdatei oder in
`Config/companies/*.ini`). Schlüssel dürfen die Nummer als Suffix tragen (`CompanyMailDomain1`), wie in
Version 1.x. Zulässige Mail-Domänen zusätzlich in `[MailEndungen]`.

### Kontonamen

```ini
[DisplayNameUPNTemplates]
DefaultDisplayNameFormat={first} {last}
; Legacy-Schlüsselwörter (FIRSTNAME.LASTNAME, F.LASTNAME ...) oder Platzhalter
DefaultUserPrincipalNameFormat={first}.{last}

[Identity]
SamAccountNameFormat={f}{last}
CollisionStrategy=AppendNumber
MaxSamAccountNameLength=20
```

Platzhalter: `{first}` (erster Vorname), `{firstfull}` (alle Vornamen), `{last}`, `{f}`/`{l}`
(Initialen), `{first:N}`/`{last:N}` (erste N Zeichen), `{employeeid}`. Umlaute und Sonderzeichen
werden transliteriert (`ä` → `ae`, `ß` → `ss`, …; ergänzbar über `[NameNormalization] Transliteration`).
Details: [ONBOARDING.md](ONBOARDING.md#kontonamen).

### Kennwörter

```ini
[PasswordFixGenerate]
DefaultPasswordLength=16
MinUpperCase=2
MinLowerCase=2
MinDigits=2
MinSpecialChars=1
AvoidAmbiguousChars=True

[Security]
AllowManualPassword=1
ShowPasswordOnce=1
AllowCredentialPrint=1
ClipboardClearSeconds=30
UseDomainPasswordPolicy=1
```

Ist `UseDomainPasswordPolicy=1`, gelten Mindestlänge und Komplexität der Domänenrichtlinie
zusätzlich (der strengere Wert gewinnt).

### Sicherheit und Schutz

```ini
[Security]
SimulationByDefault=1
ProtectedGroups=
ProtectedGroupPatterns=*Admin*
ProtectedAccounts=
BreakGlassAccounts=notfall-admin1
ServiceAccountPatterns=svc_*;svc-*;*_svc;sa_*
ProtectedOUs=OU=Administration,DC=example,DC=local
AllowPrivilegedOffboarding=0
```

Die eingebauten privilegierten Gruppen (Domain Admins, Enterprise Admins, Schema Admins usw.) sind
immer geschützt; die Einstellungen ergänzen diese Liste.

### Gruppen, Lizenzen und Rollen

```ini
[UserCreationDefaults]
InitialGroupMembership=GRP-Alle

[LicensesGroups]
MS365_E3=GRP-Lizenz-E3

[ADGroups]
Vertrieb=GRP-Vertrieb

[RoleTemplate.Vertrieb]
DisplayName=Vertrieb Innendienst
Groups=GRP-Vertrieb;GRP-VPN-Benutzer
License=MS365_E3
Department=Vertrieb
```

### Offboarding und Massenverarbeitung

```ini
[Offboarding]
DefaultTemplate=Standard
DisabledUsersOU=OU=Ausgeschieden,DC=example,DC=local
RequireTicket=1
KeepGroups=

[Bulk]
MaxRows=500
ConfirmationThreshold=25
PasswordDelivery=Discard
```

Aufbau der Offboarding-Vorlagen (`[OffboardingTemplate.<Name>]` mit `Action.<Aktion>=<Phase>`):
[OFFBOARDING.md](OFFBOARDING.md#vorlagen).

### Berichte und E-Mail

```ini
[Report]
ReportPath=Reports
Formats=Html;Json
PdfEngine=Auto
CreateWelcomeDocument=1
TemplatePathHTML=ReportTemplates/HTMLTemplate.txt

[EmailSettings]
SMTPServer=smtp.example.local
SMTPPort=25
UseSSL=1
FromAddress=it-service@example.com
SendWelcomeEmail=0
```

Platzhalter der HTML-Vorlagen: [ReportTemplates/README.md](../ReportTemplates/README.md). Kennwort-Platzhalter
werden nie befüllt.

### Integrationen

```ini
[Exchange]
; None, Online, OnPremises, Hybrid
Mode=None
OnPremisesUri=
RemoteRoutingDomain=

[Graph]
Enabled=0
TenantId=

[ADSync]
EnableADSync=0
ADSyncServer=
PolicyType=Delta
```

Alle Integrationen sind standardmäßig aus. Ihr Zustand wird im Dashboard und von `-CheckOnly`
angezeigt.

### Oberfläche

```ini
[UI]
Theme=Light
AccentColor=#0F6CBD
LogoPath=
```

Farbschema und Akzentfarbe lassen sich auch in der Ansicht *Einstellungen* ändern und speichern.
Die Schriftfarbe auf Akzentflächen (Schwarz oder Weiß) wird nach dem WCAG-Kontrastverhältnis gewählt;
im dunklen Schema werden sehr dunkle Akzentfarben aufgehellt.
