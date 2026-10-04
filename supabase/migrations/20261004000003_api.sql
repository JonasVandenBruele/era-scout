-- Nog één deur — API voor de app (aan te roepen via supabase.rpc).
-- Elke functie draait als security definer, bepaalt zelf wie de gebruiker is (auth.uid()) en
-- werkt enkel binnen diens team. Fouten komen terug als P0001 met een Nederlandse melding
-- (message) en eventueel een code (hint), bv. do_not_contact.

create function app.me() returns public.profiles language plpgsql stable as $$
declare l_me public.profiles;
begin
  select * into l_me from public.profiles where id = auth.uid() and active;
  if not found then perform app.fail('Log opnieuw in.', 'auth'); end if;
  return l_me;
end $$;

create function app.admin() returns public.profiles language plpgsql stable as $$
declare l_me public.profiles := app.me();
begin
  if l_me.role <> 'admin' then perform app.fail('Alleen voor beheerders.', 'forbidden'); end if;
  return l_me;
end $$;

create function app.team(p_id bigint) returns public.teams language sql stable as $$
  select * from public.teams where id = p_id
$$;

create function app.profile_json(p public.profiles) returns jsonb language sql stable as $$
  select jsonb_build_object('id', p.id, 'name', p.name, 'email', p.email, 'color', p.color, 'role', p.role,
    'daily_goal', p.daily_goal, 'work_days', p.work_days, 'away_until', p.away_until, 'team_id', p.team_id)
$$;

create function app.color_for(p_n int) returns text language sql immutable as $$
  select (array['#d60a29', '#3e8bff', '#9c7cff', '#ffc53d', '#00b99b', '#2ec5e8', '#ff7a45', '#e84c88'])[1 + (p_n % 8)]
$$;

create function app.default_team_setup(p_team bigint) returns void language sql as $$
  insert into public.point_rules (team_id, door, conversation, phone, appointment, revisit_pct)
  values (p_team, 5, 10, 15, 30, 50);
  insert into public.challenges (team_id, title, metric, period, scope, target) values
    (p_team, 'Bezoek vandaag tien nieuwe adressen', 'new_doors', 'day', 'personal', 10),
    (p_team, 'Registreer deze week drie telefoonnummers', 'phones', 'week', 'personal', 3),
    (p_team, 'Leg deze week een afspraak vast', 'appointments', 'week', 'personal', 1),
    (p_team, 'Bezoek als team tweehonderd deuren', 'doors', 'week', 'team', 200);
$$;

-- ================================================================ login ==

create function public.auth_status() returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare l_p public.profiles;
begin
  select * into l_p from public.profiles where id = auth.uid() and active;
  return jsonb_build_object('user', case when found then app.profile_json(l_p) end,
    'needs_setup', not exists (select 1 from public.teams),
    'inactive', exists (select 1 from public.profiles where id = auth.uid() and not active));
end $$;

-- Eerste gebruiker maakt het team aan (enkel zolang er nog geen team bestaat).
create function public.setup_team(p_team_name text, p_name text) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  l_uid uuid := auth.uid();
  l_email text;
  l_team bigint;
begin
  if l_uid is null then perform app.fail('Log eerst in.', 'auth'); end if;
  perform pg_advisory_xact_lock(hashtextextended('nod-setup', 0));
  if exists (select 1 from public.teams) then perform app.fail('De app is al ingesteld. Vraag een uitnodiging aan je beheerder.'); end if;
  select email into l_email from auth.users where id = l_uid;
  insert into public.teams (name) values (app.clean_text(p_team_name, 'Teamnaam', 60, true)) returning id into l_team;
  perform app.default_team_setup(l_team);
  insert into public.profiles (id, team_id, email, name, role, color)
  values (l_uid, l_team, l_email, app.clean_text(p_name, 'Naam', 60, true), 'admin', '#d60a29');
  return public.auth_status();
end $$;

create function public.invite_info(p_code text) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare l_i public.invites;
begin
  select * into l_i from public.invites where code = p_code and used_at is null and expires_at > now();
  if not found then perform app.fail('Deze uitnodiging is niet (meer) geldig.', 'not_found'); end if;
  return jsonb_build_object('email', l_i.email, 'team', (select name from public.teams where id = l_i.team_id));
end $$;

create function public.accept_invite(p_code text, p_name text) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  l_uid uuid := auth.uid();
  l_email text;
  l_i public.invites;
  l_n int;
begin
  if l_uid is null then perform app.fail('Log eerst in.', 'auth'); end if;
  if exists (select 1 from public.profiles where id = l_uid) then return public.auth_status(); end if;
  select * into l_i from public.invites where code = p_code and used_at is null and expires_at > now() for update;
  if not found then perform app.fail('Deze uitnodiging is niet (meer) geldig.', 'not_found'); end if;
  select email into l_email from auth.users where id = l_uid;
  if lower(l_email) <> lower(l_i.email) then
    perform app.fail('Deze uitnodiging is voor een ander e-mailadres.');
  end if;
  select count(*) into l_n from public.profiles where team_id = l_i.team_id;
  insert into public.profiles (id, team_id, email, name, role, color)
  values (l_uid, l_i.team_id, l_email, app.clean_text(p_name, 'Naam', 60, true), l_i.role, app.color_for(l_n));
  update public.invites set used_at = now(), used_by = l_uid where code = p_code;
  return public.auth_status();
end $$;

-- =============================================================== mijn dag ==

