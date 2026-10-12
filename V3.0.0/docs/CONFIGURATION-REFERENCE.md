# Konfigurationsreferenz

> Automatisch erzeugt aus `Config/schemas/easyONB.schema.psd1` mit
> `Scripts/Export-EobConfigurationReference.ps1`. Bitte nicht von Hand bearbeiten.

Erläuterungen zu Aufbau, Zusammenführung und Beispielen: [CONFIGURATION.md](CONFIGURATION.md).

Kennzeichnungen: **Pflicht** = muss gesetzt sein · *Veraltet* = wird noch gelesen, bitte durch den
Ersatz austauschen · *Ohne Wirkung* = wird in 3.x nicht ausgewertet · **Secret – wird ignoriert** =
Klartext-Geheimnisse werden nicht unterstützt, gemeldet und nie verwendet.

## [ScriptInfo]

*Veralteter Abschnitt.* Legacy-Versionsangaben (Version stammt ab 3.0 aus der Datei VERSION).

| Schlüssel | Typ | Standard | Beschreibung |
|---|---|---|---|
| `ScriptVersion` | String | – | *Ohne Wirkung.* Veraltet, wird ignoriert. |
| `LastUpdate` | String | – | *Ohne Wirkung.* Veraltet, wird ignoriert. |
| `Author` | String | – | *Ohne Wirkung.* Veraltet, wird ignoriert. |

## [Logging]

Protokollierung und Audit.

| Schlüssel | Typ | Standard | Beschreibung |
|---|---|---|---|
| `LogFile` | Path | `Logs` | Verzeichnis für Textlogs (relativ zur Anwendungswurzel oder absolut). |
| `ExtraFile` | Path | – | *Veraltet.* Ersatz: `Logging.AuditDirectory`. Veraltet. |
| `AuditDirectory` | Path | – | Verzeichnis für Audit-Logs (leer = &lt;LogFile&gt;\audit). |
| `DebugMode` | Bool | `0` | 1 = Debug-Einträge protokollieren (entspricht MinimumLevel=Debug). |
| `MinimumLevel` | Enum (Debug, Information, Warning, Error, Critical) | `Information` | Minimales Level für Textlogs. |
| `RetentionDays` | Int (1–3650) | `90` | Aufbewahrung Textlogs in Tagen. |
| `AuditRetentionDays` | Int (0–36500) | `0` | Aufbewahrung Audit-Logs in Tagen (0 = unbegrenzt). |
| `MaxFileSizeMB` | Int (1–1024) | `20` | Maximale Größe einer Logdatei. |

## [RemoteExecution]

*Veralteter Abschnitt.* Legacy-Abschnitt.

| Schlüssel | Typ | Standard | Beschreibung |
|---|---|---|---|
| `Enable` | Bool | – | *Ohne Wirkung.* Veraltet, wird ignoriert. |
| `DefaultDCServerName` | String | – | *Veraltet.* Ersatz: `ActiveDirectory.PreferredDomainController`. Wird als bevorzugter DC verwendet, wenn ActiveDirectory.PreferredDomainController leer ist. |

## [ActiveDirectory]

Active-Directory-Verbindung und Suche.

| Schlüssel | Typ | Standard | Beschreibung |
|---|---|---|---|
| `PreferredDomainController` | String | – | Fester (beschreibbarer) Domänencontroller. Leer = automatische Auswahl, alle Schritte eines Vorgangs nutzen denselben DC. |
| `SearchBase` | Dn | – | Optionale Einschränkung der Benutzersuche. |
| `MaxSearchResults` | Int (1–500) | `50` | Maximale Trefferzahl der Benutzersuche. |

## [WPFGUI]

Branding der Oberfläche.

| Schlüssel | Typ | Standard | Beschreibung |
|---|---|---|---|
| `APPName` | String | `easyONBOARDING` | Anzeigename im Fenstertitel und Kopfbereich. |
| `ThemeColor` | String | – | *Ohne Wirkung.* Ersatz: `UI.AccentColor`. Veraltet (Legacy-Farbe), siehe [UI]. |
| `BoxColor` | String | – | *Ohne Wirkung.* Veraltet, wird ignoriert. |
| `RahmenColor` | String | – | *Ohne Wirkung.* Veraltet, wird ignoriert. |
| `LogoURL` | Url | – | Link hinter dem Logo (nur https). |
| `FooterText` | String | – | Zusatztext in der Statusleiste. |
| `FooterWebseite` | String | – | Webseite in der Info-Ansicht. |

