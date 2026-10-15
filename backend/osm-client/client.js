import { osmAuth } from 'osm-auth';

/** Bind these helpers to explicit reviewer buttons, never to a background worker.
 * Configure an OSM OAuth application with an exact HTTPS redirect URI and write_api.
 * OSM tokens stay in osm-auth's browser storage; never send them to PausePath.
 */
export function createOSMReviewClient({ clientId, redirectUri, apiBase, getPausePathToken }) {
  const auth = osmAuth({ client_id: clientId, redirect_uri: redirectUri,
    scope: 'read_prefs write_api', singlepage: true, auto: false });
  async function api(path, method = 'GET', body) {
    const response = await fetch(`${apiBase}/api/v1${path}`, {
      method, headers: { Authorization: `Bearer ${await getPausePathToken()}`, 'Content-Type': 'application/json' },
      body: body === undefined ? undefined : JSON.stringify(body), cache: 'no-store'
    });
    if (!response.ok) throw new Error(`PausePath request failed (${response.status})`);
    return response.json();
  }
  function osm(method, path, content) {
    return new Promise((resolve, reject) => auth.xhr({ method, path, content,
      headers: content ? { 'Content-Type': 'text/xml' } : undefined },
    (error, result) => error ? reject(error) : resolve(result)));
  }
  function xmlDocument(root) { return document.implementation.createDocument('', root); }
  function tag(doc, parent, key, value) {
    const element = doc.createElement('tag'); element.setAttribute('k', key); element.setAttribute('v', value);
    parent.appendChild(element);
  }
  function serialize(doc) { return new XMLSerializer().serializeToString(doc); }
  function parse(value) {
    const doc = typeof value === 'string' ? new DOMParser().parseFromString(value, 'text/xml') : value;
    if (!doc || doc.querySelector('parsererror')) throw new Error('Invalid OSM XML response');
    return doc;
  }
  return {
    authenticate: () => auth.authenticateAsync(),
    completeOAuthRedirect: () => auth.authenticateAsync(),
    logout: () => auth.logout(),
    listQueue: () => api('/osm/queue'),
    queueVerifiedPOI: ({ poiId, action, independentSurveyEvidence }) => api('/osm/queue', 'POST', {
      poi_id: poiId, action, evidence: independentSurveyEvidence
    }),
    /** Call only after the reviewer has inspected the queued location, tags and
     * independent survey evidence, checked for duplicates, and confirmed submission.
     * No retries after claiming: ambiguous failures require changeset reconciliation.
     */
    async submitReviewedEdit(editId) {
      if (!auth.authenticated()) throw new Error('Sign in to OSM before submitting an edit');
      const entry = await api(`/osm/queue/${editId}/claim`, 'POST');
      let changesetId;
      let recorded = false;
      try {
        let existing;
        if (entry.action === 'remove') {
          if (!/^node\/\d+$/.test(entry.payload.external_id)) throw new Error('Only OSM nodes are supported');
          const doc = parse(await osm('GET', `/api/0.6/${entry.payload.external_id}`));
          existing = doc.querySelector('node');
          if (!existing || existing.getAttribute('visible') === 'false') throw new Error('Node is absent; reconcile manually');
          const amenity = [...existing.querySelectorAll('tag')].find(t => t.getAttribute('k') === 'amenity');
          if (!amenity || amenity.getAttribute('v') !== entry.payload.tags.amenity) throw new Error('OSM amenity changed; review the latest node');
        }
        const cs = xmlDocument('osm'); const changeset = cs.createElement('changeset'); cs.documentElement.appendChild(changeset);
        tag(cs, changeset, 'created_by', 'PausePath community review');
        tag(cs, changeset, 'comment', entry.action === 'add' ? 'Add independently surveyed public amenity' : 'Mark surveyed amenity as no longer operating');
        tag(cs, changeset, 'source', 'survey');
        const created = await osm('PUT', '/api/0.6/changeset/create', serialize(cs));
        changesetId = Number(typeof created === 'string' ? created : created?.documentElement?.textContent);
        if (!Number.isSafeInteger(changesetId) || changesetId <= 0) throw new Error('Changeset response ambiguous; reconcile before retrying');
        await api(`/osm/queue/${editId}/changeset/${changesetId}`, 'PUT'); recorded = true;
        const change = xmlDocument('osmChange'); change.documentElement.setAttribute('version', '0.6');
        change.documentElement.setAttribute('generator', 'PausePath');
        const operation = change.createElement(entry.action === 'add' ? 'create' : 'modify'); change.documentElement.appendChild(operation);
        let node;
        if (entry.action === 'add') {
          node = change.createElement('node'); node.setAttribute('id', '-1'); node.setAttribute('version', '0');
          node.setAttribute('lon', entry.payload.location.coordinates[0]); node.setAttribute('lat', entry.payload.location.coordinates[1]);
          for (const [key, value] of Object.entries(entry.payload.tags)) tag(change, node, key, value);
        } else {
          // Retire only the amenity tag, preserving the node, topology and other tags.
          // OSM version matching rejects concurrent edits instead of overwriting them.
          node = change.importNode(existing, true);
          for (const attr of ['user','uid','timestamp']) node.removeAttribute(attr);
          const amenity = [...node.querySelectorAll('tag')].find(t => t.getAttribute('k') === 'amenity');
          if ([...node.querySelectorAll('tag')].some(t => t.getAttribute('k') === 'disused:amenity')) throw new Error('Existing lifecycle tag requires manual review');
          amenity.setAttribute('k', 'disused:amenity');
        }
        node.setAttribute('changeset', String(changesetId)); operation.appendChild(node);
        await osm('POST', `/api/0.6/changeset/${changesetId}/upload`, serialize(change));
        await api(`/osm/queue/${editId}/receipt`, 'POST', { status: 'submitted', changeset_id: changesetId });
        return { changesetId, url: `https://www.openstreetmap.org/changeset/${changesetId}` };
      } catch (error) {
        if (recorded) {
          try { await api(`/osm/queue/${editId}/receipt`, 'POST', { status: 'needs_reconciliation', changeset_id: changesetId }); } catch { /* claimed entry remains blocked */ }
        }
        throw new Error(`Edit is blocked for manual reconciliation${changesetId ? ` (changeset ${changesetId})` : ''}. ${error.message}`);
      } finally {
        if (changesetId) { try { await osm('PUT', `/api/0.6/changeset/${changesetId}/close`); } catch { /* close manually if needed */ } }
      }
    }
  };
}
