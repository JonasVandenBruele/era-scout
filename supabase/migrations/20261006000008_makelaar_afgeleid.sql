-- Website van een kantoor ook afleiden uit de naam (enkel aanvaard als de site de naam draagt, zie makelaarsites.py).
-- Rangorde: handmatig > Immoweb > afgeleid.
alter table public.agency_sites drop constraint agency_sites_source_check;
alter table public.agency_sites add constraint agency_sites_source_check check (source in ('immoweb', 'manual', 'guess'));

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
  -- Afgeleide website (uit de kantoornaam): alleen bewaren als er nog niets beters is.
  if p_site = 'agency' and p_details->>'website_source' = 'guess' and coalesce(p_details->>'agency_website', '') ~* '^https?://' then
    insert into public.agency_sites (team_id, name_key, name, website, source)
    select distinct l_team, app.norm_text(r.agency_name), r.agency_name, p_details->>'agency_website', 'guess'
    from public.source_records r where r.property_id = p_property and not r.deleted and r.agency_name is not null
    on conflict (team_id, name_key) do nothing;
  end if;
  update public.check_runs set checked = checked + 1, failed = failed + (p_status = 'failed')::int,
    lease_until = now() + interval '45 minutes' where id = p_run;
end $$;
revoke all on function worker.save_check(bigint, bigint, text, text, text, text, text, text, int, jsonb) from public, anon, authenticated;
grant execute on function worker.save_check(bigint, bigint, text, text, text, text, text, text, int, jsonb) to scout_import;
