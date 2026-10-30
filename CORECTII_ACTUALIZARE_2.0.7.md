# Corecții 2.0.7 — actualizarea prețurilor

Cauza verificată pe 30.10.2026: jobul GitHub Import Linella din 30 octombrie a eșuat la prima cerere către /toate-categoriile/, HTTP 403. Catalogul API era accesibil, dar prețul SKU 285759 era încă 47,99 lei, modificat la 22 octombrie. Captura utilizatorului arată 54,99 lei. Nu am înlocuit manual prețul și nu am ocolit blocarea Linella.

## Modificări

- API-ul publică data ultimei verificări complete Linella separat de starea bazei/API. O verificare parțială, întreruptă sau exclusiv Mega nu este considerată verificare completă.
- O descărcare reușită pe telefon nu dovedește că serverul are prețuri recente. Aplicația afișează ambele date, avertizează după 26 ore, la eșec sau când backendul vechi nu oferă informația. Avertismentul persistă offline și se recalculează folosind ceasul telefonului.
- Lipsa internetului nu blochează catalogul. Eroarea de descărcare rămâne vizibilă; data ultimei descărcări reușite nu se înlocuiește cu data încercării eșuate.
- O reducere cu perioadă încheiată nu mai este afișată ca preț actual atunci când sursa repetă reducerea și în câmpul preț normal. Se afișează prețul normal salvat, cu indicație de reverificare; dacă lipsește, preț indisponibil. Datele promoției nu sunt șterse.
- Listele se recalculează la schimbarea perioadei promoționale, iar detaliile se recalculează la revenirea în aplicație și cel mult într-un minut cât timp sunt deschise.
- Despre afișează 2.0.7. Pachetul rămâne md.cautapret.cauta_pret.

## Programare server

Repository-ul are deja workflow-ul .github/workflows/sync-linella.yml. Noua programare este 17 */6 * * * (UTC), cu comandă sync-scheduled: verificare completă o dată pe zi, reîncercare la următorul interval după un eșec. Pentru Render Cron există aceeași comandă în Blueprint, ca alternativă; nu crea două programări. Lock-ul PostgreSQL împiedică scrierile concurente.

Nu sunt necesare tabele noi sau modificarea secretelor. Un job reușit trebuie să publice priceRefreshComplete=true. Cât timp Linella întoarce 403, nu poate fi garantată actualizarea efectivă. Este necesar acces permis de sursă ori un flux de date oficial; nu se recomandă schimbarea IP-urilor sau ocolirea protecțiilor.

Instalează noul APK peste aplicația existentă, fără dezinstalare. Verifică data sursei după Actualizare rapidă. Datele importate și codurile de bare rămân locale.

## Starea livrării

Publicarea în gorila989/Preturi-Linella a fost autorizată de utilizator. Pachetul conține 18 fișiere modificate față de main 6d4bc9f82e248c9785c834ab0bba54f939d26f3e; nu include secrete. După publicare se verifică separat activarea versiunii API și rezultatul importului Linella. APK 2.0.7 (versionCode 11) compilat și verificat, semnat cu același certificat ca versiunile anterioare.

Validare: Flutter analyze fără probleme, 88 teste Flutter trecute și unul omis; 163 teste backend trecute; încă 6 verificări backend pentru metadate/API/lock și 3 teste Flutter finale trecute. APK-ul nu a fost testat fizic pe Samsung.
