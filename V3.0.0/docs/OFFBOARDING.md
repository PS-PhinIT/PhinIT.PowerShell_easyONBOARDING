# Offboarding

Austritte laufen in Phasen: Manche Aktionen erfolgen sofort, andere zum Austrittsdatum, wieder andere
erst in der Aufbewahrungsphase. Eine **endgültige Löschung erfolgt nie automatisch**.

## Ablauf in der Oberfläche

Navigation *Offboarding*, Registerkarte *Neuer Vorgang*:

1. **Benutzer:** Suche nach Name, Anmeldename, UPN oder E-Mail. Geschützte Konten (siehe unten)
   werden sofort als gesperrt angezeigt.
2. **Vorlage und Angaben:** Offboarding-Vorlage, Austrittsdatum (letzter Arbeitstag), Ticket, Grund,
   Weiterleitung an eine interne Adresse, Abwesenheitsnotiz, zurückzugebendes Inventar, Bemerkung.
3. **Vorschau:** Termine je Phase, alle Aktionen nach Phase mit Risiko, Gruppen mit Klassifizierung
   (wird entfernt / bleibt / geschützt), Prüfergebnisse.
4. **Ausführung:** Die fälligen Phasen werden Schritt für Schritt ausgeführt; offene Phasen gehen in
   die Warteschlange.

Das zusätzliche **Handout (HTML/PDF)** ist standardmäßig abgewählt und wird nur nach
ausdrücklicher Auswahl erzeugt, auch bei einer manuellen Löschung. Es enthält die
Vorgangszusammenfassung und Ergebnisse, keine Kennwörter; ohne PDF-Engine bleibt HTML.
Technische Vorgangsberichte, Audit und notwendige Zustandsberichte entstehen unabhängig
davon. Bei unbeaufsichtigten geplanten Phasen wird kein Handout automatisch erzeugt.

Registerkarte *Warteschlange*: offene Vorgänge mit nächster Phase und Fälligkeit, *Fällige Phase
ausführen* (mit Vorschau und Bestätigung), *Löschung prüfen …*, *Vorgang abbrechen …* (mit
Begründung) und *Zustandsberichte öffnen*.

## Phasen

| Phase | Fällig | Beispiele |
|---|---|---|
| Dokumentation | immer | Zustandsbericht vorher/nachher, Vorgangsbericht |
| Sofort (`Immediate`) | bei der Ausführung | Ablaufdatum setzen, Beschreibung, Postfachberechtigungen dokumentieren |
| Zum Austritt (`ExitDate`) | am Tag nach dem letzten Arbeitstag (liegt das Datum in der Vergangenheit: sofort) | Konto deaktivieren, Kennwort zurücksetzen, Sitzungen widerrufen, Gruppen entfernen, verschieben |
| Aufbewahrung (`Retention`) | Austritt + `RetentionPhaseStartDays` | freigegebenes Postfach, Lizenzgruppen entfernen, Home-Verzeichnis archivieren |
| Endgültige Löschung (`FinalDeletion`) | Austritt + `RetentionDays` | Konto löschen – nur manuell, siehe unten |

Eine Phase wird erst ausgeführt, wenn alle vorherigen Phasen erledigt sind. Fehlgeschlagene Phasen
bleiben offen und werden beim nächsten Lauf erneut versucht. Folgephasen werden immer neu geplant
und gegen das AD geprüft (u. a. Abgleich der ObjectGUID); passt das Konto nicht mehr, wird der
Vorgang blockiert.

Unvollständige oder übersprungene aktivierte Schritte schließen eine Phase nicht ab. Eine
offene Sofort-Phase bleibt unmittelbar fällig. Wird die Umwandlung in ein freigegebenes
Postfach angefordert, werden Lizenzgruppen erst nach erfolgreicher Umwandlung entfernt;
eine fehlgeschlagene oder unvollständige Hybrid-Umwandlung darf keinen Lizenzentzug auslösen.
Bei diesem Übergang bleibt die Lizenz auch bei Litigation Hold oder aktivem Archiv erhalten.
Die bestätigte Umwandlung bedeutet nicht automatisch, dass das Postfach lizenzfrei ist:
Größe, Archiv und Aufbewahrungsanforderungen vorab in Exchange prüfen. Bei nicht geklärtem
Lizenzbedarf `RemoveLicenseGroups` in der Vorlage deaktivieren und Lizenzgruppen auch von
allgemeinen Gruppenentfernungen ausnehmen; erst nach der Prüfung manuell freigeben.

