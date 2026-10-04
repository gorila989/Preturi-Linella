# Caută Preț 2.0.3 — Linella SKU → Excel barcode → scanner offline

Implementare incrementală pe aplicația existentă. Checkpoint înainte de această etapă: `92b9c0c` (versiunea 2.0.2 completă). Checkpoint anterior primei schimbări SKU: `5060f4cda86c5b11ead8d6bb9c0ab0bbf8831cdb`.

Nu s-au accesat sau modificat baza Neon ori datele telefonului. Nu există migrare: schemele PostgreSQL și SQLite, produsele, ID-urile, prețurile, imaginile și categoriile existente se păstrează. Importurile și testele rulează pe baze locale izolate. Fișierele originale HTML și Excel sunt nemodificate.

## Fluxul final

1. GitHub Actions **Import Linella**, mod `full`, extrage produsele și SKU-ul public din detaliile produselor care nu au deja SKU. Funcționează și cu Search API debifat. Actualizarea selectivă Search API completează SKU pentru produsele existente selectate.
2. `sourceProductId` rămâne ID-ul intern Linella; `sku` este citit din elementul exact `product_code_<sourceProductId> .ut2--sku-text`, după verificarea identității paginii. Nu se presupune egalitatea lor și nu se extrage barcode în acest pas.
3. SKU-ul este publicat prin mecanismul API existent și primit în SQLite. Pentru prima completare extinsă se recomandă actualizare totală pe telefon după încheierea importului serverului.
4. Importul XLSX/CSV din aplicație folosește numai `Product.sku == Excel.Cod produs`. Se atașează doar codul de bare. Numele, prețurile și alte câmpuri eventual prezente în Excel nu suprascriu produsul în acest flux.
5. Zero produse Linella găsite: rând separat neasociat. Un rând local vechi fără sourceProductId nu este considerat automat produs Linella; se păstrează până când sincronizarea îi confirmă identitatea. Un produs și barcode identic: deja asociat. Mai multe produse, cod existent diferit sau barcode aparținând altui produs: conflict, fără suprascriere.
6. Rândurile neasociate sunt reverificate după sincronizare, inclusiv când API-ul nu trimite produse modificate. Nu este necesar un nou import Excel.
7. Scannerul caută local codul, inclusiv aliasurile existente. Un rezultat deschide detaliile produsului; mai multe rezultate dau conflict, nu primul produs arbitrar. Ecranul păstrează imaginea, prețul și promoția și arată SKU, barcode și categoria disponibilă.

Statusurile interne existente `pending` și `needsReview` sunt păstrate pentru compatibilitate; corespund UNMATCHED și CONFLICT. Raportul afișat arată citite, valide, asociate după SKU, deja asociate, neasociate, conflicte, invalide și erori. Reimportarea rândurilor neasociate nu le raportează fals ca deja asociate.

Importul normal `import` este strict implicit. Funcția generală veche de transfer produse rămâne explicit disponibilă intern ca `importProducts`, pentru compatibilitatea exporturilor/transferurilor și testelor existente; ecranul de import UNARETAIL folosește numai importul strict. Aserțiunile testelor vechi de transfer au fost păstrate, apelurile lor indicând acum explicit acest mod vechi.

Identificatorii sunt texte; `279905.0` devine `279905`, iar zerourile inițiale sunt păstrate. Valorile numerice Excel sunt validate înainte de conversie; valori fracționare, formule sau precizie nesigură nu sunt ghicite.

## Verificarea celor patru exemple reale

Verificate pe paginile publice Linella la 2026-10-04 și comparate cu fișierul original UNARETAIL:

| SKU | ID intern Linella | Produs | Barcode cerut | Rezultat în Excel complet |
|---|---|---|---|---|
| 279905 | 29770 | Apa minerala 1.25l BORJOMI | 4860019002077 | Asociere exactă |
| 153029 | 29712 | Apa minerala carbo 0.75l st. BORSEC | 5942219111182 | Asociere exactă |
| 442891 | 47296 | Seminte de de floarea soarelui pestrite 90g BANZAI | 4840811002031 | Asociere exactă |
| 2003985 | 51042 | RADACINI VERO DI MOSCATO Vin roze dulce 0.75l | 4840267009547 | Conflict: două barcode-uri pentru același SKU |

