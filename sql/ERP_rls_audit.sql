-- فحص الصلاحيات (RLS) على مشروع Supabase: شغّله من SQL Editor وابعت النتيجة.
-- ما بيغيّرش أي بيانات، بس بيقرا.

-- 1) جداول من غير RLS مفعّل (المفروض تكون صفر صفوف)
select c.relname as table_without_rls
from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relkind='r' and not c.relrowsecurity
order by 1;

-- 2) سياسات مفتوحة لأي حد (using true أو with check true) — المفروض تكون صفر صفوف
select tablename, policyname, cmd, roles, qual, with_check
from pg_policies
where schemaname='public'
  and (qual='true' or with_check='true')
order by tablename;

-- 3) جداول بصلاحيات مفتوحة لـ anon (زوار من غير تسجيل دخول) — المفروض تكون صفر
select table_name, privilege_type
from information_schema.role_table_grants
where table_schema='public' and grantee='anon'
order by 1,2;

-- 4) دوال متاحة لـ anon وبتغيّر بيانات — المفروض تكون صفر (أو قايمة قصيرة مبررة)
select p.proname as function_name, p.prosecdef as security_definer
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public'
  and has_function_privilege('anon', p.oid, 'EXECUTE')
order by 1;

-- 5) جداول الحسابات الحساسة: مين عنده صلاحية قراءة
select tablename, policyname, roles, qual
from pg_policies
where schemaname='public'
  and tablename in ('expenses','payroll','employees','journal_entries','journal_lines','company_settings','profiles')
order by tablename, policyname;
