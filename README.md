# deSEC Client (iOS)

Inoffizielle native iOS-App (Swift/SwiftUI, iOS 17+) für die [deSEC](https://desec.io) DNS-API v1.

## Funktionen

- **Mehrere Konten** – Anmeldung per E-Mail + Passwort **mit 2FA (TOTP)** oder per API-Token, schneller Kontowechsel
- **Domains** – auflisten, suchen, anlegen (optional mit Zonefile-Import), löschen (mit Namens-Bestätigung), zuständige Domain für einen Namen finden
- **DNS-Einträge (RRsets)** – alle von deSEC unterstützten Typen ansehen, anlegen, ändern, löschen; Typ-Filter, Suche, Mehrfachauswahl
- **Diff-Vorschau** vor jeder Änderung, Extra-Warnung bei NS/DS/DNSKEY
- **Bulk-Editor** – viele Einträge atomar in einem Schritt (Zeilenformat `name ttl TYP wert`)
- **DNSSEC & Delegation** – DS/DNSKEY kopieren, Delegationsstatus, Neuprüfung anstoßen
- **Zonefile-Export** über das Teilen-Menü
- **Tokens** – anlegen (Geheimnis wird einmalig angezeigt), Rechte, erlaubte Netze, Ablauf, Auto-Policy, Login-Sitzungen beenden
- **Token-Policies** – Standard-Policy und spezifische Policies je Domain/Subname/Typ
- **Konto** – Infos und Domain-Limit, Newsletter-Einstellung, E-Mail ändern, Passwort zurücksetzen, Konto löschen, Registrierung mit Captcha, Bestätigungslinks aus E-Mails einlösen
- **dynDNS** – IP-Update für einen oder mehrere Hosts, öffentliche IPv4/IPv6 erkennen
- **Sicherheit** – Zugangsdaten nur im Schlüsselbund (`WhenUnlockedThisDeviceOnly`), optionale App-Sperre per Face ID/Code
- Automatischer Retry bei Rate-Limits (HTTP 429), Cursor-Pagination ab 500 Einträgen

## Build per GitHub Actions

1. Neues Repo anlegen, Inhalt dieses Ordners pushen (Branch `main`).
2. Der Workflow `.github/workflows/build.yml` erzeugt mit XcodeGen das Projekt und baut eine **unsignierte IPA**.
3. Unter *Actions → Build unsigned IPA → Artifacts* die Datei `DesecClient-unsigned.ipa` herunterladen und mit deinem Zertifikat signieren.

Bundle-ID ändern: `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml`.

## Lokal bauen

```sh
brew install xcodegen
xcodegen generate
open DesecClient.xcodeproj
```

## Hinweise zu 2FA

deSEC-Login-Tokens haben bei aktivierter 2FA zunächst eingeschränkte Rechte (`mfa: false`). Die App fragt nach dem Login die TOTP-Faktoren ab (`GET /auth/totp/`) und bestätigt den Code über `POST /auth/totp/{id}/verify/`. Diese Schnittstelle ist laut deSEC noch nicht final und kann sich ändern.

Login-Tokens laufen nach 1 Stunde Inaktivität bzw. 7 Tagen ab. Dann erscheint automatisch der Anmeldedialog; mit gespeichertem Passwort genügt der 2FA-Code. Für dauerhaften Zugriff ohne erneute Anmeldung kann man in der App ein API-Token erstellen und als zusätzliches Konto hinzufügen – API-Tokens sind allerdings nicht durch 2FA geschützt.

## Struktur

```
DesecClient/
  App/        App-Einstieg, Tab-Navigation, Sperrbildschirm
  API/        DesecClient (HTTP), Modelle
  Store/      AppModel (Konten), Keychain, Hilfsfunktionen
  Views/      Auth, Domains, Records, Tokens, Account, DynDNS, Settings
```
