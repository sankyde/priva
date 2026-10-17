-- App identity for AppTransaction verification, and narrower lookup grant (no Supabase Auth users exist).
insert into priva.app_config (key, value) values ('bundle_id', '"com.priva.app"'::jsonb)
on conflict (key) do update set value = excluded.value;

revoke execute on function public.lookup_username(text) from authenticated;
