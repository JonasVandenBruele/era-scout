-- ERA Scout — Inkoopbonus: extra punten als een bezochte deur een opdracht wordt (Opportunity in ERAforce).
--
-- * Bron: opdrachten (verkoop en verhuur) uit de ERAForce-mirror, met het adres van het gekoppelde pand
--   (ERA_Object__c) en de datum van ondertekening (ERA_Datum_Ondertekening_Mandaat__c; anders Start opdracht).
-- * Koppeling op deurniveau: straat + huisnummer + postcode van het pand = die van een bezochte deur in ERA Scout.
-- * Bonus voor elke collega met een bezoek in de periode [ondertekening − venster, ondertekening], één keer per
--   opdracht per collega. Bedrag en venster komen uit de puntregels (instelbaar door de beheerder).
-- * De bonus telt in de periode van de ondertekening (effective_date), niet in die van het bezoek: oude rankings
--   veranderen niet. De bonus staat los van de bezoekpunten: een correctie van het bezoek raakt hem niet.

alter table public.point_rules add column if not exists mandate_bonus int not null default 100 check (mandate_bonus between 0 and 10000);
alter table public.point_rules add column if not exists mandate_window_days int not null default 365 check (mandate_window_days between 30 and 1095);

alter table public.point_transactions drop constraint if exists point_transactions_kind_check;
alter table public.point_transactions add constraint point_transactions_kind_check
  check (kind in ('visit', 'upgrade', 'correction', 'void', 'mandate'));
alter table public.point_transactions add column if not exists effective_date date;

insert into public.listing_sources (code, label, description) values
  ('eraforce_opportunity', 'ERAforce · Opdrachten', 'Getekende verkoop- en verhuuropdrachten (Opportunity) uit de ERAForce-mirror.')
on conflict (code) do nothing;

create table public.mandates (
  id bigint generated always as identity primary key,
  team_id bigint not null references public.teams (id),
  source text not null references public.listing_sources (code),
  external_id text not null,              -- Opportunity-ID
  kind text,                              -- Verkoop | Verhuur
  stage text,
  signed_on date not null,
  date_basis text not null,               -- welke bronkolom de datum leverde
  owner_label text,
  street text, number text, box text, postcode text, city text,
  building_key text not null,
  lat double precision, lon double precision,
  imported_at timestamptz not null default now(),
  unique (team_id, source, external_id)
);
create index mandates_building on public.mandates (team_id, building_key);

create table public.mandate_awards (
  mandate_id bigint not null references public.mandates (id) on delete cascade,
  user_id uuid not null references public.profiles (id),
  transaction_id bigint references public.point_transactions (id),
  visit_id bigint references public.visits (id),
  revoked boolean not null default false,
  created_at timestamptz not null default now(),
  primary key (mandate_id, user_id)
);

alter table public.mandates enable row level security;
alter table public.mandate_awards enable row level security;
revoke all on public.mandates, public.mandate_awards from anon, authenticated;

-- ---------- Bezoekpunten zonder bonus; ranking op de datum van de bonus ----------

create or replace function app.visit_points(p_visit bigint) returns int language sql stable as $$
  select coalesce(sum(amount), 0)::int from public.point_transactions where visit_id = p_visit and kind <> 'mandate'
$$;

create or replace function app.period_stats(p_team bigint, p_d1 date, p_d2 date)
returns table (user_id uuid, points int, doors int, conversations int, phones int, appointments int)
language sql stable as $$
  select pr.id, coalesce(tx.points, 0)::int, coalesce(vs.doors, 0)::int, coalesce(vs.conv, 0)::int,
         coalesce(vs.phones, 0)::int, coalesce(vs.appts, 0)::int
  from public.profiles pr
  left join (select t.user_id, sum(t.amount) as points from public.point_transactions t
             join public.visits v on v.id = t.visit_id
             where t.team_id = p_team and coalesce(t.effective_date, v.visit_date) between p_d1 and p_d2
             group by t.user_id) tx on tx.user_id = pr.id
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

