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

-- 2026-11-17: qidiruv so'zlar bo'yicha — har bir so'z (tartibsiz) ism, tavsif, kasb yoki tumanda bo'lsa topiladi.
-- Kichik harf, apostroflarsiz (o', o‘, oʻ bir xil): "santexnik chilonzor", "Mirzo Ulug'bek elektrik".
create or replace function public._norm_search(p text)
returns text language sql immutable as $$
  select translate(lower(coalesce(p, '')), '''‘’ʻʼ`', '')
$$;

create or replace function public._words_match(p_q text, p_hay text)
returns boolean language sql immutable as $$
  select not exists (
    select 1 from regexp_split_to_table(_norm_search(btrim(p_q)), '\s+') w
    where w <> '' and position(w in _norm_search(p_hay)) = 0
  )
$$;

-- Qidiruv sinonimlari: bazadagi kasb va Toshkent tumanlari o'zbekcha lotinda saqlanadi — ruscha, inglizcha va o'zbek
-- kirillchasida yozgan ham topsin ("сантехник Чиланзар", "plumber Chilanzar", "электрик Юнусобод").
create or replace function public._search_synonyms(p_values text[])
returns text language sql immutable as $$
  select coalesce(string_agg(s.words, ' '), '') from (values
    ('Santexnik',           'сантехник сантехника plumber plumbing'),
    ('Elektrik',            'электрик электрика electrician electric'),
    ('Mebel ustasi',        'мебел устаси мебельщик мебель furniture'),
    ('Konditsioner ustasi', 'кондиционер устаси кондиционер aircon conditioner'),
    ('Quruvchi/ta''mirchi', 'қурувчи таъмирчи строитель ремонт builder renovation remont'),
    ('Payvandchi',          'пайвандчи сварщик сварка welder welding'),
    ('Muzlatgich ustasi',   'музлатгич устаси холодильник fridge refrigerator'),
    ('Bo''yoqchi',          'бўёқчи маляр покраска painter malyar'),
    ('Duradgor',            'дурадгор плотник столяр carpenter'),
    ('Boshqa',              'бошқа другое other'),
    ('Bektemir',            'бектемир'),
    ('Chilonzor',           'чилонзор чиланзар chilanzar'),
    ('Mirobod',             'миробод мирабад mirabad'),
    ('Mirzo Ulug''bek',     'мирзо улуғбек мирзо-улугбек улугбек mirzo ulugbek'),
    ('Olmazor',             'олмазор алмазар almazar'),
    ('Sergeli',             'сергели'),
    ('Shayxontohur',        'шайхонтоҳур шайхантахур shaykhantakhur'),
    ('Uchtepa',             'учтепа'),
    ('Yakkasaroy',          'яккасарой яккасарай yakkasaray'),
    ('Yashnobod',           'яшнобод яшнабад yashnabad'),
    ('Yunusobod',           'юнусобод юнусабад yunusabad'),
    ('Yangihayot',          'янгиҳаёт янгихаёт yangihayot')
  ) s(val, words) where s.val = any (p_values)
$$;

revoke execute on function public._norm_search(text), public._words_match(text, text),
  public._search_synonyms(text[]) from public, anon, authenticated;

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
        and (v_q is null or _words_match(v_q, concat_ws(' ', j.title, j.description, j.category, j.district,
                                                  _search_synonyms(array[j.category, j.district]))))
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
    'renewed_at', v_job.renewed_at, 'stale_notified_at', v_job.stale_notified_at,
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

-- search_providers: + lat/lng (yaxlitlangan). Kirmagan mehmon ham qidira oladi (usta profillari ochiq).
-- 2026-11-13: mijoz joylashuvi (p_lat/p_lng) berilsa — yaqinlik va sharhlar bo'yicha tartib:
--   1) masofa oralig'i: 0-2, 2-5, 5-10, 10-25, 25-50 km, 50 km dan uzoq; joylashuvi belgilanmagan ustalar — eng oxirida;
--   2) bir oraliq ichida: top_rated, sharhlar soni bilan tekislangan reyting (bayes: 2 ta 4.0 "virtual" baho), masofa.
-- Masofa yaxlitlangan koordinatadan (approx_coord, ~1 km) hisoblanadi — ustaning aniq joyi chiqib qolmasin.
-- Joylashuv berilmasa — avval ish joyini belgilagan ustalar, keyin eski tartib (top_rated, reyting, bajarilgan ishlar).
-- 2026-11-23: joylashuvi bor ustalar har doim joylashuvsizlardan yuqorida (mijoz ruxsat bermagan bo'lsa ham).
drop function if exists public.search_providers(text, text, text, int, int);
create or replace function public.search_providers(
  p_category text default null,
  p_district text default null,
  p_query    text default null,
  p_limit    int  default 30,
  p_offset   int  default 0,
  p_lat      double precision default null,
  p_lng      double precision default null
)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_uid   uuid := auth.uid();
  v_q     text := nullif(btrim(coalesce(p_query, '')), '');
  v_like  text;
  v_limit int  := least(greatest(coalesce(p_limit, 30), 1), 50);
  -- Noto'g'ri yoki chala koordinata — joylashuvsiz deb hisoblanadi (xato bermaymiz: bu faqat tartib)
  v_lat   double precision := case when p_lat between 37 and 46 and p_lng between 55 and 74 then p_lat end;
  v_lng   double precision := case when p_lat between 37 and 46 and p_lng between 55 and 74 then p_lng end;
begin
  if v_q is not null then
    v_like := '%' || replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_') || '%';
  end if;

  return coalesce((
    select jsonb_agg(x.item || jsonb_build_object('distance_km', round(x.distance_km::numeric, 1))
                     order by x.ord)
    from (
      select y.*,
             row_number() over (
               order by case when y.distance_km is null then 6
                             when y.distance_km < 2  then 0
                             when y.distance_km < 5  then 1
                             when y.distance_km < 10 then 2
                             when y.distance_km < 25 then 3
                             when y.distance_km < 50 then 4
                             else 5 end,
                        y.has_location desc,
                        y.top_rated desc, y.completeness desc, y.score desc, y.distance_km asc nulls last,
                        y.completed desc, y.created_at desc) as ord
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
          case when v_lat is not null and pp.lat is not null and pp.lng is not null then
            111.32 * sqrt(power(approx_coord(pp.lat) - v_lat, 2)
                          + power((approx_coord(pp.lng) - v_lng) * cos(radians(v_lat)), 2))
          end as distance_km,
          (pp.lat is not null and pp.lng is not null) as has_location,
          coalesce((s.stats ->> 'top_rated')::boolean, false) as top_rated,
          (coalesce((s.stats ->> 'avg_rating')::numeric, 0) * coalesce((s.stats ->> 'reviews_count')::int, 0) + 4.0 * 2)
            / (coalesce((s.stats ->> 'reviews_count')::int, 0) + 2) as score,
          coalesce((s.stats ->> 'completed_jobs')::int, 0) as completed,
          -- 2026-11-17: profil to'liqligi (rasm, ish joyi, ish rasmlari, tavsif) — to'liqlari yuqorida
          4 - cardinality(_provider_missing(pp.user_id)) as completeness,
          pp.created_at
        from provider_profiles pp
        join profiles p on p.id = pp.user_id
        cross join lateral (select provider_stats(pp.user_id) as stats) s
        where pp.status = 'approved'
          and pp.user_id is distinct from v_uid
          and not _blocked(v_uid, pp.user_id)
          and (p_category is null or p_category = any (pp.categories))
          and (p_district is null or p_district = any (pp.districts))
          and (v_q is null
               or _words_match(v_q, concat_ws(' ', p.full_name, pp.headline, pp.bio,
                                              array_to_string(pp.categories, ' '), array_to_string(pp.districts, ' '),
                                              _search_synonyms(pp.categories || pp.districts))))
      ) y
      order by ord
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
  public.search_providers(text, text, text, int, int, double precision, double precision)
  to anon;
grant execute on function
  public.search_providers(text, text, text, int, int, double precision, double precision)
  to authenticated;
