> Document istoric pentru versiunea anterioară. Pentru 2.0 folosește [README.md](README.md), [RAPORT_HIBRID.md](RAPORT_HIBRID.md) și [DEPLOY_RENDER.md](DEPLOY_RENDER.md).

# Raport CAUTĂ PREȚ 1.1.0 — 1 octombrie 2026

## Rezultatul actualizării

Modificările sunt în proiectul Flutter existent `outputs/cauta_pret`. Nu a fost creată o aplicație nouă. Pachetul rămâne `md.cautapret.cauta_pret`; versiunea este `1.1.0+2`, față de `1.0.0+1`. Configurația de semnare nu a fost modificată. Certificatul ambelor APK-uri are SHA-256 `beb1353d3a57cdb91f1e81c64b2b78ba99a5e06f2d7188d9b214281eff9cc09d`.

APK ARM64 release: `Cauta-Pret-1.1.0-arm64.apk`. Android minimum API 24, target API 36. Build reușit, aproximativ 35,9 MB în afișarea Flutter. Certificatul este cel Android Debug folosit și la livrarea anterioară, pentru instalare personală. Verificarea semnăturii v2 a trecut.

## Datele existente și migrarea

Schema SQLite crește **1 → 2** prin `ALTER TABLE`, adăugarea unei tabele și a indexurilor. Nu există ștergere/recreare a bazei la upgrade. Se păstrează tabelele și valorile existente, inclusiv SKU, barcode, aliasuri, promoții, asocieri, istoric și căi de imagini.

Se adaugă `Product.sourceProductId`, `Product.localImageUrl`, `PendingProductIdentifier`, statistici în `ImportHistory` și `SyncHistory`. ID-urile vechi `linella:…` completează `sourceProductId`; nu sunt copiate în SKU. Migrarea compară numărul categoriilor, produselor, SKU-urilor, codurilor, referințelor de imagine și promoțiilor înainte/după. O diferență anulează tranzacția.

Test reprezentativ v1 → v2, cu comparația fiecărei coloane vechi și a relațiilor:

| Date | Înainte | După |
|---|---:|---:|
| Categorii | 2 | 2 |
| Produse | 1 | 1 |
| Produse cu SKU | 1 | 1 |
| Produse cu barcode | 1 | 1 |
| Imagini locale | 1 | 1 |
| Promoții | 1 | 1 |

Toate valorile vechi sunt identice; fișierul imaginii este păstrat. Dovezi: `validation/1.1/migration.json`, `test/update_test.dart`.

În emulator Android 16, versiunea release 1.0.0 a primit două produse de test prin import. Versiunea release 1.1.0, compilată pentru x86_64 din același cod, a fost instalată cu **`adb install -r`**, fără dezinstalare și fără ștergerea datelor. Instalarea a reușit; ecranul arată **2 produse înainte și 2 după**, respectiv **31 de categorii principale înainte și după**. `firstInstallTime` a rămas neschimbat. Dovezi: fișierele `android-before-upgrade.xml`, `android-after-upgrade.xml`, `android-upgrade-install.txt` și `android-upgrade-package.txt` din `validation/1.1`.

Nu am accesat baza de pe telefonul utilizatorului. Numerele de mai sus sunt măsurători pe baze și emulator de test, nu o inventariere a datelor de pe telefon.

## Parser și sincronizare

Fixture-ul HTML este copia exactă a `html_link.txt`: `test/fixtures/energizante.html`. Conține **24 de carduri**, dintre care două cu preț vechi/reducere. Testul confirmă pentru `sourceProductId=30374`:

- `Bautura energizanta Pepene Rosu 0.25l RED BULL`;
- preț **28,19 lei**, citit din `28<sup>19</sup>`;
- starea „în stoc”, fără inventarea cantității;
- URL public de produs și imagine WebP 450×450;
- SKU absent, distinct de `sourceProductId`.

Separat este verificat cardul cu preț vechi **12,99 lei** și reducere **46%**. Se păstrează prețurile REAL existente în SQLite pentru compatibilitate; nu s-a făcut o conversie financiară a datelor vechi. Reducerile active continuă să folosească perioadele cunoscute, fără inventarea datelor lipsă.

Paginarea citește `link[rel=next]`, ancorele next, `data-ut2-load-more-url` și linkurile `data-ca-page`. Setul de URL-uri vizitate și identificarea paginilor repetate previn buclele. Numărul paginilor nu este hardcodat. Testul rulează trei pagini cu carduri reale distincte și verifică oprirea; un test separat confirmă oprirea unei bucle fără pierderea produselor salvate.

Etapa automată **„Detalii SKU și brand” a fost eliminată** din actualizările rapide, selective și totale. Cardurile furnizează prețurile și imaginile. SKU/brand opționale lipsă nu mai declanșează câte o cerere per produs. Parserul de detalii rămâne disponibil pentru codul existent și testele lui, dar sincronizarea normală nu îl apelează.

