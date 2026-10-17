-- "com.priva.app" belongs to another developer account; Priva ships as com.sanketdesai.priva.
-- issue-token checks App Store transactions against this value.
update priva.app_config set value = '"com.sanketdesai.priva"'::jsonb where key = 'bundle_id';