create or replace function app.round_stats(p_round public.rounds) returns jsonb language sql stable as $$
  select jsonb_build_object(
    'id', p_round.id, 'goal', p_round.goal, 'started_at', p_round.started_at, 'ended_at', p_round.ended_at,
    'minutes', greatest(0, floor(extract(epoch from (coalesce(p_round.ended_at, now()) - p_round.started_at)) / 60))::int,
    'doors', count(v.id),
    'conversations', count(v.id) filter (where v.result in ('conversation', 'appointment') or (v.result = 'phone' and v.phone_source = 'direct')),
    'phones', count(v.id) filter (where v.result = 'phone' or v.phone_status = 'stored'),
    'appointments', count(v.id) filter (where v.result = 'appointment'),
    'flyers', count(v.id) filter (where v.flyer),
    'points', (select coalesce(sum(t.amount), 0) from public.point_transactions t
               join public.visits x on x.id = t.visit_id where x.round_id = p_round.id and t.kind <> 'mandate'))
  from public.visits v where v.round_id = p_round.id and not v.voided
$$;

-- ---------- Deur van een ERA Scout-adres ----------

-- Gebouw-sleutel (straat|nummer|postcode) van een bezochte deur: uit het Adressenregister als het adres daaruit
-- komt, anders uit de adrestekst ("Straat 12, 1800 Gemeente").
create function app.prospect_building_key(p public.prospects) returns text language plpgsql stable as $$
declare
  l_a public.addresses;
  l_part text := split_part(p.address, ',', 1);
  l_street text;
  l_nr text;
  l_pc text;
begin
  if p.address_ref is not null then
    select * into l_a from public.addresses where team_id = p.team_id and id = p.address_ref;
    if l_a.id is not null then return app.building_key_of(l_a.street, l_a.number, l_a.postcode); end if;
  end if;
  -- In aparte stappen: Postgres maakt een heel patroon "lui" als het eerste deel lui is.
  l_pc := substring(p.address from ',\s*(\d{4})');
  l_nr := substring(l_part from '\s(\d+[a-zA-Z]?)(?:\s|$)');
  l_street := btrim(substring(l_part from '^(\D+?)\s\d'));
  if l_pc is null or l_nr is null or l_street is null then return null; end if;   -- zonder postcode geen betrouwbare koppeling
  return app.building_key_of(l_street, l_nr, l_pc);
end $$;

-- ---------- Bonussen toekennen ----------

create function app.award_mandate_bonuses(p_team bigint) returns int language plpgsql as $$
declare
  l_rule public.point_rules := app.current_rule(p_team);
  l_row record;
  l_tx bigint;
  l_n int := 0;
begin
  if l_rule.mandate_bonus <= 0 then return 0; end if;
  for l_row in
    with doors as (
      select p.id, app.prospect_building_key(p) as building_key
      from public.prospects p where p.team_id = p_team
    )
    select distinct on (m.id, v.user_id) m.id as mandate_id, m.kind, m.signed_on, v.user_id, v.id as visit_id
    from public.mandates m
    join doors d on d.building_key = m.building_key
    join public.visits v on v.prospect_id = d.id and not v.voided
    where m.team_id = p_team
      and v.visit_date between m.signed_on - l_rule.mandate_window_days and m.signed_on
      and not exists (select 1 from public.mandate_awards a where a.mandate_id = m.id and a.user_id = v.user_id)
    order by m.id, v.user_id, v.visit_date desc
  loop
    insert into public.point_transactions (team_id, user_id, visit_id, amount, kind, detail, effective_date)
    values (p_team, l_row.user_id, l_row.visit_id, l_rule.mandate_bonus, 'mandate',
            format('Inkoopbonus: %s getekend op %s', lower(coalesce(l_row.kind, 'opdracht')) || 'opdracht',
                   to_char(l_row.signed_on, 'DD/MM/YYYY')), l_row.signed_on)
    returning id into l_tx;
    insert into public.mandate_awards (mandate_id, user_id, transaction_id, visit_id)
    values (l_row.mandate_id, l_row.user_id, l_tx, l_row.visit_id);
    l_n := l_n + 1;
  end loop;
  return l_n;
