-- Telegram orqali kirish. Qayta ishga tushirish xavfsiz (idempotent).
--
-- Oqim: ilova POST /api/auth/telegram/start -> t.me/<bot>?start=login_<start_code> ni ochadi;
-- bot /start login_<kod> ni olib chat_id ni yozadi va kontakt so'raydi; foydalanuvchi o'z raqamini
-- yuborgach phone yoziladi; ilova POST /api/auth/telegram/check { secret } bilan token oladi.
create table if not exists telegram_logins (
  id          bigint generated always as identity primary key,
  start_code  text unique not null,  -- havoladagi ochiq kod
  secret_hash text unique not null,  -- sha256(secret): secret faqat ilovada, havolada yo'q
  chat_id     bigint,                -- /start bosilgan chat
  phone       text,                  -- tasdiqlangan raqam (998XXXXXXXXX)
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null,
  used_at     timestamptz
);

create index if not exists telegram_logins_chat_idx on telegram_logins (chat_id) where phone is null;
create index if not exists telegram_logins_created_idx on telegram_logins (created_at);
