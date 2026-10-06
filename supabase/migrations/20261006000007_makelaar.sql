-- Makelaar van het pand: naam uit ERAforce (Marketpulse) en de website van dat kantoor,
-- geleerd uit Immoweb-controles van andere panden van hetzelfde kantoor.

alter table public.source_records add column if not exists agency_name text;  -- concurrerend kantoor volgens Marketpulse

create table public.agency_sites (
  team_id bigint not null references public.teams(id) on delete cascade,
  name_key text not null,
  name text not null,
  website text not null,
  source text not null check (source in ('immoweb', 'manual')),
  updated_at timestamptz not null default now(),
  primary key (team_id, name_key)
);
alter table public.agency_sites enable row level security;
revoke all on public.agency_sites from anon, authenticated;

create function app.agency_name_of(p_property bigint) returns text
language sql stable security definer set search_path = public, app, pg_temp as $$
  select agency_name from public.source_records where property_id = p_property and not deleted and agency_name is not null
  order by market_date desc nulls last, source_modified_at desc nulls last limit 1
$$;

create function app.agency_site(p_team bigint, p_name text) returns text
language sql stable security definer set search_path = public, app, pg_temp as $$
  select website from public.agency_sites where team_id = p_team and name_key = app.norm_text(p_name)
$$;

drop function worker.import_records(bigint, text, jsonb);
create function worker.import_records(p_team bigint, p_source text, p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  l_n int := 0;
  l_rec record;
begin
  if not exists (select 1 from public.teams where id = p_team) then perform app.fail('Team niet gevonden.'); end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) > 2000 then perform app.fail('Ongeldige lijst.'); end if;
  for l_rec in
    insert into public.source_records as s (team_id, source, external_id, owner_key, owner_email, owner_label, owner_is_queue,
      lifecycle, status_label, end_reason, market_date, created_in_source, ended_on, source_modified_at,
      street, number, box, postcode, city, lat, lon, object_type, price_current, price_initial, agency_label, agency_name,
      immoweb_url, immoweb_id, realo_url, realo_property_id, realo_listing_id, raw, deleted, imported_at, updated_at)
    select p_team, p_source, x.external_id, x.owner_key, lower(x.owner_email), x.owner_label, coalesce(x.owner_is_queue, false),
      x.lifecycle, x.status_label, x.end_reason, x.market_date, x.created_in_source, x.ended_on, x.source_modified_at,
      nullif(btrim(x.street), ''), nullif(btrim(x.number), ''), nullif(btrim(x.box), ''), nullif(btrim(x.postcode), ''),
      nullif(btrim(x.city), ''), x.lat, x.lon, x.object_type, x.price_current, x.price_initial, x.agency_label, nullif(btrim(x.agency_name), ''),
      x.immoweb_url, x.immoweb_id, x.realo_url, x.realo_property_id, x.realo_listing_id, coalesce(x.raw, '{}'::jsonb),
      false, now(), now()
    from jsonb_to_recordset(p_rows) as x(external_id text, owner_key text, owner_email text, owner_label text, owner_is_queue boolean,
      lifecycle text, status_label text, end_reason text, market_date date, created_in_source timestamptz, ended_on date,
      source_modified_at timestamptz, street text, number text, box text, postcode text, city text, lat double precision,
      lon double precision, object_type text, price_current numeric, price_initial numeric, agency_label text, agency_name text, immoweb_url text,
      immoweb_id text, realo_url text, realo_property_id text, realo_listing_id text, raw jsonb)
    where x.external_id is not null
    on conflict (team_id, source, external_id) do update set
      owner_key = excluded.owner_key, owner_email = excluded.owner_email, owner_label = excluded.owner_label,
      owner_is_queue = excluded.owner_is_queue, lifecycle = excluded.lifecycle, status_label = excluded.status_label,
      end_reason = excluded.end_reason, market_date = excluded.market_date, created_in_source = excluded.created_in_source,
      ended_on = excluded.ended_on, source_modified_at = excluded.source_modified_at, street = excluded.street,
      number = excluded.number, box = excluded.box, postcode = excluded.postcode, city = excluded.city, lat = excluded.lat,
      lon = excluded.lon, object_type = excluded.object_type, price_current = excluded.price_current,
      price_initial = excluded.price_initial, agency_label = excluded.agency_label, agency_name = excluded.agency_name, immoweb_url = excluded.immoweb_url,
      immoweb_id = excluded.immoweb_id, realo_url = excluded.realo_url, realo_property_id = excluded.realo_property_id,
      realo_listing_id = excluded.realo_listing_id, raw = excluded.raw, deleted = false, imported_at = now(),
      updated_at = now(),
      -- Opnieuw koppelen als het adres of het Realo-pand veranderde (handmatige beslissingen blijven staan).
      property_id = case when s.match_method = 'handmatig' then s.property_id
                         when app.address_key_of(s.street, s.number, s.box, s.postcode)
                              is distinct from app.address_key_of(excluded.street, excluded.number, excluded.box, excluded.postcode)
                           or s.realo_property_id is distinct from excluded.realo_property_id then null
                         else s.property_id end
    returning s.id, s.property_id
  loop
    l_n := l_n + 1;
    if l_rec.property_id is null then perform app.match_record(l_rec.id); end if;
  end loop;
  return jsonb_build_object('records', l_n);
