-- ERA Scout — Aanbellen: eigen prospecten die lang te koop staan, actueel gecontroleerd, zelf kiezen en in
-- een efficiënte volgorde bezoeken.
--
-- Gegevensmodel (bronneutraal, zodat een latere centrale pandendatabase een extra bron wordt):
--   listing_sources      welke bronnen er zijn (nu: ERAforce · Marketpulse uit de mirror op de Mac)
--   source_records       één rij per bronrecord (in ERAforce: één Lead), met de originele kerngegevens
--   properties           het fysieke pand (één woning / één unit); bronrecords verwijzen ernaar
--   match_reviews        twijfelachtige koppelingen: controleerbaar, niets wordt onomkeerbaar samengevoegd
--   owner_links          welke ERA Scout-gebruiker hoort bij een eigenaar in de bron (via e-mail of handmatig)
--   listing_checks       actuele controles per pand en per site (Immoweb, makelaarswebsite), met bewijs
--   manual_confirmations handmatige bevestiging door een gebruiker (datum + herkomst)
--   check_requests / check_runs   aangevraagde en uitgevoerde controles (één taak tegelijk)
--   scout_prefs / visit_selection / route_plans   persoonlijke instellingen, selectie en bezoekvolgorde
--
-- De verkoopperiodes worden afgeleid uit de marktdatums van de bronrecords (functie app.sale_periods).
-- Het wegschrijven door de Mac gebeurt enkel via de functies in schema worker, als rol scout_import.

create schema if not exists worker;
revoke all on schema worker from public;

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'scout_import') then
    create role scout_import nologin;
  end if;
end $$;
grant usage on schema worker to scout_import;

-- ---------- Bronnen ----------

create table public.listing_sources (
  code text primary key,
  label text not null,
  description text
);
insert into public.listing_sources (code, label, description) values
  ('eraforce_marketpulse', 'ERAforce · Marketpulse',
   'Prospects met bron Marketpulse uit de ERAforce-mirror (advertenties op Immoweb, aangevuld met Realo).')
on conflict (code) do nothing;

-- ---------- Fysieke panden ----------

create table public.properties (
  id bigint generated always as identity primary key,
  team_id bigint not null references public.teams (id),
  street text,
  number text,
  box text,
  postcode text,
  city text,
  address_key text not null,          -- genormaliseerd: straat|nummer|bus|postcode
  building_key text not null,         -- genormaliseerd: straat|nummer|postcode
  realo_property_id text,             -- stabiel pand-ID van Realo (blijft gelijk bij een nieuwe aanbieding)
  object_type text,
  lat double precision,
  lon double precision,
  geo_source text check (geo_source in ('register', 'immoweb', 'eraforce', 'geopunt', 'manual')),
  geo_quality text check (geo_quality in ('exact', 'approx', 'unsure')),
  geocoded_at timestamptz,
  created_at timestamptz not null default now()
);
create index properties_key on public.properties (team_id, address_key);
create index properties_building on public.properties (team_id, building_key);
create index properties_realo on public.properties (team_id, realo_property_id);

-- ---------- Bronrecords (prospectrecords) ----------

create table public.source_records (
  id bigint generated always as identity primary key,
  team_id bigint not null references public.teams (id),
  source text not null references public.listing_sources (code),
  external_id text not null,                 -- ERAforce: Lead-ID
  property_id bigint references public.properties (id) on delete set null,
  match_method text,                         -- realo_id | adres | nieuw | handmatig
  match_note text,
  owner_key text,                            -- ERAforce: OwnerId (gebruiker of wachtrij)
  owner_email text,
  owner_label text,
  owner_is_queue boolean not null default false,
  lifecycle text not null check (lifecycle in ('open', 'ended_usable', 'ended_excluded', 'converted')),
  status_label text,                         -- bv. "In Opvolging", "Beëindigd"
  end_reason text,                           -- bv. "Reeds verkocht", "Automatically ended"
  market_date date,                          -- ERAforce: Datum op de markt (start van deze aanbieding volgens Marketpulse)
  created_in_source timestamptz,             -- importdatum in ERAforce (NIET de verkoopstart)
  ended_on date,                             -- ERAforce: Datum Verkocht/Beëindigd
  source_modified_at timestamptz,
  street text, number text, box text, postcode text, city text,
  lat double precision, lon double precision,
  object_type text,
  price_current numeric,
  price_initial numeric,
  agency_label text,                         -- bv. "Marketpulse / Concurrent Makelaar (…)"
  immoweb_url text,
  immoweb_id text,
  realo_url text,
  realo_property_id text,
  realo_listing_id text,
  raw jsonb not null default '{}'::jsonb,    -- originele bronvelden (zonder persoonsgegevens)
  deleted boolean not null default false,    -- niet meer in de bron
  imported_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (team_id, source, external_id)
);
create index source_records_property on public.source_records (property_id);
create index source_records_owner on public.source_records (team_id, source, owner_key);

create table public.owner_links (
  team_id bigint not null references public.teams (id),
  source text not null references public.listing_sources (code),
  owner_key text not null,
  profile_id uuid references public.profiles (id) on delete cascade,
  method text not null check (method in ('email', 'manual')),
  updated_at timestamptz not null default now(),
  primary key (team_id, source, owner_key)
);

