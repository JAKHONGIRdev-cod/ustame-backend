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

-- Moderatsiya va hisobni o'chirish (Google Play talabi)
alter table public.users add column if not exists blocked_at timestamptz;
alter table public.users add column if not exists block_reason text;
alter table public.users add column if not exists deleted_at timestamptz;
-- Telegram orqali kirishda raqami (kontakt) tasdiqlangan chat: keyingi kirishlarda bot raqamni qayta so'ramaydi.
-- Faqat bildirishnoma uchun ulangan chat (telegram_chat_id) kirish huquqini bermaydi.
alter table public.users add column if not exists telegram_login_chat_id bigint;

create or replace function auth.uid() returns uuid language sql stable as $$
  select nullif(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub', '')::uuid
$$;

-- Backend /api/rpc har so'rovda funksiyadan oldin chaqiradi (bitta paketda, bazaga bir marta borib):
-- token bekor qilinmaganini (token_version) tekshiradi va auth.uid() uchun request.jwt.claims ni
-- shu tranzaksiyaga o'rnatadi. Xato bo'lsa keyingi funksiya umuman bajarilmaydi.
create or replace function auth.set_request_user(p_uid uuid, p_tv int) returns void
language plpgsql as $$
begin
  if not exists (select 1 from public.users where id = p_uid and token_version = p_tv
                 and blocked_at is null and deleted_at is null) then
    raise exception 'AUTH_REQUIRED';
  end if;
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
end $$;
revoke all on function auth.set_request_user(uuid, int) from public;

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

-- ===== schema.sql =====
create extension if not exists pgcrypto;

create table if not exists public.provider_profiles (
  user_id          uuid primary key references public.users (id) on delete cascade,
  headline         text not null check (char_length(headline) between 3 and 80),
  bio              text not null default '' check (char_length(bio) <= 1000),
  categories       text[] not null check (cardinality(categories) between 1 and 3),
  districts        text[] not null check (cardinality(districts) between 1 and 12),
  experience_years int not null default 0 check (experience_years between 0 and 60),
  status           text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  rejection_reason text,
  created_at       timestamptz not null default now(),
  reviewed_at      timestamptz
);

-- Admin ustaning shaxsini (pasport/ID) ko'rib tasdiqlagan vaqt — profilda "Shaxsi tasdiqlangan" belgisi
alter table public.provider_profiles add column if not exists id_verified_at timestamptz;

-- Ixtiyoriy soliq maqomi (o'zini o'zi band qilgan / YaTT) — tartibi pastda, "soliq maqomi" bo'limida.
-- Ustunlar shu yerda: provider_stats ularni o'qiydi.
alter table public.provider_profiles add column if not exists tax_kind text;
alter table public.provider_profiles add column if not exists tax_id text;
alter table public.provider_profiles add column if not exists tax_consent_at timestamptz;
alter table public.provider_profiles add column if not exists tax_submitted_at timestamptz;
alter table public.provider_profiles add column if not exists tax_verified_at timestamptz;
alter table public.provider_profiles add column if not exists tax_rejection_reason text;

create table if not exists public.jobs (
  id          uuid primary key default gen_random_uuid(),
  client_id   uuid not null references public.users (id) on delete cascade,
  category    text not null,
  district    text not null,
  title       text not null check (char_length(title) between 5 and 80),
  description text not null check (char_length(description) between 10 and 2000),
  budget      int check (budget is null or budget between 10000 and 100000000),
  urgency     text not null default 'flexible' check (urgency in ('today', 'this_week', 'flexible')),
  status      text not null default 'open' check (status in ('open', 'in_progress', 'completed', 'cancelled')),
  created_at  timestamptz not null default now(),
  closed_at   timestamptz
);

create index if not exists jobs_open_feed_idx on public.jobs (status, created_at desc);

create index if not exists jobs_client_idx on public.jobs (client_id, created_at desc);

create table if not exists public.job_addresses (
  job_id  uuid primary key references public.jobs (id) on delete cascade,
  address text not null check (char_length(address) between 5 and 300)
);

create table if not exists public.proposals (
  id          uuid primary key default gen_random_uuid(),
  job_id      uuid not null references public.jobs (id) on delete cascade,
  provider_id uuid not null references public.users (id) on delete cascade,
  price       int not null check (price between 10000 and 100000000),
  message     text not null default '' check (char_length(message) <= 1000),
  status      text not null default 'submitted'
              check (status in ('submitted', 'withdrawn', 'declined', 'closed', 'accepted')),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (job_id, provider_id)
);

create index if not exists proposals_provider_idx on public.proposals (provider_id, created_at desc);

create table if not exists public.contracts (
  id                 uuid primary key default gen_random_uuid(),
  job_id             uuid not null references public.jobs (id) on delete cascade,
  proposal_id        uuid not null unique references public.proposals (id) on delete cascade,
  client_id          uuid not null references public.users (id) on delete cascade,
  provider_id        uuid not null references public.users (id) on delete cascade,
  price              int not null,
  status             text not null default 'active'
                     check (status in ('active', 'submitted', 'completed', 'cancelled', 'disputed')),
  created_at         timestamptz not null default now(),
  submitted_at       timestamptz,
  completed_at       timestamptz,
  cancelled_at       timestamptz,
  cancelled_by       text check (cancelled_by in ('client', 'provider', 'admin')),
  cancel_reason      text,
  disputed_at        timestamptz,
  dispute_reason     text,
  dispute_resolution text check (dispute_resolution in ('provider', 'client')),
  resolved_at        timestamptz
);

create index if not exists contracts_client_idx on public.contracts (client_id, created_at desc);

create index if not exists contracts_provider_idx on public.contracts (provider_id, created_at desc);

create index if not exists contracts_job_idx on public.contracts (job_id);

create unique index if not exists contracts_one_live_per_job
  on public.contracts (job_id) where status in ('active', 'submitted', 'disputed', 'completed');

-- Kafolatlangan to'lov (to'lov tizimi ulanguncha admin pul harakatini qo'lda belgilaydi):
--   none     — kafolat ishlatilmagan (hisob-kitob mijoz va usta o'rtasida)
--   held     — mijoz puli Ustame'da ushlab turilibdi
--   released — ish qabul qilingach pul ustaga o'tkazildi
--   refunded — shartnoma bekor bo'lgach pul mijozga qaytarildi
alter table public.contracts add column if not exists payment_status text not null default 'none';
alter table public.contracts add column if not exists payment_held_at timestamptz;
alter table public.contracts add column if not exists payment_released_at timestamptz;
alter table public.contracts add column if not exists payment_refunded_at timestamptz;
alter table public.contracts add column if not exists payment_held_amount int;

-- Nizo (Upwork usulida): usta 72 soatda javob beradi, tomonlar kelishadi yoki admin hal qiladi.
--   payout_amount — nizo bo'yicha ustaga tegadigan summa to'liq emas bo'lsa (qisman qaytarish); null — to'liq
--   dispute_resolution: provider/client — admin bir tomon foydasiga, split — admin bo'lib berdi,
--                       settled — tomonlar o'zi kelishdi
alter table public.contracts add column if not exists payout_amount int;
alter table public.contracts add column if not exists dispute_response text;
alter table public.contracts add column if not exists dispute_responded_at timestamptz;
alter table public.contracts add column if not exists dispute_escalated_at timestamptz;
alter table public.contracts add column if not exists dispute_escalated_by text;
alter table public.contracts add column if not exists dispute_note text;
alter table public.contracts drop constraint if exists contracts_dispute_resolution_check;
alter table public.contracts add constraint contracts_dispute_resolution_check
  check (dispute_resolution in ('provider', 'client', 'split', 'settled'));

-- Mijoz usta yo'lga chiqqandan (yoki yetib kelgandan) keyin bekor qilgan — mijoz statistikasida ko'rinadi
alter table public.contracts add column if not exists late_cancel boolean not null default false;

-- Kafolat davri: ish yakunlangach 30 kun ichida mijoz nuqson bo'yicha murojaat qiladi, usta bepul tuzatadi.
--   open → fixed (usta tuzatdim dedi) → resolved (mijoz tasdiqladi) | unresolved (hal bo'lmadi yoki usta
--   3 kun javob bermadi — ustaning statistikasiga yoziladi)
create table if not exists public.warranty_claims (
  id            uuid primary key default gen_random_uuid(),
  contract_id   uuid not null references public.contracts (id) on delete cascade,
  reason        text not null check (char_length(reason) between 5 and 1000),
  status        text not null default 'open' check (status in ('open', 'fixed', 'resolved', 'unresolved')),
  provider_note text,
  created_at    timestamptz not null default now(),
  fixed_at      timestamptz,
  closed_at     timestamptz
);

create index if not exists warranty_claims_contract_idx on public.warranty_claims (contract_id);
create unique index if not exists warranty_claims_one_active
  on public.warranty_claims (contract_id) where status in ('open', 'fixed');

alter table public.warranty_claims enable row level security;

-- Nizo (Upwork usulida), 2-bosqich — mediatsiya: admin murosa summasini taklif qiladi, ikkala tomon 72 soat ichida
-- qabul qiladi yoki rad etadi (javob bermagan — qabul qilgan hisoblanadi). Kimdir rad etsa — 3-bosqich, arbitraj:
-- admin yakuniy qaror chiqaradi (admin_decide_dispute).
alter table public.contracts add column if not exists mediation_amount int;
alter table public.contracts add column if not exists mediation_note text;
alter table public.contracts add column if not exists mediation_at timestamptz;
alter table public.contracts add column if not exists mediation_client_ok boolean;
alter table public.contracts add column if not exists mediation_provider_ok boolean;
alter table public.contracts add column if not exists arbitration_at timestamptz;

-- Mijoz usta yo'lga chiqqach bekor qilsa, kafolatdagi puldan ustaga o'tadigan chaqiruv haqi (so'm)
create or replace function public._callout_fee() returns int language sql immutable as $$ select 50000 $$;

-- Shartnomagacha kontakt almashish taqiqlanadi (Upwork: platformani chetlab o'tish): telefon yoki karta raqami,
-- Telegram/WhatsApp havolasi, @username yoki e-pochta. Shartnoma tuzilgach telefon raqami o'zi ko'rinadi.
create or replace function public._has_contact(p text) returns boolean language sql immutable as $$
  select coalesce(p, '') ~ '(?<![0-9])(\+?998[ -]?)?\(?(20|33|50|55|7[0-9]|88|9[0-9])\)?[ .-]?[0-9]{3}[ .-]?[0-9]{2}[ .-]?[0-9]{2}(?![0-9])'
      or coalesce(p, '') ~ '(?<![0-9])[0-9]{4}[ -]?[0-9]{4}[ -]?[0-9]{4}[ -]?[0-9]{4}(?![0-9])'
      or coalesce(p, '') ~* '(t\.me/|telegram\.me/|wa\.me/|whatsapp|@[a-z][a-z0-9_.]{3,})'
$$;

-- Usta yuklagan pasport rasmlari (id-docs/<uid>/passport.jpg, selfie.jpg). Faqat egasi va admin ko'radi,
-- admin qaroridan keyin darhol o'chiriladi (internal/api/files.go).
create or replace function public._id_docs(p_user_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('name', substr(f.path, 38), 'v', (extract(epoch from f.updated_at) * 1000)::bigint)
                            order by f.path), '[]'::jsonb)
  from files f where f.bucket = 'id-docs' and f.path like p_user_id::text || '/%';
$$;

-- Usta holatlari: yo'lga chiqdi (va qachon yetib borishini aytdi) -> yetib keldi -> ish boshlandi
alter table public.contracts add column if not exists on_the_way_at timestamptz;
alter table public.contracts add column if not exists eta_at timestamptz;
alter table public.contracts add column if not exists arrived_at timestamptz;
alter table public.contracts add column if not exists started_at timestamptz;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'contracts_payment_status_check') then
    alter table public.contracts add constraint contracts_payment_status_check
      check (payment_status in ('none', 'held', 'released', 'refunded'));
  end if;
end $$;

create index if not exists contracts_payment_held_idx
  on public.contracts (created_at) where payment_status = 'held';

create table if not exists public.reviews (
  id          uuid primary key default gen_random_uuid(),
  contract_id uuid not null references public.contracts (id) on delete cascade,
  reviewer_id uuid not null references public.users (id) on delete cascade,
  reviewee_id uuid not null references public.users (id) on delete cascade,
  rating      int not null check (rating between 1 and 5),
  comment     text not null default '' check (char_length(comment) <= 1000),
  created_at  timestamptz not null default now(),
  unique (contract_id, reviewer_id)
);

create index if not exists reviews_reviewee_idx on public.reviews (reviewee_id, created_at desc);

alter table public.provider_profiles enable row level security;

alter table public.jobs              enable row level security;

alter table public.job_addresses     enable row level security;

alter table public.proposals         enable row level security;

alter table public.contracts         enable row level security;

alter table public.reviews           enable row level security;

revoke all on public.profiles, public.provider_profiles, public.jobs, public.job_addresses,
              public.proposals, public.contracts, public.reviews
  from anon, authenticated;

grant select on public.profiles, public.provider_profiles, public.jobs,
                public.proposals, public.contracts
  to authenticated;

create or replace function public.job_client_id(p_job_id uuid)
returns uuid language sql stable security definer set search_path = public as $$
  select client_id from jobs where id = p_job_id;
$$;

drop policy if exists profiles_select on public.profiles;

drop policy if exists provider_profiles_select on public.provider_profiles;

create policy provider_profiles_select on public.provider_profiles
  for select to authenticated using (status = 'approved' or user_id = auth.uid());

drop policy if exists jobs_select on public.jobs;

create policy jobs_select on public.jobs
  for select to authenticated using (
    status = 'open'
    or client_id = auth.uid()
    or exists (select 1 from public.proposals p where p.job_id = jobs.id and p.provider_id = auth.uid())
  );

drop policy if exists proposals_select on public.proposals;

create policy proposals_select on public.proposals
  for select to authenticated using (
    provider_id = auth.uid() or public.job_client_id(job_id) = auth.uid()
  );

drop policy if exists contracts_select on public.contracts;

create policy contracts_select on public.contracts
  for select to authenticated using (client_id = auth.uid() or provider_id = auth.uid());

create or replace function public.require_uid()
returns uuid language plpgsql stable security definer set search_path = public as $$
declare v uuid := auth.uid();
begin
  if v is null then raise exception 'AUTH_REQUIRED'; end if;
  return v;
end;
$$;

-- Baho (Upwork usulida) ikkala tomon baho qo'ygach yoki baholash muddati (yakunlangandan 14 kun) tugagach ochiladi
create or replace function public.review_is_public(p_contract_id uuid, p_reviewer_id uuid, p_created_at timestamptz)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select k.completed_at from contracts k where k.id = p_contract_id), p_created_at) < now() - interval '14 days'
      or exists (select 1 from reviews o
                 where o.contract_id = p_contract_id and o.reviewer_id <> p_reviewer_id);
$$;

create or replace function public.provider_stats(p_user_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  with c as (
    select
      count(*) filter (where status = 'completed')                                        as completed,
      count(*) filter (where status = 'cancelled' and cancelled_by = 'provider')          as withdrawals,
      -- Yutqazilgan nizo: admin mijoz foydasiga hal qilgan yoki kelishuvda pul to'liq qaytarilgan
      count(*) filter (where dispute_resolution = 'client'
                         or (dispute_resolution in ('split', 'settled') and status = 'cancelled'))  as disputes_lost,
      -- O'z vaqtida: aytgan vaqtidan 15 daqiqagacha kechikish kechiriladi
      count(*) filter (where eta_at is not null and arrived_at is not null)               as arrivals,
      count(*) filter (where exists (select 1 from warranty_claims w
                                      where w.contract_id = contracts.id and w.status = 'unresolved'))
                                                                                          as warranty_unresolved,
      count(*) filter (where eta_at is not null and arrived_at <= eta_at + interval '15 minutes') as on_time,
      -- Muvaffaqiyatli: yakunlangan, nizoda yutqazilmagan, pulning bir qismi qaytarilmagan
      -- va mijoz bahosi 4+ (yoki baho qo'ymagan)
      count(*) filter (where status = 'completed' and dispute_resolution is distinct from 'client'
                         and payout_amount is null
                         and not exists (select 1 from warranty_claims w
                                          where w.contract_id = contracts.id and w.status = 'unresolved')
                         and coalesce((select r2.rating from reviews r2
                                        where r2.contract_id = contracts.id and r2.reviewer_id = contracts.client_id
                                          and review_is_public(r2.contract_id, r2.reviewer_id, r2.created_at)), 5) >= 4)
                                                                                          as good
    from contracts where provider_id = p_user_id
  ),
  pp as (
    select status, reviewed_at, id_verified_at, tax_verified_at from provider_profiles where user_id = p_user_id
  ),
  r as (
    select count(*) as cnt, round(avg(rating)::numeric, 1) as avg
    from reviews where reviewee_id = p_user_id
      and exists (select 1 from contracts k where k.id = reviews.contract_id and k.provider_id = p_user_id)
      and review_is_public(reviews.contract_id, reviews.reviewer_id, reviews.created_at)
  )
  select jsonb_build_object(
    'completed_jobs', c.completed,
    'withdrawals',    c.withdrawals,
    'disputes_lost',  c.disputes_lost,
    'warranty_unresolved', c.warranty_unresolved,
    'reviews_count',  r.cnt,
    'avg_rating',     r.avg,
    'top_rated',      coalesce(r.avg >= 4.5 and c.completed >= 5, false),
    -- Kamida 3 ta holatdan keyin ko'rsatiladi (bitta tasodif foizni buzmasin)
    'on_time_rate',   case when c.arrivals >= 3 then round(100.0 * c.on_time / c.arrivals) end,
    'reliability',    case when c.completed + c.withdrawals + c.disputes_lost >= 3
                        then round(100.0 * c.completed / (c.completed + c.withdrawals + c.disputes_lost)) end,
    -- Upwork'dagi Job Success Score kabi: yakunlangan ishlarning qanchasi muvaffaqiyatli
    'success_score',  case when c.completed + c.withdrawals + c.disputes_lost >= 3
                        then round(100.0 * c.good / (c.completed + c.withdrawals + c.disputes_lost)) end,
    -- Yangi iqtidor: 90 kun ichida tasdiqlangan, 1-4 ta ishni muammosiz va yaxshi baho bilan bajargan
    'rising',         coalesce((select pp.status = 'approved' and pp.reviewed_at > now() - interval '90 days' from pp)
                               and c.completed between 1 and 4 and c.withdrawals = 0 and c.disputes_lost = 0
                               and coalesce(r.avg, 5) >= 4.5, false),
    'verified',       coalesce((select pp.id_verified_at is not null from pp), false),
    -- Ixtiyoriy: o'zini o'zi band qilgan yoki YaTT ekani admin tomonidan tekshirilgan ("soliq maqomi" bo'limi)
    'tax_registered', coalesce((select pp.tax_verified_at is not null from pp), false)
  )
  from c, r;
$$;

create or replace function public.client_stats(p_user_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  with j as (
    select count(*) as posted from jobs where client_id = p_user_id
  ),
  c as (
    select count(*) as hires,
           count(*) filter (where status = 'completed') as completed,
           count(*) filter (where status = 'cancelled' and cancelled_by = 'client' and late_cancel) as late_cancels
    from contracts where client_id = p_user_id
  ),
  r as (
    select count(*) as cnt, round(avg(rating)::numeric, 1) as avg
    from reviews where reviewee_id = p_user_id
      and exists (select 1 from contracts k where k.id = reviews.contract_id and k.client_id = p_user_id)
      and review_is_public(reviews.contract_id, reviews.reviewer_id, reviews.created_at)
  )
  select jsonb_build_object(
    'jobs_posted',    j.posted,
    'hires',          c.hires,
    'completed_jobs', c.completed,
    'late_cancellations', c.late_cancels,
    'reviews_count',  r.cnt,
    'avg_rating',     r.avg
  )
  from j, c, r;
$$;

create or replace function public.is_approved_provider(p_user_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from provider_profiles where user_id = p_user_id and status = 'approved');
$$;

create or replace function public.get_me()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v jsonb;
begin
  select jsonb_build_object(
    'id',          p.id,
    'full_name',   p.full_name,
    'phone',       u.phone,
    'active_role', p.active_role,
    'created_at',  p.created_at,
    'provider',    (select to_jsonb(pp) - 'user_id' from provider_profiles pp where pp.user_id = p.id)
  )
  into v
  from profiles p join auth.users u on u.id = p.id
  where p.id = v_uid;

  if v is null then
    if not exists (select 1 from auth.users where id = v_uid) then raise exception 'AUTH_REQUIRED'; end if;
    insert into profiles (id) values (v_uid) on conflict do nothing;
    return get_me();
  end if;
  return v;
end;
$$;

create or replace function public.set_my_name(p_full_name text)
returns void language plpgsql security definer set search_path = public as $$
declare v_name text := btrim(coalesce(p_full_name, ''));
begin
  if char_length(v_name) < 2 or char_length(v_name) > 60 then raise exception 'INVALID_NAME'; end if;
  update profiles set full_name = v_name where id = require_uid();
end;
$$;

create or replace function public.set_active_role(p_role text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_role not in ('client', 'provider') then raise exception 'INVALID_INPUT'; end if;
  update profiles set active_role = p_role where id = require_uid();
end;
$$;

create or replace function public.save_provider_profile(
  p_headline text, p_bio text, p_categories text[], p_districts text[], p_experience_years int
)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_status text;
begin
  if char_length(btrim(coalesce(p_headline, ''))) < 3 or char_length(btrim(p_headline)) > 80 then
    raise exception 'INVALID_HEADLINE';
  end if;
  if coalesce(cardinality(p_categories), 0) not between 1 and 3 then raise exception 'INVALID_CATEGORIES'; end if;
  if coalesce(cardinality(p_districts), 0) not between 1 and 12 then raise exception 'INVALID_DISTRICTS'; end if;
  if p_experience_years is null or p_experience_years not between 0 and 60 then raise exception 'INVALID_EXPERIENCE'; end if;
  if char_length(coalesce(p_bio, '')) > 1000 then raise exception 'INVALID_BIO'; end if;
  if _has_contact(p_headline) or _has_contact(p_bio) then raise exception 'CONTACT_NOT_ALLOWED'; end if;

  insert into provider_profiles (user_id, headline, bio, categories, districts, experience_years)
  values (v_uid, btrim(p_headline), btrim(coalesce(p_bio, '')), p_categories, p_districts, p_experience_years)
  on conflict (user_id) do update set
    headline         = excluded.headline,
    bio              = excluded.bio,
    categories       = excluded.categories,
    districts        = excluded.districts,
    experience_years = excluded.experience_years,
    status           = case when provider_profiles.status = 'rejected' then 'pending' else provider_profiles.status end,
    rejection_reason = case when provider_profiles.status = 'rejected' then null else provider_profiles.rejection_reason end
  returning status into v_status;

  return v_status;
end;
$$;

create or replace function public.get_provider_profile(p_user_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v jsonb;
begin
  select jsonb_build_object(
    'id',               p.id,
    'full_name',        p.full_name,
    'member_since',     p.created_at,
    'headline',         pp.headline,
    'bio',              pp.bio,
    'categories',       pp.categories,
    'districts',        pp.districts,
    'experience_years', pp.experience_years,
    'status',           pp.status,
    'stats',            provider_stats(p.id),
    'reviews', coalesce((
      select jsonb_agg(jsonb_build_object(
               'rating', r.rating, 'comment', r.comment, 'created_at', r.created_at,
               'reviewer_name', rp.full_name, 'job_title', j.title
             ) order by r.created_at desc)
      from (select * from reviews
            where reviewee_id = p.id
              and exists (select 1 from contracts k where k.id = reviews.contract_id and k.provider_id = p.id)
            order by created_at desc limit 30) r
      join profiles rp on rp.id = r.reviewer_id
      join contracts k on k.id = r.contract_id
      join jobs j on j.id = k.job_id
      where review_is_public(r.contract_id, r.reviewer_id, r.created_at)
    ), '[]'::jsonb)
  )
  into v
  from profiles p join provider_profiles pp on pp.user_id = p.id
  where p.id = p_user_id and (pp.status = 'approved' or p.id = v_uid);

  if v is null then raise exception 'NOT_FOUND'; end if;
  return v;
end;
$$;

create or replace function public.post_job(
  p_category text, p_district text, p_title text, p_description text,
  p_address text, p_budget int, p_urgency text
)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_id uuid;
begin
  if coalesce(btrim(p_category), '') = '' or coalesce(btrim(p_district), '') = '' then
    raise exception 'INVALID_INPUT';
  end if;
  if char_length(btrim(coalesce(p_title, ''))) not between 5 and 80 then raise exception 'INVALID_TITLE'; end if;
  if char_length(btrim(coalesce(p_description, ''))) not between 10 and 2000 then raise exception 'INVALID_DESCRIPTION'; end if;
  if char_length(btrim(coalesce(p_address, ''))) not between 5 and 300 then raise exception 'INVALID_ADDRESS'; end if;
  if p_budget is not null and p_budget not between 10000 and 100000000 then raise exception 'INVALID_PRICE'; end if;
  if coalesce(p_urgency, 'flexible') not in ('urgent', 'today', 'this_week', 'flexible') then raise exception 'INVALID_INPUT'; end if;
  if _has_contact(p_title) or _has_contact(p_description) then raise exception 'CONTACT_NOT_ALLOWED'; end if;

  insert into jobs (client_id, category, district, title, description, budget, urgency)
  values (v_uid, btrim(p_category), btrim(p_district), btrim(p_title), btrim(p_description),
          p_budget, coalesce(p_urgency, 'flexible'))
  returning id into v_id;

  insert into job_addresses (job_id, address) values (v_id, btrim(p_address));
  return v_id;
end;
$$;

create or replace function public.get_my_jobs()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := require_uid();
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', j.id, 'title', j.title, 'category', j.category, 'district', j.district,
      'budget', j.budget, 'urgency', j.urgency, 'status', j.status, 'created_at', j.created_at,
      'proposals_count', (select count(*) from proposals p where p.job_id = j.id and p.status = 'submitted'),
      'contract', (
        select jsonb_build_object('id', k.id, 'status', k.status, 'provider_name', pr.full_name, 'price', k.price)
        from contracts k join profiles pr on pr.id = k.provider_id
        where k.job_id = j.id order by k.created_at desc limit 1
      )
    ) order by j.created_at desc)
    from jobs j where j.client_id = v_uid
  ), '[]'::jsonb);
end;
$$;

create or replace function public.cancel_job(p_job_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_job jobs;
begin
  select * into v_job from jobs where id = p_job_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_job.client_id <> v_uid then raise exception 'NOT_ALLOWED'; end if;
  if v_job.status <> 'open' then raise exception 'JOB_NOT_OPEN'; end if;

  update jobs set status = 'cancelled', closed_at = now() where id = p_job_id;
  update proposals set status = 'closed', updated_at = now()
   where job_id = p_job_id and status = 'submitted';
end;
$$;

create or replace function public.get_job(p_job_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_job jobs;
  v_is_client boolean;
  v_contract contracts;
  v_is_party boolean;
  v_my_proposal jsonb;
begin
  select * into v_job from jobs where id = p_job_id;
  if not found then raise exception 'NOT_FOUND'; end if;

  v_is_client := v_job.client_id = v_uid;

  select * into v_contract from contracts
   where job_id = p_job_id and status <> 'cancelled'
   order by created_at desc limit 1;
  v_is_party := v_is_client or (v_contract.id is not null and v_contract.provider_id = v_uid);

  select jsonb_build_object('id', p.id, 'price', p.price, 'message', p.message,
                            'status', p.status, 'created_at', p.created_at)
    into v_my_proposal
    from proposals p where p.job_id = p_job_id and p.provider_id = v_uid;

  if not v_is_client and v_job.status <> 'open' and v_my_proposal is null then
    raise exception 'NOT_FOUND';
  end if;

  return jsonb_build_object(
    'id', v_job.id, 'title', v_job.title, 'description', v_job.description,
    'category', v_job.category, 'district', v_job.district, 'budget', v_job.budget,
    'urgency', v_job.urgency, 'status', v_job.status, 'created_at', v_job.created_at,
    'is_mine', v_is_client,
    'address', case when v_is_party then (select address from job_addresses where job_id = p_job_id) end,
    'proposals_count', (select count(*) from proposals p where p.job_id = p_job_id and p.status = 'submitted'),
    'client', (select jsonb_build_object('id', c.id, 'full_name', c.full_name, 'member_since', c.created_at,
                                         'stats', client_stats(c.id))
               from profiles c where c.id = v_job.client_id),
    'my_proposal', v_my_proposal,
    'contract', case when v_is_party and v_contract.id is not null
                     then jsonb_build_object('id', v_contract.id, 'status', v_contract.status) end
  );
end;
$$;

create or replace function public.get_job_proposals(p_job_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := require_uid();
begin
  if job_client_id(p_job_id) is distinct from v_uid then raise exception 'NOT_ALLOWED'; end if;

  -- Sifat bali: reyting (baho yo'q bo'lsa 4.0), bajarilgan ishlar, voz kechish va yutqazilgan nizolar
  -- jarimasi, kelish vaqti va narx. Kutilayotgan takliflar ichida eng yaxshi 3 tasi — "tavsiya".
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', x.id, 'price', x.price, 'message', x.message, 'status', x.status, 'created_at', x.created_at,
      'eta_minutes', x.eta_minutes, 'score', round(x.score),
      'recommended', x.status = 'submitted' and x.rank <= 3,
      'unread', (select count(*) from messages m where m.proposal_id = x.id and m.sender_id <> v_uid and m.read_at is null),
      'provider', x.provider,
      'team', (select jsonb_build_object('id', t.id, 'name', t.name, 'kind', t.kind, 'size', t.size,
                                         'stats', team_stats(t.id))
               from teams t where t.id = x.team_id)
    ) order by (x.status = 'submitted') desc, x.score desc, x.created_at asc)
    from (
      select y.*, rank() over (partition by y.status = 'submitted' order by y.score desc, y.created_at) as rank
      from (
        select p.id, p.price, p.message, p.status, p.created_at, p.eta_minutes, p.team_id,
          jsonb_build_object('id', pr.id, 'full_name', pr.full_name, 'headline', pp.headline,
                             'experience_years', pp.experience_years, 'stats', st.s) as provider,
          coalesce((st.s->>'avg_rating')::numeric, 4.0) * 20
            + least((st.s->>'completed_jobs')::int, 20) * 1.5
            - (st.s->>'withdrawals')::int * 10
            - (st.s->>'disputes_lost')::int * 15
            + (coalesce((st.s->>'on_time_rate')::numeric, 85) - 85) * 0.4
            + case when p.team_id is not null and (select crew_needed from jobs where id = p_job_id) then 15 else 0 end
            + case when p.eta_minutes is not null then greatest(0, 30 - p.eta_minutes / 2.0) else 0 end
            + 20.0 * min(p.price) filter (where p.status = 'submitted') over () / p.price
            as score
        from proposals p
        join profiles pr on pr.id = p.provider_id
        left join provider_profiles pp on pp.user_id = p.provider_id
        cross join lateral (select provider_stats(pr.id) as s) st
        where p.job_id = p_job_id and p.status in ('submitted', 'declined', 'accepted')
          and (p.status = 'accepted' or not _blocked(v_uid, p.provider_id))
      ) y
    ) x
  ), '[]'::jsonb);
end;
$$;

create or replace function public.decline_proposal(p_proposal_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_p proposals;
begin
  select * into v_p from proposals where id = p_proposal_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if job_client_id(v_p.job_id) <> v_uid then raise exception 'NOT_ALLOWED'; end if;
  if v_p.status <> 'submitted' then raise exception 'INVALID_STATE'; end if;
  update proposals set status = 'declined', updated_at = now() where id = p_proposal_id;
end;
$$;

create or replace function public.accept_proposal(p_proposal_id uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_p proposals;
  v_job jobs;
  v_contract_id uuid;
begin
  select * into v_p from proposals where id = p_proposal_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;

  select * into v_job from jobs where id = v_p.job_id for update;
  if v_job.client_id <> v_uid then raise exception 'NOT_ALLOWED'; end if;
  if v_job.status <> 'open' then raise exception 'JOB_NOT_OPEN'; end if;
  if v_p.status <> 'submitted' then raise exception 'INVALID_STATE'; end if;
  if not is_approved_provider(v_p.provider_id) then raise exception 'PROVIDER_NOT_AVAILABLE'; end if;
  if _blocked(v_uid, v_p.provider_id) then raise exception 'USER_BLOCKED'; end if;

  insert into contracts (job_id, proposal_id, client_id, provider_id, price, team_id)
  values (v_job.id, v_p.id, v_uid, v_p.provider_id, v_p.price, v_p.team_id)
  returning id into v_contract_id;

  update proposals set status = 'accepted', updated_at = now() where id = v_p.id;
  update proposals set status = 'closed', updated_at = now()
   where job_id = v_job.id and id <> v_p.id and status = 'submitted';
  update jobs set status = 'in_progress' where id = v_job.id;

  return v_contract_id;
end;
$$;

create or replace function public.find_jobs(
  p_category text default null, p_district text default null, p_search text default null,
  p_limit int default 30, p_offset int default 0
)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_q text := nullif(btrim(coalesce(p_search, '')), '');
begin
  return coalesce((
    select jsonb_agg(row_data order by created_at desc)
    from (
      select j.created_at, jsonb_build_object(
        'id', j.id, 'title', j.title, 'description', left(j.description, 240),
        'category', j.category, 'district', j.district, 'budget', j.budget,
        'urgency', j.urgency, 'created_at', j.created_at,
        'proposals_count', (select count(*) from proposals p where p.job_id = j.id and p.status = 'submitted'),
        'has_applied', exists (select 1 from proposals p where p.job_id = j.id and p.provider_id = v_uid),
        'client', jsonb_build_object('full_name', c.full_name, 'stats', client_stats(c.id))
      ) as row_data
      from jobs j join profiles c on c.id = j.client_id
      where j.status = 'open'
        and j.client_id <> v_uid
        and (p_category is null or j.category = p_category)
        and (p_district is null or j.district = p_district)
        and (v_q is null or j.title ilike '%' || v_q || '%' or j.description ilike '%' || v_q || '%')
      order by j.created_at desc
      limit least(greatest(coalesce(p_limit, 30), 1), 100)
      offset greatest(coalesce(p_offset, 0), 0)
    ) s
  ), '[]'::jsonb);
end;
$$;

-- p_eta_minutes — "qancha vaqtda yetib boraman" (shoshilinch e'lonlarda tavsiya tartibiga ta'sir qiladi)
drop function if exists public.submit_proposal(uuid, int, text);
drop function if exists public.submit_proposal(uuid, int, text, int);
-- p_as_team: brigada boshlig'i taklifni o'z brigadasi nomidan yuboradi
create or replace function public.submit_proposal(
  p_job_id uuid, p_price int, p_message text, p_eta_minutes int default null, p_as_team boolean default false
)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_job jobs;
  v_existing proposals;
  v_id uuid;
  v_team uuid;
begin
  if not is_approved_provider(v_uid) then raise exception 'NOT_APPROVED_PROVIDER'; end if;
  -- Oylik obuna: bepul davrdan keyin obunasiz usta oyiga cheklangan taklif yuboradi (pastda, "oylik obuna")
  perform _check_proposal_quota(v_uid);
  if p_price is null or p_price not between 10000 and 100000000 then raise exception 'INVALID_PRICE'; end if;
  if char_length(coalesce(p_message, '')) > 1000 then raise exception 'INVALID_MESSAGE'; end if;
  if _has_contact(p_message) then raise exception 'CONTACT_NOT_ALLOWED'; end if;
  if p_eta_minutes is not null and p_eta_minutes not between 5 and 600 then raise exception 'INVALID_INPUT'; end if;

  select * into v_job from jobs where id = p_job_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_job.client_id = v_uid then raise exception 'OWN_JOB'; end if;
  if v_job.status <> 'open' then raise exception 'JOB_NOT_OPEN'; end if;
  if _blocked(v_uid, v_job.client_id) then raise exception 'USER_BLOCKED'; end if;
  if coalesce(p_as_team, false) then
    select id into v_team from teams where owner_id = v_uid and status = 'approved';
    if v_team is null then raise exception 'TEAM_NOT_APPROVED'; end if;
  end if;

  select * into v_existing from proposals where job_id = p_job_id and provider_id = v_uid for update;
  if found then
    if v_existing.status <> 'withdrawn'
       or exists (select 1 from contracts k where k.proposal_id = v_existing.id) then
      raise exception 'ALREADY_APPLIED';
    end if;
    update proposals
       set price = p_price, message = btrim(coalesce(p_message, '')), status = 'submitted',
           eta_minutes = p_eta_minutes, team_id = v_team, created_at = now(), updated_at = now()
     where id = v_existing.id;
    return v_existing.id;
  end if;

  insert into proposals (job_id, provider_id, price, message, eta_minutes, team_id)
  values (p_job_id, v_uid, p_price, btrim(coalesce(p_message, '')), p_eta_minutes, v_team)
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.withdraw_proposal(p_proposal_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_p proposals;
begin
  select * into v_p from proposals where id = p_proposal_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_p.provider_id <> v_uid then raise exception 'NOT_ALLOWED'; end if;
  if v_p.status <> 'submitted' then raise exception 'INVALID_STATE'; end if;
  update proposals set status = 'withdrawn', updated_at = now() where id = p_proposal_id;
end;
$$;

create or replace function public.get_my_proposals()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := require_uid();
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', p.id, 'price', p.price, 'message', p.message, 'status', p.status, 'created_at', p.created_at,
      'job', jsonb_build_object('id', j.id, 'title', j.title, 'category', j.category,
                                'district', j.district, 'status', j.status),
      'contract_id', (select k.id from contracts k where k.proposal_id = p.id),
      'unread', (select count(*) from messages m where m.proposal_id = p.id and m.sender_id <> v_uid and m.read_at is null)
    ) order by p.updated_at desc)
    from proposals p join jobs j on j.id = p.job_id
    where p.provider_id = v_uid
  ), '[]'::jsonb);