Excel-ul real conține pentru SKU `2003985` atât `4840267009547`, cât și `4840472014350`. Nu se alege automat unul și nu se schimbă Excel-ul original. Cele patru perechi sunt testate și separat: într-un set fără ambiguitate fiecare se asociază corect. Importul complet păstrează conflictul pentru a patra pereche.

Fragmentele HTML reale sunt în `server/tests/fixtures/sku-detail-*.html`; valorile publice verificate și relațiile Excel sunt în `test/fixtures/sku-verified-products.json` și `validation/strict-sku-live.json`. Testele bazei folosesc aceste produse verificate; nu se pretinde că baza de producție a fost deja completată.

## Instalare și publicare

1. Instalează `Cauta-Pret-2.0.3-arm64.apk` peste aplicația existentă, fără dezinstalare. Package-ul și certificatul sunt aceleași; codul de versiune crește la 7.
2. Extrage arhiva cumulativă `Cauta-Pret-2.0.3-SKU-actualizare.zip` și încarcă fișierele în `gorila989/Preturi-Linella`, păstrând directoarele. Include explicit `.github/workflows/sync-linella.yml`; arhiva include și implementarea 2.0.2, dacă nu ai încărcat-o încă.
3. Așteaptă actualizarea serviciului Render **preturi-linella**, apoi pornește GitHub Actions **Import Linella → Run workflow → mode full**. Extragerea SKU nu necesită bifarea Search API. Nu folosi repository-ul sau serviciul vechii aplicații `cauta-pret-linella`.
4. Prima rulare poate dura ore pentru un catalog mare: se cer numai detaliile produselor fără SKU, cu limitele HTTP existente. Workflow-ul permite 360 minute. Datele se salvează pe pagini; dacă rularea este întreruptă, repetarea păstrează SKU-urile salvate și continuă completarea celor lipsă. Pentru loturi manuale controlate rămâne disponibil **Completeaza SKU Linella**.
5. Verifică în jurnal `skusExtracted`, `skuUnavailable`, `skuErrors`, `skuConflicts`. SKU absent, pagini restricționate sau erori nu produc valori inventate. Erorile de extragere SKU fac rularea incompletă; datele anterioare rămân păstrate.
6. Pe telefon: server `https://preturi-linella.onrender.com` → actualizare totală pentru preluarea inițială → import Excel, dacă încă nu este importat. După aceea, actualizarea rapidă este suficientă.
7. Scanează cele trei barcode-uri unice pentru verificare. SKU `2003985` necesită verificarea manuală a celor două rânduri conflictuale din Excel.

Fișierele au fost pregătite local. Nu s-a făcut push, deploy sau import pe baza de producție.

## Schimbări și validare

Backend: `scraper.py`, `data_source.py`, `importer.py`, `identifier_matching.py`, `cli.py`; extragerea SKU folosește modulul verificat `sku_enrichment.py`. Nu se ține o tranzacție de scriere deschisă în timpul cererilor HTTP pentru SKU.

Flutter: `catalog_repository.dart`, `models.dart`, `api_sync_service.dart`, `transfer_service.dart`, `transfer_pages.dart`, `product_pages.dart`; versiune nouă în `pubspec.yaml`. În workflow-ul existent s-a extins doar timpul disponibil primei completări.

Teste noi: sincronizare fără Excel → SKU → API, Search API cu SKU lipsă, patru perechi reale, import complet cu conflict, reimport, necunoscut cu nume fără creare de produs, barcode-only refuzat, SKU duplicat, cod existent diferit, re-asociere fără modificări API și deschiderea detaliilor offline. Regresiile existente de prețuri/promoții/categorii/imagini/backup/sincronizare rămân incluse.

Rezultatele finale sunt salvate în `validation/strict-sku-*.txt`; verificarea schemei: `No new upgrade operations detected`.

Rezultat final: 90 teste backend, 70 teste Flutter și 3 teste Android. Analiză statică fără probleme. APK release arm64 2.0.3 compilat cu același certificat ca versiunea existentă.
