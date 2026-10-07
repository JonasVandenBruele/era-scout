-- 'In opvolging': een pand waarvoor al een afspraak was in ERAforce (op de Marketpulse-prospect zelf of op een
-- prospect op hetzelfde adres/gebouw), of waarop ERA een opdracht tekende. Zulke panden horen niet meer in de aanbellijst.

alter table public.source_records add column if not exists last_appointment date, add column if not exists appointment_type text;
alter table public.crm_contacts add column if not exists last_appointment date, add column if not exists appointment_type text;

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
      street, number, box, postcode, city, lat, lon, object_type, price_current, price_initial, agency_label, agency_name, last_appointment, appointment_type,
      immoweb_url, immoweb_id, realo_url, realo_property_id, realo_listing_id, raw, deleted, imported_at, updated_at)
    select p_team, p_source, x.external_id, x.owner_key, lower(x.owner_email), x.owner_label, coalesce(x.owner_is_queue, false),
      x.lifecycle, x.status_label, x.end_reason, x.market_date, x.created_in_source, x.ended_on, x.source_modified_at,
      nullif(btrim(x.street), ''), nullif(btrim(x.number), ''), nullif(btrim(x.box), ''), nullif(btrim(x.postcode), ''),
      nullif(btrim(x.city), ''), x.lat, x.lon, x.object_type, x.price_current, x.price_initial, x.agency_label, nullif(btrim(x.agency_name), ''), x.last_appointment, x.appointment_type,
      x.immoweb_url, x.immoweb_id, x.realo_url, x.realo_property_id, x.realo_listing_id, coalesce(x.raw, '{}'::jsonb),
      false, now(), now()
    from jsonb_to_recordset(p_rows) as x(external_id text, owner_key text, owner_email text, owner_label text, owner_is_queue boolean,
      lifecycle text, status_label text, end_reason text, market_date date, created_in_source timestamptz, ended_on date,
      source_modified_at timestamptz, street text, number text, box text, postcode text, city text, lat double precision,
      lon double precision, object_type text, price_current numeric, price_initial numeric, agency_label text, agency_name text, last_appointment date, appointment_type text, immoweb_url text,
      immoweb_id text, realo_url text, realo_property_id text, realo_listing_id text, raw jsonb)
    where x.external_id is not null
    on conflict (team_id, source, external_id) do update set
      owner_key = excluded.owner_key, owner_email = excluded.owner_email, owner_label = excluded.owner_label,
      owner_is_queue = excluded.owner_is_queue, lifecycle = excluded.lifecycle, status_label = excluded.status_label,
      end_reason = excluded.end_reason, market_date = excluded.market_date, created_in_source = excluded.created_in_source,
      ended_on = excluded.ended_on, source_modified_at = excluded.source_modified_at, street = excluded.street,
      number = excluded.number, box = excluded.box, postcode = excluded.postcode, city = excluded.city, lat = excluded.lat,
      lon = excluded.lon, object_type = excluded.object_type, price_current = excluded.price_current,
      price_initial = excluded.price_initial, agency_label = excluded.agency_label, agency_name = excluded.agency_name, last_appointment = excluded.last_appointment, appointment_type = excluded.appointment_type, immoweb_url = excluded.immoweb_url,
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

drop function worker.import_contacts(bigint, jsonb);
create function worker.import_contacts(p_team bigint, p_rows jsonb) returns int
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare l_n int;
begin
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) > 5000 then perform app.fail('Ongeldige lijst.'); end if;
  insert into public.crm_contacts as c (team_id, source, external_id, address_type, kind, name, phone, mobile, do_not_call, status,
    lead_source, owner_label, created_in_source, last_appointment, appointment_type, street, number, box, postcode, city, address_key, building_key, loose_key,
    deleted, imported_at)
  select p_team, 'eraforce_lead', x.external_id, x.address_type, x.kind, left(x.name, 200), left(x.phone, 40), left(x.mobile, 40),
    coalesce(x.do_not_call, false), x.status, x.lead_source, x.owner_label, x.created_in_source, x.last_appointment, x.appointment_type,
    x.street, x.number, x.box, x.postcode, x.city,
    app.address_key_of(x.street, x.number, x.box, x.postcode), app.building_key_of(x.street, x.number, x.postcode),
    app.loose_key_of(x.street, x.number, x.postcode), false, now()
  from jsonb_to_recordset(p_rows) as x(external_id text, address_type text, kind text, name text, phone text, mobile text,
       do_not_call boolean, status text, lead_source text, owner_label text, created_in_source timestamptz, last_appointment date, appointment_type text,
       street text, number text, box text, postcode text, city text)
  where x.external_id is not null and x.address_type in ('main', 'other') and x.street is not null and x.number is not null
  on conflict (team_id, source, external_id, address_type) do update set kind = excluded.kind, name = excluded.name,
    phone = excluded.phone, mobile = excluded.mobile, do_not_call = excluded.do_not_call, status = excluded.status,
    lead_source = excluded.lead_source, owner_label = excluded.owner_label, created_in_source = excluded.created_in_source,
    last_appointment = excluded.last_appointment, appointment_type = excluded.appointment_type,
    street = excluded.street, number = excluded.number, box = excluded.box, postcode = excluded.postcode, city = excluded.city,
    address_key = excluded.address_key, building_key = excluded.building_key, loose_key = excluded.loose_key,
    deleted = false, imported_at = now();
  get diagnostics l_n = row_count;
  return l_n;
end $$;

create function app.property_follow_up(p_property bigint) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  with p as (
    select team_id, app.address_key_of(street, number, box, postcode) as ak, app.building_key_of(street, number, postcode) as bk
    from public.properties where id = p_property
  ), hits as (
    select 'afspraak' as kind, r.last_appointment as day, r.appointment_type as detail, r.owner_label as who
    from public.source_records r where r.property_id = p_property and not r.deleted and r.last_appointment is not null
    union all
    select 'afspraak', c.last_appointment, c.appointment_type, coalesce(c.owner_label, c.lead_source)
    from public.crm_contacts c, p
    where c.team_id = p.team_id and not c.deleted and c.building_key = p.bk and c.last_appointment is not null
      and c.kind in ('Verkoper', 'Verhuurder')
    union all
    select 'opdracht', m.signed_on, m.kind, m.owner_label
    from public.mandates m, p
    where m.team_id = p.team_id and m.building_key = p.bk and m.signed_on >= current_date - 730
  )
  select jsonb_build_object('kind', kind, 'date', day, 'detail', detail, 'who', who)
  from hits order by day desc nulls last limit 1
$$;

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
    'contacts', app.property_contacts(p_property),
    'follow_up', app.property_follow_up(p_property),
    'selected', exists (select 1 from public.visit_selection s where s.user_id = p_user.id and s.property_id = p_property),
    'request_pending', exists (select 1 from public.check_requests q where q.property_id = p_property and q.done_at is null));
end $$;

revoke all on function app.property_follow_up(bigint) from public, anon, authenticated;
revoke all on function worker.import_records(bigint, text, jsonb), worker.import_contacts(bigint, jsonb) from public, anon, authenticated;
grant execute on function worker.import_records(bigint, text, jsonb), worker.import_contacts(bigint, jsonb) to scout_import;