end;
$$;

create or replace function public.get_my_contracts(p_role text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := require_uid();
begin
  if p_role not in ('client', 'provider') then raise exception 'INVALID_INPUT'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', k.id, 'status', k.status, 'price', k.price, 'created_at', k.created_at,
      'submitted_at', k.submitted_at, 'completed_at', k.completed_at,
      'job_title', j.title, 'job_category', j.category,
      'counterpart_name', o.full_name,
      'needs_my_review', k.status = 'completed'
                         and not exists (select 1 from reviews r where r.contract_id = k.id and r.reviewer_id = v_uid)
    ) order by k.created_at desc)
    from contracts k
    join jobs j on j.id = k.job_id
    join profiles o on o.id = case when p_role = 'client' then k.provider_id else k.client_id end
    where (p_role = 'client' and k.client_id = v_uid) or (p_role = 'provider' and k.provider_id = v_uid)
  ), '[]'::jsonb);
end;
$$;

create or replace function public.get_contract(p_contract_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_k contracts;
  v_role text;
  v_other uuid;
  v_my_review reviews;
  v_their_review reviews;
begin
  select * into v_k from contracts where id = p_contract_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_k.client_id = v_uid then v_role := 'client'; v_other := v_k.provider_id;
  elsif v_k.provider_id = v_uid then v_role := 'provider'; v_other := v_k.client_id;
  else raise exception 'NOT_FOUND';
  end if;

  select * into v_my_review from reviews where contract_id = v_k.id and reviewer_id = v_uid;
  select * into v_their_review from reviews where contract_id = v_k.id and reviewer_id = v_other;

  return jsonb_build_object(
    'id', v_k.id, 'status', v_k.status, 'price', v_k.price, 'my_role', v_role,
    'created_at', v_k.created_at, 'submitted_at', v_k.submitted_at, 'completed_at', v_k.completed_at,
    'cancelled_at', v_k.cancelled_at, 'cancelled_by', v_k.cancelled_by, 'cancel_reason', v_k.cancel_reason,
    'disputed_at', v_k.disputed_at, 'dispute_reason', v_k.dispute_reason,
    'dispute_resolution', v_k.dispute_resolution,
    -- Nizo jarayoni: ustaning javobi (72 soat), admin'ga o'tganmi, kelishuv takliflari, dalil rasmlari
    'dispute_amount', case when v_k.status = 'disputed' then _dispute_amount(v_k.id) end,
    'dispute_response', v_k.dispute_response, 'dispute_responded_at', v_k.dispute_responded_at,
    'dispute_response_due_at', case when v_k.status = 'disputed' and v_k.dispute_response is null
                                     and v_k.dispute_escalated_at is null
                                    then v_k.disputed_at + interval '72 hours' end,
    'dispute_escalated_at', v_k.dispute_escalated_at, 'dispute_escalated_by', v_k.dispute_escalated_by,
    'dispute_note', v_k.dispute_note,
    'payout_amount', v_k.payout_amount,
    'dispute_photos', case when v_k.disputed_at is not null then _dispute_photos(v_k.id) else '[]'::jsonb end,
    'dispute_offers', case when v_k.disputed_at is not null then coalesce((
        select jsonb_agg(jsonb_build_object('id', o.id, 'provider_amount', o.provider_amount, 'note', o.note,
                                            'status', o.status, 'by_me', o.proposed_by = v_uid,
                                            'created_at', o.created_at, 'decided_at', o.decided_at)
                         order by o.created_at)
        from dispute_offers o where o.contract_id = v_k.id and o.created_at >= v_k.disputed_at), '[]'::jsonb)
      else '[]'::jsonb end,
    'revisions', coalesce((
        select jsonb_agg(jsonb_build_object('stage_id', r.stage_id, 'reason', r.reason, 'created_at', r.created_at)
                         order by r.created_at)
        from revision_requests r where r.contract_id = v_k.id), '[]'::jsonb),
    'auto_approve_at', case when v_k.status = 'submitted' then v_k.submitted_at + interval '72 hours' end,
    'late_cancel', v_k.late_cancel,
    -- Kafolat davri: yakunlangandan 30 kun
    'warranty_until', case when v_k.status = 'completed' then v_k.completed_at + interval '30 days' end,
    'warranty_claims', coalesce((
        select jsonb_agg(jsonb_build_object('id', w.id, 'reason', w.reason, 'status', w.status,
                                            'provider_note', w.provider_note, 'created_at', w.created_at,
                                            'fixed_at', w.fixed_at, 'closed_at', w.closed_at,
                                            'respond_until', case when w.status = 'open' then w.created_at + interval '72 hours' end)
                         order by w.created_at)
        from warranty_claims w where w.contract_id = v_k.id), '[]'::jsonb),
    'team', (select jsonb_build_object('id', t.id, 'name', t.name, 'kind', t.kind) from teams t where t.id = v_k.team_id),
    'staged', v_k.staged,
    'stages', case when v_k.staged then _stages_json(v_k.id) else '[]'::jsonb end,
    'stage_plan', case when v_k.stage_plan is not null
                    then jsonb_build_object('stages', v_k.stage_plan, 'by_me', v_k.stage_plan_by = v_uid) end,
    'on_the_way_at', v_k.on_the_way_at, 'eta_at', v_k.eta_at,
    'arrived_at', v_k.arrived_at, 'started_at', v_k.started_at,
    'work_photos', _work_photos(v_k.id),
    'price_change', case when v_k.status in ('active', 'submitted') then (
        select jsonb_build_object('id', c.id, 'old_price', c.old_price, 'new_price', c.new_price,
                                  'reason', c.reason, 'created_at', c.created_at)
        from price_changes c where c.contract_id = v_k.id and c.status = 'pending') end,
    'price_history', coalesce((
        select jsonb_agg(jsonb_build_object('old_price', c.old_price, 'new_price', c.new_price, 'reason', c.reason,
                                            'status', c.status, 'created_at', c.created_at) order by c.created_at)
        from price_changes c where c.contract_id = v_k.id and c.status in ('approved', 'declined')), '[]'::jsonb),
    'payment_status', v_k.payment_status, 'payment_held_at', v_k.payment_held_at,
    'payment_released_at', v_k.payment_released_at, 'payment_refunded_at', v_k.payment_refunded_at,
    'job', (select jsonb_build_object('id', j.id, 'title', j.title, 'description', j.description,
                                      'category', j.category, 'district', j.district,
                                      'address', (select address from job_addresses a where a.job_id = j.id))
            from jobs j where j.id = v_k.job_id),
    'counterpart', (select jsonb_build_object(
                      'id', o.id, 'full_name', o.full_name,
                      'phone', case when v_k.status in ('active', 'submitted', 'disputed', 'completed')
                                    then (select phone from auth.users u where u.id = o.id) end)
                    from profiles o where o.id = v_other),
    'my_review', case when v_my_review.id is not null then
                   jsonb_build_object('rating', v_my_review.rating, 'comment', v_my_review.comment,
                                      'created_at', v_my_review.created_at) end,
    'their_review', case when v_their_review.id is not null
                          and review_is_public(v_their_review.contract_id, v_their_review.reviewer_id,
                                               v_their_review.created_at) then
                      jsonb_build_object('rating', v_their_review.rating, 'comment', v_their_review.comment,
                                         'created_at', v_their_review.created_at) end
  -- jsonb_build_object 100 tadan ortiq argument qabul qilmaydi — qolgani alohida
  ) || jsonb_build_object(
    'can_review', v_k.status = 'completed' and v_my_review.id is null and v_k.completed_at > now() - interval '14 days',
    'review_until', case when v_k.status = 'completed' then v_k.completed_at + interval '14 days' end,
    -- Nizo 2-bosqichi: admin murosa taklifi (72 soat) va arbitraj (rad etilgach admin yakuniy qaror chiqaradi)
    'mediation', case when v_k.mediation_at is not null and v_k.disputed_at is not null then jsonb_build_object(
        'provider_amount', v_k.mediation_amount, 'note', v_k.mediation_note, 'created_at', v_k.mediation_at,
        'respond_until', v_k.mediation_at + interval '72 hours',
        'client_ok', v_k.mediation_client_ok, 'provider_ok', v_k.mediation_provider_ok) end,
    'arbitration_at', v_k.arbitration_at
  );
end;
$$;

create or replace function public.submit_work(p_contract_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_k contracts;
begin
  select * into v_k from contracts where id = p_contract_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_k.provider_id <> v_uid then raise exception 'NOT_ALLOWED'; end if;
  if v_k.status <> 'active' then raise exception 'INVALID_STATE'; end if;
  update contracts set status = 'submitted', submitted_at = now() where id = p_contract_id;
end;
$$;

create or replace function public._complete_contract(p_contract_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_job_id uuid;
begin
  update contracts set status = 'completed', completed_at = now()
   where id = p_contract_id returning job_id into v_job_id;
  -- Javobsiz qolgan narx o'zgartirish so'rovi endi kuchini yo'qotadi
  update price_changes set status = 'cancelled', decided_at = now()
   where contract_id = p_contract_id and status = 'pending';
  update contract_stages set status = 'approved', approved_at = coalesce(approved_at, now())
   where contract_id = p_contract_id and status <> 'approved';
  update jobs set status = 'completed', closed_at = now() where id = v_job_id;
end;
$$;

create or replace function public.approve_work(p_contract_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_k contracts;
begin
  select * into v_k from contracts where id = p_contract_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_k.client_id <> v_uid then raise exception 'NOT_ALLOWED'; end if;
  if v_k.status not in ('active', 'submitted') then raise exception 'INVALID_STATE'; end if;
  perform _complete_contract(p_contract_id);
end;
$$;

create or replace function public.open_dispute(p_contract_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_k contracts;
begin
  if char_length(btrim(coalesce(p_reason, ''))) < 5 then raise exception 'REASON_REQUIRED'; end if;
  select * into v_k from contracts where id = p_contract_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_k.client_id <> v_uid then raise exception 'NOT_ALLOWED'; end if;
  if v_k.status not in ('active', 'submitted') then raise exception 'INVALID_STATE'; end if;
  -- Oldin yopilgan nizoning javobi va natijasi yangisiga o'tmaydi
  update contracts
     set status = 'disputed', disputed_at = now(), dispute_reason = left(btrim(p_reason), 1000),
         dispute_response = null, dispute_responded_at = null, dispute_escalated_at = null,
         dispute_escalated_by = null, dispute_note = null, dispute_resolution = null, resolved_at = null,
         mediation_amount = null, mediation_note = null, mediation_at = null, mediation_client_ok = null,
         mediation_provider_ok = null, arbitration_at = null
   where id = p_contract_id;
end;
$$;

create or replace function public.withdraw_from_contract(p_contract_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_k contracts;
begin
  if char_length(btrim(coalesce(p_reason, ''))) < 5 then raise exception 'REASON_REQUIRED'; end if;
  select * into v_k from contracts where id = p_contract_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_k.provider_id <> v_uid then raise exception 'NOT_ALLOWED'; end if;
  if v_k.status <> 'active' then raise exception 'INVALID_STATE'; end if;

  update contracts
     set status = 'cancelled', cancelled_at = now(), cancelled_by = 'provider',
         cancel_reason = left(btrim(p_reason), 1000)
   where id = p_contract_id;
  update proposals set status = 'withdrawn', updated_at = now() where id = v_k.proposal_id;
  update proposals set status = 'submitted', updated_at = now()
   where job_id = v_k.job_id and status = 'closed';
  update jobs set status = 'open' where id = v_k.job_id;
end;
$$;

create or replace function public.leave_review(p_contract_id uuid, p_rating int, p_comment text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_k contracts;
  v_reviewee uuid;
begin
  if p_rating is null or p_rating not between 1 and 5 then raise exception 'INVALID_RATING'; end if;
  if char_length(coalesce(p_comment, '')) > 1000 then raise exception 'INVALID_MESSAGE'; end if;
  select * into v_k from contracts where id = p_contract_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_k.client_id = v_uid then v_reviewee := v_k.provider_id;
  elsif v_k.provider_id = v_uid then v_reviewee := v_k.client_id;
  else raise exception 'NOT_ALLOWED';
  end if;
  if v_k.status <> 'completed' then raise exception 'INVALID_STATE'; end if;
  -- Baholash muddati — yakunlangandan 14 kun (Upwork)
  if v_k.completed_at < now() - interval '14 days' then raise exception 'REVIEW_WINDOW_CLOSED'; end if;

  insert into reviews (contract_id, reviewer_id, reviewee_id, rating, comment)
  values (p_contract_id, v_uid, v_reviewee, p_rating, btrim(coalesce(p_comment, '')))
  on conflict (contract_id, reviewer_id) do nothing;
  if not found then raise exception 'ALREADY_REVIEWED'; end if;
end;
$$;

create or replace function public.admin_review_provider(p_user_id uuid, p_approve boolean, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  update provider_profiles
     set status = case when p_approve then 'approved' else 'rejected' end,
         rejection_reason = case when p_approve then null else p_reason end,
         reviewed_at = now()
   where user_id = p_user_id;
  if not found then raise exception 'NOT_FOUND'; end if;
end;
$$;

create or replace function public.admin_resolve_dispute(p_contract_id uuid, p_winner text)
returns void language plpgsql security definer set search_path = public as $$
declare v_k contracts;
begin
  if p_winner not in ('provider', 'client') then raise exception 'INVALID_INPUT'; end if;
  select * into v_k from contracts where id = p_contract_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_k.status <> 'disputed' then raise exception 'INVALID_STATE'; end if;

  update contracts set dispute_resolution = p_winner, resolved_at = now() where id = p_contract_id;
  if p_winner = 'provider' then
    perform _complete_contract(p_contract_id);
  else
    update contracts set status = 'cancelled', cancelled_at = now(), cancelled_by = 'admin'
     where id = p_contract_id;
    update jobs set status = 'cancelled', closed_at = now() where id = v_k.job_id;
  end if;
end;
$$;

create or replace function public.auto_approve_overdue()
returns int language plpgsql security definer set search_path = public as $$
declare
  r record;
  n int := 0;
begin
  for r in select id from contracts where status = 'submitted' and submitted_at < now() - interval '72 hours'
  loop
    perform _complete_contract(r.id);
    n := n + 1;
  end loop;
  return n;
end;
$$;

revoke execute on all functions in schema public from public, anon, authenticated;

grant execute on function
  public.get_me(),
  public.set_my_name(text),
  public.set_active_role(text),
  public.save_provider_profile(text, text, text[], text[], int),
  public.get_provider_profile(uuid),
  public.post_job(text, text, text, text, text, int, text),
  public.get_my_jobs(),
  public.cancel_job(uuid),
  public.get_job(uuid),
  public.get_job_proposals(uuid),
  public.decline_proposal(uuid),
  public.accept_proposal(uuid),
  public.find_jobs(text, text, text, int, int),
  public.submit_proposal(uuid, int, text, int, boolean),
  public.withdraw_proposal(uuid),
  public.get_my_proposals(),
  public.get_my_contracts(text),
  public.get_contract(uuid),
  public.submit_work(uuid),
  public.approve_work(uuid),
  public.open_dispute(uuid, text),
  public.withdraw_from_contract(uuid, text),
  public.leave_review(uuid, int, text),
  public.job_client_id(uuid)
to authenticated;


-- ===== chat.sql =====
create table if not exists public.messages (
  id          uuid primary key default gen_random_uuid(),
  contract_id uuid not null references public.contracts (id) on delete cascade,
  sender_id   uuid not null references public.users (id) on delete cascade,
  text        text not null check (char_length(text) between 1 and 1000),
  created_at  timestamptz not null default now(),
  read_at     timestamptz
);

create index if not exists messages_contract_idx on public.messages (contract_id, created_at asc);

alter table public.messages enable row level security;

revoke all on public.messages from anon, authenticated;

grant select on public.messages to authenticated;

drop policy if exists messages_select on public.messages;

create policy messages_select on public.messages
  for select to authenticated using (
    exists (
      select 1 from public.contracts k
      where k.id = messages.contract_id
        and (k.client_id = auth.uid() or k.provider_id = auth.uid())
    )
  );

create or replace function public.send_message(p_contract_id uuid, p_text text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_k contracts;
  v_text text := btrim(coalesce(p_text, ''));
  v_id uuid;
  v_created timestamptz;
begin
  if char_length(v_text) < 1 or char_length(v_text) > 1000 then raise exception 'INVALID_MESSAGE'; end if;

  select * into v_k from contracts where id = p_contract_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_k.client_id <> v_uid and v_k.provider_id <> v_uid then raise exception 'NOT_ALLOWED'; end if;
  if _blocked(v_k.client_id, v_k.provider_id) then raise exception 'USER_BLOCKED'; end if;

  insert into messages (contract_id, sender_id, text)
  values (p_contract_id, v_uid, v_text)
  returning id, created_at into v_id, v_created;

  return jsonb_build_object(
    'id', v_id, 'sender_id', v_uid, 'text', v_text, 'created_at', v_created, 'read_at', null
  );
end;
$$;

-- p_after berilsa faqat shu vaqtdan keyingi xabarlar (chat har necha soniyada faqat yangilarini oladi).
-- Eski ilova versiyalari p_after'siz chaqiradi — butun yozishma qaytadi.
drop function if exists public.get_messages(uuid);
create or replace function public.get_messages(p_contract_id uuid, p_after timestamptz default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_k contracts;
begin
  select * into v_k from contracts where id = p_contract_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_k.client_id <> v_uid and v_k.provider_id <> v_uid then raise exception 'NOT_ALLOWED'; end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', m.id, 'sender_id', m.sender_id, 'text', m.text,
      'created_at', m.created_at, 'read_at', m.read_at, 'kind', m.kind, 'agreement_id', m.agreement_id
    ) order by m.created_at asc)
    from messages m
    where (m.contract_id = p_contract_id or (v_k.proposal_id is not null and m.proposal_id = v_k.proposal_id))
      and (p_after is null or m.created_at > p_after)
  ), '[]'::jsonb);
end;
$$;

create or replace function public.mark_messages_read(p_contract_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_k contracts;
begin
  select * into v_k from contracts where id = p_contract_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_k.client_id <> v_uid and v_k.provider_id <> v_uid then raise exception 'NOT_ALLOWED'; end if;

  update messages set read_at = now()
   where (contract_id = p_contract_id or (v_k.proposal_id is not null and proposal_id = v_k.proposal_id))
     and sender_id <> v_uid and read_at is null;
end;
$$;

create or replace function public.get_my_contracts(p_role text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := require_uid();
begin
  if p_role not in ('client', 'provider') then raise exception 'INVALID_INPUT'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', k.id, 'status', k.status, 'price', k.price, 'created_at', k.created_at,
      'submitted_at', k.submitted_at, 'completed_at', k.completed_at,
      'job_title', j.title, 'job_category', j.category,
      'counterpart_name', o.full_name,
      'needs_my_review', k.status = 'completed' and k.completed_at > now() - interval '14 days'
                         and not exists (select 1 from reviews r where r.contract_id = k.id and r.reviewer_id = v_uid),
      'unread_count', (
        select count(*) from messages m
        where m.contract_id = k.id and m.sender_id <> v_uid and m.read_at is null
      )
    ) order by k.created_at desc)
    from contracts k
    join jobs j on j.id = k.job_id
    join profiles o on o.id = case when p_role = 'client' then k.provider_id else k.client_id end
    where (p_role = 'client' and k.client_id = v_uid) or (p_role = 'provider' and k.provider_id = v_uid)
  ), '[]'::jsonb);
end;
$$;

revoke execute on function
  public.send_message(uuid, text),
  public.get_messages(uuid, timestamptz),
  public.mark_messages_read(uuid)
from public, anon, authenticated;

grant execute on function
  public.send_message(uuid, text),
  public.get_messages(uuid, timestamptz),
  public.mark_messages_read(uuid)
to authenticated;


-- ===== storage.sql =====
create or replace function public.set_avatar_uploaded()
returns void language plpgsql security definer set search_path = public as $$
begin
  update profiles set avatar_updated_at = now() where id = require_uid();
end;
$$;

revoke execute on function public.set_avatar_uploaded() from public, anon, authenticated;

grant execute on function public.set_avatar_uploaded() to authenticated;

create or replace function public.get_me()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v jsonb;
begin
  select jsonb_build_object(
    'id',                p.id,
    'full_name',         p.full_name,
    'phone',             u.phone,
    'active_role',       p.active_role,
    'created_at',        p.created_at,
    'avatar_updated_at', p.avatar_updated_at,
    'provider',          (select to_jsonb(pp) - 'user_id' from provider_profiles pp where pp.user_id = p.id)
  )
  into v
  from profiles p join auth.users u on u.id = p.id
  where p.id = v_uid;

  if v is null then
    if not exists (select 1 from auth.users where id = v_uid) then raise exception 'AUTH_REQUIRED'; end if;
    insert into profiles (id) values (v_uid) on conflict do nothing;
    return get_me();
  end if;
  return v;
end;
$$;

create or replace function public.get_provider_profile(p_user_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v jsonb;
begin
  select jsonb_build_object(
    'id',                p.id,
    'full_name',         p.full_name,
    'member_since',      p.created_at,
    'avatar_updated_at', p.avatar_updated_at,
    'headline',          pp.headline,
    'bio',               pp.bio,
    'categories',        pp.categories,
    'districts',         pp.districts,
    'experience_years',  pp.experience_years,
    'status',            pp.status,
    'stats',             provider_stats(p.id),
    'reviews', coalesce((
      select jsonb_agg(jsonb_build_object(
               'rating', r.rating, 'comment', r.comment, 'created_at', r.created_at,
               'reviewer_name', rp.full_name, 'job_title', j.title
             ) order by r.created_at desc)
      from (select * from reviews
            where reviewee_id = p.id
              and exists (select 1 from contracts k where k.id = reviews.contract_id and k.provider_id = p.id)
            order by created_at desc limit 30) r
      join profiles rp on rp.id = r.reviewer_id
      join contracts k on k.id = r.contract_id
      join jobs j on j.id = k.job_id
      where review_is_public(r.contract_id, r.reviewer_id, r.created_at)
    ), '[]'::jsonb)
  )
  into v
  from profiles p join provider_profiles pp on pp.user_id = p.id
  where p.id = p_user_id and (pp.status = 'approved' or p.id = v_uid);

  if v is null then raise exception 'NOT_FOUND'; end if;
  return v;
end;
$$;


-- ===== photos.sql =====
alter table public.jobs add column if not exists has_photo boolean not null default false;

create or replace function public.safe_uuid(p text)
returns uuid language plpgsql immutable as $$
begin
  return p::uuid;
exception when others then
  return null;
end;
$$;

grant execute on function public.safe_uuid(text) to authenticated, anon;

create or replace function public.set_job_photo_uploaded(p_job_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := require_uid();
begin
  if job_client_id(p_job_id) <> v_uid then raise exception 'NOT_ALLOWED'; end if;
  update jobs set has_photo = exists (select 1 from files where bucket = 'job-photos' and path = p_job_id::text || '/photo.jpg')
   where id = p_job_id;
end;
$$;

revoke execute on function public.set_job_photo_uploaded(uuid) from public, anon, authenticated;

grant execute on function public.set_job_photo_uploaded(uuid) to authenticated;

create or replace function public.get_job(p_job_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_job jobs;
  v_is_client boolean;
  v_contract contracts;
  v_is_party boolean;
  v_my_proposal jsonb;
begin
  select * into v_job from jobs where id = p_job_id;
  if not found then raise exception 'NOT_FOUND'; end if;

  v_is_client := v_job.client_id = v_uid;

  select * into v_contract from contracts
   where job_id = p_job_id and status <> 'cancelled'
   order by created_at desc limit 1;
  v_is_party := v_is_client or (v_contract.id is not null and v_contract.provider_id = v_uid);

  select jsonb_build_object('id', p.id, 'price', p.price, 'message', p.message,
                            'status', p.status, 'created_at', p.created_at)
    into v_my_proposal
    from proposals p where p.job_id = p_job_id and p.provider_id = v_uid;

  if not v_is_client and v_job.status <> 'open' and v_my_proposal is null then
    raise exception 'NOT_FOUND';
  end if;

  return jsonb_build_object(
    'id', v_job.id, 'title', v_job.title, 'description', v_job.description,
    'category', v_job.category, 'district', v_job.district, 'budget', v_job.budget,
    'urgency', v_job.urgency, 'status', v_job.status, 'created_at', v_job.created_at,
    'has_photo', v_job.has_photo,
    'photos', _job_photos(v_job.id),
    'is_mine', v_is_client,
    'address', case when v_is_party then (select address from job_addresses where job_id = p_job_id) end,
    'proposals_count', (select count(*) from proposals p where p.job_id = p_job_id and p.status = 'submitted'),
    'client', (select jsonb_build_object('id', c.id, 'full_name', c.full_name, 'member_since', c.created_at,
                                         'stats', client_stats(c.id))
               from profiles c where c.id = v_job.client_id),
    'my_proposal', v_my_proposal,
    'contract', case when v_is_party and v_contract.id is not null
                     then jsonb_build_object('id', v_contract.id, 'status', v_contract.status) end
  );
end;
$$;

create or replace function public.get_my_jobs()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := require_uid();
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', j.id, 'title', j.title, 'category', j.category, 'district', j.district,
      'budget', j.budget, 'urgency', j.urgency, 'status', j.status, 'created_at', j.created_at,
      'has_photo', j.has_photo,
      'proposals_count', (select count(*) from proposals p where p.job_id = j.id and p.status = 'submitted'),
      'contract', (
        select jsonb_build_object('id', k.id, 'status', k.status, 'provider_name', pr.full_name, 'price', k.price)
        from contracts k join profiles pr on pr.id = k.provider_id
        where k.job_id = j.id order by k.created_at desc limit 1
      )
    ) order by j.created_at desc)
    from jobs j where j.client_id = v_uid
  ), '[]'::jsonb);
end;
$$;

create or replace function public.find_jobs(
  p_category text default null, p_district text default null, p_search text default null,
  p_limit int default 30, p_offset int default 0
)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_q text := nullif(btrim(coalesce(p_search, '')), '');
begin
  return coalesce((
    select jsonb_agg(row_data order by created_at desc)
    from (
      select j.created_at, jsonb_build_object(
        'id', j.id, 'title', j.title, 'description', left(j.description, 240),
        'category', j.category, 'district', j.district, 'budget', j.budget,
        'urgency', j.urgency, 'created_at', j.created_at, 'has_photo', j.has_photo,
        'proposals_count', (select count(*) from proposals p where p.job_id = j.id and p.status = 'submitted'),
        'has_applied', exists (select 1 from proposals p where p.job_id = j.id and p.provider_id = v_uid),
        'client', jsonb_build_object('full_name', c.full_name, 'stats', client_stats(c.id))
      ) as row_data
      from jobs j join profiles c on c.id = j.client_id
      where j.status = 'open'
        and j.client_id <> v_uid
        and (p_category is null or j.category = p_category)
        and (p_district is null or j.district = p_district)
        and (v_q is null or j.title ilike '%' || v_q || '%' or j.description ilike '%' || v_q || '%')
      order by j.created_at desc
      limit least(greatest(coalesce(p_limit, 30), 1), 100)
      offset greatest(coalesce(p_offset, 0), 0)
    ) s
  ), '[]'::jsonb);
end;
$$;


-- ===== favorites.sql =====
create table if not exists public.favorites (
  client_id   uuid not null references public.users (id) on delete cascade,
  provider_id uuid not null references public.users (id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (client_id, provider_id)
);

create index if not exists favorites_client_idx on public.favorites (client_id, created_at desc);

create table if not exists public.job_invites (
  id          uuid primary key default gen_random_uuid(),
  job_id      uuid not null references public.jobs (id) on delete cascade,
  provider_id uuid not null references public.users (id) on delete cascade,
  client_id   uuid not null references public.users (id) on delete cascade,
  created_at  timestamptz not null default now(),
  unique (job_id, provider_id)
);

create index if not exists job_invites_provider_idx on public.job_invites (provider_id, created_at desc);

create index if not exists job_invites_job_idx on public.job_invites (job_id);

alter table public.favorites   enable row level security;

alter table public.job_invites enable row level security;

create or replace function public.add_favorite(p_provider_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := require_uid();
begin
  if p_provider_id = v_uid then raise exception 'INVALID_INPUT'; end if;
  if not is_approved_provider(p_provider_id) then raise exception 'NOT_FOUND'; end if;
  insert into favorites (client_id, provider_id) values (v_uid, p_provider_id)
  on conflict (client_id, provider_id) do nothing;
end;
$$;

create or replace function public.remove_favorite(p_provider_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from favorites where client_id = require_uid() and provider_id = p_provider_id;
end;
$$;

create or replace function public.get_favorites()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := require_uid();
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', p.id, 'full_name', p.full_name, 'avatar_updated_at', p.avatar_updated_at,
      'headline', pp.headline, 'categories', pp.categories, 'districts', pp.districts,
      'experience_years', pp.experience_years, 'stats', provider_stats(p.id)
    ) order by f.created_at desc)
    from favorites f
    join profiles p on p.id = f.provider_id
    join provider_profiles pp on pp.user_id = f.provider_id
    where f.client_id = v_uid
  ), '[]'::jsonb);
end;
$$;

create or replace function public.invite_provider(p_job_id uuid, p_provider_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_job jobs;
begin
  select * into v_job from jobs where id = p_job_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_job.client_id <> v_uid then raise exception 'NOT_ALLOWED'; end if;
  if v_job.status <> 'open' then raise exception 'JOB_NOT_OPEN'; end if;
  if not is_approved_provider(p_provider_id) then raise exception 'NOT_APPROVED_PROVIDER'; end if;
  if _blocked(v_uid, p_provider_id) then raise exception 'USER_BLOCKED'; end if;

  insert into job_invites (job_id, provider_id, client_id) values (p_job_id, p_provider_id, v_uid)
  on conflict (job_id, provider_id) do nothing;
end;
$$;

create or replace function public.get_job_invites(p_job_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := require_uid();
begin
  if job_client_id(p_job_id) <> v_uid then raise exception 'NOT_ALLOWED'; end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', pr.id, 'full_name', pr.full_name, 'headline', pp.headline, 'invited_at', i.created_at,
      'has_applied', exists (select 1 from proposals p where p.job_id = i.job_id and p.provider_id = i.provider_id)
    ) order by i.created_at desc)
    from job_invites i
    join profiles pr on pr.id = i.provider_id
    left join provider_profiles pp on pp.user_id = i.provider_id
    where i.job_id = p_job_id
  ), '[]'::jsonb);
end;
$$;

create or replace function public.get_invited_jobs()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := require_uid();
begin
  return coalesce((
    select jsonb_agg(row_data order by invited_at desc)
    from (
      select i.created_at as invited_at, jsonb_build_object(
        'id', j.id, 'title', j.title, 'description', left(j.description, 240),
        'category', j.category, 'district', j.district, 'budget', j.budget,
        'budget_max', (select d.budget_max from job_details d where d.job_id = j.id and d.budget_type = 'range'),
        'urgency', j.urgency, 'created_at', j.created_at, 'has_photo', j.has_photo,
        'proposals_count', (select count(*) from proposals p where p.job_id = j.id and p.status = 'submitted'),
        'has_applied', exists (select 1 from proposals p where p.job_id = j.id and p.provider_id = v_uid),
        'client', jsonb_build_object('full_name', c.full_name, 'stats', client_stats(c.id)),
        'invited_at', i.created_at
      ) as row_data
      from job_invites i
      join jobs j on j.id = i.job_id
      join profiles c on c.id = j.client_id
      where i.provider_id = v_uid and j.status = 'open'
    ) s
  ), '[]'::jsonb);
end;
$$;

