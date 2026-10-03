# Faza 2 — integrarea hibridă Linella Search API

Implementare locală verificată la 3 octombrie 2026. Nu a fost încă publicată în GitHub/Render. Nu necesită reinstalarea aplicației Android.

## Cum o publici și o folosești

1. Încarcă fișierele din pachetul de actualizare în repository, păstrând căile `server/app/`, `server/tests/`, `server/tools/` și `.github/workflows/`. Nu încărca ZIP-ul ca un singur fișier și nu modifica secretul DATABASE_URL.
2. Păstrează inițial flag-ul dezactivat. Rulările zilnice rămân `full`, cu descoperire HTML.
3. În Actions → Import Linella → Run workflow, pentru prima probă alege:
   - `mode`: **selective**;
   - `search_api`: **true**;
   - `query`: **red bull**;
   - `category`: **/bauturi/energizante/**.
4. Categoria și produsele trebuie să existe deja dintr-un import HTML. Citește în log `searchApiRequests`, `searchApiFailures`, `htmlFallbackRequests` și starea catalogului. O căutare selectivă nu declară catalogul întreg complet.
5. Pe telefon folosește adresa `https://preturi-linella.onrender.com`, apoi Actualizare rapidă pentru a primi delta salvată de server. La o instalare fără date, folosește actualizarea inițială completă.

Butonul „Actualizare rapidă” de pe telefon continuă să consume API-ul PostgreSQL/FastAPI. Nu declanșează GitHub Actions și nu trimite hash/cookies Linella din telefon. Etapa aceasta adaugă actualizarea rapidă selectivă pe server, apoi delta existentă o distribuie telefonului.

CLI echivalent (din `server`, cu mediul DB deja configurat):

```sh
# Windows PowerShell: $env:LINELLA_SEARCH_API_ENABLED='true'
# POSIX: export LINELLA_SEARCH_API_ENABLED=true
python -m app.cli sync-selected --query "red bull" --category /bauturi/energizante/

# Restricție opțională la ID-uri cunoscute; se poate repeta --source-id.
python -m app.cli sync-selected --query coca --category /bauturi/bauturi-racoritoare/ --source-id 29835

# Descoperirea catalogului rămâne HTML.
python -m app.cli sync-linella

# Stoc pentru UN produs, la cerere, fără scrieri în DB.
python -m app.cli stock --product-id 32956
```

Pentru îmbogățiri suplimentare în rularea zilnică full, setează în **GitHub Settings → Secrets and variables → Actions → Variables**:

- `LINELLA_SEARCH_API_ENABLED`: `true`;
- `LINELLA_SEARCH_SELECTIONS`: de exemplu `[ {"query":"red bull","category":"/bauturi/energizante/"} ]`.

Nu sunt secrete și nu conțin hash. Sunt acceptate maximum3 selecții explicite. Implicit lista este goală și flag-ul este false. Pornirea manuală permite alegerea flag-ului pentru acea rulare; programarea zilnică citește variabilele repository-ului. Flag ON cu full și lista goală continuă descoperirea HTML fără interogări Search inutile.

## 1. Fișiere existente modificate

- `server/app/scraper.py`: transport comun GET/POST, rate limit/retry, injecție client pentru teste, mapare HTML după source_product_id, scope selectiv fără marcarea absențelor, orchestrare full/selective și SyncRun.stats.
- `server/app/cli.py`: păstrează `sync-linella`; adaugă `sync-selected` și `stock`.
- `server/app/models.py`: anotările monetare sunt Decimal în loc de float. Tipurile PostgreSQL Numeric sunt identice; nu există migrare nouă.
- `server/.env.example`: flag-ul și lista de selecții, implicit dezactivate/goale.
- `.github/workflows/sync-linella.yml`: opțiuni manuale full/selective, flag, query și category; programarea și secretul DB sunt păstrate. Actualizat numai după prima suită completă trecută.
- `README.md`: trimitere la această documentație.

Parserul HTML, contractul FastAPI, Flutter, migrațiile DB și fișierele originale HTML/XLSX ale utilizatorului nu au fost rescrise.

## 2. Fișiere noi

- `server/app/linella_session.py`: sesiune publică, hash și refresh;
- `server/app/search_models.py`: DTO-uri validate, Decimal și reduceri;
- `server/app/search_client.py`: LinellaSearchClient și paginare;
- `server/app/search_normalizer.py`: patch-uri parțiale, identitate și politica promoțiilor/imaginilor;
- `server/app/data_source.py`: LinellaDataSource, flag, actualizare selectivă și fallback;
- `server/app/stock_client.py`: fragmentul de disponibilitate și cache temporar;
- `server/tests/test_search.py`, `test_data_source.py`, `tests/fixtures/search/*.json`: mock-uri și verificări PostgreSQL;
- `server/tools/audit_search_live.py`: probă read-only limitată, executată doar explicit;
- acest document și rapoartele `validation/phase2-*`.

## 3–6. Client, hash, refresh și cookies

LinellaSearchClient expune `initialize_session()`, `refresh_security_hash()`, `search(query, offset, limit)`, `collect(...)` și `get_stock_availability(product_id)`.

LinellaSession folosește același httpx.AsyncClient din Fetcher. GET-ul inițial citește pagina publică și extrage hash din input-urile security_hash și din atribuirea inline `_.security_hash`/`Tygh.security_hash`. Valorile contradictorii ori absente provoacă eșec controlat. Codul nu execută scripturile paginii și nu hardcodează un token real.

Cookie jar-ul httpx persistă între GET și POST. Hash-ul și acquired_at rămân în memoria procesului. Sesiunea serializează accesul și refresh-ul cu un lock async. La refresh șterge cookies vechi, reinițializează legitim sesiunea și repetă POST-ul o singură dată. Fără loop infinit, fără hash în loguri sau GitHub Secrets.

Semnalele de expirare sunt restrânse la coduri explicite `invalid_security_hash`, `expired_security_hash`, `session_expired` sau mesaje de eroare ce spun explicit invalid/expired security hash/CSRF token/session expired. Forma exactă a expirării naturale Linella nu a fost observată live; această ramură este verificată cu răspunsuri sintetice. Un 403 generic ori un challenge nu este tratat ca permisiune de ocolire: provoacă fallback. Nu se confirmă vârsta și nu se autentifică un cont.

Transportul comun are maximum4 cereri simultane, interval implicit0,5s (minimum0,25), timeout30s, corp maximum8MiB, maximum3 încercări pentru erori tranzitorii. Retry păstrează form data originală inclusiv după un stream întrerupt. Pentru 429 se respectă Retry-After numeric, plafonat la30s. Redirect-urile externe nu sunt urmate.

## 7–8. Paginare și limită

Defaultul noului client este100 produse/pagină; intervalul acceptat este1…100. Sunt validate envelope-ul success, meta/query/offset/limit/returned/total, has_more și next_offset, produse, brands, categories și settings. HTTP200 cu notificare E nu este succes.

`collect` colectează atomic o căutare limitată înainte de DB: maximum10 pagini/1000 produse, garduri pe offset, semnătură de pagină, duplicate product_id, total schimbat, rezultat gol intermediar și metadate incoerente. Un rezultat gol valid este acceptat de client; pentru o actualizare a unor produse cunoscute, coordinatorul îl tratează ca lipsă de acoperire și folosește HTML.

## 9. Limita20000

Clientul refuză `offset+limit>20000`. Colectorul selectiv refuză query gol, `*` și `%`, precum și rezultate peste buget. Nu generează query-uri alfabetice și nu încearcă scroll ori acces la indexul intern. Search nu este discovery și nu confirmă dispariția produselor.

## 10–11. Ce rămâne HTML și ce folosește Search

HTML păstrează arborele, toate scope-urile full, campaniile Mega și perioadele lor, colecțiile promoționale, miniaturile și fallback-ul. Remedierile anterioare pentru AUTOCOMMIT și conținut restricționat sunt păstrate.

Search actualizează selectiv numai produsele deja existente în categoria indicată și descendenții ei. Produsele necunoscute întoarse de query sunt numărate și ignorate; nu sunt inserate ca un al doilea catalog. Asocierea DB este după Product.source_product_id, apoi upsert folosește ID-ul real al rândului existent, inclusiv când nu are forma linella:ID. Numele nu este criteriu de fuziune.

Categorie textuală și cart_available sunt păstrate separat în DTO și în `SyncRun.stats.searchCommercialIndicators` (maximum1000 observații per rulare). Nu suprascriu `in_stock`, nu schimbă arbitrar ierarhia și nu sunt prezentate pe telefon ca stoc fizic. Categoriile FK sunt rezolvate prin URL și arborele existent. Într-un query fără --source-id, rezultatul este subsetul cunoscut din categoria selectată; nu reprezintă actualizarea tuturor produselor acelei categorii.

## 12–13. Prețuri, reduceri și identificatori

Parserul monetar acceptă format validat cu lei, punct/virgulă, spații/NBSP pentru mii, apoi Decimal exact la două zecimale. Respinge valori negative, NaN/Infinity, formate ambigue, overflow și mai mult de două zecimale. `21.99lei` și `23.99lei` produc reducere observată **8,34%**, rotunjită ROUND_HALF_UP. list_price absent nu este inventat.

Patch-urile omit SKU, barcode, promotion_start/end și thumbnail_url. Nu șterg câmpuri bune prin null. Promoțiile dated rămân autoritatea HTML: dacă noua pereche de prețuri ar contrazice o campanie cu perioadă verificată, grupul monetar este păstrat și `searchPromotionConflicts` crește; brandul și celelalte câmpuri sigure se pot îmbogăți. Similar, list_price absent nu este dovadă de expirare a reducerii existente. Aceste conflicte marchează SyncRun partial pentru verificare prin sursa promoțională.

DB este în continuare Numeric(12,2). Calculul nou Search nu folosește float. Serializarea publică existentă transformă Decimal în număr JSON, iar SQLite folosește REAL; contractul API/Flutter nu a fost schimbat în această fază.

## 14. Imagini400×400 și evitarea duplicatelor

Am folosit alternativa autorizată în cerere: **păstrarea sursei reale225×225**, fără serviciu nou de resize/storage. Search.img400 se salvează numai ca source_image_url/full_image_url, niciodată ca thumbnail_url.

Dacă miniatura lipsește sau fișierul de imagine observat s-a schimbat, se face o singură parcurgere HTML a categoriei, nu câte un request de detaliu pentru fiecare produs. Se preia doar URL-ul225 prezent efectiv în HTML. Dacă nici HTML nu oferă o miniatură validă, nu se inventează URL-ul și nu se trimite400 ca miniatură; valoarea sigură existentă rămâne sau miniatura rămâne absentă.

Backendul nu descarcă imaginile în sincronizarea normală. Telefonul păstrează logica existentă: URL/hash pentru reutilizare, verificare reală a dimensiunii≤225, limită96KiB și plafon512MiB. Cache-ul separat pentru imagini mari cerute explicit de utilizator rămâne neschimbat. Nu a fost generat WebP nou și nu este necesar un APK nou pentru această integrare.

## 15. Fallback și stoc la cerere

Timeout, HTTP error, JSON invalid, metadate/câmpuri obligatorii lipsă, buget depășit, hash nerecuperabil sau acoperire insuficientă produc `SEARCH_API_FAILED`, apoi `FALLBACK_HTML_USED`. HTML actualizează scope-ul cunoscut fără a marca absențe în modul selectiv. Dacă HTML funcționează, jobul poate continua; dacă și acesta eșuează, eroarea se propagă și istoricul o consemnează. Nu se publică pagini Search parțiale înainte de validarea întregii căutări limitate.

Stocul este disponibil prin metoda clientului și comanda CLI dedicată, fără apeluri automate în import. Se extrage exclusiv `html[warehouses_stock_availability_ID]`. Proba live a confirmat că rândurile de disponibilitate sunt frați ai wrapper-ului titlului; parserul suportă structura reală. Rezultatul conține context, etichete/valori și checked_at, nu cantități inventate. Cache-ul în memorie are TTL15 minute, maximum256 intrări și cheie legată de generația sesiunii. Procesul CLI scurt închide cache-ul la ieșire; reutilizarea se aplică unui client persistent. HTML-ul brut nu se salvează permanent.

## 16. Metrici și comparație OFF/ON

SyncRun.stats (fără migrare) și logurile expun `searchApiRequests`, `searchApiProducts`, `searchApiFailures`, `securityHashRefreshes`, `htmlFallbackRequests`, `stockRequests`, plus totalRequests/durationMs și contoarele existente. Cererile Search numără încercările HTTP efective, inclusiv retry; totalRequests include bootstrap-ul sesiunii. Error de paginare este numărat o singură dată la nivelul căutării. Detaliile comerciale sunt salvate limitat în stats, dar nu tipărite ca o listă lungă în log.

**Aceeași sarcină controlată, PostgreSQL real local, HTTP mock:**240 produse cunoscute cu aceleași prețuri inițiale, exact aceleași240 ID-uri țintă. Sunt pagini HTML24 produse și Search100 produse; pauza implicită și scrierile DB sunt incluse.

| Măsură | Search OFF | Search ON |
|---|---:|---:|
| Durată măsurată |4,66s|1,89s|
| Cereri HTTP, inclusiv bootstrap |10|4|
| Produse descoperite noi |0|0|
| Produse existente actualizate |240|240|
| Reduceri detectate |240|240|
| Erori / fallback requests |0 /0|0 /0|

Reducere de cereri: **60%** în această sarcină controlată. Nu este o estimare a vitezei întregului catalog.

**Probă live read-only cu implementarea nouă:** Search „red bull”, limit100:2 cereri inclusiv inițializarea,32 rezultate,1,28s. Categoria HTML Energizante:4 pagini,82 produse,4,93s; acoperirea acelei categorii s-a încheiat. Cele7 ID-uri comune au preț și list_price identice în7/7 cazuri. Search și categoria nu sunt același univers de produse; comparația live nu demonstrează înlocuirea descoperirii. Nicio scriere în DB de producție. Stock explicit product32956: context Кишинев, „În stoc”, „în1 magazin”, rezultat structurat verificat; zero stock requests în importurile automate testate.

Avantaj real demonstrat: mai puține cereri pentru sarcina selectivă testată. Un Full HTML + Search suplimentar poate crește durata, deoarece adaugă îmbogățire. Fallback-ul pentru imagini lipsă/erori poate anula avantajul; de aceea există metrici separate și flag OFF.

## 17. Verificări

- **72 teste backend trecute**,67,56s, inclusiv PostgreSQL local,50.000 produse, teste vechi și teste noi.
- Prețuri, hash/config conflictual, cookies, refresh reușit/eșuat, retry o singură dată, inițializare concurentă, stream întrerupt, paginare/duplicate/total/limite, răspunsuri invalide, stoc/cache și fallback sunt acoperite prin mock-uri.
- Teste DB: identitate după source_product_id, SKU/barcode păstrate, fără duplicate, date promoționale păstrate, actualizare repetată fără schimbări inutile, miniaturi225 fără download400, Search parțial nepublicat.
- `alembic check`: **No new upgrade operations detected**. Nu s-au rulat migrații pe Neon.
- Modulele Python compilează. Proiectul nu are formatter/linter backend configurat; nu s-a introdus unul ca dependență de producție.
- Workflow YAML parsează; inputurile sunt transmise ca variabile de mediu și argumente shell între ghilimele, fără interpolare de cod în script. Flag default false, cron existent, permisiuni contents:read și excludere de concurență păstrate.
- Client httpx validat live cu sesiune publică reală. Testele unitare nu depind de Linella live.
- Flutter nu a fost modificat; nu a fost reconstruit APK-ul și nu s-au reluat testele Flutter pentru o schimbare exclusiv server-side.

Rapoarte: `validation/phase2-backend-tests.log`, `phase2-off-on-mock.json`, `phase2-live.json`. Probele live sunt separate de testele automate și nu se execută în workflow-ul normal.

## 18. Limite și rollback

- Nu există enumerare completă Search demonstrată; HTML rămâne obligatoriu pentru discovery.
- Nu este o soluție pentru ocolirea verificării vârstei; conținutul restricționat se raportează în continuare.
- Nu este verificată toate magazinele/regiunile sau expirarea naturală exactă a sesiunii Linella. Nu tratăm cartAvailable drept stoc fizic.
- Buget1000 rezultate/query, maximum3 selecții suplimentare pe full; căutări prea largi cad pe HTML, nu sunt partiționate artificial.
- Detaliile de stoc/cartAvailable nu sunt afișate în UI-ul Android în această fază; nu a fost extins contractul public.
- Fără miniatură225 verificată, nu se face resize400 în această implementare; imaginea400 nu este folosită ca miniatură persistentă.
- Conflictele cu perioade promoționale păstrează valorile HTML și sunt raportate; nu se garantează că orice ofertă observată Search înlocuiește imediat o campanie verificată.
- Schimbările sunt locale; trebuie încărcate în GitHub. Flag false revine la HTML pentru rulările ulterioare, fără a inversa automat datele deja publicate. Corecțiile se propagă printr-o sincronizare ulterioară.
