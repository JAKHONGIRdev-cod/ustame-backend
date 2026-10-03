-- Ustalar katalogi: mijoz tasdiqlangan ustalarni kasb, tuman va matn bo'yicha qidiradi.
-- app.sql dan keyin ishga tushiriladi (qayta ishga tushirish xavfsiz).

create or replace function public.search_providers(
  p_category text default null,
  p_district text default null,
  p_query    text default null,
  p_limit    int  default 30,
  p_offset   int  default 0
)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_uid   uuid := require_uid();
  v_q     text := nullif(btrim(coalesce(p_query, '')), '');
  v_like  text;
  v_limit int  := least(greatest(coalesce(p_limit, 30), 1), 50);
begin
  if v_q is not null then
    -- foydalanuvchi yozgan % va _ oddiy belgi sifatida qidirilsin
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
        and pp.user_id <> v_uid
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

revoke execute on function public.search_providers(text, text, text, int, int) from public, anon;
grant execute on function public.search_providers(text, text, text, int, int) to authenticated;
