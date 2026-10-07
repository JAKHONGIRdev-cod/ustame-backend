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

create or replace function public.provider_stats(p_user_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  with c as (
    select
      count(*) filter (where status = 'completed')                                        as completed,
      count(*) filter (where status = 'cancelled' and cancelled_by = 'provider')          as withdrawals,
      count(*) filter (where dispute_resolution = 'client')                               as disputes_lost
    from contracts where provider_id = p_user_id
  ),
  r as (
    select count(*) as cnt, round(avg(rating)::numeric, 1) as avg
    from reviews where reviewee_id = p_user_id
      and exists (select 1 from contracts k where k.id = reviews.contract_id and k.provider_id = p_user_id)
  )
  select jsonb_build_object(
    'completed_jobs', c.completed,
    'withdrawals',    c.withdrawals,
    'disputes_lost',  c.disputes_lost,
    'reviews_count',  r.cnt,
    'avg_rating',     r.avg,
    'top_rated',      coalesce(r.avg >= 4.5 and c.completed >= 5, false)
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
           count(*) filter (where status = 'completed') as completed
    from contracts where client_id = p_user_id
  ),
  r as (
    select count(*) as cnt, round(avg(rating)::numeric, 1) as avg
    from reviews where reviewee_id = p_user_id
      and exists (select 1 from contracts k where k.id = reviews.contract_id and k.client_id = p_user_id)
  )
  select jsonb_build_object(
    'jobs_posted',    j.posted,
    'hires',          c.hires,
    'completed_jobs', c.completed,
    'reviews_count',  r.cnt,
    'avg_rating',     r.avg
  )
  from j, c, r;
$$;

create or replace function public.review_is_public(p_contract_id uuid, p_reviewer_id uuid, p_created_at timestamptz)
returns boolean language sql stable security definer set search_path = public as $$
  select p_created_at < now() - interval '7 days'
      or exists (select 1 from reviews o
                 where o.contract_id = p_contract_id and o.reviewer_id <> p_reviewer_id);
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
  if coalesce(p_urgency, 'flexible') not in ('today', 'this_week', 'flexible') then raise exception 'INVALID_INPUT'; end if;

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

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', p.id, 'price', p.price, 'message', p.message, 'status', p.status, 'created_at', p.created_at,
      'provider', jsonb_build_object(
        'id', pr.id, 'full_name', pr.full_name, 'headline', pp.headline,
        'experience_years', pp.experience_years, 'stats', provider_stats(pr.id)
      )
    ) order by (p.status = 'submitted') desc, p.created_at asc)
    from proposals p
    join profiles pr on pr.id = p.provider_id
    left join provider_profiles pp on pp.user_id = p.provider_id
    where p.job_id = p_job_id and p.status in ('submitted', 'declined', 'accepted')
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

  insert into contracts (job_id, proposal_id, client_id, provider_id, price)
  values (v_job.id, v_p.id, v_uid, v_p.provider_id, v_p.price)
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

create or replace function public.submit_proposal(p_job_id uuid, p_price int, p_message text)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_job jobs;
  v_existing proposals;
  v_id uuid;
