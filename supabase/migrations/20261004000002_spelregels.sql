-- ERA Scout — spelregels (interne functies in schema app).
--
-- Puntenmodel
-- * Een bezoek heeft één resultaat: door (aangebeld) < conversation (gesprek) < phone (telefoonnummer)
--   < appointment (afspraak). Punten = waarde van het hoogste resultaat dat nog in aanmerking komt,
--   volgens de puntregelversie die gold bij het aanmaken van het bezoek. Bedragen zijn totalen.
-- * Punten veranderen enkel via point_transactions: verbeteren van 5 naar 15 schrijft één transactie +10.
-- * Geschiktheid (t.o.v. bezoeken die vóór dit bezoek zijn aangemaakt, dus later bezoeken herschrijven
--   de geschiedenis niet):
--     door/gesprek: altijd, maar aan revisit_pct % wanneer het adres binnen revisit_cooldown_days al
--                   een bezoek met punten kreeg (door iemand van het team);
--     telefoon:     geen eerder bezoek kreeg al de nummer- of afspraakbonus en het nummer is nieuw;
--     afspraak:     er staat geen eerdere afspraak meer gepland op of na dit moment.

-- ---------- Algemene hulpfuncties ----------

create function app.fail(p_msg text, p_code text default '') returns void
language plpgsql as $$
begin
  raise exception using errcode = 'P0001', message = p_msg, hint = coalesce(p_code, '');
end $$;

create function app.clean_text(p_value text, p_field text, p_max int default 300, p_required boolean default false)
returns text language plpgsql immutable as $$
declare l_s text := btrim(regexp_replace(coalesce(p_value, ''), '\s+', ' ', 'g'));
begin
  if p_required and l_s = '' then perform app.fail(p_field || ' is verplicht.'); end if;
  if length(l_s) > p_max then perform app.fail(format('%s is te lang (max. %s tekens).', p_field, p_max)); end if;
  return nullif(l_s, '');
end $$;

create function app.address_key(p_address text) returns text language sql immutable as $$
  select btrim(regexp_replace(regexp_replace(lower(coalesce(p_address, '')), '[.,;/]', ' ', 'g'), '\s+', ' ', 'g'))
$$;

create function app.normalize_phone(p_raw text) returns text language plpgsql immutable as $$
declare l_s text := regexp_replace(coalesce(p_raw, ''), '[\s.\-/()]', '', 'g');
begin
  if l_s like '00%' then l_s := '+' || substr(l_s, 3);
  elsif l_s like '0%' then l_s := '+32' || substr(l_s, 2);  -- aanname: lokale nummers zijn Belgisch
  end if;
  if l_s !~ '^\+?\d{8,15}$' then perform app.fail('Dat lijkt geen geldig telefoonnummer.'); end if;
  return l_s;
end $$;

create function app.format_phone(p_number text) returns text language plpgsql immutable as $$
declare l_local text;
begin
  if p_number like '+32%' and length(p_number) >= 11 then
    l_local := '0' || substr(p_number, 4);
    if length(l_local) = 10 then
      return format('%s %s %s %s', substr(l_local, 1, 4), substr(l_local, 5, 2), substr(l_local, 7, 2), substr(l_local, 9));
    end if;
    return format('%s %s %s %s', substr(l_local, 1, 3), substr(l_local, 4, 2), substr(l_local, 6, 2), substr(l_local, 8));
  end if;
  return p_number;
end $$;

create function app.tier(p_result text) returns int language sql immutable as $$
  select case p_result when 'door' then 1 when 'conversation' then 2 when 'phone' then 3 when 'appointment' then 4 else 0 end
$$;

create function app.tier_name(p_tier int) returns text language sql immutable as $$
  select (array['door', 'conversation', 'phone', 'appointment'])[p_tier]
$$;

create function app.result_label(p_result text) returns text language sql immutable as $$
  select case p_result when 'door' then 'Aangebeld' when 'conversation' then 'Gesprek'
    when 'phone' then 'Telefoonnummer' when 'appointment' then 'Afspraak' end
$$;

create function app.check_result(p_result text) returns text language plpgsql immutable as $$
begin
  if app.tier(p_result) = 0 then perform app.fail('Kies een resultaat.'); end if;
  return p_result;
end $$;

create function app.today(p_team public.teams) returns date language sql stable as $$
  select (now() at time zone p_team.timezone)::date
$$;

create function app.week_start(p_day date) returns date language sql immutable as $$
  select p_day - (extract(isodow from p_day)::int - 1)
$$;

create function app.current_rule(p_team bigint) returns public.point_rules language sql stable as $$
  select * from public.point_rules where team_id = p_team order by id desc limit 1
$$;

create function app.tier_value(p_rule public.point_rules, p_tier int, p_reduced boolean) returns int
language plpgsql immutable as $$
declare l_value int;
begin
  l_value := case p_tier when 1 then p_rule.door when 2 then p_rule.conversation
    when 3 then p_rule.phone when 4 then p_rule.appointment else 0 end;
  if p_reduced and p_tier <= 2 then
    l_value := (l_value * p_rule.revisit_pct + 50) / 100;
  end if;
  return l_value;
end $$;

create function app.visit_points(p_visit bigint) returns int language sql stable as $$
  select coalesce(sum(amount), 0)::int from public.point_transactions where visit_id = p_visit
$$;

create function app.user_xp(p_user uuid) returns int language sql stable as $$
  select coalesce(sum(amount), 0)::int from public.point_transactions where user_id = p_user
$$;

create function app.level_info(p_xp int) returns jsonb language plpgsql immutable as $$
declare
  l_n int := 1;
  l_floor int;
  l_ceil int;
  l_titles text[] := array['Rookie', 'Verkenner', 'Deurklopper', 'Buurtkenner', 'Wijkspecialist',
                           'Straatkampioen', 'Topprospector', 'Meesterprospector', 'Legende'];
begin
  while p_xp >= 25 * (l_n + 1) * l_n loop l_n := l_n + 1; end loop;
  l_floor := 25 * l_n * (l_n - 1);
  l_ceil := 25 * (l_n + 1) * l_n;
  return jsonb_build_object('level', l_n, 'title', l_titles[least(l_n, 9)], 'xp', p_xp, 'floor', l_floor,
    'next', l_ceil, 'progress', greatest(0, round((p_xp - l_floor)::numeric / (l_ceil - l_floor), 3)));
end $$;

create function app.is_workday(p_user public.profiles, p_day date) returns boolean language sql immutable as $$
  select not (p_user.away_until is not null and p_day <= p_user.away_until)
     and position(extract(isodow from p_day)::int::text in coalesce(p_user.work_days, '12345')) > 0
$$;

-- ---------- Geschiktheid en punten ----------

create function app.eligibility(p_team public.teams, p_prospect bigint, p_date date, p_local timestamp, p_before bigint)
returns jsonb language plpgsql stable as $$
declare
  l_by text;
  l_date date;
  l_recent boolean;
