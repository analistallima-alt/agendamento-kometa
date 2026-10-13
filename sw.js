/* Service worker do app Kometa Agenda.
   - Abre o app mesmo com internet fraca (usa a última versão salva).
   - Sempre tenta buscar a versão mais nova primeiro, então atualizações chegam sozinhas.
   - Nunca guarda dados de agendamento: chamadas ao Supabase e a outros sites passam direto. */
const CACHE = "kometa-agenda-v4";
const ARQUIVOS = ["./", "./index.html", "./manifest.webmanifest", "./icon-192.png", "./icon-512.png", "./apple-touch-icon.png", "./favicon-64.png"];

self.addEventListener("install", (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => Promise.all(ARQUIVOS.map((u) => c.add(u).catch(() => null)))).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (e) => {
  e.waitUntil(caches.keys().then((ks) => Promise.all(ks.filter((k) => k !== CACHE).map((k) => caches.delete(k)))).then(() => self.clients.claim()));
});

self.addEventListener("fetch", (e) => {
  const req = e.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return; // Supabase, fontes, Receita: sempre pela internet

  // Página: tenta a internet primeiro; sem conexão, usa a cópia salva
  if (req.mode === "navigate" || url.pathname.endsWith(".html") || url.pathname.endsWith("/")) {
    e.respondWith(
      fetch(req).then((r) => {
        if (r && r.ok) { const copia = r.clone(); caches.open(CACHE).then((c) => c.put("./index.html", copia)); }
        return r;
      }).catch(() => caches.match("./index.html").then((r) => r || caches.match("./")))
    );
    return;
  }
  // Ícones e manifesto: cópia salva primeiro
  e.respondWith(caches.match(req).then((r) => r || fetch(req).then((resp) => {
    if (resp && resp.ok) { const copia = resp.clone(); caches.open(CACHE).then((c) => c.put(req, copia)); }
    return resp;
  })));
});

/* Clique na notificação de novo agendamento: abre o app (ou traz para frente) no agendamento */
self.addEventListener("notificationclick", (e) => {
  e.notification.close();
  const p = (e.notification.data && e.notification.data.p) || "";
  e.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((cs) => {
    const c = cs.find((x) => x.url.startsWith(self.registration.scope)) || cs[0];
    if (c) { c.postMessage({ abrir: p }); return c.focus(); }
    return self.clients.openWindow("./" + (/^KM-/.test(p) ? "#ag=" + p : ""));
  }));
});