create table public.match_reviews (
  id bigint generated always as identity primary key,
  team_id bigint not null references public.teams (id),
  record_id bigint not null references public.source_records (id) on delete cascade,
  property_id bigint references public.properties (id) on delete cascade,
  other_property_id bigint references public.properties (id) on delete cascade,
  kind text not null check (kind in ('apartment_without_box', 'realo_address_conflict', 'same_address_other_realo')),
  note text,
  status text not null default 'open' check (status in ('open', 'confirmed', 'split', 'merged')),
  decided_by uuid references public.profiles (id),
  decided_at timestamptz,
  created_at timestamptz not null default now(),
  unique (record_id, kind)
);

-- ---------- Controles ----------

create table public.check_runs (
  id bigint generated always as identity primary key,
  team_id bigint not null references public.teams (id),
  kind text not null check (kind in ('daily', 'request', 'import')),
  worker text,
  started_at timestamptz not null default now(),
  lease_until timestamptz,
  finished_at timestamptz,
  checked int not null default 0,
  failed int not null default 0,
  note text
);

create table public.listing_checks (
  id bigint generated always as identity primary key,
  team_id bigint not null references public.teams (id),
  property_id bigint not null references public.properties (id) on delete cascade,
  site text not null check (site in ('immoweb', 'agency')),
  url text,
  status text not null check (status in ('active', 'under_option', 'sold', 'not_found', 'failed', 'unknown', 'not_applicable')),
  reason text,
  evidence text,
  error text,
  http_status int,
  details jsonb not null default '{}'::jsonb,
  checked_at timestamptz not null default now(),
  run_id bigint references public.check_runs (id) on delete set null
);
create index listing_checks_latest on public.listing_checks (property_id, site, checked_at desc);

create table public.manual_confirmations (
  id bigint generated always as identity primary key,
  team_id bigint not null references public.teams (id),
  property_id bigint not null references public.properties (id) on delete cascade,
  user_id uuid not null references public.profiles (id),
  status text not null check (status in ('active', 'not_active')),
  observed_on date not null,
  origin text not null,
  note text,
  created_at timestamptz not null default now()
);

create table public.check_requests (
  id bigint generated always as identity primary key,
  team_id bigint not null references public.teams (id),
  property_id bigint not null references public.properties (id) on delete cascade,
  requested_by uuid not null references public.profiles (id),
  created_at timestamptz not null default now(),
  done_at timestamptz
);
create index check_requests_open on public.check_requests (team_id) where done_at is null;

-- ---------- Persoonlijk: instellingen, selectie, route ----------

create table public.scout_prefs (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  min_days int not null default 90 check (min_days between 0 and 3650),
  basis text not null default 'current' check (basis in ('current', 'first')),
  updated_at timestamptz not null default now()
);

create table public.visit_selection (
  user_id uuid not null references public.profiles (id) on delete cascade,
  property_id bigint not null references public.properties (id) on delete cascade,
  selected_at timestamptz not null default now(),
  primary key (user_id, property_id)
);

create table public.route_plans (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  plan jsonb not null,
  saved_at timestamptz not null default now()
);

do $$
declare t text;
begin
  foreach t in array array['listing_sources', 'properties', 'source_records', 'owner_links', 'match_reviews', 'check_runs',
    'listing_checks', 'manual_confirmations', 'check_requests', 'scout_prefs', 'visit_selection', 'route_plans']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end $$;

-- ================================================================ normaliseren ==

create function app.norm_text(p text) returns text language sql immutable as $$
  select btrim(regexp_replace(
    translate(lower(coalesce(p, '')), 'àáâäãèéêëìíîïòóôöõùúûüçñ''’`´-', 'aaaaaeeeeiiiiooooouuuucn      '),
    '[^a-z0-9 ]+', ' ', 'g'))
$$;

-- Straatnaam: kleine letters, zonder accenten en leestekens, gangbare afkortingen voluit
-- (ook achteraan: "Kerkstr." → "kerkstraat", "Brusselsestwg" → "brusselsesteenweg").
create function app.norm_street(p text) returns text language sql immutable as $$
  select btrim(regexp_replace(
    regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(
      app.norm_text(p),
      '(stwg|steenwg)\M|\mstw\M', 'steenweg', 'g'),
      'str\M', 'straat', 'g'),
      '\mln\M', 'laan', 'g'),
      '\m(st|s)\M', 'sint', 'g'),
      '\mpl\M', 'plein', 'g'),
    '\s+', ' ', 'g'))
$$;

create function app.norm_number(p text) returns text language sql immutable as $$
  select regexp_replace(lower(coalesce(p, '')), '[^a-z0-9/-]', '', 'g')
$$;

-- Bus: "bus 0.1", "b1", "Bte 01" → "1"; "B" (unit B) blijft "b"; leeg blijft leeg.
create function app.norm_box(p text) returns text language sql immutable as $$
  select coalesce(nullif(ltrim(regexp_replace(regexp_replace(lower(coalesce(p, '')), '^\s*((bus|bte|box)\M|b(?=\s*[0-9]))', '', 'g'),
                                               '[^a-z0-9]', '', 'g'), '0'), ''),
                  case when regexp_replace(lower(coalesce(p, '')), '[^0-9]', '', 'g') ~ '^0+$' then '0' else '' end)
$$;

create function app.norm_postcode(p text) returns text language sql immutable as $$
  select regexp_replace(coalesce(p, ''), '[^0-9]', '', 'g')
$$;

create function app.address_key_of(p_street text, p_number text, p_box text, p_postcode text) returns text
language sql immutable as $$
  select concat_ws('|', app.norm_street(p_street), app.norm_number(p_number), app.norm_box(p_box), app.norm_postcode(p_postcode))