begin
  select pr.name, v.visit_date into l_by, l_date
  from public.visits v join public.profiles pr on pr.id = v.user_id
  where v.prospect_id = p_prospect and v.id < p_before and not v.voided and v.awarded_tier > 0
    and v.visit_date between p_date - (p_team.revisit_cooldown_days - 1) and p_date
  order by v.visit_date desc limit 1;
  l_recent := found;
  return jsonb_build_object(
    'door', not l_recent,
    'phone', not exists (select 1 from public.visits where prospect_id = p_prospect and id < p_before
                         and not voided and awarded_tier >= 3),
    'appointment', not exists (select 1 from public.appointments a join public.visits v on v.id = a.visit_id
                               where a.prospect_id = p_prospect and v.id < p_before and not v.voided
                                 and a.status = 'planned' and a.starts_at >= p_local),
    'recent_by', l_by, 'recent_date', l_date);
end $$;

create function app.pick_tier(p_result text, p_el jsonb, p_known boolean, p_source text,
                              out tier int, out reduced boolean)
language plpgsql immutable as $$
declare l_rt int := app.tier(p_result);
begin
  if l_rt >= 4 and (p_el->>'appointment')::boolean then tier := 4; reduced := false; return; end if;
  if l_rt >= 3 and not coalesce(p_known, false) and (p_el->>'phone')::boolean then tier := 3; reduced := false; return; end if;
  tier := case when l_rt in (2, 4) or (l_rt = 3 and coalesce(p_source, 'direct') = 'direct') then 2 else 1 end;
  reduced := not (p_el->>'door')::boolean;
end $$;

create function app.eligible_tier(p_team public.teams, p_visit public.visits) returns jsonb
language plpgsql stable as $$
declare
  l_el jsonb := app.eligibility(p_team, p_visit.prospect_id, p_visit.visit_date,
                                p_visit.visited_at at time zone p_team.timezone, p_visit.id);
  l_tier int;
  l_reduced boolean;
  l_rt int := app.tier(p_visit.result);
  l_notes jsonb := '[]';
  l_rd date;
begin
  select t.tier, t.reduced into l_tier, l_reduced
  from app.pick_tier(p_visit.result, l_el, coalesce(p_visit.phone_status = 'known', false), p_visit.phone_source) t;
  if l_rt >= 4 and l_tier < 4 then
    l_notes := l_notes || to_jsonb('Er stond al een afspraak gepland voor dit adres: geen nieuwe afspraakbonus.'::text);
  end if;
  if l_rt = 3 and l_tier < 3 then
    l_notes := l_notes || to_jsonb(case when p_visit.phone_status = 'known'
      then 'Dit nummer was al bekend: geen nieuwe nummerbonus.'
      else 'Voor dit adres werd al eerder een nummer- of afspraakbonus toegekend.' end);
  end if;
  if l_reduced then
    l_rd := (l_el->>'recent_date')::date;
    l_notes := l_notes || to_jsonb(format('Herbezoek: hier werd op %s/%s al aangebeld. Je krijgt een deel van de punten; nieuwe deuren leveren meer op.',
                                          extract(day from l_rd)::int, extract(month from l_rd)::int));
  end if;
  return jsonb_build_object('tier', l_tier, 'reduced', l_reduced, 'notes', l_notes);
end $$;

create function app.recompute_points(p_team public.teams, p_visit bigint, p_actor uuid, p_kind text,
                                     p_reason text default null, p_detail text default null)
returns jsonb language plpgsql as $$
declare
  l_v public.visits;
  l_rule public.point_rules;
  l_r jsonb;
  l_tier int := 0;
  l_reduced boolean := false;
  l_notes jsonb := '[]';
  l_target int;
  l_delta int;
begin
  select * into l_v from public.visits where id = p_visit;
  if not l_v.voided then
    l_r := app.eligible_tier(p_team, l_v);
    l_tier := (l_r->>'tier')::int;
    l_reduced := (l_r->>'reduced')::boolean;
    l_notes := l_r->'notes';
  end if;
  select * into l_rule from public.point_rules where id = l_v.rule_id;
  l_target := app.tier_value(l_rule, l_tier, l_reduced);
  l_delta := l_target - app.visit_points(p_visit);
  update public.visits set awarded_tier = l_tier, reduced = l_reduced, updated_at = now() where id = p_visit;
  if l_delta <> 0 or p_kind in ('visit', 'correction', 'void') then
    insert into public.point_transactions (team_id, user_id, visit_id, amount, kind, detail, reason, created_by)
    values (l_v.team_id, l_v.user_id, p_visit, l_delta, p_kind, p_detail, p_reason, p_actor);
  end if;
  return jsonb_build_object('delta', l_delta, 'target', l_target, 'tier', l_tier, 'notes', l_notes);
end $$;

-- ---------- Adressen / prospecten ----------

create function app.match_keys(p_street text, p_number text, p_postcode text, p_municipality text) returns text[]
language sql immutable as $$
  select array[
    app.address_key(format('%s %s, %s %s', p_street, p_number, p_postcode, p_municipality)),
    app.address_key(format('%s %s, %s', p_street, p_number, p_municipality)),
    app.address_key(format('%s %s', p_street, p_number))]
$$;

create function app.find_or_create_prospect(p_user public.profiles, p_address text, p_name text,
  p_ref bigint default null, p_lat double precision default null, p_lon double precision default null,
  p_extra_keys text[] default '{}') returns public.prospects
language plpgsql as $$
declare
  l_address text := app.clean_text(p_address, 'Adres', 160, true);
  l_name text := app.clean_text(p_name, 'Naam', 80);
  l_key text;
  l_p public.prospects;
begin
  if length(l_address) < 3 then perform app.fail('Adres is te kort.'); end if;
  l_key := app.address_key(l_address);
  if p_ref is not null then
    select * into l_p from public.prospects where team_id = p_user.team_id and address_ref = p_ref limit 1;
  end if;
  if l_p.id is null then
    select * into l_p from public.prospects
    where team_id = p_user.team_id and address_key = any (array_append(p_extra_keys, l_key)) limit 1;
  end if;
  if l_p.id is not null then
    if l_name is not null and l_p.name is null then
      update public.prospects set name = l_name where id = l_p.id returning * into l_p;
    end if;
    if p_ref is not null and l_p.address_ref is null then
      update public.prospects set address_ref = p_ref, lat = p_lat, lon = p_lon where id = l_p.id returning * into l_p;
    end if;
    return l_p;
  end if;
  insert into public.prospects (team_id, address, address_key, name, created_by, address_ref, lat, lon)
  values (p_user.team_id, l_address, l_key, l_name, p_user.id, p_ref, p_lat, p_lon)
  returning * into l_p;
  return l_p;
end $$;