Zugriff auf ein Home-Verzeichnis verlangt eine ausdrückliche Freigabe des Empfängerkontos
(`AuthorizedHomeAccessAccount` in der Anfrage: einfacher `sAMAccountName`, ohne Domänenpräfix,
z. B. `chefin`; leer = kein Zugriff). Der AD-Eintrag `manager` allein autorisiert
keinen Zugriff. Das Ziel muss exakt `<AllowedRoot>/<SamAccountName>` sein; Stammpfade,
fremde Verzeichnisse, Traversal und Reparse-Point-Vorfahren werden abgelehnt. Benutzerordner
mit abweichender Namenskonvention müssen außerhalb dieses automatischen Vorgangs geprüft
und berechtigt werden. Windows-ACLs vor Produktivbetrieb in einer Testumgebung prüfen.

## Vorlagen

Mitgeliefert in `Config/templates/offboarding-templates.ini`; eigene Anpassungen am besten in
`Config/easyONB.ini` (hat Vorrang).

| Vorlage (`[OffboardingTemplate.<Name>]`) | Anzeigename | Aufbewahrung ab / Löschung nach (Tage) | Besonderheiten |
|---|---|---|---|
| `Standard` | Standardaustritt | 30 / 180 | Sperre zum Austrittsdatum |
| `SofortigeSperrung` | Sofortige Sperrung | 30 / 180 | alle Sperren sofort, zusätzlich Anmeldezeiten gesperrt |
| `Befristet` | Befristeter Mitarbeiter | 14 / 90 | Vertragsende |
| `Extern` | Externer Dienstleister | 7 / 30 | kein Postfach-Übergang, keine Archivierung |
| `Ruhestand` | Ruhestand | 60 / 365 | Weiterleitung an die Führungskraft vorgeschlagen |
| `InternerWechsel` | Interner Wechsel | – / – | Konto bleibt aktiv, nur ausgewählte Gruppen werden entfernt, keine Löschung |
| `Testmodus` | Testmodus (nur Simulation) | 1 / 2 | erzwingt die Simulation, kein Ticket nötig |

Aufbau einer Vorlage:

```ini
[OffboardingTemplate.Standard]
DisplayName=Standardaustritt
RetentionPhaseStartDays=30
RetentionDays=180
RemoveGroupsMode=AllNonProtected
Action.SetExpiration=Immediate
Action.DisableAccount=ExitDate
Action.ConvertToSharedMailbox=Retention
Action.DeleteAccount=FinalDeletion
Action.SetForwarding=Off
```

`RetentionDays=0` bedeutet: keine Löschung vorgesehen. Alle Schlüssel einer Vorlage: Abschnitt
*OffboardingTemplate* der [Konfigurationsreferenz](CONFIGURATION-REFERENCE.md).

## Aktionen

| Aktion | System | Wirkung |
|---|---|---|
| `DisableAccount` | AD | Konto deaktivieren |
| `SetExpiration` | AD | Ablaufdatum auf das Austrittsdatum setzen |
| `DenyLogonHours` | AD | Anmeldezeiten vollständig sperren |
| `UpdateDescription` | AD | Beschreibung nach `[Offboarding] DescriptionTemplate` |
| `ResetPassword` | AD | zufälliges Kennwort (32 Zeichen), wird nicht angezeigt |
| `ForcePasswordChange` | AD | Kennwortänderung bei der nächsten Anmeldung erzwingen |
| `RemoveGroups` | AD | Gruppen entfernen gemäß `RemoveGroupsMode` (`AllNonProtected`, `LicenseOnly`, `Selected`, `None`) |
| `RemoveLicenseGroups` | AD | Lizenzgruppen (`[LicensesGroups]`) entfernen |
| `ClearManager` | AD | Führungskraft entfernen |
| `MoveToOU` | AD | in `TargetOU` bzw. `[Offboarding] DisabledUsersOU` verschieben |
| `ClearProfilePath` | AD | Profilpfad leeren |
| `RevokeSessions` | Microsoft Graph¹ | Anmeldesitzungen und Aktualisierungstoken widerrufen |
| `HideFromAddressLists` | Exchange¹ | aus Adresslisten ausblenden |
| `SetAutoReply` | Exchange¹ | Abwesenheitsnotiz (Vorlage oder eigener Text) |
| `SetForwarding` | Exchange¹ | Weiterleitung, nur an interne Domänen |
| `ConvertToSharedMailbox` | Exchange¹ | in ein freigegebenes Postfach umwandeln |
| `DocumentMailboxPermissions` | Exchange¹ | Postfachberechtigungen als JSON und CSV dokumentieren |
| `ArchiveHomeDirectory` | Dateiserver | Home-Verzeichnis nach `[FileServer] ArchiveRoot` verschieben (nur unter `AllowedRoots`) |
| `GrantManagerHomeAccess` | Dateiserver | Führungskraft erhält Lesezugriff auf das Home-Verzeichnis |
| `DeleteAccount` | AD | endgültige Löschung (nur Phase `FinalDeletion`, nur manuell) |

