# اختبار قسم المساهمين (محلي)

يشغّل السيناريوهات على PostgreSQL محلي، بمحاكاة بسيطة لـ Supabase (auth.uid و auth_role وجداول الحسابات والقيود).

    createdb shtest
    psql -d shtest -f tests/shareholders/mock_base.sql
    psql -d shtest -f sql/SHAREHOLDERS_v1.93.sql
    psql -d shtest -f tests/shareholders/scenarios.sql

النتايج المتوقعة: مجموع المدين = الدائن (فرق 0)، والمحاسب ما يقدرش يوزّع أو يعتمد طلب تعديل بنفسه، والمبيعات ما يشوفش رأس المال.
