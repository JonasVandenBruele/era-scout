-- Salesforce-Id van de prospect mee op de kaart: knop om na het bellen een 'Uitgaande Oproep'-taak te loggen.
create or replace function app.property_contacts(p_property bigint) returns jsonb
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
      'sf_id', external_id, 'name', name, 'phone', phone, 'mobile', mobile, 'do_not_call', do_not_call,
      'kind', kind, 'status', status, 'lead_source', lead_source, 'owner', owner_label,
      'created', created_in_source, 'other_address', address_type = 'other',
      'address', concat_ws(' ', street, number) || case when coalesce(box, '') <> '' then ' bus ' || box else '' end,
      'match', case tier when 1 then 'adres' when 2 then 'gebouw' else 'vermoedelijk' end)
    order by tier, created_in_source desc nulls last), '[]'::jsonb)
  from (select * from best order by tier, created_in_source desc nulls last limit 6) b
$$;