end $$;

create function worker.import_mandates(p_team bigint, p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare l_n int;
begin
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) > 5000 then perform app.fail('Ongeldige lijst.'); end if;
  insert into public.mandates as m (team_id, source, external_id, kind, stage, signed_on, date_basis, owner_label,
                                    street, number, box, postcode, city, building_key, lat, lon, imported_at)
  select p_team, 'eraforce_opportunity', x.external_id, x.kind, x.stage, x.signed_on, x.date_basis, x.owner_label,
         x.street, x.number, x.box, x.postcode, x.city, app.building_key_of(x.street, x.number, x.postcode), x.lat, x.lon, now()
  from jsonb_to_recordset(p_rows) as x(external_id text, kind text, stage text, signed_on date, date_basis text,
       owner_label text, street text, number text, box text, postcode text, city text, lat double precision, lon double precision)
  where x.external_id is not null and x.signed_on is not null and x.street is not null and x.number is not null
  on conflict (team_id, source, external_id) do update set kind = excluded.kind, stage = excluded.stage,
    signed_on = excluded.signed_on, date_basis = excluded.date_basis, owner_label = excluded.owner_label,
    street = excluded.street, number = excluded.number, box = excluded.box, postcode = excluded.postcode,
    city = excluded.city, building_key = excluded.building_key, lat = excluded.lat, lon = excluded.lon, imported_at = now();
  get diagnostics l_n = row_count;
  return jsonb_build_object('mandates', l_n, 'awarded', app.award_mandate_bonuses(p_team));
end $$;

-- ---------- API ----------

create function public.my_recent_bonuses() returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select jsonb_build_object(
    'rule', (select jsonb_build_object('bonus', r.mandate_bonus, 'window_days', r.mandate_window_days)
             from app.current_rule((app.me()).team_id) r),
    'bonuses', coalesce(jsonb_agg(jsonb_build_object(
      'amount', t.amount, 'detail', t.detail, 'date', t.effective_date, 'address', p.address) order by t.id desc), '[]'::jsonb))
  from public.point_transactions t
  join public.visits v on v.id = t.visit_id join public.prospects p on p.id = v.prospect_id
  join public.mandate_awards a on a.transaction_id = t.id and not a.revoked
  where t.user_id = (app.me()).id and t.kind = 'mandate' and t.created_at > now() - interval '14 days'
$$;

create function public.admin_mandate_bonuses() returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare l_me public.profiles := app.admin();
begin
  return jsonb_build_object(
    'last_import', (select max(imported_at) from public.mandates where team_id = l_me.team_id),
    'mandates', (select count(*) from public.mandates where team_id = l_me.team_id),
    'awards', (select coalesce(jsonb_agg(jsonb_build_object('mandate_id', a.mandate_id, 'user_id', a.user_id, 'user', u.name,
                 'amount', t.amount, 'signed_on', m.signed_on, 'kind', m.kind, 'address', p.address, 'visit_date', v.visit_date,
                 'revoked', a.revoked) order by m.signed_on desc), '[]'::jsonb)
               from public.mandate_awards a join public.mandates m on m.id = a.mandate_id
               join public.profiles u on u.id = a.user_id join public.point_transactions t on t.id = a.transaction_id
               join public.visits v on v.id = a.visit_id join public.prospects p on p.id = v.prospect_id
               where m.team_id = l_me.team_id));
end $$;