## [WPFGUITypography]

Schriftarten der Oberfläche.

| Schlüssel | Typ | Standard | Beschreibung |
|---|---|---|---|
| `DefaultFontFamily` | String | `Segoe UI` | Standardschriftart. |
| `DefaultFontSize` | Int (10–20) | `13` | Standardschriftgröße. |
| `HeaderFontSize` | Int (12–32) | `20` | Schriftgröße der Überschriften. |
| `FooterFontSize` | Int (9–18) | `11` | Schriftgröße der Statusleiste. |

## [WPFGUILogos]

Legacy-Logo- und Iconpfade.

| Schlüssel | Typ | Standard | Beschreibung |
|---|---|---|---|
| `OnboardingLogo` | Path | – | *Veraltet.* Ersatz: `UI.LogoPath`. Wird als Logo verwendet, wenn UI.LogoPath leer ist. |
| `ADUpdateLogo` | Path | – | *Ohne Wirkung.* Veraltet, wird ignoriert. |
| `TabOnboardingIcon` | Path | – | *Ohne Wirkung.* Veraltet, wird ignoriert. |
| `TabADUpdateIcon` | Path | – | *Ohne Wirkung.* Veraltet, wird ignoriert. |
| `InfoIcon` | Path | – | *Ohne Wirkung.* Veraltet, wird ignoriert. |
| `SettingsIcon` | Path | – | *Ohne Wirkung.* Veraltet, wird ignoriert. |
| `CloseIcon` | Path | – | *Ohne Wirkung.* Veraltet, wird ignoriert. |

## [UI]

Darstellung der Oberfläche (ab 3.0).

| Schlüssel | Typ | Standard | Beschreibung |
|---|---|---|---|
| `Theme` | Enum (Light, Dark) | `Light` | Farbschema. |
| `AccentColor` | Color | `#0F6CBD` | Akzentfarbe (Branding) als #RRGGBB. |
| `LogoPath` | Path | – | Optionales Logo (PNG/JPG) im Kopfbereich. |

## [Security]

Sicherheitsrichtlinien (ab 3.0).

| Schlüssel | Typ | Standard | Beschreibung |
|---|---|---|---|
| `SimulationByDefault` | Bool | `1` | Neue Vorgänge starten im Simulationsmodus. |
| `AllowManualPassword` | Bool | `1` | Manuelle Kennworteingabe (je Vorgang) erlauben. |
| `ShowPasswordOnce` | Bool | `1` | Generiertes Kennwort nach der Ausführung einmalig anzeigen. |
| `AllowCredentialPrint` | Bool | `1` | Druck des Zugangsdatenblatts aus dem Speicher erlauben. |
| `ClipboardClearSeconds` | Int (0–600) | `30` | Zwischenablage nach N Sekunden leeren (0 = Kopieren deaktiviert). |
| `ProtectedGroups` | List | – | Zusätzliche geschützte Gruppen (Name, DN oder SID). |
| `ProtectedGroupPatterns` | List | `*Admin*` | Namensmuster geschützter Gruppen (Platzhalter *). |
| `ProtectedAccounts` | List | – | Konten, die nie bearbeitet werden dürfen (SamAccountName oder SID). |
| `BreakGlassAccounts` | List | – | Notfallkonten (werden nie bearbeitet). |
| `ServiceAccountPatterns` | List | `svc_*;svc-*;*_svc;sa_*` | Namensmuster von Dienstkonten (werden nie bearbeitet). |
| `ProtectedOUs` | List | – | OUs, deren Konten nie bearbeitet werden (DN). |
| `AllowPrivilegedOffboarding` | Bool | `0` | Offboarding privilegierter Konten nach gesonderter Bestätigung erlauben. |
| `UseDomainPasswordPolicy` | Bool | `1` | Domänen-Kennwortrichtlinie (Mindestlänge, Komplexität) zusätzlich berücksichtigen. |

## [Report]

Berichte und Vorlagen.