end $$;

drop function worker.claim_checks(bigint, text, int, text);
create function worker.claim_checks(p_team bigint, p_kind text, p_limit int, p_worker text) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  l_run bigint;
  l_items jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended('scout-checks:' || p_team, 0));
  if exists (select 1 from public.check_runs where team_id = p_team and finished_at is null and lease_until > now()) then
    return jsonb_build_object('run_id', null, 'items', '[]'::jsonb);
  end if;
  insert into public.check_runs (team_id, kind, worker, lease_until)
  values (p_team, p_kind, p_worker, now() + interval '45 minutes') returning id into l_run;

  with visible as (
    select distinct r.property_id as pid
    from public.source_records r
    join public.owner_links o on o.team_id = r.team_id and o.source = r.source and o.owner_key = r.owner_key and o.profile_id is not null
    where r.team_id = p_team and not r.deleted and r.lifecycle in ('open', 'ended_usable') and r.property_id is not null
  ), cand as (
    select v.pid,
      exists (select 1 from public.check_requests q where q.property_id = v.pid and q.done_at is null) as requested,
      exists (select 1 from public.visit_selection s where s.property_id = v.pid) as selected,
      (select max(checked_at) from public.listing_checks c where c.property_id = v.pid and c.site = 'immoweb') as last_iw,
      (select c.status from public.listing_checks c where c.property_id = v.pid and c.site = 'immoweb' order by c.checked_at desc limit 1) as last_status,
      (app.sale_periods(v.pid)->>'current_start')::date as cur
    from visible v
  )
  select coalesce(jsonb_agg(x), '[]'::jsonb) into l_items from (
    select jsonb_build_object(
      'property_id', c.pid, 'requested', c.requested,
      'immoweb_url', (select immoweb_url from public.source_records r where r.property_id = c.pid and not r.deleted
                      and r.immoweb_url is not null order by r.market_date desc nulls last limit 1),
      'agency_label', (select agency_label from public.source_records r where r.property_id = c.pid and not r.deleted
                       order by r.market_date desc nulls last limit 1),
      'street', p.street, 'number', p.number, 'box', p.box, 'postcode', p.postcode, 'city', p.city,
      'lat', p.lat, 'geo_quality', p.geo_quality,
      'agency_name', app.agency_name_of(c.pid),
      'agency_website', coalesce((select c2.details->>'agency_website' from public.listing_checks c2 where c2.property_id = c.pid
                         and c2.details ? 'agency_website' order by c2.checked_at desc limit 1),
                         app.agency_site(p_team, app.agency_name_of(c.pid)))) as x
    from cand c join public.properties p on p.id = c.pid
    where c.requested
       or (p_kind = 'daily' and (c.cur is null or c.cur <= app.today(app.team(p_team)) - 30)
           and (c.last_iw is null
                or (c.last_status in ('sold', 'not_found') and c.last_iw < now() - interval '7 days')
                or (coalesce(c.last_status, '') not in ('sold', 'not_found') and c.last_iw < now() - interval '20 hours')))
    order by c.requested desc, c.selected desc, c.last_iw nulls first
    limit greatest(1, least(p_limit, 2000))) s;
  if jsonb_array_length(l_items) = 0 then
    delete from public.check_runs where id = l_run;  -- niets te doen: geen lege ronde bewaren
    return jsonb_build_object('run_id', null, 'items', '[]'::jsonb, 'nothing_to_do', true);
  end if;
  return jsonb_build_object('run_id', l_run, 'items', l_items);