create function app.resolve_prospect(p_user public.profiles, p_data jsonb) returns public.prospects
language plpgsql as $$
declare
  l_p public.prospects;
  l_new jsonb := p_data->'new_prospect';
  l_a public.addresses;
  l_lat double precision;
  l_lon double precision;
begin
  if p_data ? 'prospect_id' and p_data->>'prospect_id' is not null then
    if p_data->>'prospect_id' !~ '^\d+$' then perform app.fail('Ongeldig adres.'); end if;
    select * into l_p from public.prospects where id = (p_data->>'prospect_id')::bigint and team_id = p_user.team_id;
    if not found then perform app.fail('Adres niet gevonden.', 'not_found'); end if;
    return l_p;
  end if;
  if jsonb_typeof(l_new) is distinct from 'object' then perform app.fail('Kies een adres of voeg er een toe.'); end if;
  if coalesce(l_new->>'address_ref', '') ~ '^\d+$' then
    select * into l_a from public.addresses where team_id = p_user.team_id and id = (l_new->>'address_ref')::bigint;
    if found then
      return app.find_or_create_prospect(p_user, l_a.label, l_new->>'name', l_a.id, l_a.lat, l_a.lon,
                                         app.match_keys(l_a.street, l_a.number, l_a.postcode, l_a.municipality));
    end if;
  end if;
  if jsonb_typeof(l_new->'lat') = 'number' and jsonb_typeof(l_new->'lon') = 'number' then
    l_lat := (l_new->>'lat')::double precision;
    l_lon := (l_new->>'lon')::double precision;
    if not (l_lat between 49.4 and 51.6 and l_lon between 2.4 and 6.5) then l_lat := null; l_lon := null; end if;
  end if;
  return app.find_or_create_prospect(p_user, l_new->>'address', l_new->>'name', null, l_lat, l_lon);
end $$;

create function app.set_do_not_contact(p_prospect bigint, p_value boolean) returns void
language plpgsql as $$
begin
  update public.prospects set do_not_contact = p_value where id = p_prospect;
  if p_value then
    update public.follow_ups set status = 'cancelled', done_at = now() where prospect_id = p_prospect and status = 'open';
  end if;
end $$;

-- ---------- Bezoeken ----------

create function app.visit_time(p_raw text, p_backdate boolean) returns timestamptz
language plpgsql stable as $$
declare l_ts timestamptz;
begin
  if p_raw is null or p_raw = '' then return now(); end if;
  begin
    l_ts := p_raw::timestamptz;
  exception when others then
    return now();
  end;
  if p_backdate then return l_ts; end if;
  -- Offline registraties komen soms later binnen: tot 72 u terug, nooit in de toekomst.
  if l_ts > now() + interval '5 minutes' or l_ts < now() - interval '72 hours' then return now(); end if;
  return date_trunc('second', l_ts);
end $$;

create function app.apply_details(p_team public.teams, p_visit public.visits, p_result text, p_flyer boolean,
                                  p_phone jsonb, p_appt jsonb) returns void
language plpgsql as $$
declare
  l_tier int := app.tier(p_result);
  l_status text := p_visit.phone_status;
  l_source text := p_visit.phone_source;
  l_number text;
  l_norm text;
  l_existing public.phones;
  l_a public.appointments;
  l_day date;
  l_time text;
  l_note text;
  l_starts timestamp;
begin
  if l_tier >= 3 then
    if jsonb_typeof(p_phone) = 'object' and coalesce(p_phone->>'source', '') <> '' then
      if p_phone->>'source' not in ('direct', 'neighbour', 'other') then perform app.fail('Ongeldige bron voor het nummer.'); end if;
      l_source := p_phone->>'source';
    end if;
    l_source := coalesce(l_source, 'direct');
    l_number := case when jsonb_typeof(p_phone) = 'object' then btrim(coalesce(p_phone->>'number', '')) else '' end;
    if l_number <> '' then
      l_norm := app.normalize_phone(l_number);
      select * into l_existing from public.phones where prospect_id = p_visit.prospect_id and number = l_norm;
      if found then
        l_status := case when l_existing.visit_id = p_visit.id then 'stored' else 'known' end;
        if l_existing.visit_id = p_visit.id and l_existing.source <> l_source then
          update public.phones set source = l_source where id = l_existing.id;
        end if;
      else
        insert into public.phones (prospect_id, number, source, visit_id) values (p_visit.prospect_id, l_norm, l_source, p_visit.id);
        l_status := 'stored';
      end if;
    elsif l_status is null or l_status not in ('stored', 'known') then
      l_status := 'not_stored';
    end if;
  else
    delete from public.phones where visit_id = p_visit.id;
    l_status := null;
    l_source := null;
  end if;

  select * into l_a from public.appointments where visit_id = p_visit.id;
  if l_tier = 4 then
    if l_a.id is null or (jsonb_typeof(p_appt) = 'object'
                          and (coalesce(p_appt->>'date', '') <> '' or coalesce(p_appt->>'time', '') <> '')) then
      begin
        l_day := (p_appt->>'date')::date;
      exception when others then
        l_day := null;
      end;
      l_time := coalesce(p_appt->>'time', '');
      if l_day is null or l_time !~ '^([01]\d|2[0-3]):[0-5]\d$' then
        perform app.fail('Kies een datum en tijd voor de afspraak.');
      end if;
      if l_day < p_visit.visit_date or l_day > p_visit.visit_date + 366 then
        perform app.fail('De afspraakdatum ligt niet in de verwachte periode.');
      end if;
      l_starts := (l_day::text || ' ' || l_time)::timestamp;
      l_note := app.clean_text(p_appt->>'note', 'Notitie', 280);
      if l_a.id is not null then
        update public.appointments set starts_at = l_starts, note = l_note, status = 'planned' where id = l_a.id;
      else
        insert into public.appointments (team_id, prospect_id, user_id, visit_id, starts_at, note)
        values (p_visit.team_id, p_visit.prospect_id, p_visit.user_id, p_visit.id, l_starts, l_note);
      end if;
    elsif l_a.status <> 'planned' then
      update public.appointments set status = 'planned' where id = l_a.id;
    end if;
  elsif l_a.id is not null and l_a.status = 'planned' then
    update public.appointments set status = 'cancelled' where id = l_a.id;
  end if;

  update public.visits set result = p_result, flyer = coalesce(p_flyer, false), phone_status = l_status,
    phone_source = l_source, updated_at = now() where id = p_visit.id;
end $$;