$$;

create function app.building_key_of(p_street text, p_number text, p_postcode text) returns text
language sql immutable as $$
  select concat_ws('|', app.norm_street(p_street), app.norm_number(p_number), app.norm_postcode(p_postcode))
$$;

create function app.is_apartment(p_type text) returns boolean language sql immutable as $$
  select coalesce(lower(p_type) ~ '(appart|apartment|studio|duplex|triplex|penthouse|flat|loft|kot)', false)
$$;

-- ================================================================ samenvoegen ==

create function app.new_property_for(p_r public.source_records) returns bigint language plpgsql as $$
declare l_id bigint;
begin
  insert into public.properties (team_id, street, number, box, postcode, city, address_key, building_key,
                                 realo_property_id, object_type)
  values (p_r.team_id, p_r.street, p_r.number, p_r.box, p_r.postcode, p_r.city,
          app.address_key_of(p_r.street, p_r.number, p_r.box, p_r.postcode),
          app.building_key_of(p_r.street, p_r.number, p_r.postcode), p_r.realo_property_id, p_r.object_type)
  returning id into l_id;
  return l_id;
end $$;

-- Koppel één bronrecord aan een fysiek pand. Stabiel ID eerst, dan het genormaliseerde adres.
-- Twijfel → een apart pand + een markering in match_reviews (nooit stilzwijgend samenvoegen).
create function app.match_record(p_record bigint) returns void language plpgsql as $$
declare
  l_r public.source_records;
  l_key text;
  l_building text;
  l_p public.properties;
  l_other public.properties;
  l_box text;
begin
  select * into l_r from public.source_records where id = p_record;
  if l_r.match_method = 'handmatig' then return; end if;
  l_key := app.address_key_of(l_r.street, l_r.number, l_r.box, l_r.postcode);
  l_building := app.building_key_of(l_r.street, l_r.number, l_r.postcode);
  l_box := app.norm_box(l_r.box);

  -- 1. Zelfde Realo-pand-ID.
  if l_r.realo_property_id is not null then
    select * into l_p from public.properties
    where team_id = l_r.team_id and realo_property_id = l_r.realo_property_id order by id limit 1;
    if l_p.id is not null then
      update public.source_records set property_id = l_p.id, match_method = 'realo_id',
        match_note = case when l_r.street is not null and l_p.address_key <> l_key then 'Realo-ID gelijk, adres verschilt' end
      where id = l_r.id;
      if l_r.street is not null and l_p.address_key <> l_key then
        insert into public.match_reviews (team_id, record_id, property_id, kind, note)
        values (l_r.team_id, l_r.id, l_p.id, 'realo_address_conflict',
                'Zelfde Realo-pand, maar het adres in dit record verschilt. Controleer of het om hetzelfde pand gaat.')
        on conflict (record_id, kind) do nothing;
      end if;
      return;
    end if;
  end if;

  -- 2. Zelfde genormaliseerd adres (straat, nummer, bus, postcode).
  if l_r.street is not null and l_r.number is not null then
    select * into l_p from public.properties
    where team_id = l_r.team_id and address_key = l_key order by id limit 1;
    if l_p.id is not null then
      if l_p.realo_property_id is not null and l_r.realo_property_id is not null
         and l_p.realo_property_id <> l_r.realo_property_id then
        -- Zelfde adres maar een ander Realo-pand: vaak twee units zonder busnummer. Niet samenvoegen.
        update public.source_records set property_id = app.new_property_for(l_r), match_method = 'nieuw',
          match_note = 'Zelfde adres, ander Realo-pand' where id = l_r.id;
        insert into public.match_reviews (team_id, record_id, property_id, other_property_id, kind, note)
        select l_r.team_id, l_r.id, property_id, l_p.id, 'same_address_other_realo',
               'Zelfde adres als een ander pand, maar een ander Realo-pand. Mogelijk twee units in hetzelfde gebouw.'
        from public.source_records where id = l_r.id
        on conflict (record_id, kind) do nothing;
        return;
      end if;
      if l_box = '' and app.is_apartment(l_r.object_type)
         and exists (select 1 from public.properties where team_id = l_r.team_id and building_key = l_building and id <> l_p.id) then
        null;  -- appartement zonder bus in een gebouw met meerdere units: hieronder behandeld als twijfel
      else
        update public.source_records set property_id = l_p.id, match_method = 'adres', match_note = null where id = l_r.id;
        update public.properties set realo_property_id = coalesce(realo_property_id, l_r.realo_property_id) where id = l_p.id;
        return;
      end if;
    end if;

    -- 3. Appartement zonder bus in een gebouw waar al units bekend zijn: apart pand + markering.
    if l_box = '' and app.is_apartment(l_r.object_type) then
      select * into l_other from public.properties
      where team_id = l_r.team_id and building_key = l_building order by id limit 1;
      if l_other.id is not null then
        update public.source_records set property_id = app.new_property_for(l_r), match_method = 'nieuw',
          match_note = 'Appartement zonder busnummer' where id = l_r.id;
        insert into public.match_reviews (team_id, record_id, property_id, other_property_id, kind, note)
        select l_r.team_id, l_r.id, property_id, l_other.id, 'apartment_without_box',
               'Appartement zonder busnummer in een gebouw met een ander bekend pand. Mogelijk dezelfde unit.'
        from public.source_records where id = l_r.id
        on conflict (record_id, kind) do nothing;
        return;
      end if;
    end if;
  end if;

  -- 4. Nieuw pand.
  update public.source_records set property_id = app.new_property_for(l_r), match_method = 'nieuw', match_note = null
  where id = l_r.id;
