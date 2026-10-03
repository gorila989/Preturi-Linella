# Caută Preț 2.0.1 — catalog central și aplicație offline

Faza 2 server-side: [Search API hibrid, activare și validare](FAZA_2_SEARCH_API.md). Flag-ul este implicit OFF; HTML rămâne sursa de descoperire.

Adresa Render este preconfigurată. Vezi [CONEXIUNE_2.0.1.md](CONEXIUNE_2.0.1.md) pentru starea conectării.

Linella → job Python → PostgreSQL → FastAPI HTTPS → Flutter → SQLite + miniaturi.

Telefonul nu mai descarcă pagini HTML Linella. Quick = delta API; Full = snapshot API paginat. Parserul Dart vechi este păstrat pentru teste istorice și nu este instanțiat de AppState sau de serviciul Android.

## Structura

- `lib/`, `android/`: aplicația Flutter existentă, importul, scannerul și UI-ul păstrate.
- `server/app/`: FastAPI, modele PostgreSQL, parser DOM, job independent și import central.
- `server/migrations/`: migrații Alembic versionate, cu DDL înghețat.
- `server/tests/`: teste pe PostgreSQL real, inclusiv 50.000 de produse.
- `test/fixtures/`: copii ale HTML-ului și XLSX-ului furnizate, plus răspuns API generat de testul PostgreSQL.
- `test/api_sync_test.dart`: fluxul API → SQLite, reduceri, anulare, replay, imagini.
- `integration_test/app_test.dart`: verificarea pe Android a SQLite, promoțiilor, backupului și utilizării offline.
- `DEPLOY_RENDER.md`: pașii GitHub, Render și telefon.
- `RAPORT_HIBRID.md`: rezultate, limite și cele 24 de puncte cerute.

## API

GET `/api/v1/health`, `/api/v1/catalog/bootstrap`, `/api/v1/sync?since=…&generation=…`, `/api/v1/products`, `/api/v1/products/{id}`, `/api/v1/categories`, `/api/v1/promotions`, `/api/v1/special-collections`.

Lista produselor și listele de documente au `after` și `limit` (maximum 500). Bootstrap/delta au cursor semnat și limită 500; telefonul cere 250. OpenAPI: `/docs`. Compresia gzip este activă. Niciun endpoint public nu modifică datele.

## Contractul de sincronizare

Fiecare scriere ia `catalog_state FOR UPDATE`, modifică entitățile și publică evenimente `product_changes` în aceeași tranzacție. Contorul tranzacțional nu este o secvență care poate sări peste o tranzacție încă neconfirmată. Un import folosește aceeași cale.

Prima pagină îngheață `serverVersion` și generația bazei. Paginile următoare sunt limitate la acea versiune, chiar dacă jobul publică schimbări între timp. Bootstrap alege ultima imagine a fiecărei entități la acea versiune; delta livrează numai evenimentele ulterioare versiunii telefonului. Evenimentele sunt păstrate; nu există expirare ascunsă a cursorului sau ștergere automată a istoricului necesar unui telefon offline.

Telefonul aplică fiecare pagină într-o tranzacție. `apiVersion` se publică numai în tranzacția ultimei pagini. În caz de întrerupere se repetă de la ultima versiune completă; upsert-ul este idempotent. La bootstrap complet, produsele vechi gestionate de server și absente din snapshot devin inactive; importurile exclusiv locale sunt păstrate. Imaginile se descarcă separat, după date. URL-ul nou este sincronizat chiar dacă descărcarea miniaturii eșuează; următoarea actualizare reîncearcă imaginile lipsă.

## Teste locale

Este necesar PostgreSQL 17+ separat, numit `cauta_test`. Testele golesc EXCLUSIV această bază; nu folosi baza de producție. Exemplele de mai jos folosesc un container local, nu stocare SQLite pe server:

```sh
docker run --name cauta-test-postgres -e POSTGRES_USER=cauta_test -e POSTGRES_PASSWORD=local_test_only -e POSTGRES_DB=cauta_test -p 127.0.0.1:55432:5432 -d postgres:17
cd server
python -m venv .venv
# Linux/macOS: source .venv/bin/activate
# PowerShell: .venv/Scripts/Activate.ps1
pip install -r requirements.lock
```

Setează `DATABASE_URL=postgresql://cauta_test:local_test_only@127.0.0.1:55432/cauta_test` în mediul shell. Pentru API în afara testelor, setează și `SYNC_CURSOR_SECRET` (minimum 32 caractere aleatoare). `.env.example` este un exemplu, nu se încarcă automat.

```sh
alembic upgrade head
alembic check
python -m pytest -q
uvicorn app.api:app --host 127.0.0.1 --port 8000
```

Apoi, din rădăcina Flutter:

```sh
flutter pub get
dart format lib test integration_test
flutter analyze
flutter test
flutter test integration_test/app_test.dart -d ID_EMULATOR
flutter build apk --release --target-platform android-arm64
```

Testul Python generează `test/fixtures/api_bootstrap.json` din HTML → PostgreSQL → FastAPI; testul Flutter verifică apoi persistența celor 24 produse și 2 reduceri, folosind imagini PNG minuscule controlate pentru test. Nu conține produse fictive în aplicația livrată.

## Administrare

```sh
python -m app.cli sync-linella
python -m app.cli import-unaretail /cale/unaretail.xlsx
python -m app.cli associate-identifier ID_RAND linella:ID_PRODUS
```

Acestea sunt comenzi server cu acces administrativ la PostgreSQL, nu endpointuri HTTP accesibile telefoanelor. Configurarea producției și URL-ului în aplicație este descrisă în [DEPLOY_RENDER.md](DEPLOY_RENDER.md).
