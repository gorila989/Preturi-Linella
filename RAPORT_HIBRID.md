# Raport Caută Preț 2.0.0 — arhitectură hibridă

## 1. Arhitectura finală
Linella → job Python independent → PostgreSQL → FastAPI HTTPS → Flutter → SQLite local + miniaturi. Nici AppState, nici serviciul Android nu mai instanțiază scraperul. Pornirea aplicației nu pornește scraping.

## 2. Fișiere și directoare
Creat `server/app/` (api, db, models, catalog, parser, scraper, importer, cli), `server/migrations/`, `server/tests/`, `server/requirements.lock`, `.env.example`, `render.yaml`, `DEPLOY_RENDER.md`. Creat în Flutter `api_sync_service.dart`, `full_image_cache.dart`, `test/api_sync_test.dart`; adaptate AppState, background sync, schema locală, repository, UI de actualizare/promoții/stocare și backup. Flutter rămâne la rădăcină; nu a fost mutat inutil în mobile/.

## 3. Tehnologia backend
Python 3.12, FastAPI, SQLAlchemy 2, Alembic, psycopg, httpx, BeautifulSoup/lxml, openpyxl. Dependențele efectiv instalate sunt fixate în `server/requirements.lock`. Backendul refuză un DATABASE_URL SQLite.

## 4. PostgreSQL
Tabele: catalog_state, categories, products, promotions, product_promotions, special_collections, special_collection_products, sync_runs, product_changes, pending_identifiers. Identificatori sursă, SKU și barcode separați, cu unicitate și indexuri; parent_id referențiază arborele real. Migrare inițială versionată cu DDL înghețat; upgrade, downgrade și verificarea diferențelor față de modele au reușit pe PostgreSQL 17 real.

## 5. Endpointuri
GET `/api/v1/health`, `/catalog/bootstrap`, `/sync`, `/products`, `/products/{id}`, `/categories`, `/promotions`, `/special-collections`, toate listele sub prefixul `/api/v1`. OpenAPI la `/docs`. Gzip activ. Health verifică PostgreSQL și configurația secretului. Nu sunt expuse comenzi administrative HTTP.

## 6. Sincronizarea Linella
`python -m app.cli sync-linella` citește arborele DOM, paginile categoriilor și colecțiile. Maximum 4 cereri concurente, interval global implicit 0,5 sec, timeout 30 sec, retry/backoff. Advisory lock împiedică două joburi simultane. Upsert stabil, refuz al identificatorilor contradictorii, loguri per pagină și SyncRun. O categorie incompletă nu confirmă absențe; după trei parcurgeri complete cu absență produsul devine inactiv, fără ștergere.

## 7. Cereri în teste
Fixture real: 24 carduri analizate dintr-o pagină, fără acces la detalii. Test de paginare: exact 2 cereri pentru 2 pagini, reduceri pe ambele, 0 cereri de produs. Verificare live limitată: 1 cerere la Energizante, 24 produse, 3 reduceri la momentul citirii. Nu s-a rulat un crawl complet al întregului site și nu se pretinde verificarea fiecărui produs Linella.

## 8. Reduceri
Prețul cu `<sup>` este reconstruit corect (28.19). Se păstrează prețul vechi numai când există; procentul se poate calcula când oldPrice > price. `observed` înseamnă reducere văzută fără perioadă cunoscută; `dated` păstrează intervalul, evaluat local inclusiv după expirare; `none` elimină reducerea la o observație nouă fără promoție. Lipsa datei finale nu ascunde o reducere. Fixture-ul original are 2 reduceri, păstrate prin PostgreSQL → API → SQLite → filtrul categoriei părinte.

## 9. Paginare
Se urmăresc rel=next și data-ut2-load-more-url până la epuizare; visitedUrls și semnătura ID-urilor detectează bucle/repetarea paginii. Numărul de pagini nu este hardcodat. Membership-urile colecțiilor se înlocuiesc numai după parcurgerea completă.