end $$;

create index addresses_norm on public.addresses (team_id, app.norm_street(street), app.norm_number(number));

-- Coördinaten: eerst het Adressenregister van de eigen regio (exact per huisnummer), dan die uit de bron.
create function app.locate_property(p_property bigint) returns void language plpgsql as $$
declare
  l_p public.properties;
  l_a public.addresses;
  l_r public.source_records;
begin
  select * into l_p from public.properties where id = p_property;
  if l_p.geo_quality = 'exact' or l_p.geo_source = 'manual' then return; end if;
  select a.* into l_a from public.addresses a
  where a.team_id = l_p.team_id and app.norm_street(a.street) = app.norm_street(l_p.street)
    and app.norm_number(a.number) = app.norm_number(l_p.number) and coalesce(a.postcode, '') = app.norm_postcode(l_p.postcode)
  limit 1;
  if l_a.id is not null then
    update public.properties set lat = l_a.lat, lon = l_a.lon, geo_source = 'register', geo_quality = 'exact', geocoded_at = now()
    where id = p_property;
    return;
  end if;
  if l_p.lat is null then
    select * into l_r from public.source_records
    where property_id = p_property and lat is not null and not deleted order by source_modified_at desc nulls last limit 1;
    if l_r.id is not null then
      update public.properties set lat = l_r.lat, lon = l_r.lon, geo_source = 'eraforce', geo_quality = 'approx', geocoded_at = now()
      where id = p_property;
    end if;
  end if;
end $$;

-- ================================================================ verkoopperiodes ==

-- Groepeert de marktdatums van alle bronrecords van een pand tot verkoopperiodes (datums binnen 30 dagen
-- = dezelfde aanbieding). Een nieuwe periode is 'bevestigd' als een eerder record vóór de nieuwe startdatum
-- als beëindigd of verkocht staat; anders 'onzeker' (bv. enkel een nieuwe advertentie of import).
create function app.sale_periods(p_property bigint) returns jsonb language plpgsql stable as $$
declare
  l_rec record;
  l_periods jsonb := '[]';
  l_start date;
  l_last date;
  l_certain boolean;
  l_any_uncertain boolean := false;
  l_no_date int;
begin
  for l_rec in
    select distinct market_date from public.source_records
    where property_id = p_property and not deleted and market_date is not null order by market_date
  loop
    if l_start is null then
      l_start := l_rec.market_date;
      l_periods := jsonb_build_array(jsonb_build_object('start', l_start, 'certain', true));
    elsif l_rec.market_date > l_last + 30 then
      l_certain := exists (select 1 from public.source_records r
                           where r.property_id = p_property and not r.deleted and r.market_date between l_start and l_last
                             and r.ended_on is not null and r.ended_on <= l_rec.market_date);
      l_any_uncertain := l_any_uncertain or not l_certain;
      l_start := l_rec.market_date;
      l_periods := l_periods || jsonb_build_object('start', l_start, 'certain', l_certain);
    end if;
    l_last := l_rec.market_date;
  end loop;
  select count(*) into l_no_date from public.source_records where property_id = p_property and not deleted and market_date is null;
  return jsonb_build_object(
    'periods', l_periods,
    'first_start', l_periods->0->>'start',
    'current_start', l_periods->(jsonb_array_length(l_periods) - 1)->>'start',
    'relisted', jsonb_array_length(l_periods) > 1,
    'relist_certain', jsonb_array_length(l_periods) > 1 and not l_any_uncertain,
    'records_without_date', l_no_date);
end $$;

-- ================================================================ controlestatus ==

create function app.check_json(p_property bigint, p_site text) returns jsonb language sql stable as $$
  select jsonb_build_object(
    'status', c.status, 'checked_at', c.checked_at, 'url', c.url, 'reason', c.reason, 'error', c.error,
    'fresh', c.checked_at > now() - interval '36 hours',
    'details', c.details,
    'last_success', (select jsonb_build_object('status', s.status, 'checked_at', s.checked_at)
                     from public.listing_checks s where s.property_id = p_property and s.site = p_site
                       and s.status in ('active', 'under_option', 'sold', 'not_found', 'not_applicable')
                     order by s.checked_at desc limit 1))
  from public.listing_checks c where c.property_id = p_property and c.site = p_site
  order by c.checked_at desc limit 1
$$;

-- Beslissing per pand:
--   actief te koop op minstens één bron (verse controle of handmatige bevestiging) → geschikt
--   alle toepasselijke bronnen aantoonbaar niet meer actief (verkocht, onder optie, niet meer gevonden) → niet meer te koop
--   anders (nooit gecontroleerd, mislukt, onbekend, verouderd) → controle nodig
create function app.property_decision(p_property bigint) returns jsonb language plpgsql stable as $$
declare
  l_iw jsonb := app.check_json(p_property, 'immoweb');
  l_ag jsonb := app.check_json(p_property, 'agency');
  l_m public.manual_confirmations;
  l_sites jsonb := '[]';
  l_s jsonb;
  l_active boolean := false;
  l_all_gone boolean := true;
  l_any boolean := false;
  l_conflict boolean := false;
  l_reason text;
  l_inactive constant text[] := array['sold', 'under_option', 'not_found'];
