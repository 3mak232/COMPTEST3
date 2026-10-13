DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role NOLOGIN; END IF;
END $$;
DROP SCHEMA IF EXISTS auth CASCADE; DROP SCHEMA IF EXISTS public CASCADE;
CREATE SCHEMA auth; CREATE SCHEMA public;
GRANT USAGE ON SCHEMA public, auth TO anon, authenticated, service_role;
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('request.jwt.claim.sub', true),'')::uuid $$;
CREATE TABLE auth.users(id uuid PRIMARY KEY, email text);
CREATE TABLE public.profiles(id uuid PRIMARY KEY REFERENCES auth.users, role text NOT NULL, active boolean NOT NULL DEFAULT true);
CREATE OR REPLACE FUNCTION public.auth_role() RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public AS $$
  SELECT CASE WHEN p.role='developer' THEN 'admin' ELSE p.role END FROM profiles p WHERE p.id=auth.uid() AND p.active $$;
CREATE TABLE accounts(code text PRIMARY KEY, name text NOT NULL, type text NOT NULL CHECK(type IN('Asset','Liability','Equity','Revenue','Expense','COGS')));
INSERT INTO accounts VALUES('1000','Cash','Asset'),('1300','AR','Asset'),('3000','Equity','Equity'),('4000','Sales','Revenue'),('6000','Expenses','Expense');
CREATE TABLE journal_entries(id uuid PRIMARY KEY DEFAULT gen_random_uuid(), date date DEFAULT current_date, description text, doc_type text, doc_id uuid, created_by uuid DEFAULT auth.uid());
CREATE TABLE journal_lines(id uuid PRIMARY KEY DEFAULT gen_random_uuid(), entry_id uuid NOT NULL REFERENCES journal_entries ON DELETE CASCADE, account_code text NOT NULL REFERENCES accounts, debit numeric(14,2) DEFAULT 0, credit numeric(14,2) DEFAULT 0, CHECK(debit>=0 AND credit>=0));
CREATE TABLE approval_requests(id uuid PRIMARY KEY DEFAULT gen_random_uuid(), entity text NOT NULL, entity_id uuid NOT NULL, requested_by uuid DEFAULT auth.uid(), status text NOT NULL DEFAULT 'Pending' CHECK(status IN('Pending','Approved','Rejected','Cancelled')), requested_at timestamptz DEFAULT now(), decided_by uuid, decided_at timestamptz, notes text);
CREATE OR REPLACE FUNCTION profit_loss(p_from date DEFAULT date_trunc('month',current_date)::date,p_to date DEFAULT current_date)
RETURNS TABLE(account_code text,account_name text,amount numeric)
LANGUAGE sql SECURITY DEFINER STABLE SET search_path=public AS $$
  SELECT a.code,a.name,round(sum(l.credit-l.debit),2) amount
  FROM accounts a JOIN journal_lines l ON l.account_code=a.code JOIN journal_entries e ON e.id=l.entry_id
  WHERE e.date BETWEEN p_from AND p_to AND a.type IN ('Revenue','Expense','COGS') AND auth_role() IN ('admin','accountant')
  GROUP BY a.code,a.name ORDER BY a.code $$;
GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT SELECT ON accounts TO authenticated;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO service_role;
INSERT INTO auth.users VALUES('00000000-0000-0000-0000-00000000000a','admin@x'),('00000000-0000-0000-0000-00000000000b','acc@x'),('00000000-0000-0000-0000-00000000000c','sales@x');
INSERT INTO profiles VALUES('00000000-0000-0000-0000-00000000000a','admin',true),('00000000-0000-0000-0000-00000000000b','accountant',true),('00000000-0000-0000-0000-00000000000c','sales',true);
