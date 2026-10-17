-- Identity v2: random usernames, client-side commitments, active/uninstalled lifecycle.
--
-- The server never sees a username. Devices store and query only
--   ucommit = scrypt("priva-username-v1|" ‖ username, "priva.directory.v1", N=2^16, r=8, p=1)
-- computed on the phone. No server-side jobs or hashing: the server stores, compares and
-- verifies signatures; every decision about usernames happens on the user's device.

drop function if exists public.lookup_username(text);
drop function if exists public.svc_register(text, text, text);
drop function if exists public.svc_get_bundle(text);
drop function if exists public.svc_update_bundle(text, text);
drop function if exists public.svc_delete_username(text);
drop table if exists priva.directory;

create table priva.directory (
  ucommit     text primary key check (ucommit ~ '^[0-9a-f]{64}$'),
  status      text not null default 'active' check (status in ('active', 'uninstalled')),
  bundle      bytea check (bundle is null or octet_length(bundle) between 7000 and 16384),
  lease_until date not null,
  created_on  date not null default (now() at time zone 'utc')::date,
  -- An uninstalled username keeps only its tombstone (never reissued); its keys are erased.
  check ((status = 'active') = (bundle is not null))
);
alter table priva.directory enable row level security;
revoke all on priva.directory from public, anon, authenticated;

-- Purchases: day-granular issuance log instead of a lifetime counter, so a returning customer
-- (reinstall) can obtain a fresh anonymous token while abuse stays rate-limited.
alter table priva.purchases drop constraint if exists purchases_tokens_issued_check;
alter table priva.purchases add column if not exists issued_on date[] not null default '{}';
insert into priva.app_config (key, value) values
  ('max_tokens_per_day', '2'::jsonb), ('max_tokens_per_year', '10'::jsonb), ('lease_days', '21'::jsonb)
on conflict (key) do nothing;
delete from priva.app_config where key = 'max_tokens_per_purchase';

create or replace function public.svc_authorize_issue(p_ref text, p_env text, p_blinded_sha256 text)
returns text language plpgsql security definer set search_path = '' as $$
declare
  rec priva.purchases%rowtype;
  today date := (now() at time zone 'utc')::date;
  per_day int := coalesce((select (value)::text::int from priva.app_config where key = 'max_tokens_per_day'), 2);
  per_year int := coalesce((select (value)::text::int from priva.app_config where key = 'max_tokens_per_year'), 10);
begin
  if p_blinded_sha256 !~ '^[0-9a-f]{64}$' then raise exception 'bad blinded hash'; end if;
  insert into priva.purchases (purchase_ref, environment) values (p_ref, p_env) on conflict (purchase_ref) do nothing;
  select * into rec from priva.purchases where purchase_ref = p_ref for update;
  if p_blinded_sha256 = any (rec.issued_blinded_sha256) then return 'reissue'; end if;
  if (select count(*) from unnest(rec.issued_on) d where d = today) >= per_day then return 'rate_limited'; end if;
  if (select count(*) from unnest(rec.issued_on) d where d > today - 365) >= per_year then return 'limit'; end if;
  update priva.purchases
     set tokens_issued = tokens_issued + 1,
         issued_on = array_append(issued_on, today),
         issued_blinded_sha256 = (array_append(issued_blinded_sha256, p_blinded_sha256))[greatest(1, cardinality(issued_blinded_sha256) - 18):]
   where purchase_ref = p_ref;
  return 'new';
end $$;

-- ── anonymous: exact commitment lookup ────────────────────────────────────────
create or replace function public.lookup_directory(p_commit text)
returns table (status text, lease_until date, bundle text)
language sql stable security definer set search_path = '' as $$
  select d.status, d.lease_until, translate(encode(d.bundle, 'base64'), E'\n', '')
  from priva.directory d
  where p_commit ~ '^[0-9a-f]{64}$' and d.ucommit = p_commit;
$$;
revoke all on function public.lookup_directory(text) from public, authenticated;
grant execute on function public.lookup_directory(text) to anon;

-- ── service_role only (called by Edge Functions after signature checks) ───────
create or replace function public.svc_register(p_commit text, p_bundle_b64 text, p_token_sha256 text)
returns text language plpgsql security definer set search_path = '' as $$
declare days int := coalesce((select (value)::text::int from priva.app_config where key = 'lease_days'), 21);
begin
  if exists (select 1 from priva.directory where ucommit = p_commit) then return 'taken'; end if;
  begin
    insert into priva.redeemed_tokens (token_sha256) values (p_token_sha256);
  exception when unique_violation then return 'token_spent';
  end;
  begin
    insert into priva.directory (ucommit, bundle, lease_until)
    values (p_commit, decode(p_bundle_b64, 'base64'), (now() at time zone 'utc')::date + days);
  exception when unique_violation then raise exception 'taken_race';
  end;
  return 'ok';
end $$;

create or replace function public.svc_get_bundle(p_commit text)
returns text language sql stable security definer set search_path = '' as $$
  select translate(encode(bundle, 'base64'), E'\n', '') from priva.directory where ucommit = p_commit and status = 'active';
$$;

create or replace function public.svc_renew(p_commit text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare days int := coalesce((select (value)::text::int from priva.app_config where key = 'lease_days'), 21);
begin
  update priva.directory set lease_until = (now() at time zone 'utc')::date + days
   where ucommit = p_commit and status = 'active';
  return found;
end $$;

create or replace function public.svc_retire(p_commit text)
returns boolean language plpgsql security definer set search_path = '' as $$
begin
  update priva.directory set status = 'uninstalled', bundle = null where ucommit = p_commit and status = 'active';
  return found;
end $$;

create or replace function public.svc_update_bundle(p_commit text, p_bundle_b64 text)
returns boolean language plpgsql security definer set search_path = '' as $$
begin
  update priva.directory set bundle = decode(p_bundle_b64, 'base64') where ucommit = p_commit and status = 'active';
  return found;
end $$;

do $$
declare f text;
begin
  foreach f in array array[
    'public.svc_authorize_issue(text,text,text)', 'public.svc_register(text,text,text)', 'public.svc_get_bundle(text)',
    'public.svc_renew(text)', 'public.svc_retire(text)', 'public.svc_update_bundle(text,text)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