begin
  select * into l_m from public.manual_confirmations
  where property_id = p_property and observed_on >= current_date - 30 order by observed_on desc, id desc limit 1;
  if l_iw is not null then l_sites := l_sites || l_iw; end if;
  if l_ag is not null and l_ag->>'status' <> 'not_applicable' then l_sites := l_sites || l_ag; end if;
  for l_s in select x.v from jsonb_array_elements(l_sites) as x(v) loop
    l_any := true;
    if (l_s->>'fresh')::boolean and l_s->>'status' = 'active' then l_active := true; end if;
    if not ((l_s->>'fresh')::boolean and l_s->>'status' = any (l_inactive)) then l_all_gone := false; end if;
  end loop;
  l_conflict := l_iw is not null and l_ag is not null and (l_iw->>'fresh')::boolean and (l_ag->>'fresh')::boolean
    and ((l_iw->>'status' = 'active') <> (l_ag->>'status' = 'active')) and l_ag->>'status' <> 'not_applicable'
    and l_iw->>'status' not in ('failed', 'unknown') and l_ag->>'status' not in ('failed', 'unknown');

  if l_m.id is not null and l_m.status = 'active' then
    return jsonb_build_object('decision', 'eligible', 'reason', 'Handmatig bevestigd als te koop',
      'conflict', l_conflict, 'immoweb', l_iw, 'agency', l_ag, 'manual', to_jsonb(l_m));
  end if;
  if l_active then
    l_reason := case when l_conflict then 'Actief op één bron, niet op de andere' else 'Actief te koop' end;
    return jsonb_build_object('decision', 'eligible', 'reason', l_reason, 'conflict', l_conflict,
      'immoweb', l_iw, 'agency', l_ag, 'manual', to_jsonb(l_m));
  end if;
  if (l_m.id is not null and l_m.status = 'not_active') or (l_any and l_all_gone) then
    return jsonb_build_object('decision', 'not_for_sale',
      'reason', case when l_m.id is not null and l_m.status = 'not_active' then 'Handmatig: niet meer te koop'
                     else 'Op de gecontroleerde bronnen niet meer actief' end,
      'conflict', l_conflict, 'immoweb', l_iw, 'agency', l_ag, 'manual', to_jsonb(l_m));
  end if;
  return jsonb_build_object('decision', 'needs_check',
    'reason', case when not l_any then 'Nog niet gecontroleerd'
                   when exists (select 1 from jsonb_array_elements(l_sites) as x(v) where not (x.v->>'fresh')::boolean) then 'Controle verouderd'
                   else 'Geen actieve aanbieding bevestigd; een bron is onzeker of niet controleerbaar' end,
    'conflict', l_conflict, 'immoweb', l_iw, 'agency', l_ag, 'manual', to_jsonb(l_m));
end $$;

-- ================================================================ zichtbaarheid ==

-- Panden van een gebruiker: minstens één bruikbaar, niet-verwijderd bronrecord met die gebruiker als eigenaar.
create function app.my_property_ids(p_user public.profiles) returns setof bigint language sql stable as $$
  select distinct r.property_id
  from public.source_records r
  join public.owner_links o on o.team_id = r.team_id and o.source = r.source and o.owner_key = r.owner_key
  where r.team_id = p_user.team_id and o.profile_id = p_user.id and not r.deleted
    and r.lifecycle in ('open', 'ended_usable') and r.property_id is not null
$$;

create function app.property_card(p_property bigint, p_user public.profiles, p_today date) returns jsonb
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
    'price', l_latest.price_current, 'agency', l_latest.agency_label,
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
    'agency_url', coalesce(l_dec->'agency'->>'url', l_dec->'agency'->'details'->>'agency_website'),
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

-- ================================================================ API (app) ==

create function public.scout_overview(p_min_days int default null, p_basis text default null) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  l_me public.profiles := app.me();
  l_team public.teams := app.team(l_me.team_id);
  l_today date := app.today(l_team);
  l_prefs public.scout_prefs;
  l_cards jsonb;
  l_below int;
