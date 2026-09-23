# MacAdBlock

Natywny projekt macOS w Swift 6 przygotowany dla Xcode 27 i macOS 27. Minimalny target ustawiono na macOS 15, ponieważ użyte publiczne API są dostępne wcześniej; dzięki temu aplikacja pozostaje kompatybilna wstecz i działa na macOS 27 bez warunkowego używania prywatnych API.

Projekt zawiera:

- aplikację SwiftUI z dashboardem, `MenuBarExtra`, ustawieniami, listą źródeł i statystykami,
- warstwę pobierania z `ETag`, `Last-Modified`, SHA-256, atomowym cache i odzyskiwaniem po niespójnym `304`,
- parser reguł Adblock Plus/uBlock/AdGuard oraz parser `hosts`/list domen,
- deduplikację, współdzielony App Group storage i generowanie dwóch formatów reguł Safari,
- klasyczny Safari Content Blocker oraz Safari Web Extension Manifest V3 z popupem i szkieletem element pickera,
- uprzywilejowany LaunchDaemon/XPC zarządzający wyłącznie własną sekcją `/etc/hosts`,
- uruchamianie głównej aplikacji przy logowaniu przez `SMAppService.mainApp`,
- odseparowany, opcjonalny target `DNSProxy` oparty o `NEDNSProxyProvider`,
- systemowy klient Personal VPN dla serwerów IKEv2, z hasłem przechowywanym w Pęku kluczy,
- wybór gotowych, oficjalnie udokumentowanych adresów Surfshark i hide.me bez ręcznego wpisywania hostname oraz Remote ID,
- pakiet Swift z testami parserów i kompilatora,
- kontrolę instalacji przy każdym uruchomieniu oraz aktualizator pakietów `.pkg` z HTTPS i weryfikacją SHA-256.
- blokadę pojedynczej instancji: kolejna kopia aktywuje już działające okno i natychmiast się zamyka.
- wspólną listę wyjątków dla wszystkich warstw: wyjątek zapisany w popupie Safari lub w aplikacji wyłącza Content Blocker, reguły Web Extension, sekcję `/etc/hosts` i DNS proxy,
- własne reguły w składni Adblock Plus oraz własne listy z adresów HTTPS, dopisywane do katalogu w czasie działania,
- selektory wskazane element pickerem zapisywane jako własne reguły w aplikacji, więc przetrwają ponowną instalację rozszerzenia,
- adaptacyjny limit reguł Content Blockera: domyślnie 150 000, automatycznie zmniejszany, gdy Safari odrzuci listę,
- eksport i import konfiguracji do pliku JSON oraz powiadomienie po trzech nieudanych aktualizacjach z rzędu.
- minimalistyczny interfejs: neutralne, płaskie tła, karty bez poświaty i kolorowych obwódek, akcent tylko jako nośnik stanu,
- ikonę paska menu z SF Symbols (`checkmark.shield` / `shield.slash`), więc grubość i rozmiar dobiera system,
- okienko paska menu w układzie menu systemowego oraz popup Safari bez kart i bez zmyślonych statystyk,
- jedną rodzinę ikon z tego samego znaku (tarcza z ptaszkiem): kafelek dla listy rozszerzeń Safari, jednobarwny glif dla paska Safari i szablonowy glif dla paska menu macOS, generowane skryptem `Scripts/generate-icons.py`,
- jeden zestaw kolorów w `SentinelTheme` (`accent` i `control`) używany przez wszystkie widoki oraz popup rozszerzenia,
- drugi Content Blocker (`SafariBlocker2`): Safari liczy limit reguł osobno dla każdego rozszerzenia, więc reguły są dzielone na dwie listy, a wyjątki allowlisty trafiają na koniec każdej z nich,
- diagnostykę domeny w oknie „Diagnostyka i własne reguły”: która włączona lista zawiera regułę dla domeny, czy jest w sekcji hosts, ile reguł ukrywania i jakie scriptlety ją obejmują, z przykładowymi regułami i jednym kliknięciem dodania wyjątku,
- scriptlety `##+js(...)` i `#%#//scriptlet(...)`: set-constant, abort-on-property-read, abort-on-property-write, json-prune, prevent-setTimeout, prevent-setInterval i prevent-window-open, wykonywane w kontekście strony wyłącznie dla reguł z wskazaną domeną.

