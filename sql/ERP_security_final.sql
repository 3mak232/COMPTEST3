-- ============================================================
-- الحالة النهائية لكل تحديثات الأمان (ملف واحد).
-- بيتشغل على مشروع فيه الـ schema الأساسي (الجداول والـ RLS الأساسي).
-- آمن للتشغيل أكتر من مرة.
-- الترتيب: الملف ده كله، ماعدا القسم F اللي بيتشغل بعد نشر الدالة والكود.
-- ============================================================

-- A) علامة الإصدار (بدل توكن الـ refresh القديم)
ALTER TABLE public.app_control ADD COLUMN IF NOT EXISTS app_version text;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema='public' AND table_name='app_control' AND column_name='refresh_token') THEN
    UPDATE public.app_control SET app_version = COALESCE(app_version, refresh_token);
    ALTER TABLE public.app_control DROP COLUMN refresh_token;
  END IF;
END $$;

-- B) دالة القراءة العامة لعلامة الإصدار (مش توكن)
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

-- C) حذف الدالة القديمة اللي كانت بتسرّب القيمة للزوار
DROP FUNCTION IF EXISTS public.app_refresh_token();

-- D) تشديد الكتابة على الجداول الحساسة
-- parties: المبيعات والمخزن يضيفوا ويعدّلوا، والحذف للأدمن بس
DROP POLICY IF EXISTS write_parties ON public.parties;
DROP POLICY IF EXISTS ins_parties ON public.parties;
DROP POLICY IF EXISTS upd_parties ON public.parties;
DROP POLICY IF EXISTS del_parties ON public.parties;
CREATE POLICY ins_parties ON public.parties FOR INSERT TO authenticated
  WITH CHECK (auth_role() = ANY (ARRAY['admin','accountant','sales','store']));
CREATE POLICY upd_parties ON public.parties FOR UPDATE TO authenticated
  USING (auth_role() = ANY (ARRAY['admin','accountant','sales','store']))
  WITH CHECK (auth_role() = ANY (ARRAY['admin','accountant','sales','store']));
CREATE POLICY del_parties ON public.parties FOR DELETE TO authenticated
  USING (auth_role() = 'admin');

-- fiscal_periods: الإضافة للأدمن والمحاسب، والتعديل والحذف للأدمن بس
DROP POLICY IF EXISTS write_fiscal_periods_admin ON public.fiscal_periods;
DROP POLICY IF EXISTS ins_fiscal_periods ON public.fiscal_periods;
DROP POLICY IF EXISTS upd_fiscal_periods ON public.fiscal_periods;
DROP POLICY IF EXISTS del_fiscal_periods ON public.fiscal_periods;
CREATE POLICY ins_fiscal_periods ON public.fiscal_periods FOR INSERT TO authenticated
  WITH CHECK (auth_role() = ANY (ARRAY['admin','accountant']));
CREATE POLICY upd_fiscal_periods ON public.fiscal_periods FOR UPDATE TO authenticated
  USING (auth_role() = 'admin') WITH CHECK (auth_role() = 'admin');
CREATE POLICY del_fiscal_periods ON public.fiscal_periods FOR DELETE TO authenticated
  USING (auth_role() = 'admin');

-- tax_documents: الإضافة والتعديل للأدمن والمحاسب، والحذف للأدمن بس
DROP POLICY IF EXISTS write_tax_documents ON public.tax_documents;
DROP POLICY IF EXISTS ins_tax_documents ON public.tax_documents;
DROP POLICY IF EXISTS upd_tax_documents ON public.tax_documents;
DROP POLICY IF EXISTS del_tax_documents ON public.tax_documents;
CREATE POLICY ins_tax_documents ON public.tax_documents FOR INSERT TO authenticated
  WITH CHECK (auth_role() = ANY (ARRAY['admin','accountant']));
CREATE POLICY upd_tax_documents ON public.tax_documents FOR UPDATE TO authenticated
  USING (auth_role() = ANY (ARRAY['admin','accountant']))
  WITH CHECK (auth_role() = ANY (ARRAY['admin','accountant']));
CREATE POLICY del_tax_documents ON public.tax_documents FOR DELETE TO authenticated
  USING (auth_role() = 'admin');

-- E) role_default_perms: القراءة للحسابات الفعّالة بس
DROP POLICY IF EXISTS rdp_select ON public.role_default_perms;
CREATE POLICY rdp_select ON public.role_default_perms FOR SELECT TO authenticated
  USING (auth_role() IS NOT NULL);

-- ============================================================
-- F) قفل resolve_login عن الزوار. شغّله بعد ما:
--    1) تنشر دالة login-with-identifier
--    2) تنشر app.js اللي بيكلمها
--    3) تتأكد إن تسجيل الدخول بالاسم والموبايل شغال
-- ============================================================
-- REVOKE EXECUTE ON FUNCTION public.resolve_login(text) FROM PUBLIC, anon, authenticated;
-- GRANT EXECUTE ON FUNCTION public.resolve_login(text) TO service_role;

-- ============================================================
-- تحقق بعد التشغيل
-- ============================================================
-- SELECT has_function_privilege('anon', 'public.app_version()', 'EXECUTE');       -- true
-- SELECT has_function_privilege('anon', 'public.resolve_login(text)', 'EXECUTE'); -- false بعد القسم F
-- SELECT tablename, policyname, cmd FROM pg_policies
--  WHERE schemaname='public' AND tablename IN ('parties','fiscal_periods','tax_documents','role_default_perms')
--  ORDER BY 1,2;
