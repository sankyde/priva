-- Postgres base64 output wraps at 76 columns; strip newlines so strict decoders (Swift) accept it.
create or replace function public.lookup_username(p_username text)
returns table (username text, bundle text)
language sql stable security definer set search_path = '' as $$
  select d.username, translate(encode(d.bundle, 'base64'), E'\n', '')
  from priva.directory d
  where d.username = priva.normalize_username(p_username)
    and priva.normalize_username(p_username) ~ '^[a-z0-9_]{3,20}$';
$$;
revoke all on function public.lookup_username(text) from public, authenticated;
grant execute on function public.lookup_username(text) to anon;

create or replace function public.svc_get_bundle(p_username text)
returns text language sql stable security definer set search_path = '' as $$
  select translate(encode(bundle, 'base64'), E'\n', '') from priva.directory
  where username = priva.normalize_username(p_username);
$$;
revoke all on function public.svc_get_bundle(text) from public, anon, authenticated;
grant execute on function public.svc_get_bundle(text) to service_role;