end $$;

drop function worker.save_check(bigint, bigint, text, text, text, text, text, text, int, jsonb);
create function worker.save_check(p_run bigint, p_property bigint, p_site text, p_url text, p_status text, p_reason text,
                                  p_evidence text, p_error text, p_http int, p_details jsonb) returns void
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare l_team bigint;
begin
  select team_id into l_team from public.properties where id = p_property;
  if l_team is null then return; end if;
  insert into public.listing_checks (team_id, property_id, site, url, status, reason, evidence, error, http_status, details, run_id)
  values (l_team, p_property, p_site, left(p_url, 1000), p_status, left(p_reason, 300), left(p_evidence, 500), left(p_error, 300),
          p_http, coalesce(p_details, '{}'::jsonb), p_run);
  -- Website van het kantoor onthouden (Immoweb toont die bij de advertentie), voor panden van hetzelfde kantoor.
  if p_site = 'immoweb' and p_details->>'agency_type' = 'AGENCY' and coalesce(p_details->>'agency_website', '') ~* '^https?://' then
    insert into public.agency_sites as a (team_id, name_key, name, website, source)
    select distinct l_team, app.norm_text(r.agency_name), r.agency_name, p_details->>'agency_website', 'immoweb'
    from public.source_records r where r.property_id = p_property and not r.deleted and r.agency_name is not null
    on conflict (team_id, name_key) do update set website = excluded.website, updated_at = now()
      where a.source <> 'manual';
  end if;
  update public.check_runs set checked = checked + 1, failed = failed + (p_status = 'failed')::int,
    lease_until = now() + interval '45 minutes' where id = p_run;
end $$;

create or replace function app.property_card(p_property bigint, p_user public.profiles, p_today date) returns jsonb
language plpgsql stable as $$
declare
  l_p public.properties;
  l_per jsonb := app.sale_periods(p_property);
  l_dec jsonb := app.property_decision(p_property);
  l_latest public.source_records;
  l_cur date := (l_per->>'current_start')::date;
  l_first date := (l_per->>'first_start')::date;