begin
  if p_basis is not null and p_basis not in ('current', 'first') then perform app.fail('Ongeldige berekeningswijze.'); end if;
  if p_min_days is not null and p_min_days not between 0 and 3650 then perform app.fail('Kies een aantal dagen tussen 0 en 3650.'); end if;
  insert into public.scout_prefs (user_id) values (l_me.id) on conflict (user_id) do nothing;
  if p_min_days is not null or p_basis is not null then
    update public.scout_prefs set min_days = coalesce(p_min_days, min_days), basis = coalesce(p_basis, basis), updated_at = now()
    where user_id = l_me.id;
  end if;
  select * into l_prefs from public.scout_prefs where user_id = l_me.id;

  -- Enkel panden boven de dagengrens (strikt meer dan), panden zonder betrouwbare datum en geselecteerde panden.
  select coalesce(jsonb_agg(c order by (c->>'decision') <> 'eligible', coalesce((c->>'days_current')::int, -1) desc), '[]'::jsonb),
         count(*) filter (where not keep)
  into l_cards, l_below
  from (select c, (c->>'selected')::boolean
                  or (c->>case when l_prefs.basis = 'first' then 'days_first' else 'days_current' end) is null
                  or (c->>case when l_prefs.basis = 'first' then 'days_first' else 'days_current' end)::int > l_prefs.min_days as keep
        from (select app.property_card(pid, l_me, l_today) as c from app.my_property_ids(l_me) pid) s0) s
  where keep or true;
  select coalesce(jsonb_agg(x.v order by (x.v->>'decision') <> 'eligible', coalesce((x.v->>'days_current')::int, -1) desc), '[]'::jsonb)
  into l_cards
  from jsonb_array_elements(l_cards) as x(v)
  where (x.v->>'selected')::boolean
     or (x.v->>case when l_prefs.basis = 'first' then 'days_first' else 'days_current' end) is null
     or (x.v->>case when l_prefs.basis = 'first' then 'days_first' else 'days_current' end)::int > l_prefs.min_days;

  return jsonb_build_object(
    'prefs', jsonb_build_object('min_days', l_prefs.min_days, 'basis', l_prefs.basis),
    'today', l_today,
    'source', jsonb_build_object(
      'label', (select label from public.listing_sources where code = 'eraforce_marketpulse'),
      'last_import', (select max(imported_at) from public.source_records where team_id = l_team.id),
      'last_run', (select to_jsonb(r) from public.check_runs r where r.team_id = l_team.id and r.finished_at is not null
                   and r.kind <> 'import' order by r.finished_at desc limit 1),
      'running', exists (select 1 from public.check_runs r where r.team_id = l_team.id and r.finished_at is null and r.lease_until > now()),
      'pending_requests', (select count(*) from public.check_requests q where q.team_id = l_team.id and q.done_at is null),
      'linked', exists (select 1 from public.owner_links o where o.team_id = l_team.id and o.profile_id = l_me.id)),
    'below_threshold', l_below,
    'cards', l_cards);
end $$;

create function public.scout_select(p_property bigint, p_selected boolean) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare l_me public.profiles := app.me();
begin
  if p_selected then
    if p_property not in (select app.my_property_ids(l_me)) then perform app.fail('Dit pand staat niet in jouw lijst.', 'forbidden'); end if;
    insert into public.visit_selection (user_id, property_id) values (l_me.id, p_property) on conflict do nothing;
  else
    delete from public.visit_selection where user_id = l_me.id and property_id = p_property;
  end if;
  return jsonb_build_object('selected', (select count(*) from public.visit_selection where user_id = l_me.id));
end $$;

create function public.scout_request_check(p_property bigint default null) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  l_me public.profiles := app.me();
  l_n int;
begin
  insert into public.check_requests (team_id, property_id, requested_by)
  select l_me.team_id, pid, l_me.id from app.my_property_ids(l_me) pid
  where (p_property is null or pid = p_property)
    and not exists (select 1 from public.check_requests q where q.property_id = pid and q.done_at is null);
  get diagnostics l_n = row_count;
  if p_property is not null and l_n = 0
     and not exists (select 1 from public.check_requests q where q.property_id = p_property and q.done_at is null) then
    perform app.fail('Dit pand staat niet in jouw lijst.', 'forbidden');
  end if;
  return jsonb_build_object('requested', l_n);
end $$;

create function public.scout_confirm(p_property bigint, p_status text, p_observed_on date, p_origin text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public, app, pg_temp as $$
declare l_me public.profiles := app.me();
begin
  if p_property not in (select app.my_property_ids(l_me)) then perform app.fail('Dit pand staat niet in jouw lijst.', 'forbidden'); end if;
  if p_status not in ('active', 'not_active') then perform app.fail('Kies of het pand nog te koop staat.'); end if;
  if p_observed_on is null or p_observed_on > app.today(app.team(l_me.team_id)) or p_observed_on < current_date - 60 then
    perform app.fail('Kies een datum van de laatste 60 dagen.');
  end if;
  insert into public.manual_confirmations (team_id, property_id, user_id, status, observed_on, origin, note)
  values (l_me.team_id, p_property, l_me.id, p_status, p_observed_on,
          app.clean_text(p_origin, 'Herkomst', 80, true), app.clean_text(p_note, 'Notitie', 280));
  return jsonb_build_object('card', app.property_card(p_property, l_me, app.today(app.team(l_me.team_id))));
end $$;

create function public.scout_save_route(p_plan jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare l_me public.profiles := app.me();
begin
  if jsonb_typeof(p_plan) <> 'object' or length(p_plan::text) > 100000 then perform app.fail('Ongeldige route.'); end if;
  insert into public.route_plans (user_id, plan) values (l_me.id, p_plan)
  on conflict (user_id) do update set plan = excluded.plan, saved_at = now();
  return jsonb_build_object('ok', true);
end $$;

create function public.scout_route() returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select jsonb_build_object('plan', (select plan from public.route_plans where user_id = (app.me()).id))
$$;

-- ---------- Beheer: samenvoegingen en eigenaarskoppeling ----------

create function public.scout_admin_reviews() returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare l_me public.profiles := app.admin();
begin
  return jsonb_build_object(
    'reviews', (select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'kind', m.kind, 'note', m.note, 'created_at', m.created_at,
                  'record', r.external_id, 'record_address', concat_ws(' ', r.street, r.number, nullif('bus ' || r.box, 'bus '), r.postcode, r.city),
                  'property_id', m.property_id, 'other_property_id', m.other_property_id,
                  'other_address', (select concat_ws(' ', p.street, p.number, nullif('bus ' || p.box, 'bus '), p.postcode, p.city)
                                    from public.properties p where p.id = m.other_property_id))
                  order by m.created_at desc), '[]'::jsonb)
                from public.match_reviews m join public.source_records r on r.id = m.record_id
                where m.team_id = l_me.team_id and m.status = 'open'),
    'owners', (select coalesce(jsonb_agg(jsonb_build_object('owner_key', x.owner_key, 'label', x.owner_label, 'email', x.owner_email,
                 'queue', x.owner_is_queue, 'records', x.n, 'profile_id', o.profile_id, 'method', o.method) order by x.n desc), '[]'::jsonb)
               from (select owner_key, max(owner_label) as owner_label, max(owner_email) as owner_email, bool_or(owner_is_queue) as owner_is_queue,
                            count(*) as n
                     from public.source_records where team_id = l_me.team_id and not deleted and lifecycle in ('open', 'ended_usable')
                     group by owner_key) x
               left join public.owner_links o on o.team_id = l_me.team_id and o.source = 'eraforce_marketpulse' and o.owner_key = x.owner_key));
