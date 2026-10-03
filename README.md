# Ustago backend (Go)

Bitta API: mobil ilova (Expo), web-sayt va keyinroq Telegram bot uchun. Hosting — Railway, baza — Neon Postgres.

Biznes mantiq (e'lon, taklif, shartnoma, chat, baho, admin) va ruxsat tekshiruvlari Postgres funksiyalarida
(`sql/app.sql`). Go qatlami yupqa: kirish (SMS-kod, JWT), funksiyalarni chaqirish, rasmlar.

## Endpointlar

| Yo'l | Vazifasi |
|---|---|
| `POST /api/auth/send-code` `{phone}` | SMS-kod (Eskiz). 60 soniyada 1, soatiga 5 ta |
| `POST /api/auth/verify` `{phone, code}` | `{token, user}` — 30 kunlik JWT |
| `GET/PATCH /api/me` | Profil, `{full_name?, active_role?}` |
| `POST /api/rpc/{fn}` `{p_arg: ...}` | `sql/app.sql` dagi funksiya (faqat `authenticated` ga ruxsat berilganlari) |
| `GET/POST/DELETE /api/files` | Rasmlar: avatar, e'lon rasmi, portfolio |
| `GET /healthz` | Sog'liq tekshiruvi |

Xatolar: `{"error": "KOD"}` — `AUTH_REQUIRED` 401, `NOT_ALLOWED` 403, `NOT_FOUND` 404, qolgan biznes xatolar 400.

## Lokal ishga tushirish

```bash
cp .env.example .env.local   # qiymatlarni to'ldiring
go test ./...
go run ./cmd/server
```

Smoke test (8 tekshiruv): `powershell -ExecutionPolicy Bypass -File scripts\smoke-test.ps1 -BaseUrl http://localhost:8080`

## Tuzilma

```
cmd/server/       main: konfiguratsiya, baza puli, HTTP server
internal/config/  muhit o'zgaruvchilari (+ .env.local)
internal/auth/    telefon formati, OTP xeshi, JWT (Node usta-api bilan mos)
internal/eskiz/   SMS yuborish
internal/api/     endpointlar
sql/              baza sxemasi (00-auth.sql, app.sql)
```
