-- ============================================================
-- قسم المساهمين (v1.93): رأس المال، الإيداع والسحب، توزيع الأرباح الشهري،
-- طلبات تعديل بيانات المساهم (المحاسب يطلب، الأدمن يوافق).
-- ملاحظة مهمة: كل القيود بتتسجل بـ doc_type = 'manual' عشان rebuild_journal
-- ماتمسحهاش (دالة الإعادة بتمسح كل حاجة ما عدا manual و opening_balance).
-- ============================================================

-- 1) حسابات جديدة
INSERT INTO accounts(code,name,type) VALUES
  ('2500','مستحق للمساهمين','Liability'),
  ('3100','رأس مال المساهمين','Equity'),
  ('3200','توزيعات الأرباح للمساهمين','Equity')
ON CONFLICT (code) DO NOTHING;

-- 2) الجداول
CREATE TABLE IF NOT EXISTS shareholder_settings(
  id int PRIMARY KEY DEFAULT 1 CHECK(id=1),
  loss_mode text NOT NULL DEFAULT 'proportional' CHECK(loss_mode IN('proportional','carry_forward'))
);
INSERT INTO shareholder_settings(id) VALUES(1) ON CONFLICT (id) DO NOTHING;

CREATE TABLE IF NOT EXISTS shareholders(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  phone text,
  email text,
  profit_mode text NOT NULL DEFAULT 'reinvest' CHECK(profit_mode IN('reinvest','withdraw')),
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz DEFAULT now(),
  created_by uuid DEFAULT auth.uid()
);

CREATE TABLE IF NOT EXISTS shareholder_movements(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shareholder_id uuid NOT NULL REFERENCES shareholders ON DELETE RESTRICT,
  date date NOT NULL DEFAULT current_date,
  type text NOT NULL CHECK(type IN('deposit','withdraw','profit_reinvest','profit_withdraw','profit_payout','loss')),
  amount numeric(14,2) NOT NULL CHECK(amount>0),
  entry_id uuid REFERENCES journal_entries ON DELETE SET NULL,
  run_id uuid,
  notes text,
  created_at timestamptz DEFAULT now(),
  created_by uuid DEFAULT auth.uid()
);

CREATE TABLE IF NOT EXISTS shareholder_profit_runs(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  month date NOT NULL,
  net_profit numeric(14,2) NOT NULL,
  total_avg_capital numeric(14,2) NOT NULL DEFAULT 0,
  status text NOT NULL DEFAULT 'Distributed' CHECK(status IN('Distributed','Carried','Consumed')),
  entry_id uuid REFERENCES journal_entries ON DELETE SET NULL,
  created_at timestamptz DEFAULT now(),
  created_by uuid DEFAULT auth.uid()
);

CREATE TABLE IF NOT EXISTS shareholder_change_requests(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shareholder_id uuid REFERENCES shareholders ON DELETE CASCADE,
  changes jsonb NOT NULL,
  status text NOT NULL DEFAULT 'Pending' CHECK(status IN('Pending','Approved','Rejected')),
  requested_by uuid DEFAULT auth.uid(),
  requested_at timestamptz DEFAULT now(),
  decided_by uuid,
  decided_at timestamptz,
  notes text
);

-- 3) الأمان: القراءة للأدمن والمحاسب بس، والكتابة من الدوال بس
ALTER TABLE shareholder_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE shareholders ENABLE ROW LEVEL SECURITY;
ALTER TABLE shareholder_movements ENABLE ROW LEVEL SECURITY;
ALTER TABLE shareholder_profit_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE shareholder_change_requests ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON shareholder_settings, shareholders, shareholder_movements, shareholder_profit_runs, shareholder_change_requests FROM PUBLIC, anon, authenticated;
GRANT SELECT ON shareholder_settings, shareholders, shareholder_movements, shareholder_profit_runs, shareholder_change_requests TO authenticated;

DROP POLICY IF EXISTS sel_shareholder_settings ON shareholder_settings;
DROP POLICY IF EXISTS sel_shareholders ON shareholders;
DROP POLICY IF EXISTS sel_shareholder_movements ON shareholder_movements;
DROP POLICY IF EXISTS sel_shareholder_profit_runs ON shareholder_profit_runs;
DROP POLICY IF EXISTS sel_shareholder_change_requests ON shareholder_change_requests;
CREATE POLICY sel_shareholder_settings ON shareholder_settings FOR SELECT TO authenticated USING (auth_role() IN ('admin','accountant'));
CREATE POLICY sel_shareholders ON shareholders FOR SELECT TO authenticated USING (auth_role() IN ('admin','accountant'));
CREATE POLICY sel_shareholder_movements ON shareholder_movements FOR SELECT TO authenticated USING (auth_role() IN ('admin','accountant'));
CREATE POLICY sel_shareholder_profit_runs ON shareholder_profit_runs FOR SELECT TO authenticated USING (auth_role() IN ('admin','accountant'));
CREATE POLICY sel_shareholder_change_requests ON shareholder_change_requests FOR SELECT TO authenticated USING (auth_role() IN ('admin','accountant'));