create function app.visit_public(p_visit public.visits) returns jsonb language sql stable as $$
  select jsonb_build_object(
    'id', p_visit.id, 'prospect_id', p_visit.prospect_id, 'address', p.address, 'name', p.name,
    'result', p_visit.result, 'flyer', p_visit.flyer, 'phone_status', p_visit.phone_status,
    'phone_source', p_visit.phone_source, 'reduced', p_visit.reduced,
    'phone', (select jsonb_build_object('number', app.format_phone(ph.number), 'source', ph.source)
              from public.phones ph where ph.visit_id = p_visit.id order by ph.id desc limit 1),
    'appointment', (select jsonb_build_object('starts_at', to_char(a.starts_at, 'YYYY-MM-DD"T"HH24:MI'),
                                              'note', a.note, 'status', a.status)
                    from public.appointments a where a.visit_id = p_visit.id),
    'awarded', app.tier_name(p_visit.awarded_tier), 'points', app.visit_points(p_visit.id),
    'visit_date', p_visit.visit_date, 'visited_at', p_visit.visited_at, 'voided', p_visit.voided,
    'user_id', p_visit.user_id)
  from public.prospects p where p.id = p_visit.prospect_id
$$;

-- ---------- Statistieken en ranking ----------

create function app.period_stats(p_team bigint, p_d1 date, p_d2 date)
returns table (user_id uuid, points int, doors int, conversations int, phones int, appointments int)
language sql stable as $$
  select pr.id, coalesce(tx.points, 0)::int, coalesce(vs.doors, 0)::int, coalesce(vs.conv, 0)::int,
         coalesce(vs.phones, 0)::int, coalesce(vs.appts, 0)::int
  from public.profiles pr
  left join (select t.user_id, sum(t.amount) as points from public.point_transactions t
             join public.visits v on v.id = t.visit_id
             where t.team_id = p_team and v.visit_date between p_d1 and p_d2 group by t.user_id) tx on tx.user_id = pr.id
  left join (select v.user_id, count(*) as doors,
                    count(*) filter (where v.result in ('conversation', 'appointment')
                                       or (v.result = 'phone' and v.phone_source = 'direct')) as conv,
                    count(*) filter (where v.result = 'phone' or v.phone_status = 'stored') as phones,
                    count(*) filter (where v.result = 'appointment') as appts
             from public.visits v
             where v.team_id = p_team and not v.voided and v.visit_date between p_d1 and p_d2
             group by v.user_id) vs on vs.user_id = pr.id
  where pr.team_id = p_team
$$;

create function app.day_stats(p_team public.teams, p_user public.profiles, p_day date) returns jsonb
language sql stable as $$
  select jsonb_build_object('date', p_day, 'doors', coalesce(s.doors, 0), 'points', coalesce(s.points, 0),
    'conversations', coalesce(s.conversations, 0), 'phones', coalesce(s.phones, 0),
    'appointments', coalesce(s.appointments, 0), 'goal', p_user.daily_goal, 'workday', app.is_workday(p_user, p_day))
  from (select 1) one
  left join app.period_stats(p_team.id, p_day, p_day) s on s.user_id = p_user.id
$$;

create function app.active_competition(p_team public.teams) returns public.competitions language sql stable as $$
  select * from public.competitions
  where team_id = p_team.id and starts_on <= app.today(p_team) and ends_on >= app.today(p_team)
  order by id desc limit 1
$$;

create function app.leaderboard(p_team public.teams, p_me public.profiles, p_period text, p_sort text) returns jsonb
language plpgsql stable as $$
declare
  l_d date := app.today(p_team);
  l_d1 date;
  l_d2 date;
  l_label text;
  l_comp public.competitions;
  l_entries jsonb;
  l_me jsonb;
  l_team jsonb;
begin
  if p_sort is null or p_sort not in ('points', 'doors') then p_sort := 'points'; end if;
  if p_period = 'month' then
    l_d1 := date_trunc('month', l_d)::date;
    l_d2 := (date_trunc('month', l_d) + interval '1 month - 1 day')::date;
    l_label := to_char(l_d1, 'MM/YYYY');
  elsif p_period = 'competition' then
    l_comp := app.active_competition(p_team);
    if l_comp.id is null then
      return jsonb_build_object('period', p_period, 'sort', p_sort, 'entries', '[]'::jsonb, 'me', null,
        'competition', null, 'team', jsonb_build_object('points', 0, 'doors', 0, 'conversations', 0, 'phones', 0, 'appointments', 0));
    end if;
    l_d1 := l_comp.starts_on;
    l_d2 := l_comp.ends_on;
    l_label := l_comp.name;
  else
    p_period := 'week';
    l_d1 := app.week_start(l_d);
    l_d2 := l_d1 + 6;
    l_label := 'Deze week';
  end if;

  with e as (
    select pr.id, pr.name, pr.color, s.points, s.doors, s.conversations, s.phones, s.appointments,
           pr.id = p_me.id as is_me
    from public.profiles pr
    join app.period_stats(p_team.id, l_d1, least(l_d2, l_d)) s on s.user_id = pr.id
    where pr.team_id = p_team.id and pr.active
      and (l_comp.id is null or exists (select 1 from public.competition_participants cp
                                        where cp.competition_id = l_comp.id and cp.user_id = pr.id))
  ), r as (
    select e.*, rank() over (order by case when p_sort = 'doors' then e.doors else e.points end desc) as rank from e
  )
  select coalesce(jsonb_agg(to_jsonb(r) order by r.rank, lower(r.name)), '[]'::jsonb),
         jsonb_build_object('points', coalesce(sum(r.points), 0), 'doors', coalesce(sum(r.doors), 0),
           'conversations', coalesce(sum(r.conversations), 0), 'phones', coalesce(sum(r.phones), 0),
           'appointments', coalesce(sum(r.appointments), 0))
  into l_entries, l_team from r;

  select x.v into l_me from jsonb_array_elements(l_entries) as x(v) where (x.v->>'is_me')::boolean limit 1;
  return jsonb_build_object('period', p_period, 'sort', p_sort, 'label', l_label, 'from', l_d1, 'to', l_d2,
    'entries', l_entries, 'me', l_me, 'team', l_team,
    'competition', case when l_comp.id is null then null
                        else to_jsonb(l_comp) || jsonb_build_object('days_left', l_d2 - l_d) end);
end $$;

create function app.my_week_rank(p_team public.teams, p_me public.profiles) returns int
language sql stable as $$
  select (app.leaderboard(p_team, p_me, 'week', 'points')->'me'->>'rank')::int
$$;

-- ---------- Badges ----------

create function app.badge_defs() returns jsonb language sql immutable as $$
  select '[
    {"key": "first_door", "icon": "door", "name": "Eerste deur", "desc": "Eerste bezoek geregistreerd"},
    {"key": "on_the_move", "icon": "steps", "name": "Op gang", "desc": "Tien deuren bezocht"},
    {"key": "icebreaker", "icon": "chat", "name": "IJsbreker", "desc": "Eerste gesprek gevoerd"},
    {"key": "contact", "icon": "phone", "name": "Contact gelegd", "desc": "Eerste telefoonnummer gekregen"},
    {"key": "agenda", "icon": "calendar", "name": "Agenda gevuld", "desc": "Eerste afspraak vastgelegd"},
    {"key": "scout", "icon": "star", "name": "Kansenspotter", "desc": "Eerste opvolging genoteerd"},
    {"key": "persistent", "icon": "medal", "name": "Doorzetter", "desc": "Honderd unieke adressen bezocht"},
    {"key": "together", "icon": "team", "name": "Samen op pad", "desc": "Bijgedragen aan een teamdoel"},
    {"key": "challenger", "icon": "target", "name": "Uitdaging gehaald", "desc": "Eerste uitdaging voltooid"}
  ]'::jsonb