¹ vorbereitet: implementiert und mit Mocks getestet, nicht gegen reale Umgebungen verifiziert. Ist die
Integration nicht aktiv oder nicht verbunden, zeigt die Vorschau die Aktion als nicht ausführbar an.

**Gruppen, die nie entfernt werden:** primäre Gruppe, Lizenzgruppen (nur über `RemoveLicenseGroups`),
die Microsoft-365-Synchronisationsgruppe sowie Gruppen aus `[Offboarding] KeepGroups` bzw. `KeepGroups`
der Vorlage.

## Schutz von Konten

* **Nie bearbeitet:** das eigene Konto, eingebaute Konten (RID 500–504), Notfallkonten
  (`BreakGlassAccounts`), Dienstkonten (`ServiceAccountPatterns`), `ProtectedAccounts` und Konten in
  `ProtectedOUs`.
* **Privilegierte Konten** (Mitglied privilegierter Gruppen, `adminCount=1`): nur mit
  `[Security] AllowPrivilegedOffboarding=1` und der ausdrücklichen Bestätigung im Assistenten; nie
  durch die geplante Aufgabe.
* Unterstellte Mitarbeitende erscheinen in der Vorschau als Warnung, damit ihnen eine neue
  Führungskraft zugeordnet wird.

## Warteschlange und geplante Ausführung

Nach einer Live-Ausführung mit offenen Phasen entsteht je Vorgang eine Datei in
`Data/OffboardingQueue/<OperationId>.json` (keine Kennwörter; Anfrage, Termine, erledigte Phasen,
Historie, Pfade und SHA-256-Prüfsummen der Zustandsberichte). Status: `Open`, `AwaitingDeletion`,
`Completed`, `Cancelled`, `Deleted`.

Fällige Phasen führt entweder die Oberfläche oder die geplante Aufgabe
`Scripts/Invoke-DueOffboardingPhases.ps1` aus ([INSTALLATION.md](INSTALLATION.md#geplante-aufgabe-für-folgephasen-des-offboardings)).
Phasen vorziehen (z. B. bei vorzeitigem Austritt) ist per PowerShell möglich:

```powershell
$plan = New-EobOffboardingPlanFromQueue -QueueEntry $entry -Config $config
Invoke-EobOffboardingPlan -Plan $plan -Phase Immediate, ExitDate -WhatIf   # erst simulieren
```

## Endgültige Löschung

Die Löschung ist nur über *Warteschlange › Löschung prüfen …* möglich und setzt voraus:

1. Vorgang im Status `AwaitingDeletion`, Aufbewahrungsfrist abgelaufen (`RetentionDays > 0`),
2. ein Zustandsbericht "vorher" ist vorhanden **und unverändert** (Abgleich der SHA-256-Prüfsumme),
3. das Konto ist per ObjectGUID eindeutig, deaktiviert, nicht geschützt und nicht gegen Löschen gesperrt,
4. Vorschau mit Warnungen (z. B. AD-Papierkorb nicht aktiviert, synchronisiertes Postfach),
5. Eingabe des Bestätigungstexts `LÖSCHEN <Anmeldename>`.

Unmittelbar vor der Löschung wird ein weiterer Zustandsbericht ("vor-loeschung") gespeichert. Alle
Schritte werden im Audit-Log festgehalten. In der Simulation wird nur angezeigt, was gelöscht würde.

## Massen-Offboarding (CSV)

Ansicht *Massenverarbeitung* › Offboarding. Spalten: `Identity` (auch `SamAccountName`,
`UserPrincipalName`, `UPN`, `Mail`, `Benutzer`, `Konto`)*, `ExitDate` (`Austrittsdatum`, `Austritt`,
`EndDate`)*, `Template` (`Vorlage`), `Ticket`, `Reason` (`Grund`), `ForwardTo` (`Weiterleitung`),
`Notes` (`Bemerkung`), `Assets` (`Inventar`), `TargetOU` (`ZielOU`). Jede Zeile wird einzeln geplant und
geprüft; privilegierte Konten werden in der Massenverarbeitung nicht bearbeitet. Ab
`[Bulk] ConfirmationThreshold` Zeilen ist die Eingabe `AUSFÜHREN <Anzahl>` erforderlich.