| Schlüssel | Typ | Standard | Beschreibung |
|---|---|---|---|
| `UserOnboardingCreateTXT` | Bool | – | *Veraltet.* Ersatz: `Report.Formats`. 1 = TXT zusätzlich erzeugen (wird auf Formats abgebildet). |
| `ReportPath` | Path | `Reports` | Ablageverzeichnis für Berichte. |
| `ReportTitle` | String | `easyONBOARDING Bericht` | Berichtstitel. |
| `ReportHeader` | String | – | Überschrift im Willkommensdokument. |
| `ReportFooter` | String | – | Fußzeile der Berichte. |
| `ReportThemeColor` | String | – | *Ohne Wirkung.* Veraltet, wird ignoriert. |
| `ReportFontFamily` | String | – | *Ohne Wirkung.* Veraltet, wird ignoriert. |
| `ReportFontSize` | String | – | *Ohne Wirkung.* Veraltet, wird ignoriert. |
| `TemplatePathHTML` | Path | `ReportTemplates/HTMLTemplate.txt` | HTML-Vorlage des Willkommensdokuments (Kennwort-Platzhalter werden nie befüllt). |
| `TemplatePathTXT` | Path | – | *Ohne Wirkung.* Legacy-TXT-Vorlage (wird nicht mehr verwendet, TXT-Berichte werden generiert). |
| `TemplateLogo` | Path | – | Logo für HTML-Berichte. |
| `wkhtmltopdfPath` | Path | – | Pfad zu wkhtmltopdf.exe (Legacy-PDF-Engine, optional). |
| `EdgePath` | Path | – | Optionaler Pfad zu msedge.exe (sonst Standard-Installationspfade). |
| `PdfTimeoutSeconds` | Int (5–300) | `60` | Zeitlimit der PDF-Erzeugung in Sekunden. |
| `Formats` | List | `Html;Json` | Berichtsformate: Html, Json, Csv, Txt, Pdf. |
| `PdfEngine` | Enum (Auto, Edge, Wkhtmltopdf, None) | `Auto` | PDF-Erzeugung (Auto = Edge, sonst wkhtmltopdf, sonst HTML). |
| `CreateWelcomeDocument` | Bool | `1` | *Ohne Wirkung.* Legacy-Schlüssel, wird ignoriert: Das Onboarding-Handout aus TemplatePathHTML wird immer erzeugt (ohne Kennwort). |

## [CustomPWLabels]

*Veralteter Abschnitt.* Legacy: Zusatzkennwörter werden aus Sicherheitsgründen nicht mehr erzeugt.

Freie Schlüssel (Bezeichnung=Wert), Werttyp: String.

## [Websites]

Links im Willkommensdokument (Format: Bezeichnung \| URL \| Beschreibung).

Freie Schlüssel (Bezeichnung=Wert), Werttyp: String.

## [ReportPlaceholders]

Zusätzliche Platzhalter des Willkommensdokuments ({{Name}} = Wert). Kennwort-Platzhalter werden nie befüllt.

Freie Schlüssel (Bezeichnung=Wert), Werttyp: String.

## [ADUserDefaults]

Standardwerte für neue Benutzerkonten.

| Schlüssel | Typ | Standard | Beschreibung |
|---|---|---|---|
| `DefaultOU` | Dn | – | Standard-Ziel-OU (DN). |
| `AccountDisabled` | Bool | `True` | Neue Konten deaktiviert anlegen (Aktivierung zum Startdatum). |
| `PasswordNeverExpires` | Bool | `False` | Kennwort läuft nie ab (nicht empfohlen). |
| `MustChangePasswordAtLogon` | Bool | `True` | Kennwortänderung bei der ersten Anmeldung erzwingen. |
| `SmartcardLogonRequired` | Bool | `False` | Smartcard-Anmeldung erforderlich. |
| `CannotChangePassword` | Bool | – | *Ohne Wirkung.* Nicht unterstützt, wird ignoriert. |
| `HomeLWLetter` | String | `H` | Laufwerksbuchstabe des Home-Verzeichnisses. |
| `HomeDirectory` | String | – | Home-Verzeichnis (%username% wird ersetzt). |
| `ProfilePath` | String | – | Profilpfad (%username% wird ersetzt). |
| `LogonScript` | String | – | Anmeldeskript. |

## [DisplayNameUPNTemplates]

Vorlagen für Anzeigename und UPN.

| Schlüssel | Typ | Standard | Beschreibung |
|---|---|---|---|
| `DefaultDisplayNameFormat` | Template | `{first} {last}` | Standardformat des Anzeigenamens. |
| `DefaultUserPrincipalNameFormat` | String | `FIRSTNAME.LASTNAME` | UPN-Format (Legacy-Schlüsselwort wie FIRSTNAME.LASTNAME oder Platzhalter wie {first}.{last}). |
| Muster `^DisplayNameTemplate\d+$` | String | – | Weitere Anzeigenamen-Vorlage ("Bezeichnung\|Vorlage" oder "Vorlage"). |

## [Identity]

