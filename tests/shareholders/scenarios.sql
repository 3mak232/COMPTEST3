\set ON_ERROR_STOP 0
\pset pager off
-- إعداد بيانات الاختبار كسوبر يوزر
INSERT INTO journal_entries(id,date,description,doc_type) VALUES
 ('10000000-0000-0000-0000-000000000001','2026-09-10','مبيعات سبتمبر','sales_invoice'),
 ('10000000-0000-0000-0000-000000000002','2026-09-12','مصروف سبتمبر','expense');
INSERT INTO journal_lines(entry_id,account_code,debit,credit) VALUES
 ('10000000-0000-0000-0000-000000000001','1000',3000,0),('10000000-0000-0000-0000-000000000001','4000',0,3000),
 ('10000000-0000-0000-0000-000000000002','6000',500,0),('10000000-0000-0000-0000-000000000002','1000',0,500);

\echo '=== 1) الأدمن: إضافة مساهمين'
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000a',false);
SELECT shareholder_save(NULL,'{"name":"أحمد","profit_mode":"reinvest"}'::jsonb) AS a_res;
SELECT shareholder_save(NULL,'{"name":"محمد","profit_mode":"withdraw"}'::jsonb) AS b_res;
SELECT id,name,profit_mode FROM shareholders ORDER BY name;
RESET ROLE;

\echo '=== 2) إيداعات (الأدمن)'
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000a',false);
SELECT shareholder_capital_move((SELECT id FROM shareholders WHERE name='أحمد'),'deposit',10000,'2026-09-01','رأس مال أولي');
SELECT shareholder_capital_move((SELECT id FROM shareholders WHERE name='محمد'),'deposit',5000,'2026-09-16','رأس مال أولي');
RESET ROLE;

\echo '=== 3) متوسط رأس المال سبتمبر (المتوقع أحمد 10000، محمد 2500)'
SELECT s.name, a.avg_capital FROM shareholder_avg_capital('2026-09-01') a JOIN shareholders s ON s.id=a.shareholder_id ORDER BY s.name;

\echo '=== 4) توزيع سبتمبر (المتوقع: ربح 2500، أحمد 2000 يتضاف، محمد 500 مستحق)'
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000a',false);
SELECT shareholder_distribute_profit('2026-09-01') AS dist_sep;
SELECT s.name, m.type, m.amount FROM shareholder_movements m JOIN shareholders s ON s.id=m.shareholder_id WHERE m.type LIKE 'profit%' ORDER BY s.name;
RESET ROLE;

\echo '=== 5) محاولة توزيع نفس الشهر تاني (المتوقع خطأ)'
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000a',false);
SELECT shareholder_distribute_profit('2026-09-01');
RESET ROLE;

\echo '=== 6) صرف 200 من مستحق محمد (المتوقع المتبقي 300)'
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000a',false);
SELECT shareholder_pay_profit((SELECT id FROM shareholders WHERE name='محمد'),200,'2026-10-02','صرف جزء');
SELECT coalesce(sum(CASE WHEN type='profit_withdraw' THEN amount WHEN type='profit_payout' THEN -amount END),0) AS due_left FROM shareholder_movements m JOIN shareholders s ON s.id=m.shareholder_id WHERE s.name='محمد';
RESET ROLE;

\echo '=== 7) سحب 1000 من رأس مال أحمد بتاريخ 3 أكتوبر'
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000a',false);
SELECT shareholder_capital_move((SELECT id FROM shareholders WHERE name='أحمد'),'withdraw',1000,'2026-10-03','سحب');
RESET ROLE;

\echo '=== 8) المحاسب: محاولة توزيع (المتوقع رفض)'
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000b',false);
SELECT shareholder_distribute_profit('2026-10-01');
RESET ROLE;

\echo '=== 9) المحاسب: طلب تعديل اسم (المتوقع pending)'
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000b',false);
SELECT shareholder_save((SELECT id FROM shareholders WHERE name='محمد'),'{"name":"محمد علي","phone":"0100"}'::jsonb) AS req;
RESET ROLE;
SELECT name FROM shareholders WHERE name='محمد';

\echo '=== 10) الأدمن يوافق على الطلب'
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000a',false);
SELECT shareholder_decide_change((SELECT id FROM shareholder_change_requests WHERE status='Pending'),true,'موافق');
RESET ROLE;
SELECT name,phone FROM shareholders WHERE phone='0100';
SELECT status FROM approval_requests WHERE entity='shareholder_change';

