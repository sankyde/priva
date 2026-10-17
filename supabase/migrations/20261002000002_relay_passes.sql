-- Relay passes (functions/relay-pass): a purchase may take a limited number each month. Counted per month and
-- pruned to the current and previous month, like the other issuance counters (metadata minimisation).
alter table priva.purchases add column if not exists relay_passes jsonb not null default '{}'::jsonb;
insert into priva.app_config (key, value) values ('max_relay_passes_per_month', '160'::jsonb)
  on conflict (key) do nothing;

create or replace function public.svc_authorize_relay(p_ref text, p_env text, p_count int)
returns text language plpgsql security definer set search_path = '' as $$
declare
  this_month text := to_char(now() at time zone 'utc', 'YYYY-MM');
  last_month text := to_char((now() at time zone 'utc') - interval '1 month', 'YYYY-MM');
  per_month int := coalesce((select (value)::text::int from priva.app_config where key = 'max_relay_passes_per_month'), 160);
  used int;
begin
  if p_ref !~ '^[0-9a-f]{64}$' or p_count < 1 or p_count > 40 then raise exception 'bad request'; end if;
  insert into priva.purchases (purchase_ref, environment) values (p_ref, p_env) on conflict (purchase_ref) do nothing;
  select coalesce((relay_passes ->> this_month)::int, 0) into used from priva.purchases where purchase_ref = p_ref for update;
  if used + p_count > per_month then return 'limit'; end if;
  update priva.purchases
     set relay_passes = jsonb_strip_nulls(jsonb_build_object(this_month, used + p_count, last_month, relay_passes -> last_month))
   where purchase_ref = p_ref;
  return 'ok';
end $$;
revoke all on function public.svc_authorize_relay(text, text, int) from public, anon, authenticated;
grant execute on function public.svc_authorize_relay(text, text, int) to service_role;