Kontonamen und Kollisionsbehandlung (ab 3.0).

| Schlüssel | Typ | Standard | Beschreibung |
|---|---|---|---|
| `SamAccountNameFormat` | Template | `{f}{last}` | Format des SamAccountName. |
| `MailFormat` | Template | – | Format des lokalen Teils der E-Mail-Adresse (leer = wie UPN). |
| `CollisionStrategy` | Enum (AppendNumber, Fail) | `AppendNumber` | Verhalten bei belegten Namen. |
| `CollisionStartNumber` | Int (1–99) | `2` | Erste angehängte Zahl. |
| `MaxCollisionAttempts` | Int (1–99) | `20` | Maximale Anzahl Versuche. |
| `LowerCaseIdentifiers` | Bool | `1` | SamAccountName, UPN und E-Mail kleinschreiben. |
| `MaxSamAccountNameLength` | Int (1–20) | `20` | Maximale Länge des SamAccountName (AD-Limit 20). |

## [NameNormalization]

Umlaute, Sonderzeichen und Transliteration.

| Schlüssel | Typ | Standard | Beschreibung |
|---|---|---|---|
| `Enabled` | Bool | – | *Ohne Wirkung.* Veraltet: Normalisierung ist immer aktiv. |
| `ReplaceSpecialChars` | String | – | Legacy-Ersetzungen im Format a=b;c=d (werden zusätzlich angewendet). |
| `NormalizeCase` | Bool | – | *Veraltet.* Ersatz: `Identity.LowerCaseIdentifiers`. Veraltet. |
| `Transliteration` | String | – | Zusätzliche/abweichende Ersetzungen im Format ä=ae;ø=oe. Für einzelne Kleinbuchstaben wird die Großschreibung automatisch ergänzt, sofern nicht explizit angegeben. |
| `KeepHyphen` | Bool | `1` | Bindestriche in Kontonamen beibehalten. |

## [ValidateUPN]

*Veralteter Abschnitt.* Legacy-Abschnitt (Duplikatprüfung ist ab 3.0 immer aktiv).

| Schlüssel | Typ | Standard | Beschreibung |
|---|---|---|---|
| `CheckForDuplicates` | Bool | – | *Ohne Wirkung.* Veraltet: Prüfung ist immer aktiv. |
| `AppendRandomOnConflict` | Bool | – | *Veraltet.* Ersatz: `Identity.CollisionStrategy`. Veraltet: deterministische Nummerierung statt Zufall. |

## [PasswordFixGenerate]

Kennwortgenerierung.

| Schlüssel | Typ | Standard | Beschreibung |
|---|---|---|---|
| `fixPassword` | String | – | **Secret – wird ignoriert.** *Veraltet.* Nicht mehr unterstützt: feste Standardkennwörter sind ein Sicherheitsrisiko. |
| `DefaultPasswordLength` | Int (12–128) | `16` | Länge generierter Kennwörter. |
| `MinDigits` | Int (0–20) | `2` | Mindestanzahl Ziffern. |
| `MinUpperCase` | Int (0–20) | `2` | Mindestanzahl Großbuchstaben. |
| `MinLowerCase` | Int (0–20) | `2` | Mindestanzahl Kleinbuchstaben. |
| `MinSpecialChars` | Int (0–20) | `1` | Mindestanzahl Sonderzeichen (0 wenn IncludeSpecialChars=False). |
| `MinNonAlpha` | Int (0–20) | `2` | Mindestanzahl nicht-alphabetischer Zeichen. |
| `IncludeSpecialChars` | Bool | `True` | Sonderzeichen verwenden. |
| `AvoidAmbiguousChars` | Bool | `True` | Verwechselbare Zeichen (Il1O0) vermeiden. |
| `SpecialCharacters` | String | `!#%*+-=?@_` | Zulässige Sonderzeichen. |
| `MinManualPasswordLength` | Int (8–128) | `12` | Mindestlänge manuell eingegebener Kennwörter. |

## [CompanyHelpdesk]

Helpdesk-Angaben für das Willkommensdokument.

| Schlüssel | Typ | Standard | Beschreibung |
|---|---|---|---|
| `CompanyITMitarbeiter` | String | – | Ansprechpartner IT. |
| `CompanyHelpdeskMail` | Email | – | Helpdesk-E-Mail. |
| `CompanyHelpdeskTel` | String | – | Helpdesk-Telefon. |

## [CompanyWLAN]

WLAN-Namen für das Willkommensdokument (keine Schlüssel eintragen).