\echo '=== 11) المبيعات: قراءة متوسط رأس المال (المتوقع صفوف فاضية)'
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000c',false);
SELECT count(*) AS sales_sees_capital FROM shareholder_avg_capital('2026-09-01');
SELECT count(*) AS sales_sees_movements FROM shareholder_movements;
RESET ROLE;

\echo '=== 12) خسارة أكتوبر: مصروف 8000 (توزيع نسبي)'
INSERT INTO journal_entries(id,date,description,doc_type) VALUES ('10000000-0000-0000-0000-000000000003','2026-10-05','مصروف أكتوبر','expense');
INSERT INTO journal_lines(entry_id,account_code,debit,credit) VALUES ('10000000-0000-0000-0000-000000000003','6000',8000,0),('10000000-0000-0000-0000-000000000003','1000',0,8000);
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000a',false);
SELECT shareholder_distribute_profit('2026-10-01') AS dist_oct;
RESET ROLE;
SELECT s.name, m.type, m.amount FROM shareholder_movements m JOIN shareholders s ON s.id=m.shareholder_id WHERE m.type='loss' ORDER BY s.name;

\echo '=== 13) فحص التوازن: مجموع المدين = الدائن'
SELECT sum(debit) AS total_debit, sum(credit) AS total_credit, sum(debit)-sum(credit) AS diff FROM journal_lines;
\echo '=== 14) أرصدة الحسابات الجديدة'
SELECT a.code, a.name, sum(l.debit)-sum(l.credit) AS dr_minus_cr FROM journal_lines l JOIN accounts a ON a.code=l.account_code WHERE a.code IN ('1000','2500','3100','3200') GROUP BY a.code,a.name ORDER BY a.code;

\echo '=== 15) وضع الخسارة: ترحيل (نوفمبر خسارة 1000 ثم ديسمبر ربح 3000)'
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000a',false);
SELECT shareholder_set_loss_mode('carry_forward');
RESET ROLE;
INSERT INTO journal_entries(id,date,description,doc_type) VALUES ('10000000-0000-0000-0000-000000000004','2026-11-05','مصروف نوفمبر','expense'),('10000000-0000-0000-0000-000000000005','2026-12-05','ربح ديسمبر','sales_invoice');
INSERT INTO journal_lines(entry_id,account_code,debit,credit) VALUES ('10000000-0000-0000-0000-000000000004','6000',1000,0),('10000000-0000-0000-0000-000000000004','1000',0,1000),('10000000-0000-0000-0000-000000000005','1000',3000,0),('10000000-0000-0000-0000-000000000005','4000',0,3000);
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000a',false);
SELECT shareholder_distribute_profit('2026-11-01') AS nov;
SELECT shareholder_distribute_profit('2026-12-01') AS dec;
RESET ROLE;
SELECT month, net_profit, status FROM shareholder_profit_runs ORDER BY month;

\echo '=== 16) فحص التوازن النهائي'
SELECT sum(debit)-sum(credit) AS final_diff FROM journal_lines;
\echo '=== 17) الصلاحيات: anon'
SELECT has_function_privilege('anon','public.shareholder_distribute_profit(date)','EXECUTE') AS anon_dist, has_function_privilege('anon','public.shareholder_avg_capital(date)','EXECUTE') AS anon_avg;

\echo '=== 18) المحاسب يحاول يعتمد طلب تعديل مباشرة (المتوقع رفض)'
INSERT INTO shareholders(id,name,profit_mode) VALUES('20000000-0000-0000-0000-000000000001','تجربة','reinvest');
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000b',false);
SELECT shareholder_save('20000000-0000-0000-0000-000000000001','{"name":"تجربة2"}'::jsonb) AS req2;
UPDATE approval_requests SET status='Approved' WHERE entity='shareholder_change' AND status='Pending';
RESET ROLE;
SELECT status FROM approval_requests WHERE entity='shareholder_change' ORDER BY requested_at DESC LIMIT 1;
\echo '=== 19) الأدمن يعتمد من الشاشة (المتوقع نجاح)'
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000a',false);
SELECT shareholder_decide_change((SELECT id FROM shareholder_change_requests WHERE status='Pending'),true);
RESET ROLE;
SELECT name FROM shareholders WHERE id='20000000-0000-0000-0000-000000000001';
