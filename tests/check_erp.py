"""
فحص شامل للبرنامج على نسخة تجريبية (مش على بيانات العميل الحقيقية).

الاستخدام:
  ERP_URL=https://<your-site>/ ERP_USER=<username-or-email> ERP_PASS=<password> python3 tests/check_erp.py

بيعمل:
  1) تسجيل دخول بحساب تجريبي.
  2) يفتح كل صفحة في القائمة اللي الحساب يشوفها، ويسجل أي خطأ JavaScript أو خطأ ظاهر في الصفحة.
  3) يتحقق من الحسابات: ميزان المراجعة لازم يتوازن (مدين = دائن)، والمركز المالي يطبع الأرقام للمراجعة.
  4) يكتب تقرير في tests/report.md.
"""
import os, sys, json, datetime
from playwright.sync_api import sync_playwright

URL = os.environ.get('ERP_URL', '').strip()
USER = os.environ.get('ERP_USER', '').strip()
PASS = os.environ.get('ERP_PASS', '').strip()
if not (URL and USER and PASS):
    print('ضبط المتغيرات: ERP_URL, ERP_USER, ERP_PASS'); sys.exit(2)

results = []   # (name, ok, detail)
def rec(name, ok, detail=''):
    results.append((name, bool(ok), detail))
    print(('✓ ' if ok else '✗ ') + name + (f' — {detail}' if detail else ''))

with sync_playwright() as p:
    browser = p.chromium.launch(executable_path=os.environ.get('CHROME_PATH') or None, args=['--no-sandbox'])
    page = browser.new_page(viewport={'width': 1280, 'height': 860})
    errors = []
    page.on('pageerror', lambda e: errors.append(str(e)))
    page.on('console', lambda m: errors.append(m.text) if m.type == 'error' else None)

    page.goto(URL, wait_until='domcontentloaded')
    page.wait_for_selector('#lu', timeout=30000)
    page.fill('#lu', USER); page.fill('#lp', PASS)
    page.evaluate('login()')
    try:
        page.wait_for_selector('.sidebar', timeout=30000)
        rec('تسجيل الدخول', True)
    except Exception as e:
        rec('تسجيل الدخول', False, str(e)[:120]); browser.close(); sys.exit(1)

    version = page.evaluate('APP_VERSION')
    rec('إصدار الواجهة', True, version)

    # ---- الصفحات ----
    views = page.evaluate("NAV.filter(x=>can(x[0])).map(x=>[x[0],x[1]])")
    for vid, label in views:
        errors.clear()
        try:
            page.evaluate(f"go('{vid}')")
            page.wait_for_timeout(900)
            page.wait_for_function("!document.querySelector('.page') || document.querySelector('.page').innerText.trim().length>0", timeout=15000)
            text = page.inner_text('.page')
            bad_text = any(k in text for k in ['undefined', 'NaN', 'Error:', 'TypeError'])
            ok = not errors and not bad_text
            detail = ('; '.join(errors)[:160] if errors else '') + (' | نص مشبوه في الصفحة' if bad_text else '')
            rec(f'صفحة: {label} ({vid})', ok, detail)
        except Exception as e:
            rec(f'صفحة: {label} ({vid})', False, str(e)[:160])

    # ---- الحسابات ----
    try:
        tb = page.evaluate("(async()=>{const r=await sb.rpc('trial_balance',{});if(r.error)throw r.error;return r.data})()")
        dr = sum(float(x.get('debit') or 0) for x in tb); cr = sum(float(x.get('credit') or 0) for x in tb)
        rec('ميزان المراجعة متوازن (مدين = دائن)', abs(dr - cr) < 0.01, f'مدين {dr:,.2f} | دائن {cr:,.2f}')
    except Exception as e:
        rec('ميزان المراجعة متوازن (مدين = دائن)', False, str(e)[:160])

    try:
        today = datetime.date.today().isoformat()
        bs = page.evaluate(f"(async()=>{{const r=await sb.rpc('balance_sheet',{{p_as_of:'{today}'}});if(r.error)throw r.error;return r.data}})()")
        rec('المركز المالي متاح', True, f'{len(bs)} بند — راجعه بنفسك للتأكد من التوازن')
    except Exception as e:
        rec('المركز المالي متاح', False, str(e)[:160])

    # ---- ملخص ----
    failed = [r for r in results if not r[1]]
    os.makedirs('tests', exist_ok=True)
    with open('tests/report.md', 'w', encoding='utf-8') as f:
        f.write(f'# تقرير الفحص — {datetime.datetime.now():%Y-%m-%d %H:%M}\n\n')
        f.write(f'- الإصدار: {version}\n- الناجح: {len(results)-len(failed)} | الفاشل: {len(failed)}\n\n')
        for n, ok, d in results:
            f.write(f"- {'✅' if ok else '❌'} {n}" + (f' — {d}' if d else '') + '\n')
    print(f'\nالتقرير: tests/report.md — فشل {len(failed)} من {len(results)}')
    browser.close()
    sys.exit(1 if failed else 0)