| Schlüssel | Typ | Standard | Beschreibung |
|---|---|---|---|
| `CompanySSID` | String | – | SSID Mitarbeiter. |
| `CompanySSIDbyod` | String | – | SSID BYOD. |
| `CompanySSIDGuest` | String | – | SSID Gäste. |

## [CompanyVPN]

VPN-Angaben für das Willkommensdokument.

| Schlüssel | Typ | Standard | Beschreibung |
|---|---|---|---|
| `CompanyVPNDomain` | String | – | VPN-Adresse. |
| `CompanyVPNUser` | String | – | Hinweis zum VPN-Benutzernamen. |
| `CompanyVPNPassword` | String | – | **Secret – wird ignoriert.** *Veraltet.* Nicht mehr unterstützt: Kennwörter gehören nicht in die Konfiguration. |

## [MailEndungen]

Zulässige E-Mail-Domänen (Domain1=@example.com).

Freie Schlüssel (Bezeichnung=Wert), Werttyp: MailDomain.

## [UserCreationDefaults]

Standardgruppen und -lizenz.

| Schlüssel | Typ | Standard | Beschreibung |
|---|---|---|---|
| `InitialGroupMembership` | List | – | Gruppen für jeden neuen Benutzer (durch ; getrennt). |
| `DefaultLicense` | String | – | Vorausgewählte Lizenz (Schlüssel aus [LicensesGroups]). |
| `DefaultTLGroup` | String | – | Vorausgewählte Teamleitergruppe. |

## [ActivateUserMS365ADSync]

Gruppe für die Microsoft-365-Synchronisation.

| Schlüssel | Typ | Standard | Beschreibung |
|---|---|---|---|
| `ADSync` | Bool | `0` | 1 = Benutzer der Synchronisationsgruppe hinzufügen. |
| `ADSyncADGroup` | String | – | Name der Synchronisationsgruppe. |

## [LicensesGroups]

Lizenzgruppen (Bezeichnung=AD-Gruppe, leerer Wert = keine Gruppe).

Freie Schlüssel (Bezeichnung=Wert), Werttyp: String.

## [TLGroups]

Teamleitergruppen (Bezeichnung=AD-Gruppe).

Freie Schlüssel (Bezeichnung=Wert), Werttyp: String.

## [ALGroup]

Gruppe für Abteilungsleitungen.

| Schlüssel | Typ | Standard | Beschreibung |
|---|---|---|---|
| `Group` | String | – | AD-Gruppe. |

## [ADGroups]

Auswählbare Gruppen (Bezeichnung=AD-Gruppe).

Freie Schlüssel (Bezeichnung=Wert), Werttyp: String.

## [CustomAttributeMappings]

Zuordnung AD-Attribut=Feld der Anfrage (z. B. extensionAttribute1=EmployeeType).

Freie Schlüssel (Bezeichnung=Wert), Werttyp: String.

## [Jira]

*Veralteter Abschnitt.* Legacy: Jira-Anbindung ist nicht implementiert.

| Schlüssel | Typ | Standard | Beschreibung |
|---|---|---|---|
| `EnableTicketing` | Bool | – | *Ohne Wirkung.* Nicht implementiert. |
| `JiraToken` | String | – | **Secret – wird ignoriert.** *Ohne Wirkung.* Tokens gehören nicht in die Konfiguration. |
| `JiraURL` | String | – | *Ohne Wirkung.* Nicht implementiert. |
| `ProjectKey` | String | – | *Ohne Wirkung.* Nicht implementiert. |

## [EmailSettings]

SMTP für Benachrichtigungen (Welcome-Mail ohne Kennwort).

| Schlüssel | Typ | Standard | Beschreibung |
|---|---|---|---|
| `SMTPServer` | String | – | SMTP-Relay (Hostname). |
| `SMTPPort` | Int (1–65535) | `25` | SMTP-Port. |
| `UseSSL` | Bool | `1` | TLS verwenden. |
| `UseDefaultCredentials` | Bool | `0` | Mit dem Windows-Konto am Relay authentifizieren. |
| `FromAddress` | Email | – | Absenderadresse. |
| `From` | Email | – | *Veraltet.* Ersatz: `EmailSettings.FromAddress`. Veraltet. |
| `CopyAddress` | Email | – | Kopie an (z. B. HR). |
| `SendWelcomeEmail` | Bool | `0` | Welcome-Mail versenden (ohne Kennwort). |
| `WelcomeEmailTemplate` | Path | – | Eigene HTML-Vorlage (Kennwort-Platzhalter werden nie befüllt). |
| `WelcomeEmailSubject` | String | `Willkommen` | Betreff. |
| `Username` | String | – | *Ohne Wirkung.* Nicht unterstützt (Anmeldedaten gehören nicht in die Konfiguration). |
| `Password` | String | – | **Secret – wird ignoriert.** *Ohne Wirkung.* Nicht unterstützt (Anmeldedaten gehören nicht in die Konfiguration). |

