-- =====================================================================
-- Ilova SQL'i (Supabase'dan Neon'ga ko'chirilgan). Qayta ishga tushirish xavfsiz.
-- Manba: ustame/supabase/*.sql — scripts/migrate-app.js orqali qo'llanadi.
--
-- Supabase o'rniga:
--   * auth.users  -> public.users ustidagi ko'rinish (id, phone)
--   * profiles    -> public.users ustidagi yangilanadigan ko'rinish
--   * auth.uid()  -> backend tranzaksiya ichida o'rnatgan request.jwt.claims.sub
--                    (api/rpc: set_config('request.jwt.claims', ..., true))
-- Olib tashlangan: Storage siyosatlari, Realtime, pg_net (Telegram yuborish), auth trigger.
-- =====================================================================

create extension if not exists pgcrypto;

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
end $$;

create schema if not exists auth;

create or replace view auth.users as
  select id, phone from public.users;

create or replace function auth.uid() returns uuid language sql stable as $$
  select nullif(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub', '')::uuid
$$;

create or replace view public.profiles as
  select id, full_name, active_role, created_at, avatar_updated_at, is_admin,
         telegram_chat_id, telegram_link_code
  from public.users;

grant usage on schema auth to anon, authenticated;
grant execute on function auth.uid() to anon, authenticated;
grant usage on schema public to anon, authenticated;
grant select on auth.users to authenticated;

-- Rasmlar (Supabase Storage o'rniga, vaqtincha Neon'da)
create table if not exists public.files (
  bucket       text not null,
  path         text not null,
  content_type text not null,
  data         bytea not null,
  updated_at   timestamptz not null default now(),
  primary key (bucket, path)
);
