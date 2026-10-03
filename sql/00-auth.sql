-- Usta API sxemasi. Qayta ishga tushirish xavfsiz (idempotent).
-- scripts/migrate.js bilan bir xil jadvallar; qo'shimcha: users.active_role check.

create table if not exists users (
  id uuid primary key default gen_random_uuid(),
  phone text unique not null,
  full_name text not null default '',
  active_role text not null default 'client'
    constraint users_active_role_check check (active_role in ('client', 'provider')),
  created_at timestamptz not null default now(),
  avatar_updated_at timestamptz,
  is_admin boolean not null default false,
  telegram_chat_id bigint unique,
  telegram_link_code text unique,
  token_version integer not null default 0
);

-- Jadval avvalroq qisman yaratilgan bo'lsa ham xavfsiz qo'shiladi.
alter table users add column if not exists avatar_updated_at timestamptz;
alter table users add column if not exists is_admin boolean not null default false;
alter table users add column if not exists telegram_chat_id bigint unique;
alter table users add column if not exists telegram_link_code text unique;
alter table users add column if not exists token_version integer not null default 0;

-- Eski jadvalda check bo'lmasa qo'shiladi.
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'users_active_role_check') then
    alter table users add constraint users_active_role_check
      check (active_role in ('client', 'provider'));
  end if;
end $$;

create table if not exists otp_codes (
  id bigserial primary key,
  phone text not null,
  code_hash text not null,
  expires_at timestamptz not null,
  used boolean not null default false,
  attempts integer not null default 0,
  created_at timestamptz not null default now()
);

create index if not exists otp_codes_phone_idx on otp_codes (phone);

-- Eskiz tokeni va boshqa sozlamalar (key = 'eskiz_token', ...).
create table if not exists app_settings (
  key text primary key,
  value text,
  updated_at timestamptz not null default now()
);