## [ADSync]

Entra Connect Sync (ehemals Azure AD Connect).

| Schlüssel | Typ | Standard | Beschreibung |
|---|---|---|---|
| `EnableADSync` | Bool | `0` | Synchronisation anbieten. |
| `ADSyncServer` | String | – | Server mit Entra Connect (WinRM erforderlich). |
| `ADSyncGroup` | String | – | *Ohne Wirkung.* Veraltet, siehe [ActivateUserMS365ADSync]. |
| `SyncCommand` | String | – | *Veraltet.* Nicht mehr unterstützt: aus Sicherheitsgründen wird nur Start-ADSyncSyncCycle ausgeführt. |
| `PolicyType` | Enum (Delta, Initial) | `Delta` | Synchronisationstyp. |
| `AutoSyncNewUsers` | Bool | `0` | Nach Onboarding automatisch Delta-Sync auslösen. |

## [OnboardingExtensions]

Ergänzende Onboarding-Aktionen.

| Schlüssel | Typ | Standard | Beschreibung |
|---|---|---|---|
| `CreateHomeDirectory` | Bool | `0` | Home-Verzeichnis anlegen. |
| `HomeDirectoryPath` | String | – | Pfad (%username% wird ersetzt), muss unter FileServer.AllowedRoots liegen. |
| `SetUserPhoto` | Bool | `0` | Profilbild setzen (thumbnailPhoto). |
| `DefaultPhotoPath` | Path | – | Verzeichnis mit Fotos (&lt;SamAccountName&gt;.jpg). |
| `CreateMailbox` | Bool | `0` | Postfach anlegen (Exchange On-Premises/Hybrid). |
| `MailboxDatabase` | String | – | Postfachdatenbank (On-Premises). |
| `BackupUserData` | Bool | – | *Ohne Wirkung.* Veraltet, wird ignoriert. |
| `BackupPath` | String | – | *Ohne Wirkung.* Veraltet, wird ignoriert. |
| `GenerateDetailedReport` | Bool | – | *Ohne Wirkung.* Ersatz: `Report.Formats`. Veraltet, siehe Report.Formats. |
| `ValidateUserInput` | Bool | – | *Ohne Wirkung.* Veraltet: Validierung ist immer aktiv. |

## [ValidationRules]

Eingabevalidierung.

| Schlüssel | Typ | Standard | Beschreibung |
|---|---|---|---|
| `FirstNameMinLength` | Int (1–64) | `1` | Mindestlänge Vorname. |
| `FirstNameMaxLength` | Int (1–64) | `64` | Maximallänge Vorname. |
| `LastNameMinLength` | Int (1–64) | `1` | Mindestlänge Nachname. |
| `LastNameMaxLength` | Int (1–64) | `64` | Maximallänge Nachname. |
| `EmailPattern` | Regex | – | Zusätzliches Muster für E-Mail-Adressen. |
| `PhonePattern` | Regex | – | Zusätzliches Muster für Telefonnummern. |

## [SystemSettings]

*Veralteter Abschnitt.* Legacy-Systemeinstellungen (ohne Wirkung in 3.0).

Freie Schlüssel (Bezeichnung=Wert), Werttyp: String.

## [LicenseSettings]

*Veralteter Abschnitt.* Legacy: Graph-Lizenzverwaltung ist nicht Bestandteil von 3.0 (gruppenbasierte Lizenzierung).

Freie Schlüssel (Bezeichnung=Wert), Werttyp: String.

## [LicenseTemplates]

*Veralteter Abschnitt.* Legacy: nicht verwendet (gruppenbasierte Lizenzierung).

Freie Schlüssel (Bezeichnung=Wert), Werttyp: String.

## [TeamsSettings]

*Veralteter Abschnitt.* Legacy: Teams-Benachrichtigungen sind nicht implementiert.