## Instalator i aktualizacje aplikacji

Przy każdym uruchomieniu MacAdBlock sprawdza, czy działa z `/Applications/MacAdBlock.app`. Jeśli uruchomiono nowszą kopię z Xcode, katalogu Pobrane lub obrazu dysku, aplikacja proponuje instalację albo zastąpienie starszej wersji w folderze Aplikacje. Po skopiowaniu uruchamia zainstalowaną kopię i zamyka bieżącą.

Pakiet instalacyjny utworzysz poleceniem:

```sh
Scripts/build-installer.sh /ścieżka/do/MacAdBlock.app
```

Skrypt zapisuje w `Build/Installer` pakiet `.pkg` instalujący aplikację w `/Applications` oraz gotowy `update-manifest.json`. Podpis produkcyjny instalatora można przekazać przez `INSTALLER_SIGN_IDENTITY`, a docelowy adres pakietu przez `MACADBLOCK_PACKAGE_URL`.

Automatyczne sprawdzanie wersji internetowej włączysz, wpisując adres HTTPS opublikowanego manifestu w kluczu `MacAdBlockUpdateManifestURL` pliku `Configuration/App-Info.plist`. Format pokazuje `Configuration/update-manifest.example.json`. Gdy numer `build` lub wersja jest nowsza, aplikacja pobiera `.pkg`, ogranicza jego rozmiar, porównuje SHA-256 z manifestem i dopiero potem otwiera systemowy Instalator. Instalacja do chronionego `/Applications` wymaga zgody macOS; aplikacja celowo jej nie omija.

Przed publiczną dystrybucją podpisz aplikację certyfikatem Developer ID Application, pakiet certyfikatem Developer ID Installer oraz notaryzuj oba artefakty. Dla publicznego kanału aktualizacji zalecane jest przejście na Sparkle 2 z podpisem EdDSA zamiast polegania wyłącznie na TLS i SHA-256.

## Wymagania

- Xcode 27 beta 4 lub nowszy na Apple silicon oraz macOS Tahoe 26.4 lub nowszy. Xcode 27 zawiera SDK macOS 27 i Swift 6.4.
- Konto Apple Developer do podpisania App Group, rozszerzeń Safari, LaunchDaemona oraz Network Extension.
- Do samego sprawdzenia kompilacji kodu wystarczy wyłączyć code signing. Projekt został także sprawdzony w Xcode 26.6 / SDK macOS 26.5, z wyjątkiem funkcji zależnych od podpisania.

Oficjalne wymagania Xcode: <https://developer.apple.com/xcode/system-requirements/>

## Targety

| Target | Bundle identifier | Funkcja | Specjalne wymagania |
|---|---|---|---|
| `MacAdBlock` | `com.italiano88.MacAdBlock` | Główna aplikacja | App Group, podpis deweloperski |
| `SafariBlocker` | `com.italiano88.MacAdBlock.SafariBlocker` | Klasyczny Content Blocker | App Group, rozszerzenie Safari |
| `SafariWebExtension` | `com.italiano88.MacAdBlock.SafariWebExtension` | Web Extension + DNR | App Group, rozszerzenie Safari |
| `HostsHelper` | `com.italiano88.MacAdBlock.HostsHelper` | Uprzywilejowany XPC/LaunchDaemon | Developer ID/team, zatwierdzenie administratora |
| `DNSProxy` | `com.italiano88.MacAdBlock.DNSProxy` | Opcjonalny DNS Proxy | Network Extension: DNS Proxy |

`DNSProxy` celowo nie jest zależnością schematu aplikacji i nie jest osadzany. Dzięki temu podstawowa aplikacja buduje się bez Network Extension entitlement.

## Pierwsza konfiguracja w Xcode 27

