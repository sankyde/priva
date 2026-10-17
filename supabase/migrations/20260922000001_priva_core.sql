-- Priva core schema.
-- Everything lives in the non-exposed `priva` schema. PostgREST cannot see it.
-- The only anonymous surface is public.lookup_username(); every write goes through
-- service_role-only SECURITY DEFINER functions called by Edge Functions.

create schema if not exists priva;
revoke all on schema priva from public, anon, authenticated;

-- 1. List of purchases. No Apple account data: only a keyed hash of appTransactionID.
create table priva.purchases (
  purchase_ref          text primary key check (purchase_ref ~ '^[0-9a-f]{64}$'),
  environment           text not null check (environment in ('Production', 'Sandbox', 'Dev')),
  verified_on           date not null default (now() at time zone 'utc')::date,
  tokens_issued         smallint not null default 0 check (tokens_issued between 0 and 2),
  issued_blinded_sha256 text[] not null default '{}'
);

-- 2. Active usernames (the searchable directory). Public keys only.
create table priva.directory (
  username   text primary key check (username ~ '^[a-z0-9_]{3,20}$'),
  bundle     bytea not null check (octet_length(bundle) between 7000 and 16384),
  created_on date not null default (now() at time zone 'utc')::date,
  updated_on date not null default (now() at time zone 'utc')::date
);

-- 3. Spent registration tokens (nullifiers). Blind signatures make these unlinkable to purchases.
create table priva.redeemed_tokens (
  token_sha256 text primary key check (token_sha256 ~ '^[0-9a-f]{64}$'),
  redeemed_on  date not null default (now() at time zone 'utc')::date
);

-- 4. Server secrets (HMAC pepper, blind-signing key). Generated inside Edge Functions.
create table priva.server_secrets (
  name  text primary key,
  value bytea not null
);

-- 5. Runtime flags.
create table priva.app_config (
  key   text primary key,
  value jsonb not null
);
insert into priva.app_config (key, value) values
  ('allow_dev_purchases', 'true'::jsonb),   -- MUST be false before App Store launch
  ('max_tokens_per_purchase', '2'::jsonb);

-- Defence in depth: RLS on, zero policies, and no privileges for API roles.
alter table priva.purchases       enable row level security;
alter table priva.directory       enable row level security;
alter table priva.redeemed_tokens enable row level security;
alter table priva.server_secrets  enable row level security;
alter table priva.app_config      enable row level security;
revoke all on all tables in schema priva from public, anon, authenticated;

create or replace function priva.normalize_username(p text)
returns text language sql immutable set search_path = '' as $$
  select lower(btrim(coalesce(p, '')));
$$;

create or replace function priva.is_reserved(p text)
returns boolean language sql immutable set search_path = '' as $$
  select p = any (array['admin','administrator','root','system','priva','support','help',
                        'security','official','staff','moderator','mod','team','null','undefined']);
$$;

-- ── Public, anonymous: exact-match lookup only (no prefix search, no listing) ──
create or replace function public.lookup_username(p_username text)
returns table (username text, bundle text)
language sql stable security definer set search_path = '' as $$
  select d.username, encode(d.bundle, 'base64')
  from priva.directory d
  where d.username = priva.normalize_username(p_username)
    and priva.normalize_username(p_username) ~ '^[a-z0-9_]{3,20}$';
$$;
revoke all on function public.lookup_username(text) from public;
grant execute on function public.lookup_username(text) to anon, authenticated;

-- ── service_role only ─────────────────────────────────────────────────────────
create or replace function public.svc_get_config(p_key text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select value from priva.app_config where key = p_key;
$$;

create or replace function public.svc_get_or_create_secret(p_name text, p_candidate text)
returns text language plpgsql security definer set search_path = '' as $$
declare v bytea;
begin
  insert into priva.server_secrets (name, value)
  values (p_name, decode(p_candidate, 'base64'))
  on conflict (name) do nothing;
  select value into v from priva.server_secrets where name = p_name;
  return encode(v, 'base64');
end $$;

create or replace function public.svc_get_secret(p_name text)
returns text language sql stable security definer set search_path = '' as $$
  select encode(value, 'base64') from priva.server_secrets where name = p_name;
$$;

-- Records a purchase and authorises one blind signature.
-- Returns 'new' | 'reissue' (same blinded message again, idempotent) | 'limit'.
create or replace function public.svc_authorize_issue(p_ref text, p_env text, p_blinded_sha256 text)
returns text language plpgsql security definer set search_path = '' as $$
declare
  rec priva.purchases%rowtype;
  cap smallint := coalesce((select (value)::text::smallint from priva.app_config
                            where key = 'max_tokens_per_purchase'), 2);
begin
  if p_blinded_sha256 !~ '^[0-9a-f]{64}$' then raise exception 'bad blinded hash'; end if;
  insert into priva.purchases (purchase_ref, environment) values (p_ref, p_env)
  on conflict (purchase_ref) do nothing;
  select * into rec from priva.purchases where purchase_ref = p_ref for update;
  if p_blinded_sha256 = any (rec.issued_blinded_sha256) then
    return 'reissue';
  end if;
  if rec.tokens_issued >= cap then
    return 'limit';
  end if;
  update priva.purchases
     set tokens_issued = tokens_issued + 1,
         issued_blinded_sha256 = array_append(issued_blinded_sha256, p_blinded_sha256)
   where purchase_ref = p_ref;
  return 'new';
end $$;

-- Atomically spends a token and claims a username.
-- Returns 'ok' | 'token_spent' | 'username_taken' | 'invalid_username'.
create or replace function public.svc_register(p_username text, p_bundle_b64 text, p_token_sha256 text)
returns text language plpgsql security definer set search_path = '' as $$
declare u text := priva.normalize_username(p_username);
begin
  if u !~ '^[a-z0-9_]{3,20}$' or priva.is_reserved(u) then
    return 'invalid_username';
  end if;
  if exists (select 1 from priva.directory where username = u) then
    return 'username_taken';
  end if;
  begin
    insert into priva.redeemed_tokens (token_sha256) values (p_token_sha256);
  exception when unique_violation then
    return 'token_spent';
  end;
  begin
    insert into priva.directory (username, bundle) values (u, decode(p_bundle_b64, 'base64'));
  exception when unique_violation then
    raise exception 'username_taken_race';  -- rolls back the nullifier insert too
  end;
  return 'ok';
end $$;

create or replace function public.svc_get_bundle(p_username text)
returns text language sql stable security definer set search_path = '' as $$
  select encode(bundle, 'base64') from priva.directory
  where username = priva.normalize_username(p_username);
$$;

create or replace function public.svc_update_bundle(p_username text, p_bundle_b64 text)
returns boolean language plpgsql security definer set search_path = '' as $$
begin
  update priva.directory
     set bundle = decode(p_bundle_b64, 'base64'),
         updated_on = (now() at time zone 'utc')::date
   where username = priva.normalize_username(p_username);
  return found;
end $$;

create or replace function public.svc_delete_username(p_username text)
returns boolean language plpgsql security definer set search_path = '' as $$
begin
  delete from priva.directory where username = priva.normalize_username(p_username);
  return found;
end $$;

do $$
declare f text;
begin
  foreach f in array array[
    'public.svc_get_config(text)',
    'public.svc_get_or_create_secret(text,text)',
    'public.svc_get_secret(text)',
    'public.svc_authorize_issue(text,text,text)',
    'public.svc_register(text,text,text)',
    'public.svc_get_bundle(text)',
    'public.svc_update_bundle(text,text)',
    'public.svc_delete_username(text)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
