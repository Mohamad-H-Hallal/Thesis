const jwt = require('jsonwebtoken');
const http = require('node:http');
const WebSocket = require('ws');
const {
  API_PREFIX,
  app,
  request,
  authHeader,
  resetDb,
  shutdown,
  registerUser,
  loginUser,
} = require('./helpers/api-test-helpers');
const {
  attachWorkflowSocket,
  coarseWorkflowPath,
  eventForUser,
  parseAuthenticationMessage,
} = require('../src/realtime/workflowSocket');
const { publishWorkflowChange } = require('../src/realtime/workflowEvents');

describe('Security: authenticated session lifecycle and realtime event privacy', () => {
  beforeEach(async () => {
    await resetDb();
  });

  afterAll(async () => {
    await resetDb();
    await shutdown();
  });

  test('rotates refresh tokens and revokes all sessions when an old token is replayed', async () => {
    const account = await registerUser({ role: 'viewer', emailPrefix: 'refresh-rotation' });
    const session = await loginUser(account);

    const rotated = await request(app)
      .post(`${API_PREFIX}/auth/refresh-token`)
      .send({ refresh_token: session.refreshToken });

    expect(rotated.status).toBe(200);
    expect(rotated.body.data.refreshToken).not.toBe(session.refreshToken);

    const replay = await request(app)
      .post(`${API_PREFIX}/auth/refresh-token`)
      .send({ refresh_token: session.refreshToken });

    expect(replay.status).toBe(401);
    expect(replay.body.error.code).toBe('AUTH_REFRESH_REPLAYED');

    const revokedAccess = await request(app)
      .get(`${API_PREFIX}/auth/me`)
      .set(authHeader(rotated.body.data.token));
    expect(revokedAccess.status).toBe(401);
  });

  test('revokes both access and refresh credentials on logout', async () => {
    const account = await registerUser({ role: 'viewer', emailPrefix: 'logout-revocation' });
    const session = await loginUser(account);

    const logout = await request(app)
      .post(`${API_PREFIX}/auth/logout`)
      .set(authHeader(session.token));
    expect(logout.status).toBe(200);

    const accessAfterLogout = await request(app)
      .get(`${API_PREFIX}/auth/me`)
      .set(authHeader(session.token));
    expect(accessAfterLogout.status).toBe(401);
    expect(accessAfterLogout.body.error.code).toBe('AUTH_SESSION_REVOKED');

    const refreshAfterLogout = await request(app)
      .post(`${API_PREFIX}/auth/refresh-token`)
      .send({ refresh_token: session.refreshToken });
    expect(refreshAfterLogout.status).toBe(401);
  });

  test('password change revokes other devices and returns a renewed current session', async () => {
    const account = await registerUser({ role: 'viewer', emailPrefix: 'password-sessions' });
    const currentDevice = await loginUser(account);
    const otherDevice = await loginUser(account);
    const newPassword = 'N3w-Password!456';

    const changed = await request(app)
      .post(`${API_PREFIX}/auth/change-password`)
      .set(authHeader(currentDevice.token))
      .send({ current_password: account.password, new_password: newPassword });

    expect(changed.status).toBe(200);
    expect(changed.body.data.token).toEqual(expect.any(String));
    expect(changed.body.data.refreshToken).toEqual(expect.any(String));

    const renewedCurrent = await request(app)
      .get(`${API_PREFIX}/auth/me`)
      .set(authHeader(changed.body.data.token));
    expect(renewedCurrent.status).toBe(200);

    for (const staleToken of [currentDevice.token, otherDevice.token]) {
      const stale = await request(app)
        .get(`${API_PREFIX}/auth/me`)
        .set(authHeader(staleToken));
      expect(stale.status).toBe(401);
    }

    const oldPassword = await request(app).post(`${API_PREFIX}/auth/login`).send({
      email: account.email,
      password: account.password,
    });
    expect(oldPassword.status).toBe(401);
    expect((await loginUser({ email: account.email, password: newPassword })).token).toBeTruthy();
  });

  test('rejects signed JWTs with the wrong audience or without an access-token purpose', async () => {
    const account = await registerUser({ role: 'viewer', emailPrefix: 'jwt-claims' });
    const session = await loginUser(account);
    const payload = jwt.decode(session.token);
    const secret = process.env.JWT_SECRET_CURRENT || process.env.JWT_SECRET;
    const baseOptions = {
      algorithm: 'HS256',
      expiresIn: '15m',
      issuer: process.env.JWT_ISSUER,
      subject: account.user.id,
    };

    const wrongAudience = jwt.sign(
      {
        userId: account.user.id,
        role: 'viewer',
        authVersion: payload.authVersion,
        sessionId: payload.sessionId,
        tokenType: 'access',
      },
      secret,
      { ...baseOptions, audience: 'untrusted-client' },
    );
    const missingPurpose = jwt.sign(
      {
        userId: account.user.id,
        role: 'viewer',
        authVersion: payload.authVersion,
        sessionId: payload.sessionId,
      },
      secret,
      { ...baseOptions, audience: process.env.JWT_AUDIENCE },
    );

    for (const token of [wrongAudience, missingPurpose]) {
      const response = await request(app)
        .get(`${API_PREFIX}/auth/me`)
        .set(authHeader(token));
      expect(response.status).toBe(401);
      expect(response.body.message).toBe('Invalid token');
    }
  });

  test('rejects valid JWTs presented outside the exact Bearer authorization envelope', async () => {
    const account = await registerUser({ role: 'viewer', emailPrefix: 'bearer-envelope' });
    const session = await loginUser(account);

    for (const authorization of [
      session.token,
      `Basic ${session.token}`,
      `Bearer  ${session.token}`,
      `Bearer ${session.token} trailing-value`,
    ]) {
      const response = await request(app)
        .get(`${API_PREFIX}/auth/me`)
        .set('Authorization', authorization);
      expect(response.status).toBe(401);
      expect(response.body.message).toBe('No token provided');
    }
  });

  test('removes identifiers from realtime paths and limits user-target metadata', () => {
    const projectId = '11111111-1111-4111-8111-111111111111';
    expect(coarseWorkflowPath(`/api/v1/projects/${projectId}/assignments?include=user`)).toBe(
      '/api/v1/projects',
    );

    const event = {
      type: 'workflow_changed',
      id: 'event-1',
      occurredAt: new Date().toISOString(),
      method: 'POST',
      path: `/api/v1/users/${projectId}/block`,
      actorUserId: 'admin-user',
      requestId: 'private-request-id',
      targetUserId: 'target-user',
      targetAction: 'block',
    };

    expect(
      eventForUser(event, {
        id: 'unrelated-user',
        role: 'viewer',
        sessionId: 'session',
        authVersion: 0,
        tokenExpiresAt: Date.now() + 1000,
      }),
    ).toBeNull();

    const targetEvent = eventForUser(event, {
      id: 'target-user',
      role: 'viewer',
      sessionId: 'session',
      authVersion: 0,
      tokenExpiresAt: Date.now() + 1000,
    });
    expect(targetEvent).toEqual(
      expect.objectContaining({
        path: '/api/v1/users',
        actorUserId: null,
        targetUserId: 'target-user',
        targetAction: 'block',
      }),
    );
    expect(JSON.stringify(targetEvent)).not.toContain(projectId);
    expect(JSON.stringify(targetEvent)).not.toContain('private-request-id');
  });

  test('accepts only a bounded first-message authentication envelope', () => {
    expect(
      parseAuthenticationMessage(
        Buffer.from(JSON.stringify({ type: 'authenticate', token: 'signed-token' })),
      ),
    ).toBe('signed-token');
    expect(() => parseAuthenticationMessage(Buffer.from('{"token":"missing-type"}'))).toThrow(
      'Invalid realtime authentication message',
    );
  });

  test('authenticates realtime connections by first message and emits only coarse paths', async () => {
    const account = await registerUser({ role: 'viewer', emailPrefix: 'realtime-handshake' });
    const session = await loginUser(account);
    const server = http.createServer(app);
    const stopSocket = attachWorkflowSocket(server, API_PREFIX);
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    const address = server.address();
    const socket = new WebSocket(
      `ws://127.0.0.1:${address.port}${API_PREFIX}/realtime/workflow`,
    );

    const received = await new Promise((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error('Timed out waiting for realtime event')), 5000);
      socket.on('open', () => {
        socket.send(JSON.stringify({ type: 'authenticate', token: session.token }));
      });
      socket.on('message', (raw) => {
        const message = JSON.parse(raw.toString());
        if (message.type === 'workflow_realtime_ready') {
          publishWorkflowChange({
            method: 'PATCH',
            path: '/api/v1/features/11111111-1111-4111-8111-111111111111/review',
            actorUserId: 'another-user',
            requestId: 'private-request-id',
            targetUserId: null,
            targetAction: null,
          });
          return;
        }
        if (message.type === 'workflow_changed') {
          clearTimeout(timeout);
          resolve(message);
        }
      });
      socket.on('error', reject);
    });

    expect(received).toEqual(
      expect.objectContaining({
        type: 'workflow_changed',
        path: '/api/v1/features',
        actorUserId: null,
      }),
    );
    expect(JSON.stringify(received)).not.toContain('11111111-1111-4111-8111-111111111111');
    expect(JSON.stringify(received)).not.toContain('private-request-id');

    socket.close();
    stopSocket();
    await new Promise((resolve) => server.close(resolve));
  });
});
