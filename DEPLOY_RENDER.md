# Publicare Caută Preț 2.0

Flutter rămâne în rădăcina repository-ului; backendul este în `server/`.
Nu încărca folderul părinte `outputs`, mediul Python, PostgreSQL local sau APK-urile în repository.

## Repository-ul GitHub existent

Repository verificat: https://github.com/gorila989/Preturi-Linella — public, ramura `main`, fără commituri la verificare. Codul nu a fost încă publicat.

Pagina serviciului existent: https://dashboard.render.com/web/srv-d8i7ggkm0tmc73cd64ug . Aceasta cere autentificare și nu este adresa publică de introdus în aplicație.

Clonare:

```sh
git clone https://github.com/gorila989/Preturi-Linella.git
cd Preturi-Linella
```


1. Descarcă/clonază repository-ul tău într-un folder separat.
2. Copiază în el conținutul proiectului `cauta_pret`, inclusiv `server`, `lib`, `test`, `android`, `pubspec.yaml`, `pubspec.lock`, documentația și `.gitignore`. Păstrează folderul `.git` al repository-ului clonat.
3. Verifică modificările înainte de publicare. Nu înlocui un proiect diferit din repository.
4. Din folderul clonat:

```sh
git status
git add .
git diff --cached --stat
git commit -m "Add PostgreSQL catalog API and offline Flutter sync"
git push
```

Nu adăuga `.env`, parole, conexiuni PostgreSQL reale, chei de semnare, `build/`, `.dart_tool/` sau datele unei baze locale. `.gitignore` exclude acestea. Fixture-urile reale HTML/XLSX sunt incluse pentru teste; alege vizibilitatea repository-ului potrivită datelor tale.

## Serviciul Render existent

Folosește serviciul existent, fără să creezi un al doilea serviciu cu același scop.

1. Deschide Render → serviciul tău → Settings. Verifică repository-ul și ramura conectată.
2. Backendul trebuie să fie un **Web Service Python**. Dacă serviciul existent este Static Site, creează un Web Service Python pentru API.
3. Creează sau selectează o bază **Render PostgreSQL**, în aceeași regiune. Păstrează datele existente; nu șterge o bază utilizată de altă aplicație.
4. Configurează:

| Setare | Valoare |
|---|---|
| Root Directory | `server` |
| Build Command | `pip install -r requirements.lock` |
| Pre-Deploy Command | `alembic upgrade head` |
| Start Command | `uvicorn app.api:app --host 0.0.0.0 --port $PORT` |
| Health Check Path | `/api/v1/health` |

Dacă planul nu oferă Pre-Deploy Command, folosește Start Command:

```sh
alembic upgrade head && uvicorn app.api:app --host 0.0.0.0 --port $PORT
```

Nu folosi mai multe instanțe care migrează simultan în varianta aceasta.

5. În Environment:

| Variabilă | Valoare |
|---|---|
| `DATABASE_URL` | Internal Database URL al bazei PostgreSQL; doar în Render, niciodată în Flutter |
| `SYNC_CURSOR_SECRET` | șir aleator stabil, minimum 32 caractere |
| `PYTHON_VERSION` | `3.12.10` |

Poți genera secretul local cu `python -c "import secrets; print(secrets.token_urlsafe(48))"`. Păstrează aceeași valoare între deploy-uri. Rotirea lui invalidează cursoarele aflate în curs, dar o nouă sincronizare funcționează.

6. Publică noul cod cu Manual Deploy → Deploy latest commit, dacă deploy-ul automat nu a pornit.
7. Deschide `https://ADRESA-TA.onrender.com/api/v1/health`. Rezultatul așteptat este `status: ok`, `database: postgresql`. Un catalog încă gol poate avea `serverVersion: 0`.
8. Documentația API este la `/docs`. Nu există endpoint public de administrare/scraping/import.

## Job Linella separat

Creează un **Cron Job** din același repository și aceeași ramură:

| Setare | Valoare |
|---|---|
| Root Directory | `server` |
| Build Command | `pip install -r requirements.lock` |
| Command | `python -m app.cli sync-linella` |
| Schedule | `0 3 * * *` (03:00 UTC zilnic) |
| `DATABASE_URL` | aceeași conexiune internă PostgreSQL ca API |
| `PYTHON_VERSION` | `3.12.10` |
| `SCRAPER_CONCURRENCY` | `4` (limită globală; maximum 4) |
| `SCRAPER_INTERVAL_SECONDS` | `0.5` (minimum 0.25) |
| `SCRAPER_USER_AGENT` | opțional, identificarea clientului |

După ce migrarea serviciului API a reușit, apasă **Trigger Run** pentru primul catalog. Verifică `SyncRun ... complete`, numărul paginilor și `errors: 0`. Dacă apare `partial`, paginile salvate rămân disponibile, dar trebuie verificată eroarea din log înainte de a considera catalogul complet.

Cron nu așteaptă un telefon conectat. Telefonul nu pornește acest job și nu așteaptă scraping-ul. Joburile concurente sunt împiedicate și prin advisory lock PostgreSQL. Un request eșuat primește maximum 3 încercări cu backoff, timeout 30 sec și interval global între cereri. Un răspuns HTML peste 8 MiB este refuzat.

`render.yaml` este o alternativă pentru instalări NOI, cu Web Service, PostgreSQL și Cron. Nu aplica automat Blueprint-ul peste alte resurse; adaptează numele și verifică planurile/costurile afișate de Render înainte de creare. Nu s-au creat resurse externe din acest proiect.

## UNARETAIL central

Dintr-un shell administrativ cu acces la PostgreSQL și fișierul XLSX:

```sh
cd server
python -m app.cli import-unaretail /cale/unaretail.xlsx
```

Comanda citește `Cod de bare` → barcode și `Cod produs` → SKU. Nu transformă SKU în ID Linella. Asociază numai identificatori identici; rândurile fără legătură sigură rămân în `pending_identifiers` și ajung în ecranul de neasociate de pe telefon.

După verificare umană, un administrator poate lega explicit un rând de un produs:

```sh
python -m app.cli associate-identifier ID_RAND_IMPORT linella:ID_PRODUS
```

Comanda refuză conflictele cu alte produse. Nu are opțiune de potrivire aproximativă după nume. Importul local XLSX/CSV existent rămâne disponibil ca fallback.

## Telefon

1. Instalează `Cauta-Pret-2.0.1-arm64.apk`.
2. Deschide Mai multe → Actualizare date → Server catalog.
3. Adresa `https://cauta-pret-linella.onrender.com` este deja inclusă în APK-ul 2.0.1. Verific-o în Server catalog; nu adăuga `/api/v1`.
4. După primul job Linella reușit, apasă ACTUALIZARE INIȚIALĂ COMPLETĂ.
5. Ulterior folosește ACTUALIZARE RAPIDĂ. ACTUALIZARE TOTALĂ recitește snapshot-ul API.

Scannerul, căutarea, categoriile, prețurile și promoțiile folosesc SQLite și funcționează fără server după prima sincronizare. O eroare de rețea lasă datele locale disponibile. Anularea închide cererea HTTP; sincronizarea următoare repetă în siguranță paginile neconfirmate.

Miniaturile sunt de maximum 225×225 și 96 KiB fiecare; plafonul folderului este 512 MiB. La plafon, produsele/prețurile continuă să se actualizeze, dar miniaturile care nu încap rămân nesalvate. Imaginile mari se cer numai la apăsare, într-un cache separat de 100 MiB. Nu intră în backup și pot fi șterse din Setări → Stocare.

Backupurile vechi cu schema 1 sau 2 sunt migrate pe o copie temporară. Exportul/restaurarea ZIP pe telefon au limită de 48 MiB pentru a preveni alocări mari în memorie; un backup vechi foarte mare, cu imagini, trebuie pregătit fără imagini pe calculator. Fișierele originale nu sunt modificate. Pentru prima instalare nouă, preferă bootstrap din server și importul identificatorilor, fără a readuce imaginile mari vechi.

## Surse pentru configurarea Render

[Blueprint YAML Reference](https://render.com/docs/blueprint-spec) și [Cron Jobs](https://render.com/docs/cronjobs), consultate la implementare. Programarea Cron folosește UTC, iar Cron nu oferă disc persistent; de aceea imaginile sunt URL-uri Linella, iar catalogul este în PostgreSQL.
