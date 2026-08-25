const CACHE='padel-v10-3';
const STATIC_FALLBACK=['./','./index.html'];

self.addEventListener('install',event=>{
  event.waitUntil(caches.open(CACHE).then(cache=>cache.addAll(STATIC_FALLBACK)));
  self.skipWaiting();
});

self.addEventListener('activate',event=>{
  event.waitUntil(
    caches.keys().then(keys=>Promise.all(keys.filter(key=>key!==CACHE).map(key=>caches.delete(key))))
      .then(()=>self.clients.claim())
  );
});

self.addEventListener('fetch',event=>{
  if(event.request.method!=='GET')return;
  const url=new URL(event.request.url);

  // JavaScript, CSS og manifest hentes altid direkte fra nettet,
  // så nye GitHub-versioner ikke bliver hængende i PWA-cachen.
  if(/\.(js|css|webmanifest)$/.test(url.pathname)){
    event.respondWith(fetch(event.request,{cache:'no-store'}));
    return;
  }

  // HTML: network-first med offline fallback.
  if(event.request.mode==='navigate'){
    event.respondWith(
      fetch(event.request,{cache:'no-store'})
        .then(response=>{
          const copy=response.clone();
          caches.open(CACHE).then(cache=>cache.put('./index.html',copy));
          return response;
        })
        .catch(()=>caches.match('./index.html'))
    );
  }
});
