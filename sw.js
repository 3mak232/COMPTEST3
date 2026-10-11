const CACHE='erp-business-shell-v53';
const ASSETS=['./','./index.html','./style.css','./manifest.webmanifest'];
self.addEventListener('install',event=>event.waitUntil(caches.open(CACHE).then(c=>c.addAll(ASSETS)).then(()=>self.skipWaiting())));
self.addEventListener('activate',event=>event.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(k=>k!==CACHE).map(k=>caches.delete(k)))).then(()=>self.clients.claim())));
// الشبكة أولاً: أي تحديث بيوصل المستخدم فوراً، والكاش بيشتغل بس لو مفيش نت
self.addEventListener('fetch',event=>{
  const req=event.request;
  if(req.method!=='GET') return;
  const url=new URL(req.url);
  // لا نخزن طلبات Supabase (API/Auth)، ونخزن الشل المحلي بس
  if(url.origin!==self.location.origin) return;
  const key=req.mode==='navigate'?'./index.html':req;
  event.respondWith(fetch(req).then(r=>{if(r&&r.ok){const copy=r.clone();caches.open(CACHE).then(c=>c.put(key,copy))}return r}).catch(()=>caches.match(key)));
});
