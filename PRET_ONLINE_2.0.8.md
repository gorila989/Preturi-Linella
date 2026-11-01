# Caută Preț 2.0.8 — pagina produsului în aplicație

Instalează Cauta-Pret-2.0.8-arm64.apk peste versiunea existentă, fără dezinstalare.
Caută sau scanează produsul, deschide detaliile și apasă VEZI PREȚUL PE LINELLA.
Pagina oficială se deschide într-o filă de browser integrată (Android Custom Tabs).
Dacă site-ul cere o verificare de securitate, utilizatorul o completează manual.
Închide fila cu X sau Înapoi pentru revenirea la produs.

Este necesar internet și un browser compatibil instalat, de exemplu Chrome actualizat.
Nu se modifică identitatea browserului, nu se rezolvă automat verificări, nu se transferă cookie-uri către server.
Prețul paginii nu este copiat automat în SQLite. Prețul salvat offline este etichetat separat.
Produsele importate fără URL Linella afișează că nu au pagină asociată; nu se ghicește URL-ul după SKU.
Linkurile inițiale acceptate sunt HTTPS linella.md/www.linella.md, fără credențiale sau porturi neobișnuite.

Validare: Flutter analyze fără probleme, 7 teste trecute (URL, deschidere numai la apăsare, lipsă browser, produs fără URL, navigare și scanare offline).
Nu este conectat un telefon/emulator. Funcționarea verificării Cloudflare pe Samsung trebuie verificată de utilizator; integrarea nu garantează acceptarea de către site.

Documentație:
- https://pub.dev/packages/url_launcher
- https://developers.cloudflare.com/cloudflare-challenges/reference/supported-browsers/
