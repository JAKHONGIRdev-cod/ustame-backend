-- Xarita: e'lon va ustalarning joylashuvi.
-- app.sql va catalog.sql dan keyin ishga tushiriladi (qayta ishga tushirish xavfsiz).
--
-- Maxfiylik: e'lonning aniq nuqtasi manzil bilan birga job_addresses'da turadi va faqat
-- mijoz hamda tanlangan ustaga ko'rinadi. Boshqalar xaritada ~1 km ga yaxlitlangan nuqtani ko'radi.

alter table public.job_addresses     add column if not exists lat double precision;
alter table public.job_addresses     add column if not exists lng double precision;
alter table public.jobs              add column if not exists approx_lat double precision;
alter table public.jobs              add column if not exists approx_lng double precision;
alter table public.provider_profiles add column if not exists lat double precision;
alter table public.provider_profiles add column if not exists lng double precision;

-- O'zbekiston chegarasi (taxminan) — xato kiritilgan koordinatalarni qaytaramiz
create or replace function public.check_location(p_lat double precision, p_lng double precision)
returns void language plpgsql immutable as $$
begin
  if (p_lat is null) <> (p_lng is null) then raise exception 'INVALID_LOCATION'; end if;
  if p_lat is not null and (p_lat not between 37 and 46 or p_lng not between 55 and 74) then
    raise exception 'INVALID_LOCATION';
  end if;
end;
$$;

-- ~1.1 km aniqlik
create or replace function public.approx_coord(p double precision)
returns double precision language sql immutable as $$
  select round(p::numeric, 2)::double precision
$$;

create or replace function public.set_job_location(p_job_id uuid, p_lat double precision, p_lng double precision)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := require_uid();
  v_job jobs;
begin
  perform check_location(p_lat, p_lng);
  select * into v_job from jobs where id = p_job_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_job.client_id <> v_uid then raise exception 'NOT_ALLOWED'; end if;

  update job_addresses set lat = p_lat, lng = p_lng where job_id = p_job_id;
  update jobs set approx_lat = approx_coord(p_lat), approx_lng = approx_coord(p_lng) where id = p_job_id;
end;
$$;

create or replace function public.set_provider_location(p_lat double precision, p_lng double precision)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := require_uid();
begin
  perform check_location(p_lat, p_lng);
  update provider_profiles set lat = p_lat, lng = p_lng where user_id = v_uid;
  if not found then raise exception 'NOT_FOUND'; end if;
end;
$$;

-- find_jobs: + approx_lat/approx_lng (xarita uchun). Kirmagan mehmon ham ko'radi (auth.uid() null):
-- mijoz ismi qisqartiriladi ("Aziza K."), "sizga mos" saralash yo'q
create or replace function public.find_jobs(
  p_category text default null, p_district text default null, p_search text default null,
  p_limit int default 30, p_offset int default 0
)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_q text := nullif(btrim(coalesce(p_search, '')), '');
  v_cats text[];
  v_dists text[];