create function public.admin_revoke_bonus(p_mandate bigint, p_user uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  l_me public.profiles := app.admin();
  l_a public.mandate_awards;
  l_t public.point_transactions;
  l_reason text := app.clean_text(p_reason, 'Reden', 200);
begin
  if l_reason is null or length(l_reason) < 3 then perform app.fail('Geef een reden voor de correctie.'); end if;
  select a.* into l_a from public.mandate_awards a join public.mandates m on m.id = a.mandate_id
  where a.mandate_id = p_mandate and a.user_id = p_user and m.team_id = l_me.team_id;
  if not found then perform app.fail('Bonus niet gevonden.', 'not_found'); end if;
  if l_a.revoked then perform app.fail('Deze bonus is al ingetrokken.'); end if;
  select * into l_t from public.point_transactions where id = l_a.transaction_id;
  insert into public.point_transactions (team_id, user_id, visit_id, amount, kind, detail, reason, created_by, effective_date)
  values (l_t.team_id, l_t.user_id, l_t.visit_id, -l_t.amount, 'mandate', 'Inkoopbonus ingetrokken', l_reason, l_me.id, l_t.effective_date);
  update public.mandate_awards set revoked = true where mandate_id = p_mandate and user_id = p_user;
  return jsonb_build_object('ok', true);
end $$;

-- Puntregels: ook de inkoopbonus en het venster (bestaande waarden blijven als ze niet meegegeven worden).
create or replace function public.admin_rules(p_data jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  l_me public.profiles := app.admin();
  l_cur public.point_rules := app.current_rule(l_me.team_id);
  l_k text;
begin
  foreach l_k in array array['door', 'conversation', 'phone', 'appointment'] loop
    if coalesce(p_data->>l_k, '') !~ '^\d{1,4}$' or (p_data->>l_k)::int > 1000 then
      perform app.fail('Puntwaarden moeten tussen 0 en 1000 liggen.');
    end if;
  end loop;
  if coalesce(p_data->>'revisit_pct', '50') !~ '^\d{1,3}$' or coalesce((p_data->>'revisit_pct')::int, 50) > 100 then
    perform app.fail('Herbezoek-percentage moet tussen 0 en 100 liggen.');
  end if;
  if coalesce(p_data->>'mandate_bonus', l_cur.mandate_bonus::text) !~ '^\d{1,5}$'
     or coalesce((p_data->>'mandate_bonus')::int, l_cur.mandate_bonus) > 10000 then
    perform app.fail('Inkoopbonus moet tussen 0 en 10000 liggen.');
  end if;
  if coalesce(p_data->>'mandate_window_days', l_cur.mandate_window_days::text) !~ '^\d{1,4}$'
     or coalesce((p_data->>'mandate_window_days')::int, l_cur.mandate_window_days) not between 30 and 1095 then
    perform app.fail('Venster voor de inkoopbonus moet tussen 30 en 1095 dagen liggen.');
  end if;
  if not ((p_data->>'door')::int <= (p_data->>'conversation')::int and (p_data->>'conversation')::int <= (p_data->>'phone')::int
          and (p_data->>'phone')::int <= (p_data->>'appointment')::int) then
    perform app.fail('Een hoger resultaat moet minstens evenveel punten opleveren.');
  end if;
  insert into public.point_rules (team_id, door, conversation, phone, appointment, revisit_pct, mandate_bonus, mandate_window_days, created_by)
  values (l_me.team_id, (p_data->>'door')::int, (p_data->>'conversation')::int, (p_data->>'phone')::int,
          (p_data->>'appointment')::int, coalesce((p_data->>'revisit_pct')::int, 50),
          coalesce((p_data->>'mandate_bonus')::int, l_cur.mandate_bonus),
          coalesce((p_data->>'mandate_window_days')::int, l_cur.mandate_window_days), l_me.id);
  return jsonb_build_object('ok', true);
end $$;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig, n.nspname, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where (n.nspname = 'app' and p.proname in ('prospect_building_key', 'award_mandate_bonuses', 'visit_points', 'period_stats', 'round_stats'))
              or (n.nspname = 'worker' and p.proname = 'import_mandates')
              or (n.nspname = 'public' and p.proname in ('my_recent_bonuses', 'admin_mandate_bonuses', 'admin_revoke_bonus', 'admin_rules')) loop
    execute format('revoke all on function %s from public', f.sig);
    if f.nspname = 'worker' then
      execute format('grant execute on function %s to scout_import', f.sig);
    elsif f.nspname = 'public' then
      execute format('revoke all on function %s from anon', f.sig);
      execute format('grant execute on function %s to authenticated', f.sig);
    end if;
  end loop;
end $$;
