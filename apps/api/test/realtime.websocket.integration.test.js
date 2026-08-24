const http = require('node:http');
const jwt = require('jsonwebtoken');
const WebSocket = require('ws');
const {
  API_PREFIX,
  app,
  pool,
  request,
  authHeader,
  resetDb,
  shutdown,
  registerUser,
  loginUser,
  approveContributorRequest,
  createAdminUser,
  createCategory,
  createProject,
  createAssignment,
} = require('./helpers/api-test-helpers');
const { attachWorkflowSocket } = require('../src/realtime/workflowSocket');
const {
  emitRealtimeDomainEvent,
  publishRealtimeChange,
} = require('../src/realtime/realtimeEvents');
const { createRealtimeEvent } = require('../src/realtime/realtimeProtocol');
const { startWorkflowChangeListener } = require('../src/realtime/workflowEvents');

const delay = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

const connectRealtime = async ({ url, token, scopes, knownRevisions = [] }) => {
  const socket = new WebSocket(url);
  const messages = [];
  const waiters = [];
  socket.on('message', (raw) => {
    const message = JSON.parse(raw.toString());
    messages.push(message);
    for (const waiter of [...waiters]) {
      if (waiter.predicate(message)) {
        waiters.splice(waiters.indexOf(waiter), 1);
        clearTimeout(waiter.timeout);
        waiter.resolve(message);
      }
    }
  });
  const waitFor = (predicate, timeoutMs = 2000) => {
    const existing = messages.find(predicate);
    if (existing) {
      return Promise.resolve(existing);
    }
    return new Promise((resolve, reject) => {
      const waiter = { predicate, resolve, reject, timeout: null };
      waiter.timeout = setTimeout(() => {
        const index = waiters.indexOf(waiter);
        if (index >= 0) {
          waiters.splice(index, 1);
        }
        reject(new Error('Timed out waiting for realtime message'));
      }, timeoutMs);
      waiters.push(waiter);
    });
  };

  await new Promise((resolve, reject) => {
    socket.once('open', resolve);
    socket.once('error', reject);
  });
  socket.send(JSON.stringify({ type: 'authenticate', token, scopes, knownRevisions }));
  await waitFor((message) => message.type === 'realtime_scopes_ready');
  return { socket, messages, waitFor };
};