end $$;

-- Twijfel beslissen: 'merge' = toch hetzelfde pand (record naar het andere pand), 'separate' = apart laten.
create function public.scout_admin_review_decide(p_id bigint, p_decision text) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  l_me public.profiles := app.admin();
  l_m public.match_reviews;
  l_target bigint;
begin
  select * into l_m from public.match_reviews where id = p_id and team_id = l_me.team_id;
  if not found then perform app.fail('Markering niet gevonden.', 'not_found'); end if;
  if p_decision = 'merge' then
    l_target := coalesce(l_m.other_property_id, l_m.property_id);
    update public.source_records set property_id = l_target, match_method = 'handmatig',
      match_note = 'Handmatig samengevoegd door ' || l_me.name where id = l_m.record_id;
    update public.match_reviews set status = 'merged', decided_by = l_me.id, decided_at = now() where id = p_id;
  elsif p_decision = 'separate' then
    if l_m.kind = 'realo_address_conflict' then
      update public.source_records set property_id = null, match_method = null where id = l_m.record_id;
      update public.source_records set property_id = app.new_property_for(r), match_method = 'handmatig',
        match_note = 'Handmatig gesplitst door ' || l_me.name
      from public.source_records r where r.id = l_m.record_id and public.source_records.id = r.id;
    else
      update public.source_records set match_method = 'handmatig', match_note = 'Bevestigd als apart pand door ' || l_me.name
      where id = l_m.record_id;
    end if;
    update public.match_reviews set status = 'split', decided_by = l_me.id, decided_at = now() where id = p_id;
  else
    perform app.fail('Kies samenvoegen of apart houden.');
  end if;
  return jsonb_build_object('ok', true);
end $$;

create function public.scout_admin_link_owner(p_owner_key text, p_profile uuid) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare l_me public.profiles := app.admin();
begin
  if p_profile is not null and not exists (select 1 from public.profiles where id = p_profile and team_id = l_me.team_id) then
    perform app.fail('Collega niet gevonden.', 'not_found');
  end if;
  insert into public.owner_links (team_id, source, owner_key, profile_id, method)
  values (l_me.team_id, 'eraforce_marketpulse', p_owner_key, p_profile, 'manual')
  on conflict (team_id, source, owner_key) do update set profile_id = excluded.profile_id, method = 'manual', updated_at = now();
  return jsonb_build_object('ok', true);
end $$;

-- ================================================================ Mac (worker) ==

-- Bronrecords inlezen. p_rows: lijst van objecten met de velden van source_records (zonder id/property_id).
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
      street, number, box, postcode, city, lat, lon, object_type, price_current, price_initial, agency_label,
      immoweb_url, immoweb_id, realo_url, realo_property_id, realo_listing_id, raw, deleted, imported_at, updated_at)
    select p_team, p_source, x.external_id, x.owner_key, lower(x.owner_email), x.owner_label, coalesce(x.owner_is_queue, false),
      x.lifecycle, x.status_label, x.end_reason, x.market_date, x.created_in_source, x.ended_on, x.source_modified_at,
      nullif(btrim(x.street), ''), nullif(btrim(x.number), ''), nullif(btrim(x.box), ''), nullif(btrim(x.postcode), ''),
      nullif(btrim(x.city), ''), x.lat, x.lon, x.object_type, x.price_current, x.price_initial, x.agency_label,
      x.immoweb_url, x.immoweb_id, x.realo_url, x.realo_property_id, x.realo_listing_id, coalesce(x.raw, '{}'::jsonb),
      false, now(), now()
    from jsonb_to_recordset(p_rows) as x(external_id text, owner_key text, owner_email text, owner_label text, owner_is_queue boolean,
      lifecycle text, status_label text, end_reason text, market_date date, created_in_source timestamptz, ended_on date,
      source_modified_at timestamptz, street text, number text, box text, postcode text, city text, lat double precision,
      lon double precision, object_type text, price_current numeric, price_initial numeric, agency_label text, immoweb_url text,
      immoweb_id text, realo_url text, realo_property_id text, realo_listing_id text, raw jsonb)
    where x.external_id is not null
    on conflict (team_id, source, external_id) do update set
      owner_key = excluded.owner_key, owner_email = excluded.owner_email, owner_label = excluded.owner_label,
      owner_is_queue = excluded.owner_is_queue, lifecycle = excluded.lifecycle, status_label = excluded.status_label,
      end_reason = excluded.end_reason, market_date = excluded.market_date, created_in_source = excluded.created_in_source,
      ended_on = excluded.ended_on, source_modified_at = excluded.source_modified_at, street = excluded.street,
      number = excluded.number, box = excluded.box, postcode = excluded.postcode, city = excluded.city, lat = excluded.lat,
      lon = excluded.lon, object_type = excluded.object_type, price_current = excluded.price_current,
      price_initial = excluded.price_initial, agency_label = excluded.agency_label, immoweb_url = excluded.immoweb_url,
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

