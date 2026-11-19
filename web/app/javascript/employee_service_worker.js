// Never persist employee responses, bearer credentials, or timesheets offline.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', event => event.waitUntil(self.clients.claim()));
self.addEventListener('fetch', event => {
  if (event.request.mode !== 'navigate' || event.request.method !== 'GET') return;
  event.respondWith(fetch(event.request).catch(() => new Response(
    '<!doctype html><html lang="en"><meta name="viewport" content="width=device-width"><title>Rupert is offline</title><main><h1>You’re offline</h1><p>Reconnect to view or save your timesheet. No hours were saved by this page.</p><button onclick="location.reload()">Try again</button></main></html>',
    { status: 503, headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' } }
  )));
});

// Web Push (time & pay): show the notification and open its page on tap. Nothing is cached.
self.addEventListener('push', event => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; } catch (_error) { data = { title: 'Rupert', body: event.data && event.data.text() }; }
  const title = data.title || 'Rupert';
  const options = { body: data.body || '', data: { url: data.url || '/employee' }, tag: data.kind || 'rupert', icon: '/employee/icon-192.png?v=rupert-dog-1', badge: '/employee/icon-192.png?v=rupert-dog-1' };
  event.waitUntil(self.registration.showNotification(title, options));
});
self.addEventListener('notificationclick', event => {
  event.notification.close();
  const url = (event.notification.data && event.notification.data.url) || '/employee';
  event.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(clients => {
    const open = clients.find(client => 'focus' in client);
    if (open) { open.navigate(url); return open.focus(); }
    return self.clients.openWindow(url);
  }));
});