describe('realtime v2 WebSocket delivery and reconciliation', () => {
  let server;
  let stopSocket;
  let closeWorkflowListener;
  let url;
  let admin;
  let ordinaryAdmin;
  let previousProtectedEmail;
  let adminSecondSession;
  let viewerSession;
  let contributorSession;
  let contributorAssignment;
  let projectA;
  let projectB;

  beforeAll(async () => {
    await resetDb();
    admin = await createAdminUser({ emailPrefix: 'realtime-ws-admin' });
    ordinaryAdmin = await createAdminUser({ emailPrefix: 'realtime-ws-ordinary-admin' });
    previousProtectedEmail = process.env.SUPER_ADMIN_EMAIL;
    process.env.SUPER_ADMIN_EMAIL = admin.email;
    adminSecondSession = await loginUser(admin);
    const viewer = await registerUser({ role: 'viewer', emailPrefix: 'realtime-ws-viewer' });
    viewerSession = await loginUser(viewer);
    const contributor = await registerUser({
      role: 'contributor',
      emailPrefix: 'realtime-ws-contributor',
    });
    await approveContributorRequest({ token: admin.token, userId: contributor.user.id });
    contributorSession = await loginUser(contributor);
    const category = await createCategory({
      token: admin.token,
      name: `Realtime WS category ${Date.now()}`,
    });
    projectA = await createProject({
      token: admin.token,
      categoryId: category.id,
      name: `Realtime private A ${Date.now()}`,
      visibleToViewers: false,
      visibleToContributors: false,
    });
    projectB = await createProject({
      token: admin.token,
      categoryId: category.id,
      name: `Realtime private B ${Date.now()}`,
      visibleToViewers: false,
      visibleToContributors: false,
    });
    contributorAssignment = await createAssignment({
      token: admin.token,
      projectId: projectA.id,
      userId: contributor.user.id,
    });

    server = http.createServer();
    stopSocket = attachWorkflowSocket(server, API_PREFIX, {
      v2Enabled: true,
      legacyEnabled: false,
      heartbeatIntervalMs: 60000,
    });
    closeWorkflowListener = await startWorkflowChangeListener();
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    const address = server.address();
    url = `ws://127.0.0.1:${address.port}${API_PREFIX}/realtime/workflow`;
  }, 30000);

  afterAll(async () => {
    stopSocket?.();
    await closeWorkflowListener?.();
    await new Promise((resolve) => server?.close(resolve));
    if (previousProtectedEmail === undefined) {
      delete process.env.SUPER_ADMIN_EMAIL;
    } else {
      process.env.SUPER_ADMIN_EMAIL = previousProtectedEmail;
    }
    await resetDb();
    await shutdown();
  });

  test('delivers to another session of the same account and identifies only the exact origin', async () => {
    const scope = { scopeType: 'features', scopeId: projectA.id };
    const first = await connectRealtime({ url, token: admin.token, scopes: [scope] });
    const second = await connectRealtime({
      url,
      token: adminSecondSession.token,
      scopes: [scope],
    });
    const firstSessionId = jwt.decode(admin.token).sessionId;
    const event = createRealtimeEvent(
      {
        ...scope,
        action: 'updated',
        entityType: 'feature',
        entityId: 'feature-realtime-1',
        projectId: projectA.id,
        originSessionId: firstSessionId,
        audience: { kind: 'project', projectId: projectA.id, access: 'readers' },
      },
      1,
    );
    emitRealtimeDomainEvent(event);

    const [firstEvent, secondEvent] = await Promise.all([
      first.waitFor((message) => message.eventId === event.eventId),
      second.waitFor((message) => message.eventId === event.eventId),
    ]);
    expect(firstEvent.originatedByCurrentSession).toBe(true);
    expect(secondEvent.originatedByCurrentSession).toBe(false);
    first.socket.close();
    second.socket.close();
  });

  test('delivers privacy queue invalidation only to the protected administrator without PII', async () => {
    const scope = { scopeType: 'privacy_admin_queue', scopeId: 'all' };
    const protectedClient = await connectRealtime({ url, token: admin.token, scopes: [scope] });
    const ordinaryClient = await connectRealtime({
      url,
      token: ordinaryAdmin.token,
      scopes: [scope],
    });
    const event = createRealtimeEvent(
      {
        ...scope,
        action: 'request_updated',
        entityType: 'privacy_request',
        entityId: '39c16245-22fa-43f2-863a-e2a87d48aa11',
        audience: { kind: 'protected_admins' },
      },
      1,
    );
    emitRealtimeDomainEvent(event);

    const delivered = await protectedClient.waitFor(
      (message) => message.eventId === event.eventId,
    );
    await delay(250);
    expect(ordinaryClient.messages.some((message) => message.eventId === event.eventId)).toBe(false);
    expect(JSON.stringify(delivered)).not.toMatch(/email|phone|description|full_name/i);
    protectedClient.socket.close();
    ordinaryClient.socket.close();
  });

  test('does not deliver an unrelated or unauthorized private-project event', async () => {
    const unrelated = await connectRealtime({
      url,
      token: admin.token,
      scopes: [{ scopeType: 'features', scopeId: projectB.id }],
    });
    const unauthorized = await connectRealtime({
      url,
      token: viewerSession.token,
      scopes: [{ scopeType: 'features', scopeId: projectA.id }],
    });
    const event = createRealtimeEvent(
      {
        scopeType: 'features',
        scopeId: projectA.id,
        action: 'updated',
        entityType: 'feature',
        entityId: 'feature-realtime-2',
        projectId: projectA.id,
        audience: { kind: 'project', projectId: projectA.id, access: 'readers' },
      },
      2,
    );
    emitRealtimeDomainEvent(event);
    await delay(250);

    expect(unrelated.messages.some((message) => message.eventId === event.eventId)).toBe(false);
    expect(unauthorized.messages.some((message) => message.eventId === event.eventId)).toBe(false);
    unrelated.socket.close();
    unauthorized.socket.close();
  });

  test('indexes exact import subscribers and enforces import access before delivery', async () => {
    const inserted = await pool.query(
      `INSERT INTO gis_import_job
         (project_id, uploaded_by_user_id, original_filename, stored_filename, file_path,
          file_size_bytes, file_checksum_sha256, file_type)
       VALUES ($1, $2, 'realtime.geojson', 'realtime.geojson', '/tmp/realtime.geojson',
               1, $3, 'geojson')
       RETURNING id`,
      [projectA.id, contributorSession.user.id, 'a'.repeat(64)],
    );
    const importId = inserted.rows[0].id;
    const scope = { scopeType: 'import', scopeId: importId };
    const owner = await connectRealtime({
      url,
      token: contributorSession.token,
      scopes: [scope],
    });
    const authorizedAdmin = await connectRealtime({ url, token: admin.token, scopes: [scope] });
    const unauthorizedViewer = await connectRealtime({
      url,
      token: viewerSession.token,
      scopes: [scope],
    });
    const event = createRealtimeEvent(
      {
        ...scope,
        action: 'processing',
        entityType: 'import',
        entityId: importId,
        projectId: projectA.id,
        audience: { kind: 'scope_subscribers' },
      },
      1,
    );
    emitRealtimeDomainEvent(event);

    await Promise.all([
      owner.waitFor((message) => message.eventId === event.eventId),
      authorizedAdmin.waitFor((message) => message.eventId === event.eventId),
    ]);
    await delay(250);
    expect(unauthorizedViewer.messages.some((message) => message.eventId === event.eventId)).toBe(
      false,
    );
    owner.socket.close();
    authorizedAdmin.socket.close();
    unauthorizedViewer.socket.close();
  });

  test('reports a missed active-scope revision after reconnect', async () => {
    const scope = { scopeType: 'project', scopeId: projectA.id };
    const published = await publishRealtimeChange({
      ...scope,
      action: 'updated',
      entityType: 'project',
      entityId: projectA.id,
      projectId: projectA.id,
      audience: { kind: 'project', projectId: projectA.id, access: 'readers' },
    });
    const client = await connectRealtime({
      url,
      token: admin.token,
      scopes: [scope],
      knownRevisions: [{ ...scope, revision: published.revision - 1 }],
    });
    const ready = client.messages.find((message) => message.type === 'realtime_scopes_ready');

    expect(ready.staleScopes).toContainEqual({ ...scope, revision: published.revision });
    client.socket.close();
  });

  test('immediately closes only a revoked authenticated session', async () => {
    const client = await connectRealtime({
      url,
      token: adminSecondSession.token,
      scopes: [],
    });
    const closed = new Promise((resolve) => {
      client.socket.once('close', (code, reason) =>
        resolve({ code, reason: reason.toString() }),
      );
    });

    const logout = await request(app)
      .post(`${API_PREFIX}/auth/logout`)
      .set(authHeader(adminSecondSession.token));
    expect(logout.status).toBe(200);
    await expect(closed).resolves.toEqual({ code: 1008, reason: 'session_revoked' });
  });

  test('revokes an existing project subscription after assignment removal', async () => {
    const scope = { scopeType: 'features', scopeId: projectA.id };
    const client = await connectRealtime({
      url,
      token: contributorSession.token,
      scopes: [scope, { scopeType: 'assignments', scopeId: contributorSession.user.id }],
    });

    const removed = await request(app)
      .delete(`${API_PREFIX}/assignments/${contributorAssignment.id}`)
      .set(authHeader(admin.token));
    expect(removed.status).toBe(200);
    await client.waitFor(
      (message) =>
        message.type === 'realtime_subscription_revoked' && message.projectId === projectA.id,
    );

    const event = createRealtimeEvent(
      {
        ...scope,
        action: 'updated',
        entityType: 'feature',
        entityId: 'feature-after-revocation',
        projectId: projectA.id,
        audience: { kind: 'project', projectId: projectA.id, access: 'readers' },
      },
      8,
    );
    emitRealtimeDomainEvent(event);
    await delay(250);
    expect(client.messages.some((message) => message.eventId === event.eventId)).toBe(false);
    client.socket.close();
  });
});