> Ważne: konfiguracje `Debug` i `Release` używają tych samych plików App Group entitlements. Dzięki temu build uruchomiony przyciskiem Run przekazuje reguły do rozszerzeń tak samo jak wydanie produkcyjne. Nie usuwaj entitlements z konfiguracji Debug, jeśli testujesz Safari.

1. Otwórz `MacAdBlock.xcodeproj`.
2. Dla wszystkich targetów wybierz ten sam `Team` w `Signing & Capabilities`.
3. Zastąp prefiks `com.example` własnym odwróconym identyfikatorem we wszystkich Bundle ID i w plikach źródłowych/konfiguracyjnych.
4. Utwórz App Group, na przykład `group.pl.twojafirma.MacAdBlock`, i zastąp `group.com.italiano88.MacAdBlock` w:
   - `SharedStorage.swift`,
   - `MacAdBlock.entitlements`,
   - `SafariExtension.entitlements`,
   - opcjonalnie `DNSProxy.entitlements`.
5. Włącz capability App Groups dla aplikacji, Content Blockera i Web Extension.
6. Dla ekranu VPN włącz capability `Personal VPN` w głównym targecie aplikacji.
7. W Safari włącz oba rozszerzenia w `Safari → Ustawienia → Rozszerzenia`.
8. Uruchom aplikację i wybierz „Aktualizuj teraz”. Po kompilacji list aplikacja prosi Safari o przeładowanie Content Blockera, a Web Extension pobiera reguły przez native messaging.

MacAdBlock sprawdza osobno stan obu rozszerzeń i przy pierwszym uruchomieniu danej kompilacji automatycznie otwiera właściwy panel ustawień Safari, jeśli któregoś modułu brakuje. System Apple nie udostępnia API do samodzielnego zaznaczenia rozszerzenia: użytkownik musi jednorazowo potwierdzić każde z nich w Safari. Aplikacja wykrywa tę zmianę i po powrocie pokazuje aktualny stan obu modułów.

Nie zmieniaj samych identyfikatorów targetów bez równoczesnej aktualizacji stałych `AppIdentifiers`, nazwy usługi Mach, launchd plist i pól autoryzacji helpera.

Konfiguracja `Debug` używa lokalnego podpisu ad-hoc oraz ograniczonych plików `MacAdBlock-Debug.entitlements` i `SafariExtension-Debug.entitlements`. Dzięki temu aplikację i interfejs można uruchomić przyciskiem Run bez certyfikatu deweloperskiego. App Group, komunikacja rozszerzeń, helper hosts i VPN są w tym trybie diagnostycznie odseparowane i mogą być niedostępne. `Release` zachowuje pełne entitlementy; pełne funkcje systemowe wymagają wybrania Team, prawidłowego certyfikatu Apple Development oraz profili z odpowiednimi capabilities.

Safari domyślnie nie rejestruje rozszerzeń z aplikacji podpisanej ad-hoc. Taki build nie ma Apple Team ID, mimo że sam podpis pakietu jest technicznie poprawny. Do testu można każdorazowo po uruchomieniu Safari włączyć `Programowanie → Zezwalaj na niepodpisane rozszerzenia`; do normalnego działania trzeba podpisać aplikację i oba rozszerzenia tym samym Apple Teamem. Aplikacja wykrywa brak Team ID i pokazuje tę przyczynę zamiast błędnie zgłaszać brak plików rozszerzeń.

## App Group i storage

Współdzielony kontener ma katalogi:

```text
FilterCache/                 surowe listy źródłowe
Generated/blockerList.json   reguły Safari Content Blocker
Generated/dnr-rules.json     dynamiczne reguły declarativeNetRequest
Generated/cosmetic-rules.json reguły kosmetyczne i proceduralne Web Extension
Generated/hosts-domains.txt  znormalizowane domeny dla helpera
download-metadata.json       ETag, Last-Modified, SHA-256, rozmiar i data
statistics.json              ostatnie statystyki kompilacji
```

Główna aplikacja ma fallback do Application Support wyłącznie po to, aby można było uruchomić niepodpisany build interfejsu. Rozszerzenia nie stosują fallbacku, bo muszą odczytywać dokładnie ten sam App Group.

## Źródła filtrów

