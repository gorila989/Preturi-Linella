# Caută Preț 2.0.1 — adresă Render configurată

Adresa implicită în aplicație și în serviciul Android:
https://cauta-pret-linella.onrender.com

Aceasta poate fi schimbată din Actualizare date → Server catalog. O adresă personalizată deja salvată este păstrată.

La verificarea din 2 octombrie 2026, GET /api/v1/health a răspuns HTTP 404 (File not found). Adresa HTTPS răspunde, dar noul API nu este încă disponibil la această rută. Instalarea APK-ului nu publică backendul.

Următorul pas: publicarea codului pregătit în https://github.com/gorila989/Preturi-Linella și configurarea serviciului Render conform DEPLOY_RENDER.md (root server, migrare PostgreSQL, uvicorn, variabile de mediu, apoi primul job Linella).

Schimbări față de 2.0.0: adresă implicită comună pentru interfață și sincronizare; versiune Android 2.0.1, cod 5. Nu s-au schimbat schema bazei sau protocolul API. Se păstrează datele la instalare peste versiunea anterioară cu aceeași semnătură.
