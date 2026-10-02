> Document istoric pentru versiunea anterioară. Pentru 2.0 folosește [README.md](README.md), [RAPORT_HIBRID.md](RAPORT_HIBRID.md) și [DEPLOY_RENDER.md](DEPLOY_RENDER.md).

Versiunea curentă: **1.1.1+3**. Detaliile verificării importului și fișierelor alternative sunt în [IMPORT_1.1.1.md](IMPORT_1.1.1.md). Schema bazei rămâne 2. Instrucțiunile de actualizare și utilizare de mai jos rămân valabile.

# CAUTĂ PREȚ 1.1.0 — actualizare

1. În aplicația existentă, deschide **Mai multe → Backup / Restaurare → Creează backup**. Bifează imaginile dacă dorești să le incluzi.
2. Copiază `Cauta-Pret-1.1.0-arm64.apk` pe telefon și deschide-l. Alege **Actualizează**. Nu dezinstala aplicația și nu șterge datele ei.
3. Versiunea nouă păstrează baza existentă și aplică automat migrarea SQLite 1 → 2. Pentru utilizarea zilnică, folosește **Actualizare rapidă**. Nu este necesară repetarea unei actualizări totale doar pentru instalarea acestei versiuni.
4. Pentru UNARETAIL: **Mai multe → Importă produse / SKU → Selectează XLSX / CSV**. Verifică foaia `Date`, coloanele `Cod de bare` și `Cod produs`, apoi confirmă importul.
5. **Mai multe → Identificatori neasociați** păstrează perechile care nu au încă un produs. Poți căuta exact după SKU/cod și alege manual un produs verificat. ID-ul intern Linella nu este tratat drept SKU UNARETAIL.
6. Dacă un SKU are mai multe coduri sau un cod are SKU-uri diferite, aplicația cere verificarea asocierii și păstrează valorile existente. Fișierul furnizat conține 1.559 de perechi, dintre care 175 sunt în această situație. Reimportul nu dublează perechile.
7. **Mai multe → Setări • Stocare** arată baza, imaginile, cache-ul și backupurile locale. Curățarea este disponibilă când sincronizarea/importul s-au oprit. Backupurile salvate în alte foldere sau cloud nu sunt incluse în total.

Produsele deja salvate, imaginile locale, căutarea și identificarea după cod funcționează offline. Pentru un cod importat care nu este asociat, aplicația afișează SKU-ul și codul, fără să inventeze produsul sau prețul.

Actualizarea citește cardurile paginilor de categorie și paginarea. Nu mai descarcă automat pagina individuală a fiecărui produs pentru SKU și brand. Câmpurile deja existente sunt păstrate când sursa nu furnizează aceste informații.

APK-ul folosește același pachet și același certificat ca APK-ul 1.0.0 livrat în acest proiect. Dacă Android refuză actualizarea unei aplicații provenite din altă variantă sau cu altă semnătură, păstrează aplicația instalată și comunică mesajul exact.

## Compilare și verificare

Mediu verificat: Flutter 3.47.5 / Dart 3.13.4, JDK 21, Android SDK 36. Rulează flutter pub get, dart format lib test, flutter analyze, flutter test și flutter build apk --release --target-platform android-arm64. Testele folosesc copiile reale din test/fixtures și baze temporare, fără acces la telefon.

Detaliile arhitecturii, migrării și rezultatele se află în VALIDARE.md și validation/1.1/. Păstrează certificatul original dacă recompiliezi pentru upgrade; alt certificat nu poate actualiza instalarea existentă.

