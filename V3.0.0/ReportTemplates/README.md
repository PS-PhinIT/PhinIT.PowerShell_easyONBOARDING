# Berichtsvorlagen

`HTMLTemplate.txt` (Deutsch) und `HTMLTemplateENG.txt` (Englisch) sind die Vorlagen des
**Willkommensdokuments (Handout)**, das beim Onboarding immer erzeugt wird. Der Legacy-Schlüssel
`[Report] CreateWelcomeDocument` wird ignoriert. Eine fehlende Vorlage sperrt den Onboarding-Plan;
in der Simulation wird kein Handout geschrieben.
Sie stammen aus Version 1.4.x und wurden für 3.0 bereinigt:

* Kennwort-Platzhalter (`{{Passwort}}`, `{{CustomPW1..5}}`, `{{CompanyVPNPassword}}`) wurden entfernt.
  Werden sie in eigenen Vorlagen weiterverwendet, ersetzt easyONBOARDING sie durch einen Hinweistext –
  Kennwörter gelangen nie in eine Datei.
* Die Kennwortkriterien werden aus der konfigurierten Richtlinie erzeugt (`{{PasswordPolicyList}}`).
* Alle Werte werden HTML-kodiert eingesetzt. Nicht befüllte Platzhalter werden entfernt und im
  Ergebnis als Warnung gemeldet.
* Zusätzliche Platzhalter lassen sich im Abschnitt `[ReportPlaceholders]` der INI definieren.
* Bilder werden über `{{AssetDataUri:Report/<Datei>}}` aus dem Ordner `Assets` als data-URI
  eingebettet (PNG, JPG, GIF, SVG, WebP; max. 2 MB; nur innerhalb von `Assets`). Die fest
  codierten Pfade `C:\easyIT\...` der Version 1.4 wurden dadurch ersetzt; das Dokument ist
  eigenständig und kann als HTML oder PDF weitergegeben werden.
* Korrigiert: Die Zeilen „Büro"/„Telefon" (EN: „Office"/„Phone") zeigten in 1.4 vertauschte
  Beschriftungen.

Rangfolge der Werte (spätere Quellen gewinnen): Berichtseinstellungen (`ReportTitle`/`ReportHeader`,
`ReportFooter`, `ReportDate`, `Admin`) → Unternehmensdaten (`CompanyName`, `CompanyStreet`,
`CompanyZIP`, `CompanyCity`, `CompanyPhone`, `CompanyDomain`, `CompanyWebsite`) →
`[CompanyHelpdesk]`, `[CompanyWLAN]`, `[CompanyVPN]` → `[ReportPlaceholders]` → Benutzerwerte
(`Vorname`, `Nachname`, `DisplayName`, `LoginName`, `UPN`, `MailAddress`, `Position`, `Abteilung`,
`Buero`, `Rufnummer`, `Mobil`, `Ablaufdatum`, `License`).

Die technischen Berichte (Vorgangsbericht, Offboarding-Zustandsbericht) werden unabhängig von diesen
Vorlagen erzeugt (HTML, JSON, CSV, TXT, optional PDF).

Eine Übersicht aller Platzhalter enthält `docs/CONFIGURATION.md`.