$$;

create function app.badge(p_key text) returns jsonb language sql immutable as $$
  select b.v from jsonb_array_elements(app.badge_defs()) as b(v) where b.v->>'key' = p_key
$$;

create function app.award_badge(p_user uuid, p_key text) returns boolean language plpgsql as $$
declare l_n int;
begin
  insert into public.user_badges (user_id, badge) values (p_user, p_key) on conflict do nothing;
  get diagnostics l_n = row_count;
  return l_n = 1;
end $$;

create function app.lifetime(p_user uuid) returns jsonb language sql stable as $$
  select jsonb_build_object(
    'doors', count(*), 'unique_doors', count(distinct prospect_id),
    'conversations', count(*) filter (where result in ('conversation', 'appointment') or (result = 'phone' and phone_source = 'direct')),
    'phones', count(*) filter (where result = 'phone' or phone_status = 'stored'),
    'appointments', count(*) filter (where result = 'appointment'),
    'follow_ups', (select count(*) from public.follow_ups f where f.user_id = p_user))
  from public.visits where user_id = p_user and not voided
$$;

create function app.evaluate_badges(p_team public.teams, p_user public.profiles) returns jsonb
language plpgsql as $$
declare
  l_life jsonb := app.lifetime(p_user.id);
  l_out jsonb := '[]';
  l_key text;
  l_ok boolean;
begin
  foreach l_key in array array['first_door', 'on_the_move', 'icebreaker', 'contact', 'agenda', 'scout', 'persistent', 'together'] loop
    l_ok := case l_key
      when 'first_door' then (l_life->>'doors')::int >= 1
      when 'on_the_move' then (l_life->>'doors')::int >= 10
      when 'icebreaker' then (l_life->>'conversations')::int >= 1
      when 'contact' then (l_life->>'phones')::int >= 1
      when 'agenda' then (l_life->>'appointments')::int >= 1
      when 'scout' then (l_life->>'follow_ups')::int >= 1
      when 'persistent' then (l_life->>'unique_doors')::int >= 100
      when 'together' then (l_life->>'doors')::int >= 1 and exists (
        select 1 from public.challenges where team_id = p_team.id and scope = 'team' and active)
    end;
    if l_ok and app.award_badge(p_user.id, l_key) then l_out := l_out || app.badge(l_key); end if;
  end loop;
  return l_out;
end $$;

-- ---------- Uitdagingen ----------

create function app.metric_count(p_team bigint, p_metric text, p_d1 date, p_d2 date, p_user uuid) returns int
language sql stable as $$
  select count(*)::int from public.visits v
  where v.team_id = p_team and not v.voided and v.visit_date between p_d1 and p_d2
    and (p_user is null or v.user_id = p_user)
    and case p_metric
      when 'new_doors' then not exists (select 1 from public.visits o where o.prospect_id = v.prospect_id
                                        and not o.voided and o.id < v.id)
      when 'phones' then coalesce(v.result = 'phone' or v.phone_status = 'stored', false)
      when 'appointments' then v.result = 'appointment'
      else true end
$$;

create function app.challenges_progress(p_team public.teams, p_user public.profiles) returns jsonb
language sql stable as $$
  with d as (select app.today(p_team) as day),
  c as (
    select ch.*, case when ch.period = 'day' then d.day else app.week_start(d.day) end as d1,
                 case when ch.period = 'day' then d.day else app.week_start(d.day) + 6 end as d2
    from public.challenges ch, d where ch.team_id = p_team.id and ch.active
  ), p as (
    select c.*, app.metric_count(p_team.id, c.metric, c.d1, c.d2,
                                 case when c.scope = 'personal' then p_user.id end) as progress from c
  )
  select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'title', p.title, 'metric', p.metric, 'period', p.period,
    'scope', p.scope, 'target', p.target, 'progress', p.progress, 'done', p.progress >= p.target,
    'period_key', p.d1, 'ends', p.d2) order by p.id), '[]'::jsonb)
  from p
$$;

create function app.check_challenges(p_team public.teams, p_user public.profiles) returns jsonb
language plpgsql as $$
declare
  l_c jsonb;
  l_out jsonb := '[]';
  l_n int;
begin
  for l_c in select x.v from jsonb_array_elements(app.challenges_progress(p_team, p_user)) as x(v) loop
    continue when not (l_c->>'done')::boolean;
    insert into public.challenge_completions (challenge_id, subject, period_key)
    values ((l_c->>'id')::bigint, case when l_c->>'scope' = 'personal' then p_user.id::text else 'team' end,
            (l_c->>'period_key')::date)
    on conflict do nothing;
    get diagnostics l_n = row_count;
    if l_n = 1 then
      l_out := l_out || jsonb_build_object('id', l_c->'id', 'title', l_c->'title', 'scope', l_c->'scope');
    end if;
  end loop;
  return l_out;
end $$;

-- ---------- Rondes ----------

create function app.round_stats(p_round public.rounds) returns jsonb language sql stable as $$
  select jsonb_build_object(
    'id', p_round.id, 'goal', p_round.goal, 'started_at', p_round.started_at, 'ended_at', p_round.ended_at,
    'minutes', greatest(0, floor(extract(epoch from (coalesce(p_round.ended_at, now()) - p_round.started_at)) / 60))::int,
    'doors', count(v.id),
    'conversations', count(v.id) filter (where v.result in ('conversation', 'appointment') or (v.result = 'phone' and v.phone_source = 'direct')),
    'phones', count(v.id) filter (where v.result = 'phone' or v.phone_status = 'stored'),
    'appointments', count(v.id) filter (where v.result = 'appointment'),
    'flyers', count(v.id) filter (where v.flyer),
    'points', (select coalesce(sum(t.amount), 0) from public.point_transactions t
               join public.visits x on x.id = t.visit_id where x.round_id = p_round.id))
  from public.visits v where v.round_id = p_round.id and not v.voided
$$;

create function app.round_message(p_s jsonb) returns text language plpgsql immutable as $$
declare
  l_doors int := (p_s->>'doors')::int;
  l_appts int := (p_s->>'appointments')::int;
  l_phones int := (p_s->>'phones')::int;
