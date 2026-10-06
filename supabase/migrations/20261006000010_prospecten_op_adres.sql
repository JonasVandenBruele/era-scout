-- Prospecten uit ERAforce op hetzelfde (genormaliseerde) adres: naam en telefoon op de kaart.
-- Enkel zichtbaar op de kaarten van de eigen panden (property_card), nooit rechtstreeks opvraagbaar.

create table public.crm_contacts (
  id bigserial primary key,
  team_id bigint not null references public.teams(id) on delete cascade,
  source text not null,                       -- 'eraforce_lead'
  external_id text not null,                  -- Salesforce-Id van de prospect
  address_type text not null check (address_type in ('main', 'other')),
  kind text,                                  -- Verkoper / Verhuurder / Koper
  name text,
  phone text,
  mobile text,
  do_not_call boolean not null default false,
  status text,
  lead_source text,
  owner_label text,
  created_in_source timestamptz,
  street text, number text, box text, postcode text, city text,
  address_key text, building_key text, loose_key text,
  deleted boolean not null default false,
  imported_at timestamptz not null default now(),
  unique (team_id, source, external_id, address_type)
);
create index crm_contacts_building on public.crm_contacts (team_id, building_key) where not deleted;
create index crm_contacts_loose on public.crm_contacts (team_id, loose_key) where not deleted;
alter table public.crm_contacts enable row level security;
revoke all on public.crm_contacts from anon, authenticated;
revoke all on sequence public.crm_contacts_id_seq from anon, authenticated;

-- Losse sleutel: postcode | huisnummer zonder letter | laatste woord van de straat.
-- Vangt afkortingen ("Lod. van Veltemstraat" = "Lodewijk van Veltemstraat") en 51 / 51A / 51/A.
create function app.loose_key_of(p_street text, p_number text, p_postcode text) returns text
language sql immutable as $$
  select case when coalesce(substring(p_number from '\d+'), '') = '' or app.norm_street(p_street) = '' then null
              else concat_ws('|', app.norm_postcode(p_postcode), substring(p_number from '\d+'),
                             regexp_replace(app.norm_street(p_street), '^.* ', '')) end
$$;

create function app.property_contacts(p_property bigint) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  with p as (
    select team_id, app.address_key_of(street, number, box, postcode) as ak,
           app.building_key_of(street, number, postcode) as bk, app.loose_key_of(street, number, postcode) as lk
    from public.properties where id = p_property
  ), m as (
    select c.*, case when c.address_key = p.ak then 1 when c.building_key = p.bk then 2 else 3 end as tier
    from public.crm_contacts c, p
    where c.team_id = p.team_id and not c.deleted
      and (c.building_key = p.bk or (p.lk is not null and c.loose_key = p.lk))
  ), best as (
    select distinct on (external_id) * from m order by external_id, tier, address_type
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'name', name, 'phone', case when do_not_call then null else phone end,
      'mobile', case when do_not_call then null else mobile end, 'do_not_call', do_not_call,
      'kind', kind, 'status', status, 'lead_source', lead_source, 'owner', owner_label,
      'created', created_in_source, 'other_address', address_type = 'other',
      'address', concat_ws(' ', street, number) || case when coalesce(box, '') <> '' then ' bus ' || box else '' end,
      'match', case tier when 1 then 'adres' when 2 then 'gebouw' else 'vermoedelijk' end)
    order by tier, created_in_source desc nulls last), '[]'::jsonb)
  from (select * from best order by tier, created_in_source desc nulls last limit 6) b
$$;

create function worker.import_contacts(p_team bigint, p_rows jsonb) returns int
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare l_n int;
begin
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) > 5000 then perform app.fail('Ongeldige lijst.'); end if;
  insert into public.crm_contacts as c (team_id, source, external_id, address_type, kind, name, phone, mobile, do_not_call, status,
    lead_source, owner_label, created_in_source, street, number, box, postcode, city, address_key, building_key, loose_key,
    deleted, imported_at)
  select p_team, 'eraforce_lead', x.external_id, x.address_type, x.kind, left(x.name, 200), left(x.phone, 40), left(x.mobile, 40),
    coalesce(x.do_not_call, false), x.status, x.lead_source, x.owner_label, x.created_in_source,
    x.street, x.number, x.box, x.postcode, x.city,
    app.address_key_of(x.street, x.number, x.box, x.postcode), app.building_key_of(x.street, x.number, x.postcode),
    app.loose_key_of(x.street, x.number, x.postcode), false, now()
  from jsonb_to_recordset(p_rows) as x(external_id text, address_type text, kind text, name text, phone text, mobile text,
       do_not_call boolean, status text, lead_source text, owner_label text, created_in_source timestamptz,
       street text, number text, box text, postcode text, city text)
  where x.external_id is not null and x.address_type in ('main', 'other') and x.street is not null and x.number is not null
  on conflict (team_id, source, external_id, address_type) do update set kind = excluded.kind, name = excluded.name,
    phone = excluded.phone, mobile = excluded.mobile, do_not_call = excluded.do_not_call, status = excluded.status,
    lead_source = excluded.lead_source, owner_label = excluded.owner_label, created_in_source = excluded.created_in_source,
    street = excluded.street, number = excluded.number, box = excluded.box, postcode = excluded.postcode, city = excluded.city,
    address_key = excluded.address_key, building_key = excluded.building_key, loose_key = excluded.loose_key,
    deleted = false, imported_at = now();
  get diagnostics l_n = row_count;
  return l_n;
end $$;

-- Na een volledige import: wat niet meer in de bron zit, wordt gewist (geen persoonsgegevens bijhouden die weg zijn).
create function worker.finish_contacts(p_team bigint, p_started timestamptz) returns int
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare l_n int;
begin
  delete from public.crm_contacts where team_id = p_team and source = 'eraforce_lead' and imported_at < p_started;
  get diagnostics l_n = row_count;
  return l_n;
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
    'contacts', app.property_contacts(p_property),
    'selected', exists (select 1 from public.visit_selection s where s.user_id = p_user.id and s.property_id = p_property),
    'request_pending', exists (select 1 from public.check_requests q where q.property_id = p_property and q.done_at is null));
end $$;

revoke all on function app.loose_key_of(text, text, text), app.property_contacts(bigint) from public, anon, authenticated;
revoke all on function worker.import_contacts(bigint, jsonb), worker.finish_contacts(bigint, timestamptz) from public, anon, authenticated;
grant execute on function worker.import_contacts(bigint, jsonb), worker.finish_contacts(bigint, timestamptz) to scout_import;