begin
  select * into l_p from public.properties where id = p_property;
  select * into l_latest from public.source_records where property_id = p_property and not deleted
  order by market_date desc nulls last, source_modified_at desc nulls last limit 1;
  return jsonb_build_object(
    'id', l_p.id,
    'address', concat_ws(' ', l_p.street, l_p.number) || case when coalesce(l_p.box, '') <> '' then ' bus ' || l_p.box else '' end,
    'postcode', l_p.postcode, 'city', l_p.city, 'street', l_p.street, 'number', l_p.number, 'box', l_p.box,
    'lat', l_p.lat, 'lon', l_p.lon, 'geo_quality', l_p.geo_quality, 'geo_source', l_p.geo_source,
    'object_type', coalesce(l_latest.object_type, l_p.object_type),
    'price', l_latest.price_current, 'agency', l_latest.agency_label, 'agency_name', app.agency_name_of(p_property),
    'current_start', l_cur, 'first_start', l_first,
    'days_current', case when l_cur is not null then p_today - l_cur end,
    'days_first', case when l_first is not null then p_today - l_first end,
    'relisted', l_per->'relisted', 'relist_certain', l_per->'relist_certain', 'periods', l_per->'periods',
    'records_without_date', l_per->'records_without_date',
    'records', (select count(*) from public.source_records where property_id = p_property and not deleted),
    'record_ids', (select jsonb_agg(external_id order by market_date nulls last) from public.source_records
                   where property_id = p_property and not deleted),
    'immoweb_url', (select immoweb_url from public.source_records where property_id = p_property and not deleted
                    and immoweb_url is not null order by market_date desc nulls last limit 1),
    'realo_url', (select realo_url from public.source_records where property_id = p_property and not deleted
                  and realo_url is not null order by market_date desc nulls last limit 1),
    'agency_url', coalesce(l_dec->'agency'->>'url', l_dec->'agency'->'details'->>'agency_website',
                          app.agency_site(l_p.team_id, app.agency_name_of(p_property))),
    'shared_with', (select coalesce(jsonb_agg(distinct coalesce(pr.name, r.owner_label)), '[]'::jsonb)
                    from public.source_records r
                    left join public.owner_links o on o.team_id = r.team_id and o.source = r.source and o.owner_key = r.owner_key
                    left join public.profiles pr on pr.id = o.profile_id
                    where r.property_id = p_property and not r.deleted and r.lifecycle in ('open', 'ended_usable')
                      and coalesce(o.profile_id::text, '') <> p_user.id::text),
    'open_reviews', (select count(*) from public.match_reviews m where (m.property_id = p_property or m.other_property_id = p_property)
                     and m.status = 'open'),
    'decision', l_dec->>'decision', 'decision_reason', l_dec->>'reason', 'conflict', l_dec->'conflict',
    'immoweb', l_dec->'immoweb', 'agency_check', l_dec->'agency', 'manual', l_dec->'manual',
    'selected', exists (select 1 from public.visit_selection s where s.user_id = p_user.id and s.property_id = p_property),
    'request_pending', exists (select 1 from public.check_requests q where q.property_id = p_property and q.done_at is null));
end $$;

-- Beheer: website van een kantoor zelf instellen of corrigeren.
create function public.admin_agency_sites() returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare l_me public.profiles := app.admin();
begin
  return jsonb_build_object('agencies', coalesce((
    select jsonb_agg(jsonb_build_object('name', n.name, 'properties', n.props, 'website', a.website, 'source', a.source)
                     order by a.website is not null, n.props desc, n.name)
    from (select min(r.agency_name) as name, app.norm_text(r.agency_name) as key, count(distinct r.property_id) as props
          from public.source_records r where r.team_id = l_me.team_id and not r.deleted and r.agency_name is not null
            and r.lifecycle in ('open', 'ended_usable')
          group by 2) n
    left join public.agency_sites a on a.team_id = l_me.team_id and a.name_key = n.key), '[]'::jsonb));
end $$;

create function public.admin_set_agency_site(p_name text, p_website text) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare l_me public.profiles := app.admin();
begin
  if coalesce(btrim(p_name), '') = '' then perform app.fail('Naam ontbreekt.'); end if;
  if coalesce(btrim(p_website), '') = '' then
    delete from public.agency_sites where team_id = l_me.team_id and name_key = app.norm_text(p_name);
    return jsonb_build_object('ok', true);
  end if;
  if p_website !~* '^https?://[^\s/]+\.[^\s]+$' or length(p_website) > 300 then perform app.fail('Geef een volledig webadres (https://…).'); end if;
  insert into public.agency_sites (team_id, name_key, name, website, source)
  values (l_me.team_id, app.norm_text(p_name), btrim(p_name), btrim(p_website), 'manual')
  on conflict (team_id, name_key) do update set website = excluded.website, name = excluded.name, source = 'manual', updated_at = now();
  return jsonb_build_object('ok', true);
end $$;

revoke all on function app.agency_name_of(bigint), app.agency_site(bigint, text) from public, anon, authenticated;
revoke all on function public.admin_agency_sites(), public.admin_set_agency_site(text, text) from public, anon;
grant execute on function public.admin_agency_sites(), public.admin_set_agency_site(text, text) to authenticated;
revoke all on function worker.import_records(bigint, text, jsonb), worker.claim_checks(bigint, text, int, text),
  worker.save_check(bigint, bigint, text, text, text, text, text, text, int, jsonb) from public, anon, authenticated;
grant execute on function worker.import_records(bigint, text, jsonb), worker.claim_checks(bigint, text, int, text),
  worker.save_check(bigint, bigint, text, text, text, text, text, text, int, jsonb) to scout_import;
