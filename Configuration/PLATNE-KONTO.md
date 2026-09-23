# Uprawnienia dostępne tylko na płatnym koncie Apple Developer

Darmowy Personal Team nie podpisze tych uprawnień, dlatego usunięto je z plików `.entitlements`.
Po przejściu na płatne konto dopisz je z powrotem:

`MacAdBlock.entitlements` (aplikacja):

    <key>com.apple.developer.networking.vpn.api</key><array><string>allow-vpn</string></array>
    <key>com.apple.developer.networking.networkextension</key><array><string>dns-settings</string></array>

`DNSProxy.entitlements` (rozszerzenie DNS proxy):

    <key>com.apple.developer.networking.networkextension</key><array><string>dns-proxy</string></array>

Bez nich w aplikacji nie działają: VPN, filtrowanie DNS (DNS Proxy) i szyfrowany DNS (DoH).
Rozszerzenia Safari, App Group i helper hosts działają z Personal Team.