## 10. Thumbnail-uri
Adapterul SourceThumbnailStorage selectează un URL de maximum 225×225 prezent efectiv în HTML. Păstrează separat thumbnailUrl/sourceImageUrl/fullImageUrl. Varianta actuală folosește direct miniaturile Linella; nu stochează imagini pe filesystem-ul efemer Render și nu face resize în server. Adapterul poate fi înlocuit cu object storage ulterior.

## 11. Prevenirea a circa 23 GB
Telefonul verifică dimensiunile imaginii, maximum 96 KiB per thumbnail, folder maximum 512 MiB. Fișierele sunt deduplicate după URL și reutilizate. Se șterg automat numai fișierele gestionate care nu mai sunt referențiate. Imaginile mari se cer doar la apăsare, maximum 8 MiB/răspuns, cache separat 100 MiB. Ecranul Stocare separă SQLite, miniaturi, cache mare, temporare și backupuri. La plafonul miniaturilor nu se șterg cele active; noile imagini pot rămâne nesalvate, dar datele produselor se actualizează.

## 12. Bootstrap
Snapshot versionat, paginat, cu categorii înaintea produselor și documentelor. Ultima versiune a fiecărei entități este selectată la watermark-ul primei pagini, astfel încât schimbările simultane nu alterează snapshot-ul. Test PostgreSQL: 50.000 produse, 100 pagini de 500, 12875 ms pe acest calculator, maximum 74074 octeți JSON decomprimat/pagină în setul sintetic. Telefonul cere 250 elemente/pagină.

## 13. Delta
Contor generat de server, blocat tranzacțional; cursor HMAC și generation ID. Schimbările categorii/produs/preț/inactivitate/promoții/colecții/identificatori/URL imagini sunt evenimente în aceeași tranzacție cu datele. Test A20+B30 → A18+Cnew returnează numai A și C. Delta fără schimbări în testul de 50.000 produse: 113 octeți. Test separat pentru două scrieri concurente și rollback, fără publicare parțială.

## 14. SQLite
Schema 3 păstrează tabelele, codurile, aliasurile, importurile locale și referințele anterioare. Adaugă starea/perioada reducerii, fullImageUrl, serverVersion, bootstrapMark și auditul identificatorilor centrali. Indexurile sursă/SKU/barcode/categorie/timp rămân; index FTS5 sau FTS4 disponibil pe platformă, cu căutare parțială literală păstrată. Fiecare pagină se aplică atomic, versiunea finală numai după ultima pagină. Replay-ul după eșec este sigur.

## 15. Offline
Numele, codurile, scannerul, prețurile, promoțiile, arborele și miniaturile sunt locale. Testul închide/redeschide SQLite și verifică datele fără backend; test Android verifică produsul promoțional în UI și codul de bare local. Camera/scannerele existente EAN13/EAN8/UPCA/Code128 sunt păstrate; nu s-a făcut un test nou cu o cameră fizică. Countdown-ul Mega folosește ceasul local. Anularea întrerupe inclusiv o cerere HTTP blocată; watchdog-ul serviciului oprește un serviciu fără progres raportat peste 60 sec.

## 16. UNARETAIL
Fișierul real are 1.559 rânduri. În baza de test fără produse asociabile: 1.384 pending, 175 conflicte, 0 asocieri inventate. Reimport: 1.559 duplicate, fără multiplicare. Codurile sunt text; zerourile sunt păstrate. Import central prin CLI, asociere administrativă explicită cu verificarea conflictelor și propagare delta; importul local XLSX/CSV rămâne. Un barcode necunoscut nu poate găsi un produs până când există o asociere verificată.

## 17. Teste backend
17 teste trecute pe PostgreSQL 17 local: HTML real, categorii/niveluri, prețuri/procente, promoții, paginare, bucle, absențe repetate, upsert repetat, snapshot stabil, tampering cursor, rollback, scrieri concurente, API read-only, import real/numeric/text/zerouri, asociere centrală și 50.000 produse. Log: `validation/hybrid-backend-tests.log`. `alembic check`: fără operații noi. `render.yaml` validat cu schema JSON oficială Render. Producția Render nu a fost modificată.

## 18. Flutter analyze
`No issues found`. Formatter rulat pe lib/test/integration_test. Log: `validation/hybrid-analyze.log`.