begin
  if l_doors = 0 then return 'Geen deuren deze keer. De volgende ronde begint met één deur.'; end if;
  if l_appts > 0 then return format('Topronde! %s %s vastgelegd.', l_appts, case when l_appts > 1 then 'afspraken' else 'afspraak' end); end if;
  if l_doors >= (p_s->>'goal')::int then return format('Doel gehaald: %s deuren. Sterk werk!', l_doors); end if;
  if l_phones > 0 then return format('Mooi: %s %s. Elke deur telt.', l_phones, case when l_phones > 1 then 'nieuwe contacten' else 'nieuw contact' end); end if;
  return format('%s deuren bezocht. Elke deur brengt je dichter bij een afspraak.', l_doors);
end $$;

-- ---------- Opvolgingen ----------

create function app.signal_label(p_signal text) returns text language sql immutable as $$
  select case p_signal when 'sell' then 'Verkoopplannen' when 'buy' then 'Koopplannen' when 'move' then 'Verhuisplannen'
    when 'valuation' then 'Wil een schatting' when 'rent' then 'Verhuurplannen' else 'Andere kans' end
$$;

create function app.horizon_label(p_horizon text) returns text language sql immutable as $$
  select case p_horizon when 'now' then 'Nu / binnen 6 maanden' when 'lt1' then 'Binnen 1 jaar'
    when '1to2' then '1 à 2 jaar' when '2to5' then '2 à 5 jaar' when 'gt5' then 'Over 5 jaar of later' end
$$;

create function app.follow_up_public(p_id bigint) returns jsonb language sql stable as $$
  select jsonb_build_object('id', f.id, 'prospect_id', f.prospect_id, 'user_id', f.user_id, 'visit_id', f.visit_id,
    'signal', f.signal, 'horizon', f.horizon, 'due_on', f.due_on, 'note', f.note, 'status', f.status,
    'created_at', f.created_at, 'done_at', f.done_at, 'address', p.address, 'prospect_name', p.name, 'owner', u.name,
    'signal_label', app.signal_label(f.signal), 'horizon_label', app.horizon_label(f.horizon),
    'phone', (select app.format_phone(ph.number) from public.phones ph where ph.prospect_id = p.id order by ph.id desc limit 1))
  from public.follow_ups f join public.prospects p on p.id = f.prospect_id join public.profiles u on u.id = f.user_id
  where f.id = p_id
$$;

create function app.due_date(p_team public.teams, p_data jsonb, p_horizon text) returns date
language plpgsql stable as $$
declare
  l_today date := app.today(p_team);
  l_due date;
begin
  if coalesce(p_data->>'due_on', '') <> '' then
    begin
      l_due := (p_data->>'due_on')::date;
    exception when others then
      perform app.fail('Ongeldige opvolgdatum.');
    end;
    if l_due < l_today or l_due > l_today + 366 * 6 then
      perform app.fail('Kies een opvolgdatum tussen vandaag en binnen 6 jaar.');
    end if;
    return l_due;
  end if;
  return l_today + case coalesce(p_horizon, 'lt1') when 'now' then 7 when 'lt1' then 30 when '1to2' then 90
                                                   when '2to5' then 180 else 365 end;
end $$;

create function app.create_follow_up(p_user public.profiles, p_prospect bigint, p_data jsonb, p_visit bigint default null)
returns jsonb language plpgsql as $$
declare
  l_team public.teams;
  l_p public.prospects;
  l_horizon text := nullif(p_data->>'horizon', '');
  l_id bigint;
begin
  if jsonb_typeof(p_data) is distinct from 'object' then perform app.fail('Ongeldige opvolging.'); end if;
  select * into l_team from public.teams where id = p_user.team_id;
  select * into l_p from public.prospects where id = p_prospect and team_id = p_user.team_id;
  if not found then perform app.fail('Adres niet gevonden.', 'not_found'); end if;
  if l_p.do_not_contact then perform app.fail('Dit adres staat op ‘Niet meer contacteren’.', 'do_not_contact'); end if;
  if coalesce(p_data->>'signal', '') not in ('sell', 'buy', 'move', 'valuation', 'rent', 'other') then
    perform app.fail('Kies wat er interessant is.');
  end if;
  if l_horizon is not null and l_horizon not in ('now', 'lt1', '1to2', '2to5', 'gt5') then
    perform app.fail('Ongeldige termijn.');
  end if;
  insert into public.follow_ups (team_id, prospect_id, user_id, visit_id, signal, horizon, due_on, note)
  values (p_user.team_id, p_prospect, p_user.id, p_visit, p_data->>'signal', l_horizon,
          app.due_date(l_team, p_data, l_horizon), app.clean_text(p_data->>'note', 'Notitie', 280))
  returning id into l_id;
  return app.follow_up_public(l_id);
end $$;

create function app.list_follow_ups(p_team public.teams, p_user public.profiles, p_scope text, p_status text,
                                    p_prospect bigint default null) returns jsonb
language sql stable as $$
  select coalesce(jsonb_agg(app.follow_up_public(f.id) order by f.status = 'open' desc, f.due_on, f.id), '[]'::jsonb)
  from (select * from public.follow_ups f
        where f.team_id = p_team.id
          and (p_prospect is null or f.prospect_id = p_prospect)
          and (p_prospect is not null or p_scope = 'team' or f.user_id = p_user.id)
          and (p_status is null or f.status = p_status)
        order by f.status = 'open' desc, f.due_on, f.id limit 300) f
$$;

create function app.follow_up_summary(p_team public.teams, p_user public.profiles) returns jsonb
language plpgsql stable as $$
declare
  l_today date := app.today(p_team);
  l_items jsonb := app.list_follow_ups(p_team, p_user, 'mine', 'open');
  l_due jsonb;
begin
  select coalesce(jsonb_agg(x.v), '[]'::jsonb) into l_due
  from jsonb_array_elements(l_items) as x(v) where (x.v->>'due_on')::date <= l_today + 7;
  return jsonb_build_object('open', jsonb_array_length(l_items), 'due', jsonb_array_length(l_due),
    'overdue', (select count(*) from jsonb_array_elements(l_items) as x(v) where (x.v->>'due_on')::date < l_today),
    'items', (select coalesce(jsonb_agg(s.v), '[]'::jsonb) from (select x.v from jsonb_array_elements(l_due) as x(v) limit 3) s),
    'today', l_today);
end $$;

-- ---------- Terugkoppeling na registratie ----------

create function app.feedback(p_team public.teams, p_owner public.profiles, p_visit public.visits, p_delta int,
  p_notes jsonb, p_merged boolean, p_already boolean, p_xp_before int, p_rank_before int, p_follow_up jsonb)
returns jsonb language plpgsql as $$
declare
  l_xp int := app.user_xp(p_owner.id);
  l_level jsonb := app.level_info(l_xp);
  l_badges jsonb := app.evaluate_badges(p_team, p_owner);
  l_done jsonb := app.check_challenges(p_team, p_owner);
  l_round public.rounds;
