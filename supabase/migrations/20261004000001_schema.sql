-- Nog één deur — basisschema.
-- Alle gegevens horen bij een team. De app leest en schrijft NOOIT rechtstreeks in deze tabellen:
-- alles loopt via de functies in 20261004000003_api.sql (security definer), die het team en de rol
-- van de ingelogde gebruiker controleren en de punten zelf berekenen. RLS staat overal aan zonder
-- policies voor anon/authenticated, dus rechtstreekse toegang via de REST-API is dicht.

create schema if not exists app;  -- interne hulpfuncties, niet zichtbaar via de API
revoke all on schema app from public;

-- ---------- Teams en gebruikers ----------

create table public.teams (
  id bigint generated always as identity primary key,
  name text not null,
  timezone text not null default 'Europe/Brussels',
  revisit_cooldown_days int not null default 14 check (revisit_cooldown_days between 1 and 120),
  created_at timestamptz not null default now()
);

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  team_id bigint not null references public.teams (id),
  email text not null,
  name text not null,
  color text not null default '#3e8bff',
  role text not null default 'member' check (role in ('member', 'admin')),
  daily_goal int not null default 10 check (daily_goal between 1 and 100),
  work_days text not null default '12345' check (work_days ~ '^[1-7]{1,7}$'),
  away_until date,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create index profiles_team on public.profiles (team_id);

create table public.invites (
  code text primary key,
  team_id bigint not null references public.teams (id),
  email text not null,
  role text not null default 'member' check (role in ('member', 'admin')),
  created_by uuid references public.profiles (id),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at timestamptz,
  used_by uuid
);

-- ---------- Puntregels (geversioneerd: een bezoek onthoudt zijn versie) ----------

create table public.point_rules (
  id bigint generated always as identity primary key,
  team_id bigint not null references public.teams (id),
  door int not null,
  conversation int not null,
  phone int not null,
  appointment int not null,
  revisit_pct int not null default 50 check (revisit_pct between 0 and 100),
  created_by uuid references public.profiles (id),
  created_at timestamptz not null default now(),
  check (door <= conversation and conversation <= phone and phone <= appointment)
);

-- ---------- Adressen (prospecten) en bezoeken ----------

create table public.prospects (
  id bigint generated always as identity primary key,
  team_id bigint not null references public.teams (id),
  address text not null,
  address_key text not null,
  name text,
  note text,
  do_not_contact boolean not null default false,
  address_ref bigint,
  lat double precision,
  lon double precision,
  created_by uuid references public.profiles (id),
  created_at timestamptz not null default now(),
  unique (team_id, address_key)
);
create index prospects_ref on public.prospects (team_id, address_ref);

create table public.rounds (
  id bigint generated always as identity primary key,
  team_id bigint not null references public.teams (id),
  user_id uuid not null references public.profiles (id),
  goal int not null,
  started_at timestamptz not null default now(),
  ended_at timestamptz
);