begin
  -- "Sizga mos" (Upwork'dagi Best matches): ustaning kasbi va tumaniga mos e'lonlar birinchi
  select categories, districts into v_cats, v_dists from provider_profiles where user_id = v_uid;
  return coalesce((
    select jsonb_agg(row_data order by sort_key, created_at desc)
    from (
      select j.created_at,
        (case when j.category = any (coalesce(v_cats, '{}')) then 0 else 2 end)
          + (case when j.district = any (coalesce(v_dists, '{}')) then 0 else 1 end) as sort_key,
        jsonb_build_object(
        'id', j.id, 'title', j.title, 'description', left(j.description, 240),
        'category', j.category, 'district', j.district, 'budget', j.budget,
        'budget_max', (select d.budget_max from job_details d where d.job_id = j.id and d.budget_type = 'range'),
        'urgency', j.urgency, 'created_at', j.created_at, 'has_photo', j.has_photo,
        'crew_needed', j.crew_needed,
        'lat', j.approx_lat, 'lng', j.approx_lng,
        'proposals_count', (select count(*) from proposals p where p.job_id = j.id and p.status = 'submitted'),
        'has_applied', exists (select 1 from proposals p where p.job_id = j.id and p.provider_id = v_uid),
        'is_saved', exists (select 1 from saved_jobs sj where sj.user_id = v_uid and sj.job_id = j.id),
        'match', j.category = any (coalesce(v_cats, '{}')) and j.district = any (coalesce(v_dists, '{}')),
        'client', jsonb_build_object('full_name', case when v_uid is null then _public_name(c.full_name) else c.full_name end,
                                     'stats', client_stats(c.id))
      ) as row_data
      from jobs j join profiles c on c.id = j.client_id
      where j.status = 'open'
        and j.client_id is distinct from v_uid
        and not _blocked(v_uid, j.client_id)
        and (p_category is null or j.category = p_category)
        and (p_district is null or j.district = p_district)
        and (v_q is null or j.title ilike '%' || v_q || '%' or j.description ilike '%' || v_q || '%')
      order by 2, j.created_at desc
      limit least(greatest(coalesce(p_limit, 30), 1), 100)
      offset greatest(coalesce(p_offset, 0), 0)
    ) s
  ), '[]'::jsonb);
end;
$$;

-- get_job: + location (tomonlarga aniq, boshqalarga yaxlitlangan). Kirmagan mehmon faqat ochiq e'lonni ko'radi,
-- manzil va shartnomasiz, mijoz ismi qisqartirilgan
create or replace function public.get_job(p_job_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_job jobs;
  v_is_client boolean;
  v_contract contracts;
  v_is_party boolean;
  v_my_proposal jsonb;
  v_addr job_addresses;
begin
  select * into v_job from jobs where id = p_job_id;
  if not found then raise exception 'NOT_FOUND'; end if;

  -- coalesce: mehmonda (v_uid null) taqqoslash null beradi — "mijoz emas" deb hisoblanishi shart
  v_is_client := coalesce(v_job.client_id = v_uid, false);

  select * into v_contract from contracts
   where job_id = p_job_id and status <> 'cancelled'
   order by created_at desc limit 1;
  v_is_party := v_is_client or coalesce(v_contract.id is not null and v_contract.provider_id = v_uid, false);

  select jsonb_build_object('id', p.id, 'price', p.price, 'message', p.message,
                            'status', p.status, 'created_at', p.created_at,
                            'unread', (select count(*) from messages m
                                        where m.proposal_id = p.id and m.sender_id <> v_uid and m.read_at is null))
    into v_my_proposal
    from proposals p where p.job_id = p_job_id and p.provider_id = v_uid;

  if not v_is_client and v_job.status <> 'open' and v_my_proposal is null then
    raise exception 'NOT_FOUND';
  end if;

  select * into v_addr from job_addresses where job_id = p_job_id;

  return jsonb_build_object(
    'id', v_job.id, 'title', v_job.title, 'description', v_job.description,
    'category', v_job.category, 'district', v_job.district, 'budget', v_job.budget,
    'urgency', v_job.urgency, 'status', v_job.status, 'created_at', v_job.created_at,
    'has_photo', v_job.has_photo,
    'photos', _job_photos(v_job.id),
    'crew_needed', v_job.crew_needed,
    'is_mine', v_is_client,
    'address', case when v_is_party then v_addr.address end,
    'location', case
      when v_is_party and v_addr.lat is not null
        then jsonb_build_object('lat', v_addr.lat, 'lng', v_addr.lng, 'exact', true)
      when v_job.approx_lat is not null
        then jsonb_build_object('lat', v_job.approx_lat, 'lng', v_job.approx_lng, 'exact', false)
    end,
    'proposals_count', (select count(*) from proposals p where p.job_id = p_job_id and p.status = 'submitted'),
    -- Buyurtma holati (Yangi ... Bajarilgan) va 3 bosqichli formadagi tafsilotlar (app.sql)
    'order_status', _order_status(v_job.id),
    'details', _job_details_json(v_job.id),
    'client', (select jsonb_build_object('id', c.id,
                                         'full_name', case when v_uid is null then _public_name(c.full_name) else c.full_name end,
                                         'member_since', c.created_at, 'stats', client_stats(c.id))
               from profiles c where c.id = v_job.client_id),
    'my_proposal', v_my_proposal,
    'contract', case when v_is_party and v_contract.id is not null
                     then jsonb_build_object('id', v_contract.id, 'status', v_contract.status) end
  );
end;
$$;

-- search_providers: + lat/lng (yaxlitlangan). Kirmagan mehmon ham qidira oladi (usta profillari ochiq)
create or replace function public.search_providers(
  p_category text default null,
  p_district text default null,
  p_query    text default null,
  p_limit    int  default 30,
  p_offset   int  default 0
)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_uid   uuid := auth.uid();
  v_q     text := nullif(btrim(coalesce(p_query, '')), '');
  v_like  text;
  v_limit int  := least(greatest(coalesce(p_limit, 30), 1), 50);
begin
  if v_q is not null then
    v_like := '%' || replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_') || '%';
  end if;

  return coalesce((
    select jsonb_agg(x.item order by x.top_rated desc, x.avg_rating desc nulls last,
                                     x.completed desc, x.created_at desc)
    from (
      select
        jsonb_build_object(
          'id',                p.id,
          'full_name',         p.full_name,
          'avatar_updated_at', p.avatar_updated_at,
          'headline',          pp.headline,
          'categories',        pp.categories,
          'districts',         pp.districts,
          'experience_years',  pp.experience_years,
          'lat',               approx_coord(pp.lat),
          'lng',               approx_coord(pp.lng),
          'is_favorite',       exists (select 1 from favorites f where f.client_id = v_uid and f.provider_id = p.id),
          'stats',             s.stats
        ) as item,
        (s.stats ->> 'top_rated')::boolean       as top_rated,
        (s.stats ->> 'avg_rating')::numeric      as avg_rating,
        (s.stats ->> 'completed_jobs')::int      as completed,
        pp.created_at
      from provider_profiles pp
      join profiles p on p.id = pp.user_id
      cross join lateral (select provider_stats(pp.user_id) as stats) s
      where pp.status = 'approved'
        and pp.user_id is distinct from v_uid
        and not _blocked(v_uid, pp.user_id)
        and (p_category is null or p_category = any (pp.categories))
        and (p_district is null or p_district = any (pp.districts))
        and (v_like is null
             or p.full_name ilike v_like
             or pp.headline ilike v_like
             or pp.bio ilike v_like)
      order by (s.stats ->> 'top_rated')::boolean desc,
               (s.stats ->> 'avg_rating')::numeric desc nulls last,
               (s.stats ->> 'completed_jobs')::int desc,
               pp.created_at desc
      limit v_limit offset greatest(coalesce(p_offset, 0), 0)
    ) x
  ), '[]'::jsonb);
end;
$$;

revoke execute on function
  public.check_location(double precision, double precision), public.approx_coord(double precision)
  from public, anon, authenticated;

revoke execute on function
  public.set_job_location(uuid, double precision, double precision),
  public.set_provider_location(double precision, double precision)
  from public, anon;

grant execute on function
  public.set_job_location(uuid, double precision, double precision),
  public.set_provider_location(double precision, double precision)
  to authenticated;

-- Mehmon rejimi (saytda kirmasdan ko'rish): e'lonlar lentasi, e'lon sahifasi va ustalar qidiruvi.
-- Taklif yuborish, e'lon joylash va boshqa amallar baribir kirishni talab qiladi.
grant execute on function
  public.find_jobs(text, text, text, int, int),
  public.get_job(uuid),
  public.search_providers(text, text, text, int, int)
  to anon;