Test comparativ cu aceeași pagină de 24 de carduri, folosind codul anterior salvat înainte de modificări și transport HTTP controlat:

| Cereri HTML, fără imagini | Cod vechi | Cod nou |
|---|---:|---:|
| Pagina de categorie | 1 | 1 |
| Detalii opționale | 24 | 0 |
| Total | 25 | 1 |

Acesta măsoară cereri, nu viteza internetului sau durata unui catalog complet. Dovezi: `request-cost.json` și `request-cost.txt`. Pentru trei pagini distincte testate: 3 cereri HTML și 0 cereri de detalii. Imaginile lipsă presupun separat cereri; retry-urile pot crește traficul real.

Actualizarea rapidă păstrează Mega Ofertă, Cele mai bune oferte și două categorii prin rotație. Nu este un delta complet al întregului magazin: nu există un API delta configurat. Actualizarea selectivă păstrează limitarea la selecție. Concurența imaginilor este configurabilă între 1 și 6, implicit 4, cu timeout, retry/backoff, pauze între cereri și anulare. Paginile sunt salvate în tranzacții; identificatorii locali lipsă în HTML nu sunt goliți.

## Categorii și funcționare offline

Arborele existent folosește `parentId`, nivel și ordine; nu a fost reimportat sau aplatizat. Testul UI confirmă extinderea/restrângerea până la nivelul al treilea. „Vezi toate produsele” folosește query recursiv și nu creează o categorie artificială. Cele **301 de noduri**, inclusiv cele două denumiri identice din fișierul inițial, sunt păstrate de testele existente.

După închiderea/redeschiderea SQLite, testele verifică produse, prețuri, imagini, căutare, SKU, barcode și categorii fără client de rețea. Scannerul folosește același lookup local. Countdown-ul promoției este local și nu trimite cereri în fiecare secundă.

## Import UNARETAIL

Importul a fost executat și prin selectorul de fișiere Android în aplicația release, după upgrade; rezultatul nativ confirmă 1.559 de rânduri valide, 1.384 de perechi neasociate fără conflict și 175 de conflicte păstrate. Lista nativă afișează perechile, fișierul, foaia și rândul. Dovezi: `android-unaretail-preview.xml`, `android-unaretail-result.xml` și `android-pending.xml`.

Fixture: `test/fixtures/unaretail.xlsx`, copia exactă a originalului. Foaia **Date** conține **1.559 de rânduri de date**. `Cod de bare → barcode`, `Cod produs → SKU`; denumirea nu este obligatorie. Ordinea coloanelor, spațiile, diacriticele și aliasurile cerute sunt tratate în mapare.

Identificatorii XLSX sunt citiți din XML fără conversie în `double`. Textul păstrează zerourile, întregii și `279905.0` sunt normalizați, iar măștile numerice simple cu zerouri sunt respectate. Numerele fracționare sau peste precizia sigură Excel sunt semnalate. Nu se pot recupera zerouri deja pierdute din fișierul sursă. CSV acceptă și terminatoare de linie mixte. Formulele în coloanele importate sunt semnalate pentru înlocuire cu valori.

Primele patru perechi reale au fost verificate exact, inclusiv `4860019002077 → 279905`; există și teste cu `0012345678901`.

Pe un catalog fără asocieri UNARETAIL:

| Rezultat | Primul import | Al doilea import |
|---|---:|---:|
| Rânduri citite | 1.559 | 1.559 |
| Perechi stocate, total | 1.559 | 1.559 |
| Perechi noi fără conflict | 1.384 | 0 |
| Perechi identice deja stocate | 0 | 1.559 |
| Rânduri care necesită verificarea asocierii | 175 | 175 |

Cele 175 de rânduri sunt relații cu identificatori multipli, nu rânduri pierdute. Interfața separă erorile de citire de conflicte: 0 erori de citire și 175 de conflicte. Câmpul agregat istoric `rowsFailed`, păstrat pentru compatibilitate, include și conflictele. Toate perechile sunt păstrate. O asociere sigură prin SKU/barcode poate schimba numerele „asociate/neasociate” pe baza utilizatorului.

Perechile fără produs sunt salvate în `PendingProductIdentifier`, cu fișier, foaie, rând, dată, stare și eventuală eroare. Nu creează produse fără denumire. Rândurile invalide sunt păstrate distinct și nu se multiplică la repetarea aceluiași import. Există preview cu primele 50 de rânduri, raport, listă de erori, căutare a identificatorilor neasociați și asociere manuală confirmată.

La scanarea unui cod neasociat, aplicația afișează codul și SKU-ul local. ID-ul numeric Linella nu este folosit pentru a ghici SKU-ul UNARETAIL. Testele verifică explicit acest caz și faptul că o sincronizare ulterioară nu șterge identificatorii importați.