create or replace function public.get_provider_profile(p_user_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v jsonb;
begin
  select jsonb_build_object(
    'id',                p.id,
    'full_name',         p.full_name,
    'member_since',      p.created_at,
    'avatar_updated_at', p.avatar_updated_at,
    'headline',          pp.headline,
    'bio',               pp.bio,
    'categories',        pp.categories,
    'districts',         pp.districts,
    'experience_years',  pp.experience_years,
    'status',            pp.status,
    'is_favorite',       exists (select 1 from favorites where client_id = v_uid and provider_id = p.id),
    'stats',             provider_stats(p.id),
    'reviews', coalesce((
      select jsonb_agg(jsonb_build_object(
               'rating', r.rating, 'comment', r.comment, 'created_at', r.created_at,
               'reviewer_name', rp.full_name, 'job_title', j.title
             ) order by r.created_at desc)
      from (select * from reviews
            where reviewee_id = p.id
              and exists (select 1 from contracts k where k.id = reviews.contract_id and k.provider_id = p.id)
            order by created_at desc limit 30) r
      join profiles rp on rp.id = r.reviewer_id
      join contracts k on k.id = r.contract_id
      join jobs j on j.id = k.job_id
      where review_is_public(r.contract_id, r.reviewer_id, r.created_at)
    ), '[]'::jsonb)
  )
  into v
  from profiles p join provider_profiles pp on pp.user_id = p.id
  where p.id = p_user_id and (pp.status = 'approved' or p.id = v_uid);

  if v is null then raise exception 'NOT_FOUND'; end if;
  return v;
end;
$$;

revoke execute on function
  public.add_favorite(uuid), public.remove_favorite(uuid), public.get_favorites(),
  public.invite_provider(uuid, uuid), public.get_job_invites(uuid), public.get_invited_jobs()
  from public, anon, authenticated;

grant execute on function
  public.add_favorite(uuid), public.remove_favorite(uuid), public.get_favorites(),
  public.invite_provider(uuid, uuid), public.get_job_invites(uuid), public.get_invited_jobs()
  to authenticated;


-- ===== notifications.sql =====
create table if not exists public.app_secrets (
  id                       int primary key default 1 check (id = 1),
  telegram_bot_token       text,
  telegram_bot_username    text,
  telegram_last_update_id  bigint not null default 0
);

insert into public.app_secrets (id) values (1) on conflict (id) do nothing;

alter table public.app_secrets enable row level security;

create table if not exists public.notification_outbox (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references public.users (id) on delete cascade,
  message    text not null,
  created_at timestamptz not null default now(),
  sent_at    timestamptz
);

create index if not exists notification_outbox_pending_idx
  on public.notification_outbox (created_at) where sent_at is null;

-- Bildirishnoma bosilganda ilovada ochiladigan sahifa (expo-router yo'li, masalan /chat/<id>)
alter table public.notification_outbox add column if not exists link text;

-- Telefonga (push) yuborilishi Telegram'dan alohida kuzatiladi: sent_at — Telegram, push_sent_at — push
do $$ begin
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'notification_outbox'
                   and column_name = 'push_sent_at') then
    alter table public.notification_outbox add column push_sent_at timestamptz;
    -- Push qo'shilishidan oldingi eski xabarlar telefonga yuborilmaydi
    update public.notification_outbox set push_sent_at = now();
  end if;
end $$;

create index if not exists notification_outbox_push_pending_idx
  on public.notification_outbox (id) where push_sent_at is null;

-- Telefonlarning Expo push tokenlari (bitta foydalanuvchida bir nechta qurilma bo'lishi mumkin)
create table if not exists public.push_tokens (
  token      text primary key,
  user_id    uuid not null references public.users (id) on delete cascade,
  platform   text not null check (platform in ('android', 'ios')),
  updated_at timestamptz not null default now()
);

create index if not exists push_tokens_user_idx on public.push_tokens (user_id);

alter table public.push_tokens enable row level security;

-- Ilova kirgandan keyin chaqiradi. Qurilmada boshqa hisobga kirilgan bo'lsa token yangi egasiga o'tadi.
create or replace function public.register_push_token(p_token text, p_platform text)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := require_uid();
begin
  if p_token is null or p_token !~ '^Expo(nent)?PushToken\[[A-Za-z0-9_-]{10,}\]$'
     or p_platform is null or p_platform not in ('android', 'ios') then
    raise exception 'INVALID_INPUT';
  end if;
  insert into push_tokens (token, user_id, platform) values (p_token, v_uid, p_platform)
  on conflict (token) do update set user_id = excluded.user_id, platform = excluded.platform, updated_at = now();
end;
$$;

-- Hisobdan chiqishda: bu telefonga boshqa bildirishnoma kelmaydi
create or replace function public.unregister_push_token(p_token text)
returns void language sql security definer set search_path = public as $$
  delete from push_tokens where token = p_token and user_id = require_uid();
$$;

alter table public.notification_outbox enable row level security;

create or replace function public.get_telegram_link()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_code text;
  v_username text;
begin
  select telegram_bot_username into v_username from app_secrets where id = 1;
  select telegram_link_code into v_code from profiles where id = v_uid;
  if v_code is null then
    v_code := encode(gen_random_bytes(16), 'hex');
    update profiles set telegram_link_code = v_code where id = v_uid;
  end if;
  return jsonb_build_object('code', v_code, 'bot_username', v_username);
end;
$$;

create or replace function public.unlink_telegram()
returns void language plpgsql security definer set search_path = public as $$
begin
  update profiles set telegram_chat_id = null where id = require_uid();
  update users set telegram_login_chat_id = null where id = require_uid(); -- uzilgan Telegram bir bosishda kira olmaydi
end;
$$;

drop function if exists public.queue_notification(uuid, text);
create or replace function public.queue_notification(p_user_id uuid, p_message text, p_link text default null)
returns void language sql security definer set search_path = public as $$
  insert into notification_outbox (user_id, message, link) values (p_user_id, p_message, p_link);
$$;

create or replace function public.notify_new_proposal()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_client_id uuid; v_job_title text; v_provider_name text;
begin
  select client_id, title into v_client_id, v_job_title from jobs where id = new.job_id;
  select full_name into v_provider_name from profiles where id = new.provider_id;
  perform queue_notification(v_client_id, format(
    E'\U0001F514 "%s" e''loningizga yangi taklif keldi.\n%s', v_job_title, v_provider_name),
    '/job/' || new.job_id);
  return new;
end;
$$;

drop trigger if exists trg_notify_new_proposal on public.proposals;

create trigger trg_notify_new_proposal after insert on public.proposals
for each row execute function public.notify_new_proposal();

create or replace function public.notify_proposal_accepted()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_job_title text;
begin
  if new.status = 'accepted' and old.status is distinct from 'accepted' then
    select title into v_job_title from jobs where id = new.job_id;
    perform queue_notification(new.provider_id, format(
      E'✅ Tabriklaymiz! "%s" e''longa taklifingiz qabul qilindi.', v_job_title),
      '/job/' || new.job_id);
  end if;
  return new;
end;
$$;

drop trigger if exists trg_notify_proposal_accepted on public.proposals;

create trigger trg_notify_proposal_accepted after update on public.proposals
for each row execute function public.notify_proposal_accepted();

create or replace function public.notify_job_invite()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_job_title text; v_client_name text;
begin
  select title into v_job_title from jobs where id = new.job_id;
  select full_name into v_client_name from profiles where id = new.client_id;
  perform queue_notification(new.provider_id, format(
    E'⭐ %s sizni "%s" e''loniga shaxsan taklif qildi.', v_client_name, v_job_title),
    '/job/' || new.job_id);
  return new;
end;
$$;

drop trigger if exists trg_notify_job_invite on public.job_invites;

create trigger trg_notify_job_invite after insert on public.job_invites
for each row execute function public.notify_job_invite();

create or replace function public.notify_new_message()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_recipient uuid; v_sender_name text;
begin
  select case when client_id = new.sender_id then provider_id else client_id end
    into v_recipient from contracts where id = new.contract_id;
  select full_name into v_sender_name from profiles where id = new.sender_id;
  perform queue_notification(v_recipient, format(E'\U0001F4AC %s: %s', v_sender_name, left(new.text, 200)),
    '/chat/' || new.contract_id);
  return new;
end;
$$;

drop trigger if exists trg_notify_new_message on public.messages;

create trigger trg_notify_new_message after insert on public.messages
for each row execute function public.notify_new_message();

create or replace function public.notify_contract_status()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_job_title text; v_msg text; v_recipient uuid;
begin
  if new.status is not distinct from old.status then return new; end if;
  -- Nizo yopilishi (kelishuv, admin qarori, mijoz nizoni qaytarib olishi) haqida o'sha funksiyalar
  -- summalari bilan xabar beradi
  if old.status = 'disputed' then return new; end if;
  select title into v_job_title from jobs where id = new.job_id;

  if new.status = 'submitted' then
    v_recipient := new.client_id;
    v_msg := format(E'\U0001F4E6 Usta "%s" ishini tugatdi deb belgiladi. 72 soat ichida ishni qabul qiling yoki e''tiroz bildiring — javob bo''lmasa, ish avtomatik qabul qilinadi.', v_job_title);
  elsif new.status = 'completed' then
    v_recipient := new.provider_id;
    v_msg := format(E'\U0001F389 "%s" shartnomasi yakunlandi.', v_job_title);
    -- Mijoz ham bilsin (ayniqsa 72 soatdan keyin avtomatik qabul qilinganda) va ustani baholasin
    perform queue_notification(new.client_id,
      format(E'✅ "%s" ishi yakunlandi. Ilovada ustani baholashni unutmang.', v_job_title),
      '/contract/' || new.id);
  elsif new.status = 'disputed' then
    v_recipient := new.provider_id;
    v_msg := format(E'⚠️ Mijoz "%s" shartnomasi bo''yicha nizo ochdi. Sabab: %s. 72 soat ichida javob bering — aks holda nizo admin''ga o''tadi.',
                    v_job_title, new.dispute_reason);
  elsif new.status = 'cancelled' then
    if new.cancelled_by = 'provider' then
      v_recipient := new.client_id;
      v_msg := format(E'⚠️ Usta "%s" ishidan voz kechdi. Sabab: %s', v_job_title, new.cancel_reason);
    elsif new.cancelled_by = 'admin' then
      v_recipient := new.provider_id;
      v_msg := format(E'⚠️ "%s" shartnomasi bo''yicha nizo admin tomonidan mijoz foydasiga hal qilindi.', v_job_title);
    end if;
  end if;

  if v_recipient is not null then perform queue_notification(v_recipient, v_msg, '/contract/' || new.id); end if;
  return new;
end;
$$;

drop trigger if exists trg_notify_contract_status on public.contracts;

create trigger trg_notify_contract_status after update on public.contracts
for each row execute function public.notify_contract_status();

create or replace function public.get_me()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v jsonb;
begin
  select jsonb_build_object(
    'id',                p.id,
    'full_name',         p.full_name,
    'phone',             u.phone,
    'active_role',       p.active_role,
    'created_at',        p.created_at,
    'avatar_updated_at', p.avatar_updated_at,
    'telegram_linked',   p.telegram_chat_id is not null,
    'provider',          (select to_jsonb(pp) - 'user_id' from provider_profiles pp where pp.user_id = p.id)
  )
  into v
  from profiles p join auth.users u on u.id = p.id
  where p.id = v_uid;

  if v is null then
    if not exists (select 1 from auth.users where id = v_uid) then raise exception 'AUTH_REQUIRED'; end if;
    insert into profiles (id) values (v_uid) on conflict do nothing;
    return get_me();
  end if;
  return v;
end;
$$;

revoke execute on function public.get_telegram_link(), public.unlink_telegram()
  from public, anon, authenticated;

grant execute on function public.get_telegram_link(), public.unlink_telegram()
  to authenticated;

revoke execute on function public.register_push_token(text, text), public.unregister_push_token(text)
  from public, anon, authenticated;

grant execute on function public.register_push_token(text, text), public.unregister_push_token(text)
  to authenticated;

revoke execute on function
  public.queue_notification(uuid, text, text), public.notify_new_proposal(),
  public.notify_proposal_accepted(), public.notify_job_invite(),
  public.notify_new_message(), public.notify_contract_status()
  from public, anon, authenticated;


-- ===== admin.sql =====
create or replace function public.require_admin()
returns uuid language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := require_uid();
begin
  if not coalesce((select is_admin from profiles where id = v_uid), false) then
    raise exception 'NOT_ALLOWED';
  end if;
  return v_uid;
end;
$$;

-- Usta arizasi: admin profilni ko'rib tasdiqlaydi yoki rad etadi. 2026-10-30 dan pasport so'ralmaydi — tasdiq
-- "Shaxsi tasdiqlangan" belgisini bermaydi (uni admin_set_verified bilan qo'lda qo'yish mumkin). Eski ilovadan
-- yuklangan pasport rasmlari bo'lsa, qarordan keyin o'chiriladi.
create or replace function public.admin_review_provider(p_user_id uuid, p_approve boolean, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_pp provider_profiles;
begin
  if v_uid is not null and not coalesce((select is_admin from profiles where id = v_uid), false) then
    raise exception 'NOT_ALLOWED';
  end if;
  select * into v_pp from provider_profiles where user_id = p_user_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;

  update provider_profiles
     set status = case when p_approve then 'approved' else 'rejected' end,
         rejection_reason = case when p_approve then null else p_reason end,
         reviewed_at = now()
   where user_id = p_user_id;
  delete from files where bucket = 'id-docs' and path like p_user_id::text || '/%';

  perform queue_notification(p_user_id,
    case when p_approve
      then E'✅ Tabriklaymiz! Usta profilingiz tasdiqlandi — endi ishlarga taklif yubora olasiz.'
      else format(E'❌ Usta profilingiz rad etildi. Sabab: %s', coalesce(p_reason, '-'))
    end,
    case when p_approve then '/' else '/become-provider' end);
end;
$$;

create or replace function public.admin_resolve_dispute(p_contract_id uuid, p_winner text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_k contracts;
begin
  if v_uid is not null and not coalesce((select is_admin from profiles where id = v_uid), false) then
    raise exception 'NOT_ALLOWED';
  end if;
  if p_winner not in ('provider', 'client') then raise exception 'INVALID_INPUT'; end if;
  select * into v_k from contracts where id = p_contract_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_k.status <> 'disputed' then raise exception 'INVALID_STATE'; end if;
  -- Admin yakuniy qarorni faqat mediatsiya rad etilgach chiqaradi (tizim chaqiruvi — istisno)
  if v_uid is not null and v_k.arbitration_at is null then raise exception 'MEDIATION_REQUIRED'; end if;
  -- Butun summa bir tomonga (eski ilova); qisman yechim — admin_decide_dispute
  perform _resolve_dispute(p_contract_id,
    case when p_winner = 'provider' then _dispute_amount(p_contract_id) else 0 end, p_winner, null);
end;
$$;

create or replace function public.admin_get_dashboard_stats()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  perform require_admin();
  select jsonb_build_object(
    'pending_providers',   (select count(*) from provider_profiles
                             where status = 'pending'
                                -- Soliq maqomini tekshirish ham shu ekranda
                                or (tax_id is not null and tax_verified_at is null and tax_rejection_reason is null)),
    'disputed_contracts',  (select count(*) from contracts where status = 'disputed'),
    'payments_action',     (select count(*) from contracts
                             where payment_status = 'held' and status in ('completed', 'cancelled'))
                         + (select count(*) from contract_stages st join contracts k on k.id = st.contract_id
                             where st.payment_status = 'held'
                               and (st.status = 'approved' or k.status in ('completed', 'cancelled'))),
    'errors_24h',          (select count(*) from client_errors where created_at > now() - interval '24 hours'),
    'waiting_jobs',        (select count(*) from jobs j where j.status = 'open'
                             and j.created_at > now() - interval '7 days'
                             and not exists (select 1 from proposals p where p.job_id = j.id and p.status = 'submitted')),
    'blocked_users',       (select count(*) from users where blocked_at is not null and deleted_at is null),
    'open_reports',        (select count(*) from reports where status = 'open'),
    'pending_teams',       (select count(*) from teams where status = 'pending'),
    'total_users',         (select count(*) from profiles),
    'total_providers',     (select count(*) from provider_profiles where status = 'approved'),
    'open_jobs',           (select count(*) from jobs where status = 'open'),
    'active_contracts',    (select count(*) from contracts where status = 'active'),
    'completed_contracts', (select count(*) from contracts where status = 'completed')
  ) into v;
  return v;
end;
$$;

create or replace function public.admin_get_pending_providers()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  perform require_admin();
  select coalesce(jsonb_agg(jsonb_build_object(
    'user_id',          pp.user_id,
    'full_name',        p.full_name,
    'phone',            u.phone,
    'headline',         pp.headline,
    'bio',              pp.bio,
    'categories',       pp.categories,
    'districts',        pp.districts,
    'experience_years', pp.experience_years,
    'created_at',       pp.created_at,
    'status',           pp.status,
    'id_docs',          _id_docs(pp.user_id)
  ) order by pp.created_at asc), '[]'::jsonb)
  into v
  from provider_profiles pp
  join profiles p on p.id = pp.user_id
  join auth.users u on u.id = pp.user_id
  where pp.status = 'pending';
  return v;
end;
$$;

create or replace function public.admin_get_disputed_contracts()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  perform require_admin();
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',             k.id,
    'price',          k.price,
    'disputed_at',    k.disputed_at,
    'dispute_reason', k.dispute_reason,
    -- Nizodagi summa (bosqichli shartnomada — hali qabul qilinmagan bosqichlar), ustaning javobi,
    -- admin'ga qachon va kim yubordi, kelishuv takliflari, ikki tomonning dalil rasmlari
    'dispute_amount',       _dispute_amount(k.id),
    'staged',               k.staged,
    'payment_status',       k.payment_status,
    'dispute_response',     k.dispute_response,
    'dispute_responded_at', k.dispute_responded_at,
    'dispute_escalated_at', k.dispute_escalated_at,
    'dispute_escalated_by', k.dispute_escalated_by,
    'mediation',            case when k.mediation_at is not null then jsonb_build_object(
        'provider_amount', k.mediation_amount, 'note', k.mediation_note, 'created_at', k.mediation_at,
        'respond_until', k.mediation_at + interval '72 hours',
        'client_ok', k.mediation_client_ok, 'provider_ok', k.mediation_provider_ok) end,
    'arbitration_at',       k.arbitration_at,
    'dispute_photos',       _dispute_photos(k.id),
    'dispute_offers',       coalesce((
        select jsonb_agg(jsonb_build_object('provider_amount', o.provider_amount, 'note', o.note, 'status', o.status,
                                            'by', case when o.proposed_by = k.client_id then 'client' else 'provider' end,
                                            'created_at', o.created_at) order by o.created_at)
        from dispute_offers o where o.contract_id = k.id and o.created_at >= k.disputed_at), '[]'::jsonb),
    'revisions',            coalesce((
        select jsonb_agg(jsonb_build_object('reason', r.reason, 'created_at', r.created_at) order by r.created_at)
        from revision_requests r where r.contract_id = k.id), '[]'::jsonb),
    'arrived_at',     k.arrived_at,
    'started_at',     k.started_at,
    'work_photos',    _work_photos(k.id),
    'price_history',  coalesce((
        select jsonb_agg(jsonb_build_object('old_price', c.old_price, 'new_price', c.new_price, 'reason', c.reason,
                                            'status', c.status, 'created_at', c.created_at) order by c.created_at)
        from price_changes c where c.contract_id = k.id and c.status in ('approved', 'declined')), '[]'::jsonb),
    'job',      jsonb_build_object('id', j.id, 'title', j.title, 'category', j.category, 'district', j.district),
    'client',   jsonb_build_object('id', cp.id, 'full_name', cp.full_name, 'phone', cu.phone),
    'provider', jsonb_build_object('id', pp.id, 'full_name', pp.full_name, 'phone', pu.phone)
  -- Yakuniy qaror kutayotganlar, keyin admin'ga yuborilganlar (murosa kerak), oxirida — tomonlar hali gaplashyapti
  ) order by k.arbitration_at is null, k.dispute_escalated_at is null,
             coalesce(k.arbitration_at, k.dispute_escalated_at, k.disputed_at) asc), '[]'::jsonb)
  into v
  from contracts k
  join jobs j on j.id = k.job_id
  join profiles cp on cp.id = k.client_id
  join auth.users cu on cu.id = k.client_id
  join profiles pp on pp.id = k.provider_id
  join auth.users pu on pu.id = k.provider_id
  where k.status = 'disputed';
  return v;
end;
$$;

-- Admin: pul harakati bo'yicha shartnomalar. action:
--   release — pul kafolatda, ish yakunlangan: ustaga o'tkazish kerak
--   refund  — pul kafolatda, shartnoma bekor: mijozga qaytarish kerak
--   held    — pul kafolatda, ish davom etmoqda
--   hold    — kafolatsiz faol shartnoma: mijoz to'lasa "qabul qilindi" deb belgilanadi
create or replace function public.admin_get_payments()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  perform require_admin();
  select coalesce(jsonb_agg(x.row_data order by x.sort_key, x.created_at desc), '[]'::jsonb)
  into v
  from (
    select k.created_at,
      case
        when k.payment_status = 'held' and k.status = 'completed' then 1
        when k.payment_status = 'held' and k.status = 'cancelled' then 2
        when k.payment_status = 'held' then 3
        else 4
      end as sort_key,
      jsonb_build_object(
        'id', k.id, 'price', k.price, 'status', k.status, 'payment_status', k.payment_status,
        'payment_held_at', k.payment_held_at, 'held_amount', k.payment_held_amount, 'created_at', k.created_at,
        'action', case
          when k.payment_status = 'held' and k.status = 'completed' then 'release'
          when k.payment_status = 'held' and k.status = 'cancelled' then 'refund'
          when k.payment_status = 'held' then 'held'
          else 'hold'
        end,
        'job',      jsonb_build_object('id', j.id, 'title', j.title),
        'client',   jsonb_build_object('id', cp.id, 'full_name', cp.full_name, 'phone', cu.phone),
        'provider', jsonb_build_object('id', pp.id, 'full_name', pp.full_name, 'phone', pu.phone)
      ) as row_data
    from contracts k
    join jobs j on j.id = k.job_id
    join profiles cp on cp.id = k.client_id
    join auth.users cu on cu.id = k.client_id
    join profiles pp on pp.id = k.provider_id
    join auth.users pu on pu.id = k.provider_id
    where k.payment_status = 'held'
       or (k.payment_status = 'none' and k.status in ('active', 'submitted', 'disputed'))
    order by 2, k.created_at desc
    limit 100
  ) x;
  return v;
end;
$$;

-- Admin: pul harakatini belgilash. Faqat shu o'tishlar mumkin:
--   none -> held      (shartnoma active / submitted / disputed — mijoz pulni o'tkazdi)
--   held -> released  (shartnoma completed — pul ustaga o'tkazildi; nizoda qisman yechim bo'lsa
--                      ustaga payout_amount, qolgani mijozga qaytariladi)
--   held -> refunded  (shartnoma cancelled — pul mijozga qaytarildi)
create or replace function public.admin_set_payment(p_contract_id uuid, p_status text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_k contracts;
  v_title text;
  v_sum text;
  v_back int;
  v_link text := '/contract/' || p_contract_id;
begin
  perform require_admin();
  select * into v_k from contracts where id = p_contract_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if not coalesce(
       (p_status = 'held' and v_k.payment_status = 'none' and v_k.status in ('active', 'submitted', 'disputed'))
    or (p_status = 'released' and v_k.payment_status = 'held'
        and (v_k.status = 'completed' or (v_k.status = 'cancelled' and v_k.payout_amount is not null)))
    or (p_status = 'refunded' and v_k.payment_status = 'held' and v_k.status = 'cancelled' and v_k.payout_amount is null), false) then
    raise exception 'INVALID_STATE';
  end if;
  -- Qisman yechimda (nizo yoki kech bekor qilishdagi chaqiruv haqi) mijozga qaytadigan qism (kafolatdagi summadan)
  v_back := case when p_status = 'released' and v_k.payout_amount is not null
                 then greatest(coalesce(v_k.payment_held_amount, v_k.price) - v_k.payout_amount, 0) else 0 end;

  update contracts set
    payment_status      = p_status,
    payment_held_at     = case when p_status = 'held' then now() else payment_held_at end,
    payment_held_amount = case when p_status = 'held' then price else payment_held_amount end,
    payment_released_at = case when p_status = 'released' then now() else payment_released_at end,
    payment_refunded_at = case when p_status = 'refunded' or v_back > 0 then now() else payment_refunded_at end
  where id = p_contract_id;

  select title into v_title from jobs where id = v_k.job_id;
  v_sum := replace(to_char(case when p_status = 'released' then coalesce(v_k.payout_amount, v_k.price) else v_k.price end,
                           'FM999,999,999'), ',', ' ');
  if p_status = 'held' then
    perform queue_notification(v_k.provider_id, format(
      E'\U0001F512 "%s": mijoz puli (%s so''m) Ustame''da kafolatda. Ishni qabul qilgach pul sizga o''tkaziladi.',
      v_title, v_sum), v_link);
    perform queue_notification(v_k.client_id, format(
      E'\U0001F512 "%s": to''lovingiz (%s so''m) kafolatda. Ishni qabul qilganingizdan keyingina ustaga o''tkaziladi.',
      v_title, v_sum), v_link);
  elsif p_status = 'released' then
    perform queue_notification(v_k.provider_id, format(
      E'\U0001F4B8 "%s": %s so''m sizga o''tkazildi.', v_title, v_sum), v_link);
    if v_back > 0 then
      perform queue_notification(v_k.client_id, format(
        E'↩️ "%s": %s %s so''m sizga qaytarildi.', v_title,
        case when v_k.status = 'cancelled' then 'chaqiruv haqi ushlab qolinib,' else 'nizo yechimiga ko''ra' end,
        replace(to_char(v_back, 'FM999,999,999'), ',', ' ')), v_link);
    end if;
  else
    perform queue_notification(v_k.client_id, format(
      E'↩️ "%s": %s so''m sizga qaytarildi.', v_title, v_sum), v_link);
  end if;
end;
$$;

create or replace function public.get_me()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v jsonb;
begin
  select jsonb_build_object(
    'id',                p.id,
    'full_name',         p.full_name,
    'phone',             u.phone,
    'active_role',       p.active_role,
    'created_at',        p.created_at,
    'avatar_updated_at', p.avatar_updated_at,
    'telegram_linked',   p.telegram_chat_id is not null,
    'is_admin',          p.is_admin,
    'provider',          (select to_jsonb(pp) - 'user_id' from provider_profiles pp where pp.user_id = p.id),
    -- Tekshiruvni kutayotgan pasport rasmlari (tasdiqlangach o'chiriladi)
    'id_docs',           _id_docs(p.id),
    -- Oylik obuna holati — faqat ustalarga
    'subscription',      case when exists (select 1 from provider_profiles pp where pp.user_id = p.id)
                              then _subscription_json(p.id) end,
    -- Mijoz profili: shaxsiy yoki tashkilot, buyurtmalar statistikasi
    'account_type',      (select x.account_type from users x where x.id = p.id),
    'organization_name', (select x.organization_name from users x where x.id = p.id),
    'client_stats',      client_stats(p.id)
  )
  into v
  from profiles p join auth.users u on u.id = p.id
  where p.id = v_uid;

  if v is null then
    if not exists (select 1 from auth.users where id = v_uid) then raise exception 'AUTH_REQUIRED'; end if;
    insert into profiles (id) values (v_uid) on conflict do nothing;
    return get_me();
  end if;
  return v;
end;
$$;

revoke execute on function
  public.admin_review_provider(uuid, boolean, text), public.admin_resolve_dispute(uuid, text),
  public.admin_get_dashboard_stats(), public.admin_get_pending_providers(),
  public.admin_get_disputed_contracts(), public.admin_get_payments(), public.admin_set_payment(uuid, text)
  from public, anon, authenticated;

grant execute on function
  public.admin_review_provider(uuid, boolean, text), public.admin_resolve_dispute(uuid, text),
  public.admin_get_dashboard_stats(), public.admin_get_pending_providers(),
  public.admin_get_disputed_contracts(), public.admin_get_payments(), public.admin_set_payment(uuid, text)
  to authenticated;


-- ===== moderatsiya, hisobni o'chirish, ilova xatolari =====

-- Foydalanuvchining ochiq e'lonlari, kutilayotgan takliflari va push tokenlarini yopadi
-- (bloklash va hisobni o'chirishda). Faol shartnomalarga tegmaydi.
create or replace function public._close_user_activity(p_user_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update proposals set status = 'closed', updated_at = now()
   where status = 'submitted'
     and job_id in (select id from jobs where client_id = p_user_id and status = 'open');
  update jobs set status = 'cancelled', closed_at = now() where client_id = p_user_id and status = 'open';
  update proposals set status = 'withdrawn', updated_at = now()
   where provider_id = p_user_id and status = 'submitted';
  delete from push_tokens where user_id = p_user_id;
end;
$$;

-- Admin: foydalanuvchilarni ism yoki telefon bo'yicha qidirish (bloklanganlar birinchi)
create or replace function public.admin_search_users(p_query text default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_q text := nullif(btrim(coalesce(p_query, '')), '');
  v_digits text;
  v jsonb;
begin
  perform require_admin();
  v_digits := nullif(regexp_replace(coalesce(v_q, ''), '\D', '', 'g'), '');
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', u.id, 'full_name', u.full_name, 'phone', u.phone, 'active_role', u.active_role,
    'is_admin', u.is_admin, 'created_at', u.created_at,
    'blocked_at', u.blocked_at, 'block_reason', u.block_reason,
    'provider_status', (select pp.status from provider_profiles pp where pp.user_id = u.id),
    'provider_verified', (select pp.id_verified_at is not null from provider_profiles pp where pp.user_id = u.id),
    'paid_until', (select s.paid_until from provider_subscriptions s where s.user_id = u.id),
    'jobs_count', (select count(*) from jobs j where j.client_id = u.id),
    'contracts_count', (select count(*) from contracts k where k.client_id = u.id or k.provider_id = u.id)
  ) order by u.blocked_at desc nulls last, u.created_at desc), '[]'::jsonb)
  into v
  from (
    select * from users u
    where u.deleted_at is null
      and (v_q is null
           or u.full_name ilike '%' || v_q || '%'
           or (v_digits is not null and u.phone like '%' || v_digits || '%'))
    order by u.blocked_at desc nulls last, u.created_at desc
    limit 50
  ) u;
  return v;
end;
$$;

-- Admin: bloklash — hisobdan chiqariladi, kira olmaydi, ochiq e'lon va takliflari yopiladi,
-- usta profili katalogdan olinadi. Faol shartnomalar admin tomonidan alohida hal qilinadi.
create or replace function public.admin_block_user(p_user_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_admin uuid := require_admin();
  v_u users;
  v_reason text := left(btrim(coalesce(p_reason, '')), 500);
begin
  if char_length(v_reason) < 3 then raise exception 'REASON_REQUIRED'; end if;
  select * into v_u from users where id = p_user_id for update;
  if not found or v_u.deleted_at is not null then raise exception 'NOT_FOUND'; end if;
  if v_u.is_admin or p_user_id = v_admin then raise exception 'NOT_ALLOWED'; end if;
  if v_u.blocked_at is not null then raise exception 'INVALID_STATE'; end if;

  update users set blocked_at = now(), block_reason = v_reason, token_version = token_version + 1
   where id = p_user_id;
  update provider_profiles
     set status = 'rejected', rejection_reason = left('Hisob bloklangan: ' || v_reason, 500), reviewed_at = now()
   where user_id = p_user_id and status <> 'rejected';
  perform _close_user_activity(p_user_id);
end;
$$;

create or replace function public.admin_unblock_user(p_user_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform require_admin();
  update users set blocked_at = null, block_reason = null
   where id = p_user_id and blocked_at is not null and deleted_at is null;
  if not found then raise exception 'INVALID_STATE'; end if;
end;
$$;

-- Admin: qoidabuzar (spam, firibgarlik) ochiq e'lonni olib tashlash; mijozga sababi yuboriladi
create or replace function public.admin_remove_job(p_job_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_job jobs;
  v_reason text := left(btrim(coalesce(p_reason, '')), 300);
begin
  perform require_admin();
  if char_length(v_reason) < 3 then raise exception 'REASON_REQUIRED'; end if;
  select * into v_job from jobs where id = p_job_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_job.status <> 'open' then raise exception 'JOB_NOT_OPEN'; end if;

  update jobs set status = 'cancelled', closed_at = now() where id = p_job_id;
  update proposals set status = 'closed', updated_at = now() where job_id = p_job_id and status = 'submitted';
  perform queue_notification(v_job.client_id, format(
    E'⚠️ "%s" e''loningiz moderator tomonidan olib tashlandi. Sabab: %s', v_job.title, v_reason),
    '/job/' || p_job_id);
end;
$$;

-- Hisobni o'chirish (Google Play talabi). Shaxsiy ma'lumotlar o'chiriladi: telefon, ism, rasmlar,
-- manzillar, usta profili, sevimlilar. Qarshi tomonga tegishli yozuvlar (yakunlangan shartnoma,
-- sharh, xabarlar) qoladi, ismi "O'chirilgan hisob" bo'ladi. Shu raqam bilan keyin yangi hisob ochish mumkin.
create or replace function public.delete_my_account()
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := require_uid();
begin
  if exists (select 1 from contracts
             where (client_id = v_uid or provider_id = v_uid)
               and (status in ('active', 'submitted', 'disputed') or payment_status = 'held')) then
    raise exception 'HAS_ACTIVE_CONTRACTS';
  end if;

  perform _close_user_activity(v_uid);
  delete from files
   where (bucket in ('avatars', 'portfolio-photos') and path like v_uid::text || '/%')
      or (bucket = 'job-photos' and split_part(path, '/', 1) in (select id::text from jobs where client_id = v_uid));
  delete from job_addresses where job_id in (select id from jobs where client_id = v_uid);
  delete from favorites where client_id = v_uid or provider_id = v_uid;
  delete from user_blocks where blocker_id = v_uid or blocked_id = v_uid;
  delete from saved_jobs where user_id = v_uid;
  delete from teams where owner_id = v_uid;
  delete from team_members where user_id = v_uid;
  delete from job_invites where client_id = v_uid or provider_id = v_uid;
  delete from provider_profiles where user_id = v_uid;
  update users set
    full_name = 'O''chirilgan hisob', phone = 'deleted:' || id::text, active_role = 'client',
    telegram_chat_id = null, telegram_link_code = null, telegram_login_chat_id = null, avatar_updated_at = null,
    is_admin = false, token_version = token_version + 1, deleted_at = now()
  where id = v_uid;
end;
$$;

-- Ilova xatolari (telefon/saytda yiqilish): backend POST /api/client-errors orqali yozadi
create table if not exists public.client_errors (
  id          bigint generated always as identity primary key,
  created_at  timestamptz not null default now(),
  user_id     uuid references public.users (id) on delete set null,
  platform    text not null,
  app_version text,
  message     text not null,
  stack       text,
  context     text
);

create index if not exists client_errors_created_idx on public.client_errors (created_at desc);

alter table public.client_errors enable row level security;

-- Admin: oxirgi 30 kundagi xatolar, bir xil xabar bo'yicha guruhlangan (eng yangisi birinchi)
create or replace function public.admin_get_client_errors()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  perform require_admin();
  select coalesce(jsonb_agg(x.row_data order by x.last_seen desc), '[]'::jsonb)
  into v
  from (
    select max(e.created_at) as last_seen, jsonb_build_object(
      'message', e.message,
      'count', count(*),
      'users', count(distinct e.user_id),
      'first_seen', min(e.created_at),
      'last_seen', max(e.created_at),
      'platforms', to_jsonb(array_agg(distinct e.platform)),
      'versions', coalesce(to_jsonb(array_agg(distinct e.app_version) filter (where e.app_version is not null)), '[]'::jsonb),
      'context', (array_agg(e.context order by e.created_at desc))[1],
      'stack', (array_agg(e.stack order by e.created_at desc))[1]
    ) as row_data
    from client_errors e
    where e.created_at > now() - interval '30 days'
    group by e.message
    order by max(e.created_at) desc
    limit 50
  ) x;
  return v;
end;
$$;

revoke execute on function
  public._close_user_activity(uuid), public.admin_search_users(text), public.admin_block_user(uuid, text),
  public.admin_unblock_user(uuid), public.admin_remove_job(uuid, text), public.delete_my_account(),
  public.admin_get_client_errors()
from public, anon, authenticated;

grant execute on function
  public.admin_search_users(text), public.admin_block_user(uuid, text), public.admin_unblock_user(uuid),
  public.admin_remove_job(uuid, text), public.delete_my_account(), public.admin_get_client_errors()
to authenticated;


-- ===== tezkor tanlov: shoshilinch e'lon, bo'sh ustalar, operator =====

-- Shoshilinch e'lon ('urgent'): ustaga zudlik bilan kerak
do $$ begin
  alter table public.jobs drop constraint if exists jobs_urgency_check;
  alter table public.jobs add constraint jobs_urgency_check
    check (urgency in ('urgent', 'today', 'this_week', 'flexible'));
end $$;

-- Taklifdagi "qancha vaqtda yetib boraman" (daqiqa)
alter table public.proposals add column if not exists eta_minutes int;

-- Usta "Hozir bo'shman" — shu vaqtgacha shoshilinch e'lonlar unga darhol yuboriladi
alter table public.provider_profiles add column if not exists available_until timestamptz;

create index if not exists provider_profiles_available_idx
  on public.provider_profiles (available_until) where status = 'approved';

-- p_hours: 1..12 — shuncha soatga bo'sh, 0 — o'chirish. Yangi vaqtni qaytaradi (yoki null).
create or replace function public.set_my_availability(p_hours int)
returns timestamptz language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_until timestamptz;
begin
  if p_hours is null or p_hours not between 0 and 12 then raise exception 'INVALID_INPUT'; end if;
  if not is_approved_provider(v_uid) then raise exception 'NOT_APPROVED_PROVIDER'; end if;
  v_until := case when p_hours = 0 then null else now() + make_interval(hours => p_hours) end;
  update provider_profiles set available_until = v_until where user_id = v_uid;
  return v_until;
end;
$$;

-- Shoshilinch e'lon joylanishi bilan: shu kasb va tumandagi bo'sh ustalarga va adminlarga xabar
create or replace function public.notify_urgent_job()
returns trigger language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if new.urgency <> 'urgent' then return new; end if;
  for r in
    select pp.user_id from provider_profiles pp join users u on u.id = pp.user_id
     where pp.status = 'approved' and pp.available_until > now()
       and new.category = any (pp.categories) and new.district = any (pp.districts)
       and pp.user_id <> new.client_id and u.blocked_at is null and u.deleted_at is null
  loop
    perform queue_notification(r.user_id, format(
      E'\U0001F6A8 Shoshilinch: "%s" (%s). Narx va qancha vaqtda yetib borishingizni yozing.',
      new.title, new.district), '/job/' || new.id);
  end loop;
  for r in select id from users where is_admin and blocked_at is null and deleted_at is null loop
    perform queue_notification(r.id, format(E'\U0001F6A8 Yangi shoshilinch e''lon: "%s" (%s, %s).',
      new.title, new.category, new.district), '/admin/waiting');
  end loop;
  return new;
end;
$$;

drop trigger if exists trg_notify_urgent_job on public.jobs;

create trigger trg_notify_urgent_job after insert on public.jobs
for each row execute function public.notify_urgent_job();

-- Operator: hali birorta ham taklif kelmagan ochiq e'lonlar (shoshilinchlari birinchi, eskisi birinchi)
-- va har biriga mos ustalar (bo'shlari birinchi, keyin reyting bo'yicha)
create or replace function public.admin_get_waiting_jobs()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  perform require_admin();
  select coalesce(jsonb_agg(x.row_data order by x.urgent desc, x.created_at asc), '[]'::jsonb)
  into v
  from (
    select j.created_at, j.urgency = 'urgent' as urgent, jsonb_build_object(
      'id', j.id, 'title', j.title, 'category', j.category, 'district', j.district,
      'urgency', j.urgency, 'created_at', j.created_at,
      'waiting_minutes', floor(extract(epoch from now() - j.created_at) / 60),
      'client', jsonb_build_object('id', c.id, 'full_name', c.full_name, 'phone', c.phone),
      'invited', (select count(*) from job_invites i where i.job_id = j.id),
      'candidates', coalesce((
        select jsonb_agg(m.cand order by m.available desc, m.rating desc nulls last, m.completed desc)
        from (
          select coalesce(pp.available_until > now(), false) as available,
                 (st.s->>'avg_rating')::numeric as rating, (st.s->>'completed_jobs')::int as completed,
                 jsonb_build_object(
                   'id', u.id, 'full_name', u.full_name, 'phone', u.phone,
                   'available', coalesce(pp.available_until > now(), false),
                   'available_until', pp.available_until, 'stats', st.s,
                   'invited', exists (select 1 from job_invites i where i.job_id = j.id and i.provider_id = u.id)
                 ) as cand
          from provider_profiles pp
          join users u on u.id = pp.user_id
          cross join lateral (select provider_stats(u.id) as s) st
          where pp.status = 'approved' and j.category = any (pp.categories) and j.district = any (pp.districts)
            and u.id <> j.client_id and u.blocked_at is null and u.deleted_at is null
          order by available desc, rating desc nulls last, completed desc
          limit 8
        ) m
      ), '[]'::jsonb)
    ) as row_data
    from jobs j
    join users c on c.id = j.client_id
    where j.status = 'open' and j.created_at > now() - interval '7 days'
      and not exists (select 1 from proposals p where p.job_id = j.id and p.status = 'submitted')
    order by (j.urgency = 'urgent') desc, j.created_at asc
    limit 50
  ) x;
  return v;
end;
$$;

-- Operator ishni ustaga taklif qiladi (mijoz nomidan taklif sifatida — ustaga bildirishnoma boradi)
create or replace function public.admin_offer_job(p_job_id uuid, p_provider_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_job jobs;
begin
  perform require_admin();
  select * into v_job from jobs where id = p_job_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_job.status <> 'open' then raise exception 'JOB_NOT_OPEN'; end if;
  if not is_approved_provider(p_provider_id) or p_provider_id = v_job.client_id then raise exception 'PROVIDER_NOT_AVAILABLE'; end if;
  insert into job_invites (job_id, provider_id, client_id) values (p_job_id, p_provider_id, v_job.client_id)
  on conflict (job_id, provider_id) do nothing;
end;
$$;

revoke execute on function
  public.set_my_availability(int), public.notify_urgent_job(), public.admin_get_waiting_jobs(),
  public.admin_offer_job(uuid, uuid)
from public, anon, authenticated;

grant execute on function
  public.set_my_availability(int), public.admin_get_waiting_jobs(), public.admin_offer_job(uuid, uuid)
to authenticated;


-- ===== narx o'zgarmasligi kafolati =====
-- Kelishilgan narxni usta o'zi o'zgartira olmaydi: sababini yozib so'raydi, mijoz tasdiqlasagina
-- shartnoma narxi yangilanadi. Har bir so'rov tarixda qoladi (nizoda dalil).
create table if not exists public.price_changes (
  id          uuid primary key default gen_random_uuid(),
  contract_id uuid not null references public.contracts (id) on delete cascade,
  old_price   int not null,
  new_price   int not null check (new_price between 10000 and 100000000),
  reason      text not null check (char_length(reason) between 5 and 500),
  status      text not null default 'pending' check (status in ('pending', 'approved', 'declined', 'cancelled')),
  created_at  timestamptz not null default now(),
  decided_at  timestamptz
);

create unique index if not exists price_changes_one_pending
  on public.price_changes (contract_id) where status = 'pending';

alter table public.price_changes enable row level security;

create or replace function public.request_price_change(p_contract_id uuid, p_new_price int, p_reason text)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_k contracts;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_title text;
  v_id uuid;
begin
  select * into v_k from contracts where id = p_contract_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_k.provider_id <> v_uid then raise exception 'NOT_ALLOWED'; end if;
  if v_k.status not in ('active', 'submitted') then raise exception 'INVALID_STATE'; end if;
  if p_new_price is null or p_new_price not between 10000 and 100000000 or p_new_price = v_k.price then
    raise exception 'INVALID_PRICE';
  end if;
  if char_length(v_reason) < 5 then raise exception 'REASON_REQUIRED'; end if;
  if v_k.staged and _adjustable_stage(p_contract_id) is null then raise exception 'STAGES_LOCKED'; end if;
  if exists (select 1 from price_changes where contract_id = p_contract_id and status = 'pending') then
    raise exception 'PRICE_CHANGE_PENDING';
  end if;

  insert into price_changes (contract_id, old_price, new_price, reason)
  values (p_contract_id, v_k.price, p_new_price, left(v_reason, 500))
  returning id into v_id;

  select title into v_title from jobs where id = v_k.job_id;
  perform queue_notification(v_k.client_id, format(
    E'\U0001F4AC "%s": usta narxni %s so''mdan %s so''mga o''zgartirishni so''radi. Sabab: %s. Siz tasdiqlamaguningizcha narx o''zgarmaydi.',
    v_title, replace(to_char(v_k.price, 'FM999,999,999'), ',', ' '),
    replace(to_char(p_new_price, 'FM999,999,999'), ',', ' '), left(v_reason, 200)), '/contract/' || p_contract_id);
  return v_id;
end;
$$;

create or replace function public.decide_price_change(p_change_id uuid, p_approve boolean)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_c price_changes;
  v_k contracts;
  v_title text;
  v_sum text;
  v_diff int;
  v_stage uuid;
  v_stage_amount int;
  r record;
begin
  select * into v_c from price_changes where id = p_change_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  select * into v_k from contracts where id = v_c.contract_id for update;
  if v_k.client_id <> v_uid then raise exception 'NOT_ALLOWED'; end if;
  if v_c.status <> 'pending' or v_k.status not in ('active', 'submitted') then raise exception 'INVALID_STATE'; end if;

  update price_changes set status = case when p_approve then 'approved' else 'declined' end, decided_at = now()
   where id = p_change_id;
  if p_approve then
    if v_k.staged then
      -- Farq oxirgi hali boshlanmagan va to'lanmagan bosqichga tushadi
      v_stage := _adjustable_stage(v_k.id);
      if v_stage is null then raise exception 'STAGES_LOCKED'; end if;
      update contract_stages set amount = amount + (v_c.new_price - v_k.price) where id = v_stage
      returning amount into v_stage_amount;
      if v_stage_amount < 10000 then raise exception 'INVALID_PRICE'; end if;
    end if;
    -- Taklif qilingan (hali tasdiqlanmagan) reja eski narx bo'yicha edi — bekor bo'ladi
    update contracts set price = v_c.new_price, stage_plan = null, stage_plan_by = null where id = v_k.id;
  end if;

  select title into v_title from jobs where id = v_k.job_id;
  v_sum := replace(to_char(v_c.new_price, 'FM999,999,999'), ',', ' ');
  perform queue_notification(v_k.provider_id,
    case when p_approve
      then format(E'✅ "%s": mijoz yangi narxni tasdiqladi — %s so''m.', v_title, v_sum)
      else format(E'❌ "%s": mijoz narx o''zgarishini rad etdi. Ish kelishilgan narx bo''yicha davom etadi.', v_title)
    end, '/contract/' || v_k.id);

  -- Pul allaqachon kafolatda bo'lsa, farqni operator hal qiladi
  if p_approve and v_k.payment_status = 'held' then
    v_diff := v_c.new_price - coalesce(v_k.payment_held_amount, v_k.price);
    if v_diff > 0 then
      perform queue_notification(v_k.client_id, format(
        E'\U0001F512 "%s": kafolatdagi summa yangi narxdan %s so''m kam. Farqni Ustame operatoriga o''tkazing.',
        v_title, replace(to_char(v_diff, 'FM999,999,999'), ',', ' ')), '/contract/' || v_k.id);
    elsif v_diff < 0 then
      perform queue_notification(v_k.client_id, format(
        E'↩️ "%s": ortiqcha %s so''m ish yakunlangach sizga qaytariladi.',
        v_title, replace(to_char(-v_diff, 'FM999,999,999'), ',', ' ')), '/contract/' || v_k.id);
    end if;
    for r in select id from users where is_admin and blocked_at is null and deleted_at is null loop
      perform queue_notification(r.id, format(
        E'\U0001F4B0 "%s": narx %s so''mga o''zgardi, kafolatdagi summa bilan farq bor.', v_title, v_sum),
        '/admin/payments');
    end loop;
  end if;
end;
$$;

revoke execute on function public.request_price_change(uuid, int, text), public.decide_price_change(uuid, boolean)
from public, anon, authenticated;

grant execute on function public.request_price_change(uuid, int, text), public.decide_price_change(uuid, boolean)
to authenticated;


-- ===== e'lon rasmlari (4 tagacha) =====
-- Nomlar qat'iy: photo.jpg (asosiy — kartochkada ko'rinadi), photo-2.jpg, photo-3.jpg, photo-4.jpg.
-- Ro'yxat files jadvalidan olinadi (alohida jadval yo'q); v — keshni yangilash uchun o'zgarish vaqti.
create or replace function public._job_photos(p_job_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('name', n.name, 'v', (extract(epoch from f.updated_at) * 1000)::bigint)
                            order by n.ord), '[]'::jsonb)
  from unnest(array['photo.jpg', 'photo-2.jpg', 'photo-3.jpg', 'photo-4.jpg']) with ordinality as n(name, ord)
  join files f on f.bucket = 'job-photos' and f.path = p_job_id::text || '/' || n.name;
$$;

revoke execute on function public._job_photos(uuid) from public, anon, authenticated;

-- Mijoz e'lon rasmini o'chiradi. Asosiy rasm o'chsa, keyingisi uning o'rniga o'tadi.
create or replace function public.delete_job_photo(p_job_id uuid, p_name text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_next text;
begin
  if job_client_id(p_job_id) is distinct from v_uid then raise exception 'NOT_ALLOWED'; end if;
  if p_name is null or p_name not in ('photo.jpg', 'photo-2.jpg', 'photo-3.jpg', 'photo-4.jpg') then
    raise exception 'INVALID_INPUT';
  end if;
  delete from files where bucket = 'job-photos' and path = p_job_id::text || '/' || p_name;
  if p_name = 'photo.jpg' then
    select n.name into v_next
      from unnest(array['photo-2.jpg', 'photo-3.jpg', 'photo-4.jpg']) with ordinality as n(name, ord)
      join files f on f.bucket = 'job-photos' and f.path = p_job_id::text || '/' || n.name
     order by n.ord limit 1;
    if v_next is not null then
      update files set path = p_job_id::text || '/photo.jpg', updated_at = now()
       where bucket = 'job-photos' and path = p_job_id::text || '/' || v_next;
    end if;
  end if;
  update jobs set has_photo = exists (select 1 from files where bucket = 'job-photos' and path = p_job_id::text || '/photo.jpg')
   where id = p_job_id;
end;
$$;

revoke execute on function public.delete_job_photo(uuid, text) from public, anon, authenticated;

grant execute on function public.delete_job_photo(uuid, text) to authenticated;


-- ===== usta holatlari va ish rasmlari =====
-- Ish rasmlari: work-photos/<shartnoma id>/before-1..3.jpg (ishdan oldin), after-1..3.jpg (ishdan keyin).
-- Faqat usta yuklaydi (internal/api/files.go), ikkala tomon va nizoda admin ko'radi.
create or replace function public._work_photos(p_contract_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('name', n.name, 'v', (extract(epoch from f.updated_at) * 1000)::bigint)
                            order by n.ord), '[]'::jsonb)
  from unnest(array['before-1.jpg', 'before-2.jpg', 'before-3.jpg', 'after-1.jpg', 'after-2.jpg', 'after-3.jpg'])
       with ordinality as n(name, ord)
  join files f on f.bucket = 'work-photos' and f.path = p_contract_id::text || '/' || n.name;
$$;

revoke execute on function public._work_photos(uuid) from public, anon, authenticated;

-- Usta ish bosqichini belgilaydi; orqaga qaytib bo'lmaydi, mijozga darhol xabar ketadi.
--   on_the_way — yo'lga chiqdim (p_eta_minutes: necha daqiqada yetib boraman)
--   arrived    — manzilga yetib keldim
--   started    — ishni boshladim
create or replace function public.set_work_stage(p_contract_id uuid, p_stage text, p_eta_minutes int default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_k contracts;
  v_title text;
  v_link text := '/contract/' || p_contract_id;
begin
  select * into v_k from contracts where id = p_contract_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_k.provider_id <> v_uid then raise exception 'NOT_ALLOWED'; end if;
  if v_k.status <> 'active' then raise exception 'INVALID_STATE'; end if;
  select title into v_title from jobs where id = v_k.job_id;

  if p_stage = 'on_the_way' then
    if v_k.on_the_way_at is not null or v_k.arrived_at is not null or v_k.started_at is not null then
      raise exception 'INVALID_STATE';
    end if;
    if p_eta_minutes is null or p_eta_minutes not between 5 and 240 then raise exception 'INVALID_INPUT'; end if;
    update contracts set on_the_way_at = now(), eta_at = now() + make_interval(mins => p_eta_minutes)
     where id = p_contract_id;
    perform queue_notification(v_k.client_id, format(
      E'\U0001F697 "%s": usta yo''lga chiqdi, taxminan %s daqiqada yetib boradi.', v_title, p_eta_minutes), v_link);
  elsif p_stage = 'arrived' then
    if v_k.arrived_at is not null or v_k.started_at is not null then raise exception 'INVALID_STATE'; end if;
    update contracts set arrived_at = now() where id = p_contract_id;
    perform queue_notification(v_k.client_id, format(
      E'\U0001F4CD "%s": usta manzilga yetib keldi.', v_title), v_link);
  elsif p_stage = 'started' then
    if v_k.started_at is not null then raise exception 'INVALID_STATE'; end if;
    update contracts set started_at = now(), arrived_at = coalesce(arrived_at, now()) where id = p_contract_id;
    perform queue_notification(v_k.client_id, format(
      E'\U0001F527 "%s": usta ishni boshladi.', v_title), v_link);
  else
    raise exception 'INVALID_INPUT';
  end if;
end;
$$;

revoke execute on function public.set_work_stage(uuid, text, int) from public, anon, authenticated;

grant execute on function public.set_work_stage(uuid, text, int) to authenticated;


-- ===== shikoyatlar va bloklash (Google Play: foydalanuvchi kontenti talabi) =====
-- Bloklash ikki tomonlama ta'sir qiladi: bir-birining e'lon/taklifini ko'rmaydi, taklif va chat yopiladi.
create table if not exists public.user_blocks (
  blocker_id uuid not null references public.users (id) on delete cascade,
  blocked_id uuid not null references public.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);

create index if not exists user_blocks_blocked_idx on public.user_blocks (blocked_id);

alter table public.user_blocks enable row level security;

create or replace function public._blocked(p_a uuid, p_b uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from user_blocks
                 where (blocker_id = p_a and blocked_id = p_b) or (blocker_id = p_b and blocked_id = p_a));
$$;

revoke execute on function public._blocked(uuid, uuid) from public, anon, authenticated;

create or replace function public.block_user(p_user_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := require_uid();
begin
  if p_user_id is null or p_user_id = v_uid then raise exception 'INVALID_INPUT'; end if;
  if not exists (select 1 from users where id = p_user_id and deleted_at is null) then raise exception 'NOT_FOUND'; end if;
  insert into user_blocks (blocker_id, blocked_id) values (v_uid, p_user_id) on conflict do nothing;
  delete from favorites where (client_id = v_uid and provider_id = p_user_id) or (client_id = p_user_id and provider_id = v_uid);
end;
$$;

create or replace function public.unblock_user(p_user_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := require_uid();
begin
  delete from user_blocks where blocker_id = v_uid and blocked_id = p_user_id;
end;
$$;

create or replace function public.get_my_blocks()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'full_name', p.full_name, 'created_at', b.created_at)
                            order by b.created_at desc), '[]'::jsonb)
  from user_blocks b join profiles p on p.id = b.blocked_id
  where b.blocker_id = auth.uid();
$$;

-- Shikoyatlar: e'lon, foydalanuvchi yoki chat xabari ustidan. Bitta narsaga bir kishidan bitta ochiq shikoyat.
create table if not exists public.reports (
  id               uuid primary key default gen_random_uuid(),
  reporter_id      uuid not null references public.users (id) on delete cascade,
  target_type      text not null check (target_type in ('job', 'user', 'message')),
  target_id        uuid not null,
  reported_user_id uuid not null references public.users (id) on delete cascade,
  reason           text not null check (reason in ('fraud', 'abuse', 'spam', 'fake', 'other')),
  comment          text not null default '' check (char_length(comment) <= 500),
  status           text not null default 'open' check (status in ('open', 'resolved', 'dismissed')),
  action           text,
  created_at       timestamptz not null default now(),
  resolved_at      timestamptz,
  resolved_by      uuid references public.users (id) on delete set null
);

create unique index if not exists reports_one_open
  on public.reports (reporter_id, target_type, target_id) where status = 'open';
create index if not exists reports_open_idx on public.reports (created_at) where status = 'open';

-- off_platform — ilovadan tashqarida kelishish yoki to'lashni taklif qildi (Upwork: platformani chetlab o'tish)
alter table public.reports drop constraint if exists reports_reason_check;
alter table public.reports add constraint reports_reason_check
  check (reason in ('fraud', 'abuse', 'spam', 'fake', 'off_platform', 'other'));

alter table public.reports enable row level security;

create or replace function public.report_content(p_target_type text, p_target_id uuid, p_reason text, p_comment text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_owner uuid;
  v_k contracts;
  v_id uuid;
  v_label text;
  r record;
begin
  if p_reason is null or p_reason not in ('fraud', 'abuse', 'spam', 'fake', 'off_platform', 'other') then raise exception 'INVALID_INPUT'; end if;
  if char_length(coalesce(p_comment, '')) > 500 then raise exception 'INVALID_INPUT'; end if;

  if p_target_type = 'job' then
    select client_id, title into v_owner, v_label from jobs where id = p_target_id;
  elsif p_target_type = 'user' then
    select id, full_name into v_owner, v_label from profiles where id = p_target_id;
  elsif p_target_type = 'message' then
    -- Xabar ustidan faqat shu yozishma ishtirokchisi shikoyat qila oladi
    select m.sender_id, left(m.text, 80) into v_owner, v_label from messages m where m.id = p_target_id;
    if v_owner is not null and not exists (
      select 1 from messages m
        left join contracts k on k.id = m.contract_id
        left join proposals pr on pr.id = m.proposal_id
        left join jobs jb on jb.id = pr.job_id
       where m.id = p_target_id and v_uid in (k.client_id, k.provider_id, pr.provider_id, jb.client_id)) then
      raise exception 'NOT_ALLOWED';
    end if;
  else
    raise exception 'INVALID_INPUT';
  end if;
  if v_owner is null then raise exception 'NOT_FOUND'; end if;
  if v_owner = v_uid then raise exception 'NOT_ALLOWED'; end if;
  if exists (select 1 from reports where reporter_id = v_uid and target_type = p_target_type
                                     and target_id = p_target_id and status = 'open') then
    raise exception 'ALREADY_REPORTED';
  end if;
  if (select count(*) from reports where reporter_id = v_uid and created_at > now() - interval '24 hours') >= 20 then
    raise exception 'TOO_MANY_REPORTS';
  end if;

  insert into reports (reporter_id, target_type, target_id, reported_user_id, reason, comment)
  values (v_uid, p_target_type, p_target_id, v_owner, p_reason, btrim(coalesce(p_comment, '')))
  returning id into v_id;

  for r in select id from users where is_admin and blocked_at is null and deleted_at is null loop
    perform queue_notification(r.id, format(E'\U0001F6A9 Yangi shikoyat (%s): %s',
      case p_target_type when 'job' then 'e''lon' when 'user' then 'foydalanuvchi' else 'xabar' end,
      coalesce(v_label, '')), '/admin/reports');
  end loop;
  return v_id;
end;
$$;

-- Admin: ochiq shikoyatlar (eskisi birinchi), keyin oxirgi hal qilinganlar
create or replace function public.admin_get_reports()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  perform require_admin();
  select coalesce(jsonb_agg(x.item order by x.open desc, case when x.open then x.created_at end asc,
                                            x.created_at desc), '[]'::jsonb)
  into v
  from (
    select rp.status = 'open' as open, rp.created_at,
      jsonb_build_object(
        'id', rp.id, 'target_type', rp.target_type, 'target_id', rp.target_id, 'reason', rp.reason,
        'comment', rp.comment, 'status', rp.status, 'action', rp.action,
        'created_at', rp.created_at, 'resolved_at', rp.resolved_at,
        'target', case rp.target_type
          when 'job' then (select jsonb_build_object('title', j.title, 'description', left(j.description, 300),
                                                     'status', j.status) from jobs j where j.id = rp.target_id)
          when 'message' then (select jsonb_build_object('text', m.text, 'contract_id', m.contract_id)
                               from messages m where m.id = rp.target_id)
        end,
        'reported_user', (select jsonb_build_object('id', u.id, 'full_name', u.full_name, 'phone', u.phone,
                                                    'blocked', u.blocked_at is not null,
                                                    'open_reports', (select count(*) from reports o
                                                                     where o.reported_user_id = u.id and o.status = 'open'))
                          from users u where u.id = rp.reported_user_id),
        'reporter', (select jsonb_build_object('id', u.id, 'full_name', u.full_name, 'phone', u.phone)
                     from users u where u.id = rp.reporter_id)
      ) as item
    from reports rp
    where rp.status = 'open' or rp.resolved_at > now() - interval '7 days'
    order by rp.status = 'open' desc, rp.created_at desc
    limit 100
  ) x;
  return v;
end;
$$;

-- Admin: shikoyatni hal qilish. p_action:
--   dismiss        — asossiz, rad etiladi
--   confirm        — tasdiqlandi, kontentga chora kerak emas (masalan foydalanuvchi ustidan shikoyat)
--   remove_job     — e'lon olib tashlanadi (faqat ochiq e'lon)
--   hide_message   — xabar matni yashiriladi
--   block_user     — shikoyat qilingan foydalanuvchi bloklanadi (barcha faoliyati yopiladi)
-- Shu narsaga tushgan boshqa ochiq shikoyatlar ham birga yopiladi.
-- Bloklash qoidasi: firibgarlik yoki ilovadan tashqariga chiqish tasdiqlansa — darhol, ogohlantirishsiz;
-- boshqa sabablar bo'yicha oxirgi 12 oyda 3 ta tasdiqlangan holat (har xil e'lon/xabar/profil) — avtomatik.
create or replace function public.admin_resolve_report(p_report_id uuid, p_action text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_admin uuid := require_admin();
  v_r reports;
  v_word text;
  v_reason text;
  v_strikes int;
begin
  select * into v_r from reports where id = p_report_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_r.status <> 'open' then raise exception 'INVALID_STATE'; end if;
  v_word := case v_r.reason when 'fraud' then 'firibgarlik' when 'abuse' then 'haqorat' when 'spam' then 'spam'
                            when 'fake' then 'soxta ma''lumot' when 'off_platform' then 'ilovadan tashqarida kelishish'
                            else 'qoidabuzarlik' end;
  v_reason := 'Shikoyat: ' || v_word;

  if p_action = 'remove_job' then
    if v_r.target_type <> 'job' then raise exception 'INVALID_INPUT'; end if;
    perform admin_remove_job(v_r.target_id, v_reason);
  elsif p_action = 'hide_message' then
    if v_r.target_type <> 'message' then raise exception 'INVALID_INPUT'; end if;
    update messages set text = '[Xabar moderator tomonidan yashirildi]' where id = v_r.target_id;
  elsif p_action = 'block_user' then
    perform admin_block_user(v_r.reported_user_id, v_reason);
  elsif p_action not in ('dismiss', 'confirm') then
    raise exception 'INVALID_INPUT';
  end if;

  update reports set status = case when p_action = 'dismiss' then 'dismissed' else 'resolved' end,
                     action = p_action, resolved_at = now(), resolved_by = v_admin
   where status = 'open'
     and (id = p_report_id
          or (target_type = v_r.target_type and target_id = v_r.target_id)
          or (p_action = 'block_user' and reported_user_id = v_r.reported_user_id));

  if p_action in ('confirm', 'remove_job', 'hide_message')
     and exists (select 1 from users where id = v_r.reported_user_id
                   and blocked_at is null and deleted_at is null and not is_admin) then
    if v_r.reason in ('fraud', 'off_platform') then
      perform admin_block_user(v_r.reported_user_id, v_reason);
    else
      select count(distinct (target_type, target_id)) into v_strikes
        from reports where reported_user_id = v_r.reported_user_id and status = 'resolved'
                       and resolved_at > now() - interval '12 months';
      if v_strikes >= 3 then
        perform admin_block_user(v_r.reported_user_id, format('%s (%s ta tasdiqlangan shikoyat)', v_reason, v_strikes));
      else
        perform queue_notification(v_r.reported_user_id, format(
          E'⚠️ Sizga nisbatan shikoyat tasdiqlandi (%s/3): %s. 12 oy ichida 3 ta tasdiqlangan shikoyatda hisob bloklanadi.',
          v_strikes, v_word), '/');
      end if;
    end if;
  end if;
end;
$$;

revoke execute on function public.block_user(uuid), public.unblock_user(uuid), public.get_my_blocks(),
  public.report_content(text, uuid, text, text), public.admin_get_reports(), public.admin_resolve_report(uuid, text)
from public, anon, authenticated;

grant execute on function public.block_user(uuid), public.unblock_user(uuid), public.get_my_blocks(),
  public.report_content(text, uuid, text, text), public.admin_get_reports(), public.admin_resolve_report(uuid, text)
to authenticated;


-- ===== bosqichli to'lov =====
-- Katta ish shartnoma summasi 2-6 bosqichga bo'linadi (masalan: material, asosiy ish, yakun). Bir tomon reja
-- taklif qiladi, ikkinchisi tasdiqlaydi. Har bosqich puli alohida kafolatga tushadi, usta bosqichni topshiradi,
-- mijoz qabul qiladi (72 soatda javob bo'lmasa avtomatik) — shundan keyin pul ustaga o'tkaziladi.
-- Oxirgi bosqich qabul qilinganda shartnoma yakunlanadi.
alter table public.contracts add column if not exists staged boolean not null default false;
alter table public.contracts add column if not exists stage_plan jsonb;
alter table public.contracts add column if not exists stage_plan_by uuid;

create table if not exists public.contract_stages (
  id                  uuid primary key default gen_random_uuid(),
  contract_id         uuid not null references public.contracts (id) on delete cascade,
  position            smallint not null,
  title               text not null check (char_length(title) between 2 and 120),
  amount              int not null check (amount between 1 and 100000000),
  status              text not null default 'pending' check (status in ('pending', 'submitted', 'approved')),
  submitted_at        timestamptz,
  approved_at         timestamptz,
  payment_status      text not null default 'none' check (payment_status in ('none', 'held', 'released', 'refunded')),
  payment_held_at     timestamptz,
  payment_released_at timestamptz,
  payment_refunded_at timestamptz,
  unique (contract_id, position)
);

alter table public.contract_stages enable row level security;

-- Nizo qisman hal qilinsa bosqich bo'yicha ustaga tegadigan summa (null — to'liq, 0 — hammasi qaytariladi)
alter table public.contract_stages add column if not exists payout_amount int;

create or replace function public._stages_json(p_contract_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', st.id, 'position', st.position, 'title', st.title, 'amount', st.amount, 'status', st.status,
    'payout_amount', st.payout_amount,
    'submitted_at', st.submitted_at, 'approved_at', st.approved_at,
    'auto_approve_at', case when st.status = 'submitted' then st.submitted_at + interval '72 hours' end,
    'payment_status', st.payment_status, 'payment_held_at', st.payment_held_at,
    'payment_released_at', st.payment_released_at, 'payment_refunded_at', st.payment_refunded_at
  ) order by st.position), '[]'::jsonb)
  from contract_stages st where st.contract_id = p_contract_id;
$$;

-- Narx o'zgarsa farq tushadigan bosqich: oxirgi, hali boshlanmagan va puli kafolatga tushmagan
create or replace function public._adjustable_stage(p_contract_id uuid)
returns uuid language sql stable security definer set search_path = public as $$
  select id from contract_stages
   where contract_id = p_contract_id and status = 'pending' and payment_status = 'none'
   order by position desc limit 1;
$$;

revoke execute on function public._stages_json(uuid), public._adjustable_stage(uuid) from public, anon, authenticated;

create or replace function public.propose_stages(p_contract_id uuid, p_stages jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_k contracts;
  v_plan jsonb;
  v_n int;
  v_title text;
begin
  select * into v_k from contracts where id = p_contract_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_uid not in (v_k.client_id, v_k.provider_id) then raise exception 'NOT_ALLOWED'; end if;
  if v_k.status <> 'active' or v_k.staged or v_k.payment_status <> 'none' then raise exception 'INVALID_STATE'; end if;
  if jsonb_typeof(p_stages) is distinct from 'array' then raise exception 'INVALID_STAGES'; end if;
  v_n := jsonb_array_length(p_stages);
  if v_n not between 2 and 6 then raise exception 'INVALID_STAGES'; end if;
  if exists (select 1 from jsonb_array_elements(p_stages) e
             where jsonb_typeof(e) <> 'object'
                or coalesce(char_length(btrim(e->>'title')), 0) not between 2 and 120
                -- CASE: matnli summa ::numeric da xato bermasligi uchun (OR tartibi kafolatlanmagan)
                or case when jsonb_typeof(e->'amount') = 'number'
                        then (e->>'amount')::numeric <> trunc((e->>'amount')::numeric)
                             or (e->>'amount')::numeric not between 10000 and 100000000
                        else true end) then
    raise exception 'INVALID_STAGES';
  end if;
  select jsonb_agg(jsonb_build_object('title', btrim(e->>'title'), 'amount', (e->>'amount')::int) order by ord)
    into v_plan from jsonb_array_elements(p_stages) with ordinality as t(e, ord);
  if (select sum((e->>'amount')::bigint) from jsonb_array_elements(v_plan) e) <> v_k.price then
    raise exception 'STAGES_SUM_MISMATCH';
  end if;

  update contracts set stage_plan = v_plan, stage_plan_by = v_uid where id = p_contract_id;
  select title into v_title from jobs where id = v_k.job_id;
  perform queue_notification(case when v_uid = v_k.client_id then v_k.provider_id else v_k.client_id end,
    format(E'\U0001F9E9 "%s": %s to''lovni %s bosqichga bo''lishni taklif qildi. Ko''rib chiqing.',
           v_title, case when v_uid = v_k.client_id then 'mijoz' else 'usta' end, v_n),
    '/contract/' || p_contract_id);
end;
$$;

create or replace function public.decide_stages(p_contract_id uuid, p_approve boolean)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_k contracts;
  v_title text;
begin
  select * into v_k from contracts where id = p_contract_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_uid not in (v_k.client_id, v_k.provider_id) then raise exception 'NOT_ALLOWED'; end if;
  if v_k.stage_plan is null or v_k.status <> 'active' or v_k.staged or v_k.payment_status <> 'none' then
    raise exception 'INVALID_STATE';
  end if;
  -- O'z taklifini faqat qaytarib olish mumkin, tasdiqlash — ikkinchi tomon
  if v_k.stage_plan_by = v_uid and p_approve then raise exception 'NOT_ALLOWED'; end if;
  select title into v_title from jobs where id = v_k.job_id;

  if p_approve then
    if (select sum((e->>'amount')::bigint) from jsonb_array_elements(v_k.stage_plan) e) <> v_k.price then
      raise exception 'STAGES_SUM_MISMATCH';
    end if;
    insert into contract_stages (contract_id, position, title, amount)
    select p_contract_id, t.ord, t.e->>'title', (t.e->>'amount')::int
      from jsonb_array_elements(v_k.stage_plan) with ordinality as t(e, ord);
    update contracts set staged = true, stage_plan = null, stage_plan_by = null where id = p_contract_id;
    perform queue_notification(v_k.stage_plan_by, format(
      E'✅ "%s": bosqichli to''lov rejasi tasdiqlandi. Har bosqich puli alohida kafolatga tushadi.', v_title),
      '/contract/' || p_contract_id);
  else
    update contracts set stage_plan = null, stage_plan_by = null where id = p_contract_id;
    if v_k.stage_plan_by <> v_uid then
      perform queue_notification(v_k.stage_plan_by, format(
        E'❌ "%s": bosqichli to''lov rejasi rad etildi. To''lov butun summa bo''yicha qoladi.', v_title),
        '/contract/' || p_contract_id);
    end if;
  end if;
end;
$$;

-- Usta navbatdagi bosqichni topshiradi (oldingi bosqichlar topshirilgan bo'lishi kerak)
create or replace function public.submit_stage(p_stage_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_s contract_stages;
  v_k contracts;
  v_title text;
begin
  select * into v_s from contract_stages where id = p_stage_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  select * into v_k from contracts where id = v_s.contract_id for update;
  if v_k.provider_id <> v_uid then raise exception 'NOT_ALLOWED'; end if;
  if v_k.status <> 'active' or v_s.status <> 'pending' then raise exception 'INVALID_STATE'; end if;
  if exists (select 1 from contract_stages where contract_id = v_s.contract_id
                                             and position < v_s.position and status = 'pending') then
    raise exception 'STAGE_ORDER';
  end if;

  update contract_stages set status = 'submitted', submitted_at = now() where id = p_stage_id;
  select title into v_title from jobs where id = v_k.job_id;
  perform queue_notification(v_k.client_id, format(
    E'\U0001F4E6 "%s": usta %s-bosqichni ("%s") topshirdi. Tekshirib qabul qiling — 72 soatda javob bo''lmasa avtomatik qabul qilinadi.',
    v_title, v_s.position, v_s.title), '/contract/' || v_k.id);
end;
$$;

-- Bosqichni qabul qilish (mijoz yoki 72 soatdan keyin avtomatik). Hammasi qabul qilinsa — shartnoma yakunlanadi.
create or replace function public._approve_stage(p_stage_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_s contract_stages;
  v_k contracts;
  v_title text;
  v_sum text;
  r record;
begin
  update contract_stages set status = 'approved', approved_at = now() where id = p_stage_id returning * into v_s;
  select * into v_k from contracts where id = v_s.contract_id;
  select title into v_title from jobs where id = v_k.job_id;
  v_sum := replace(to_char(v_s.amount, 'FM999,999,999'), ',', ' ');
  perform queue_notification(v_k.provider_id, format(
    E'✅ "%s": %s-bosqich ("%s") qabul qilindi.%s', v_title, v_s.position, v_s.title,
    case when v_s.payment_status = 'held' then format(E' %s so''m sizga o''tkaziladi.', v_sum) else '' end),
    '/contract/' || v_k.id);
  if v_s.payment_status = 'held' then
    for r in select id from users where is_admin and blocked_at is null and deleted_at is null loop
      perform queue_notification(r.id, format(
        E'\U0001F4B8 "%s": %s-bosqich qabul qilindi — %s so''mni ustaga o''tkazing.', v_title, v_s.position, v_sum),
        '/admin/payments');
    end loop;
  end if;
  if not exists (select 1 from contract_stages where contract_id = v_s.contract_id and status <> 'approved') then
    perform _complete_contract(v_s.contract_id);
  end if;
end;
$$;

revoke execute on function public._approve_stage(uuid) from public, anon, authenticated;

create or replace function public.approve_stage(p_stage_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_s contract_stages;
  v_k contracts;
begin
  select * into v_s from contract_stages where id = p_stage_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  select * into v_k from contracts where id = v_s.contract_id for update;
  if v_k.client_id <> v_uid then raise exception 'NOT_ALLOWED'; end if;
  if v_k.status not in ('active', 'submitted') or v_s.status = 'approved' then raise exception 'INVALID_STATE'; end if;
  perform _approve_stage(p_stage_id);
end;
$$;

-- 72 soat: butun ish (eski yo'l) va bosqichlar
create or replace function public.auto_approve_overdue()
returns int language plpgsql security definer set search_path = public as $$
declare
  r record;
  n int := 0;
begin
  for r in select id from contracts where status = 'submitted' and submitted_at < now() - interval '72 hours'
  loop
    perform _complete_contract(r.id);
    n := n + 1;
  end loop;
  for r in select st.id from contract_stages st join contracts k on k.id = st.contract_id
            where st.status = 'submitted' and st.submitted_at < now() - interval '72 hours'
              and k.status in ('active', 'submitted')
            order by st.contract_id, st.position
  loop
    -- Oldingi qadamda shartnoma yakunlangan bo'lsa bosqich allaqachon qabul qilingan
    if (select status from contract_stages where id = r.id) = 'submitted' then
      perform _approve_stage(r.id);
      n := n + 1;
    end if;
  end loop;
  -- Kafolat: usta 3 kunda tuzatmasa — hal bo'lmagan; usta tuzatdi deganidan 7 kun o'tib mijoz jim bo'lsa — hal bo'lgan
  for r in select id from warranty_claims where status = 'open' and created_at < now() - interval '72 hours' loop
    perform _close_warranty(r.id, false, true);
    n := n + 1;
  end loop;
  for r in select id from warranty_claims where status = 'fixed' and fixed_at < now() - interval '7 days' loop
    perform _close_warranty(r.id, true, true);
    n := n + 1;
  end loop;
  -- Mediatsiya taklifiga 72 soatda hech kim rad javob bermasa — qabul qilingan hisoblanadi
  for r in select id from contracts
            where status = 'disputed' and mediation_at < now() - interval '72 hours' and arbitration_at is null
  loop
    perform _accept_mediation(r.id);
    n := n + 1;
  end loop;
  -- Usta 72 soatda nizoga javob bermasa — nizo admin'ga o'tadi
  for r in select id from contracts
            where status = 'disputed' and dispute_escalated_at is null and dispute_response is null
              and disputed_at < now() - interval '72 hours'
  loop
    perform _escalate_dispute(r.id, 'auto');
    n := n + 1;
  end loop;
  return n;
end;
$$;

revoke execute on function public.auto_approve_overdue() from public, anon, authenticated;

-- Admin: pul harakati — butun shartnoma (bosqichsiz) va bosqichlar. action:
--   release — pul kafolatda, ish (bosqich) qabul qilingan: ustaga o'tkazish kerak
--   refund  — pul kafolatda, shartnoma bekor (bosqich qabul qilinmagan): mijozga qaytarish kerak
--   held    — pul kafolatda, ish davom etmoqda
--   hold    — kafolatsiz: mijoz to'lasa "qabul qilindi" deb belgilanadi (bosqichlarda — navbatdagisi)
create or replace function public.admin_get_payments()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  perform require_admin();
  select coalesce(jsonb_agg(x.row_data order by x.sort_key, x.created_at desc), '[]'::jsonb)
  into v
  from (
    select y.* from (
      select k.created_at,
        case
          when k.payment_status = 'held' and k.status = 'completed' then 1
          when k.payment_status = 'held' and k.status = 'cancelled' and k.payout_amount is not null then 1
          when k.payment_status = 'held' and k.status = 'cancelled' then 2
          when k.payment_status = 'held' then 3
          else 4
        end as sort_key,
        jsonb_build_object(
          'id', k.id, 'price', k.price, 'status', k.status, 'payment_status', k.payment_status,
          'payment_held_at', k.payment_held_at, 'held_amount', k.payment_held_amount, 'created_at', k.created_at,
          -- Nizo qisman hal qilingan: ustaga shuncha, qolgani mijozga
          'payout', k.payout_amount,
          -- Mijoz usta yo'lga chiqqach bekor qilgan: payout — ustaga chaqiruv haqi, qolgani mijozga
          'late_cancel', k.late_cancel,
          'action', case
            when k.payment_status = 'held' and k.status = 'completed' then 'release'
            when k.payment_status = 'held' and k.status = 'cancelled' and k.payout_amount is not null then 'release'
            when k.payment_status = 'held' and k.status = 'cancelled' then 'refund'
            when k.payment_status = 'held' then 'held'
            else 'hold'
          end,
          'job',      jsonb_build_object('id', j.id, 'title', j.title),
          'client',   jsonb_build_object('id', cp.id, 'full_name', cp.full_name, 'phone', cu.phone),
          'provider', jsonb_build_object('id', pp.id, 'full_name', pp.full_name, 'phone', pu.phone)
        ) as row_data
      from contracts k
      join jobs j on j.id = k.job_id
      join profiles cp on cp.id = k.client_id
      join auth.users cu on cu.id = k.client_id
      join profiles pp on pp.id = k.provider_id
      join auth.users pu on pu.id = k.provider_id
      where not k.staged
        and (k.payment_status = 'held'
             or (k.payment_status = 'none' and k.status in ('active', 'submitted', 'disputed')))
      union all
      select k.created_at,
        case
          when st.payment_status = 'held' and st.status = 'approved' and st.payout_amount = 0 then 2
          when st.payment_status = 'held' and (st.status = 'approved' or k.status = 'completed') then 1
          when st.payment_status = 'held' and k.status = 'cancelled' then 2
          when st.payment_status = 'held' then 3
          else 4
        end,
        jsonb_build_object(
          'id', k.id, 'price', st.amount, 'status', k.status, 'payment_status', st.payment_status,
          'payment_held_at', st.payment_held_at, 'held_amount', null, 'created_at', k.created_at,
          'payout', st.payout_amount,
          'stage', jsonb_build_object('id', st.id, 'position', st.position, 'title', st.title, 'status', st.status,
                                      'count', (select count(*) from contract_stages c where c.contract_id = k.id)),
          'action', case
            -- Nizo yechimida bu bosqich puli to'liq mijozga qaytadi
            when st.payment_status = 'held' and st.status = 'approved' and st.payout_amount = 0 then 'refund'
            when st.payment_status = 'held' and (st.status = 'approved' or k.status = 'completed') then 'release'
            when st.payment_status = 'held' and k.status = 'cancelled' then 'refund'
            when st.payment_status = 'held' then 'held'
            else 'hold'
          end,
          'job',      jsonb_build_object('id', j.id, 'title', j.title),
          'client',   jsonb_build_object('id', cp.id, 'full_name', cp.full_name, 'phone', cu.phone),
          'provider', jsonb_build_object('id', pp.id, 'full_name', pp.full_name, 'phone', pu.phone)
        )
      from contract_stages st
      join contracts k on k.id = st.contract_id
      join jobs j on j.id = k.job_id
      join profiles cp on cp.id = k.client_id
      join auth.users cu on cu.id = k.client_id
      join profiles pp on pp.id = k.provider_id
      join auth.users pu on pu.id = k.provider_id
      where k.staged
        and (st.payment_status = 'held'
             or (st.payment_status = 'none' and st.status <> 'approved'
                 and k.status in ('active', 'submitted', 'disputed')
                 -- to'lanmaganlardan faqat navbatdagisi
                 and st.position = (select min(c.position) from contract_stages c
                                     where c.contract_id = k.id and c.payment_status = 'none' and c.status <> 'approved')))
    ) y
    order by y.sort_key, y.created_at desc
    limit 100
  ) x;
  return v;
end;
$$;

-- Admin: bosqich puli harakati (admin_set_payment bilan bir xil o'tishlar, bosqich darajasida)
create or replace function public.admin_set_stage_payment(p_stage_id uuid, p_status text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_s contract_stages;
  v_k contracts;
  v_title text;
  v_sum text;
  v_back int;
  v_link text;
begin
  perform require_admin();
  select * into v_s from contract_stages where id = p_stage_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  select * into v_k from contracts where id = v_s.contract_id for update;
  -- Nizo yechimida bosqichga payout_amount belgilangan bo'lishi mumkin: 0 — puli to'liq mijozga qaytadi,
  -- summadan kam — ustaga shuncha o'tkaziladi, qolgani qaytariladi
  if not coalesce(
       (p_status = 'held' and v_s.payment_status = 'none' and v_k.status in ('active', 'submitted', 'disputed'))
    or (p_status = 'released' and v_s.payment_status = 'held' and (v_s.status = 'approved' or v_k.status = 'completed')
        and coalesce(v_s.payout_amount, v_s.amount) > 0)
    or (p_status = 'refunded' and v_s.payment_status = 'held'
        and ((v_k.status = 'cancelled' and v_s.status <> 'approved') or (v_s.status = 'approved' and v_s.payout_amount = 0))),
    false) then
    raise exception 'INVALID_STATE';
  end if;
  v_back := case when p_status = 'released' and v_s.payout_amount is not null
                 then v_s.amount - v_s.payout_amount else 0 end;

  update contract_stages set
    payment_status      = p_status,
    payment_held_at     = case when p_status = 'held' then now() else payment_held_at end,
    payment_released_at = case when p_status = 'released' then now() else payment_released_at end,
    payment_refunded_at = case when p_status = 'refunded' or v_back > 0 then now() else payment_refunded_at end
  where id = p_stage_id;

  select title into v_title from jobs where id = v_k.job_id;
  v_sum := replace(to_char(case when p_status = 'released' then coalesce(v_s.payout_amount, v_s.amount) else v_s.amount end,
                           'FM999,999,999'), ',', ' ');
  v_link := '/contract/' || v_k.id;
  if p_status = 'held' then
    perform queue_notification(v_k.provider_id, format(
      E'\U0001F512 "%s": %s-bosqich puli (%s so''m) Ustame''da kafolatda. Bosqichni topshiring — mijoz qabul qilgach pul sizga o''tadi.',
      v_title, v_s.position, v_sum), v_link);
    perform queue_notification(v_k.client_id, format(
      E'\U0001F512 "%s": %s-bosqich to''lovi (%s so''m) kafolatda. Bosqichni qabul qilganingizdan keyingina ustaga o''tkaziladi.',
      v_title, v_s.position, v_sum), v_link);
  elsif p_status = 'released' then
    perform queue_notification(v_k.provider_id, format(
      E'\U0001F4B8 "%s": %s-bosqich uchun %s so''m sizga o''tkazildi.', v_title, v_s.position, v_sum), v_link);
    if v_back > 0 then
      perform queue_notification(v_k.client_id, format(
        E'↩️ "%s": nizo yechimiga ko''ra %s-bosqich uchun %s so''m sizga qaytarildi.', v_title, v_s.position,
        replace(to_char(v_back, 'FM999,999,999'), ',', ' ')), v_link);
    end if;
  else
    perform queue_notification(v_k.client_id, format(
      E'↩️ "%s": %s-bosqich uchun %s so''m sizga qaytarildi.', v_title, v_s.position, v_sum), v_link);
  end if;
end;
$$;

revoke execute on function public.propose_stages(uuid, jsonb), public.decide_stages(uuid, boolean),
  public.submit_stage(uuid), public.approve_stage(uuid), public.admin_set_stage_payment(uuid, text)
from public, anon, authenticated;

grant execute on function public.propose_stages(uuid, jsonb), public.decide_stages(uuid, boolean),
  public.submit_stage(uuid), public.approve_stage(uuid), public.admin_set_stage_payment(uuid, text)
to authenticated;

grant execute on function public.admin_get_payments() to authenticated;


-- ===== brigadalar va usta-kompaniyalar =====
-- Brigada (yoki usta-kompaniya) — tasdiqlangan usta (boshliq) tuzadi va boshqa ustalarni telefon raqami
-- orqali taklif qiladi. Admin tasdiqlagach brigada katalogda ko'rinadi va boshliq takliflarni brigada nomidan
-- yuboradi. Mijoz e'longa "brigada kerak" belgisini qo'ysa, mos brigadalarga darhol xabar boradi.
-- Bir usta bir vaqtda faqat bitta brigadada bo'ladi.
create table if not exists public.teams (
  id               uuid primary key default gen_random_uuid(),
  owner_id         uuid not null unique references public.users (id) on delete cascade,
  kind             text not null default 'brigade' check (kind in ('brigade', 'company')),
  name             text not null check (char_length(name) between 3 and 60),
  description      text not null default '' check (char_length(description) <= 1000),
  size             int not null default 2 check (size between 2 and 200),
  categories       text[] not null check (cardinality(categories) between 1 and 6),
  districts        text[] not null check (cardinality(districts) between 1 and 12),
  status           text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  rejection_reason text,
  created_at       timestamptz not null default now(),
  reviewed_at      timestamptz
);

create table if not exists public.team_members (
  team_id    uuid not null references public.teams (id) on delete cascade,
  user_id    uuid not null references public.users (id) on delete cascade,
  status     text not null default 'invited' check (status in ('invited', 'active')),
  created_at timestamptz not null default now(),
  joined_at  timestamptz,
  primary key (team_id, user_id)
);

create unique index if not exists team_members_one_active on public.team_members (user_id) where status = 'active';
create index if not exists team_members_user_idx on public.team_members (user_id);

alter table public.teams enable row level security;
alter table public.team_members enable row level security;

alter table public.proposals add column if not exists team_id uuid references public.teams (id) on delete set null;
alter table public.contracts add column if not exists team_id uuid references public.teams (id) on delete set null;
alter table public.jobs add column if not exists crew_needed boolean not null default false;

create or replace function public.team_stats(p_team_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  with c as (
    select count(*) filter (where status = 'completed') as completed,
           count(*) filter (where status = 'cancelled' and cancelled_by = 'provider') as withdrawals
    from contracts where team_id = p_team_id
  ),
  r as (
    select count(*) as cnt, round(avg(rv.rating)::numeric, 1) as avg
    from reviews rv join contracts k on k.id = rv.contract_id
    where k.team_id = p_team_id and rv.reviewee_id = k.provider_id
      and review_is_public(rv.contract_id, rv.reviewer_id, rv.created_at)
  )
  select jsonb_build_object(
    'completed_jobs', c.completed,
    'withdrawals',    c.withdrawals,
    'reviews_count',  r.cnt,
    'avg_rating',     r.avg,
    'members',        (select count(*) from team_members m where m.team_id = p_team_id and m.status = 'active')
  )
  from c, r;
$$;

-- Brigada a'zolari (boshliq birinchi)
create or replace function public._team_members_json(p_team_id uuid, p_with_invited boolean)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', p.id, 'full_name', p.full_name, 'avatar_updated_at', p.avatar_updated_at,
    'headline', pp.headline, 'status', m.status, 'is_owner', p.id = t.owner_id,
    'stats', provider_stats(p.id)
  ) order by p.id = t.owner_id desc, m.status, m.joined_at nulls last, m.created_at), '[]'::jsonb)
  from team_members m
  join teams t on t.id = m.team_id
  join profiles p on p.id = m.user_id
  left join provider_profiles pp on pp.user_id = m.user_id
  where m.team_id = p_team_id and (p_with_invited or m.status = 'active');
$$;

revoke execute on function public._team_members_json(uuid, boolean) from public, anon, authenticated;

create or replace function public.save_team(
  p_kind text, p_name text, p_description text, p_size int, p_categories text[], p_districts text[]
)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_team teams;
  v_name text := btrim(coalesce(p_name, ''));
  r record;
begin
  if not is_approved_provider(v_uid) then raise exception 'NOT_APPROVED_PROVIDER'; end if;
  if coalesce(p_kind, '') not in ('brigade', 'company') then raise exception 'INVALID_INPUT'; end if;
  if char_length(v_name) not between 3 and 60 then raise exception 'INVALID_NAME'; end if;
  if char_length(coalesce(p_description, '')) > 1000 then raise exception 'INVALID_BIO'; end if;
  if p_size is null or p_size not between 2 and 200 then raise exception 'INVALID_INPUT'; end if;
  if coalesce(cardinality(p_categories), 0) not between 1 and 6 then raise exception 'INVALID_CATEGORIES'; end if;
  if coalesce(cardinality(p_districts), 0) not between 1 and 12 then raise exception 'INVALID_DISTRICTS'; end if;

  select * into v_team from teams where owner_id = v_uid for update;
  if not found then
    -- Boshqa brigada a'zosi o'z brigadasini tuza olmaydi (avval chiqishi kerak)
    if exists (select 1 from team_members where user_id = v_uid and status = 'active') then
      raise exception 'ALREADY_IN_TEAM';
    end if;
    insert into teams (owner_id, kind, name, description, size, categories, districts)
    values (v_uid, p_kind, v_name, btrim(coalesce(p_description, '')), p_size, p_categories, p_districts)
    returning * into v_team;
    insert into team_members (team_id, user_id, status, joined_at) values (v_team.id, v_uid, 'active', now());
    -- Boshliqning boshqa brigadalardan kelgan takliflari endi kerak emas
    delete from team_members where user_id = v_uid and status = 'invited';
    for r in select id from users where is_admin and blocked_at is null and deleted_at is null loop
      perform queue_notification(r.id, format(E'\U0001F477 Yangi %s arizasi: "%s".',
        case when p_kind = 'company' then 'usta-kompaniya' else 'brigada' end, v_name), '/admin/teams');
    end loop;
  else
    update teams set
      kind = p_kind, name = v_name, description = btrim(coalesce(p_description, '')), size = p_size,
      categories = p_categories, districts = p_districts,
      status = case when status = 'rejected' then 'pending' else status end,
      rejection_reason = case when status = 'rejected' then null else rejection_reason end
    where id = v_team.id
    returning * into v_team;
  end if;
  return v_team.status;
end;
$$;

-- Mening brigadam: o'zim boshliq yoki a'zo bo'lgan brigada + menga kelgan takliflar
create or replace function public.get_my_team()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_team teams;
begin
  select t.* into v_team from teams t
    join team_members m on m.team_id = t.id
   where m.user_id = v_uid and m.status = 'active';
  return jsonb_build_object(
    'team', case when v_team.id is not null then jsonb_build_object(
      'id', v_team.id, 'kind', v_team.kind, 'name', v_team.name, 'description', v_team.description,
      'size', v_team.size, 'categories', v_team.categories, 'districts', v_team.districts,
      'status', v_team.status, 'rejection_reason', v_team.rejection_reason,
      'is_owner', v_team.owner_id = v_uid,
      'members', _team_members_json(v_team.id, v_team.owner_id = v_uid),
      'stats', team_stats(v_team.id)) end,
    'invites', coalesce((
      select jsonb_agg(jsonb_build_object('team_id', t.id, 'name', t.name, 'kind', t.kind,
                                          'owner_name', o.full_name, 'created_at', m.created_at)
                       order by m.created_at desc)
      from team_members m join teams t on t.id = m.team_id join profiles o on o.id = t.owner_id
      where m.user_id = v_uid and m.status = 'invited'), '[]'::jsonb)
  );
end;
$$;

-- Boshliq ustani telefon raqami orqali brigadaga taklif qiladi
create or replace function public.invite_team_member(p_phone text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_team teams;
  v_digits text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  v_user uuid;
begin
  select * into v_team from teams where owner_id = v_uid;
  if not found then raise exception 'NOT_ALLOWED'; end if;
  if char_length(v_digits) = 9 then v_digits := '998' || v_digits; end if;
  if char_length(v_digits) <> 12 then raise exception 'INVALID_PHONE'; end if;
  select id into v_user from users where phone = v_digits and deleted_at is null and blocked_at is null;
  if v_user is null then raise exception 'USER_NOT_FOUND'; end if;
  if v_user = v_uid or exists (select 1 from team_members where team_id = v_team.id and user_id = v_user) then
    raise exception 'ALREADY_IN_TEAM';
  end if;
  if not is_approved_provider(v_user) then raise exception 'MEMBER_NOT_PROVIDER'; end if;
  if exists (select 1 from team_members where user_id = v_user and status = 'active') then
    raise exception 'ALREADY_IN_TEAM';
  end if;
  if (select count(*) from team_members where team_id = v_team.id) >= 50 then raise exception 'TEAM_FULL'; end if;

  insert into team_members (team_id, user_id) values (v_team.id, v_user);
  perform queue_notification(v_user, format(E'\U0001F477 "%s" %s sizni a''zo bo''lishga taklif qildi. Ilovada qabul qiling yoki rad eting.',
    v_team.name, case when v_team.kind = 'company' then 'usta-kompaniyasi' else 'brigadasi' end), '/my-team');
end;
$$;

create or replace function public.respond_team_invite(p_team_id uuid, p_accept boolean)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_team teams;
  v_name text;
begin
  if not exists (select 1 from team_members where team_id = p_team_id and user_id = v_uid and status = 'invited') then
    raise exception 'NOT_FOUND';
  end if;
  select * into v_team from teams where id = p_team_id;
  select full_name into v_name from profiles where id = v_uid;
  if p_accept then
    if exists (select 1 from team_members where user_id = v_uid and status = 'active') then
      raise exception 'ALREADY_IN_TEAM';
    end if;
    update team_members set status = 'active', joined_at = now() where team_id = p_team_id and user_id = v_uid;
    -- Boshqa takliflar endi kerak emas
    delete from team_members where user_id = v_uid and status = 'invited';
    perform queue_notification(v_team.owner_id, format(E'✅ %s "%s" ga qo''shildi.', v_name, v_team.name), '/my-team');
  else
    delete from team_members where team_id = p_team_id and user_id = v_uid;
    perform queue_notification(v_team.owner_id, format(E'❌ %s "%s" ga taklifni rad etdi.', v_name, v_team.name), '/my-team');
  end if;
end;
$$;

-- Boshliq a'zoni chiqaradi yoki a'zo o'zi chiqib ketadi
create or replace function public.remove_team_member(p_user_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_m team_members;
  v_team teams;
begin
  select * into v_m from team_members where user_id = p_user_id
     and team_id = coalesce((select id from teams where owner_id = v_uid),
                            (select team_id from team_members where user_id = v_uid and status = 'active'));
  if not found then raise exception 'NOT_FOUND'; end if;
  select * into v_team from teams where id = v_m.team_id;
  if p_user_id = v_team.owner_id then raise exception 'NOT_ALLOWED'; end if;
  if v_uid <> v_team.owner_id and v_uid <> p_user_id then raise exception 'NOT_ALLOWED'; end if;
  delete from team_members where team_id = v_m.team_id and user_id = p_user_id;
  if v_uid = v_team.owner_id then
    perform queue_notification(p_user_id, format(E'"%s" a''zoligingiz tugatildi.', v_team.name), '/my-team');
  else
    perform queue_notification(v_team.owner_id, format(E'%s "%s" dan chiqdi.',
      (select full_name from profiles where id = v_uid), v_team.name), '/my-team');
  end if;
end;
$$;

create or replace function public.delete_my_team()
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := require_uid();
begin
  delete from teams where owner_id = v_uid;
  if not found then raise exception 'NOT_FOUND'; end if;
end;
$$;

-- Brigadaning ommaviy sahifasi (tasdiqlangan; boshliq o'z brigadasini har doim ko'radi)
create or replace function public.get_team(p_team_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_team teams;
begin
  select * into v_team from teams where id = p_team_id;
  if not found or (v_team.status <> 'approved' and v_team.owner_id <> v_uid) then raise exception 'NOT_FOUND'; end if;
  return jsonb_build_object(
    'id', v_team.id, 'kind', v_team.kind, 'name', v_team.name, 'description', v_team.description,
    'size', v_team.size, 'categories', v_team.categories, 'districts', v_team.districts,
    'status', v_team.status, 'created_at', v_team.created_at,
    'owner', (select jsonb_build_object('id', p.id, 'full_name', p.full_name) from profiles p where p.id = v_team.owner_id),
    'members', _team_members_json(v_team.id, false),
    'stats', team_stats(v_team.id)
  );
end;
$$;

create or replace function public.search_teams(
  p_category text default null, p_district text default null, p_limit int default 30, p_offset int default 0
)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := require_uid();
begin
  return coalesce((
    select jsonb_agg(x.item order by (x.item->'stats'->>'completed_jobs')::int desc,
                                     (x.item->'stats'->>'avg_rating')::numeric desc nulls last, x.created_at desc)
    from (
      select t.created_at, jsonb_build_object(
        'id', t.id, 'kind', t.kind, 'name', t.name, 'description', left(t.description, 200), 'size', t.size,
        'categories', t.categories, 'districts', t.districts,
        'owner', jsonb_build_object('id', o.id, 'full_name', o.full_name),
        'stats', team_stats(t.id)
      ) as item
      from teams t join profiles o on o.id = t.owner_id
      where t.status = 'approved'
        and is_approved_provider(t.owner_id)
        and not _blocked(v_uid, t.owner_id)
        and (p_category is null or p_category = any (t.categories))
        and (p_district is null or p_district = any (t.districts))
      order by t.created_at desc
      limit least(greatest(coalesce(p_limit, 30), 1), 50) offset greatest(coalesce(p_offset, 0), 0)
    ) x
  ), '[]'::jsonb);
end;
$$;

-- Mijoz: e'longa "brigada kerak" belgisi. Yoqilganda mos tasdiqlangan brigadalarga darhol xabar boradi.
create or replace function public.set_job_crew(p_job_id uuid, p_needed boolean)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_job jobs;
  r record;
begin
  select * into v_job from jobs where id = p_job_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_job.client_id <> v_uid then raise exception 'NOT_ALLOWED'; end if;
  if v_job.status <> 'open' then raise exception 'JOB_NOT_OPEN'; end if;
  update jobs set crew_needed = coalesce(p_needed, false) where id = p_job_id;
  if coalesce(p_needed, false) and not v_job.crew_needed then
    for r in select t.owner_id from teams t
              where t.status = 'approved' and v_job.category = any (t.categories) and v_job.district = any (t.districts)
                and is_approved_provider(t.owner_id) and not _blocked(t.owner_id, v_uid)
    loop
      perform queue_notification(r.owner_id, format(E'\U0001F477 Brigada kerak: "%s" (%s, %s). Brigadangiz nomidan taklif yuboring.',
        v_job.title, v_job.category, v_job.district), '/job/' || p_job_id);
    end loop;
  end if;
end;
$$;

-- Admin: tasdiq kutayotgan brigadalar
create or replace function public.admin_get_pending_teams()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform require_admin();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', t.id, 'kind', t.kind, 'name', t.name, 'description', t.description, 'size', t.size,
      'categories', t.categories, 'districts', t.districts, 'created_at', t.created_at,
      'owner', (select jsonb_build_object('id', u.id, 'full_name', u.full_name, 'phone', u.phone,
                                          'stats', provider_stats(u.id)) from users u where u.id = t.owner_id),
      'members', _team_members_json(t.id, true)
    ) order by t.created_at)
    from teams t where t.status = 'pending'
  ), '[]'::jsonb);
end;
$$;

create or replace function public.admin_review_team(p_team_id uuid, p_approve boolean, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_team teams;
begin
  perform require_admin();
  if not p_approve and char_length(btrim(coalesce(p_reason, ''))) < 3 then raise exception 'REASON_REQUIRED'; end if;
  update teams set status = case when p_approve then 'approved' else 'rejected' end,
                   rejection_reason = case when p_approve then null else left(btrim(p_reason), 500) end,
                   reviewed_at = now()
   where id = p_team_id and status = 'pending'
  returning * into v_team;
  if not found then raise exception 'INVALID_STATE'; end if;
  perform queue_notification(v_team.owner_id,
    case when p_approve
      then format(E'✅ "%s" tasdiqlandi — endi katalogda ko''rinasiz va brigada nomidan taklif yubora olasiz.', v_team.name)
      else format(E'❌ "%s" rad etildi. Sabab: %s', v_team.name, btrim(p_reason))
    end, '/my-team');
end;
$$;

revoke execute on function public.team_stats(uuid), public.save_team(text, text, text, int, text[], text[]),
  public.get_my_team(), public.invite_team_member(text), public.respond_team_invite(uuid, boolean),
  public.remove_team_member(uuid), public.delete_my_team(), public.get_team(uuid),
  public.search_teams(text, text, int, int), public.set_job_crew(uuid, boolean),
  public.admin_get_pending_teams(), public.admin_review_team(uuid, boolean, text)
from public, anon, authenticated;

grant execute on function public.team_stats(uuid), public.save_team(text, text, text, int, text[], text[]),
  public.get_my_team(), public.invite_team_member(text), public.respond_team_invite(uuid, boolean),
  public.remove_team_member(uuid), public.delete_my_team(), public.get_team(uuid),
  public.search_teams(text, text, int, int), public.set_job_crew(uuid, boolean),
  public.admin_get_pending_teams(), public.admin_review_team(uuid, boolean, text)
to authenticated;


-- ===== ilova ichidagi bildirishnomalar =====
-- notification_outbox'dagi xabarlar (push/Telegram'ga ketganlari ham) ilovada ro'yxat bo'lib ko'rinadi.
do $$ begin
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'notification_outbox' and column_name = 'read_at') then
    alter table public.notification_outbox add column read_at timestamptz;
    -- Bu ustun qo'shilishidan oldingi xabarlar o'qilgan hisoblanadi (birinchi ochilishda 100 ta "yangi" chiqmasin)
    update public.notification_outbox set read_at = now();
  end if;
end $$;

create index if not exists notification_outbox_user_idx on public.notification_outbox (user_id, created_at desc);

create or replace function public.get_my_notifications()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', n.id, 'message', n.message, 'link', n.link,
                                               'created_at', n.created_at, 'read', n.read_at is not null)
                            order by n.created_at desc), '[]'::jsonb)
  from (select * from notification_outbox
         where user_id = auth.uid() and created_at > now() - interval '30 days'
         order by created_at desc limit 100) n;
$$;

create or replace function public.get_unread_notifications()
returns int language sql stable security definer set search_path = public as $$
  select count(*)::int from notification_outbox
   where user_id = auth.uid() and read_at is null and created_at > now() - interval '30 days';
$$;

create or replace function public.mark_notifications_read()
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := require_uid();
begin
  update notification_outbox set read_at = now() where user_id = v_uid and read_at is null;
end;
$$;

-- ===== yangi e'lon — mos ustalarga xabar =====
-- Shoshilinch e'lonlar notify_urgent_job orqali ketadi; qolganlari — kasbi va tumani mos tasdiqlangan
-- ustalarga. Spam bo'lmasin: ustaga kuniga ko'pi bilan 10 ta shunday xabar.
create or replace function public.notify_new_job()
returns trigger language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if new.status <> 'open' or new.urgency = 'urgent' then return new; end if;
  for r in
    select pp.user_id from provider_profiles pp
     where pp.status = 'approved' and pp.user_id <> new.client_id
       and new.category = any (pp.categories) and new.district = any (pp.districts)
       and not _blocked(pp.user_id, new.client_id)
       and (select count(*) from notification_outbox o
             where o.user_id = pp.user_id and o.created_at > now() - interval '24 hours'
               and o.message like E'\U0001F195%') < 10
  loop
    perform queue_notification(r.user_id, format(E'\U0001F195 Yangi e''lon: "%s" (%s, %s). Narxingizni taklif qiling.',
      new.title, new.category, new.district), '/job/' || new.id);
  end loop;
  return new;
end;
$$;

drop trigger if exists trg_notify_new_job on public.jobs;
create trigger trg_notify_new_job after insert on public.jobs
for each row execute function public.notify_new_job();

revoke execute on function public.get_my_notifications(), public.get_unread_notifications(),
  public.mark_notifications_read()
from public, anon, authenticated;

grant execute on function public.get_my_notifications(), public.get_unread_notifications(),
  public.mark_notifications_read()
to authenticated;


-- ===== taklif bo'yicha chat (yollashdan oldin) =====
-- Mijoz ustani tanlashdan oldin unga savol bera oladi (Upwork'dagi kabi). Xabar taklifga bog'lanadi;
-- taklif qabul qilinsa, shu yozishma shartnoma chatida davom etadi (get_messages ikkalasini qaytaradi).
alter table public.messages add column if not exists proposal_id uuid references public.proposals (id) on delete cascade;
alter table public.messages alter column contract_id drop not null;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'messages_target_check') then
    alter table public.messages add constraint messages_target_check check (contract_id is not null or proposal_id is not null);
  end if;
end $$;
create index if not exists messages_proposal_idx on public.messages (proposal_id, created_at) where proposal_id is not null;

-- Taklif ishtirokchisini tekshiradi: usta yoki e'lon egasi. Qaytaradi: (usta, mijoz)
create or replace function public._proposal_parties(p_proposal_id uuid, out provider_id uuid, out client_id uuid, out status text)
language sql stable security definer set search_path = public as $$
  select p.provider_id, j.client_id, p.status from proposals p join jobs j on j.id = p.job_id where p.id = p_proposal_id;
$$;

revoke execute on function public._proposal_parties(uuid) from public, anon, authenticated;

create or replace function public.send_proposal_message(p_proposal_id uuid, p_text text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_pp record;
  v_text text := btrim(coalesce(p_text, ''));
  v_id uuid;
  v_created timestamptz;
begin
  if char_length(v_text) < 1 or char_length(v_text) > 1000 then raise exception 'INVALID_MESSAGE'; end if;
  select * into v_pp from _proposal_parties(p_proposal_id);
  if v_pp.provider_id is null then raise exception 'NOT_FOUND'; end if;
  if v_uid <> v_pp.provider_id and v_uid <> v_pp.client_id then raise exception 'NOT_ALLOWED'; end if;
  -- Rad etilgan yoki qaytarib olingan taklif bo'yicha yozishma yopiq
  if v_pp.status not in ('submitted', 'accepted') then raise exception 'CHAT_CLOSED'; end if;
  if _blocked(v_pp.provider_id, v_pp.client_id) then raise exception 'USER_BLOCKED'; end if;
  -- Shartnomagacha kontakt almashib bo'lmaydi; tuzilgach telefon raqami o'zi ko'rinadi
  if v_pp.status = 'submitted' and _has_contact(v_text) then raise exception 'CONTACT_NOT_ALLOWED'; end if;

  insert into messages (proposal_id, sender_id, text) values (p_proposal_id, v_uid, v_text)
  returning id, created_at into v_id, v_created;
  return jsonb_build_object('id', v_id, 'sender_id', v_uid, 'text', v_text, 'created_at', v_created, 'read_at', null);
end;
$$;

create or replace function public.get_proposal_messages(p_proposal_id uuid, p_after timestamptz default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_pp record;
begin
  select * into v_pp from _proposal_parties(p_proposal_id);
  if v_pp.provider_id is null then raise exception 'NOT_FOUND'; end if;
  if v_uid <> v_pp.provider_id and v_uid <> v_pp.client_id then raise exception 'NOT_ALLOWED'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', m.id, 'sender_id', m.sender_id, 'text', m.text,
                                        'created_at', m.created_at, 'read_at', m.read_at,
                                        'kind', m.kind, 'agreement_id', m.agreement_id) order by m.created_at asc)
    from messages m
    where m.proposal_id = p_proposal_id and (p_after is null or m.created_at > p_after)
  ), '[]'::jsonb);
end;
$$;

create or replace function public.mark_proposal_messages_read(p_proposal_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_pp record;
begin
  select * into v_pp from _proposal_parties(p_proposal_id);
  if v_pp.provider_id is null then raise exception 'NOT_FOUND'; end if;
  if v_uid <> v_pp.provider_id and v_uid <> v_pp.client_id then raise exception 'NOT_ALLOWED'; end if;
  update messages set read_at = now()
   where proposal_id = p_proposal_id and sender_id <> v_uid and read_at is null;
end;
$$;

-- Yangi xabar: shartnoma yoki taklif chati — qarshi tomonga bildirishnoma
create or replace function public.notify_new_message()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_recipient uuid;
  v_sender_name text;
  v_link text;
  v_pp record;
begin
  -- Kelishuv tizim xabari: bildirishnomani _agreement_event o'zi yuboradi (takror bo'lmasin)
  if new.kind = 'system' then return new; end if;
  if new.contract_id is not null then
    select case when client_id = new.sender_id then provider_id else client_id end
      into v_recipient from contracts where id = new.contract_id;
    v_link := '/chat/' || new.contract_id;
  else
    select * into v_pp from _proposal_parties(new.proposal_id);
    v_recipient := case when new.sender_id = v_pp.client_id then v_pp.provider_id else v_pp.client_id end;
    v_link := '/proposal-chat/' || new.proposal_id;
  end if;
  select full_name into v_sender_name from profiles where id = new.sender_id;
  perform queue_notification(v_recipient, format(E'\U0001F4AC %s: %s', v_sender_name, left(new.text, 200)), v_link);
  return new;
end;
$$;

revoke execute on function public.send_proposal_message(uuid, text), public.get_proposal_messages(uuid, timestamptz),
  public.mark_proposal_messages_read(uuid)
from public, anon, authenticated;

grant execute on function public.send_proposal_message(uuid, text), public.get_proposal_messages(uuid, timestamptz),
  public.mark_proposal_messages_read(uuid)
to authenticated;


-- ===== shaxsi tasdiqlangan usta =====
-- Odatda pasport ilovada yuklanadi va admin_review_provider bilan tasdiqlanadi. Bu yerda — qo'lda: admin pasportni
-- uchrashuvda yoki video qo'ng'iroqda ko'rgan bo'lsa, yoki soxta hujjat aniqlanib tasdiqni bekor qilsa.
create or replace function public.admin_set_verified(p_user_id uuid, p_verified boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform require_admin();
  update provider_profiles set id_verified_at = case when p_verified then coalesce(id_verified_at, now()) end
   where user_id = p_user_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  delete from files where bucket = 'id-docs' and path like p_user_id::text || '/%';
  if p_verified then
    perform queue_notification(p_user_id,
      E'\U0001F6E1 Shaxsingiz tasdiqlandi — profilingizda "Shaxsi tasdiqlangan" belgisi chiqadi.', '/');
  end if;
end;
$$;

revoke execute on function public.admin_set_verified(uuid, boolean) from public, anon, authenticated;
grant execute on function public.admin_set_verified(uuid, boolean) to authenticated;


-- ===== saqlangan e'lonlar (Upwork'dagi Saved jobs) =====
create table if not exists public.saved_jobs (
  user_id    uuid not null references public.users (id) on delete cascade,
  job_id     uuid not null references public.jobs (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, job_id)
);

alter table public.saved_jobs enable row level security;

-- Saqlash yoki saqlanganlardan olib tashlash; qaytaradi: endi saqlanganmi
create or replace function public.toggle_saved_job(p_job_id uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_uid uuid := require_uid();
begin
  delete from saved_jobs where user_id = v_uid and job_id = p_job_id;
  if found then return false; end if;
  if not exists (select 1 from jobs where id = p_job_id) then raise exception 'NOT_FOUND'; end if;
  insert into saved_jobs (user_id, job_id) values (v_uid, p_job_id);
  return true;
end;
$$;

create or replace function public.get_saved_jobs()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := require_uid();
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', j.id, 'title', j.title, 'description', left(j.description, 240),
      'category', j.category, 'district', j.district, 'budget', j.budget,
      'budget_max', (select d.budget_max from job_details d where d.job_id = j.id and d.budget_type = 'range'),
      'urgency', j.urgency, 'created_at', j.created_at, 'has_photo', j.has_photo,
      'crew_needed', j.crew_needed, 'status', j.status,
      'lat', j.approx_lat, 'lng', j.approx_lng,
      'proposals_count', (select count(*) from proposals p where p.job_id = j.id and p.status = 'submitted'),
      'has_applied', exists (select 1 from proposals p where p.job_id = j.id and p.provider_id = v_uid),
      'is_saved', true,
      'client', jsonb_build_object('full_name', c.full_name, 'stats', client_stats(c.id))
    ) order by s.created_at desc)
    from saved_jobs s
    join jobs j on j.id = s.job_id
    join profiles c on c.id = j.client_id
    where s.user_id = v_uid and not _blocked(v_uid, j.client_id)
  ), '[]'::jsonb);
