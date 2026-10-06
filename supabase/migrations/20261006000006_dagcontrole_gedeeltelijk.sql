-- Een dagelijkse controle die door het maximum werd afgekapt, telt niet als 'vandaag gedaan':
-- de volgende ronde neemt de resterende panden op.
create or replace function worker.daily_done(p_team bigint) returns boolean
language sql stable security definer set search_path = public, app, pg_temp as $$
  select exists (select 1 from public.check_runs where team_id = p_team and kind = 'daily' and finished_at is not null
                 and coalesce(note, '') not like 'gedeeltelijk%'
                 and (started_at at time zone (select timezone from public.teams where id = p_team))::date
                     = app.today(app.team(p_team)))
$$;

-- Eenmalig: de testronde van 6 oktober 2026 (5 panden) was gedeeltelijk.
update public.check_runs set note = 'gedeeltelijk · ' || note
where kind = 'daily' and note like '5 panden%' and started_at::date = date '2026-10-06';