- globalne: EasyList, EasyPrivacy, Fanboy Annoyances i Fanboy Social,
- wyspecjalizowane: EasyList Cookies, Newsletter Notices i Notifications,
- AdGuard: Base, Tracking Protection, Social, Annoyances i URL Tracking,
- uBlock Origin: Ads, Privacy, Quick Fixes i Badware,
- regionalne: Polska, Niemcy, Francja, Włochy, Hiszpania i Niderlandy,
- hosts: StevenBlack Unified, AdAway, Peter Lowe oraz HaGeZi Multi PRO,
- bezpieczeństwo: CERT Polska oraz opcjonalne listy fake news i hazardu StevenBlack.

Przy pierwszym uruchomieniu kreator proponuje profil lekki, zalecany albo maksymalny, pozwala wybrać kraje oraz kategorie i pokazuje szacowaną liczbę reguł. Profil maksymalny może powodować więcej fałszywych blokad; HaGeZi PRO i dodatkowe warianty hosts najlepiej włączać świadomie. Kreator można ponownie otworzyć z ekranu „Listy ochrony”.

Sprawdź licencje i warunki redystrybucji każdego źródła przed publikacją aplikacji. MacAdBlock pobiera listy z ich oficjalnych adresów i nie dołącza ich treści do repozytorium.

Parser obsługuje reguły sieciowe i wyjątki `@@`, anchory `|`/`||`, separator `^`, wildcard `*`, bezpośrednie wyrażenia regularne, `domain=`/`from=`, `third-party`/`first-party`, `match-case`, `important`, `$method=` z metodami dodatnimi i wykluczonymi, dodatnie i ujemne typy zasobów, wyjątki `document`/`elemhide`/`generichide`/`genericblock`, blokowanie cookies, przejście na HTTPS oraz bezpieczne warianty `removeparam=`. Rozpoznaje reguły kosmetyczne `##`/`#@#`, CSS injection, `:remove()`, `:style()`, `:has-text()`, `:matches-attr()`, `:matches-css()`, `:matches-path()`, `:min-text-length()`, `:xpath()`, `:upward()`, `:remove-attr()` i `:remove-class()`.

MacAdBlock celowo nie wykonuje dowolnego JavaScriptu ani scriptletów pobranych z list. Nie implementuje też modyfikacji treści odpowiedzi HTML, `replace=`, dowolnego CSP ani dowolnych nagłówków. Safari Web Extensions nie udostępniają blokującego dostępu do pełnego ciała odpowiedzi, a wykonywanie kodu pochodzącego z niezaufanej listy byłoby ryzykiem bezpieczeństwa. Takie reguły są liczone jako nieobsługiwane, zamiast po cichu wykonywane.

Nieznany lub nieobsługiwany modyfikator powoduje pominięcie całej reguły, a nie utworzenie szerszej blokady. Parser respektuje również `badfilter`. Przy zapełnieniu limitu Safari najpierw zachowuje wyjątki i reguły `important`, następnie transformacje prywatności, a dopiero później zwykłe blokady.

## Safari

MacAdBlock łączy warstwy zamiast polegać na jednym mechanizmie:

1. klasyczny Safari Content Blocker blokuje żądania wcześnie i bez uruchamiania kodu strony,
2. Manifest V3 `declarativeNetRequest` obsługuje reguły dynamiczne, metody HTTP, wyjątki, HTTPS, cookies i parametry śledzące,
3. reguły kosmetyczne ukrywają oraz bezpiecznie usuwają elementy strony,
4. procedury DOM obsługują wybrane reguły tekstowe, atrybutowe, CSS, XPath i relacje przodków,
5. element picker tworzy prywatne reguły użytkownika dla konkretnej domeny,
6. lista dozwolona i czasowa pauza wyłączają ochronę bez usuwania konfiguracji,
7. hosts i opcjonalny DNS Proxy zatrzymują znane domeny reklamowe także poza Safari.

Klasyczny Content Blocker zwraca plik JSON przez `NSExtensionRequestHandling`; aplikacja przeładowuje go publicznym `SFContentBlockerManager.reloadContentBlocker(withIdentifier:)`.