end;
$$;

revoke execute on function public.toggle_saved_job(uuid), public.get_saved_jobs() from public, anon, authenticated;
grant execute on function public.toggle_saved_job(uuid), public.get_saved_jobs() to authenticated;


-- ===== nizolarni hal qilish (Upwork usulida) =====
-- 1. Mijoz topshirilgan ishni (yoki bosqichni) nizo ochmasdan tuzatishga qaytaradi — sababi bilan, 3 martagacha.
-- 2. Nizo ochilsa usta 72 soat ichida javob beradi (izoh va dalil rasmlari); javob bermasa nizo admin'ga o'tadi.
-- 3. Tomonlar kelishuv taklif qiladi: "ustaga X so'm, qolgani mijozga". Ikkinchi tomon qabul qilsa nizo yopiladi.
--    Ikkinchi tomon foydasiga to'liq taklif (usta pulni to'liq qaytaradi / mijoz to'liq to'laydi) darhol kuchga kiradi.
-- 4. Usta javob bergach istalgan tomon nizoni admin'ga yuboradi; admin summani bo'lib hal qiladi (sababi bilan).
-- 5. Mijoz nizoni qaytarib olishi mumkin — ish davom etadi.
create table if not exists public.revision_requests (
  id          uuid primary key default gen_random_uuid(),
  contract_id uuid not null references public.contracts (id) on delete cascade,
  stage_id    uuid references public.contract_stages (id) on delete cascade,
  reason      text not null check (char_length(reason) between 5 and 1000),
  created_at  timestamptz not null default now()
);