begin
  if not is_approved_provider(v_uid) then raise exception 'NOT_APPROVED_PROVIDER'; end if;
  if p_price is null or p_price not between 10000 and 100000000 then raise exception 'INVALID_PRICE'; end if;
  if char_length(coalesce(p_message, '')) > 1000 then raise exception 'INVALID_MESSAGE'; end if;

  select * into v_job from jobs where id = p_job_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_job.client_id = v_uid then raise exception 'OWN_JOB'; end if;
  if v_job.status <> 'open' then raise exception 'JOB_NOT_OPEN'; end if;

  select * into v_existing from proposals where job_id = p_job_id and provider_id = v_uid for update;
  if found then
    if v_existing.status <> 'withdrawn'
       or exists (select 1 from contracts k where k.proposal_id = v_existing.id) then
      raise exception 'ALREADY_APPLIED';
    end if;
    update proposals
       set price = p_price, message = btrim(coalesce(p_message, '')), status = 'submitted',
           created_at = now(), updated_at = now()
     where id = v_existing.id;
    return v_existing.id;
  end if;

  insert into proposals (job_id, provider_id, price, message)
  values (p_job_id, v_uid, p_price, btrim(coalesce(p_message, '')))
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
      'contract_id', (select k.id from contracts k where k.proposal_id = p.id)
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
    'auto_approve_at', case when v_k.status = 'submitted' then v_k.submitted_at + interval '48 hours' end,
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
                                         'created_at', v_their_review.created_at) end,
    'can_review', v_k.status = 'completed' and v_my_review.id is null
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
  update contracts
     set status = 'disputed', disputed_at = now(), dispute_reason = left(btrim(p_reason), 1000)
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
  for r in select id from contracts where status = 'submitted' and submitted_at < now() - interval '48 hours'
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
  public.submit_proposal(uuid, int, text),
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

  insert into messages (contract_id, sender_id, text)
  values (p_contract_id, v_uid, v_text)
  returning id, created_at into v_id, v_created;

  return jsonb_build_object(
    'id', v_id, 'sender_id', v_uid, 'text', v_text, 'created_at', v_created, 'read_at', null
  );
end;
$$;

create or replace function public.get_messages(p_contract_id uuid)
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
      'created_at', m.created_at, 'read_at', m.read_at
    ) order by m.created_at asc)
    from messages m where m.contract_id = p_contract_id
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
   where contract_id = p_contract_id and sender_id <> v_uid and read_at is null;
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
  public.get_messages(uuid),
  public.mark_messages_read(uuid)
from public, anon, authenticated;

grant execute on function
  public.send_message(uuid, text),
  public.get_messages(uuid),
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
  update jobs set has_photo = true where id = p_job_id;
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
end;
$$;

create or replace function public.queue_notification(p_user_id uuid, p_message text)
returns void language sql security definer set search_path = public as $$
  insert into notification_outbox (user_id, message) values (p_user_id, p_message);
$$;

create or replace function public.notify_new_proposal()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_client_id uuid; v_job_title text; v_provider_name text;
begin
  select client_id, title into v_client_id, v_job_title from jobs where id = new.job_id;
  select full_name into v_provider_name from profiles where id = new.provider_id;
  perform queue_notification(v_client_id, format(
    E'\U0001F514 "%s" e''loningizga yangi taklif keldi.\n%s', v_job_title, v_provider_name));
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
      E'✅ Tabriklaymiz! "%s" e''longa taklifingiz qabul qilindi.', v_job_title));
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
    E'⭐ %s sizni "%s" e''loniga shaxsan taklif qildi.', v_client_name, v_job_title));
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
  perform queue_notification(v_recipient, format(E'\U0001F4AC %s: %s', v_sender_name, left(new.text, 200)));
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
  select title into v_job_title from jobs where id = new.job_id;

  if new.status = 'submitted' then
    v_recipient := new.client_id;
    v_msg := format(E'\U0001F4E6 Usta "%s" ishini tugatdi deb belgiladi — tasdiqlashingiz kerak.', v_job_title);
  elsif new.status = 'completed' then
    v_recipient := new.provider_id;
    v_msg := format(E'\U0001F389 "%s" shartnomasi yakunlandi.', v_job_title);
  elsif new.status = 'disputed' then
    v_recipient := new.provider_id;
    v_msg := format(E'⚠️ Mijoz "%s" shartnomasi bo''yicha nizo ochdi. Sabab: %s', v_job_title, new.dispute_reason);
  elsif new.status = 'cancelled' then
    if new.cancelled_by = 'provider' then
      v_recipient := new.client_id;
      v_msg := format(E'⚠️ Usta "%s" ishidan voz kechdi. Sabab: %s', v_job_title, new.cancel_reason);
    elsif new.cancelled_by = 'admin' then
      v_recipient := new.provider_id;
      v_msg := format(E'⚠️ "%s" shartnomasi bo''yicha nizo admin tomonidan mijoz foydasiga hal qilindi.', v_job_title);
    end if;
  end if;

  if v_recipient is not null then perform queue_notification(v_recipient, v_msg); end if;
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

