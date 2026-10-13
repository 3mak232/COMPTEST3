-- إصلاحات أمان: نفّذ الملف ده على مشروع Supabase بالترتيب.
-- الترتيب مهم: الكود الجديد (app.js بينادي app_version) لازم يتنشر على الموقع
-- قبل ما نحذف app_refresh_token، عشان التحديث الإجباري للمتصفحات يفضل شغال.

-- 1) عمود "علامة الإصدار" بيتقري من الفرونت للتحديث الإجباري.
--    القيمة دي مش توكن جلسة (تأكد: مفيش أي كود بيستخدمها للمصادقة).
ALTER TABLE public.app_control RENAME COLUMN refresh_token TO app_version;

-- 2) دالة عامة بتقرا علامة الإصدار بس (مش توكن).
CREATE OR REPLACE FUNCTION public.app_version()
RETURNS text
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT app_version FROM app_control WHERE id = 1;
$function$;

REVOKE EXECUTE ON FUNCTION public.app_version() FROM public;
GRANT EXECUTE ON FUNCTION public.app_version() TO anon, authenticated;

-- 3) بعد ما الكود الجديد يتنشر ويتأكد إن التحديث الإجباري شغال:
--    احذف الدالة القديمة.
-- DROP FUNCTION IF EXISTS public.app_refresh_token();

-- 4) دوّر علامة الإصدار (قيمة جديدة عشوائية). ده هيعمل تحديث إجباري لكل المتصفحات مرة واحدة، وده متوقع.
-- UPDATE public.app_control SET app_version = replace(gen_random_uuid()::text, '-', '') WHERE id = 1;

-- 5) تحقق:
-- SELECT has_function_privilege('anon', 'public.app_version()', 'EXECUTE');  -- المفروض true
-- SELECT has_function_privilege('anon', 'public.app_refresh_token()', 'EXECUTE');  -- المفروض false أو الدالة اتحذفت

-- ============================================================
-- 6) تشديد الحذف والتعديل على الجداول الحساسة (للأدمن بس)
-- نفّذ كل جزء داخل transaction عشان لو حصل خطأ ما يبقاش فيه جدول من غير سياسات.
-- ============================================================
BEGIN;

-- 6أ) parties: المبيعات والمخزن يضيفوا ويعدّلوا، والحذف للأدمن بس.
DROP POLICY IF EXISTS write_parties ON public.parties;
CREATE POLICY ins_parties ON public.parties FOR INSERT TO authenticated
  WITH CHECK (auth_role() = ANY (ARRAY['admin','accountant','sales','store']));
CREATE POLICY upd_parties ON public.parties FOR UPDATE TO authenticated
  USING (auth_role() = ANY (ARRAY['admin','accountant','sales','store']))
  WITH CHECK (auth_role() = ANY (ARRAY['admin','accountant','sales','store']));
CREATE POLICY del_parties ON public.parties FOR DELETE TO authenticated
  USING (auth_role() = 'admin');

-- 6ب) fiscal_periods: الإضافة للأدمن والمحاسب (فتح سنة/شهر جديد عادي)،
--     والتعديل والحذف للأدمن بس، عشان ما حدش يفتح فترة مقفولة.
DROP POLICY IF EXISTS write_fiscal_periods_admin ON public.fiscal_periods;
CREATE POLICY ins_fiscal_periods ON public.fiscal_periods FOR INSERT TO authenticated
  WITH CHECK (auth_role() = ANY (ARRAY['admin','accountant']));
CREATE POLICY upd_fiscal_periods ON public.fiscal_periods FOR UPDATE TO authenticated
  USING (auth_role() = 'admin') WITH CHECK (auth_role() = 'admin');
CREATE POLICY del_fiscal_periods ON public.fiscal_periods FOR DELETE TO authenticated
  USING (auth_role() = 'admin');

-- 6ج) tax_documents: الحذف للأدمن بس، والإضافة والتعديل للمحاسب والأدمن.
DROP POLICY IF EXISTS write_tax_documents ON public.tax_documents;
CREATE POLICY ins_tax_documents ON public.tax_documents FOR INSERT TO authenticated
  WITH CHECK (auth_role() = ANY (ARRAY['admin','accountant']));
CREATE POLICY upd_tax_documents ON public.tax_documents FOR UPDATE TO authenticated
  USING (auth_role() = ANY (ARRAY['admin','accountant']))
  WITH CHECK (auth_role() = ANY (ARRAY['admin','accountant']));
CREATE POLICY del_tax_documents ON public.tax_documents FOR DELETE TO authenticated
  USING (auth_role() = 'admin');

COMMIT;

-- تحقق بعد التنفيذ: المفروض يرجعوا صفوف للحذف للأدمن بس
-- select tablename, policyname, cmd, qual from pg_policies
-- where schemaname='public' and tablename in ('parties','fiscal_periods','tax_documents') order by 1,2;