create index if not exists revision_requests_contract_idx on public.revision_requests (contract_id);

alter table public.revision_requests enable row level security;

create table if not exists public.dispute_offers (
  id              uuid primary key default gen_random_uuid(),
  contract_id     uuid not null references public.contracts (id) on delete cascade,
  proposed_by     uuid not null references public.users (id) on delete cascade,
  provider_amount int not null check (provider_amount >= 0),
  note            text not null default '' check (char_length(note) <= 500),
  status          text not null default 'pending' check (status in ('pending', 'accepted', 'declined', 'cancelled')),
  created_at      timestamptz not null default now(),
  decided_at      timestamptz
);

create unique index if not exists dispute_offers_one_pending on public.dispute_offers (contract_id) where status = 'pending';

alter table public.dispute_offers enable row level security;

-- Nizodagi summa: bosqichli shartnomada — hali qabul qilinmagan bosqichlar, aks holda butun narx
create or replace function public._dispute_amount(p_contract_id uuid)
returns int language sql stable security definer set search_path = public as $$
  select case when k.staged
              then (select coalesce(sum(st.amount), 0)::int from contract_stages st
                     where st.contract_id = k.id and st.status <> 'approved')
              else k.price end
  from contracts k where k.id = p_contract_id;
$$;

-- Dalil rasmlari: dispute-photos/<shartnoma id>/client-1..4.jpg (mijoz), provider-1..4.jpg (usta).
-- Har tomon nizo ochiq paytda o'zinikini yuklaydi (internal/api/files.go), ikkala tomon va admin ko'radi.
create or replace function public._dispute_photos(p_contract_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('name', n.name, 'v', (extract(epoch from f.updated_at) * 1000)::bigint)
                            order by n.ord), '[]'::jsonb)
  from unnest(array['client-1.jpg', 'client-2.jpg', 'client-3.jpg', 'client-4.jpg',
                    'provider-1.jpg', 'provider-2.jpg', 'provider-3.jpg', 'provider-4.jpg'])
       with ordinality as n(name, ord)
  join files f on f.bucket = 'dispute-photos' and f.path = p_contract_id::text || '/' || n.name;