begin
  if jsonb_array_length(l_done) > 0 and app.award_badge(p_owner.id, 'challenger') then
    l_badges := l_badges || app.badge('challenger');
  end if;
  select * into l_round from public.rounds where user_id = p_owner.id and ended_at is null order by id desc limit 1;
  return jsonb_build_object(
    'visit', app.visit_public(p_visit), 'points', p_delta, 'visit_points', app.visit_points(p_visit.id),
    'notes', p_notes, 'merged', p_merged, 'already_saved', p_already,
    'today', app.day_stats(p_team, p_owner, app.today(p_team)),
    'rank', jsonb_build_object('before', p_rank_before, 'after', app.my_week_rank(p_team, p_owner)),
    'level', l_level,
    'level_up', p_xp_before is not null and (app.level_info(p_xp_before)->>'level')::int < (l_level->>'level')::int,
    'new_badges', l_badges, 'completed_challenges', l_done,
    'round', case when l_round.id is null then null else app.round_stats(l_round) end,
    'follow_up', p_follow_up, 'reduced', p_visit.reduced);
end $$;

-- ---------- Bezoek registreren / aanpassen / schrappen ----------

create function app.register_visit(p_user public.profiles, p_data jsonb, p_backdate boolean default false)
returns jsonb language plpgsql as $$
declare
  l_team public.teams;
  l_client text := coalesce(p_data->>'client_id', '');
  l_existing public.visits;
  l_result text;
  l_p public.prospects;
  l_ts timestamptz;
  l_date date;
  l_xp_before int;
  l_rank_before int;
  l_same public.visits;
  l_v public.visits;
  l_new_result text;
  l_r jsonb;
  l_notes jsonb;
  l_merged boolean := false;
  l_round bigint;
  l_vid bigint;
  l_fu jsonb;
  l_dnc boolean := coalesce((p_data->>'do_not_contact')::boolean, false);
  l_flyer boolean := coalesce((p_data->>'flyer')::boolean, false);
begin
  select * into l_team from public.teams where id = p_user.team_id;
  if l_client !~ '^[A-Za-z0-9\-]{8,64}$' then perform app.fail('Ontbrekende registratiesleutel.'); end if;
  -- Eén registratie tegelijk per gebruiker: dubbel tikken of parallel versturen levert één bezoek op.
  perform pg_advisory_xact_lock(hashtextextended('nod-user:' || p_user.id::text, 0));
  select * into l_existing from public.visits where client_id = l_client;
  if found then
    if l_existing.user_id <> p_user.id then perform app.fail('Registratiesleutel al in gebruik.'); end if;
    return app.feedback(l_team, p_user, l_existing, 0, '[]', false, true, null, null, null);
  end if;

  l_result := app.check_result(p_data->>'result');
  l_p := app.resolve_prospect(p_user, p_data);
  if l_p.do_not_contact then perform app.fail('Dit adres staat op ‘Niet meer contacteren’.', 'do_not_contact'); end if;
  perform pg_advisory_xact_lock(hashtextextended('nod-prospect:' || l_p.id::text, 0));

  l_ts := app.visit_time(p_data->>'visited_at', p_backdate);
  l_date := (l_ts at time zone l_team.timezone)::date;
  l_xp_before := app.user_xp(p_user.id);
  l_rank_before := app.my_week_rank(l_team, p_user);

  select * into l_same from public.visits
  where user_id = p_user.id and prospect_id = l_p.id and visit_date = l_date and not voided;
  if found then
    l_new_result := case when app.tier(l_same.result) >= app.tier(l_result) then l_same.result else l_result end;
    perform app.apply_details(l_team, l_same, l_new_result, l_same.flyer or l_flyer, p_data->'phone', p_data->'appointment');
    l_r := app.recompute_points(l_team, l_same.id, p_user.id, 'upgrade', null,
      case when l_new_result <> l_same.result then app.result_label(l_same.result) || ' → ' || app.result_label(l_new_result)
           else 'Opnieuw opgeslagen' end);
    l_notes := jsonb_build_array('Je had dit adres vandaag al geregistreerd: het bezoek is bijgewerkt.') || (l_r->'notes');
    l_vid := l_same.id;
    l_merged := true;
  else
    select id into l_round from public.rounds where user_id = p_user.id and ended_at is null order by id desc limit 1;
    insert into public.visits (team_id, user_id, prospect_id, round_id, client_id, visited_at, visit_date, result, flyer, rule_id)
    values (p_user.team_id, p_user.id, l_p.id, l_round, l_client, l_ts, l_date, l_result, l_flyer,
            (app.current_rule(p_user.team_id)).id)
    returning * into l_v;
    perform app.apply_details(l_team, l_v, l_result, l_flyer, p_data->'phone', p_data->'appointment');
    l_r := app.recompute_points(l_team, l_v.id, p_user.id, 'visit', null, app.result_label(l_result));
    l_notes := l_r->'notes';
    l_vid := l_v.id;
  end if;

  if jsonb_typeof(p_data->'follow_up') = 'object' then
    if l_dnc then perform app.fail('Een opvolging kan niet samen met ‘Niet meer contacteren’.'); end if;
    l_fu := app.create_follow_up(p_user, l_p.id, p_data->'follow_up', l_vid);
  end if;
  if l_dnc then perform app.set_do_not_contact(l_p.id, true); end if;

  select * into l_v from public.visits where id = l_vid;
  return app.feedback(l_team, p_user, l_v, (l_r->>'delta')::int, l_notes, l_merged, false,
                      l_xp_before, l_rank_before, l_fu);
end $$;

create function app.edit_visit(p_actor public.profiles, p_visit bigint, p_data jsonb) returns jsonb
language plpgsql as $$
declare
  l_team public.teams;
  l_v public.visits;
  l_owner public.profiles;
  l_reason text := app.clean_text(p_data->>'reason', 'Reden', 200);
  l_result text;
  l_kind text;
  l_xp_before int;
  l_rank_before int;
  l_r jsonb;
