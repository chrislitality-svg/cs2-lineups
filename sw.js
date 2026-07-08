/* CS2 战术沙盘 · Service Worker
   离线壳 + 缓存 three.js / 雷达底图 / 字体；云同步(/cs2/sync)永远走网络，绝不缓存。
   换缓存策略时把 CACHE 版本号 +1 即可让旧缓存自动清掉。 */
const CACHE = 'cs2tac-sw-v3'; // bump: three 0.165 -> 0.184 (latest)
const SHELL = ['./', './index.html', './manifest.json'];

self.addEventListener('install', e => {
  self.skipWaiting();
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL).catch(() => {})));
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.map(k => (k === CACHE ? null : caches.delete(k)))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = req.url;

  // 云同步：永远网络优先、绝不缓存（否则会拿到过期数据覆盖）
  if (/\/cs2\/sync(\/|$)/.test(url)) return;

  // 雷达图/图标、three.js CDN、Google 字体 → cache-first（二次访问 / 弱网秒开）
  const cacheFirst =
    /\/imgs\//.test(url) ||
    /cdn\.jsdelivr\.net/.test(url) ||
    /fonts\.(googleapis|gstatic)\.com/.test(url);

  if (cacheFirst) {
    e.respondWith(
      caches.match(req).then(hit => {
        if (hit) return hit;
        return fetch(req).then(res => {
          if (res && (res.ok || res.type === 'opaque')) {
            const cp = res.clone();
            caches.open(CACHE).then(c => c.put(req, cp));
          }
          return res;
        });
      })
    );
    return;
  }

  // 其余同源资源（HTML 等）→ network-first，断网回退缓存（离线也能开）
  e.respondWith(
    fetch(req).then(res => {
      if (res && res.ok && new URL(url).origin === self.location.origin) {
        const cp = res.clone();
        caches.open(CACHE).then(c => c.put(req, cp));
      }
      return res;
    }).catch(() => caches.match(req).then(hit => hit || caches.match('./index.html')))
  );
});
