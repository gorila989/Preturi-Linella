# SKU Linella + coduri de bare Excel — actualizare aditivă 2.0.2

## Siguranță și implementare

Checkpoint Git înainte de editări: `5060f4cda86c5b11ead8d6bb9c0ab0bbf8831cdb` în acest proiect local. Nu exista un repository Git în sursa de lucru; a fost creat unul pentru checkpoint. Nu s-a făcut push sau deploy.

Schema PostgreSQL și SQLite rămâne aceeași: fără migrare, recreare, golire ori ștergere de produse. Baza Neon și telefonul utilizatorului nu au fost accesate. Testele folosesc exclusiv PostgreSQL local `cauta_test` și baze SQLite temporare; curățarea din testele existente este limitată la aceste baze de test.

Flux: detaliu public Linella → SKU verificat → produs existent → SKU exact din Excel → barcode → scanner existent. Nu se confundă sourceProductId cu SKU. Exemplul real verificat: Burn, sourceProductId `30334`, SKU `3579`. Fragmentul DOM real este salvat fără scripturi sau cookie-uri în `server/tests/fixtures/sku-detail-30334.html`.

Extragerea folosește numai `#product_code_<sourceProductId> .ut2--sku-text`, cu verificarea inputului `product_data[<sourceProductId>][product_id]`. Alte produse din recomandări nu sunt acceptate. SKU rămâne text, inclusiv zerourile inițiale. Nu se ocolesc paginile de verificare a vârstei. Search API nu este presupus a furniza SKU.

Completarea rulează separat, în loturi de maximum 1000, numai pentru produse existente cu SKU NULL. Nu schimbă prețurile, promoțiile, categoriile, imaginile, numele sau identificatorii. Folosește limita HTTP existentă și aceeași blocare PostgreSQL ca sincronizarea normală. Produsele fără SKU public rămân nemodificate; conflictele și erorile sunt raportate.

Asocierea importurilor în așteptare funcționează atât în backend, cât și pe telefon la primirea SKU-ului prin sincronizare. Se acceptă numai egalitatea exactă SKU, fără potrivire după nume sau conversie numerică. Ambiguitățile, barcode-urile aparținând altui produs și SKU/barcode existente diferite sunt păstrate pentru verificare. Importul Excel și asocierea manuală existente rămân disponibile. Nu se creează produse noi din completarea SKU.

## Fișiere

Existente modificate: `server/app/catalog.py` (reconciliere și protecție identitate), `server/app/importer.py` (conflicte între importuri, reconciliere la repetare, asociere manuală fără evenimente duplicate), `server/app/cli.py` (comandă nouă), `lib/data/catalog_repository.dart` (asociere SKU în așteptare și protecția codurilor la actualizare online), `pubspec.yaml` (2.0.2+6), `test/api_sync_test.dart` (regresie nouă).

Fișiere noi: `server/app/sku_enrichment.py`, `server/app/identifier_matching.py`, `.github/workflows/enrich-skus.yml`, testele și fixture-ul SKU. Parserul de prețuri, Search API, importul zilnic, structura bazei și ecranul scannerului nu au fost restructurate.

## Pași de utilizare

1. Instalează APK-ul 2.0.2 peste aplicația existentă, fără dezinstalare. Păstrează aceeași cheie și același package Android.
2. Încarcă fișierele din arhiva de actualizare în repository-ul `gorila989/Preturi-Linella`, păstrând directoarele. Încarcă explicit `.github/workflows/enrich-skus.yml` în folderul `.github/workflows` dacă browserul omite folderul ascuns.
3. În GitHub Actions, deschide **Completeaza SKU Linella → Run workflow**. Pentru primul test: `limit=100`, `after` gol.
4. La final, jurnalul arată `checked`, `added`, `unavailable`, `conflicts`, `errors` și `after`. `added` numără SKU completate pe produse existente, nu produse noi. Pentru lotul următor copiază valoarea `after` în câmpul cu același nume. Poți folosi ulterior `limit=1000`. Continuă până la `checked=0`.
5. Loturile deja salvate rămân salvate în caz de eroare. Conflictele nu suprascriu nimic. Pentru reîncercarea paginilor temporar indisponibile, după verificarea jurnalului pornește din nou cu `after` gol; produsele care au deja SKU sunt omise automat.
6. Pe telefon, verifică serverul `https://preturi-linella.onrender.com`, apoi apasă **Actualizare rapidă**. Importurile Excel deja în așteptare se asociază atunci când SKU-ul exact ajunge pe telefon. Dacă nu ai importat încă Excel-ul, importă `unaretail.xlsx` prin funcția existentă, după sincronizare.
7. Scanează un barcode dintr-un rând asociat. Scannerul deschide produsul existent, cu același ID, preț, promoție și imagine.

Acest workflow este manual și nu pornește automat zeci de mii de cereri. Importul zilnic existent rămâne neschimbat. Nu toate produsele pot fi asociate: sunt necesare SKU public verificabil și un rând Excel neambiguu cu același SKU.

## Verificări

- 82 teste backend trecute, inclusiv fișierul real unaretail.xlsx (1559 rânduri), ambele ordini ale importului, conflicte, eșec HTTP, repetare idempotentă și păstrarea ID-urilor.
- 58 teste Flutter trecute, inclusiv import real Excel, sincronizare API → SKU → barcode → căutarea scannerului, regresii și testul de 50.000 produse.
- Flutter analyze: fără probleme.
- Alembic check: No new upgrade operations detected.
- 2 teste Android existente trecute pe emulator (SQLite, import, backup, API, promoții, căutare offline).
- APK release arm64 compilat; rezultatele sunt în fișierele `validation/sku-*`.
