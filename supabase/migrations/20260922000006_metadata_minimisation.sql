-- Metadata minimisation (docs/IDENTITY_DESIGN.md §4): no creation dates anywhere; purchases keep
-- month buckets only; leases are stored at week granularity. Nothing here can match "a purchase
-- on day D" with "a username created on day D".

alter table priva.directory drop column if exists created_on;
alter table priva.redeemed_tokens drop column if exists redeemed_on;

alter table priva.purchases add column if not exists verified_month text not null default to_char(now() at time zone 'utc', 'YYYY-MM')
  check (verified_month ~ '^[0-9]{4}-[0-9]{2}$');
alter table priva.purchases add column if not exists issued_months text[] not null default '{}';
alter table priva.purchases drop column if exists verified_on;
alter table priva.purchases drop column if exists issued_on;
alter table priva.purchases drop column if exists tokens_issued;

-- Leases: store the Monday of the week in which the lease ends.
alter table priva.directory rename column lease_until to lease_week;
update priva.directory set lease_week = date_trunc('week', lease_week)::date;

insert into priva.app_config (key, value) values ('max_tokens_per_month', '3'::jsonb)
on conflict (key) do update set value = excluded.value;
delete from priva.app_config where key = 'max_tokens_per_day';

create or replace function priva.lease_week()
returns date language sql stable set search_path = '' as $$
  select date_trunc('week', (now() at time zone 'utc')::date
         + coalesce((select (value)::text::int from priva.app_config where key = 'lease_days'), 21))::date;
$$;

create or replace function public.svc_authorize_issue(p_ref text, p_env text, p_blinded_sha256 text)
returns text language plpgsql security definer set search_path = '' as $$
declare
  rec priva.purchases%rowtype;
  this_month text := to_char(now() at time zone 'utc', 'YYYY-MM');
  year_ago text := to_char((now() at time zone 'utc') - interval '11 months', 'YYYY-MM');
  per_month int := coalesce((select (value)::text::int from priva.app_config where key = 'max_tokens_per_month'), 3);
  per_year int := coalesce((select (value)::text::int from priva.app_config where key = 'max_tokens_per_year'), 10);
begin
  if p_blinded_sha256 !~ '^[0-9a-f]{64}$' then raise exception 'bad blinded hash'; end if;
  insert into priva.purchases (purchase_ref, environment) values (p_ref, p_env) on conflict (purchase_ref) do nothing;
  select * into rec from priva.purchases where purchase_ref = p_ref for update;
  if p_blinded_sha256 = any (rec.issued_blinded_sha256) then return 'reissue'; end if;
  if (select count(*) from unnest(rec.issued_months) m where m = this_month) >= per_month then return 'rate_limited'; end if;
  if (select count(*) from unnest(rec.issued_months) m where m >= year_ago) >= per_year then return 'limit'; end if;
  update priva.purchases
     set issued_months = (array_append(issued_months, this_month))[greatest(1, cardinality(issued_months) - 18):],
         issued_blinded_sha256 = (array_append(issued_blinded_sha256, p_blinded_sha256))[greatest(1, cardinality(issued_blinded_sha256) - 18):]
   where purchase_ref = p_ref;
  return 'new';
end $$;

drop function if exists public.lookup_directory(text);
create or replace function public.lookup_directory(p_commit text)
returns table (status text, lease_week date, bundle text)
language sql stable security definer set search_path = '' as $$
  select d.status, d.lease_week, translate(encode(d.bundle, 'base64'), E'\n', '')
  from priva.directory d
  where p_commit ~ '^[0-9a-f]{64}$' and d.ucommit = p_commit;
$$;
revoke all on function public.lookup_directory(text) from public, authenticated;
grant execute on function public.lookup_directory(text) to anon;

create or replace function public.svc_register(p_commit text, p_bundle_b64 text, p_token_sha256 text, p_revoke_hash text)
returns text language plpgsql security definer set search_path = '' as $$
begin
  if p_revoke_hash !~ '^[0-9a-f]{64}$' then return 'bad_revoke'; end if;
  if exists (select 1 from priva.directory where ucommit = p_commit)
     or exists (select 1 from priva.retired_commits where ucommit = p_commit) then return 'taken'; end if;
  begin
    insert into priva.redeemed_tokens (token_sha256) values (p_token_sha256);
  exception when unique_violation then return 'token_spent';
  end;
  begin
    insert into priva.directory (ucommit, bundle, lease_week, revoke_hash)
    values (p_commit, decode(p_bundle_b64, 'base64'), priva.lease_week(), p_revoke_hash);
  exception when unique_violation then raise exception 'taken_race';
  end;
  return 'ok';
end $$;

create or replace function public.svc_renew(p_commit text)
returns boolean language plpgsql security definer set search_path = '' as $$
begin
  update priva.directory set lease_week = priva.lease_week() where ucommit = p_commit and status = 'active';
  return found;
end $$;

revoke all on function priva.lease_week() from public, anon, authenticated;
do $$
declare f text;
begin
  foreach f in array array['public.svc_authorize_issue(text,text,text)', 'public.svc_register(text,text,text,text)', 'public.svc_renew(text)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