revoke execute on function
  public.queue_notification(uuid, text), public.notify_new_proposal(),
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

create or replace function public.admin_review_provider(p_user_id uuid, p_approve boolean, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is not null and not coalesce((select is_admin from profiles where id = v_uid), false) then
    raise exception 'NOT_ALLOWED';
  end if;

  update provider_profiles
     set status = case when p_approve then 'approved' else 'rejected' end,
         rejection_reason = case when p_approve then null else p_reason end,
         reviewed_at = now()
   where user_id = p_user_id;
  if not found then raise exception 'NOT_FOUND'; end if;

  perform queue_notification(p_user_id,
    case when p_approve
      then E'✅ Tabriklaymiz! Usta profilingiz tasdiqlandi — endi ishlarga taklif yubora olasiz.'
      else format(E'❌ Usta profilingiz rad etildi. Sabab: %s', coalesce(p_reason, '-'))
    end);
end;
$$;

create or replace function public.admin_resolve_dispute(p_contract_id uuid, p_winner text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_k contracts;
  v_job_title text;
begin
  if v_uid is not null and not coalesce((select is_admin from profiles where id = v_uid), false) then
    raise exception 'NOT_ALLOWED';
  end if;
  if p_winner not in ('provider', 'client') then raise exception 'INVALID_INPUT'; end if;
  select * into v_k from contracts where id = p_contract_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_k.status <> 'disputed' then raise exception 'INVALID_STATE'; end if;
  select title into v_job_title from jobs where id = v_k.job_id;

  update contracts set dispute_resolution = p_winner, resolved_at = now() where id = p_contract_id;
  if p_winner = 'provider' then
    perform _complete_contract(p_contract_id);
    perform queue_notification(v_k.client_id,
      format(E'⚖️ "%s" shartnomasi bo''yicha nizo admin tomonidan usta foydasiga hal qilindi.', v_job_title));
  else
    update contracts set status = 'cancelled', cancelled_at = now(), cancelled_by = 'admin'
     where id = p_contract_id;
    update jobs set status = 'cancelled', closed_at = now() where id = v_k.job_id;
    perform queue_notification(v_k.client_id,
      format(E'⚖️ "%s" shartnomasi bo''yicha nizo admin tomonidan siz foydangizga hal qilindi.', v_job_title));
  end if;
end;
$$;

create or replace function public.admin_get_dashboard_stats()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  perform require_admin();
  select jsonb_build_object(
    'pending_providers',   (select count(*) from provider_profiles where status = 'pending'),
    'disputed_contracts',  (select count(*) from contracts where status = 'disputed'),
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
    'created_at',       pp.created_at
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
    'job',      jsonb_build_object('id', j.id, 'title', j.title, 'category', j.category, 'district', j.district),
    'client',   jsonb_build_object('id', cp.id, 'full_name', cp.full_name, 'phone', cu.phone),
    'provider', jsonb_build_object('id', pp.id, 'full_name', pp.full_name, 'phone', pu.phone)
  ) order by k.disputed_at asc), '[]'::jsonb)
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

revoke execute on function
  public.admin_review_provider(uuid, boolean, text), public.admin_resolve_dispute(uuid, text),
  public.admin_get_dashboard_stats(), public.admin_get_pending_providers(),
  public.admin_get_disputed_contracts()
  from public, anon, authenticated;

grant execute on function
  public.admin_review_provider(uuid, boolean, text), public.admin_resolve_dispute(uuid, text),
  public.admin_get_dashboard_stats(), public.admin_get_pending_providers(),
  public.admin_get_disputed_contracts()
  to authenticated;