create table public.visits (
  id bigint generated always as identity primary key,
  team_id bigint not null references public.teams (id),
  user_id uuid not null references public.profiles (id),
  prospect_id bigint not null references public.prospects (id),
  round_id bigint references public.rounds (id),
  client_id text not null unique,
  visited_at timestamptz not null,
  visit_date date not null,
  result text not null check (result in ('door', 'conversation', 'phone', 'appointment')),
  flyer boolean not null default false,
  phone_status text check (phone_status in ('stored', 'not_stored', 'known')),
  phone_source text check (phone_source in ('direct', 'neighbour', 'other')),
  awarded_tier int not null default 0,
  reduced boolean not null default false,
  rule_id bigint not null references public.point_rules (id),
  voided boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
-- Maximaal één bezoek met punten per adres, per verkoper, per dag.
create unique index visits_one_per_day on public.visits (user_id, prospect_id, visit_date) where not voided;
create index visits_team_date on public.visits (team_id, visit_date);
create index visits_prospect on public.visits (prospect_id);

create table public.phones (
  id bigint generated always as identity primary key,
  prospect_id bigint not null references public.prospects (id) on delete cascade,
  number text not null,
  source text not null check (source in ('direct', 'neighbour', 'other')),
  visit_id bigint references public.visits (id),
  created_at timestamptz not null default now(),
  unique (prospect_id, number)
);

create table public.appointments (
  id bigint generated always as identity primary key,
  team_id bigint not null references public.teams (id),
  prospect_id bigint not null references public.prospects (id),
  user_id uuid not null references public.profiles (id),
  visit_id bigint not null unique references public.visits (id),
  starts_at timestamp not null,  -- lokale tijd van het team
  note text,
  status text not null default 'planned' check (status in ('planned', 'cancelled')),
  created_at timestamptz not null default now()
);

create table public.follow_ups (
  id bigint generated always as identity primary key,
  team_id bigint not null references public.teams (id),
  prospect_id bigint not null references public.prospects (id),
  user_id uuid not null references public.profiles (id),
  visit_id bigint references public.visits (id),
  signal text not null check (signal in ('sell', 'buy', 'move', 'valuation', 'rent', 'other')),
  horizon text check (horizon in ('now', 'lt1', '1to2', '2to5', 'gt5')),
  due_on date not null,
  note text,
  status text not null default 'open' check (status in ('open', 'done', 'cancelled')),
  created_at timestamptz not null default now(),
  done_at timestamptz
);
create index follow_ups_due on public.follow_ups (team_id, status, due_on);

create table public.point_transactions (
  id bigint generated always as identity primary key,
  team_id bigint not null references public.teams (id),
  user_id uuid not null references public.profiles (id),
  visit_id bigint not null references public.visits (id),
  amount int not null,
  kind text not null check (kind in ('visit', 'upgrade', 'correction', 'void')),
  detail text,
  reason text,
  created_by uuid references public.profiles (id),
  created_at timestamptz not null default now()
);
create index tx_user on public.point_transactions (user_id);
create index tx_visit on public.point_transactions (visit_id);

-- ---------- Competities, uitdagingen, badges ----------

create table public.competitions (
  id bigint generated always as identity primary key,
  team_id bigint not null references public.teams (id),
  name text not null,
  starts_on date not null,
  ends_on date not null,
  reward text,
  created_by uuid references public.profiles (id),
  created_at timestamptz not null default now(),
  check (ends_on >= starts_on)
);

create table public.competition_participants (
  competition_id bigint not null references public.competitions (id) on delete cascade,
  user_id uuid not null references public.profiles (id),
  primary key (competition_id, user_id)
);

create table public.challenges (
  id bigint generated always as identity primary key,
  team_id bigint not null references public.teams (id),
  title text not null,
  metric text not null check (metric in ('doors', 'new_doors', 'phones', 'appointments')),
  period text not null check (period in ('day', 'week')),
  scope text not null check (scope in ('personal', 'team')),
  target int not null check (target > 0),
  active boolean not null default true
);

create table public.challenge_completions (
  challenge_id bigint not null references public.challenges (id) on delete cascade,
  subject text not null,  -- profiel-id, of 'team'
  period_key date not null,
  completed_at timestamptz not null default now(),
  primary key (challenge_id, subject, period_key)
);

create table public.user_badges (
  user_id uuid not null references public.profiles (id),
  badge text not null,
  awarded_at timestamptz not null default now(),
  primary key (user_id, badge)
);

-- ---------- Regio: adressen uit het Adressenregister (per team) ----------

create table public.region_municipalities (
  id bigint generated always as identity primary key,
  team_id bigint not null references public.teams (id),
  name text not null,
  status text not null default 'queued' check (status in ('queued', 'importing', 'done', 'error')),
  address_count int,
  imported_at timestamptz,
  error text,
  created_at timestamptz not null default now(),
  unique (team_id, name)
);

-- Eén rij per voordeur (busnummers achter één deur samengevoegd).
create table public.addresses (
  team_id bigint not null references public.teams (id),
  id bigint not null,  -- ObjectId uit het Adressenregister
  street_id bigint not null,
  street text not null,
  number text not null,
  number_sort int not null,
  postcode text,
  municipality text not null,
  label text not null,
  akey text not null,
  lat double precision not null,
  lon double precision not null,
  boxes int not null default 0,
  primary key (team_id, id)
);
create index addresses_geo on public.addresses (team_id, lat, lon);
create index addresses_street on public.addresses (team_id, street_id, number_sort);
create index addresses_muni on public.addresses (team_id, municipality);

-- ---------- Rechtstreekse toegang dicht ----------

do $$
declare t text;
begin
  foreach t in array array['teams', 'profiles', 'invites', 'point_rules', 'prospects', 'rounds', 'visits', 'phones',
    'appointments', 'follow_ups', 'point_transactions', 'competitions', 'competition_participants', 'challenges',
    'challenge_completions', 'user_badges', 'region_municipalities', 'addresses']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end $$;
