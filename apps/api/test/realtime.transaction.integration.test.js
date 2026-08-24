const { randomUUID } = require('node:crypto');
const { pool, resetDb, shutdown } = require('./helpers/api-test-helpers');
const { transaction } = require('../src/config/database');
const { publishRealtimeChange } = require('../src/realtime/realtimeEvents');

const makeInput = (scopeId) => ({
  scopeType: 'project',
  scopeId,
  action: 'updated',
  entityType: 'project',
  entityId: scopeId,
  projectId: scopeId,
  originSessionId: null,
  audience: { kind: 'admins' },
});

describe('realtime revision transaction behavior', () => {
  beforeEach(async () => {
    await resetDb();
  });

  afterAll(async () => {
    await resetDb();
    await shutdown();
  });

  test('commits a revision with its owning business transaction', async () => {
    const scopeId = randomUUID();
    await transaction((client) => publishRealtimeChange(makeInput(scopeId), client));

    const revision = await pool.query(
      `SELECT revision FROM realtime_scope_revision
       WHERE scope_type = 'project' AND scope_id = $1`,
      [scopeId],
    );
    expect(Number(revision.rows[0].revision)).toBe(1);
  });

  test('does not commit a revision or notification when the transaction rolls back', async () => {
    const scopeId = randomUUID();
    await expect(
      transaction(async (client) => {
        await publishRealtimeChange(makeInput(scopeId), client);
        throw new Error('intentional rollback');
      }),
    ).rejects.toThrow('intentional rollback');

    const revision = await pool.query(
      `SELECT COUNT(*)::integer AS count FROM realtime_scope_revision
       WHERE scope_type = 'project' AND scope_id = $1`,
      [scopeId],
    );
    expect(revision.rows[0].count).toBe(0);
  });

  test('increments only the affected scope revision', async () => {
    const firstScope = randomUUID();
    const secondScope = randomUUID();
    await transaction(async (client) => {
      await publishRealtimeChange(makeInput(firstScope), client);
      await publishRealtimeChange(makeInput(firstScope), client);
      await publishRealtimeChange(makeInput(secondScope), client);
    });

    const revisions = await pool.query(
      `SELECT scope_id, revision FROM realtime_scope_revision
       WHERE scope_type = 'project' AND scope_id = ANY($1::text[])
       ORDER BY scope_id`,
      [[firstScope, secondScope]],
    );
    expect(Object.fromEntries(revisions.rows.map((row) => [row.scope_id, Number(row.revision)])))
      .toEqual({ [firstScope]: 2, [secondScope]: 1 });
  });
});
