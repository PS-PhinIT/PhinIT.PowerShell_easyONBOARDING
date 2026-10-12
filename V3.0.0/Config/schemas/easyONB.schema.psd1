# Konfigurationsschema für easyONBOARDING (INI-Format)
#
# Typen: String, Int, Bool, Path, Dn, Domain, MailDomain, Email, Url, Enum, List, Template, Color, Regex
# Eigenschaften je Schlüssel: Type, Default, Description, Required, Secret, Deprecated, Replacement,
#                             Values (Enum), Min/Max (Int), Unused (Schlüssel wird in 3.x nicht ausgewertet)
# Abschnitte: Description, Required, Deprecated, FreeForm (+ ValueType), Keys, KeyPatterns
# SectionPatterns: dynamische Abschnitte (z. B. Company1, OffboardingTemplate.Standard)
@{
    SchemaVersion = 1

    OffboardingActions = @(
        'DisableAccount', 'SetExpiration', 'DenyLogonHours', 'UpdateDescription', 'ResetPassword',
        'ForcePasswordChange', 'RevokeSessions', 'RemoveGroups', 'RemoveLicenseGroups', 'ClearManager',
        'MoveToOU', 'HideFromAddressLists', 'SetAutoReply', 'SetForwarding', 'ConvertToSharedMailbox',
        'DocumentMailboxPermissions', 'ArchiveHomeDirectory', 'GrantManagerHomeAccess', 'ClearProfilePath',
        'DeleteAccount'
    )

    Sections = @{
        ScriptInfo = @{
            Description = 'Legacy-Versionsangaben (Version stammt ab 3.0 aus der Datei VERSION).'
            Deprecated  = $true
            Keys        = @{
                ScriptVersion = @{ Type = 'String'; Unused = $true; Description = 'Veraltet, wird ignoriert.' }
                LastUpdate    = @{ Type = 'String'; Unused = $true; Description = 'Veraltet, wird ignoriert.' }
                Author        = @{ Type = 'String'; Unused = $true; Description = 'Veraltet, wird ignoriert.' }
            }
        }

        Logging = @{
            Description = 'Protokollierung und Audit.'
            Keys        = @{
                LogFile            = @{ Type = 'Path'; Default = 'Logs'; Description = 'Verzeichnis für Textlogs (relativ zur Anwendungswurzel oder absolut).' }
                ExtraFile          = @{ Type = 'Path'; Deprecated = $true; Replacement = 'Logging.AuditDirectory'; Description = 'Veraltet.' }
                AuditDirectory     = @{ Type = 'Path'; Default = ''; Description = 'Verzeichnis für Audit-Logs (leer = <LogFile>\audit).' }
                DebugMode          = @{ Type = 'Bool'; Default = '0'; Description = '1 = Debug-Einträge protokollieren (entspricht MinimumLevel=Debug).' }
                MinimumLevel       = @{ Type = 'Enum'; Values = @('Debug', 'Information', 'Warning', 'Error', 'Critical'); Default = 'Information'; Description = 'Minimales Level für Textlogs.' }
                RetentionDays      = @{ Type = 'Int'; Min = 1; Max = 3650; Default = '90'; Description = 'Aufbewahrung Textlogs in Tagen.' }
                AuditRetentionDays = @{ Type = 'Int'; Min = 0; Max = 36500; Default = '0'; Description = 'Aufbewahrung Audit-Logs in Tagen (0 = unbegrenzt).' }
                MaxFileSizeMB      = @{ Type = 'Int'; Min = 1; Max = 1024; Default = '20'; Description = 'Maximale Größe einer Logdatei.' }
            }
        }

        RemoteExecution = @{
            Description = 'Legacy-Abschnitt.'
            Deprecated  = $true
            Keys        = @{
                Enable              = @{ Type = 'Bool'; Unused = $true; Description = 'Veraltet, wird ignoriert.' }
                DefaultDCServerName = @{ Type = 'String'; Deprecated = $true; Replacement = 'ActiveDirectory.PreferredDomainController'; Description = 'Wird als bevorzugter DC verwendet, wenn ActiveDirectory.PreferredDomainController leer ist.' }
            }
        }

        ActiveDirectory = @{
            Description = 'Active-Directory-Verbindung und Suche.'
            Keys        = @{
                PreferredDomainController = @{ Type = 'String'; Default = ''; Description = 'Fester (beschreibbarer) Domänencontroller. Leer = automatische Auswahl, alle Schritte eines Vorgangs nutzen denselben DC.' }
                SearchBase                = @{ Type = 'Dn'; Default = ''; Description = 'Optionale Einschränkung der Benutzersuche.' }
                MaxSearchResults          = @{ Type = 'Int'; Min = 1; Max = 500; Default = '50'; Description = 'Maximale Trefferzahl der Benutzersuche.' }
            }
        }

        WPFGUI = @{
            Description = 'Branding der Oberfläche.'
            Keys        = @{
                APPName        = @{ Type = 'String'; Default = 'easyONBOARDING'; Description = 'Anzeigename im Fenstertitel und Kopfbereich.' }
                ThemeColor     = @{ Type = 'String'; Unused = $true; Replacement = 'UI.AccentColor'; Description = 'Veraltet (Legacy-Farbe), siehe [UI].' }
                BoxColor       = @{ Type = 'String'; Unused = $true; Description = 'Veraltet, wird ignoriert.' }
                RahmenColor    = @{ Type = 'String'; Unused = $true; Description = 'Veraltet, wird ignoriert.' }
                LogoURL        = @{ Type = 'Url'; Default = ''; Description = 'Link hinter dem Logo (nur https).' }
                FooterText     = @{ Type = 'String'; Default = ''; Description = 'Zusatztext in der Statusleiste.' }
                FooterWebseite = @{ Type = 'String'; Default = ''; Description = 'Webseite in der Info-Ansicht.' }
            }
        }

        WPFGUITypography = @{
            Description = 'Schriftarten der Oberfläche.'
            Keys        = @{
                DefaultFontFamily = @{ Type = 'String'; Default = 'Segoe UI'; Description = 'Standardschriftart.' }
                DefaultFontSize   = @{ Type = 'Int'; Min = 10; Max = 20; Default = '13'; Description = 'Standardschriftgröße.' }
                HeaderFontSize    = @{ Type = 'Int'; Min = 12; Max = 32; Default = '20'; Description = 'Schriftgröße der Überschriften.' }
                FooterFontSize    = @{ Type = 'Int'; Min = 9; Max = 18; Default = '11'; Description = 'Schriftgröße der Statusleiste.' }
            }
        }

        WPFGUILogos = @{
            Description = 'Legacy-Logo- und Iconpfade.'
            Keys        = @{
                OnboardingLogo    = @{ Type = 'Path'; Deprecated = $true; Replacement = 'UI.LogoPath'; Description = 'Wird als Logo verwendet, wenn UI.LogoPath leer ist.' }
                ADUpdateLogo      = @{ Type = 'Path'; Unused = $true; Description = 'Veraltet, wird ignoriert.' }
                TabOnboardingIcon = @{ Type = 'Path'; Unused = $true; Description = 'Veraltet, wird ignoriert.' }
                TabADUpdateIcon   = @{ Type = 'Path'; Unused = $true; Description = 'Veraltet, wird ignoriert.' }
                InfoIcon          = @{ Type = 'Path'; Unused = $true; Description = 'Veraltet, wird ignoriert.' }
                SettingsIcon      = @{ Type = 'Path'; Unused = $true; Description = 'Veraltet, wird ignoriert.' }
                CloseIcon         = @{ Type = 'Path'; Unused = $true; Description = 'Veraltet, wird ignoriert.' }
            }
        }

        UI = @{
            Description = 'Darstellung der Oberfläche (ab 3.0).'
            Keys        = @{
                Theme       = @{ Type = 'Enum'; Values = @('Light', 'Dark'); Default = 'Light'; Description = 'Farbschema.' }
                AccentColor = @{ Type = 'Color'; Default = '#0F6CBD'; Description = 'Akzentfarbe (Branding) als #RRGGBB.' }
                LogoPath    = @{ Type = 'Path'; Default = ''; Description = 'Optionales Logo (PNG/JPG) im Kopfbereich.' }
            }
        }

        Security = @{
            Description = 'Sicherheitsrichtlinien (ab 3.0).'
            Keys        = @{
                SimulationByDefault      = @{ Type = 'Bool'; Default = '1'; Description = 'Neue Vorgänge starten im Simulationsmodus.' }
                AllowManualPassword      = @{ Type = 'Bool'; Default = '1'; Description = 'Manuelle Kennworteingabe (je Vorgang) erlauben.' }
                ShowPasswordOnce         = @{ Type = 'Bool'; Default = '1'; Description = 'Generiertes Kennwort nach der Ausführung einmalig anzeigen.' }
                AllowCredentialPrint     = @{ Type = 'Bool'; Default = '1'; Description = 'Druck des Zugangsdatenblatts aus dem Speicher erlauben.' }
                ClipboardClearSeconds    = @{ Type = 'Int'; Min = 0; Max = 600; Default = '30'; Description = 'Zwischenablage nach N Sekunden leeren (0 = Kopieren deaktiviert).' }
                ProtectedGroups          = @{ Type = 'List'; Default = ''; Description = 'Zusätzliche geschützte Gruppen (Name, DN oder SID).' }
                ProtectedGroupPatterns   = @{ Type = 'List'; Default = '*Admin*'; Description = 'Namensmuster geschützter Gruppen (Platzhalter *).' }
                ProtectedAccounts        = @{ Type = 'List'; Default = ''; Description = 'Konten, die nie bearbeitet werden dürfen (SamAccountName oder SID).' }
                BreakGlassAccounts       = @{ Type = 'List'; Default = ''; Description = 'Notfallkonten (werden nie bearbeitet).' }
                ServiceAccountPatterns   = @{ Type = 'List'; Default = 'svc_*;svc-*;*_svc;sa_*'; Description = 'Namensmuster von Dienstkonten (werden nie bearbeitet).' }
                ProtectedOUs             = @{ Type = 'List'; Default = ''; Description = 'OUs, deren Konten nie bearbeitet werden (DN).' }
                AllowPrivilegedOffboarding = @{ Type = 'Bool'; Default = '0'; Description = 'Offboarding privilegierter Konten nach gesonderter Bestätigung erlauben.' }
                UseDomainPasswordPolicy  = @{ Type = 'Bool'; Default = '1'; Description = 'Domänen-Kennwortrichtlinie (Mindestlänge, Komplexität) zusätzlich berücksichtigen.' }
            }
        }

        Report = @{
            Description = 'Berichte und Vorlagen.'
            Keys        = @{
                UserOnboardingCreateTXT = @{ Type = 'Bool'; Deprecated = $true; Replacement = 'Report.Formats'; Description = '1 = TXT zusätzlich erzeugen (wird auf Formats abgebildet).' }
                ReportPath         = @{ Type = 'Path'; Default = 'Reports'; Description = 'Ablageverzeichnis für Berichte.' }
                ReportTitle        = @{ Type = 'String'; Default = 'easyONBOARDING Bericht'; Description = 'Berichtstitel.' }
                ReportHeader       = @{ Type = 'String'; Default = ''; Description = 'Überschrift im Willkommensdokument.' }
                ReportFooter       = @{ Type = 'String'; Default = ''; Description = 'Fußzeile der Berichte.' }
                ReportThemeColor   = @{ Type = 'String'; Unused = $true; Description = 'Veraltet, wird ignoriert.' }
                ReportFontFamily   = @{ Type = 'String'; Unused = $true; Description = 'Veraltet, wird ignoriert.' }
                ReportFontSize     = @{ Type = 'String'; Unused = $true; Description = 'Veraltet, wird ignoriert.' }
                TemplatePathHTML   = @{ Type = 'Path'; Default = 'ReportTemplates/HTMLTemplate.txt'; Description = 'HTML-Vorlage des Willkommensdokuments (Kennwort-Platzhalter werden nie befüllt).' }
                TemplatePathTXT    = @{ Type = 'Path'; Default = ''; Description = 'Legacy-TXT-Vorlage (wird nicht mehr verwendet, TXT-Berichte werden generiert).'; Unused = $true }
                TemplateLogo       = @{ Type = 'Path'; Default = ''; Description = 'Logo für HTML-Berichte.' }
                wkhtmltopdfPath    = @{ Type = 'Path'; Default = ''; Description = 'Pfad zu wkhtmltopdf.exe (Legacy-PDF-Engine, optional).' }
                EdgePath           = @{ Type = 'Path'; Default = ''; Description = 'Optionaler Pfad zu msedge.exe (sonst Standard-Installationspfade).' }
                PdfTimeoutSeconds  = @{ Type = 'Int'; Min = 5; Max = 300; Default = '60'; Description = 'Zeitlimit der PDF-Erzeugung in Sekunden.' }
                Formats            = @{ Type = 'List'; Default = 'Html;Json'; Description = 'Berichtsformate: Html, Json, Csv, Txt, Pdf.' }
                PdfEngine          = @{ Type = 'Enum'; Values = @('Auto', 'Edge', 'Wkhtmltopdf', 'None'); Default = 'Auto'; Description = 'PDF-Erzeugung (Auto = Edge, sonst wkhtmltopdf, sonst HTML).' }
                CreateWelcomeDocument = @{ Type = 'Bool'; Default = '1'; Unused = $true; Description = 'Legacy-Schlüssel, wird ignoriert: Das Onboarding-Handout aus TemplatePathHTML wird immer erzeugt (ohne Kennwort).' }
            }
        }

        CustomPWLabels = @{
            Description = 'Legacy: Zusatzkennwörter werden aus Sicherheitsgründen nicht mehr erzeugt.'
            Deprecated  = $true
            FreeForm    = $true
            ValueType   = 'String'
        }

        Websites = @{
            Description = 'Links im Willkommensdokument (Format: Bezeichnung | URL | Beschreibung).'
            FreeForm    = $true
            ValueType   = 'String'
        }

        ReportPlaceholders = @{
            Description = 'Zusätzliche Platzhalter des Willkommensdokuments ({{Name}} = Wert). Kennwort-Platzhalter werden nie befüllt.'
            FreeForm    = $true
            ValueType   = 'String'
        }

        ADUserDefaults = @{
            Description = 'Standardwerte für neue Benutzerkonten.'
            Keys        = @{
                DefaultOU                 = @{ Type = 'Dn'; Default = ''; Description = 'Standard-Ziel-OU (DN).' }
                AccountDisabled           = @{ Type = 'Bool'; Default = 'True'; Description = 'Neue Konten deaktiviert anlegen (Aktivierung zum Startdatum).' }
                PasswordNeverExpires      = @{ Type = 'Bool'; Default = 'False'; Description = 'Kennwort läuft nie ab (nicht empfohlen).' }
                MustChangePasswordAtLogon = @{ Type = 'Bool'; Default = 'True'; Description = 'Kennwortänderung bei der ersten Anmeldung erzwingen.' }
                SmartcardLogonRequired    = @{ Type = 'Bool'; Default = 'False'; Description = 'Smartcard-Anmeldung erforderlich.' }
                CannotChangePassword      = @{ Type = 'Bool'; Unused = $true; Description = 'Nicht unterstützt, wird ignoriert.' }
                HomeLWLetter              = @{ Type = 'String'; Default = 'H'; Description = 'Laufwerksbuchstabe des Home-Verzeichnisses.' }
                HomeDirectory             = @{ Type = 'String'; Default = ''; Description = 'Home-Verzeichnis (%username% wird ersetzt).' }
                ProfilePath               = @{ Type = 'String'; Default = ''; Description = 'Profilpfad (%username% wird ersetzt).' }
                LogonScript               = @{ Type = 'String'; Default = ''; Description = 'Anmeldeskript.' }
            }
        }

        DisplayNameUPNTemplates = @{
            Description = 'Vorlagen für Anzeigename und UPN.'
            Keys        = @{
                DefaultDisplayNameFormat       = @{ Type = 'Template'; Default = '{first} {last}'; Description = 'Standardformat des Anzeigenamens.' }
                DefaultUserPrincipalNameFormat = @{ Type = 'String'; Default = 'FIRSTNAME.LASTNAME'; Description = 'UPN-Format (Legacy-Schlüsselwort wie FIRSTNAME.LASTNAME oder Platzhalter wie {first}.{last}).' }
            }
            KeyPatterns = @(
                @{ Pattern = '^DisplayNameTemplate\d+$'; Type = 'String'; Description = 'Weitere Anzeigenamen-Vorlage ("Bezeichnung|Vorlage" oder "Vorlage").' }
            )
        }

        Identity = @{
            Description = 'Kontonamen und Kollisionsbehandlung (ab 3.0).'
            Keys        = @{
                SamAccountNameFormat    = @{ Type = 'Template'; Default = '{f}{last}'; Description = 'Format des SamAccountName.' }
                MailFormat              = @{ Type = 'Template'; Default = ''; Description = 'Format des lokalen Teils der E-Mail-Adresse (leer = wie UPN).' }
                CollisionStrategy       = @{ Type = 'Enum'; Values = @('AppendNumber', 'Fail'); Default = 'AppendNumber'; Description = 'Verhalten bei belegten Namen.' }
                CollisionStartNumber    = @{ Type = 'Int'; Min = 1; Max = 99; Default = '2'; Description = 'Erste angehängte Zahl.' }
                MaxCollisionAttempts    = @{ Type = 'Int'; Min = 1; Max = 99; Default = '20'; Description = 'Maximale Anzahl Versuche.' }
                LowerCaseIdentifiers    = @{ Type = 'Bool'; Default = '1'; Description = 'SamAccountName, UPN und E-Mail kleinschreiben.' }
                MaxSamAccountNameLength = @{ Type = 'Int'; Min = 1; Max = 20; Default = '20'; Description = 'Maximale Länge des SamAccountName (AD-Limit 20).' }
            }
        }

        NameNormalization = @{
            Description = 'Umlaute, Sonderzeichen und Transliteration.'
            Keys        = @{
                Enabled             = @{ Type = 'Bool'; Unused = $true; Description = 'Veraltet: Normalisierung ist immer aktiv.' }
                ReplaceSpecialChars = @{ Type = 'String'; Default = ''; Description = 'Legacy-Ersetzungen im Format a=b;c=d (werden zusätzlich angewendet).' }
                NormalizeCase       = @{ Type = 'Bool'; Deprecated = $true; Replacement = 'Identity.LowerCaseIdentifiers'; Description = 'Veraltet.' }
                Transliteration     = @{ Type = 'String'; Default = ''; Description = 'Zusätzliche/abweichende Ersetzungen im Format ä=ae;ø=oe. Für einzelne Kleinbuchstaben wird die Großschreibung automatisch ergänzt, sofern nicht explizit angegeben.' }
                KeepHyphen          = @{ Type = 'Bool'; Default = '1'; Description = 'Bindestriche in Kontonamen beibehalten.' }
            }
        }

        ValidateUPN = @{
            Description = 'Legacy-Abschnitt (Duplikatprüfung ist ab 3.0 immer aktiv).'
            Deprecated  = $true
            Keys        = @{
                CheckForDuplicates     = @{ Type = 'Bool'; Unused = $true; Description = 'Veraltet: Prüfung ist immer aktiv.' }
                AppendRandomOnConflict = @{ Type = 'Bool'; Deprecated = $true; Replacement = 'Identity.CollisionStrategy'; Description = 'Veraltet: deterministische Nummerierung statt Zufall.' }
            }
        }

        PasswordFixGenerate = @{
            Description = 'Kennwortgenerierung.'
            Keys        = @{
                fixPassword           = @{ Type = 'String'; Secret = $true; Deprecated = $true; Description = 'Nicht mehr unterstützt: feste Standardkennwörter sind ein Sicherheitsrisiko.' }
                DefaultPasswordLength = @{ Type = 'Int'; Min = 12; Max = 128; Default = '16'; Description = 'Länge generierter Kennwörter.' }
                MinDigits             = @{ Type = 'Int'; Min = 0; Max = 20; Default = '2'; Description = 'Mindestanzahl Ziffern.' }
                MinUpperCase          = @{ Type = 'Int'; Min = 0; Max = 20; Default = '2'; Description = 'Mindestanzahl Großbuchstaben.' }
                MinLowerCase          = @{ Type = 'Int'; Min = 0; Max = 20; Default = '2'; Description = 'Mindestanzahl Kleinbuchstaben.' }
                MinSpecialChars       = @{ Type = 'Int'; Min = 0; Max = 20; Default = '1'; Description = 'Mindestanzahl Sonderzeichen (0 wenn IncludeSpecialChars=False).' }
                MinNonAlpha           = @{ Type = 'Int'; Min = 0; Max = 20; Default = '2'; Description = 'Mindestanzahl nicht-alphabetischer Zeichen.' }
                IncludeSpecialChars   = @{ Type = 'Bool'; Default = 'True'; Description = 'Sonderzeichen verwenden.' }
                AvoidAmbiguousChars   = @{ Type = 'Bool'; Default = 'True'; Description = 'Verwechselbare Zeichen (Il1O0) vermeiden.' }
                SpecialCharacters     = @{ Type = 'String'; Default = '!#%*+-=?@_'; Description = 'Zulässige Sonderzeichen.' }
                MinManualPasswordLength = @{ Type = 'Int'; Min = 8; Max = 128; Default = '12'; Description = 'Mindestlänge manuell eingegebener Kennwörter.' }
            }
        }

        CompanyHelpdesk = @{
            Description = 'Helpdesk-Angaben für das Willkommensdokument.'
            Keys        = @{
                CompanyITMitarbeiter = @{ Type = 'String'; Default = ''; Description = 'Ansprechpartner IT.' }
                CompanyHelpdeskMail  = @{ Type = 'Email'; Default = ''; Description = 'Helpdesk-E-Mail.' }
                CompanyHelpdeskTel   = @{ Type = 'String'; Default = ''; Description = 'Helpdesk-Telefon.' }
            }
        }

        CompanyWLAN = @{
            Description = 'WLAN-Namen für das Willkommensdokument (keine Schlüssel eintragen).'
            Keys        = @{
                CompanySSID      = @{ Type = 'String'; Default = ''; Description = 'SSID Mitarbeiter.' }
                CompanySSIDbyod  = @{ Type = 'String'; Default = ''; Description = 'SSID BYOD.' }
                CompanySSIDGuest = @{ Type = 'String'; Default = ''; Description = 'SSID Gäste.' }
            }
        }

        CompanyVPN = @{
            Description = 'VPN-Angaben für das Willkommensdokument.'
            Keys        = @{
                CompanyVPNDomain   = @{ Type = 'String'; Default = ''; Description = 'VPN-Adresse.' }
                CompanyVPNUser     = @{ Type = 'String'; Default = ''; Description = 'Hinweis zum VPN-Benutzernamen.' }
                CompanyVPNPassword = @{ Type = 'String'; Secret = $true; Deprecated = $true; Description = 'Nicht mehr unterstützt: Kennwörter gehören nicht in die Konfiguration.' }
            }
        }

        MailEndungen = @{
            Description = 'Zulässige E-Mail-Domänen (Domain1=@example.com).'
            FreeForm    = $true
            ValueType   = 'MailDomain'
        }

        UserCreationDefaults = @{
            Description = 'Standardgruppen und -lizenz.'
            Keys        = @{
                InitialGroupMembership = @{ Type = 'List'; Default = ''; Description = 'Gruppen für jeden neuen Benutzer (durch ; getrennt).' }
                DefaultLicense         = @{ Type = 'String'; Default = ''; Description = 'Vorausgewählte Lizenz (Schlüssel aus [LicensesGroups]).' }
                DefaultTLGroup         = @{ Type = 'String'; Default = ''; Description = 'Vorausgewählte Teamleitergruppe.' }
            }
        }

        ActivateUserMS365ADSync = @{
            Description = 'Gruppe für die Microsoft-365-Synchronisation.'
            Keys        = @{
                ADSync        = @{ Type = 'Bool'; Default = '0'; Description = '1 = Benutzer der Synchronisationsgruppe hinzufügen.' }
                ADSyncADGroup = @{ Type = 'String'; Default = ''; Description = 'Name der Synchronisationsgruppe.' }
            }
        }

        LicensesGroups = @{
            Description = 'Lizenzgruppen (Bezeichnung=AD-Gruppe, leerer Wert = keine Gruppe).'
            FreeForm    = $true
            ValueType   = 'String'
        }

        TLGroups = @{
            Description = 'Teamleitergruppen (Bezeichnung=AD-Gruppe).'
            FreeForm    = $true
            ValueType   = 'String'
        }

        ALGroup = @{
            Description = 'Gruppe für Abteilungsleitungen.'
            Keys        = @{
                Group = @{ Type = 'String'; Default = ''; Description = 'AD-Gruppe.' }
            }
        }

        ADGroups = @{
            Description = 'Auswählbare Gruppen (Bezeichnung=AD-Gruppe).'
            FreeForm    = $true
            ValueType   = 'String'
        }

        CustomAttributeMappings = @{
            Description = 'Zuordnung AD-Attribut=Feld der Anfrage (z. B. extensionAttribute1=EmployeeType).'
            FreeForm    = $true
            ValueType   = 'String'
        }

        Jira = @{
            Description = 'Legacy: Jira-Anbindung ist nicht implementiert.'
            Deprecated  = $true
            Keys        = @{
                EnableTicketing = @{ Type = 'Bool'; Unused = $true; Description = 'Nicht implementiert.' }
                JiraToken       = @{ Type = 'String'; Secret = $true; Unused = $true; Description = 'Tokens gehören nicht in die Konfiguration.' }
                JiraURL         = @{ Type = 'String'; Unused = $true; Description = 'Nicht implementiert.' }
                ProjectKey      = @{ Type = 'String'; Unused = $true; Description = 'Nicht implementiert.' }
            }
        }

        EmailSettings = @{
            Description = 'SMTP für Benachrichtigungen (Welcome-Mail ohne Kennwort).'
            Keys        = @{
                SMTPServer            = @{ Type = 'String'; Default = ''; Description = 'SMTP-Relay (Hostname).' }
                SMTPPort              = @{ Type = 'Int'; Min = 1; Max = 65535; Default = '25'; Description = 'SMTP-Port.' }
                UseSSL                = @{ Type = 'Bool'; Default = '1'; Description = 'TLS verwenden.' }
                UseDefaultCredentials = @{ Type = 'Bool'; Default = '0'; Description = 'Mit dem Windows-Konto am Relay authentifizieren.' }
                FromAddress           = @{ Type = 'Email'; Default = ''; Description = 'Absenderadresse.' }
                From                  = @{ Type = 'Email'; Deprecated = $true; Replacement = 'EmailSettings.FromAddress'; Description = 'Veraltet.' }
                CopyAddress           = @{ Type = 'Email'; Default = ''; Description = 'Kopie an (z. B. HR).' }
                SendWelcomeEmail      = @{ Type = 'Bool'; Default = '0'; Description = 'Welcome-Mail versenden (ohne Kennwort).' }
                WelcomeEmailTemplate  = @{ Type = 'Path'; Default = ''; Description = 'Eigene HTML-Vorlage (Kennwort-Platzhalter werden nie befüllt).' }
                WelcomeEmailSubject   = @{ Type = 'String'; Default = 'Willkommen'; Description = 'Betreff.' }
                Username              = @{ Type = 'String'; Unused = $true; Description = 'Nicht unterstützt (Anmeldedaten gehören nicht in die Konfiguration).' }
                Password              = @{ Type = 'String'; Secret = $true; Unused = $true; Description = 'Nicht unterstützt (Anmeldedaten gehören nicht in die Konfiguration).' }
            }
        }

        ADSync = @{
            Description = 'Entra Connect Sync (ehemals Azure AD Connect).'
            Keys        = @{
                EnableADSync     = @{ Type = 'Bool'; Default = '0'; Description = 'Synchronisation anbieten.' }
                ADSyncServer     = @{ Type = 'String'; Default = ''; Description = 'Server mit Entra Connect (WinRM erforderlich).' }
                ADSyncGroup      = @{ Type = 'String'; Unused = $true; Description = 'Veraltet, siehe [ActivateUserMS365ADSync].' }
                SyncCommand      = @{ Type = 'String'; Deprecated = $true; Description = 'Nicht mehr unterstützt: aus Sicherheitsgründen wird nur Start-ADSyncSyncCycle ausgeführt.' }
                PolicyType       = @{ Type = 'Enum'; Values = @('Delta', 'Initial'); Default = 'Delta'; Description = 'Synchronisationstyp.' }
                AutoSyncNewUsers = @{ Type = 'Bool'; Default = '0'; Description = 'Nach Onboarding automatisch Delta-Sync auslösen.' }
            }
        }

        OnboardingExtensions = @{
            Description = 'Ergänzende Onboarding-Aktionen.'
            Keys        = @{
                CreateHomeDirectory    = @{ Type = 'Bool'; Default = '0'; Description = 'Home-Verzeichnis anlegen.' }
                HomeDirectoryPath      = @{ Type = 'String'; Default = ''; Description = 'Pfad (%username% wird ersetzt), muss unter FileServer.AllowedRoots liegen.' }
                SetUserPhoto           = @{ Type = 'Bool'; Default = '0'; Description = 'Profilbild setzen (thumbnailPhoto).' }
                DefaultPhotoPath       = @{ Type = 'Path'; Default = ''; Description = 'Verzeichnis mit Fotos (<SamAccountName>.jpg).' }
                CreateMailbox          = @{ Type = 'Bool'; Default = '0'; Description = 'Postfach anlegen (Exchange On-Premises/Hybrid).' }
                MailboxDatabase        = @{ Type = 'String'; Default = ''; Description = 'Postfachdatenbank (On-Premises).' }
                BackupUserData         = @{ Type = 'Bool'; Unused = $true; Description = 'Veraltet, wird ignoriert.' }
                BackupPath             = @{ Type = 'String'; Unused = $true; Description = 'Veraltet, wird ignoriert.' }
                GenerateDetailedReport = @{ Type = 'Bool'; Unused = $true; Replacement = 'Report.Formats'; Description = 'Veraltet, siehe Report.Formats.' }
                ValidateUserInput      = @{ Type = 'Bool'; Unused = $true; Description = 'Veraltet: Validierung ist immer aktiv.' }
            }
        }

        ValidationRules = @{
            Description = 'Eingabevalidierung.'
            Keys        = @{
                FirstNameMinLength = @{ Type = 'Int'; Min = 1; Max = 64; Default = '1'; Description = 'Mindestlänge Vorname.' }
                FirstNameMaxLength = @{ Type = 'Int'; Min = 1; Max = 64; Default = '64'; Description = 'Maximallänge Vorname.' }
                LastNameMinLength  = @{ Type = 'Int'; Min = 1; Max = 64; Default = '1'; Description = 'Mindestlänge Nachname.' }
                LastNameMaxLength  = @{ Type = 'Int'; Min = 1; Max = 64; Default = '64'; Description = 'Maximallänge Nachname.' }
                EmailPattern       = @{ Type = 'Regex'; Default = ''; Description = 'Zusätzliches Muster für E-Mail-Adressen.' }
                PhonePattern       = @{ Type = 'Regex'; Default = ''; Description = 'Zusätzliches Muster für Telefonnummern.' }
            }
        }

        SystemSettings = @{
            Description = 'Legacy-Systemeinstellungen (ohne Wirkung in 3.0).'
            Deprecated  = $true
            FreeForm    = $true
            ValueType   = 'String'
        }

        LicenseSettings = @{
            Description = 'Legacy: Graph-Lizenzverwaltung ist nicht Bestandteil von 3.0 (gruppenbasierte Lizenzierung).'
            Deprecated  = $true
            FreeForm    = $true
            ValueType   = 'String'
        }

        LicenseTemplates = @{
            Description = 'Legacy: nicht verwendet (gruppenbasierte Lizenzierung).'
            Deprecated  = $true
            FreeForm    = $true
            ValueType   = 'String'
        }

        TeamsSettings = @{
            Description = 'Legacy: Teams-Benachrichtigungen sind nicht implementiert.'
            Deprecated  = $true
            Keys        = @{
                OnboardingWebhook   = @{ Type = 'String'; Secret = $true; Unused = $true; Description = 'Webhook-URLs enthalten ein Geheimnis und gehören nicht in die Konfiguration.' }
                IntranetURL         = @{ Type = 'String'; Unused = $true; Description = 'Nicht verwendet.' }
                EnableNotifications = @{ Type = 'Bool'; Unused = $true; Description = 'Nicht implementiert.' }
            }
        }

        Paths = @{
            Description = 'Arbeitsverzeichnisse (ab 3.0).'
            Keys        = @{
                DataDirectory     = @{ Type = 'Path'; Default = 'Data'; Description = 'Arbeitsdaten (z. B. Offboarding-Warteschlange).' }
                SnapshotDirectory = @{ Type = 'Path'; Default = 'Reports/Offboarding'; Description = 'Vorher-/Nachher-Zustände beim Offboarding.' }
            }
        }

        FileServer = @{
            Description = 'Dateiserver (Home-Verzeichnisse).'
            Keys        = @{
                AllowedRoots = @{ Type = 'List'; Default = ''; Description = 'Stammpfade, unter denen Home-/Profilverzeichnisse angelegt oder archiviert werden dürfen.' }
                ArchiveRoot  = @{ Type = 'String'; Default = ''; Description = 'Archivziel für Home-Verzeichnisse beim Offboarding (muss unter AllowedRoots liegen).' }
            }
        }

        Offboarding = @{
            Description = 'Offboarding-Grundeinstellungen (ab 3.0).'
            Keys        = @{
                DefaultTemplate     = @{ Type = 'String'; Default = 'Standard'; Description = 'Vorausgewählte Vorlage.' }
                DisabledUsersOU     = @{ Type = 'Dn'; Default = ''; Description = 'Standard-OU für ausgeschiedene Benutzer.' }
                RequireTicket       = @{ Type = 'Bool'; Default = '1'; Description = 'Ticket-/Vorgangsnummer ist Pflicht.' }
                RequireReason       = @{ Type = 'Bool'; Default = '0'; Description = 'Begründung ist Pflicht.' }
                KeepGroups          = @{ Type = 'List'; Default = ''; Description = 'Gruppen, aus denen nie entfernt wird.' }
                DescriptionTemplate = @{ Type = 'Template'; Default = 'Ausgetreten {ExitDate} | Ticket {Ticket} | {Actor}'; Description = 'Neue Kontobeschreibung.' }
                AutoReplyMessage    = @{ Type = 'String'; Default = ''; Description = 'Standardtext der automatischen Antwort.' }
            }
        }

        Bulk = @{
            Description = 'CSV-Massenverarbeitung (ab 3.0).'
            Keys        = @{
                MaxRows               = @{ Type = 'Int'; Min = 1; Max = 5000; Default = '500'; Description = 'Maximale Zeilenzahl je Datei.' }
                ConfirmationThreshold = @{ Type = 'Int'; Min = 1; Max = 5000; Default = '25'; Description = 'Ab dieser Anzahl ist eine Tippbestätigung erforderlich.' }
                Delimiter             = @{ Type = 'Enum'; Values = @('Auto', 'Semicolon', 'Comma'); Default = 'Auto'; Description = 'CSV-Trennzeichen.' }
                PasswordDelivery      = @{ Type = 'Enum'; Values = @('Discard', 'Print'); Default = 'Discard'; Description = 'Kennwörter verwerfen (Reset bei Übergabe) oder Zugangsdatenblätter drucken.' }
            }
        }

        Exchange = @{
            Description = 'Exchange-Anbindung (optional).'
            Keys        = @{
                Mode                = @{ Type = 'Enum'; Values = @('None', 'Online', 'OnPremises', 'Hybrid'); Default = 'None'; Description = 'Betriebsart.' }
                OnPremisesUri       = @{ Type = 'Url'; Default = ''; Description = 'PowerShell-Endpunkt (z. B. http://exchange.example.com/PowerShell), Kerberos.' }
                RemoteRoutingDomain = @{ Type = 'Domain'; Default = ''; Description = 'Hybrid: Routingdomäne (z. B. <Mandant>.mail.onmicrosoft.com).' }
                AppId                 = @{ Type = 'Guid'; Default = ''; Description = 'Online/Hybrid: Anwendungs-ID für die Zertifikatsanmeldung (geplante Aufgabe). Leer = interaktiv.' }
                CertificateThumbprint = @{ Type = 'Thumbprint'; Default = ''; Description = 'Fingerabdruck des Zertifikats im Speicher des ausführenden Kontos (kein Secret).' }
                Organization          = @{ Type = 'Domain'; Default = ''; Description = 'Mandant für die Zertifikatsanmeldung (z. B. contoso.onmicrosoft.com).' }
            }
        }

        Graph = @{
            Description = 'Microsoft Graph (optional, z. B. Sitzungen widerrufen).'
            Keys        = @{
                Enabled  = @{ Type = 'Bool'; Default = '0'; Description = 'Graph-Funktionen anbieten.' }
                TenantId = @{ Type = 'String'; Default = ''; Description = 'Tenant-ID oder -Domäne (keine Secrets).' }
                ClientId              = @{ Type = 'Guid'; Default = ''; Description = 'Anwendungs-ID für die Zertifikatsanmeldung (geplante Aufgabe). Leer = interaktiv.' }
                CertificateThumbprint = @{ Type = 'Thumbprint'; Default = ''; Description = 'Fingerabdruck des Zertifikats im Speicher des ausführenden Kontos (kein Secret).' }
            }
        }
    }

    SectionPatterns = @(
        @{
            Pattern     = '^Company\d*$'
            Name        = 'Company'
            Description = 'Unternehmensdaten ([Company], [Company1], ...). Schlüssel dürfen die Abschnittsnummer als Suffix tragen.'
            KeyPatterns = @(
                @{ Pattern = '^CompanyNameFirma\d*$'; Type = 'String'; Description = 'Firmenname (AD-Attribut company).' }
                @{ Pattern = '^CompanyActiveDirectoryDomain\d*$'; Type = 'Domain'; Description = 'UPN-Suffix.' }
                @{ Pattern = '^CompanyActiveDirectoryOU\d*$'; Type = 'Dn'; Description = 'Standard-OU dieses Unternehmens.' }
                @{ Pattern = '^CompanyMailDomain\d*$'; Type = 'MailDomain'; Description = 'Primäre E-Mail-Domäne.' }
                @{ Pattern = '^CompanyMS365Domain\d*$'; Type = 'MailDomain'; Description = 'Microsoft-365-Domäne (sekundäre Proxyadresse).' }
                @{ Pattern = '^CompanyDomain\d*$'; Type = 'String'; Description = 'Webseite (AD-Attribut wWWHomePage).' }
                @{ Pattern = '^CompanyStrasse\d*$'; Type = 'String'; Description = 'Straße.' }
                @{ Pattern = '^CompanyPLZ\d*$'; Type = 'String'; Description = 'Postleitzahl.' }
                @{ Pattern = '^CompanyOrt\d*$'; Type = 'String'; Description = 'Ort.' }
                @{ Pattern = '^CompanyTelefon\d*$'; Type = 'String'; Description = 'Zentrale Rufnummer.' }
                @{ Pattern = '^CompanyCountry\d*$'; Type = 'String'; Description = 'Land (ISO-3166 Alpha-2, z. B. DE).' }
            )
        }
        @{
            Pattern     = '^OffboardingTemplate\.[A-Za-z0-9_\-]+$'
            Name        = 'OffboardingTemplate'
            Description = 'Offboarding-Vorlage.'
            Keys        = @{
                DisplayName             = @{ Type = 'String'; Required = $true; Description = 'Anzeigename.' }
                Description             = @{ Type = 'String'; Default = ''; Description = 'Beschreibung.' }
                RetentionDays           = @{ Type = 'Int'; Min = 0; Max = 3650; Default = '0'; Description = 'Tage bis zur möglichen endgültigen Löschung (0 = keine Löschung).' }
                RetentionPhaseStartDays = @{ Type = 'Int'; Min = 0; Max = 3650; Default = '30'; Description = 'Tage nach Austritt bis zur Aufbewahrungsphase.' }
                RemoveGroupsMode        = @{ Type = 'Enum'; Values = @('AllNonProtected', 'LicenseOnly', 'Selected', 'None'); Default = 'AllNonProtected'; Description = 'Gruppenentfernung.' }
                KeepGroups              = @{ Type = 'List'; Default = ''; Description = 'Zusätzlich beizubehaltende Gruppen.' }
                TargetOU                = @{ Type = 'Dn'; Default = ''; Description = 'Ziel-OU (leer = Offboarding.DisabledUsersOU).' }
                DescriptionTemplate     = @{ Type = 'Template'; Default = ''; Description = 'Kontobeschreibung (leer = Offboarding.DescriptionTemplate).' }
                AutoReplyMessage        = @{ Type = 'String'; Default = ''; Description = 'Text der automatischen Antwort.' }
                ForwardToManager        = @{ Type = 'Bool'; Default = '0'; Description = 'Weiterleitung an die Führungskraft vorschlagen.' }
                IsTestMode              = @{ Type = 'Bool'; Default = '0'; Description = 'Vorlage erzwingt Simulation.' }
                RequireTicket           = @{ Type = 'Bool'; Default = '1'; Description = 'Ticketnummer erforderlich.' }
            }
            KeyPatterns = @(
                @{ Pattern = '^Action\.[A-Za-z]+$'; Type = 'Enum'; Values = @('Immediate', 'ExitDate', 'Retention', 'FinalDeletion', 'Off'); Description = 'Phase der Aktion.' }
            )
        }
        @{
            Pattern     = '^RoleTemplate\.[A-Za-z0-9_\-]+$'
            Name        = 'RoleTemplate'
            Description = 'Rollenvorlage für das Onboarding.'
            Keys        = @{
                DisplayName = @{ Type = 'String'; Required = $true; Description = 'Anzeigename.' }
                Description = @{ Type = 'String'; Default = ''; Description = 'Beschreibung.' }
                Groups      = @{ Type = 'List'; Default = ''; Description = 'Gruppen der Rolle.' }
                License     = @{ Type = 'String'; Default = ''; Description = 'Lizenzschlüssel aus [LicensesGroups].' }
                TargetOU    = @{ Type = 'Dn'; Default = ''; Description = 'Ziel-OU der Rolle.' }
                Title       = @{ Type = 'String'; Default = ''; Description = 'Vorbelegte Position.' }
                Department  = @{ Type = 'String'; Default = ''; Description = 'Vorbelegte Abteilung.' }
            }
        }
    )
}