## 19. Flutter test
52 teste trecute, inclusiv testele istorice și cele noi pentru API, offline, imagini, limite, replay, anulare, promoții și bootstrap repetat. Două teste de integrare Android au trecut pe emulator API 36. La 50.000 produse sintetice pe Windows: 100 lookup-uri barcode 117 ms, căutare parțială 22 ms, paginare adâncă 92 ms. Acestea nu sunt timpi măsurați pe telefonul utilizatorului.

## 20. APK
`flutter build apk --release --target-platform android-arm64` reușit. APK 2.0.0, versionCode 4, package md.cautapret.cauta_pret, 37.029.940 octeți. Semnătură verificată; păstrează cheia locală de test folosită anterior, nu o cheie de publicare Play Store. Build-ul emite avertismentul existent de compatibilitate viitoare Kotlin pentru file_picker, fără eroare de compilare.

## 21. GitHub
Repository verificat: https://github.com/gorila989/Preturi-Linella — public și gol la verificare. Codul și instrucțiunile de commit/push sunt pregătite în `DEPLOY_RENDER.md`. Nu s-a făcut push și nu s-au publicat fișiere în repository din această sesiune.

## 22. Render
Serviciu furnizat: https://dashboard.render.com/web/srv-d8i7ggkm0tmc73cd64ug . Dashboardul cere autentificare în browserul disponibil. Ghidul conține Root Directory, Build/Pre-deploy/Start, PostgreSQL, Health Check, job zilnic și primul Trigger Run. Blueprint opțional pentru o instalare nouă; adaptarea serviciului existent evită crearea inutilă a unor resurse suplimentare. Adresa publică HTTPS a API-ului se introduce în ecranul Actualizare date → Server catalog.

## 23. Environment variables
API: DATABASE_URL PostgreSQL, SYNC_CURSOR_SECRET minimum 32 caractere aleatoare, PYTHON_VERSION. Job: același DATABASE_URL, SCRAPER_CONCURRENCY=4, SCRAPER_INTERVAL_SECONDS=0.5, SCRAPER_USER_AGENT opțional. PORT este furnizat de Render. Flutter poate primi API_BASE_URL la compilare sau adresa poate fi salvată din UI. Nu sunt incluse credențiale reale în surse/APK.

## 24. Limite și ce rămâne pentru publicare
- Publicarea în GitHub/Render și primul job complet de producție nu au fost executate; configurația reală a serviciului nu este accesibilă fără autentificarea utilizatorului.
- APK-ul poate fi instalat acum, dar are nevoie de backendul nou publicat și de URL-ul său HTTPS pentru prima descărcare.
- Nu s-a verificat individual promoția Coca-Cola 1,25 l de pe site; s-a reparat filtrarea generală și s-a testat fluxul reducerilor reale din Energizante.
- Imaginile sunt dependente de URL-urile publice Linella; pot lipsi când sursa le retrage, refuză cererea ori depășesc limita. Nu se inventează imagini/produse.
- Backup ZIP pe telefon este limitat la 48 MiB comprimat/decomprimat pentru a preveni OUT OF MEMORY. Fișierele vechi schema 1/2 sunt suportate, dar un backup foarte mare cu imagini trebuie pregătit fără imagini pe calculator. Restaurarea validează o copie temporară și reconstruiește indexul de căutare; originalul rămâne neatins.
- Indexul local FTS4 Android necesită verificare pe copia temporară scriibilă; acest caz a fost depistat și rezolvat în testul Android. Migrarea v1 → v3 păstrează coloanele și relațiile inițiale.
- Cron complet, disponibilitatea Render și comportamentul Android cu ecranul blocat pe telefonul fizic trebuie urmărite la prima utilizare reală. Testele automate nu înlocuiesc acea verificare.

## Integritatea fișierelor furnizate
Fișierele originale nu au fost modificate. Copiile din fixture au aceleași hashuri SHA-256:

- html_link.txt / energizante.html: `4f35bae72f75fd66120508dbb0a7ce924281b1c0ed9cb7de02306ca39ea146aa`
- unaretail.xlsx: `de08b46a1dba7ac30c8f215b3d309315e3af9cb717198f7fbd6ac7ff442af9af`
