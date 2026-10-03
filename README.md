# Ustago backend (Go)

Bitta API: mobil ilova (Expo), web-sayt va Telegram bildirishnomalar boti uchun. Hosting — Railway, baza — Neon Postgres.

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

## Telegram bildirishnomalari

`TELEGRAM_BOT_TOKEN` berilsa, server bilan birga bot ham ishga tushadi (`internal/telegram`):

- Ilovada Profil → Telegram → «Botga ulanish» `t.me/<bot>?start=<kod>` ni ochadi; bot `/start <kod>` ni olib,
  foydalanuvchiga `telegram_chat_id` ni yozadi. `/stop` — uzish.
- Baza triggerlari xabarlarni `notification_outbox` ga yozadi, bot ularni har 3 soniyada yuboradi.
  Botni bloklagan foydalanuvchi avtomatik uziladi; 24 soatdan eski yuborilmagan xabar tashlanadi.
- Bot nomi ishga tushganda `app_secrets.telegram_bot_username` ga yoziladi (ilova shundan oladi).

Tokenni faqat bitta joyda (Railway) bering: bir token bilan ikki server `getUpdates` qilsa, Telegram 409 qaytaradi.

## Railway'ga joylash

1. Railway → New Project → Deploy from GitHub repo → `ustago-backend`. Yig'ish `Dockerfile` va `railway.json` bo'yicha.
2. Variables: `DATABASE_URL`, `JWT_SECRET`, `OTP_SECRET`, `ESKIZ_EMAIL`, `ESKIZ_PASSWORD`, `ESKIZ_TEST_MODE`,
   `TEST_PHONES`, `TELEGRAM_BOT_TOKEN` (`.env.local` dagi qiymatlar; `PORT` ni Railway o'zi beradi).
3. Settings → Networking → Generate Domain. Shu manzilni ilovaning `eas.json` dagi `EXPO_PUBLIC_API_URL` ga yozing.

## Tuzilma

```
cmd/server/       main: konfiguratsiya, baza puli, HTTP server
internal/config/  muhit o'zgaruvchilari (+ .env.local)
internal/auth/    telefon formati, OTP xeshi, JWT (Node usta-api bilan mos)
internal/eskiz/   SMS yuborish
internal/telegram/ bildirishnomalar boti (ulash + navbatdagi xabarlarni yuborish)
internal/api/     endpointlar
sql/              baza sxemasi (00-auth.sql, app.sql)
```