| Schlüssel | Typ | Standard | Beschreibung |
|---|---|---|---|
| `OnboardingWebhook` | String | – | **Secret – wird ignoriert.** *Ohne Wirkung.* Webhook-URLs enthalten ein Geheimnis und gehören nicht in die Konfiguration. |
| `IntranetURL` | String | – | *Ohne Wirkung.* Nicht verwendet. |
| `EnableNotifications` | Bool | – | *Ohne Wirkung.* Nicht implementiert. |

## [Paths]

Arbeitsverzeichnisse (ab 3.0).

| Schlüssel | Typ | Standard | Beschreibung |
|---|---|---|---|
| `DataDirectory` | Path | `Data` | Arbeitsdaten (z. B. Offboarding-Warteschlange). |
| `SnapshotDirectory` | Path | `Reports/Offboarding` | Vorher-/Nachher-Zustände beim Offboarding. |

## [FileServer]

Dateiserver (Home-Verzeichnisse).

| Schlüssel | Typ | Standard | Beschreibung |
|---|---|---|---|
| `AllowedRoots` | List | – | Stammpfade, unter denen Home-/Profilverzeichnisse angelegt oder archiviert werden dürfen. |
| `ArchiveRoot` | String | – | Archivziel für Home-Verzeichnisse beim Offboarding (muss unter AllowedRoots liegen). |

## [Offboarding]

Offboarding-Grundeinstellungen (ab 3.0).

| Schlüssel | Typ | Standard | Beschreibung |
|---|---|---|---|
| `DefaultTemplate` | String | `Standard` | Vorausgewählte Vorlage. |
| `DisabledUsersOU` | Dn | – | Standard-OU für ausgeschiedene Benutzer. |
| `RequireTicket` | Bool | `1` | Ticket-/Vorgangsnummer ist Pflicht. |
| `RequireReason` | Bool | `0` | Begründung ist Pflicht. |
| `KeepGroups` | List | – | Gruppen, aus denen nie entfernt wird. |
| `DescriptionTemplate` | Template | `Ausgetreten {ExitDate} \| Ticket {Ticket} \| {Actor}` | Neue Kontobeschreibung. |
| `AutoReplyMessage` | String | – | Standardtext der automatischen Antwort. |

## [Bulk]

CSV-Massenverarbeitung (ab 3.0).

| Schlüssel | Typ | Standard | Beschreibung |
|---|---|---|---|
| `MaxRows` | Int (1–5000) | `500` | Maximale Zeilenzahl je Datei. |
| `ConfirmationThreshold` | Int (1–5000) | `25` | Ab dieser Anzahl ist eine Tippbestätigung erforderlich. |
| `Delimiter` | Enum (Auto, Semicolon, Comma) | `Auto` | CSV-Trennzeichen. |
| `PasswordDelivery` | Enum (Discard, Print) | `Discard` | Kennwörter verwerfen (Reset bei Übergabe) oder Zugangsdatenblätter drucken. |

## [Exchange]

Exchange-Anbindung (optional).

