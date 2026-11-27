# Ustame backend (Go)

Bitta API: mobil ilova (Expo), web-sayt va Telegram bildirishnomalar boti uchun. Hosting — Railway, baza — Neon Postgres.

Biznes mantiq (e'lon, taklif, shartnoma, chat, baho, admin) va ruxsat tekshiruvlari Postgres funksiyalarida
(`sql/app.sql`). Go qatlami yupqa: kirish (SMS-kod, JWT), funksiyalarni chaqirish, rasmlar.

## Endpointlar

| Yo'l | Vazifasi |
|---|---|
| `POST /api/auth/send-code` `{phone}` | SMS-kod (Eskiz). 60 soniyada 1, soatiga 5 ta |
| `POST /api/auth/verify` `{phone, code}` | `{token, user}` — 30 kunlik JWT |
| `POST /api/auth/telegram/start` | `{url, secret, expires_in}` — Telegram orqali kirish (pastda) |
| `POST /api/auth/telegram/check` `{secret}` | `{status: "pending"}` yoki `{status: "ok", token, user}`; eskirgan — 400 `LOGIN_EXPIRED` |
| `GET/PATCH /api/me` | Profil, `{full_name?, active_role?}` |
| `POST /api/rpc/{fn}` `{p_arg: ...}` | `sql/app.sql` dagi funksiya (faqat `authenticated` ga ruxsat berilganlari) |
| `GET/POST/DELETE /api/files` | Rasmlar: avatar, e'lon rasmi, portfolio |
| `GET /healthz` | Sog'liq tekshiruvi |
| `GET /push/logo.png` | Android bildirishnomasidagi rangli logo (telefon har push'da yuklaydi, pastda) |

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

## Telefon bildirishnomalari (push)

`internal/push` — `notification_outbox` dagi xabarlarni Expo Push orqali yuboradi (Android'da FCM). Android'da
o'ng tomondagi rangli logo `richContent.image` bilan beriladi: ilova yopiq/orqa fonda bo'lsa bildirishnomani FCM'ning
o'zi chizadi va ilovaga qo'yilgan large icon'ni o'qimaydi, rasmni faqat xabardagi havoladan oladi. Kichik belgi har
doim oq siluet (Android qoidasi). Bildirishnoma ochilganda (pastga tortilganda) FCM rasmni katta qilib ko'rsatadi,
matn bitta qatorda qoladi.

- `PUSH_IMAGE_URL` — bo'sh (standart): serverning o'zidagi `/push/logo.png` (`RAILWAY_PUBLIC_DOMAIN` dan);
  `off` — rasmsiz; boshqa qiymat — shu havola. Ishga tushganda log'da qaysi rasm ishlatilishi yoziladi.

## Telegram orqali kirish

SMS'siz kirish (jadval: `sql/01-telegram-login.sql`):

1. Ilova `POST /api/auth/telegram/start` → `t.me/<bot>?start=login_<kod>` ni ochadi, `secret` ni o'zida saqlaydi.
2. Bot `/start login_<kod>` ni olib, «📱 Raqamni yuborish» tugmasini ko'rsatadi.
3. Foydalanuvchi o'z raqamini yuboradi. Bot faqat `contact.user_id == from.id` (o'z raqami, forward emas) va
   `+998` raqamlarni qabul qiladi.
4. Ilova har 2 soniyada `POST /api/auth/telegram/check {secret}` qiladi; raqam tasdiqlangach token oladi.
   Shu Telegram bildirishnomalar uchun ham ulanadi.

Havola 10 daqiqa amal qiladi va bir martalik. `secret` havolada yo'q, bazada faqat sha256 xeshi saqlanadi.

## Botda «Usta chaqirish» (e'lon berish)

Mijoz ilovasiz, botning o'zida e'lon beradi (`internal/telegram/order.go`). Operator kerak emas:

1. Kirish: `t.me/<bot>?start=order`, `?start=order_<manba>` yoki `?start=order_<manba>__<kampaniya>` (reklama
   havolasi, masalan `order_instagram__nov25`), `/usta` buyrug'i (bot menyusi) yoki havolasiz `/start` dagi
   «🛠 Usta chaqirish» tugmasi.
2. Kasb va tuman — tugmalar (Toshkent shahri tumanlari + «Boshqa viloyat» → viloyat → tuman). Tumanlar ro'yxati
   `regions_gen.go` da: ilovadagi `regions.ts` o'zgarsa `node usta-api/scripts/gen-district-regions.mjs`.
3. Muammo — 🎤 ovoz (`STT_API_KEY` bo'lsa matnga aylanadi) yoki matn; rasm (izohi bilan ham) ixtiyoriy. Ovoz
   yoqilgan bo'lsa, muammo so'rovining o'zida ovoz qaysi xizmatga yuborilishi oldindan aytiladi (STT_URL bo'yicha:
   OpenAI, Groq yoki manzil nomi) va yozib yuborish taklif qilinadi; ovozning o'zi saqlanmaydi.
4. Manzil — 📍 joylashuv tugmasi yoki matn. Vaqt: Bugun / Shu hafta / Shoshilmayman («shoshilinch» yo'q — u faqat
   «hozir bo'shman» belgilagan ustalarga boradi).
5. Mijoz tayyor e'lonni ko'rib «✅ E'lon qilish» ni bosadi. Raqami noma'lum bo'lsa — «📱 Raqamni yuborish»
   (kirishdagi kabi faqat o'z raqami). E'lon `post_job` orqali shu foydalanuvchi nomidan chiqadi — ustalarga xabar
   odatdagidek; mijozga takliflarni ko'rish tugmasi (kirish kodi bilan) yuboriladi.

Yangi jadval yo'q, qoralama xotirada (server qayta ishga tushsa yoki deploy paytida boshlangan qoralama yo'qoladi —
eski tugma bosilsa bot «/usta bilan qayta boshlang» deydi). Himoyalar:

- Takroriy e'lon: yangilanishlar ketma-ket ishlanadi (ikkinchi bosish qoralamasiz — «eskirgan»), bundan tashqari
  baza xuddi shu mijozning xuddi shu e'lonini (kasb, tuman, tavsif) 10 daqiqa ichida qayta yaratmaydi.
- Spam: bitta foydalanuvchi bot orqali 24 soatda 5 tadan ko'p e'lon bera olmaydi.
- Sinov raqamlari (`ORDER_TEST_PHONES`): e'lon to'liq tekshiriladi (post_job, rasm, joylashuv, triggerlar), keyin
  tranzaksiya bekor qilinadi — e'lon saqlanmaydi, ustalarga xabar ketmaydi; bot nechta usta va admin xabar olishini aytadi.

Manba: reklama havolasidan kelgan tashrif `visit_sources` ga (`medium = telegram_bot`, `landing = tg-order`; menyu
va tugma — tashrif emas), bot orqali ro'yxatdan o'tgan yangi mijozga `users.signup_source` (manba bo'lmasa
`telegram_bot`). Admin «Trafik manbalari» ikkalasini ham ko'rsatadi.

Sozlamalar:

- `TELEGRAM_ORDERS` — `off` (standart, bo'sh ham) | `test` (faqat `ORDER_TEST_PHONES`, avval Telegram orqali
  kirgan chatdan) | `on` (hamma uchun: salomlashuvda tugma, bot tavsifiga qo'shimcha, menyu `/usta`, `/start`).
  `off`/`test` da bot profiliga tegilmaydi. `on` dan qaytarilsa menyu o'zi o'chmaydi (BotFather'da o'chiriladi).
- `ORDER_TEST_PHONES` — vergul bilan, masalan `998901234567,998901112233`.
- `STT_API_KEY` (bo'sh — ovoz qabul qilinmaydi), `STT_URL` (standart OpenAI `/v1/audio/transcriptions`; Groq va
  boshqa mos xizmatlar ham bo'ladi), `STT_MODEL` (standart `gpt-4o-transcribe`).

SQL sinovi (lokal PGlite, prod'ga tegmaydi — test lokal bo'lmagan manzilni rad etadi):
`USTAME_PG_TEST_URL=postgres://postgres@127.0.0.1:5433/postgres?sslmode=disable&pool_max_conns=1 go test -run TestPgOrderStore ./internal/telegram/`

## Railway'ga joylash

1. Railway → New Project → Deploy from GitHub repo → `ustame-backend`. Yig'ish `Dockerfile` va `railway.json` bo'yicha.
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
sql/              baza sxemasi (00-auth.sql, 01-telegram-login.sql, app.sql)
```