begin
  select * into l_team from public.teams where id = p_actor.team_id;
  select * into l_v from public.visits where id = p_visit and team_id = p_actor.team_id;
  if not found then perform app.fail('Bezoek niet gevonden.', 'not_found'); end if;
  if l_v.voided then perform app.fail('Dit bezoek is geschrapt.'); end if;
  perform pg_advisory_xact_lock(hashtextextended('nod-prospect:' || l_v.prospect_id::text, 0));
  if not (l_v.user_id = p_actor.id and l_v.visit_date >= app.today(l_team) - 7) then
    if p_actor.role <> 'admin' then perform app.fail('Je kan alleen je eigen recente bezoeken aanpassen.', 'forbidden'); end if;
    if l_reason is null or length(l_reason) < 3 then perform app.fail('Geef een reden voor de correctie.'); end if;
  end if;
  l_result := app.check_result(coalesce(nullif(p_data->>'result', ''), l_v.result));
  select * into l_owner from public.profiles where id = l_v.user_id;
  l_xp_before := app.user_xp(l_owner.id);
  l_rank_before := app.my_week_rank(l_team, l_owner);
  perform app.apply_details(l_team, l_v, l_result,
    case when p_data ? 'flyer' then coalesce((p_data->>'flyer')::boolean, false) else l_v.flyer end,
    p_data->'phone', p_data->'appointment');
  l_kind := case when l_reason is not null then 'correction'
                 when app.tier(l_result) >= app.tier(l_v.result) then 'upgrade' else 'correction' end;
  l_r := app.recompute_points(l_team, l_v.id, p_actor.id, l_kind,
    coalesce(l_reason, case when l_kind = 'correction' then 'Eigen aanpassing' end),
    case when l_result <> l_v.result then app.result_label(l_v.result) || ' → ' || app.result_label(l_result)
         else 'Details aangepast' end);
  select * into l_v from public.visits where id = p_visit;
  return app.feedback(l_team, l_owner, l_v, (l_r->>'delta')::int, l_r->'notes', false, false,
                      l_xp_before, l_rank_before, null);
end $$;

-- ---------- Prospectlijst en detail ----------

create function app.prospect_rows(p_team bigint, p_q text default null, p_id bigint default null) returns jsonb
language sql stable as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', p.id, 'address', p.address, 'name', p.name, 'note', p.note, 'do_not_contact', p.do_not_contact,
      'address_ref', p.address_ref, 'lat', p.lat, 'lon', p.lon,
      'best', app.tier_name(b.best),
      'last_visit', case when lv.visit_date is null then null
                         else jsonb_build_object('date', lv.visit_date, 'result', lv.result, 'by', lv.name) end,
      'phone', case when ph.number is null then null
                    else jsonb_build_object('number', app.format_phone(ph.number), 'source', ph.source) end,
      'appointment', (select to_char(a.starts_at, 'YYYY-MM-DD"T"HH24:MI') from public.appointments a
                      where a.prospect_id = p.id and a.status = 'planned' order by a.starts_at desc limit 1),
      'follow_up', (select jsonb_build_object('due_on', f.due_on, 'signal', f.signal) from public.follow_ups f
                    where f.prospect_id = p.id and f.status = 'open' order by f.due_on limit 1))
    order by p.do_not_contact,
             coalesce(substring(lower(p.address) from '^(\D*)'), lower(p.address)),
             coalesce(substring(p.address from '(\d+)')::int, 0), lower(p.address)), '[]'::jsonb)
  from public.prospects p
  left join lateral (select max(app.tier(v.result)) as best from public.visits v
                     where v.prospect_id = p.id and not v.voided) b on true
  left join lateral (select v.visit_date, v.result, u.name from public.visits v join public.profiles u on u.id = v.user_id
                     where v.prospect_id = p.id and not v.voided order by v.visited_at desc limit 1) lv on true
  left join lateral (select number, source from public.phones where prospect_id = p.id order by id desc limit 1) ph on true
  where p.team_id = p_team
    and (p_id is null or p.id = p_id)
    and (p_q is null or p.address ilike '%' || p_q || '%' or p.name ilike '%' || p_q || '%')
$$;

create function app.point_preview(p_team public.teams, p_user public.profiles, p_prospect bigint) returns jsonb
language plpgsql stable as $$
declare
  l_today date := app.today(p_team);
  l_mine public.visits;
  l_el jsonb;
  l_rule public.point_rules;
  l_have int := 0;
  l_res text;
  l_eff text;
  l_tier int;
  l_reduced boolean;
  l_points jsonb := '{}';
begin
  select * into l_mine from public.visits
  where user_id = p_user.id and prospect_id = p_prospect and visit_date = l_today and not voided;
  l_el := app.eligibility(p_team, p_prospect, l_today, (now() at time zone p_team.timezone)::timestamp,
                          coalesce(l_mine.id, 9223372036854775807));
  if l_mine.id is not null then
    select * into l_rule from public.point_rules where id = l_mine.rule_id;
    l_have := app.visit_points(l_mine.id);
  else
    l_rule := app.current_rule(p_team.id);
  end if;
  foreach l_res in array array['door', 'conversation', 'phone', 'appointment'] loop
    l_eff := case when l_mine.id is not null and app.tier(l_mine.result) > app.tier(l_res) then l_mine.result else l_res end;
    select t.tier, t.reduced into l_tier, l_reduced from app.pick_tier(l_eff, l_el, false, 'direct') t;
    if l_mine.id is not null and app.tier(l_mine.result) >= app.tier(l_res) and l_mine.awarded_tier >= l_tier then
      l_tier := l_mine.awarded_tier;
      l_reduced := l_mine.reduced;
    end if;
    l_points := l_points || jsonb_build_object(l_res, greatest(0, app.tier_value(l_rule, l_tier, l_reduced) - l_have));
  end loop;
  return jsonb_build_object('points', l_points, 'visited_today', l_mine.id is not null, 'revisit', not (l_el->>'door')::boolean,
    'today_result', l_mine.result, 'recent_by', l_el->'recent_by', 'recent_date', l_el->'recent_date');
end $$;

-- ---------- Adresregister: zoeken en buren ----------

create function app.distance_m(p_lat1 double precision, p_lon1 double precision,
                               p_lat2 double precision, p_lon2 double precision) returns double precision
language sql immutable as $$
  select 6371000 * sqrt(power(radians(p_lon2 - p_lon1) * cos(radians((p_lat1 + p_lat2) / 2)), 2)
                        + power(radians(p_lat2 - p_lat1), 2))
$$;

-- Adressen als JSON, met de bijhorende prospect van het team (koppeling via id of via adrestekst).
create function app.addresses_json(p_team bigint, p_ids bigint[], p_lat double precision default null,
                                   p_lon double precision default null) returns jsonb
language sql stable as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', a.id, 'street', a.street, 'number', a.number, 'postcode', a.postcode, 'municipality', a.municipality,
      'label', a.label, 'lat', a.lat, 'lon', a.lon, 'boxes', a.boxes,
      'distance', case when p_lat is null then null else round(app.distance_m(p_lat, p_lon, a.lat, a.lon)) end,
      'prospect_id', pr.id, 'do_not_contact', coalesce(pr.do_not_contact, false))
    order by o.ord), '[]'::jsonb)
  from unnest(p_ids) with ordinality as o(id, ord)
  join public.addresses a on a.team_id = p_team and a.id = o.id
  left join lateral (select p.id, p.do_not_contact from public.prospects p
                     where p.team_id = p_team
                       and (p.address_ref = a.id or p.address_key = any (app.match_keys(a.street, a.number, a.postcode, a.municipality)))
                     order by (p.address_ref = a.id) desc nulls last limit 1) pr on true
$$;