$$;

-- 1250000 -> "1 250 000"
create or replace function public._som(p int)
returns text language sql stable as $$
  select replace(to_char(p, 'FM999,999,999'), ',', ' ');
$$;

create or replace function public._notify_admins(p_message text, p_link text)
returns void language plpgsql security definer set search_path = public as $$
declare r record;
begin
  for r in select id from users where is_admin and blocked_at is null and deleted_at is null loop
    perform queue_notification(r.id, p_message, p_link);
  end loop;
end;
$$;

-- Nizoni yopish: ustaga p_payout so'm (nizodagi summadan), qolgani mijozga.
--   0           — shartnoma bekor, pul to'liq mijozga qaytadi
--   to'liq summa — shartnoma yakunlanadi
--   oraliq       — shartnoma yakunlanadi, payout_amount yoziladi (bosqichlarda — tartib bo'yicha taqsimlanadi)
-- p_kind: provider / client / split — admin qarori, settled — tomonlar kelishdi.
create or replace function public._resolve_dispute(p_contract_id uuid, p_payout int, p_kind text, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_k contracts;
  v_amount int;
  v_payout int;
  v_left int;
  v_give int;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_title text;
  v_msg text;
  v_link text := '/contract/' || p_contract_id;
  r record;
begin
  select * into v_k from contracts where id = p_contract_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_k.status <> 'disputed' then raise exception 'INVALID_STATE'; end if;
  v_amount := _dispute_amount(p_contract_id);
  v_payout := greatest(0, least(coalesce(p_payout, 0), v_amount));

  update dispute_offers set status = 'cancelled', decided_at = now()
   where contract_id = p_contract_id and status = 'pending';
  update contracts
     set dispute_resolution = p_kind, resolved_at = now(), dispute_note = v_note,
         payout_amount = case when v_payout > 0 and v_payout < v_amount then v_payout end
   where id = p_contract_id;

  if v_payout = 0 then
    update contracts set status = 'cancelled', cancelled_at = now(), cancelled_by = 'admin' where id = p_contract_id;
    update jobs set status = 'cancelled', closed_at = now() where id = v_k.job_id;
  else
    if v_k.staged and v_payout < v_amount then
      -- Ustaga tegadigan summa qabul qilinmagan bosqichlarga tartib bo'yicha taqsimlanadi
      v_left := v_payout;
      for r in select id, amount from contract_stages
                where contract_id = p_contract_id and status <> 'approved' order by position loop
        v_give := least(v_left, r.amount);
        update contract_stages set payout_amount = case when v_give < r.amount then v_give end where id = r.id;
        v_left := v_left - v_give;
      end loop;
    end if;
    perform _complete_contract(p_contract_id);
  end if;

  select title into v_title from jobs where id = v_k.job_id;
  v_msg := format(E'⚖️ "%s": nizo %s yopildi — ustaga %s so''m%s.', v_title,
             case when p_kind = 'settled' then 'kelishuv bilan' else 'admin qarori bilan' end, _som(v_payout),
             case when v_amount > v_payout then format(E', mijozga %s so''m qaytariladi', _som(v_amount - v_payout)) else '' end)
        || case when v_note is not null then format(E' Izoh: %s', left(v_note, 300)) else '' end;
  perform queue_notification(v_k.client_id, v_msg, v_link);
  perform queue_notification(v_k.provider_id, v_msg, v_link);
  if v_k.payment_status = 'held'
     or exists (select 1 from contract_stages where contract_id = p_contract_id and payment_status = 'held') then
    perform _notify_admins(format(E'\U0001F4B8 "%s": nizo yopildi — kafolatdagi pulni yechimga ko''ra o''tkazing.', v_title),
                           '/admin/payments');
  end if;
end;
$$;

-- Nizoni admin'ga o'tkazish. p_by: client / provider — o'sha tomon yubordi, auto — usta 72 soatda javob bermadi.
create or replace function public._escalate_dispute(p_contract_id uuid, p_by text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_k contracts;
  v_title text;
  v_msg text;
  v_link text := '/contract/' || p_contract_id;
begin
  update contracts set dispute_escalated_at = now(), dispute_escalated_by = p_by
   where id = p_contract_id and status = 'disputed' and dispute_escalated_at is null
  returning * into v_k;
  if not found then raise exception 'INVALID_STATE'; end if;
  select title into v_title from jobs where id = v_k.job_id;
  v_msg := format(E'⚖️ "%s": nizo admin''ga o''tdi%s. Admin ikkala tomonning dalillarini ko''rib murosa taklif qiladi, uni rad etsangiz — yakuniy qaror chiqaradi. Shu paytgacha o''zingiz kelishib olsangiz ham bo''ladi.',
             v_title, case when p_by = 'auto' then ' (usta 72 soat ichida javob bermadi)' else '' end);
  if p_by <> 'client' then perform queue_notification(v_k.client_id, v_msg, v_link); end if;
  if p_by <> 'provider' then perform queue_notification(v_k.provider_id, v_msg, v_link); end if;
  perform _notify_admins(format(E'⚖️ "%s": nizo qaroringizni kutmoqda.', v_title), '/admin/disputes');
end;
$$;

-- Mijoz: topshirilgan ish (yoki bosqich) yoqmasa — nizo ochmasdan tuzatishga qaytaradi (3 martagacha).
-- Usta tuzatib qayta topshirgach 72 soatlik muddat yangidan boshlanadi.
create or replace function public.request_revision(p_contract_id uuid, p_reason text, p_stage_id uuid default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_k contracts;
  v_s contract_stages;
  v_title text;
begin
  if char_length(btrim(coalesce(p_reason, ''))) < 5 then raise exception 'REASON_REQUIRED'; end if;
  select * into v_k from contracts where id = p_contract_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_k.client_id <> v_uid then raise exception 'NOT_ALLOWED'; end if;
  if p_stage_id is null then
    if v_k.staged or v_k.status <> 'submitted' then raise exception 'INVALID_STATE'; end if;
  else
    select * into v_s from contract_stages where id = p_stage_id and contract_id = p_contract_id for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    if v_k.status <> 'active' or v_s.status <> 'submitted' then raise exception 'INVALID_STATE'; end if;
  end if;
  if (select count(*) from revision_requests
       where contract_id = p_contract_id and stage_id is not distinct from p_stage_id) >= 3 then
    raise exception 'REVISION_LIMIT';
  end if;

  insert into revision_requests (contract_id, stage_id, reason)
  values (p_contract_id, p_stage_id, left(btrim(p_reason), 1000));
  if p_stage_id is null then
    update contracts set status = 'active', submitted_at = null where id = p_contract_id;
  else
    update contract_stages set status = 'pending', submitted_at = null where id = p_stage_id;
  end if;

  select title into v_title from jobs where id = v_k.job_id;
  perform queue_notification(v_k.provider_id, format(
    E'\U0001F501 "%s": mijoz %stuzatishni so''radi. Sabab: %s. Tuzatib, qayta topshiring.', v_title,
    case when p_stage_id is null then 'ishni ' else format(E'%s-bosqichni ', v_s.position) end,
    left(btrim(p_reason), 300)), '/contract/' || p_contract_id);
end;
$$;

-- Usta: nizo bo'yicha o'z javobi (qayta yozsa yangilanadi). Javob berilgach istalgan tomon nizoni admin'ga yuboradi.
create or replace function public.respond_dispute(p_contract_id uuid, p_text text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_k contracts;
  v_title text;
begin
  if char_length(btrim(coalesce(p_text, ''))) < 5 then raise exception 'REASON_REQUIRED'; end if;
  select * into v_k from contracts where id = p_contract_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_k.provider_id <> v_uid then raise exception 'NOT_ALLOWED'; end if;
  if v_k.status <> 'disputed' then raise exception 'INVALID_STATE'; end if;
  update contracts set dispute_response = left(btrim(p_text), 1000), dispute_responded_at = now()
   where id = p_contract_id;
  select title into v_title from jobs where id = v_k.job_id;
  perform queue_notification(v_k.client_id, format(
    E'\U0001F4AC "%s": usta nizo bo''yicha javob berdi: %s', v_title, left(btrim(p_text), 300)),
    '/contract/' || p_contract_id);
end;
$$;

-- Istalgan tomon: nizoni admin'ga yuborish (usta javob bergandan keyin; javob bo'lmasa 72 soatdan keyin o'zi o'tadi)
create or replace function public.escalate_dispute(p_contract_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_k contracts;
begin
  select * into v_k from contracts where id = p_contract_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_uid not in (v_k.client_id, v_k.provider_id) then raise exception 'NOT_FOUND'; end if;
  if v_k.status <> 'disputed' or v_k.dispute_escalated_at is not null or v_k.dispute_response is null then
    raise exception 'INVALID_STATE';
  end if;
  perform _escalate_dispute(p_contract_id, case when v_uid = v_k.client_id then 'client' else 'provider' end);
end;
$$;

-- Istalgan tomon: kelishuv taklifi — ustaga p_provider_amount so'm (nizodagi summadan), qolgani mijozga qaytadi.
-- Yangi taklif oldingi javobsiz taklifni bekor qiladi.
create or replace function public.propose_settlement(p_contract_id uuid, p_provider_amount int, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_k contracts;
  v_amount int;
  v_title text;
  v_note text := btrim(coalesce(p_note, ''));
begin
  select * into v_k from contracts where id = p_contract_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_uid not in (v_k.client_id, v_k.provider_id) then raise exception 'NOT_FOUND'; end if;
  if v_k.status <> 'disputed' then raise exception 'INVALID_STATE'; end if;
  if char_length(v_note) > 500 then raise exception 'INVALID_INPUT'; end if;
  v_amount := _dispute_amount(p_contract_id);
  if p_provider_amount is null or p_provider_amount < 0 or p_provider_amount > v_amount then
    raise exception 'INVALID_AMOUNT';
  end if;

  update dispute_offers set status = 'cancelled', decided_at = now()
   where contract_id = p_contract_id and status = 'pending';

  -- Ikkinchi tomon foydasiga to'liq taklif tasdiq kutmaydi
  if (v_uid = v_k.provider_id and p_provider_amount = 0) or (v_uid = v_k.client_id and p_provider_amount = v_amount) then
    insert into dispute_offers (contract_id, proposed_by, provider_amount, note, status, decided_at)
    values (p_contract_id, v_uid, p_provider_amount, v_note, 'accepted', now());
    perform _resolve_dispute(p_contract_id, p_provider_amount, 'settled', v_note);
    return;
  end if;

  insert into dispute_offers (contract_id, proposed_by, provider_amount, note)
  values (p_contract_id, v_uid, p_provider_amount, v_note);
  select title into v_title from jobs where id = v_k.job_id;
  perform queue_notification(case when v_uid = v_k.client_id then v_k.provider_id else v_k.client_id end, format(
    E'\U0001F91D "%s": %s kelishuv taklif qildi — ustaga %s so''m, mijozga %s so''m qaytadi. Ko''rib chiqing.',
    v_title, case when v_uid = v_k.client_id then 'mijoz' else 'usta' end,
    _som(p_provider_amount), _som(v_amount - p_provider_amount)), '/contract/' || p_contract_id);
end;
$$;

-- Ikkinchi tomon kelishuvni qabul qiladi yoki rad etadi; taklif egasi faqat qaytarib oladi (p_accept = false)
create or replace function public.respond_settlement(p_offer_id uuid, p_accept boolean)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_o dispute_offers;
  v_k contracts;
  v_title text;
begin
  select * into v_o from dispute_offers where id = p_offer_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  select * into v_k from contracts where id = v_o.contract_id for update;
  if v_uid not in (v_k.client_id, v_k.provider_id) then raise exception 'NOT_FOUND'; end if;
  if v_o.status <> 'pending' or v_k.status <> 'disputed' then raise exception 'INVALID_STATE'; end if;

  if v_o.proposed_by = v_uid then
    if p_accept then raise exception 'NOT_ALLOWED'; end if;
    update dispute_offers set status = 'cancelled', decided_at = now() where id = p_offer_id;
    return;
  end if;

  if p_accept then
    update dispute_offers set status = 'accepted', decided_at = now() where id = p_offer_id;
    perform _resolve_dispute(v_k.id, v_o.provider_amount, 'settled', v_o.note);
  else
    update dispute_offers set status = 'declined', decided_at = now() where id = p_offer_id;
    select title into v_title from jobs where id = v_k.job_id;
    perform queue_notification(v_o.proposed_by, format(
      E'❌ "%s": kelishuv taklifingiz rad etildi. Boshqa summa taklif qiling yoki nizoni admin''ga yuboring.', v_title),
      '/contract/' || v_k.id);
  end if;
end;
$$;

-- Mijoz: nizoni qaytarib oladi — ish davom etadi. Topshirilgan ish yana "topshirilgan" holatga qaytadi
-- va mijozda yana 72 soat bo'ladi (bosqichlarda ham).
create or replace function public.withdraw_dispute(p_contract_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_k contracts;
  v_title text;
begin
  select * into v_k from contracts where id = p_contract_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_k.client_id <> v_uid then raise exception 'NOT_ALLOWED'; end if;
  if v_k.status <> 'disputed' then raise exception 'INVALID_STATE'; end if;

  update dispute_offers set status = 'cancelled', decided_at = now()
   where contract_id = p_contract_id and status = 'pending';
  update contracts
     set status = case when not staged and submitted_at is not null then 'submitted' else 'active' end,
         submitted_at = case when not staged and submitted_at is not null then now() else submitted_at end,
         dispute_escalated_at = null, dispute_escalated_by = null,
         mediation_amount = null, mediation_note = null, mediation_at = null, mediation_client_ok = null,
         mediation_provider_ok = null, arbitration_at = null
   where id = p_contract_id;
  update contract_stages set submitted_at = now() where contract_id = p_contract_id and status = 'submitted';

  select title into v_title from jobs where id = v_k.job_id;
  perform queue_notification(v_k.provider_id, format(
    E'↩️ "%s": mijoz nizoni yopdi — ish davom etadi.', v_title), '/contract/' || p_contract_id);
end;
$$;

-- Nizo 2-bosqichi (Upwork'dagi mediatsiya): admin murosa summasini taklif qiladi — ustaga p_provider_amount,
-- qolgani mijozga. Ikkala tomon 72 soat ichida javob beradi; javob bermagan — qabul qilgan hisoblanadi.
create or replace function public.admin_propose_mediation(p_contract_id uuid, p_provider_amount int, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_k contracts;
  v_amount int;
  v_title text;
  v_msg text;
begin
  perform require_admin();
  if char_length(btrim(coalesce(p_note, ''))) < 5 then raise exception 'REASON_REQUIRED'; end if;
  select * into v_k from contracts where id = p_contract_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_k.status <> 'disputed' or v_k.mediation_at is not null then raise exception 'INVALID_STATE'; end if;
  v_amount := _dispute_amount(p_contract_id);
  if p_provider_amount is null or p_provider_amount < 0 or p_provider_amount > v_amount then
    raise exception 'INVALID_AMOUNT';
  end if;

  update dispute_offers set status = 'cancelled', decided_at = now()
   where contract_id = p_contract_id and status = 'pending';
  update contracts
     set mediation_amount = p_provider_amount, mediation_note = left(btrim(p_note), 1000), mediation_at = now(),
         mediation_client_ok = null, mediation_provider_ok = null
   where id = p_contract_id;

  select title into v_title from jobs where id = v_k.job_id;
  v_msg := format(E'⚖️ "%s": admin murosa taklif qildi — ustaga %s so''m, mijozga %s so''m qaytadi. Izoh: %s. 72 soat ichida qabul qiling yoki rad eting (javob bermasangiz — qabul qilingan hisoblanadi). Kimdir rad etsa, admin yakuniy qaror chiqaradi.',
             v_title, _som(p_provider_amount), _som(v_amount - p_provider_amount), left(btrim(p_note), 300));
  perform queue_notification(v_k.client_id, v_msg, '/contract/' || p_contract_id);
  perform queue_notification(v_k.provider_id, v_msg, '/contract/' || p_contract_id);
end;
$$;

-- Mediatsiya taklifini ikkala tomon qabul qildi (yoki 72 soat jim turdi) — nizo shu summa bilan yopiladi
create or replace function public._accept_mediation(p_contract_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_k contracts;
begin
  select * into v_k from contracts where id = p_contract_id for update;
  if v_k.status <> 'disputed' or v_k.mediation_at is null or v_k.arbitration_at is not null then
    raise exception 'INVALID_STATE';
  end if;
  perform _resolve_dispute(p_contract_id, v_k.mediation_amount, 'settled', v_k.mediation_note);
end;
$$;

-- Tomon mediatsiya taklifiga javob beradi. Rad etsa — arbitraj: admin yakuniy qaror chiqaradi.
create or replace function public.respond_mediation(p_contract_id uuid, p_accept boolean)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_k contracts;
  v_title text;
  v_other uuid;
begin
  if p_accept is null then raise exception 'INVALID_INPUT'; end if;
  select * into v_k from contracts where id = p_contract_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_uid not in (v_k.client_id, v_k.provider_id) then raise exception 'NOT_FOUND'; end if;
  if v_k.status <> 'disputed' or v_k.mediation_at is null or v_k.arbitration_at is not null then
    raise exception 'INVALID_STATE';
  end if;
  if (v_uid = v_k.client_id and v_k.mediation_client_ok is not null)
     or (v_uid = v_k.provider_id and v_k.mediation_provider_ok is not null) then
    raise exception 'INVALID_STATE';
  end if;

  update contracts
     set mediation_client_ok = case when v_uid = client_id then p_accept else mediation_client_ok end,
         mediation_provider_ok = case when v_uid = provider_id then p_accept else mediation_provider_ok end,
         arbitration_at = case when not p_accept then now() end
   where id = p_contract_id
  returning * into v_k;

  if v_k.mediation_client_ok and v_k.mediation_provider_ok then
    perform _accept_mediation(p_contract_id);
    return;
  end if;
  if not p_accept then
    select title into v_title from jobs where id = v_k.job_id;
    v_other := case when v_uid = v_k.client_id then v_k.provider_id else v_k.client_id end;
    perform queue_notification(v_other, format(
      E'⚖️ "%s": %s admin murosa taklifini rad etdi — endi admin yakuniy qaror chiqaradi.', v_title,
      case when v_uid = v_k.client_id then 'mijoz' else 'usta' end), '/contract/' || p_contract_id);
    perform _notify_admins(format(E'⚖️ "%s": murosa rad etildi — yakuniy qaroringizni kutmoqda.', v_title), '/admin/disputes');
  end if;
end;
$$;

-- Nizo 3-bosqichi (arbitraj): mediatsiya rad etilgach admin yakuniy qaror chiqaradi — ustaga p_provider_amount
-- (0..nizodagi summa), qolgani mijozga. Sabab majburiy: ikkala tomon ko'radi.
create or replace function public.admin_decide_dispute(p_contract_id uuid, p_provider_amount int, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_k contracts;
  v_amount int;
begin
  perform require_admin();
  if char_length(btrim(coalesce(p_note, ''))) < 5 then raise exception 'REASON_REQUIRED'; end if;
  select * into v_k from contracts where id = p_contract_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_k.status <> 'disputed' then raise exception 'INVALID_STATE'; end if;
  if v_k.arbitration_at is null then raise exception 'MEDIATION_REQUIRED'; end if;
  v_amount := _dispute_amount(p_contract_id);
  if p_provider_amount is null or p_provider_amount < 0 or p_provider_amount > v_amount then
    raise exception 'INVALID_AMOUNT';
  end if;
  perform _resolve_dispute(p_contract_id, p_provider_amount,
    case when p_provider_amount = v_amount then 'provider' when p_provider_amount = 0 then 'client' else 'split' end,
    p_note);
end;
$$;

revoke execute on function public._dispute_amount(uuid), public._dispute_photos(uuid), public._som(int),
  public._notify_admins(text, text), public._resolve_dispute(uuid, int, text, text),
  public._escalate_dispute(uuid, text), public.request_revision(uuid, text, uuid), public.respond_dispute(uuid, text),
  public.escalate_dispute(uuid), public.propose_settlement(uuid, int, text), public.respond_settlement(uuid, boolean),
  public.withdraw_dispute(uuid), public.admin_decide_dispute(uuid, int, text),
  public.admin_propose_mediation(uuid, int, text), public._accept_mediation(uuid), public.respond_mediation(uuid, boolean)
from public, anon, authenticated;

grant execute on function public.request_revision(uuid, text, uuid), public.respond_dispute(uuid, text),
  public.escalate_dispute(uuid), public.propose_settlement(uuid, int, text), public.respond_settlement(uuid, boolean),
  public.withdraw_dispute(uuid), public.admin_decide_dispute(uuid, int, text),
  public.admin_propose_mediation(uuid, int, text), public.respond_mediation(uuid, boolean)
to authenticated;


-- ===== usta statistikasi (Upwork'dagi My Stats) =====
-- Daromad — qabul qilingan ishlar (bosqichli shartnomada — qabul qilingan bosqichlar); nizo qisman hal
-- qilingan bo'lsa ustaga tekkan qismi. Pul Ustame orqali yoki naqd to'langanidan qat'i nazar hisoblanadi.
-- Oylar Toshkent vaqti bo'yicha, oxirgi 6 oy. Yutish foizi = yollangan / javob olgan takliflar
-- (kutilayotgan va qaytarib olinganlar hisobga kirmaydi), kamida 3 ta bo'lsa ko'rsatiladi.
create or replace function public.get_my_provider_stats()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_month timestamptz := date_trunc('month', now() at time zone 'Asia/Tashkent') at time zone 'Asia/Tashkent';
begin
  if not exists (select 1 from provider_profiles where user_id = v_uid) then raise exception 'NOT_FOUND'; end if;
  return (
    with earn as (
      select coalesce(k.payout_amount, k.price)::bigint as amount, k.completed_at as at, j.category
        from contracts k join jobs j on j.id = k.job_id
       where k.provider_id = v_uid and not k.staged and k.status = 'completed'
      union all
      select coalesce(st.payout_amount, st.amount)::bigint, st.approved_at, j.category
        from contract_stages st
        join contracts k on k.id = st.contract_id
        join jobs j on j.id = k.job_id
       where k.provider_id = v_uid and k.staged and st.status = 'approved'
    ),
    pr as (
      select status, created_at from proposals where provider_id = v_uid
    ),
    pc as (
      select count(*) filter (where status = 'accepted')                         as won,
             count(*) filter (where status in ('accepted', 'declined', 'closed')) as decided
        from pr
    ),
    -- Oylar Toshkent vaqtida hisoblanadi (UTC'da qo'shilsa oy chegaralari siljiydi)
    months as (
      select to_char(gs, 'YYYY-MM') as label,
             gs at time zone 'Asia/Tashkent' as m,
             (gs + interval '1 month') at time zone 'Asia/Tashkent' as m_end
        from generate_series(date_trunc('month', now() at time zone 'Asia/Tashkent') - interval '5 months',
                             date_trunc('month', now() at time zone 'Asia/Tashkent'), interval '1 month') gs
    )
    select jsonb_build_object(
      'earned_total', coalesce((select sum(amount) from earn), 0),
      'earned_month', coalesce((select sum(amount) from earn where at >= v_month), 0),
      -- Ish davom etayotgan shartnomalar (bosqichlida — hali qabul qilinmagan bosqichlar)
      'in_progress',  coalesce((select sum(k.price) from contracts k
                                 where k.provider_id = v_uid and not k.staged
                                   and k.status in ('active', 'submitted', 'disputed')), 0)
                    + coalesce((select sum(st.amount) from contract_stages st join contracts k on k.id = st.contract_id
                                 where k.provider_id = v_uid and k.staged
                                   and k.status in ('active', 'submitted', 'disputed') and st.status <> 'approved'), 0),
      'jobs_active',  (select count(*) from contracts
                        where provider_id = v_uid and status in ('active', 'submitted', 'disputed')),
      'proposals_sent',    (select count(*) from pr),
      'proposals_30d',     (select count(*) from pr where created_at > now() - interval '30 days'),
      'proposals_pending', (select count(*) from pr where status = 'submitted'),
      'proposals_won',     (select won from pc),
      'win_rate',          (select case when decided >= 3 then round(100.0 * won / decided) end from pc),
      'months', (select jsonb_agg(jsonb_build_object(
                   'month',  mm.label,
                   'earned', coalesce((select sum(e.amount) from earn e where e.at >= mm.m and e.at < mm.m_end), 0),
                   'jobs',   (select count(*) from contracts k
                               where k.provider_id = v_uid and k.status = 'completed'
                                 and k.completed_at >= mm.m and k.completed_at < mm.m_end)
                 ) order by mm.m) from months mm),
      'top_categories', coalesce((select jsonb_agg(jsonb_build_object('category', c.category, 'earned', c.s, 'jobs', c.n)
                                                   order by c.s desc)
                                   from (select category, sum(amount) as s, count(*) as n
                                           from earn group by category order by 2 desc limit 3) c), '[]'::jsonb),
      'stats', provider_stats(v_uid)
    )
  );
end;
$$;

revoke execute on function public.get_my_provider_stats() from public, anon, authenticated;
grant execute on function public.get_my_provider_stats() to authenticated;


-- ===== SMS hujumidan himoya =====
-- send-code har so'rovda 24 soatlik kod sonini sanaydi (internal/api/sms_guard.go) — vaqt bo'yicha indeks
create index if not exists otp_codes_created_idx on public.otp_codes (created_at);


-- ===== mijoz shartnomani bekor qilishi, kafolat davri, admin amallari jurnali =====

-- Mijoz: ish boshlanmagan faol shartnomani bekor qiladi. Usta yo'lga chiqqan yoki yetib kelgan bo'lsa —
-- "kech bekor qilish" (mijoz statistikasida ko'rinadi, chaqiruv haqini usta bilan kelishish tavsiya etiladi).
-- Ish boshlangan yoki bosqich topshirilgan bo'lsa — faqat nizo orqali. E'lon qayta ochiladi: mijoz boshqa
-- ustani tanlaydi yoki e'lonni yopadi.
create or replace function public.client_cancel_contract(p_contract_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_k contracts;
  v_late boolean;
  v_fee int;
  v_title text;
begin
  if char_length(btrim(coalesce(p_reason, ''))) < 5 then raise exception 'REASON_REQUIRED'; end if;
  select * into v_k from contracts where id = p_contract_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_k.client_id <> v_uid then raise exception 'NOT_ALLOWED'; end if;
  if v_k.status <> 'active' or v_k.started_at is not null
     or exists (select 1 from contract_stages where contract_id = v_k.id and status <> 'pending') then
    raise exception 'INVALID_STATE';
  end if;
  v_late := v_k.on_the_way_at is not null or v_k.arrived_at is not null;
  -- Pul kafolatda bo'lsa chaqiruv haqi ustaga o'tadi, qolgani mijozga qaytadi (bosqichsiz shartnomada)
  v_fee := case when v_late and v_k.payment_status = 'held' and not v_k.staged
                then least(_callout_fee(), coalesce(v_k.payment_held_amount, v_k.price)) end;

  update contracts
     set status = 'cancelled', cancelled_at = now(), cancelled_by = 'client',
         cancel_reason = left(btrim(p_reason), 1000), late_cancel = v_late, payout_amount = v_fee
   where id = p_contract_id;
  update price_changes set status = 'cancelled', decided_at = now()
   where contract_id = p_contract_id and status = 'pending';
  update proposals set status = 'submitted', updated_at = now() where job_id = v_k.job_id and status = 'closed';
  update jobs set status = 'open' where id = v_k.job_id;

  select title into v_title from jobs where id = v_k.job_id;
  perform queue_notification(v_k.provider_id, format(
    case when v_fee is not null
      then E'⚠️ Mijoz "%s" shartnomasini siz yo''lga chiqqaningizdan keyin bekor qildi. Sabab: %s. Kafolatdagi puldan chaqiruv haqi — %s so''m sizga o''tkaziladi.'
    when v_late
      then E'⚠️ Mijoz "%s" shartnomasini siz yo''lga chiqqaningizdan keyin bekor qildi. Sabab: %s. Chaqiruv haqini mijoz bilan kelishing.'
      else E'⚠️ Mijoz "%s" shartnomasini bekor qildi. Sabab: %s' end,
    v_title, left(btrim(p_reason), 300), _som(coalesce(v_fee, 0))), '/contract/' || p_contract_id);
  if v_k.payment_status = 'held' then
    perform _notify_admins(format(E'\U0001F4B8 "%s": mijoz shartnomani bekor qildi — kafolatdagi pulni %s.', v_title,
      case when v_fee is not null
        then format(E'taqsimlang: ustaga %s so''m chaqiruv haqi, qolgani mijozga', _som(v_fee))
        else 'mijozga qaytaring' end), '/admin/payments');
  end if;
end;
$$;

-- Kafolat murojaatini yopish: p_ok — hal bo'ldi, p_auto — muddat o'tgani uchun (davriy ish)
create or replace function public._close_warranty(p_claim_id uuid, p_ok boolean, p_auto boolean)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_w warranty_claims;
  v_k contracts;
  v_title text;
  v_link text;
  v_n int;
begin
  update warranty_claims set status = case when p_ok then 'resolved' else 'unresolved' end, closed_at = now()
   where id = p_claim_id and status in ('open', 'fixed')
  returning * into v_w;
  if not found then raise exception 'INVALID_STATE'; end if;
  select * into v_k from contracts where id = v_w.contract_id;
  select title into v_title from jobs where id = v_k.job_id;
  v_link := '/contract/' || v_k.id;
  if p_ok then
    perform queue_notification(v_k.provider_id, format(
      E'✅ "%s": kafolat murojaati hal bo''ldi.', v_title), v_link);
  else
    perform queue_notification(v_k.provider_id, format(
      E'⚠️ "%s": kafolat murojaati hal bo''lmadi%s — bu statistikangizda ko''rinadi.', v_title,
      case when p_auto then ' (3 kun ichida tuzatilmadi)' else '' end), v_link);
    perform queue_notification(v_k.client_id, format(
      E'⚠️ "%s": kafolat murojaati hal bo''lmadi deb belgilandi. Admin ko''rib chiqadi.', v_title), v_link);
    select count(*) into v_n from warranty_claims w join contracts k on k.id = w.contract_id
     where k.provider_id = v_k.provider_id and w.status = 'unresolved';
    perform _notify_admins(format(E'\U0001F6E0 "%s": kafolat murojaati hal bo''lmadi (ustada jami %s ta)%s', v_title, v_n,
      case when v_n >= 3 then E' — 3 tadan oshdi: ustani tekshiring, kerak bo''lsa bloklang.' else ' — ustani ko''rib chiqing.' end),
      v_link);
  end if;
end;
$$;

-- Mijoz: yakunlangan ish bo'yicha kafolat murojaati (30 kun ichida, bitta ochiq, jami 3 tagacha)
create or replace function public.open_warranty_claim(p_contract_id uuid, p_reason text)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_k contracts;
  v_id uuid;
  v_title text;
begin
  if char_length(btrim(coalesce(p_reason, ''))) < 5 then raise exception 'REASON_REQUIRED'; end if;
  select * into v_k from contracts where id = p_contract_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_k.client_id <> v_uid then raise exception 'NOT_ALLOWED'; end if;
  if v_k.status <> 'completed' then raise exception 'INVALID_STATE'; end if;
  if v_k.completed_at < now() - interval '30 days' then raise exception 'WARRANTY_EXPIRED'; end if;
  if exists (select 1 from warranty_claims where contract_id = p_contract_id and status in ('open', 'fixed')) then
    raise exception 'INVALID_STATE';
  end if;
  if (select count(*) from warranty_claims where contract_id = p_contract_id) >= 3 then
    raise exception 'WARRANTY_LIMIT';
  end if;

  insert into warranty_claims (contract_id, reason) values (p_contract_id, left(btrim(p_reason), 1000))
  returning id into v_id;
  select title into v_title from jobs where id = v_k.job_id;
  perform queue_notification(v_k.provider_id, format(
    E'\U0001F6E0 "%s": mijoz kafolat bo''yicha murojaat qildi: %s. 3 kun ichida bog''lanib, bepul tuzating va ilovada "Tuzatdim"ni bosing.',
    v_title, left(btrim(p_reason), 300)), '/contract/' || p_contract_id);
  return v_id;
end;
$$;

-- Usta: nuqsonni tuzatdim (izoh bilan)
create or replace function public.mark_warranty_fixed(p_claim_id uuid, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_w warranty_claims;
  v_k contracts;
  v_title text;
begin
  if char_length(coalesce(p_note, '')) > 1000 then raise exception 'INVALID_INPUT'; end if;
  select * into v_w from warranty_claims where id = p_claim_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  select * into v_k from contracts where id = v_w.contract_id;
  if v_k.provider_id <> v_uid then raise exception 'NOT_ALLOWED'; end if;
  if v_w.status <> 'open' then raise exception 'INVALID_STATE'; end if;
  update warranty_claims set status = 'fixed', fixed_at = now(), provider_note = nullif(btrim(coalesce(p_note, '')), '')
   where id = p_claim_id;
  select title into v_title from jobs where id = v_k.job_id;
  perform queue_notification(v_k.client_id, format(
    E'\U0001F6E0 "%s": usta nuqsonni tuzatganini aytdi. Tekshirib, natijani belgilang — 7 kunda javob bo''lmasa hal bo''lgan hisoblanadi.',
    v_title), '/contract/' || v_k.id);
end;
$$;

-- Mijoz: natija — hal bo'ldi (istalgan paytda) yoki hal bo'lmadi (usta "tuzatdim" degandan keyin)
create or replace function public.confirm_warranty(p_claim_id uuid, p_resolved boolean)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_w warranty_claims;
begin
  select * into v_w from warranty_claims where id = p_claim_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if (select client_id from contracts where id = v_w.contract_id) <> v_uid then raise exception 'NOT_ALLOWED'; end if;
  if v_w.status not in ('open', 'fixed') or (not p_resolved and v_w.status <> 'fixed') then
    raise exception 'INVALID_STATE';
  end if;
  perform _close_warranty(p_claim_id, p_resolved, false);
end;
$$;

-- Admin amallari jurnali: kim, qachon, qaysi amal va qanday qiymatlar bilan. Server (internal/api/rpc.go)
-- har bir o'zgartiruvchi admin_* chaqiruvini shu tranzaksiyaning o'zida yozadi — amal bajarilmasa yozuv ham yo'q.
create table if not exists public.admin_actions (
  id         bigserial primary key,
  admin_id   uuid references public.users (id) on delete set null,
  action     text not null,
  args       jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists admin_actions_created_idx on public.admin_actions (created_at desc);

alter table public.admin_actions enable row level security;

create or replace function public.admin_get_actions()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform require_admin();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', a.id, 'action', a.action, 'args', a.args, 'created_at', a.created_at,
      'admin', jsonb_build_object('id', p.id, 'full_name', p.full_name),
      -- Qaysi e'lon / foydalanuvchi haqida — o'qish oson bo'lsin
      'job_title', (select j.title from jobs j where j.id = coalesce(
          safe_uuid(a.args->>'p_job_id'),
          (select k.job_id from contracts k where k.id = safe_uuid(a.args->>'p_contract_id')),
          (select k.job_id from contract_stages st join contracts k on k.id = st.contract_id
            where st.id = safe_uuid(a.args->>'p_stage_id')))),
      'user_name', (select u.full_name from profiles u where u.id = safe_uuid(a.args->>'p_user_id')),
      'team_name', (select t.name from teams t where t.id = safe_uuid(a.args->>'p_team_id'))
    ) order by a.created_at desc)
    from (select * from admin_actions order by created_at desc limit 300) a
    left join profiles p on p.id = a.admin_id
  ), '[]'::jsonb);
end;
$$;

revoke execute on function public.client_cancel_contract(uuid, text), public._close_warranty(uuid, boolean, boolean),
  public.open_warranty_claim(uuid, text), public.mark_warranty_fixed(uuid, text), public.confirm_warranty(uuid, boolean),
  public.admin_get_actions()
from public, anon, authenticated;

grant execute on function public.client_cancel_contract(uuid, text), public.open_warranty_claim(uuid, text),
  public.mark_warranty_fixed(uuid, text), public.confirm_warranty(uuid, boolean), public.admin_get_actions()
to authenticated;


-- ===== oylik obuna (komissiya o'rniga) =====
-- Ustame mijozdan ham, ustadan ham komissiya olmaydi. Ustalar oylik obuna to'laydi:
--   * bepul davr (free_until gacha) — hamma narsa hamma uchun cheklovsiz;
--   * keyin obunasiz usta oyiga free_proposals ta taklif yuboradi (Toshkent vaqti bo'yicha kalendar oy),
--     obunasi bor usta — cheklovsiz.
-- To'lov hozircha qo'lda: usta pul o'tkazadi, admin admin_extend_subscription bilan muddatni uzaytiradi.
create table if not exists public.subscription_settings (
  id             int primary key default 1 check (id = 1),
  -- Ilovaning birinchi 3 oyi to'liq bepul
  free_until     timestamptz not null,
  free_proposals int not null check (free_proposals >= 0),
  price          int not null check (price > 0)
);

insert into public.subscription_settings (id, free_until, free_proposals, price)
values (1, '2027-01-22 00:00:00+05', 5, 79000)
on conflict (id) do nothing;

alter table public.subscription_settings enable row level security;

create table if not exists public.provider_subscriptions (
  user_id    uuid primary key references public.users (id) on delete cascade,
  paid_until timestamptz not null,
  updated_at timestamptz not null default now()
);

alter table public.provider_subscriptions enable row level security;

-- Har bir uzaytirish (kim, kimga, necha oy, qancha) — hisob-kitob uchun
create table if not exists public.subscription_payments (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.users (id) on delete cascade,
  admin_id   uuid references public.users (id) on delete set null,
  months     int not null check (months between 1 and 12),
  amount     int not null check (amount >= 0),
  paid_until timestamptz not null,
  created_at timestamptz not null default now()
);

create index if not exists subscription_payments_user_idx on public.subscription_payments (user_id, created_at desc);

alter table public.subscription_payments enable row level security;

-- Shu kalendar oyda (Toshkent vaqti) yuborilgan takliflar soni
create or replace function public._proposals_this_month(p_user_id uuid)
returns int language sql stable security definer set search_path = public as $$
  select count(*)::int from proposals
   where provider_id = p_user_id
     and created_at >= date_trunc('month', now() at time zone 'Asia/Tashkent') at time zone 'Asia/Tashkent'
$$;

create or replace function public._subscription_json(p_user_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_set subscription_settings;
  v_paid timestamptz;
  v_used int := _proposals_this_month(p_user_id);
begin
  select * into v_set from subscription_settings where id = 1;
  select paid_until into v_paid from provider_subscriptions where user_id = p_user_id;
  return jsonb_build_object(
    'free_until',     v_set.free_until,
    'free_period',    now() < v_set.free_until,
    'paid_until',     v_paid,
    'active',         now() < v_set.free_until or coalesce(v_paid > now(), false),
    'price',          v_set.price,
    'free_proposals', v_set.free_proposals,
    'used',           v_used
  );
end;
$$;

-- submit_proposal chaqiradi: obuna yoki bepul davr bo'lmasa, oylik bepul limit tugaganda SUBSCRIPTION_REQUIRED
create or replace function public._check_proposal_quota(p_user_id uuid)
returns void language plpgsql stable security definer set search_path = public as $$
declare v_set subscription_settings;
begin
  select * into v_set from subscription_settings where id = 1;
  if now() < v_set.free_until then return; end if;
  if exists (select 1 from provider_subscriptions where user_id = p_user_id and paid_until > now()) then return; end if;
  if _proposals_this_month(p_user_id) >= v_set.free_proposals then raise exception 'SUBSCRIPTION_REQUIRED'; end if;
end;
$$;

create or replace function public.get_my_subscription()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := require_uid();
begin
  return _subscription_json(v_uid);
end;
$$;

-- Admin: usta to'lov qilgach obunani uzaytiradi. Muddat qolgan obuna yoki bepul davr oxiridan boshlab
-- qo'shiladi — bepul davrda to'lagan usta oylarini yo'qotmaydi.
create or replace function public.admin_extend_subscription(p_user_id uuid, p_months int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_admin uuid := require_admin();
  v_set subscription_settings;
  v_until timestamptz;
begin
  if p_months is null or p_months not between 1 and 12 then raise exception 'INVALID_INPUT'; end if;
  if not exists (select 1 from provider_profiles where user_id = p_user_id) then raise exception 'NOT_FOUND'; end if;
  select * into v_set from subscription_settings where id = 1;
  select greatest(now(), v_set.free_until, (select paid_until from provider_subscriptions where user_id = p_user_id))
         + make_interval(months => p_months)
    into v_until;
  insert into provider_subscriptions (user_id, paid_until) values (p_user_id, v_until)
  on conflict (user_id) do update set paid_until = excluded.paid_until, updated_at = now();
  insert into subscription_payments (user_id, admin_id, months, amount, paid_until)
  values (p_user_id, v_admin, p_months, v_set.price * p_months, v_until);
  perform queue_notification(p_user_id, format(
    E'✅ Obunangiz %s gacha faollashtirildi — takliflar cheklovsiz.',
    to_char(v_until at time zone 'Asia/Tashkent', 'DD.MM.YYYY')), '/subscription');
  return _subscription_json(p_user_id);
end;
$$;

revoke execute on function public._proposals_this_month(uuid), public._subscription_json(uuid),
  public._check_proposal_quota(uuid), public.get_my_subscription(), public.admin_extend_subscription(uuid, int)
from public, anon, authenticated;

grant execute on function public.get_my_subscription(), public.admin_extend_subscription(uuid, int) to authenticated;


-- ===== xabarlar ro'yxati (Upwork'dagi Messages) =====
-- Foydalanuvchining barcha yozishmalari bitta so'rovda: shartnoma chatlari va kutilayotgan takliflar bo'yicha
-- (yollashdan oldingi) chatlar — qarshi tomon, bog'liq e'lon, oxirgi xabar va o'qilmaganlar soni.
-- Shartnoma chati taklif paytidagi xabarlarni ham o'z ichiga oladi (get_messages bilan bir xil).
create or replace function public.get_my_conversations(p_role text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := require_uid();
begin
  if p_role not in ('client', 'provider') then raise exception 'INVALID_INPUT'; end if;
  return coalesce((
    select jsonb_agg(c.item order by c.sort_at desc)
    from (
      -- Shartnomalar
      select coalesce(lm.created_at, k.created_at) as sort_at,
        jsonb_build_object(
          'kind', 'contract', 'id', k.id, 'created_at', k.created_at,
          'counterpart', jsonb_build_object('id', o.id, 'full_name', o.full_name, 'avatar_updated_at', o.avatar_updated_at),
          'job_id', j.id, 'job_title', j.title, 'contract_status', k.status,
          'last_message', case when lm.id is not null
            then jsonb_build_object('text', lm.text, 'created_at', lm.created_at, 'mine', lm.sender_id = v_uid) end,
          'unread', (select count(*) from messages m
                      where (m.contract_id = k.id or (k.proposal_id is not null and m.proposal_id = k.proposal_id))
                        and m.sender_id <> v_uid and m.read_at is null)
        ) as item
      from contracts k
      join jobs j on j.id = k.job_id
      join profiles o on o.id = case when p_role = 'client' then k.provider_id else k.client_id end
      left join lateral (
        select m.id, m.text, m.created_at, m.sender_id from messages m
         where m.contract_id = k.id or (k.proposal_id is not null and m.proposal_id = k.proposal_id)
         order by m.created_at desc limit 1
      ) lm on true
      where (p_role = 'client' and k.client_id = v_uid) or (p_role = 'provider' and k.provider_id = v_uid)

      union all

      -- Kutilayotgan takliflar (qabul qilingani shartnoma chatida davom etadi)
      select coalesce(lm.created_at, p.created_at),
        jsonb_build_object(
          'kind', 'proposal', 'id', p.id, 'created_at', p.created_at,
          'counterpart', jsonb_build_object('id', o.id, 'full_name', o.full_name, 'avatar_updated_at', o.avatar_updated_at),
          'job_id', j.id, 'job_title', j.title, 'contract_status', null,
          'last_message', case when lm.id is not null
            then jsonb_build_object('text', lm.text, 'created_at', lm.created_at, 'mine', lm.sender_id = v_uid) end,
          'unread', (select count(*) from messages m
                      where m.proposal_id = p.id and m.sender_id <> v_uid and m.read_at is null)
        )
      from proposals p
      join jobs j on j.id = p.job_id
      join profiles o on o.id = case when p_role = 'client' then p.provider_id else j.client_id end
      left join lateral (
        select m.id, m.text, m.created_at, m.sender_id from messages m
         where m.proposal_id = p.id order by m.created_at desc limit 1
      ) lm on true
      where p.status = 'submitted'
        and ((p_role = 'client' and j.client_id = v_uid) or (p_role = 'provider' and p.provider_id = v_uid))
    ) c
  ), '[]'::jsonb);
end;
$$;

revoke execute on function public.get_my_conversations(text) from public, anon, authenticated;
grant execute on function public.get_my_conversations(text) to authenticated;


-- ===== mijoz tomoni: buyurtma tafsilotlari, holati, murojaatlar =====
-- Buyurtmaning qo'shimcha maydonlari (3 bosqichli e'lon formasi). post_job o'zgarmaydi — eski ilova ham ishlaydi;
-- yangi ilova post_job dan keyin set_job_details ni chaqiradi.
create table if not exists public.job_details (
  job_id       uuid primary key references public.jobs (id) on delete cascade,
  skills       text check (char_length(skills) <= 300),        -- kerakli tajriba va malaka
  requirements text check (char_length(requirements) <= 1000), -- qo'shimcha talablar
  budget_type  text check (budget_type in ('fixed', 'range', 'negotiable')),
  budget_max   int check (budget_max between 10000 and 100000000),
  start_date   date,
  duration     text check (char_length(duration) <= 100),      -- taxminiy davomiylik ("2 kun")
  deadline     date,                                             -- topshirish sanasi
  materials    text check (materials in ('client', 'provider', 'agreed')),
  conditions   text check (char_length(conditions) <= 1000),   -- ishni bajarish shartlari
  notes        text check (char_length(notes) <= 1000),        -- mijozning qo'shimcha izohi
  updated_at   timestamptz not null default now()
);

alter table public.job_details enable row level security;

create or replace function public._job_details_json(p_job_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select to_jsonb(d) - 'job_id' from job_details d where d.job_id = p_job_id;
$$;

-- Bo'sh matn — null; uzunlik cheklovi oshsa INVALID_INPUT
create or replace function public._opt_text(p jsonb, p_key text, p_max int)
returns text language plpgsql immutable as $$
declare v text := nullif(btrim(coalesce(p ->> p_key, '')), '');
begin
  if v is not null and char_length(v) > p_max then raise exception 'INVALID_INPUT'; end if;
  return v;
end;
$$;

create or replace function public._opt_date(p jsonb, p_key text)
returns date language plpgsql immutable as $$
begin
  return nullif(p ->> p_key, '')::date;
exception when others then
  raise exception 'INVALID_DATE';
end;
$$;

-- Buyurtma tafsilotlari: faqat e'lon egasi, e'lon ochiq bo'lganda. Narx oralig'i: jobs.budget — pastki chegara.
create or replace function public.set_job_details(p_job_id uuid, p_details jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_job jobs;
  v_type text := nullif(p_details ->> 'budget_type', '');
  v_max int;
  v_start date := _opt_date(p_details, 'start_date');
  v_deadline date := _opt_date(p_details, 'deadline');
  v_materials text := nullif(p_details ->> 'materials', '');
begin
  begin
    v_max := nullif(p_details ->> 'budget_max', '')::int;
  exception when others then
    raise exception 'INVALID_PRICE';
  end;
  select * into v_job from jobs where id = p_job_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_job.client_id <> v_uid then raise exception 'NOT_ALLOWED'; end if;
  if v_job.status <> 'open' then raise exception 'JOB_NOT_OPEN'; end if;
  if v_type is not null and v_type not in ('fixed', 'range', 'negotiable') then raise exception 'INVALID_INPUT'; end if;
  if v_type = 'range' and (v_max is null or v_job.budget is null or v_max < v_job.budget) then raise exception 'INVALID_PRICE'; end if;
  if v_max is not null and v_max not between 10000 and 100000000 then raise exception 'INVALID_PRICE'; end if;
  if v_start is not null and v_deadline is not null and v_deadline < v_start then raise exception 'INVALID_DATE'; end if;
  if v_materials is not null and v_materials not in ('client', 'provider', 'agreed') then raise exception 'INVALID_INPUT'; end if;
  if _has_contact(concat_ws(' ', p_details ->> 'skills', p_details ->> 'requirements', p_details ->> 'conditions',
                            p_details ->> 'notes')) then
    raise exception 'CONTACT_NOT_ALLOWED';
  end if;

  insert into job_details (job_id, skills, requirements, budget_type, budget_max, start_date, duration, deadline,
                           materials, conditions, notes, updated_at)
  values (p_job_id, _opt_text(p_details, 'skills', 300), _opt_text(p_details, 'requirements', 1000), v_type,
          case when v_type = 'range' then v_max end, v_start, _opt_text(p_details, 'duration', 100), v_deadline,
          v_materials, _opt_text(p_details, 'conditions', 1000), _opt_text(p_details, 'notes', 1000), now())
  on conflict (job_id) do update set
    skills = excluded.skills, requirements = excluded.requirements, budget_type = excluded.budget_type,
    budget_max = excluded.budget_max, start_date = excluded.start_date, duration = excluded.duration,
    deadline = excluded.deadline, materials = excluded.materials, conditions = excluded.conditions,
    notes = excluded.notes, updated_at = now();
end;
$$;

-- E'lonni tahrirlash: faqat egasi, e'lon ochiq (usta hali tanlanmagan) bo'lsa; post_job bilan bir xil tekshiruvlar
create or replace function public.update_job(
  p_job_id uuid, p_category text, p_district text, p_title text, p_description text,
  p_address text, p_budget int, p_urgency text
)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_job jobs;
begin
  select * into v_job from jobs where id = p_job_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_job.client_id <> v_uid then raise exception 'NOT_ALLOWED'; end if;
  if v_job.status <> 'open' then raise exception 'JOB_NOT_OPEN'; end if;
  if coalesce(btrim(p_category), '') = '' or coalesce(btrim(p_district), '') = '' then raise exception 'INVALID_INPUT'; end if;
  if char_length(btrim(coalesce(p_title, ''))) not between 5 and 80 then raise exception 'INVALID_TITLE'; end if;
  if char_length(btrim(coalesce(p_description, ''))) not between 10 and 2000 then raise exception 'INVALID_DESCRIPTION'; end if;
  if char_length(btrim(coalesce(p_address, ''))) not between 5 and 300 then raise exception 'INVALID_ADDRESS'; end if;
  if p_budget is not null and p_budget not between 10000 and 100000000 then raise exception 'INVALID_PRICE'; end if;
  if coalesce(p_urgency, 'flexible') not in ('urgent', 'today', 'this_week', 'flexible') then raise exception 'INVALID_INPUT'; end if;
  if _has_contact(p_title) or _has_contact(p_description) then raise exception 'CONTACT_NOT_ALLOWED'; end if;

  update jobs set category = btrim(p_category), district = btrim(p_district), title = btrim(p_title),
                  description = btrim(p_description), budget = p_budget, urgency = coalesce(p_urgency, 'flexible')
   where id = p_job_id;
  insert into job_addresses (job_id, address) values (p_job_id, btrim(p_address))
  on conflict (job_id) do update set address = excluded.address;
end;
$$;

-- Buyurtmaning ko'rinadigan holati (mavjud e'lon va shartnoma ma'lumotlaridan hisoblanadi, alohida saqlanmaydi):
--   new · awaiting_proposals · provider_selected · awaiting_start · in_progress · awaiting_completion ·
--   completed · cancelled · disputed
create or replace function public._order_status(p_job_id uuid)
returns text language sql stable security definer set search_path = public as $$
  select case
    when k.status = 'disputed' then 'disputed'
    when k.status = 'completed' or j.status = 'completed' then 'completed'
    when j.status = 'cancelled' then 'cancelled'
    when k.status = 'submitted' then 'awaiting_completion'
    when k.status = 'active' and k.started_at is not null then 'in_progress'
    when k.status = 'active' and (k.on_the_way_at is not null or k.arrived_at is not null) then 'awaiting_start'
    when k.status = 'active' then 'provider_selected'
    when j.created_at > now() - interval '24 hours'
         and not exists (select 1 from proposals p where p.job_id = j.id and p.status = 'submitted') then 'new'
    else 'awaiting_proposals'
  end
  from jobs j
  left join lateral (
    select * from contracts c where c.job_id = j.id and c.status <> 'cancelled' order by c.created_at desc limit 1
  ) k on true
  where j.id = p_job_id;
$$;

-- Murojaat: ustaning ish boshlash imkoniyati va taxminiy davomiylik; mijoz ko'rib chiqqan vaqt
alter table public.proposals add column if not exists available_from date;
alter table public.proposals add column if not exists duration text check (char_length(duration) <= 100);
alter table public.proposals add column if not exists client_viewed_at timestamptz;

create or replace function public.set_proposal_terms(p_proposal_id uuid, p_available_from date, p_duration text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_p proposals;
  v_duration text := nullif(btrim(coalesce(p_duration, '')), '');
begin
  select * into v_p from proposals where id = p_proposal_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_p.provider_id <> v_uid then raise exception 'NOT_ALLOWED'; end if;
  if v_p.status <> 'submitted' then raise exception 'INVALID_STATE'; end if;
  if char_length(coalesce(v_duration, '')) > 100 then raise exception 'INVALID_INPUT'; end if;
  if _has_contact(v_duration) then raise exception 'CONTACT_NOT_ALLOWED'; end if;
  update proposals set available_from = p_available_from, duration = v_duration, updated_at = now()
   where id = p_proposal_id;
end;
$$;

-- Mijoz murojaatni ochib ko'rdi ("Yangi" -> "Ko'rib chiqilgan")
create or replace function public.mark_proposal_viewed(p_proposal_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_p proposals;
begin
  select * into v_p from proposals where id = p_proposal_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  if job_client_id(v_p.job_id) is distinct from v_uid then raise exception 'NOT_ALLOWED'; end if;
  update proposals set client_viewed_at = now() where id = p_proposal_id and client_viewed_at is null;
end;
$$;

-- Ustaning portfolio rasmlari (eng yangi 4 tasi) — murojaat kartasi uchun
create or replace function public._portfolio_json(p_user_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('path', f.path, 'updated_at', f.updated_at) order by f.updated_at desc), '[]'::jsonb)
  from (select path, updated_at from files
         where bucket = 'portfolio-photos' and path like p_user_id::text || '/%'
         order by updated_at desc limit 4) f;
$$;

-- get_my_jobs: + ko'rinadigan holat, yangi (ko'rilmagan) murojaatlar, manzil, tafsilotlar
create or replace function public.get_my_jobs()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := require_uid();
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', j.id, 'title', j.title, 'category', j.category, 'district', j.district,
      'budget', j.budget, 'urgency', j.urgency, 'status', j.status, 'created_at', j.created_at,
      'has_photo', j.has_photo,
      'order_status', _order_status(j.id),
      'address', (select a.address from job_addresses a where a.job_id = j.id),
      'details', _job_details_json(j.id),
      'proposals_count', (select count(*) from proposals p where p.job_id = j.id and p.status = 'submitted'),
      'new_proposals', (select count(*) from proposals p
                         where p.job_id = j.id and p.status = 'submitted' and p.client_viewed_at is null),
      'contract', (
        select jsonb_build_object('id', k.id, 'status', k.status, 'provider_name', pr.full_name, 'price', k.price)
        from contracts k join profiles pr on pr.id = k.provider_id
        where k.job_id = j.id order by k.created_at desc limit 1
      )
    ) order by j.created_at desc)
    from jobs j where j.client_id = v_uid
  ), '[]'::jsonb);
end;
$$;

-- Mijozning ochiq e'lonlariga yaqinda murojaat qilgan ustalar (bosh sahifa)
create or replace function public.get_recent_applicants(p_limit int default 10)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := require_uid();
begin
  return coalesce((
    select jsonb_agg(x.item order by x.created_at desc)
    from (
      select p.created_at, jsonb_build_object(
        'proposal_id', p.id, 'price', p.price, 'created_at', p.created_at, 'viewed', p.client_viewed_at is not null,
        'job', jsonb_build_object('id', j.id, 'title', j.title),
        'provider', jsonb_build_object('id', pr.id, 'full_name', pr.full_name, 'avatar_updated_at', pr.avatar_updated_at,
                                       'stats', provider_stats(pr.id))
      ) as item
      from proposals p
      join jobs j on j.id = p.job_id
      join profiles pr on pr.id = p.provider_id
      where j.client_id = v_uid and j.status = 'open' and p.status = 'submitted' and not _blocked(v_uid, p.provider_id)
      order by p.created_at desc
      limit least(greatest(coalesce(p_limit, 10), 1), 30)
    ) x
  ), '[]'::jsonb);
end;
$$;

-- get_job_proposals: + rasm, shaxsi tasdiqlanganmi, mutaxassisliklar, portfolio, ish boshlash va davomiylik,
-- mijoz ko'rib chiqqanmi. Saralash va "tavsiya" avvalgidek.
create or replace function public.get_job_proposals(p_job_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := require_uid();
begin
  if job_client_id(p_job_id) is distinct from v_uid then raise exception 'NOT_ALLOWED'; end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', x.id, 'price', x.price, 'message', x.message, 'status', x.status, 'created_at', x.created_at,
      'eta_minutes', x.eta_minutes, 'score', round(x.score),
      'available_from', x.available_from, 'duration', x.duration, 'viewed', x.client_viewed_at is not null,
      'recommended', x.status = 'submitted' and x.rank <= 3,
      'unread', (select count(*) from messages m where m.proposal_id = x.id and m.sender_id <> v_uid and m.read_at is null),
      'provider', x.provider,
      'team', (select jsonb_build_object('id', t.id, 'name', t.name, 'kind', t.kind, 'size', t.size,
                                         'stats', team_stats(t.id))
               from teams t where t.id = x.team_id)
    ) order by (x.status = 'submitted') desc, x.score desc, x.created_at asc)
    from (
      select y.*, rank() over (partition by y.status = 'submitted' order by y.score desc, y.created_at) as rank
      from (
        select p.id, p.price, p.message, p.status, p.created_at, p.eta_minutes, p.team_id,
          p.available_from, p.duration, p.client_viewed_at,
          jsonb_build_object('id', pr.id, 'full_name', pr.full_name, 'headline', pp.headline,
                             'avatar_updated_at', pr.avatar_updated_at, 'categories', pp.categories,
                             'verified', pp.id_verified_at is not null, 'portfolio', _portfolio_json(pr.id),
                             'experience_years', pp.experience_years, 'stats', st.s) as provider,
          coalesce((st.s->>'avg_rating')::numeric, 4.0) * 20
            + least((st.s->>'completed_jobs')::int, 20) * 1.5
            - (st.s->>'withdrawals')::int * 10
            - (st.s->>'disputes_lost')::int * 15
            + (coalesce((st.s->>'on_time_rate')::numeric, 85) - 85) * 0.4
            + case when p.team_id is not null and (select crew_needed from jobs where id = p_job_id) then 15 else 0 end
            + case when p.eta_minutes is not null then greatest(0, 30 - p.eta_minutes / 2.0) else 0 end
            + 20.0 * min(p.price) filter (where p.status = 'submitted') over () / p.price
            as score
        from proposals p
        join profiles pr on pr.id = p.provider_id
        left join provider_profiles pp on pp.user_id = p.provider_id
        cross join lateral (select provider_stats(pr.id) as s) st
        where p.job_id = p_job_id and p.status in ('submitted', 'declined', 'accepted')
          and (p.status = 'accepted' or not _blocked(v_uid, p.provider_id))
      ) y
    ) x
  ), '[]'::jsonb);
end;
$$;

-- Yangi baho haqida bildirishnoma (baho matni 14 kun yoki ikkala tomon baho qo'yguncha yashirin)
create or replace function public.notify_new_review()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_name text;
begin
  select full_name into v_name from profiles where id = new.reviewer_id;
  perform queue_notification(new.reviewee_id, format(
    E'⭐ %s sizga baho qo''ydi. Baholar ikkala tomon baho qo''ygach yoki 14 kundan keyin ochiladi.', v_name),
    '/contract/' || new.contract_id);
  return new;
end;
$$;

drop trigger if exists trg_notify_new_review on public.reviews;
create trigger trg_notify_new_review after insert on public.reviews
for each row execute function public.notify_new_review();

-- Mijoz profili: shaxsiy yoki tashkilot
alter table public.users add column if not exists account_type text not null default 'personal';
alter table public.users add column if not exists organization_name text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'users_account_type_check') then
    alter table public.users add constraint users_account_type_check check (account_type in ('personal', 'organization'));
  end if;
end $$;

create or replace function public.set_account_type(p_type text, p_organization_name text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_org text := nullif(btrim(coalesce(p_organization_name, '')), '');
begin
  if p_type is null or p_type not in ('personal', 'organization') then raise exception 'INVALID_INPUT'; end if;
  if p_type = 'organization' and char_length(coalesce(v_org, '')) not between 2 and 120 then raise exception 'INVALID_NAME'; end if;
  update users set account_type = p_type, organization_name = case when p_type = 'organization' then v_org end
   where id = v_uid;
end;
$$;


-- ===== ixtiyoriy kelishuv =====
-- Mijoz va usta ishni boshlashdan oldin muhim shartlarni ilova ichida sodda shaklda qayd etadi. Butunlay ixtiyoriy:
-- buyurtma, murojaat, shartnoma va yozishmalar kelishuvsiz ham avvalgidek ishlaydi; rad etish e'lonni bekor qilmaydi.
-- Mavjud to'liq shartnoma (contracts) alohida qoladi — kelishuv uning narxi yoki to'loviga ta'sir qilmaydi.
--
-- Qoidalar (server tomonida majburiy):
--   * kelishuv buyurtma egasi (mijoz) va shu e'longa murojaat qilgan usta o'rtasida; ko'radi va o'zgartiradi
--     faqat shu ikkisi; yuborilmagan qoralamani (sent_at is null) — faqat muallifi;
--   * shartlarning har bir o'zgarishi — yangi versiya; yuborgan tomon o'z versiyasini tasdiqlagan hisoblanadi,
--     oldingi versiya tasdiqlari yangisiga o'tmaydi;
--   * kelishuv faqat ikkala tomon AYNAN BIR versiyani tasdiqlaganda "accepted" bo'ladi; tasdiqlangan
--     kelishuvga o'zgartirish taklif qilinsa, yangi versiya tasdiqlanguncha eskisi amalda qoladi (accepted_version);
--   * har bir amal (kim, qachon, qaysi versiya) agreement_events da saqlanadi, hech narsa o'chirilmaydi;
--   * bitta e'lon va usta uchun bir vaqtda faqat bitta ochiq kelishuv;
--   * amallar agreements qatorini qulflab bajariladi va kutilgan versiya tekshiriladi (VERSION_CHANGED) —
--     bir vaqtda kelgan o'zgarishlar tasdiqlarni chalkashtirmaydi.
create table if not exists public.agreements (
  id               uuid primary key default gen_random_uuid(),
  number           bigint generated always as identity unique,
  job_id           uuid not null references public.jobs (id) on delete cascade,
  proposal_id      uuid not null references public.proposals (id) on delete cascade,
  client_id        uuid not null references public.users (id) on delete cascade,
  provider_id      uuid not null references public.users (id) on delete cascade,
  status           text not null check (status in ('draft', 'proposed', 'changes_proposed', 'accepted', 'rejected', 'cancelled')),
  current_version  int not null default 1,
  accepted_version int,
  accepted_at      timestamptz,
  created_by       uuid not null references public.users (id) on delete cascade,
  created_at       timestamptz not null default now(),
  -- Qarshi tomonga yuborilgan vaqt; null — qoralama, uni faqat muallif ko'radi
  sent_at          timestamptz,
  updated_at       timestamptz not null default now(),
  closed_by        uuid references public.users (id) on delete set null,
  closed_at        timestamptz,
  close_reason     text check (char_length(close_reason) <= 500)
);

-- Bir juftlik (e'lon + usta) uchun bitta ochiq kelishuv; qoralamalar hisobga kirmaydi (yuborishda tekshiriladi)
create unique index if not exists agreements_one_open on public.agreements (job_id, provider_id)
  where status in ('proposed', 'changes_proposed', 'accepted');
create index if not exists agreements_client_idx on public.agreements (client_id, updated_at desc);
create index if not exists agreements_provider_idx on public.agreements (provider_id, updated_at desc);

create table if not exists public.agreement_versions (
  agreement_id uuid not null references public.agreements (id) on delete cascade,
  version      int not null,
  terms        jsonb not null,
  comment      text check (char_length(comment) <= 500),
  created_by   uuid not null references public.users (id) on delete cascade,
  created_at   timestamptz not null default now(),
  primary key (agreement_id, version)
);

create table if not exists public.agreement_approvals (
  agreement_id uuid not null,
  version      int not null,
  user_id      uuid not null references public.users (id) on delete cascade,
  approved_at  timestamptz not null default now(),
  primary key (agreement_id, version, user_id),
  foreign key (agreement_id, version) references public.agreement_versions (agreement_id, version) on delete cascade
);

create table if not exists public.agreement_events (
  id           bigint generated always as identity primary key,
  agreement_id uuid not null references public.agreements (id) on delete cascade,
  version      int,
  actor_id     uuid references public.users (id) on delete set null,
  action       text not null check (action in ('draft', 'sent', 'approved', 'changes_proposed', 'confirmed',
                                               'rejected', 'change_rejected', 'cancelled')),
  comment      text check (char_length(comment) <= 500),
  created_at   timestamptz not null default now()
);

create index if not exists agreement_events_idx on public.agreement_events (agreement_id, id);

alter table public.agreements enable row level security;
alter table public.agreement_versions enable row level security;
alter table public.agreement_approvals enable row level security;
alter table public.agreement_events enable row level security;

-- Tizim xabarlari yozishmada (kelishuv holati o'zgarganda) — haqiqiy holatdan yoziladi
alter table public.messages add column if not exists kind text not null default 'text';
alter table public.messages add column if not exists agreement_id uuid references public.agreements (id) on delete set null;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'messages_kind_check') then
    alter table public.messages add constraint messages_kind_check check (kind in ('text', 'system'));
  end if;
end $$;

-- Shartlarni tekshiradi va bir xil ko'rinishga keltiradi. Narx yoki muddat noma'lum bo'lsa — null
-- ("Hali kelishilmagan"), o'ylab topilmaydi.
create or replace function public._agreement_terms(p jsonb)
returns jsonb language plpgsql immutable as $$
declare
  v_scope text := btrim(coalesce(p ->> 'scope', ''));
  v_price int;
  v_price_type text := coalesce(nullif(p ->> 'price_type', ''), 'negotiable');
  v_start date := _opt_date(p, 'start_date');
  v_end date := _opt_date(p, 'end_date');
  v_materials text := nullif(p ->> 'materials', '');
begin
  if char_length(v_scope) not between 10 and 2000 then raise exception 'INVALID_SCOPE'; end if;
  begin
    v_price := nullif(p ->> 'price', '')::int;
  exception when others then
    raise exception 'INVALID_PRICE';
  end;
  if v_price is not null and v_price not between 10000 and 100000000 then raise exception 'INVALID_PRICE'; end if;
  if v_price_type not in ('fixed', 'negotiable') then raise exception 'INVALID_INPUT'; end if;
  if v_price_type = 'fixed' and v_price is null then raise exception 'INVALID_PRICE'; end if;
  if v_start is not null and v_end is not null and v_end < v_start then raise exception 'INVALID_DATE'; end if;
  if v_materials is not null and v_materials not in ('client', 'provider', 'shared') then raise exception 'INVALID_INPUT'; end if;
  return jsonb_build_object(
    'scope', v_scope,
    'price', v_price,
    'price_type', v_price_type,
    'start_date', v_start,
    'end_date', v_end,
    'duration', _opt_text(p, 'duration', 100),
    'materials', v_materials,
    'payment_terms', _opt_text(p, 'payment_terms', 500),
    'extra_work', _opt_text(p, 'extra_work', 500),
    'notes', _opt_text(p, 'notes', 1000)
  );
end;
$$;

-- Amal yozuvi + qarshi tomonga bildirishnoma + yozishmada tizim xabari (taklif chati; shartnoma chati uni ham ko'rsatadi)
create or replace function public._agreement_event(p_a agreements, p_actor uuid, p_action text, p_version int, p_comment text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_name text;
  v_title text;
  v_other uuid := case when p_actor = p_a.client_id then p_a.provider_id else p_a.client_id end;
  v_text text;
  v_link text := '/agreement/' || p_a.id;
begin
  insert into agreement_events (agreement_id, version, actor_id, action, comment)
  values (p_a.id, p_version, p_actor, p_action, nullif(btrim(coalesce(p_comment, '')), ''));
  if p_action = 'draft' then return; end if;  -- qoralama qarshi tomonga ko'rinmaydi

  select full_name into v_name from profiles where id = p_actor;
  select title into v_title from jobs where id = p_a.job_id;
  v_text := case p_action
    when 'sent' then format('%s "%s" bo''yicha kelishuv taklifini yubordi.', v_name, v_title)
    when 'changes_proposed' then format('%s kelishuvga o''zgartirish taklif qildi (%s-versiya).', v_name, p_version)
    when 'approved' then format('%s kelishuvning %s-versiyasini tasdiqladi.', v_name, p_version)
    when 'confirmed' then format('Ikkala tomon kelishuvning %s-versiyasini tasdiqladi.', p_version)
    when 'rejected' then format('%s kelishuv taklifini rad etdi.', v_name)
    when 'change_rejected' then format('%s o''zgartirish taklifini rad etdi — amaldagi %s-versiya kuchda qoladi.',
                                       v_name, p_a.accepted_version)
    when 'cancelled' then format('%s kelishuvni bekor qildi.', v_name)
  end;

  insert into messages (proposal_id, sender_id, text, kind, agreement_id)
  values (p_a.proposal_id, p_actor, v_text, 'system', p_a.id);

  perform queue_notification(v_other, E'\U0001F91D ' || v_text, v_link);
  if p_action = 'confirmed' then
    perform queue_notification(p_actor, E'\U0001F91D ' || v_text, v_link);
  end if;
end;
$$;

-- Shu e'lon va usta uchun yuborilgan ochiq kelishuv bormi
create or replace function public._agreement_open_exists(p_job_id uuid, p_provider_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from agreements a where a.job_id = p_job_id and a.provider_id = p_provider_id
                  and a.status in ('proposed', 'changes_proposed', 'accepted'));
$$;

-- Kelishuvni yaratish (mijoz yoki usta). p_send = false — qoralama (faqat muallif ko'radi).
create or replace function public.create_agreement(p_proposal_id uuid, p_terms jsonb, p_send boolean default true)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_p proposals;
  v_job jobs;
  v_terms jsonb := _agreement_terms(p_terms);
  v_a agreements;
begin
  select * into v_p from proposals where id = p_proposal_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  select * into v_job from jobs where id = v_p.job_id;
  if v_uid <> v_job.client_id and v_uid <> v_p.provider_id then raise exception 'NOT_ALLOWED'; end if;
  if v_p.status not in ('submitted', 'accepted') or v_job.status = 'cancelled' then raise exception 'INVALID_STATE'; end if;
  if _blocked(v_job.client_id, v_p.provider_id) then raise exception 'USER_BLOCKED'; end if;
  if _has_contact(v_terms::text) then raise exception 'CONTACT_NOT_ALLOWED'; end if;
  if _agreement_open_exists(v_job.id, v_p.provider_id)
     or exists (select 1 from agreements a where a.job_id = v_job.id and a.provider_id = v_p.provider_id
                 and a.status = 'draft' and a.created_by = v_uid) then
    raise exception 'AGREEMENT_EXISTS';
  end if;

  insert into agreements (job_id, proposal_id, client_id, provider_id, status, created_by, sent_at)
  values (v_job.id, v_p.id, v_job.client_id, v_p.provider_id,
          case when coalesce(p_send, true) then 'proposed' else 'draft' end, v_uid,
          case when coalesce(p_send, true) then now() end)
  returning * into v_a;
  insert into agreement_versions (agreement_id, version, terms, created_by) values (v_a.id, 1, v_terms, v_uid);
  if coalesce(p_send, true) then
    insert into agreement_approvals (agreement_id, version, user_id) values (v_a.id, 1, v_uid);
    perform _agreement_event(v_a, v_uid, 'sent', 1, null);
  else
    perform _agreement_event(v_a, v_uid, 'draft', 1, null);
  end if;
  return v_a.id;
end;
$$;

-- Qoralamani saqlash (shartlarni almashtirish) va/yoki yuborish — faqat muallif
create or replace function public.save_agreement_draft(p_agreement_id uuid, p_terms jsonb, p_send boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_a agreements;
  v_terms jsonb;
begin
  select * into v_a from agreements where id = p_agreement_id for update;
  if not found or v_a.created_by <> v_uid then raise exception 'NOT_FOUND'; end if;
  if v_a.status <> 'draft' then raise exception 'INVALID_STATE'; end if;
  if p_terms is not null then
    v_terms := _agreement_terms(p_terms);
    if _has_contact(v_terms::text) then raise exception 'CONTACT_NOT_ALLOWED'; end if;
    update agreement_versions set terms = v_terms, created_at = now() where agreement_id = v_a.id and version = 1;
  end if;
  if coalesce(p_send, false) then
    if _agreement_open_exists(v_a.job_id, v_a.provider_id) then raise exception 'AGREEMENT_EXISTS'; end if;
    update agreements set status = 'proposed', sent_at = now(), updated_at = now() where id = v_a.id returning * into v_a;
    insert into agreement_approvals (agreement_id, version, user_id) values (v_a.id, 1, v_uid);
    perform _agreement_event(v_a, v_uid, 'sent', 1, null);
  end if;
end;
$$;

-- Tasdiqlash: faqat joriy (kutilayotgan) versiya; ikkala tomon tasdiqlasa — "accepted"
create or replace function public.approve_agreement(p_agreement_id uuid, p_version int)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_a agreements;
begin
  select * into v_a from agreements where id = p_agreement_id for update;
  if not found or (v_uid <> v_a.client_id and v_uid <> v_a.provider_id) or v_a.status = 'draft' then
    raise exception 'NOT_FOUND';
  end if;
  if v_a.status not in ('proposed', 'changes_proposed') then raise exception 'INVALID_STATE'; end if;
  if p_version is distinct from v_a.current_version then raise exception 'VERSION_CHANGED'; end if;
  if exists (select 1 from agreement_approvals where agreement_id = v_a.id and version = p_version and user_id = v_uid) then
    raise exception 'ALREADY_APPROVED';
  end if;

  insert into agreement_approvals (agreement_id, version, user_id) values (v_a.id, p_version, v_uid);
  if (select count(*) from agreement_approvals
       where agreement_id = v_a.id and version = p_version and user_id in (v_a.client_id, v_a.provider_id)) = 2 then
    update agreements set status = 'accepted', accepted_version = p_version, accepted_at = now(), updated_at = now()
     where id = v_a.id returning * into v_a;
    perform _agreement_event(v_a, v_uid, 'confirmed', p_version, null);
    return 'accepted';
  end if;
  update agreements set updated_at = now() where id = v_a.id;
  perform _agreement_event(v_a, v_uid, 'approved', p_version, null);
  return v_a.status;
end;
$$;

-- O'zgartirish taklifi: yangi versiya (taklif qilgan tomon uni tasdiqlagan hisoblanadi). Tasdiqlangan kelishuvga ham
-- taklif qilish mumkin — yangi versiya tasdiqlanguncha amaldagi versiya kuchda qoladi.
create or replace function public.propose_agreement_changes(p_agreement_id uuid, p_base_version int, p_terms jsonb, p_comment text default null)
returns int language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_a agreements;
  v_terms jsonb := _agreement_terms(p_terms);
  v_version int;
begin
  if char_length(coalesce(p_comment, '')) > 500 then raise exception 'INVALID_INPUT'; end if;
  select * into v_a from agreements where id = p_agreement_id for update;
  if not found or (v_uid <> v_a.client_id and v_uid <> v_a.provider_id) or v_a.status = 'draft' then
    raise exception 'NOT_FOUND';
  end if;
  if v_a.status not in ('proposed', 'changes_proposed', 'accepted') then raise exception 'INVALID_STATE'; end if;
  if p_base_version is distinct from v_a.current_version then raise exception 'VERSION_CHANGED'; end if;
  if _has_contact(v_terms::text) or _has_contact(p_comment) then raise exception 'CONTACT_NOT_ALLOWED'; end if;
  if v_terms = (select terms from agreement_versions where agreement_id = v_a.id and version = v_a.current_version) then
    raise exception 'NO_CHANGES';
  end if;

  v_version := v_a.current_version + 1;
  insert into agreement_versions (agreement_id, version, terms, comment, created_by)
  values (v_a.id, v_version, v_terms, nullif(btrim(coalesce(p_comment, '')), ''), v_uid);
  insert into agreement_approvals (agreement_id, version, user_id) values (v_a.id, v_version, v_uid);
  update agreements set status = 'changes_proposed', current_version = v_version, updated_at = now()
   where id = v_a.id returning * into v_a;
  perform _agreement_event(v_a, v_uid, 'changes_proposed', v_version, p_comment);
  return v_version;
end;
$$;

-- Rad etish: kutilayotgan versiyani qabul qilmagan tomon. Avval tasdiqlangan versiya bo'lsa — u amalda qoladi.
create or replace function public.reject_agreement(p_agreement_id uuid, p_version int, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_a agreements;
begin
  if char_length(coalesce(p_reason, '')) > 500 then raise exception 'INVALID_INPUT'; end if;
  select * into v_a from agreements where id = p_agreement_id for update;
  if not found or (v_uid <> v_a.client_id and v_uid <> v_a.provider_id) or v_a.status = 'draft' then
    raise exception 'NOT_FOUND';
  end if;
  if v_a.status not in ('proposed', 'changes_proposed') then raise exception 'INVALID_STATE'; end if;
  if p_version is distinct from v_a.current_version then raise exception 'VERSION_CHANGED'; end if;
  -- O'zi taklif qilgan versiyani rad etib bo'lmaydi — buning uchun "bekor qilish"
  if exists (select 1 from agreement_approvals where agreement_id = v_a.id and version = p_version and user_id = v_uid) then
    raise exception 'NOT_ALLOWED';
  end if;

  if v_a.accepted_version is not null then
    update agreements set status = 'accepted', updated_at = now() where id = v_a.id returning * into v_a;
    perform _agreement_event(v_a, v_uid, 'change_rejected', p_version, p_reason);
  else
    update agreements set status = 'rejected', closed_by = v_uid, closed_at = now(),
                          close_reason = nullif(btrim(coalesce(p_reason, '')), ''), updated_at = now()
     where id = v_a.id returning * into v_a;
    perform _agreement_event(v_a, v_uid, 'rejected', p_version, p_reason);
  end if;
end;
$$;

-- Bekor qilish: istalgan tomon (qoralamani — muallif). Tarix saqlanadi, kim bekor qilgani yoziladi.
create or replace function public.cancel_agreement(p_agreement_id uuid, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_a agreements;
begin
  if char_length(coalesce(p_reason, '')) > 500 then raise exception 'INVALID_INPUT'; end if;
  select * into v_a from agreements where id = p_agreement_id for update;
  if not found or (v_uid <> v_a.client_id and v_uid <> v_a.provider_id)
     or (v_a.sent_at is null and v_a.created_by <> v_uid) then
    raise exception 'NOT_FOUND';
  end if;
  if v_a.status in ('rejected', 'cancelled') then raise exception 'INVALID_STATE'; end if;
  update agreements set status = 'cancelled', closed_by = v_uid, closed_at = now(),
                        close_reason = nullif(btrim(coalesce(p_reason, '')), ''), updated_at = now()
   where id = v_a.id returning * into v_a;
  if v_a.sent_at is null then
    -- Yuborilmagan qoralama: faqat tarixga, qarshi tomon bilmaydi
    insert into agreement_events (agreement_id, version, actor_id, action, comment)
    values (v_a.id, v_a.current_version, v_uid, 'cancelled', v_a.close_reason);
  else
    perform _agreement_event(v_a, v_uid, 'cancelled', v_a.current_version, v_a.close_reason);
  end if;
end;
$$;

-- Qisqa ko'rinish (ro'yxatlar uchun): kutilayotgan amal kimda
create or replace function public._agreement_brief(p_a agreements, p_uid uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', p_a.id, 'number', p_a.number, 'status', p_a.status, 'job_id', p_a.job_id, 'proposal_id', p_a.proposal_id,
    'current_version', p_a.current_version, 'accepted_version', p_a.accepted_version, 'updated_at', p_a.updated_at,
    'counterpart', (select jsonb_build_object('id', u.id, 'full_name', u.full_name) from profiles u
                     where u.id = case when p_uid = p_a.client_id then p_a.provider_id else p_a.client_id end),
    'pending_for_me', p_a.status in ('proposed', 'changes_proposed')
      and not exists (select 1 from agreement_approvals ap
                       where ap.agreement_id = p_a.id and ap.version = p_a.current_version and ap.user_id = p_uid)
  );
$$;

create or replace function public.get_agreement(p_agreement_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_a agreements;
begin
  select * into v_a from agreements where id = p_agreement_id;
  if not found or (v_uid <> v_a.client_id and v_uid <> v_a.provider_id)
     or (v_a.sent_at is null and v_a.created_by <> v_uid) then
    raise exception 'NOT_FOUND';
  end if;
  return _agreement_brief(v_a, v_uid) || jsonb_build_object(
    'my_role', case when v_uid = v_a.client_id then 'client' else 'provider' end,
    'created_by', v_a.created_by, 'created_at', v_a.created_at, 'sent_at', v_a.sent_at, 'accepted_at', v_a.accepted_at,
    'closed_by', v_a.closed_by, 'closed_at', v_a.closed_at, 'close_reason', v_a.close_reason,
    'job', (select jsonb_build_object('id', j.id, 'title', j.title, 'category', j.category, 'district', j.district)
              from jobs j where j.id = v_a.job_id),
    'client', (select jsonb_build_object('id', u.id, 'full_name', u.full_name, 'avatar_updated_at', u.avatar_updated_at)
                 from profiles u where u.id = v_a.client_id),
    'provider', (select jsonb_build_object('id', u.id, 'full_name', u.full_name, 'avatar_updated_at', u.avatar_updated_at)
                   from profiles u where u.id = v_a.provider_id),
    'contract', (select jsonb_build_object('id', k.id, 'status', k.status) from contracts k
                  where k.proposal_id = v_a.proposal_id),
    'versions', (select jsonb_agg(jsonb_build_object(
                    'version', v.version, 'terms', v.terms, 'comment', v.comment, 'created_by', v.created_by,
                    'created_at', v.created_at,
                    'approvals', (select coalesce(jsonb_agg(jsonb_build_object('user_id', ap.user_id, 'approved_at', ap.approved_at)
                                                            order by ap.approved_at), '[]'::jsonb)
                                    from agreement_approvals ap
                                   where ap.agreement_id = v.agreement_id and ap.version = v.version)
                  ) order by v.version desc)
                  from agreement_versions v where v.agreement_id = v_a.id),
    'events', (select jsonb_agg(jsonb_build_object(
                  'action', e.action, 'version', e.version, 'actor_id', e.actor_id, 'comment', e.comment,
                  'created_at', e.created_at, 'actor_name', (select full_name from profiles where id = e.actor_id)
                ) order by e.id desc)
                from agreement_events e where e.agreement_id = v_a.id
                  and (e.action <> 'draft' or e.actor_id = v_uid))
  );
end;
$$;

-- Buyurtmaning kelishuvlari: mijozga — hammasi (boshqaning qoralamasisiz), ustaga — faqat o'ziniki
create or replace function public.get_job_agreements(p_job_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := require_uid();
begin
  if not exists (select 1 from jobs where id = p_job_id) then raise exception 'NOT_FOUND'; end if;
  return coalesce((
    select jsonb_agg(_agreement_brief(a, v_uid) order by a.updated_at desc)
    from agreements a
    where a.job_id = p_job_id and (a.client_id = v_uid or a.provider_id = v_uid)
      and (a.sent_at is not null or a.created_by = v_uid)
  ), '[]'::jsonb);
end;
$$;

-- Yozishma (taklif yoki shartnoma chati) uchun: shu juftlikning oxirgi kelishuvi va yangisini yaratish mumkinmi
create or replace function public.get_chat_agreement(p_proposal_id uuid default null, p_contract_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_proposal uuid := p_proposal_id;
  v_p proposals;
  v_client uuid;
  v_a agreements;
begin
  if v_proposal is null then
    select k.proposal_id into v_proposal from contracts k
     where k.id = p_contract_id and (k.client_id = v_uid or k.provider_id = v_uid);
  end if;
  select * into v_p from proposals where id = v_proposal;
  if not found then raise exception 'NOT_FOUND'; end if;
  v_client := job_client_id(v_p.job_id);
  if v_uid <> v_client and v_uid <> v_p.provider_id then raise exception 'NOT_ALLOWED'; end if;

  select * into v_a from agreements a
   where a.job_id = v_p.job_id and a.provider_id = v_p.provider_id and (a.sent_at is not null or a.created_by = v_uid)
   order by (a.status in ('proposed', 'changes_proposed', 'accepted')) desc, a.created_at desc limit 1;
  return jsonb_build_object(
    'proposal_id', v_p.id,
    'job_id', v_p.job_id,
    'agreement', case when v_a.id is not null then _agreement_brief(v_a, v_uid) end,
    'can_create', v_p.status in ('submitted', 'accepted') and not _agreement_open_exists(v_p.job_id, v_p.provider_id)
      and (v_a.id is null or v_a.status in ('rejected', 'cancelled'))
  );
end;
$$;

revoke execute on function
  public._job_details_json(uuid), public._opt_text(jsonb, text, int), public._opt_date(jsonb, text),
  public.set_job_details(uuid, jsonb), public.update_job(uuid, text, text, text, text, text, int, text),
  public._order_status(uuid), public.set_proposal_terms(uuid, date, text), public.mark_proposal_viewed(uuid),
  public._portfolio_json(uuid), public.get_my_jobs(), public.get_recent_applicants(int), public.get_job_proposals(uuid),
  public.notify_new_review(), public.set_account_type(text, text),
  public._agreement_terms(jsonb), public._agreement_event(agreements, uuid, text, int, text),
  public._agreement_open_exists(uuid, uuid),
  public.create_agreement(uuid, jsonb, boolean), public.save_agreement_draft(uuid, jsonb, boolean),
  public.approve_agreement(uuid, int), public.propose_agreement_changes(uuid, int, jsonb, text),
  public.reject_agreement(uuid, int, text), public.cancel_agreement(uuid, text),
  public._agreement_brief(agreements, uuid), public.get_agreement(uuid), public.get_job_agreements(uuid),
  public.get_chat_agreement(uuid, uuid)
from public, anon, authenticated;

grant execute on function
  public.set_job_details(uuid, jsonb), public.update_job(uuid, text, text, text, text, text, int, text),
  public.set_proposal_terms(uuid, date, text), public.mark_proposal_viewed(uuid),
  public.get_my_jobs(), public.get_recent_applicants(int), public.get_job_proposals(uuid),
  public.set_account_type(text, text),
  public.create_agreement(uuid, jsonb, boolean), public.save_agreement_draft(uuid, jsonb, boolean),
  public.approve_agreement(uuid, int), public.propose_agreement_changes(uuid, int, jsonb, text),
  public.reject_agreement(uuid, int, text), public.cancel_agreement(uuid, text),
  public.get_agreement(uuid), public.get_job_agreements(uuid), public.get_chat_agreement(uuid, uuid)
to authenticated;


-- ===== soliq maqomi (ixtiyoriy belgi) =====
-- Usta xohlasa o'zini o'zi band qilgan shaxs yoki YaTT sifatida ro'yxatdan o'tganini STIR (yoki JShShIR) bilan
-- ko'rsatadi; admin uni soliq.uz da tekshirib tasdiqlaydi va profilda "Soliqda ro'yxatdan o'tgan" belgisi chiqadi.
-- Majburiy emas (boshida ustalar kelishi to'xtamasin). STIR'ni faqat egasi (get_me) va admin ko'radi,
-- ochiq profilda faqat belgi (provider_stats.tax_registered). Ustunlar yuqorida, provider_profiles yonida.
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'provider_profiles_tax_check') then
    alter table public.provider_profiles add constraint provider_profiles_tax_check check (
      (tax_kind is null and tax_id is null)
      or (tax_kind in ('self_employed', 'entrepreneur') and tax_id ~ '^([0-9]{9}|[0-9]{14})$'));
  end if;
end $$;

create index if not exists provider_profiles_tax_pending_idx on public.provider_profiles (tax_submitted_at)
  where tax_id is not null and tax_verified_at is null and tax_rejection_reason is null;

-- Usta soliq maqomini yuboradi; p_tax_id bo'sh bo'lsa — olib tashlaydi. p_consent — STIR'ni soliq bazasida
-- tekshirishga rozilik (ilovadagi belgi), usiz yuborilmaydi. O'zgargan ma'lumot qayta tekshiruvga tushadi.
create or replace function public.submit_tax_status(p_kind text, p_tax_id text, p_consent boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_id text := nullif(regexp_replace(coalesce(p_tax_id, ''), '\D', '', 'g'), '');
begin
  if not exists (select 1 from provider_profiles where user_id = v_uid) then raise exception 'NOT_FOUND'; end if;
  if v_id is null then
    update provider_profiles
       set tax_kind = null, tax_id = null, tax_consent_at = null, tax_submitted_at = null,
           tax_verified_at = null, tax_rejection_reason = null
     where user_id = v_uid;
    return;
  end if;
  if p_kind is null or p_kind not in ('self_employed', 'entrepreneur') then raise exception 'INVALID_INPUT'; end if;
  if v_id !~ '^([0-9]{9}|[0-9]{14})$' then raise exception 'INVALID_TAX_ID'; end if;
  if not coalesce(p_consent, false) then raise exception 'CONSENT_REQUIRED'; end if;

  -- SET ichida eski qiymatlar o'qiladi: ma'lumot o'zgarmagan bo'lsa tasdiq saqlanadi
  update provider_profiles
     set tax_verified_at = case when tax_kind = p_kind and tax_id = v_id then tax_verified_at end,
         tax_submitted_at = case when tax_kind = p_kind and tax_id = v_id and tax_rejection_reason is null
                                 then tax_submitted_at else now() end,
         tax_kind = p_kind, tax_id = v_id, tax_consent_at = now(), tax_rejection_reason = null
   where user_id = v_uid;
end;
$$;

-- Admin: tekshirilishi kerak bo'lgan soliq maqomlari (eng eskisi birinchi)
create or replace function public.admin_get_pending_tax()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform require_admin();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'user_id',          pp.user_id,
      'full_name',        p.full_name,
      'phone',            u.phone,
      'headline',         pp.headline,
      'tax_kind',         pp.tax_kind,
      'tax_id',           pp.tax_id,
      'tax_submitted_at', pp.tax_submitted_at,
      'id_verified',      pp.id_verified_at is not null
    ) order by pp.tax_submitted_at asc)
    from provider_profiles pp
    join profiles p on p.id = pp.user_id
    join auth.users u on u.id = pp.user_id
    where pp.tax_id is not null and pp.tax_verified_at is null and pp.tax_rejection_reason is null
  ), '[]'::jsonb);
end;
$$;

-- Admin soliq.uz da tekshirgach tasdiqlaydi yoki sabab bilan rad etadi (tasdiqlanganni ham bekor qilish mumkin)
create or replace function public.admin_review_tax(p_user_id uuid, p_approve boolean, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  perform require_admin();
  if not p_approve and v_reason is null then raise exception 'INVALID_INPUT'; end if;
  update provider_profiles
     set tax_verified_at = case when p_approve then coalesce(tax_verified_at, now()) end,
         tax_rejection_reason = case when p_approve then null else left(v_reason, 300) end
   where user_id = p_user_id and tax_id is not null;
  if not found then raise exception 'NOT_FOUND'; end if;

  perform queue_notification(p_user_id,
    case when p_approve
      then E'\U0001F9FE Soliq maqomingiz tasdiqlandi — profilingizda "Soliqda ro''yxatdan o''tgan" belgisi chiqadi.'
      else format(E'Soliq maqomi tasdiqlanmadi. Sabab: %s', v_reason)
    end,
    '/become-provider');
end;
$$;

revoke execute on function public.submit_tax_status(text, text, boolean), public.admin_get_pending_tax(),
  public.admin_review_tax(uuid, boolean, text)
from public, anon, authenticated;

grant execute on function public.submit_tax_status(text, text, boolean), public.admin_get_pending_tax(),
  public.admin_review_tax(uuid, boolean, text)
to authenticated;