create function public.dashboard() returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  l_me public.profiles := app.me();
  l_team public.teams := app.team(l_me.team_id);
  l_today date := app.today(l_team);
  l_w1 date := app.week_start(l_today);
  l_lb jsonb := app.leaderboard(l_team, l_me, 'week', 'points');
  l_comp jsonb := app.leaderboard(l_team, l_me, 'competition', 'points');
  l_ch jsonb := app.challenges_progress(l_team, l_me);
  l_focus jsonb;
  l_mine jsonb := l_lb->'me';
  l_gap int;
  l_workdays int;
  l_round public.rounds;
  l_rule public.point_rules := app.current_rule(l_team.id);
begin
  select x.v into l_focus from jsonb_array_elements(l_ch) with ordinality as x(v, n)
  order by (x.v->>'scope' = 'personal' and not (x.v->>'done')::boolean) desc, not (x.v->>'done')::boolean desc, x.n limit 1;
  if l_mine is not null and (l_mine->>'rank')::int > 1 then
    select min((x.v->>'points')::int) - (l_mine->>'points')::int into l_gap
    from jsonb_array_elements(l_lb->'entries') as x(v) where (x.v->>'points')::int > (l_mine->>'points')::int;
  end if;
  select count(*) into l_workdays from generate_series(0, 6) i where app.is_workday(l_me, l_w1 + i);
  select * into l_round from public.rounds where user_id = l_me.id and ended_at is null order by id desc limit 1;
  return jsonb_build_object(
    'user', app.profile_json(l_me),
    'team', jsonb_build_object('name', l_team.name),
    'today', app.day_stats(l_team, l_me, l_today),
    'week', jsonb_build_object('rank', l_mine->'rank', 'of', jsonb_array_length(l_lb->'entries'),
      'points', coalesce((l_mine->>'points')::int, 0), 'doors', coalesce((l_mine->>'doors')::int, 0),
      'goal', l_me.daily_goal * l_workdays, 'gap_to_next', l_gap,
      'leader', l_lb->'entries'->0->'name', 'team_doors', l_lb->'team'->'doors'),
    'level', app.level_info(app.user_xp(l_me.id)),
    'challenge', l_focus,
    'challenges', l_ch,
    'competition', case when l_comp->'competition' is null or jsonb_typeof(l_comp->'competition') = 'null' then null
      else jsonb_build_object('name', l_comp->'competition'->'name', 'reward', l_comp->'competition'->'reward',
        'ends_on', l_comp->'competition'->'ends_on', 'days_left', l_comp->'competition'->'days_left',
        'rank', l_comp->'me'->'rank', 'of', jsonb_array_length(l_comp->'entries'),
        'participating', l_comp->'me' is not null and jsonb_typeof(l_comp->'me') <> 'null') end,
    'round', case when l_round.id is null then null else app.round_stats(l_round) end,
    'follow_ups', app.follow_up_summary(l_team, l_me),
    'rule', jsonb_build_object('door', l_rule.door, 'conversation', l_rule.conversation, 'phone', l_rule.phone,
      'appointment', l_rule.appointment, 'revisit_pct', l_rule.revisit_pct, 'cooldown_days', l_team.revisit_cooldown_days));
end $$;

create function public.my_profile() returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  l_me public.profiles := app.me();
  l_team public.teams := app.team(l_me.team_id);
  l_today date := app.today(l_team);
begin
  return jsonb_build_object(
    'user', app.profile_json(l_me),
    'level', app.level_info(app.user_xp(l_me.id)),
    'badges', (select jsonb_agg(b.v || jsonb_build_object('earned', ub.badge is not null, 'awarded_at', ub.awarded_at) order by b.n)
               from jsonb_array_elements(app.badge_defs()) with ordinality as b(v, n)
               left join public.user_badges ub on ub.user_id = l_me.id and ub.badge = b.v->>'key'),
    'lifetime', app.lifetime(l_me.id),
    'records', jsonb_build_object(
      'best_day', (select jsonb_build_object('visit_date', visit_date, 'doors', count(*)) from public.visits
                   where user_id = l_me.id and not voided group by visit_date order by count(*) desc, visit_date desc limit 1),
      'best_points_day', (select jsonb_build_object('visit_date', v.visit_date, 'points', sum(t.amount))
                          from public.point_transactions t join public.visits v on v.id = t.visit_id
                          where t.user_id = l_me.id group by v.visit_date order by sum(t.amount) desc limit 1),
      'best_round', coalesce((select max(c) from (select count(*) as c from public.visits where user_id = l_me.id
                              and not voided and round_id is not null group by round_id) s), 0),
      'challenges', (select count(*) from public.challenge_completions where subject = l_me.id::text)),
    'weeks', (select jsonb_agg(jsonb_build_object('from', w.d1, 'doors', coalesce(s.doors, 0), 'points', coalesce(s.points, 0),
                                                  'phones', coalesce(s.phones, 0), 'appointments', coalesce(s.appointments, 0)) order by w.i)
              from (select i, app.week_start(l_today) - 7 * i as d1 from generate_series(0, 5) i) w
              left join lateral (select * from app.period_stats(l_team.id, w.d1, w.d1 + 6) ps where ps.user_id = l_me.id) s on true),
    'transactions', (select coalesce(jsonb_agg(x order by x.id desc), '[]'::jsonb) from (
                       select t.id, t.amount, t.kind, t.detail, t.reason, t.created_at, p.address
                       from public.point_transactions t join public.visits v on v.id = t.visit_id
                       join public.prospects p on p.id = v.prospect_id
                       where t.user_id = l_me.id order by t.id desc limit 30) x));