Safari Web Extension używa Manifest V3 i `declarativeNetRequest`. Reguły dynamiczne są przekazywane z natywnego handlera w App Group do `background.js`, ograniczane do limitu zgłaszanego przez Safari i uzupełniane regułami listy dozwolonej. Rozszerzenie obsługuje blokowanie i wyjątki, `allowAllRequests`, filtrowanie metod HTTP, upgrade HTTPS, usuwanie znanych parametrów śledzących, usuwanie nagłówka Cookie dla pasujących reguł oraz dynamiczne i sesyjne odświeżanie. `declarativeNetRequestWithHostAccess` jest wymagane dla operacji modyfikujących nagłówki, dlatego Safari może poprosić użytkownika o dostęp do witryn.

Warstwa kosmetyczna działa od `document_start`, we wszystkich ramkach, dzieli duże arkusze na bezpieczne fragmenty, reaguje na dynamiczne zmiany DOM i usuwa wyłącznie jawnie oznaczone, puste kontenery reklamowe. Element picker zapisuje własne selektory per domena. Scriptlety są parsowane wyłącznie po to, by raportować brak obsługi — nie są wykonywane.

Ograniczenia platformy są celowe i widoczne: aplikacja nie przechwytuje całego ciała odpowiedzi HTML, nie wykonuje dowolnych scriptletów z list, nie używa prywatnego blokującego `webRequest`, nie prowadzi lokalnego MITM HTTPS i nie deklaruje pełnej obsługi przekierowań filtrów AdGuard w Safari. Reguły wymagające tych technik są pomijane zamiast tłumaczone na szerszą, potencjalnie błędną blokadę.

Klasyczny Content Blocker korzysta z akcji `block`, `block-cookies`, `css-display-none`, `ignore-previous-rules` i `make-https`, a triggery uwzględniają typ zasobu, domenę strony, czułość wielkości liter i relację first-/third-party. Reguły są układane tak, aby wyjątki następowały po blokadach, zgodnie z semantyką WebKit.

Dokumentacja Apple:

- <https://developer.apple.com/documentation/safariservices/creating-a-content-blocker>
- <https://developer.apple.com/documentation/safariservices/blocking-content-with-your-safari-web-extension>
- <https://developer.apple.com/documentation/safariservices/managing-safari-web-extension-permissions>
- <https://webkit.org/blog/17333/webkit-features-in-safari-26-0/>
- <https://webkit.org/blog/13966/webkit-features-in-safari-16-4/>

Składnia list i źródła referencyjne:

- <https://help.adblockplus.org/adblock-plus-help-center/how-to-write-filters>
- <https://github.com/gorhill/uBlock/wiki/Static-filter-syntax>
- <https://github.com/easylist/easylist>
- <https://github.com/AdguardTeam/AdguardFilters>
- <https://github.com/uBlockOrigin/uAssets>

## Helper `/etc/hosts`

`HostsHelper` jest osadzany w `MacAdBlock.app/Contents/Resources`, a jego plist w `Contents/Library/LaunchDaemons`. Plist używa `BundleProgram`, zgodnie z aktualnym modelem `SMAppService` dla macOS 13+.

Helper:

- akceptuje połączenie XPC tylko od procesu o oczekiwanym Bundle ID i Team ID,
- odrzuca brak Team ID, więc niepodpisany build nie może modyfikować `/etc/hosts`,
- waliduje i deduplikuje domeny oraz ogranicza wielkość wejścia i pliku wynikowego,
- utrzymuje tylko sekcję między markerami `BEGIN/END MacAdBlock`,
- blokuje równoległe zapisy,
- tworzy backupy `0600` w `/var/db/MacAdBlock`,
- zapisuje plik tymczasowy na tym samym woluminie, zachowuje właściciela i uprawnienia, wykonuje `fsync` i atomowy `rename`.

Przed dystrybucją:

1. Ustaw stabilny Bundle ID i Team.
2. Zainstaluj podpisaną aplikację w stabilnej lokalizacji (`/Applications` albo poprzez podpisany pakiet instalacyjny).
3. Aplikacja automatycznie podejmie próbę rejestracji helpera przy uruchomieniu.
4. Jednorazowo zatwierdź usługę w `Ustawienia systemowe → Ogólne → Rzeczy logowania`; tego kroku celowo nie można ominąć programowo.
5. Opcja „Odświeżaj hosts automatycznie razem z filtrami” jest domyślnie włączona. Po zatwierdzeniu helpera każda aktualizacja list bezpiecznie podmienia wyłącznie zarządzaną sekcję MacAdBlock.
6. Dla produkcji rozszerz autoryzację klienta o weryfikację pełnego designated requirement/audit token zgodnie z własną polityką podpisu i wykonaj audyt bezpieczeństwa helpera.

Apple opisuje układ pakietu i `SMAppService` tutaj: <https://developer.apple.com/documentation/servicemanagement/updating-helper-executables-from-earlier-versions-of-macos>

## DNS Proxy

Target wymaga capability `Network Extensions → DNS Proxy` i entitlementu `com.apple.developer.networking.networkextension` z wartością `dns-proxy`. W niektórych modelach dystrybucji potrzebny jest odpowiedni profil provisioning; dla system extension podpisywanej Developer ID Apple definiuje osobną wartość `dns-proxy-systemextension`.

Provider obsługuje przepływy UDP i TCP, odczytuje współdzieloną listę domen, odpowiada NXDOMAIN dla domen zablokowanych i przekazuje pozostałe zapytania do świadomie wybranego upstreamu. Aplikacja konfiguruje `NEDNSProxyManager` dla Cloudflare, Quad9 lub AdGuard DNS. Ustawienie „Systemowy” nie aktywuje rozszerzenia. Obecny forwarder używa klasycznego DNS na porcie 53; produkcyjna wersja powinna dodać DoH/DoT, DNSSEC, timeouty, health checks i kontrolowany fallback.

Aktywny provider sprawdza aktualizację współdzielonej listy domen co 30 sekund, więc nowe blokady zaczynają działać bez restartowania rozszerzenia. Zapytania przychodzące przez TCP są przekazywane do upstreamu również przez TCP, z obsługą ramek częściowych i wielu zapytań w jednym strumieniu.

Dokumentacja Apple: <https://developer.apple.com/documentation/networkextension/dns-proxy-provider>

## VPN

Sekcja `VPN` głównego okna pokazuje stan, czas połączenia, operatora, tryb trasowania i automatyczne łączenie. Pełny konfigurator w `Ustawienia → VPN` tworzy systemowy profil Personal VPN przy użyciu wbudowanego w macOS protokołu IKEv2. Użytkownik podaje adres serwera, nazwę użytkownika i hasło. Hasło jest przechowywane jako element Pęku kluczy, a konfiguracja `NEVPNManager` otrzymuje wyłącznie trwałe odwołanie do tego elementu.

Dostępne funkcje VPN:

- zapis, połączenie, rozłączenie i bezpieczne usunięcie profilu,
- pełny tunel z wymuszeniem tras albo standardowe trasowanie serwera,
- opcjonalny dostęp do drukarek, NAS i innych urządzeń sieci lokalnej,
- automatyczne łączenie na każdej sieci albo wyłącznie poza wskazanymi zaufanymi sieciami Wi‑Fi,
- MOBIKE, Perfect Forward Secrecy, częsta kontrola dostępności serwera i weryfikacja unieważnienia certyfikatu,
- blokada przekierowania IKEv2 na inny serwer,
- profile kryptograficzne: systemowy zgodny, AES-256-GCM/SHA-384/DH20 oraz AES-256-GCM/SHA-512/DH21,
- odczyt systemowej przyczyny ostatniego rozłączenia i komunikaty dla błędów DNS, uwierzytelnienia, certyfikatu oraz negocjacji,
- hasło dostępne po pierwszym odblokowaniu urządzenia i nigdy zapisywane w ustawieniach aplikacji.

Dostępne presety:

