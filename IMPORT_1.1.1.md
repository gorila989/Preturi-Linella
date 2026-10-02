# Import UNARETAIL — 1.1.1

Captura telefonului arată `FormatException: Invalid Zip Signature`. Ea confirmă că decodorul nu a recunoscut o arhivă XLSX validă în fișierul selectat. Nu arată fișierul ales, deci nu stabilește cauza exactă. Transferul USB nu demonstrează coruperea fișierului.

Originalul disponibil pe calculator este un XLSX valid de 30.364 bytes, cu SHA-256 `de08b46a1dba7ac30c8f215b3d309315e3af9cb717198f7fbd6ac7ff442af9af`. Copia `unaretail-verificat.xlsx` este identică. Originalul nu a fost modificat.

`unaretail-import.csv` este o variantă UTF-8 cu separator `;`, generată din cele două coloane originale. Toate cele 1.559 de perechi au fost comparate exact, ca text, cu sursa XLSX. Codurile și SKU-urile nu au fost convertite în numere. Copiază acest CSV în Download pe telefon, selectează-l în ecranul Importă produse / SKU și confirmă importul. CSV-ul poate fi folosit și în versiunea 1.1.0 instalată.

Modificările 1.1.1:

- mesaje distincte pentru fișier gol, conținut care nu este XLSX, fișier Excel vechi/criptat, ZIP deteriorat și arhivă care nu conține un registru Excel;
- verificarea integrității ZIP;
- numele și dimensiunea fișierului selectat sunt vizibile înainte de decodare;
- un import eșuat nu lasă previzualizarea fișierului anterior disponibilă pentru confirmare;
- curățarea copiei temporare are loc după decodare, inclusiv la eroare;
- schema SQLite rămâne 2, pachetul și configurația semnării rămân neschimbate.

Aceste schimbări îmbunătățesc verificarea fișierului și diagnosticul; nu repară automat un fișier deteriorat și nu stabilesc ce fișier a fost selectat pe telefon.

Validare: 45 de teste trecute și `flutter analyze` fără probleme. Logurile sunt în `cauta_pret/validation/1.1.1/`. Testul nou acoperă cele cinci tipuri de fișier invalid; testele pe XLSX-ul original continuă să treacă. Comportamentul acestei versiuni nu a fost verificat pe telefonul utilizatorului.

Build Android ARM64 release reușit. Certificatul APK corespunde versiunilor anterioare. APK: Cauta-Pret-1.1.1-arm64.apk; instalarea se face prin Actualizează, fără dezinstalare.