end $$;

create function public.update_me(p_data jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare l_me public.profiles := app.me();
begin
  if p_data ? 'name' then
    update public.profiles set name = app.clean_text(p_data->>'name', 'Naam', 60, true) where id = l_me.id;
  end if;
  if p_data ? 'color' then
    if p_data->>'color' not in ('#d60a29', '#3e8bff', '#9c7cff', '#ffc53d', '#00b99b', '#2ec5e8', '#ff7a45', '#e84c88') then
      perform app.fail('Kies een kleur uit de lijst.');
    end if;
    update public.profiles set color = p_data->>'color' where id = l_me.id;
  end if;
  if p_data ? 'daily_goal' then
    if coalesce(p_data->>'daily_goal', '') !~ '^\d{1,3}$' or (p_data->>'daily_goal')::int not between 1 and 100 then
      perform app.fail('Dagdoel moet tussen 1 en 100 liggen.');
    end if;
    update public.profiles set daily_goal = (p_data->>'daily_goal')::int where id = l_me.id;
  end if;
  if p_data ? 'work_days' then
    if coalesce(p_data->>'work_days', '') !~ '^[1-7]{1,7}$' then perform app.fail('Kies minstens één werkdag.'); end if;
    update public.profiles set work_days = (select string_agg(distinct c, '' order by c)
                                            from regexp_split_to_table(p_data->>'work_days', '') c) where id = l_me.id;
  end if;
  if p_data ? 'away_until' then
    begin
      update public.profiles set away_until = nullif(p_data->>'away_until', '')::date where id = l_me.id;
    exception when invalid_datetime_format or datetime_field_overflow then
      perform app.fail('Ongeldige datum voor Afwezig tot.');
    end;
  end if;
  select * into l_me from public.profiles where id = l_me.id;
  return jsonb_build_object('user', app.profile_json(l_me));
end $$;

-- ============================================================ prospecten ==

create function public.prospects_list() returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select jsonb_build_object('prospects', app.prospect_rows((app.me()).team_id))
$$;

create function public.prospect_get(p_id bigint) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  l_me public.profiles := app.me();
  l_team public.teams := app.team(l_me.team_id);
  l_p jsonb := app.prospect_rows(l_me.team_id, null, p_id)->0;
begin
  if l_p is null then perform app.fail('Adres niet gevonden.', 'not_found'); end if;
  return jsonb_build_object('prospect', l_p || jsonb_build_object(
    'phones', (select coalesce(jsonb_agg(jsonb_build_object('number', app.format_phone(number), 'source', source,
                                                            'date', created_at::date) order by id desc), '[]'::jsonb)
               from public.phones where prospect_id = p_id),
    'appointments', (select coalesce(jsonb_agg(jsonb_build_object('starts_at', to_char(a.starts_at, 'YYYY-MM-DD"T"HH24:MI'),
                       'note', a.note, 'status', a.status, 'by', u.name) order by a.starts_at desc), '[]'::jsonb)
                     from public.appointments a join public.profiles u on u.id = a.user_id where a.prospect_id = p_id),
    'visits', (select coalesce(jsonb_agg(jsonb_build_object('id', v.id, 'visit_date', v.visit_date, 'visited_at', v.visited_at,
                 'result', v.result, 'flyer', v.flyer, 'voided', v.voided, 'user_id', v.user_id, 'by', u.name,
                 'points', app.visit_points(v.id)) order by v.visited_at desc), '[]'::jsonb)
               from public.visits v join public.profiles u on u.id = v.user_id where v.prospect_id = p_id),
    'follow_ups', app.list_follow_ups(l_team, l_me, 'team', null, p_id),
    'preview', app.point_preview(l_team, l_me, p_id)));
end $$;

create function public.prospect_create(p_address text, p_name text default null) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare l_p public.prospects := app.find_or_create_prospect(app.me(), p_address, p_name);
begin
  return public.prospect_get(l_p.id);
end $$;

create function public.prospect_update(p_id bigint, p_data jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  l_me public.profiles := app.me();
  l_addr text;
begin
  perform 1 from public.prospects where id = p_id and team_id = l_me.team_id;
  if not found then perform app.fail('Adres niet gevonden.', 'not_found'); end if;
  if p_data ? 'name' then update public.prospects set name = app.clean_text(p_data->>'name', 'Naam', 80) where id = p_id; end if;
  if p_data ? 'note' then update public.prospects set note = app.clean_text(p_data->>'note', 'Notitie', 280) where id = p_id; end if;
  if p_data ? 'address' then
    l_addr := app.clean_text(p_data->>'address', 'Adres', 160, true);
    if exists (select 1 from public.prospects where team_id = l_me.team_id and address_key = app.address_key(l_addr) and id <> p_id) then
      perform app.fail('Dit adres bestaat al.');
    end if;
    update public.prospects set address = l_addr, address_key = app.address_key(l_addr) where id = p_id;
  end if;
  if p_data ? 'do_not_contact' then
    perform app.set_do_not_contact(p_id, coalesce((p_data->>'do_not_contact')::boolean, false));
  end if;
  return public.prospect_get(p_id);
end $$;

-- =============================================================== bezoeken ==

create function public.visit_register(p_data jsonb) returns jsonb
language sql security definer set search_path = public, app, pg_temp as $$
  select app.register_visit(app.me(), p_data, false)
$$;

create function public.visit_update(p_id bigint, p_data jsonb) returns jsonb
language sql security definer set search_path = public, app, pg_temp as $$
  select app.edit_visit(app.me(), p_id, p_data)
$$;

create function public.visit_get(p_id bigint) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  l_me public.profiles := app.me();
  l_v public.visits;
begin
  select * into l_v from public.visits where id = p_id and team_id = l_me.team_id;
  if not found then perform app.fail('Bezoek niet gevonden.', 'not_found'); end if;
  if l_v.user_id <> l_me.id and l_me.role <> 'admin' then perform app.fail('Geen toegang.', 'forbidden'); end if;
  return jsonb_build_object('visit', app.visit_public(l_v));
end $$;

create function public.visits_today() returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select jsonb_build_object('visits', coalesce(jsonb_agg(app.visit_public(v) order by v.visited_at desc), '[]'::jsonb))
  from public.visits v
  where v.user_id = (app.me()).id and not v.voided and v.visit_date = app.today(app.team((app.me()).team_id))
$$;

-- ================================================================ rondes ==

create function public.round_active() returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select jsonb_build_object('round', (select app.round_stats(r) from public.rounds r
                                      where r.user_id = (app.me()).id and r.ended_at is null order by r.id desc limit 1))
$$;

create function public.round_start(p_goal int default null) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  l_me public.profiles := app.me();
  l_r public.rounds;
begin
  select * into l_r from public.rounds where user_id = l_me.id and ended_at is null order by id desc limit 1;
  if not found then
    insert into public.rounds (team_id, user_id, goal)
    values (l_me.team_id, l_me.id, greatest(1, least(coalesce(p_goal, l_me.daily_goal), 200)))
    returning * into l_r;
  end if;
  return jsonb_build_object('round', app.round_stats(l_r));
end $$;

create function public.round_end(p_id bigint) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  l_me public.profiles := app.me();
  l_r public.rounds;
  l_s jsonb;
  l_best int;
begin
  select * into l_r from public.rounds where id = p_id and user_id = l_me.id;
  if not found then perform app.fail('Ronde niet gevonden.', 'not_found'); end if;
  if l_r.ended_at is null then
    update public.rounds set ended_at = now() where id = p_id returning * into l_r;
  end if;
  l_s := app.round_stats(l_r);
  select coalesce(max(c), 0) into l_best from (select count(*) as c from public.visits
    where user_id = l_me.id and not voided and round_id is not null and round_id <> p_id group by round_id) s;
  return jsonb_build_object('summary', l_s || jsonb_build_object(
    'record', (l_s->>'doors')::int > l_best and (l_s->>'doors')::int > 0,
    'previous_best', l_best, 'message', app.round_message(l_s)));
end $$;

-- ============================================================== ranglijst ==

create function public.leaderboard(p_period text default 'week', p_sort text default 'points') returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select app.leaderboard(app.team((app.me()).team_id), app.me(), p_period, p_sort)
$$;

-- ============================================================ opvolgingen ==

create function public.follow_ups_list(p_scope text default 'mine', p_status text default 'open') returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare l_me public.profiles := app.me();
begin
  if p_status not in ('open', 'done', 'cancelled') then perform app.fail('Onbekende status.'); end if;
  return jsonb_build_object('follow_ups', app.list_follow_ups(app.team(l_me.team_id), l_me,
                            case when p_scope = 'team' then 'team' else 'mine' end, p_status));
end $$;

create function public.follow_up_create(p_data jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  l_me public.profiles := app.me();
  l_f jsonb;
begin
  if coalesce(p_data->>'prospect_id', '') !~ '^\d+$' then perform app.fail('Kies een adres.'); end if;
  l_f := app.create_follow_up(l_me, (p_data->>'prospect_id')::bigint, p_data);
  return jsonb_build_object('follow_up', l_f, 'new_badges', app.evaluate_badges(app.team(l_me.team_id), l_me));
end $$;

create function public.follow_up_update(p_id bigint, p_data jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  l_me public.profiles := app.me();
  l_f public.follow_ups;
begin
  select * into l_f from public.follow_ups where id = p_id and team_id = l_me.team_id;
  if not found then perform app.fail('Opvolging niet gevonden.', 'not_found'); end if;
  if l_f.user_id <> l_me.id and l_me.role <> 'admin' then
    perform app.fail('Alleen de eigenaar of een beheerder kan deze opvolging aanpassen.', 'forbidden');
  end if;
  if p_data ? 'status' then
    if p_data->>'status' not in ('open', 'done', 'cancelled') then perform app.fail('Ongeldige status.'); end if;
    update public.follow_ups set status = p_data->>'status',
      done_at = case when p_data->>'status' = 'open' then null else now() end where id = p_id;
  end if;
  if p_data ? 'due_on' then
    update public.follow_ups set due_on = app.due_date(app.team(l_me.team_id), p_data, null) where id = p_id;
  end if;
  if p_data ? 'note' then
    update public.follow_ups set note = app.clean_text(p_data->>'note', 'Notitie', 280) where id = p_id;
  end if;
  return jsonb_build_object('follow_up', app.follow_up_public(p_id));
end $$;

-- ======================================================== adresregister ==

create function public.addresses_near(p_lat double precision, p_lon double precision,
                                      p_radius int default 60, p_limit int default 6) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
-- De positie wordt enkel voor deze opzoeking gebruikt en nergens bewaard.
declare
  l_me public.profiles := app.me();
  l_r double precision := greatest(10, least(coalesce(p_radius, 60), 250));
  l_dlat double precision;
  l_dlon double precision;
  l_ids bigint[];
begin
  if p_lat is null or p_lon is null or p_lat not between -90 and 90 or p_lon not between -180 and 180 then
    perform app.fail('Ongeldige positie.');
  end if;
  l_dlat := l_r / 111320;
  l_dlon := l_r / (111320 * greatest(0.2, cos(radians(p_lat))));
  select array_agg(id order by d) into l_ids from (
    select a.id, app.distance_m(p_lat, p_lon, a.lat, a.lon) as d from public.addresses a
    where a.team_id = l_me.team_id and a.lat between p_lat - l_dlat and p_lat + l_dlat
      and a.lon between p_lon - l_dlon and p_lon + l_dlon) s
  where d <= l_r;
  return jsonb_build_object('addresses', app.addresses_json(l_me.team_id,
    coalesce(l_ids[1:greatest(1, least(coalesce(p_limit, 6), 40))], '{}'), p_lat, p_lon), 'source', 'register');
end $$;

create function public.addresses_search(p_q text) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  l_me public.profiles := app.me();
  l_words text[];
  l_num text;
  l_ids bigint[];
begin
  l_words := array_remove(string_to_array(app.address_key(left(coalesce(p_q, ''), 80)), ' '), '');
  if coalesce(array_length(l_words, 1), 0) = 0 or length(coalesce(p_q, '')) < 2 then
    return jsonb_build_object('addresses', '[]'::jsonb);
  end if;
  select w into l_num from unnest(l_words) w where w ~ '^\d+[a-z]?$' limit 1;
  select array_agg(id) into l_ids from (
    select a.id from public.addresses a
    where a.team_id = l_me.team_id
      and (select bool_and(a.akey like '%' || replace(replace(w, '%', ''), '_', '') || '%')
           from unnest(l_words) w where w is distinct from l_num) is not false
      and (l_num is null or lower(a.number) = l_num or a.number like regexp_replace(l_num, '[a-z]$', '') || '%')
    order by (lower(a.number) = coalesce(l_num, '')) desc, a.street, a.number_sort, a.number
    limit 8) s;
  return jsonb_build_object('addresses', app.addresses_json(l_me.team_id, coalesce(l_ids, '{}')));
end $$;

create function public.address_get(p_id bigint) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare l_a jsonb := app.addresses_json((app.me()).team_id, array[p_id])->0;
begin
  if l_a is null then perform app.fail('Adres niet gevonden in jullie regio.', 'not_found'); end if;
  return jsonb_build_object('address', l_a);
end $$;

-- Echte buurnummers in dezelfde straat, eerst dezelfde kant.
create function public.address_next(p_id bigint) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  l_me public.profiles := app.me();
  l_a public.addresses;
  l_ids bigint[];
begin
  select * into l_a from public.addresses where team_id = l_me.team_id and id = p_id;
  if not found then return jsonb_build_object('addresses', '[]'::jsonb); end if;
  select array_agg(id) into l_ids from (
    select b.id from public.addresses b
    where b.team_id = l_me.team_id and b.street_id = l_a.street_id and b.id <> l_a.id
      and b.number_sort between l_a.number_sort - 12 and l_a.number_sort + 12
    order by (b.number_sort - l_a.number_sort) % 2 <> 0, abs(b.number_sort - l_a.number_sort),
             b.number_sort < l_a.number_sort, b.number
    limit 6) s;
  return jsonb_build_object('addresses', app.addresses_json(l_me.team_id, coalesce(l_ids, '{}')));
end $$;

create function public.region_status() returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select jsonb_build_object(
    'municipalities', coalesce(jsonb_agg(to_jsonb(r) order by r.name), '[]'::jsonb),
    'addresses', coalesce(sum(r.address_count) filter (where r.status = 'done'), 0))
  from public.region_municipalities r where r.team_id = (app.me()).team_id
$$;

-- ================================================================ beheer ==

create function public.admin_overview() returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  l_me public.profiles := app.admin();
  l_team public.teams := app.team(l_me.team_id);
  l_today date := app.today(l_team);
  l_w1 date := app.week_start(l_today);
  l_m1 date := date_trunc('month', l_today)::date;
begin
  return jsonb_build_object(
    'team', to_jsonb(l_team),
    'members', (select coalesce(jsonb_agg(app.profile_json(p) || jsonb_build_object('active', p.active,
                  'xp', app.user_xp(p.id), 'week', (select to_jsonb(s) from app.period_stats(l_team.id, l_w1, l_w1 + 6) s
                                                   where s.user_id = p.id)) order by not p.active, p.name), '[]'::jsonb)
                from public.profiles p where p.team_id = l_team.id),
    'rules', (select coalesce(jsonb_agg(to_jsonb(r) || jsonb_build_object('by', u.name) order by r.id desc), '[]'::jsonb)
              from public.point_rules r left join public.profiles u on u.id = r.created_by where r.team_id = l_team.id),
    'competitions', (select coalesce(jsonb_agg(to_jsonb(c) || jsonb_build_object('participants',
                       (select count(*) from public.competition_participants cp where cp.competition_id = c.id))
                       order by c.starts_on desc), '[]'::jsonb) from public.competitions c where c.team_id = l_team.id),
    'challenges', (select coalesce(jsonb_agg(to_jsonb(c) order by c.id), '[]'::jsonb) from public.challenges c where c.team_id = l_team.id),
    'invites', (select coalesce(jsonb_agg(jsonb_build_object('email', i.email, 'role', i.role, 'created_at', i.created_at,
                  'expires_at', i.expires_at, 'used_at', i.used_at) order by i.created_at desc), '[]'::jsonb)
                from (select * from public.invites where team_id = l_team.id order by created_at desc limit 20) i),
    'results', jsonb_build_object(
      'week', (select jsonb_build_object('points', coalesce(sum(points), 0), 'doors', coalesce(sum(doors), 0),
                 'conversations', coalesce(sum(conversations), 0), 'phones', coalesce(sum(phones), 0),
                 'appointments', coalesce(sum(appointments), 0)) from app.period_stats(l_team.id, l_w1, l_w1 + 6)),
      'month', (select jsonb_build_object('points', coalesce(sum(points), 0), 'doors', coalesce(sum(doors), 0),
                 'conversations', coalesce(sum(conversations), 0), 'phones', coalesce(sum(phones), 0),
                 'appointments', coalesce(sum(appointments), 0))
                from app.period_stats(l_team.id, l_m1, (l_m1 + interval '1 month - 1 day')::date)),
      'today', l_today),
    'follow_ups', (select coalesce(jsonb_agg(jsonb_build_object('signal', signal, 'n', n) order by n desc), '[]'::jsonb)
                   from (select signal, count(*) as n from public.follow_ups where team_id = l_team.id and status = 'open'
                         group by signal) s));
end $$;

create function public.admin_visits() returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare l_me public.profiles := app.admin();
begin
  return jsonb_build_object(
    'visits', (select coalesce(jsonb_agg(x order by x.visited_at desc), '[]'::jsonb) from (
      select v.id, v.visit_date, v.visited_at, v.result, v.voided, u.name as user_name, p.address,
             app.visit_points(v.id) as points
      from public.visits v join public.profiles u on u.id = v.user_id join public.prospects p on p.id = v.prospect_id
      where v.team_id = l_me.team_id order by v.visited_at desc limit 60) x),
    'corrections', (select coalesce(jsonb_agg(x order by x.id desc), '[]'::jsonb) from (
      select t.id, t.amount, t.detail, t.reason, b.name as by_name, o.name as user_name, p.address
      from public.point_transactions t left join public.profiles b on b.id = t.created_by
      join public.profiles o on o.id = t.user_id join public.visits v on v.id = t.visit_id
      join public.prospects p on p.id = v.prospect_id
      where t.team_id = l_me.team_id and t.kind in ('correction', 'void') order by t.id desc limit 30) x));
end $$;

create function public.admin_void(p_id bigint, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  l_me public.profiles := app.admin();
  l_reason text := app.clean_text(p_reason, 'Reden', 200);
  l_v public.visits;
  l_r jsonb;
begin
  if l_reason is null or length(l_reason) < 3 then perform app.fail('Geef een reden voor de correctie.'); end if;
  select * into l_v from public.visits where id = p_id and team_id = l_me.team_id;
  if not found then perform app.fail('Bezoek niet gevonden.', 'not_found'); end if;
  if l_v.voided then perform app.fail('Dit bezoek is al geschrapt.'); end if;
  update public.visits set voided = true where id = p_id;
  update public.appointments set status = 'cancelled' where visit_id = p_id;
  delete from public.phones where visit_id = p_id;
  l_r := app.recompute_points(app.team(l_me.team_id), p_id, l_me.id, 'void', l_reason, 'Registratie geschrapt');
  return jsonb_build_object('visit_id', p_id, 'points', l_r->'delta');
end $$;

create function public.admin_invite(p_email text, p_role text default 'member') returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  l_me public.profiles := app.admin();
  l_email text := lower(btrim(coalesce(p_email, '')));
  l_code text := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
begin
  if l_email !~ '^[^@\s]{1,64}@[^@\s]{1,190}\.[^@\s]{2,}$' then perform app.fail('Geef een geldig e-mailadres.'); end if;
  if coalesce(p_role, 'member') not in ('member', 'admin') then perform app.fail('Ongeldige rol.'); end if;
  if exists (select 1 from public.profiles where lower(email) = l_email) then perform app.fail('Deze collega heeft al een account.'); end if;
  insert into public.invites (code, team_id, email, role, created_by, expires_at)
  values (l_code, l_me.team_id, l_email, coalesce(p_role, 'member'), l_me.id, now() + interval '14 days');
  return jsonb_build_object('code', l_code, 'email', l_email);
end $$;

create function public.admin_user_update(p_id uuid, p_data jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  l_me public.profiles := app.admin();
  l_u public.profiles;
begin
  select * into l_u from public.profiles where id = p_id and team_id = l_me.team_id;
  if not found then perform app.fail('Collega niet gevonden.', 'not_found'); end if;
  if l_u.role = 'admin' and ((p_data->>'role') = 'member' or (p_data ? 'active' and not (p_data->>'active')::boolean))
     and (select count(*) from public.profiles where team_id = l_me.team_id and role = 'admin' and active) <= 1 then
    perform app.fail('Een team heeft minstens één beheerder nodig.');
  end if;
  if p_data ? 'role' then
    if p_data->>'role' not in ('member', 'admin') then perform app.fail('Ongeldige rol.'); end if;
    update public.profiles set role = p_data->>'role' where id = p_id;
  end if;
  if p_data ? 'active' then update public.profiles set active = (p_data->>'active')::boolean where id = p_id; end if;
  if p_data ? 'daily_goal' then
    if coalesce(p_data->>'daily_goal', '') !~ '^\d{1,3}$' or (p_data->>'daily_goal')::int not between 1 and 100 then
      perform app.fail('Dagdoel moet tussen 1 en 100 liggen.');
    end if;
    update public.profiles set daily_goal = (p_data->>'daily_goal')::int where id = p_id;
  end if;
  if p_data ? 'work_days' then
    if coalesce(p_data->>'work_days', '') !~ '^[1-7]{1,7}$' then perform app.fail('Kies minstens één werkdag.'); end if;
    update public.profiles set work_days = (select string_agg(distinct c, '' order by c)
                                            from regexp_split_to_table(p_data->>'work_days', '') c) where id = p_id;
  end if;
  return jsonb_build_object('ok', true);
end $$;

create function public.admin_team_update(p_data jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare l_me public.profiles := app.admin();
begin
  if p_data ? 'name' then
    update public.teams set name = app.clean_text(p_data->>'name', 'Teamnaam', 60, true) where id = l_me.team_id;
  end if;
  if p_data ? 'timezone' then
    if not exists (select 1 from pg_timezone_names where name = p_data->>'timezone') then
      perform app.fail('Onbekende tijdzone.');
    end if;
    update public.teams set timezone = p_data->>'timezone' where id = l_me.team_id;
  end if;
  if p_data ? 'revisit_cooldown_days' then
    if coalesce(p_data->>'revisit_cooldown_days', '') !~ '^\d{1,3}$'
       or (p_data->>'revisit_cooldown_days')::int not between 1 and 120 then
      perform app.fail('Herbezoek-periode moet tussen 1 en 120 dagen liggen.');
    end if;
    update public.teams set revisit_cooldown_days = (p_data->>'revisit_cooldown_days')::int where id = l_me.team_id;
  end if;
  return jsonb_build_object('ok', true);
end $$;

create function public.admin_rules(p_data jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  l_me public.profiles := app.admin();
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
  if not ((p_data->>'door')::int <= (p_data->>'conversation')::int and (p_data->>'conversation')::int <= (p_data->>'phone')::int
          and (p_data->>'phone')::int <= (p_data->>'appointment')::int) then
    perform app.fail('Een hoger resultaat moet minstens evenveel punten opleveren.');
  end if;
  insert into public.point_rules (team_id, door, conversation, phone, appointment, revisit_pct, created_by)
  values (l_me.team_id, (p_data->>'door')::int, (p_data->>'conversation')::int, (p_data->>'phone')::int,
          (p_data->>'appointment')::int, coalesce((p_data->>'revisit_pct')::int, 50), l_me.id);
  return jsonb_build_object('ok', true);
end $$;

create function public.admin_competition_create(p_data jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  l_me public.profiles := app.admin();
  l_s date;
  l_e date;
  l_ids uuid[];
  l_id bigint;
begin
  begin
    l_s := (p_data->>'starts_on')::date;
    l_e := (p_data->>'ends_on')::date;
  exception when others then
    perform app.fail('Ongeldige datum.');
  end;
  if l_s is null or l_e is null then perform app.fail('Kies een start- en einddatum.'); end if;
  if l_e < l_s then perform app.fail('De einddatum ligt voor de startdatum.'); end if;
  if exists (select 1 from public.competitions where team_id = l_me.team_id and starts_on <= l_e and ends_on >= l_s) then
    perform app.fail('Er loopt al een competitie in die periode. Beëindig die eerst.');
  end if;
  if jsonb_typeof(p_data->'participant_ids') = 'array' then
    select array_agg(distinct x::uuid) into l_ids from jsonb_array_elements_text(p_data->'participant_ids') x;
  else
    select array_agg(id) into l_ids from public.profiles where team_id = l_me.team_id and active;
  end if;
  if l_ids is null or exists (select 1 from unnest(l_ids) u where u not in (
       select id from public.profiles where team_id = l_me.team_id and active)) then
    perform app.fail('Kies deelnemers uit je team.');
  end if;
  insert into public.competitions (team_id, name, starts_on, ends_on, reward, created_by)
  values (l_me.team_id, app.clean_text(p_data->>'name', 'Naam', 60, true), l_s, l_e,
          app.clean_text(p_data->>'reward', 'Beloning', 160), l_me.id)
  returning id into l_id;
  insert into public.competition_participants select l_id, u from unnest(l_ids) u;
  return jsonb_build_object('id', l_id);
end $$;

create function public.admin_competition_end(p_id bigint) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  l_me public.profiles := app.admin();
  l_c public.competitions;
  l_yesterday date := app.today(app.team(l_me.team_id)) - 1;
begin
  select * into l_c from public.competitions where id = p_id and team_id = l_me.team_id;
  if not found then perform app.fail('Competitie niet gevonden.', 'not_found'); end if;
  if l_yesterday < l_c.starts_on then
    delete from public.competitions where id = p_id;
  elsif l_c.ends_on > l_yesterday then
    update public.competitions set ends_on = l_yesterday where id = p_id;
  end if;
  return jsonb_build_object('ok', true);
end $$;

create function public.admin_challenge_update(p_id bigint, p_data jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare l_me public.profiles := app.admin();
begin
  perform 1 from public.challenges where id = p_id and team_id = l_me.team_id;
  if not found then perform app.fail('Uitdaging niet gevonden.', 'not_found'); end if;
  if p_data ? 'target' then
    if coalesce(p_data->>'target', '') !~ '^\d{1,5}$' or (p_data->>'target')::int < 1 then
      perform app.fail('Doel moet minstens 1 zijn.');
    end if;
    update public.challenges set target = (p_data->>'target')::int where id = p_id;
  end if;
  if p_data ? 'active' then update public.challenges set active = (p_data->>'active')::boolean where id = p_id; end if;
  return jsonb_build_object('ok', true);
end $$;

-- ---------- Regio laden (de beheerder haalt de adressen op bij Digitaal Vlaanderen) ----------

create function public.admin_region_add(p_name text) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  l_me public.profiles := app.admin();
  l_name text := app.clean_text(p_name, 'Gemeente', 80, true);
  l_r public.region_municipalities;
begin
  insert into public.region_municipalities (team_id, name, status) values (l_me.team_id, l_name, 'queued')
  on conflict (team_id, name) do update set status = 'queued', error = null
  returning * into l_r;
  return jsonb_build_object('municipality', to_jsonb(l_r));
end $$;

create function public.admin_region_begin(p_id bigint) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  l_me public.profiles := app.admin();
  l_r public.region_municipalities;
begin
  select * into l_r from public.region_municipalities where id = p_id and team_id = l_me.team_id;
  if not found then perform app.fail('Gemeente niet gevonden.', 'not_found'); end if;
  delete from public.addresses where team_id = l_me.team_id and municipality = l_r.name;
  update public.region_municipalities set status = 'importing', address_count = 0, error = null where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

create function public.admin_region_rows(p_id bigint, p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  l_me public.profiles := app.admin();
  l_r public.region_municipalities;
  l_n int;
begin
  select * into l_r from public.region_municipalities where id = p_id and team_id = l_me.team_id;
  if not found then perform app.fail('Gemeente niet gevonden.', 'not_found'); end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) > 5000 then perform app.fail('Ongeldige adreslijst.'); end if;
  insert into public.addresses (team_id, id, street_id, street, number, number_sort, postcode, municipality, label, akey, lat, lon, boxes)
  select l_me.team_id, x.id, x.street_id, left(x.street, 120), left(x.number, 20),
         coalesce(substring(x.number from '^\d+')::int, 0), left(x.postcode, 10), l_r.name,
         format('%s %s, %s %s', x.street, x.number, x.postcode, l_r.name),
         app.address_key(format('%s %s, %s %s', x.street, x.number, x.postcode, l_r.name)),
         x.lat, x.lon, greatest(0, coalesce(x.boxes, 0))
  from jsonb_to_recordset(p_rows) as x(id bigint, street_id bigint, street text, number text, postcode text,
                                       lat double precision, lon double precision, boxes int)
  where x.id is not null and x.street is not null and x.number is not null
    and x.lat between 49.4 and 51.6 and x.lon between 2.4 and 6.5
  on conflict (team_id, id) do update set street = excluded.street, number = excluded.number, number_sort = excluded.number_sort,
    postcode = excluded.postcode, label = excluded.label, akey = excluded.akey, lat = excluded.lat, lon = excluded.lon,
    boxes = excluded.boxes;
  get diagnostics l_n = row_count;
  update public.region_municipalities set address_count = coalesce(address_count, 0) + l_n where id = p_id;
  return jsonb_build_object('inserted', l_n);
end $$;

create function public.admin_region_finish(p_id bigint, p_error text default null) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  l_me public.profiles := app.admin();
  l_r public.region_municipalities;
begin
  select * into l_r from public.region_municipalities where id = p_id and team_id = l_me.team_id;
  if not found then perform app.fail('Gemeente niet gevonden.', 'not_found'); end if;
  if p_error is not null then
    update public.region_municipalities set status = 'error', error = left(p_error, 300) where id = p_id;
  else
    update public.region_municipalities set status = 'done', imported_at = now(), error = null,
      address_count = (select count(*) from public.addresses where team_id = l_me.team_id and municipality = l_r.name)
    where id = p_id;
  end if;
  return public.region_status();
end $$;

create function public.admin_region_remove(p_id bigint) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  l_me public.profiles := app.admin();
  l_r public.region_municipalities;
begin
  select * into l_r from public.region_municipalities where id = p_id and team_id = l_me.team_id;
  if not found then perform app.fail('Gemeente niet gevonden.', 'not_found'); end if;
  delete from public.addresses where team_id = l_me.team_id and municipality = l_r.name;
  delete from public.region_municipalities where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

-- ================================================================ rechten ==

do $$
declare f record;
begin
  -- Interne functies: niemand behalve de eigenaar.
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'app' loop
    execute format('revoke all on function %s from public', f.sig);
  end loop;
  -- API: enkel ingelogde gebruikers; invite_info ook voor wie nog geen account heeft.
  for f in select p.oid::regprocedure as sig, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in (
             'auth_status', 'setup_team', 'invite_info', 'accept_invite', 'dashboard', 'my_profile', 'update_me',
             'prospects_list', 'prospect_get', 'prospect_create', 'prospect_update', 'visit_register', 'visit_update',
             'visit_get', 'visits_today', 'round_active', 'round_start', 'round_end', 'leaderboard', 'follow_ups_list',
             'follow_up_create', 'follow_up_update', 'addresses_near', 'addresses_search', 'address_get', 'address_next',
             'region_status', 'admin_overview', 'admin_visits', 'admin_void', 'admin_invite', 'admin_user_update',
             'admin_team_update', 'admin_rules', 'admin_competition_create', 'admin_competition_end',
             'admin_challenge_update', 'admin_region_add', 'admin_region_begin', 'admin_region_rows',
             'admin_region_finish', 'admin_region_remove') loop
    execute format('revoke all on function %s from public, anon', f.sig);
    execute format('grant execute on function %s to authenticated', f.sig);
    if f.proname = 'invite_info' then
      execute format('grant execute on function %s to anon', f.sig);
    end if;
  end loop;
end $$;
