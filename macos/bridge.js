// Injected into the Nexview page. Its job:
// give the native app its own read-only access key for this account, so the app can check
// notifications by itself, even with the window closed. The page's session token and the
// password never leave the page; only the read-only key is handed over.
(() => {
  if (window.__nexviewMac) return;
  window.__nexviewMac = true;
  const post = (m) => { try { window.webkit.messageHandlers.nexview.postMessage(m); } catch (e) {} };
  let auth = null;
  let apiBase = null;     // everything before "/api/", so a URL base path behind a proxy keeps working
  let reported = false;
  let keyId = null;       // id of the app's read-only key for this account (told by the app), deleted on sign-out

  const origFetch = window.fetch;
  window.fetch = async function (input, init) {
    try {
      const a = new Headers((init && init.headers) || (input instanceof Request ? input.headers : undefined)).get('authorization');
      if (a) auth = a;
    } catch (e) {}
    const reqUrl = (() => { try { return typeof input === 'string' ? input : (input && input.url) || String(input || ''); } catch (e) { return ''; } })();
    let deletedId = null;
    // Signing out: delete the app's key on the server while the session is still valid.
    if (/\/api\/auth\/logout/.test(reqUrl) && keyId && auth) {
      const id = keyId;
      try { if (await deleteKey(id)) deletedId = id; } catch (e) {}
    }
    const res = await origFetch.apply(this, arguments);
    try {
      const url = reqUrl;
      const i = url.indexOf('/api/');
      if (i >= 0 && apiBase === null) apiBase = url.slice(0, i);
      if (/\/api\/auth\/logout/.test(url)) { auth = null; reported = false; keyId = null; post({ type: 'signedOut', deletedId }); }
      else if (res.ok && /\/api\/notifications/.test(url)) post({ type: 'refresh' });  // read/cleared: update the badge now
      else if (res.ok && auth && !reported) reportSession();
      if (res.ok && auth) post({ type: 'alive' });
    } catch (e) {}
    return res;
  };

  const call = (path, opts) => origFetch((apiBase || '') + path, {
    ...opts, credentials: 'include',
    headers: { ...(opts.headers || {}), Authorization: auth, 'Content-Type': 'application/json' },
  });
  // With the window closed the page sleeps and its short-lived token can expire. Renew it the way
  // Nexview's own client does (the refresh cookie), then try once more.
  const api = async (path, opts = {}) => {
    let r = await call(path, opts);
    if (r.status === 401) {
      const f = await origFetch((apiBase || '') + '/api/auth/refresh', { method: 'POST', credentials: 'same-origin' });
      const t = f.ok ? (await f.json()).access_token : null;
      if (t) { auth = 'Bearer ' + t; r = await call(path, opts); }
    }
    return r;
  };

  async function reportSession() {
    reported = true;
    try {
      const r = await api('/api/auth/me');
      if (!r.ok) { reported = false; return; }
      const me = await r.json();
      post({ type: 'session', user: me.username });
    } catch (e) { reported = false; }
  }

  // Called by the app after its key was rejected (401): report the session again so a new key is made.
  window.__nexviewMacResetSession = () => { reported = false; if (auth) reportSession(); };

  // Called by the app when it has no key for this account yet.
  window.__nexviewMacMakeKey = async (name) => {
    if (!auth) return;
    try {
      const list = await api('/api/auth/me/schluessel');
      if (list.ok) {
        for (const k of await list.json()) {
          if (k.name === name) await api('/api/auth/me/schluessel/' + k.id, { method: 'DELETE' });
        }
      }
      const r = await api('/api/auth/me/schluessel', { method: 'POST', body: JSON.stringify({ name, nur_lesen: true }) });
      if (!r.ok) return;
      const k = await r.json();
      keyId = k.id || null;
      const me = await (await api('/api/auth/me')).json();
      post({ type: 'apikey', key: k.schluessel, id: k.id, user: me.username });
    } catch (e) {}
  };

  async function deleteKey(id) {
    const r = await api('/api/auth/me/schluessel/' + encodeURIComponent(id), { method: 'DELETE' });
    return r.ok || r.status === 404;        // 404: already gone
  }

  // Called by the app: the id of its key for the signed-in account, so sign-out can delete it.
  window.__nexviewMacSetKeyId = (id) => { keyId = id || null; };

  // Called by the app to delete one of its keys with the page's session. Resolves true when gone.
  window.__nexviewMacDeleteKey = async (id) => {
    if (!auth || !id) return false;
    try {
      const ok = await deleteKey(id);
      if (ok && keyId === id) keyId = null;
      return ok;
    } catch (e) { return false; }
  };

  // Called by the app when notifications were cleared in macOS: mark them read in Nexview.
  window.__nexviewMacMarkRead = async (ids) => {
    if (!auth) return;
    const done = [];
    for (const id of ids) {
      try {
        const r = await api('/api/notifications/' + id + '/read', { method: 'POST' });
        if (r.ok || r.status === 404) done.push(id);      // 404: already gone, nothing left to do
      } catch (e) {}
    }
    if (done.length) post({ type: 'marked', ids: done });
  };

})();