-- Na een volledige import: records die niet meer in de bron staan markeren, eigenaars koppelen, locaties zoeken.
create function worker.finish_import(p_team bigint, p_source text, p_seen text[]) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  l_gone int;
  l_linked int;
  l_pid bigint;
begin
  update public.source_records set deleted = true, updated_at = now()
  where team_id = p_team and source = p_source and not deleted and not (external_id = any (p_seen));
  get diagnostics l_gone = row_count;
  insert into public.owner_links (team_id, source, owner_key, profile_id, method)
  select distinct on (r.owner_key) p_team, p_source, r.owner_key, p.id, 'email'
  from public.source_records r join public.profiles p on p.team_id = p_team and lower(p.email) = r.owner_email
  where r.team_id = p_team and r.source = p_source and r.owner_key is not null and not r.owner_is_queue
  on conflict (team_id, source, owner_key) do update set profile_id = excluded.profile_id, updated_at = now()
    where public.owner_links.method = 'email';
  get diagnostics l_linked = row_count;
  for l_pid in select id from public.properties where team_id = p_team and (geo_quality is null or geo_quality <> 'exact') loop
    perform app.locate_property(l_pid);
  end loop;
  -- Panden zonder bronrecords meer opruimen (geen selecties of controles verliezen: enkel als die er niet zijn).
  delete from public.properties p where p.team_id = p_team
    and not exists (select 1 from public.source_records r where r.property_id = p.id)
    and not exists (select 1 from public.visit_selection s where s.property_id = p.id)
    and not exists (select 1 from public.listing_checks c where c.property_id = p.id)
    and not exists (select 1 from public.manual_confirmations m where m.property_id = p.id);
  insert into public.check_runs (team_id, kind, worker, finished_at, checked, note)
  values (p_team, 'import', 'mac', now(), coalesce(array_length(p_seen, 1), 0), format('%s niet meer in de bron', l_gone));
  return jsonb_build_object('gone', l_gone, 'owner_links', l_linked,
    'properties', (select count(*) from public.properties where team_id = p_team));
end $$;

-- Start een controleronde. Geeft niets terug als er al een ronde loopt (bescherming tegen dubbele taken).
-- Volgorde: aangevraagde panden, geselecteerde panden, dan de rest die aan vernieuwing toe is.
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
      'agency_website', (select c2.details->>'agency_website' from public.listing_checks c2 where c2.property_id = c.pid
                         and c2.details ? 'agency_website' order by c2.checked_at desc limit 1)) as x
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
  update public.check_runs set checked = checked + 1, failed = failed + (p_status = 'failed')::int,
    lease_until = now() + interval '45 minutes' where id = p_run;
end $$;

create function worker.save_geo(p_property bigint, p_lat double precision, p_lon double precision, p_source text, p_quality text)
returns void language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if p_lat not between 49.4 and 51.6 or p_lon not between 2.4 and 6.5 then return; end if;
  update public.properties set lat = p_lat, lon = p_lon, geo_source = p_source, geo_quality = p_quality, geocoded_at = now()
  where id = p_property and coalesce(geo_quality, '') <> 'exact' and coalesce(geo_source, '') <> 'manual';
end $$;

create function worker.finish_run(p_run bigint, p_note text) returns void
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  update public.check_requests q set done_at = now()
  where q.done_at is null and q.created_at <= (select started_at from public.check_runs where id = p_run)
    and exists (select 1 from public.listing_checks c where c.property_id = q.property_id and c.run_id = p_run);
  update public.check_runs set finished_at = now(), lease_until = null, note = left(p_note, 300) where id = p_run;
end $$;

create function worker.daily_done(p_team bigint) returns boolean
language sql stable security definer set search_path = public, app, pg_temp as $$
  select exists (select 1 from public.check_runs where team_id = p_team and kind = 'daily' and finished_at is not null
                 and (started_at at time zone (select timezone from public.teams where id = p_team))::date
                     = app.today(app.team(p_team)))
$$;

create function worker.team_id(p_name text default null) returns bigint
language sql stable security definer set search_path = public, app, pg_temp as $$
  select id from public.teams where p_name is null or name = p_name order by id limit 1
$$;

-- ================================================================ rechten ==

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig, n.nspname, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where (n.nspname = 'app' and p.proname in ('norm_text', 'norm_street', 'norm_number', 'norm_box', 'norm_postcode',
                   'address_key_of', 'building_key_of', 'is_apartment', 'new_property_for', 'match_record', 'locate_property',
                   'sale_periods', 'check_json', 'property_decision', 'my_property_ids', 'property_card'))
              or n.nspname = 'worker'
              or (n.nspname = 'public' and p.proname like 'scout\_%') loop
    execute format('revoke all on function %s from public', f.sig);
    if f.nspname = 'worker' then
      execute format('grant execute on function %s to scout_import', f.sig);
    elsif f.nspname = 'public' then
      execute format('revoke all on function %s from anon', f.sig);
      execute format('grant execute on function %s to authenticated', f.sig);
    end if;
  end loop;
end $$;