## Spațiu, duplicate și backup

Upsert-ul folosește `sourceProductId`, identificatorii existenți și URL-ul verificat, cu indexuri unice. Prețul sau denumirea schimbate nu creează alt produs. Importurile contradictorii nu suprascriu automat asocierile.

Imaginile folosesc nume stabile derivate din URL. Un fișier local valid cu aceeași adresă nu este descărcat din nou. Când adresa se schimbă, fișierul vechi rămâne disponibil până când înlocuitorul este salvat și referința actualizată. Curățarea șterge doar fișierele `.img` gestionate de aplicație care nu sunt referențiate. Testele verifică inclusiv descărcarea eșuată a înlocuitorului și păstrarea imaginii vechi.

Test repetat pe trei carduri reale, după curățare/checkpoint:

| Măsură | Înainte | După actualizarea identică |
|---|---:|---:|
| Produse | 3 | 3 |
| Fișiere imagine | 3 | 3 |
| Dimensiune imagini de test | 9 bytes | 9 bytes |
| SQLite + fișiere auxiliare | 217.088 bytes | 217.088 bytes |
| Imagini descărcate a doua oară | — | 0 |

Imaginile din acest test sunt răspunsuri binare mici controlate; valorile nu estimează spațiul unui catalog real. Dovezi: `repeated-sync.json`.

Copiile temporare create de selectorul Android sunt curățate după citirea importului/restaurării și sunt incluse în măsurarea cache-ului. Curățarea stocării păstrează fișierele originale și backupurile; un test separat verifică acest lucru.

Cache-ul HTML este limitat la patru corpuri de pagină în timpul actualizării și golit la final. Istoricul detaliat de sincronizare este limitat la 100 de intrări, cu maximum 200 de mesaje per raport salvat. SQLite poate păstra pagini libere pentru reutilizare; curățarea nu promite micșorarea imediată a fișierului fizic. Nu se rulează VACUUM în timpul sincronizării.

Backupul include noua tabelă. Backupurile v1 sunt validate și migrate într-o copie temporară înainte de restaurare. Verificarea checksum-urilor, integrității și relațiilor precede înlocuirea tranzacțională a rândurilor. Testele verifică restaurarea v1, v2, imaginile, setările și rollback-ul unui backup incompatibil. Fișierele originale furnizate nu au fost modificate; hash-urile înainte/după coincid.

## Verificări și limite

- `dart format`: executat pe surse și teste.
- `flutter analyze`: **No issues found**.
- `flutter test`: **44 de teste trecute**; suplimentar, un test comparativ al costului cererilor pe codul vechi/nou.
- Build Android release ARM64 și build release x86_64 pentru emulator: reușite.
- Actualizare nativă peste versiunea instalată: reușită, cu păstrarea celor două produse de test și a categoriilor.
- Testele existente pentru backup, promoții, anulare, ETag, ierarhie, 50.000 de produse și căutare continuă să treacă.

Nu s-a rulat o descărcare totală a întregului site și nu s-a testat camera fizică Samsung. Duratele/performance din testele Windows nu reprezintă măsurători pe telefon. Unele categorii din fișierul inițial încă necesită URL configurat manual dacă nu există o potrivire exactă în sursă. Perioadele promoționale lipsă nu sunt inventate. Build-ul afișează avertismentul existent despre compatibilitatea viitoare Kotlin a `file_picker`; build-ul actual reușește.

## Fișiere modificate

`lib/app_state.dart`; `lib/data/local_database.dart`; `lib/data/catalog_repository.dart`; `lib/domain/models.dart`; `lib/services/background_sync.dart`; `lib/services/backup_service.dart`; `lib/services/linella_parser.dart`; `lib/services/sync_service.dart`; `lib/services/transfer_service.dart`; `lib/services/storage_service.dart` (nou); `lib/ui/app.dart`; `lib/ui/product_pages.dart`; `lib/ui/transfer_pages.dart`; `lib/ui/pending_page.dart` (nou); `lib/ui/storage_page.dart` (nou); `pubspec.yaml`; `test/core_test.dart`; `test/update_test.dart` (nou); cele două fixtures reale și documentația.

Logurile și statisticile se găsesc în `validation/1.1/`. Codul Android de package name și semnare nu a fost modificat.

### Limită a verificării finale

Upgrade-ul release și importul UNARETAIL au fost verificate în emulator. După ultima ajustare a curățării cache-ului și a afișării separate a erorilor/conflictelor, cele 44 de teste, analiza și ambele build-uri au trecut din nou. Reinstalarea acestei ultime compilații în emulator și verificarea suplimentară a căutării au rămas neexecutate: aprobarea automată a comenzii Android a eșuat din cauza limitei de utilizare a contului, nu din cauza unei decizii că acțiunea ar fi nesigură. Telefonul utilizatorului nu a fost modificat.

