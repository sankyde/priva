-- Revocation secret + removal of previous usernames.
--
-- At registration the device creates a random secret R, keeps it in its Keychain (which survives
-- app deletion) and sends only SHA-256(R). When Priva is reinstalled and the user signs back in,
-- the device presents R and its PREVIOUS username row is deleted outright. Only the username's
-- irreversible commitment is kept in `retired_commits` so nobody can re-register (hijack) that
-- name later. The server merely compares hashes; every decision is made on the device.
alter table priva.directory add column if not exists revoke_hash text check (revoke_hash ~ '^[0-9a-f]{64}$');

create table if not exists priva.retired_commits (ucommit text primary key check (ucommit ~ '^[0-9a-f]{64}$'));
alter table priva.retired_commits enable row level security;
revoke all on priva.retired_commits from public, anon, authenticated;

drop function if exists public.svc_register(text, text, text);
create or replace function public.svc_register(p_commit text, p_bundle_b64 text, p_token_sha256 text, p_revoke_hash text)
returns text language plpgsql security definer set search_path = '' as $$
declare days int := coalesce((select (value)::text::int from priva.app_config where key = 'lease_days'), 21);
begin
  if p_revoke_hash !~ '^[0-9a-f]{64}$' then return 'bad_revoke'; end if;
  if exists (select 1 from priva.directory where ucommit = p_commit)
     or exists (select 1 from priva.retired_commits where ucommit = p_commit) then return 'taken'; end if;
  begin
    insert into priva.redeemed_tokens (token_sha256) values (p_token_sha256);
  exception when unique_violation then return 'token_spent';
  end;
  begin
    insert into priva.directory (ucommit, bundle, lease_until, revoke_hash)
    values (p_commit, decode(p_bundle_b64, 'base64'), (now() at time zone 'utc')::date + days, p_revoke_hash);
  exception when unique_violation then raise exception 'taken_race';
  end;
  return 'ok';
end $$;

-- Removes a previous username (row + keys) when its owner presents the revocation secret.
create or replace function public.svc_revoke(p_commit text, p_secret_sha256 text)
returns boolean language plpgsql security definer set search_path = '' as $$
begin
  delete from priva.directory where ucommit = p_commit and revoke_hash = p_secret_sha256;
  if not found then return false; end if;
  insert into priva.retired_commits (ucommit) values (p_commit) on conflict do nothing;
  return true;
end $$;

-- Explicit "Leave Priva" (signed by the owner): mark uninstalled now, erase keys, keep revoke hash
-- so a later reinstall can still remove the row.
create or replace function public.svc_retire(p_commit text)
returns boolean language plpgsql security definer set search_path = '' as $$
begin
  update priva.directory set status = 'uninstalled', bundle = null where ucommit = p_commit and status = 'active';
  return found;
end $$;

do $$
declare f text;
begin
  foreach f in array array['public.svc_register(text,text,text,text)', 'public.svc_revoke(text,text)', 'public.svc_retire(text)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
