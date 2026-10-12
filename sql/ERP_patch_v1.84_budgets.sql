-- ERP patch v1.84: budgets (الموازنة والفعلي)
-- Run once in Supabase SQL editor. Idempotent.

create table if not exists public.budgets (
  id         uuid primary key default gen_random_uuid(),
  month      date not null,                       -- first day of the month
  category   text not null,
  amount     numeric(14,2) not null default 0 check (amount >= 0),
  created_at timestamptz not null default now(),
  constraint budgets_month_category_key unique (month, category)
);

alter table public.budgets enable row level security;

drop policy if exists budgets_select on public.budgets;
drop policy if exists budgets_insert on public.budgets;
drop policy if exists budgets_update on public.budgets;
drop policy if exists budgets_delete on public.budgets;

create policy budgets_select on public.budgets for select to authenticated
  using (public.auth_role() in ('admin','accountant'));
create policy budgets_insert on public.budgets for insert to authenticated
  with check (public.auth_role() in ('admin','accountant'));
create policy budgets_update on public.budgets for update to authenticated
  using (public.auth_role() in ('admin','accountant'))
  with check (public.auth_role() in ('admin','accountant'));
create policy budgets_delete on public.budgets for delete to authenticated
  using (public.auth_role() in ('admin','accountant'));

grant select, insert, update, delete on public.budgets to authenticated;