| Operator | Automatyczna konfiguracja | Dane wymagane od użytkownika |
|---|---|---|
| Surfshark | Remote ID zgodne z hostname serwera | hostname lokalizacji oraz osobne dane `Manual setup → IKEv2` z konta Surfshark |
| hide.me | Remote ID `hide.me` | adres serwera z Members Area oraz dane konta |
| Własny IKEv2 | pełna konfiguracja ręczna | serwer, Remote ID, login i hasło administratora |

Adresy lokalizacji nie są zapisane na stałe w aplikacji, ponieważ operatorzy mogą je zmieniać. Przyciski w aplikacji otwierają aktualne instrukcje operatorów: [Surfshark IKEv2 dla macOS](https://support.surfshark.com/hc/en-us/articles/360006636013-How-to-set-up-IKEv2-manual-connection-on-macOS) oraz [hide.me IKEv2 dla macOS](https://hide.me/en/help/setup-macos-ikev2/). Surfshark może także wymagać zainstalowania certyfikatu CA zgodnie ze swoją instrukcją.

MacAdBlock nie dostarcza infrastruktury VPN ani danych konta. Do połączenia jest wymagany własny lub komercyjny serwer IKEv2 obsługujący uwierzytelnianie EAP nazwą użytkownika i hasłem. Profile „Nowoczesny” i „Wzmocniony” są przeznaczone głównie dla własnych serwerów; operator komercyjny może wymagać profilu „Zgodny”. Główna aplikacja musi mieć capability `Personal VPN`, które dodaje entitlement `com.apple.developer.networking.vpn.api` z wartością `allow-vpn`; zapis profilu zawsze podlega zatwierdzeniu przez macOS.

Dokumentacja Apple: <https://developer.apple.com/documentation/networkextension/nevpnmanager> oraz <https://developer.apple.com/documentation/networkextension/nevpnprotocolikev2>.

## Budowanie i testy

W Xcode wybierz schemat `MacAdBlock` i `My Mac`, następnie Build. `DNSProxy` buduj oddzielnie dopiero po dodaniu capability.

Sprawdzenie bez podpisu z terminala:

```sh
xcodebuild -project MacAdBlock.xcodeproj \
  -scheme MacAdBlock \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build
```

Testy rdzenia:

```sh
swift test
```

## Stan weryfikacji

- projekt jest poprawnie odczytywany przez Xcode,
- schemat `MacAdBlock` buduje aplikację, oba rozszerzenia Safari i helper bez podpisu,
- target `DNSProxy` buduje się oddzielnie bez podpisu,
- wszystkie testy Swift parserów, deduplikacji, kompilatora i sekcji hosts przechodzą,
- pliki plist i entitlement zostały sprawdzone narzędziem `plutil`.

Środowisko lokalne ma Xcode 26.6, podczas gdy Xcode 27 jest obecnie wersją beta. Projekt nie używa API dostępnego wyłącznie w SDK 27, więc można go zweryfikować na SDK 26.5 i otworzyć bez migracji w Xcode 27. Po instalacji Xcode 27 wybierz je w `Xcode → Settings → Locations → Command Line Tools` albo ustaw `DEVELOPER_DIR` tylko dla polecenia build.

## Nowości w buildzie 28

- **Szyfrowany DNS (DoH)** w Ustawienia → DNS: Cloudflare, Quad9 lub AdGuard przez `NEDNSSettingsManager`. Wymaga podpisanej aplikacji z uprawnieniem Network Extensions (DNS Settings), dlatego wpis jest tylko w `MacAdBlock.entitlements` (wydanie), a nie w wersji debug.
- **Dziennik blokad DNS**: DNS proxy zapisuje ostatnie 150 zablokowanych domen do kontenera App Group, a okno „Diagnostyka i własne reguły” pokazuje je z przyciskiem „Zezwól”.
- **Interfejs po angielsku**: `Localization.swift` tłumaczy teksty aplikacji, gdy język systemu nie jest polski (wymuszenie: `defaults write com.italiano88.MacAdBlock appLanguage en`). Popup i picker w Safari tłumaczą się według `navigator.language`.
- **Ikona aplikacji** bez kafelka (`Scripts/generate-icons.py`) i `Scripts/bump-version.sh`, które podnosi numer buildu o 1 w całym projekcie.