| Schlüssel | Typ | Standard | Beschreibung |
|---|---|---|---|
| `Mode` | Enum (None, Online, OnPremises, Hybrid) | `None` | Betriebsart. |
| `OnPremisesUri` | Url | – | PowerShell-Endpunkt (z. B. http://exchange.example.com/PowerShell), Kerberos. |
| `RemoteRoutingDomain` | Domain | – | Hybrid: Routingdomäne (z. B. &lt;Mandant&gt;.mail.onmicrosoft.com). |
| `AppId` | Guid | – | Online/Hybrid: Anwendungs-ID für die Zertifikatsanmeldung (geplante Aufgabe). Leer = interaktiv. |
| `CertificateThumbprint` | Thumbprint | – | Fingerabdruck des Zertifikats im Speicher des ausführenden Kontos (kein Secret). |
| `Organization` | Domain | – | Mandant für die Zertifikatsanmeldung (z. B. contoso.onmicrosoft.com). |

## [Graph]

Microsoft Graph (optional, z. B. Sitzungen widerrufen).

| Schlüssel | Typ | Standard | Beschreibung |
|---|---|---|---|
| `Enabled` | Bool | `0` | Graph-Funktionen anbieten. |
| `TenantId` | String | – | Tenant-ID oder -Domäne (keine Secrets). |
| `ClientId` | Guid | – | Anwendungs-ID für die Zertifikatsanmeldung (geplante Aufgabe). Leer = interaktiv. |
| `CertificateThumbprint` | Thumbprint | – | Fingerabdruck des Zertifikats im Speicher des ausführenden Kontos (kein Secret). |

## Dynamische Abschnitte

### Company (Abschnittsmuster `^Company\d*$`)

Unternehmensdaten ([Company], [Company1], ...). Schlüssel dürfen die Abschnittsnummer als Suffix tragen.

| Schlüssel | Typ | Standard | Beschreibung |
|---|---|---|---|
| Muster `^CompanyNameFirma\d*$` | String | – | Firmenname (AD-Attribut company). |
| Muster `^CompanyActiveDirectoryDomain\d*$` | Domain | – | UPN-Suffix. |
| Muster `^CompanyActiveDirectoryOU\d*$` | Dn | – | Standard-OU dieses Unternehmens. |
| Muster `^CompanyMailDomain\d*$` | MailDomain | – | Primäre E-Mail-Domäne. |
| Muster `^CompanyMS365Domain\d*$` | MailDomain | – | Microsoft-365-Domäne (sekundäre Proxyadresse). |
| Muster `^CompanyDomain\d*$` | String | – | Webseite (AD-Attribut wWWHomePage). |
| Muster `^CompanyStrasse\d*$` | String | – | Straße. |
| Muster `^CompanyPLZ\d*$` | String | – | Postleitzahl. |
| Muster `^CompanyOrt\d*$` | String | – | Ort. |
| Muster `^CompanyTelefon\d*$` | String | – | Zentrale Rufnummer. |
| Muster `^CompanyCountry\d*$` | String | – | Land (ISO-3166 Alpha-2, z. B. DE). |

### OffboardingTemplate (Abschnittsmuster `^OffboardingTemplate\.[A-Za-z0-9_\-]+$`)

Offboarding-Vorlage.

| Schlüssel | Typ | Standard | Beschreibung |
|---|---|---|---|
| `DisplayName` | String | – | **Pflicht.** Anzeigename. |
| `Description` | String | – | Beschreibung. |
| `RetentionDays` | Int (0–3650) | `0` | Tage bis zur möglichen endgültigen Löschung (0 = keine Löschung). |
| `RetentionPhaseStartDays` | Int (0–3650) | `30` | Tage nach Austritt bis zur Aufbewahrungsphase. |
| `RemoveGroupsMode` | Enum (AllNonProtected, LicenseOnly, Selected, None) | `AllNonProtected` | Gruppenentfernung. |
| `KeepGroups` | List | – | Zusätzlich beizubehaltende Gruppen. |
| `TargetOU` | Dn | – | Ziel-OU (leer = Offboarding.DisabledUsersOU). |
| `DescriptionTemplate` | Template | – | Kontobeschreibung (leer = Offboarding.DescriptionTemplate). |
| `AutoReplyMessage` | String | – | Text der automatischen Antwort. |
| `ForwardToManager` | Bool | `0` | Weiterleitung an die Führungskraft vorschlagen. |
| `IsTestMode` | Bool | `0` | Vorlage erzwingt Simulation. |
| `RequireTicket` | Bool | `1` | Ticketnummer erforderlich. |
| Muster `^Action\.[A-Za-z]+$` | Enum (Immediate, ExitDate, Retention, FinalDeletion, Off) | – | Phase der Aktion. |

### RoleTemplate (Abschnittsmuster `^RoleTemplate\.[A-Za-z0-9_\-]+$`)

Rollenvorlage für das Onboarding.

| Schlüssel | Typ | Standard | Beschreibung |
|---|---|---|---|
| `DisplayName` | String | – | **Pflicht.** Anzeigename. |
| `Description` | String | – | Beschreibung. |
| `Groups` | List | – | Gruppen der Rolle. |
| `License` | String | – | Lizenzschlüssel aus [LicensesGroups]. |
| `TargetOU` | Dn | – | Ziel-OU der Rolle. |
| `Title` | String | – | Vorbelegte Position. |
| `Department` | String | – | Vorbelegte Abteilung. |

## Offboarding-Aktionen

Gültige Aktionsnamen für `Action.<Aktion>=<Phase>` in Offboarding-Vorlagen:

`DisableAccount`, `SetExpiration`, `DenyLogonHours`, `UpdateDescription`, `ResetPassword`, `ForcePasswordChange`, `RevokeSessions`, `RemoveGroups`, `RemoveLicenseGroups`, `ClearManager`, `MoveToOU`, `HideFromAddressLists`, `SetAutoReply`, `SetForwarding`, `ConvertToSharedMailbox`, `DocumentMailboxPermissions`, `ArchiveHomeDirectory`, `GrantManagerHomeAccess`, `ClearProfilePath`, `DeleteAccount`