-- 4) متوسط رأس المال لكل مساهم خلال الشهر (بالأيام)
CREATE OR REPLACE FUNCTION shareholder_avg_capital(p_month date)
RETURNS TABLE(shareholder_id uuid, avg_capital numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public AS $$
  WITH b AS (
    SELECT date_trunc('month',p_month)::date AS s,
           ((date_trunc('month',p_month) + interval '1 month')::date - 1) AS e
  ),
  d AS (
    SELECT g::date AS dd FROM b, generate_series(b.s::timestamp, b.e::timestamp, interval '1 day') g
  ),
  bal AS (
    SELECT sh.id AS sid, d.dd,
      coalesce(sum(CASE WHEN m.type IN ('deposit','profit_reinvest') THEN m.amount
                        WHEN m.type IN ('withdraw','loss') THEN -m.amount
                        ELSE 0 END),0) AS cap
    FROM shareholders sh CROSS JOIN d
    LEFT JOIN shareholder_movements m ON m.shareholder_id=sh.id AND m.date<=d.dd
    GROUP BY sh.id, d.dd
  )
  SELECT sid, round(sum(cap) / ((SELECT e-s+1 FROM b)), 2) FROM bal
  WHERE auth_role() IN ('admin','accountant') GROUP BY sid
$$;
REVOKE ALL ON FUNCTION shareholder_avg_capital(date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION shareholder_avg_capital(date) TO authenticated;

-- 5) إيداع أو سحب من رأس المال (الأدمن والمحاسب)
CREATE OR REPLACE FUNCTION shareholder_capital_move(p_shareholder uuid, p_type text, p_amount numeric, p_date date DEFAULT current_date, p_notes text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_entry uuid := gen_random_uuid(); v_id uuid := gen_random_uuid(); v_cap numeric;
BEGIN
  IF auth_role() IS NULL OR auth_role() NOT IN ('admin','accountant') THEN RAISE EXCEPTION 'غير مسموح'; END IF;
  IF p_type NOT IN ('deposit','withdraw') THEN RAISE EXCEPTION 'نوع الحركة غير صحيح'; END IF;
  IF p_amount IS NULL OR p_amount<=0 THEN RAISE EXCEPTION 'المبلغ لازم يكون أكبر من صفر'; END IF;
  IF NOT EXISTS(SELECT 1 FROM shareholders WHERE id=p_shareholder) THEN RAISE EXCEPTION 'المساهم غير موجود'; END IF;

  IF p_type='withdraw' THEN
    SELECT coalesce(sum(CASE WHEN type IN ('deposit','profit_reinvest') THEN amount WHEN type IN ('withdraw','loss') THEN -amount END),0)
      INTO v_cap FROM shareholder_movements WHERE shareholder_id=p_shareholder AND date<=p_date;
    IF v_cap < p_amount THEN RAISE EXCEPTION 'رصيد رأس المال لا يكفي للسحب (المتاح %)', v_cap; END IF;
    INSERT INTO journal_entries(id,date,description,doc_type) VALUES(v_entry,p_date,'سحب من رأس مال مساهم','manual');
    INSERT INTO journal_lines(entry_id,account_code,debit,credit) VALUES(v_entry,'3100',p_amount,0),(v_entry,'1000',0,p_amount);
  ELSE
    INSERT INTO journal_entries(id,date,description,doc_type) VALUES(v_entry,p_date,'إيداع في رأس مال مساهم','manual');
    INSERT INTO journal_lines(entry_id,account_code,debit,credit) VALUES(v_entry,'1000',p_amount,0),(v_entry,'3100',0,p_amount);
  END IF;

  INSERT INTO shareholder_movements(id,shareholder_id,date,type,amount,entry_id,notes)
    VALUES(v_id,p_shareholder,p_date,p_type,p_amount,v_entry,p_notes);
  RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION shareholder_capital_move(uuid,text,numeric,date,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION shareholder_capital_move(uuid,text,numeric,date,text) TO authenticated;

-- 6) توزيع أرباح الشهر (الأدمن بس)
CREATE OR REPLACE FUNCTION shareholder_distribute_profit(p_month date)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
  s date := date_trunc('month',p_month)::date;
  e date := ((date_trunc('month',p_month) + interval '1 month')::date - 1);
  v_net numeric; v_carried numeric; v_dist numeric; v_total numeric; v_mode text;
  v_run uuid := gen_random_uuid(); v_entry uuid := gen_random_uuid();
  r record; v_share numeric; v_reinvest numeric:=0; v_payable numeric:=0; v_loss numeric:=0; v_count int:=0;
BEGIN
  IF auth_role() IS DISTINCT FROM 'admin' THEN RAISE EXCEPTION 'توزيع الأرباح للأدمن بس'; END IF;
  IF EXISTS(SELECT 1 FROM shareholder_profit_runs WHERE month=s AND status='Distributed') THEN
    RAISE EXCEPTION 'تم توزيع أرباح الشهر ده قبل كده';
  END IF;
  DELETE FROM shareholder_profit_runs WHERE month=s AND status='Carried';

  SELECT coalesce(sum(amount),0) INTO v_net FROM profit_loss(s,e);
  SELECT coalesce(sum(net_profit),0) INTO v_carried FROM shareholder_profit_runs WHERE status='Carried' AND month<s;
  v_dist := v_net + v_carried;
  SELECT loss_mode INTO v_mode FROM shareholder_settings WHERE id=1;

  IF v_dist < 0 AND v_mode='carry_forward' THEN
    INSERT INTO shareholder_profit_runs(id,month,net_profit,total_avg_capital,status)
      VALUES(v_run,s,v_net,0,'Carried');
    RETURN jsonb_build_object('status','carried','amount',v_net);
  END IF;
  IF v_dist = 0 THEN RETURN jsonb_build_object('status','zero'); END IF;

  SELECT coalesce(sum(avg_capital),0) INTO v_total FROM shareholder_avg_capital(s);
  IF v_total <= 0 THEN RAISE EXCEPTION 'ما فيش رأس مال للمساهمين في الشهر ده'; END IF;

  INSERT INTO shareholder_profit_runs(id,month,net_profit,total_avg_capital,status)
    VALUES(v_run,s,v_net,v_total,'Distributed');

  INSERT INTO journal_entries(id,date,description,doc_type)
    VALUES(v_entry,e,'توزيع أرباح/خسائر المساهمين '||to_char(s,'YYYY-MM'),'manual');

  FOR r IN
    SELECT a.shareholder_id AS sid, a.avg_capital AS ac, sh.profit_mode AS pm
    FROM shareholder_avg_capital(s) a JOIN shareholders sh ON sh.id=a.shareholder_id
    WHERE a.avg_capital>0
  LOOP
    v_share := round(v_dist * r.ac / v_total, 2);
    IF v_share = 0 THEN CONTINUE; END IF;
    v_count := v_count + 1;
    IF v_dist > 0 THEN
      IF r.pm='withdraw' THEN
        INSERT INTO shareholder_movements(shareholder_id,date,type,amount,entry_id,run_id,notes)
          VALUES(r.sid,e,'profit_withdraw',v_share,v_entry,v_run,'ربح شهر '||to_char(s,'YYYY-MM'));
        v_payable := v_payable + v_share;
      ELSE
        INSERT INTO shareholder_movements(shareholder_id,date,type,amount,entry_id,run_id,notes)
          VALUES(r.sid,e,'profit_reinvest',v_share,v_entry,v_run,'ربح شهر '||to_char(s,'YYYY-MM'));
        v_reinvest := v_reinvest + v_share;
      END IF;
    ELSE
      INSERT INTO shareholder_movements(shareholder_id,date,type,amount,entry_id,run_id,notes)
        VALUES(r.sid,e,'loss',-v_share,v_entry,v_run,'خسارة شهر '||to_char(s,'YYYY-MM'));
      v_loss := v_loss + (-v_share);
    END IF;
  END LOOP;

  IF v_dist > 0 THEN
    INSERT INTO journal_lines(entry_id,account_code,debit,credit) VALUES(v_entry,'3200',v_reinvest+v_payable,0);
    IF v_reinvest>0 THEN INSERT INTO journal_lines(entry_id,account_code,debit,credit) VALUES(v_entry,'3100',0,v_reinvest); END IF;
    IF v_payable>0 THEN INSERT INTO journal_lines(entry_id,account_code,debit,credit) VALUES(v_entry,'2500',0,v_payable); END IF;
  ELSE
    INSERT INTO journal_lines(entry_id,account_code,debit,credit) VALUES(v_entry,'3100',v_loss,0),(v_entry,'3200',0,v_loss);
  END IF;

  UPDATE shareholder_movements SET entry_id=v_entry WHERE run_id=v_run;
  UPDATE shareholder_profit_runs SET entry_id=v_entry WHERE id=v_run;
  UPDATE shareholder_profit_runs SET status='Consumed' WHERE status='Carried' AND month<s;

  RETURN jsonb_build_object('status','distributed','month',to_char(s,'YYYY-MM'),'net',v_net,'carried',v_carried,
    'reinvested',v_reinvest,'payable',v_payable,'loss',v_loss,'shareholders',v_count);
END $$;
REVOKE ALL ON FUNCTION shareholder_distribute_profit(date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION shareholder_distribute_profit(date) TO authenticated;

-- 7) صرف ربح مستحق للمساهم (الأدمن والمحاسب)
CREATE OR REPLACE FUNCTION shareholder_pay_profit(p_shareholder uuid, p_amount numeric, p_date date DEFAULT current_date, p_notes text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_entry uuid := gen_random_uuid(); v_id uuid := gen_random_uuid(); v_due numeric;
BEGIN
  IF auth_role() IS NULL OR auth_role() NOT IN ('admin','accountant') THEN RAISE EXCEPTION 'غير مسموح'; END IF;
  IF p_amount IS NULL OR p_amount<=0 THEN RAISE EXCEPTION 'المبلغ لازم يكون أكبر من صفر'; END IF;
  SELECT coalesce(sum(CASE WHEN type='profit_withdraw' THEN amount WHEN type='profit_payout' THEN -amount END),0)
    INTO v_due FROM shareholder_movements WHERE shareholder_id=p_shareholder;
  IF v_due < p_amount THEN RAISE EXCEPTION 'المستحق للمساهم لا يكفي (المتاح %)', v_due; END IF;
  INSERT INTO journal_entries(id,date,description,doc_type) VALUES(v_entry,p_date,'صرف ربح مستحق لمساهم','manual');
  INSERT INTO journal_lines(entry_id,account_code,debit,credit) VALUES(v_entry,'2500',p_amount,0),(v_entry,'1000',0,p_amount);
  INSERT INTO shareholder_movements(id,shareholder_id,date,type,amount,entry_id,notes)
    VALUES(v_id,p_shareholder,p_date,'profit_payout',p_amount,v_entry,p_notes);
  RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION shareholder_pay_profit(uuid,numeric,date,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION shareholder_pay_profit(uuid,numeric,date,text) TO authenticated;

-- 8) إضافة أو تعديل بيانات مساهم: الأدمن يطبّق مباشرة، والمحاسب يطلب ويستنى موافقة الأدمن
CREATE OR REPLACE FUNCTION shareholder_save(p_id uuid, p_data jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_req uuid := gen_random_uuid(); v_id uuid := p_id;
BEGIN
  IF auth_role() IS NULL OR auth_role() NOT IN ('admin','accountant') THEN RAISE EXCEPTION 'غير مسموح'; END IF;
  IF coalesce(p_data->>'name','')='' THEN RAISE EXCEPTION 'اسم المساهم مطلوب'; END IF;
  IF p_data->>'profit_mode' IS NOT NULL AND p_data->>'profit_mode' NOT IN ('reinvest','withdraw') THEN RAISE EXCEPTION 'طريقة الربح غير صحيحة'; END IF;

  IF auth_role()='admin' THEN
    IF p_id IS NULL THEN
      v_id := gen_random_uuid();
      INSERT INTO shareholders(id,name,phone,email,profit_mode,active)
        VALUES(v_id,p_data->>'name',p_data->>'phone',p_data->>'email',coalesce(p_data->>'profit_mode','reinvest'),coalesce((p_data->>'active')::boolean,true));
    ELSE
      UPDATE shareholders SET name=coalesce(p_data->>'name',name), phone=coalesce(p_data->>'phone',phone),
        email=coalesce(p_data->>'email',email), profit_mode=coalesce(p_data->>'profit_mode',profit_mode),
        active=coalesce((p_data->>'active')::boolean,active)
        WHERE id=p_id;
    END IF;
    RETURN jsonb_build_object('status','applied','id',v_id);
  END IF;

  -- المحاسب: طلب تعديل
  IF p_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM shareholders WHERE id=p_id) THEN RAISE EXCEPTION 'المساهم غير موجود'; END IF;
  INSERT INTO shareholder_change_requests(id,shareholder_id,changes) VALUES(v_req,p_id,p_data);
  INSERT INTO approval_requests(entity,entity_id,status) VALUES('shareholder_change',v_req,'Pending');
  RETURN jsonb_build_object('status','pending','request',v_req);
END $$;
REVOKE ALL ON FUNCTION shareholder_save(uuid,jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION shareholder_save(uuid,jsonb) TO authenticated;

-- 9) قرار الأدمن على طلب تعديل
CREATE OR REPLACE FUNCTION shareholder_decide_change(p_request uuid, p_approve boolean, p_notes text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE r shareholder_change_requests%ROWTYPE; v_id uuid;
BEGIN
  IF auth_role() IS DISTINCT FROM 'admin' THEN RAISE EXCEPTION 'الموافقة للأدمن بس'; END IF;
  SELECT * INTO r FROM shareholder_change_requests WHERE id=p_request AND status='Pending';
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير متاح'; END IF;
  PERFORM set_config('erp.shareholder_decide','1',true);
  IF p_approve THEN
    IF r.shareholder_id IS NULL THEN
      v_id := gen_random_uuid();
      INSERT INTO shareholders(id,name,phone,email,profit_mode,active)
        VALUES(v_id,r.changes->>'name',r.changes->>'phone',r.changes->>'email',coalesce(r.changes->>'profit_mode','reinvest'),coalesce((r.changes->>'active')::boolean,true));
    ELSE
      UPDATE shareholders SET name=coalesce(r.changes->>'name',name), phone=coalesce(r.changes->>'phone',phone),
        email=coalesce(r.changes->>'email',email), profit_mode=coalesce(r.changes->>'profit_mode',profit_mode),
        active=coalesce((r.changes->>'active')::boolean,active)
        WHERE id=r.shareholder_id;
    END IF;
  END IF;
  UPDATE shareholder_change_requests SET status=CASE WHEN p_approve THEN 'Approved' ELSE 'Rejected' END,
    decided_by=auth.uid(), decided_at=now(), notes=coalesce(p_notes,notes) WHERE id=p_request;
  UPDATE approval_requests SET status=CASE WHEN p_approve THEN 'Approved' ELSE 'Rejected' END,
    decided_by=auth.uid(), decided_at=now(), notes=coalesce(p_notes,notes)
    WHERE entity='shareholder_change' AND entity_id=p_request;
END $$;
REVOKE ALL ON FUNCTION shareholder_decide_change(uuid,boolean,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION shareholder_decide_change(uuid,boolean,text) TO authenticated;

-- 10) وضع الخسارة (الأدمن بس)
CREATE OR REPLACE FUNCTION shareholder_set_loss_mode(p_mode text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
  IF auth_role() IS DISTINCT FROM 'admin' THEN RAISE EXCEPTION 'للأدمن بس'; END IF;
  IF p_mode NOT IN ('proportional','carry_forward') THEN RAISE EXCEPTION 'وضع غير صحيح'; END IF;
  UPDATE shareholder_settings SET loss_mode=p_mode WHERE id=1;
END $$;
REVOKE ALL ON FUNCTION shareholder_set_loss_mode(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION shareholder_set_loss_mode(text) TO authenticated;


-- 11) حماية: طلبات المساهمين ماتتعتمدش إلا من شاشة المساهمين (الأدمن)، مش من decide_approval العامة
CREATE OR REPLACE FUNCTION trg_guard_shareholder_approval() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
  IF NEW.entity='shareholder_change' AND NEW.status IS DISTINCT FROM OLD.status THEN
    IF coalesce(current_setting('erp.shareholder_decide', true),'')<>'1' OR auth_role() IS DISTINCT FROM 'admin' THEN
      RAISE EXCEPTION 'طلبات تعديل المساهمين تتعتمد من شاشة المساهمين بواسطة الأدمن بس';
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS guard_shareholder_approval ON approval_requests;
CREATE TRIGGER guard_shareholder_approval BEFORE UPDATE ON approval_requests
  FOR EACH ROW EXECUTE FUNCTION trg_guard_shareholder_approval();

-- ============================================================
-- تحقق بعد التشغيل:
-- SELECT * FROM shareholder_avg_capital(date_trunc('month',current_date)::date);
-- SELECT has_function_privilege('anon','public.shareholder_distribute_profit(date)','EXECUTE'); -- false
-- ============================================================
