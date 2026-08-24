const {
  assertRealtimePayloadSize,
  createRealtimeEvent,
  parseKnownRevisions,
  parseRealtimeDomainEvent,
} = require('../src/realtime/realtimeProtocol');
const {
  emitRealtimeDomainEvent,
  subscribeRealtimeChanges,
} = require('../src/realtime/realtimeEvents');
const {
  clientIpForRequest,
  hostAllowed,
  originAllowed,
} = require('../src/realtime/workflowSocket');

const input = {
  scopeType: 'features',
  scopeId: 'project-123',
  action: 'updated',
  entityType: 'feature',
  entityId: 'feature-456',
  projectId: 'project-123',
  originSessionId: 'session-789',
  audience: {
    kind: 'project',
    projectId: 'project-123',
    access: 'members',
  },
};

describe('realtime v1 protocol', () => {
  test('serializes and validates a minimal invalidation event', () => {
    const event = createRealtimeEvent(input, 7);
    const parsed = parseRealtimeDomainEvent(JSON.parse(JSON.stringify(event)));

    expect(parsed).toEqual(event);
    expect(parsed.revision).toBe(7);
    expect(parsed).not.toHaveProperty('geometry');
    expect(Buffer.byteLength(JSON.stringify(parsed), 'utf8')).toBeLessThan(1024);
  });

  test('supports indexed exact-scope subscriber delivery without exposing audience data', () => {
    const event = createRealtimeEvent(
      {
        ...input,
        scopeType: 'import',
        scopeId: 'import-123',
        entityType: 'import',
        entityId: 'import-123',
        audience: { kind: 'scope_subscribers' },
      },
      2,
    );
    expect(parseRealtimeDomainEvent(event).audience).toEqual({ kind: 'scope_subscribers' });
  });

  test('rejects unsupported protocol, audience, revision, and oversized payloads', () => {
    const event = createRealtimeEvent(input, 1);
    expect(() => parseRealtimeDomainEvent({ ...event, protocolVersion: 2 })).toThrow(
      'Unsupported realtime protocol version',
    );
    expect(() =>
      parseRealtimeDomainEvent({
        ...event,
        audience: { kind: 'project', projectId: 'project-123', access: 'owners' },
      }),
    ).toThrow('Unsupported realtime project audience access');
    expect(() => parseRealtimeDomainEvent({ ...event, revision: 0 })).toThrow(
      'revision must be a positive safe integer',
    );
    expect(() => assertRealtimePayloadSize({ value: 'x'.repeat(4096) })).toThrow(
      'Realtime payload exceeds 4096 bytes',
    );
  });

  test('deduplicates known revisions and delivered event IDs', () => {
    expect(
      parseKnownRevisions([
        { scopeType: 'features', scopeId: 'project-123', revision: 1 },
        { scopeType: 'features', scopeId: 'project-123', revision: 3 },
      ]),
    ).toEqual([{ scopeType: 'features', scopeId: 'project-123', revision: 3 }]);

    const listener = jest.fn();
    const unsubscribe = subscribeRealtimeChanges(listener);
    const event = createRealtimeEvent(input, 4);
    emitRealtimeDomainEvent(event);
    emitRealtimeDomainEvent(event);
    unsubscribe();
    expect(listener).toHaveBeenCalledTimes(1);
  });

  test('validates production origin and host independently', () => {
    const request = {
      headers: { origin: 'https://app.terraleb.example', host: 'api.terraleb.example' },
    };
    const options = {
      allowedOrigins: ['https://app.terraleb.example'],
      allowedHosts: ['api.terraleb.example'],
      nodeEnv: 'production',
    };
    expect(originAllowed(request, options)).toBe(true);
    expect(hostAllowed(request, options)).toBe(true);
    expect(originAllowed({ headers: { origin: 'https://evil.example' } }, options)).toBe(false);
    expect(hostAllowed({ headers: { host: 'evil.example' } }, options)).toBe(false);
  });

  test('uses forwarded IPs only behind an explicitly trusted proxy', () => {
    const request = {
      headers: { 'x-forwarded-for': '198.51.100.9, 203.0.113.4' },
      socket: { remoteAddress: '172.20.0.2' },
    };
    expect(clientIpForRequest(request, { trustProxy: false, trustProxyHops: 1 })).toBe(
      '172.20.0.2',
    );
    expect(clientIpForRequest(request, { trustProxy: true, trustProxyHops: 1 })).toBe(
      '203.0.113.4',
    );
    expect(clientIpForRequest(request, { trustProxy: true, trustProxyHops: 2 })).toBe(
      '198.51.100.9',
    );
  });
});
