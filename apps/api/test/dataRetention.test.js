jest.mock('../src/config/database', () => ({
  query: jest.fn(),
  transaction: jest.fn(),
}));

const database = require('../src/config/database');
const { runApprovedRetentionCleanup } = require('../src/services/dataRetention.service');

describe('approved retention cleanup', () => {
  beforeEach(() => {
    jest.clearAllMocks();
  });

  test('is fail-closed and performs no transaction when no policy is approved', async () => {
    database.query.mockResolvedValueOnce({ rows: [] });

    const result = await runApprovedRetentionCleanup('scheduled');

    expect(result).toEqual({
      runId: null,
      status: 'completed',
      affectedRows: 0,
      policyCount: 0,
    });
    expect(database.transaction).not.toHaveBeenCalled();
  });

  test('deletes only through a transaction with hold checks and policy audit evidence', async () => {
    database.query.mockResolvedValueOnce({
      rows: [
        {
          data_category: 'notifications',
          retention_days: 30,
          disposal_action: 'delete',
          approval_reference: 'COUNSEL-APPROVAL-123',
        },
      ],
    });
    const statements = [];
    const client = {
      query: jest.fn(async (text, params) => {
        statements.push({ text, params });
        if (text.includes('pg_try_advisory_xact_lock')) {
          return { rows: [{ acquired: true }], rowCount: 1 };
        }
        if (text.includes('INSERT INTO data_retention_cleanup_run')) {
          return { rows: [{ id: '00000000-0000-4000-8000-000000000099' }], rowCount: 1 };
        }
        if (text.includes('DELETE FROM notification')) {
          return { rows: [], rowCount: 2 };
        }
        return { rows: [], rowCount: 1 };
      }),
    };
    database.transaction.mockImplementation(async (callback) => callback(client));

    const result = await runApprovedRetentionCleanup('manual');

    expect(result.affectedRows).toBe(2);
    expect(result.policyCount).toBe(1);
    const deletion = statements.find((statement) =>
      statement.text.includes('DELETE FROM notification'),
    );
    expect(deletion.text).toContain('data_retention_hold');
    expect(deletion.params).toEqual([30, 'notifications']);
    expect(
      statements.some((statement) =>
        statement.text.includes('INSERT INTO data_retention_cleanup_item'),
      ),
    ).toBe(true);
  });

  test('rolls back unsupported disposal policies and records a sanitized failure', async () => {
    database.query
      .mockResolvedValueOnce({
        rows: [
          {
            data_category: 'ai_artifacts',
            retention_days: 10,
            disposal_action: 'anonymize',
            approval_reference: 'COUNSEL-APPROVAL-456',
          },
        ],
      })
      .mockResolvedValueOnce({ rows: [], rowCount: 1 });
    const client = {
      query: jest.fn(async (text) => {
        if (text.includes('pg_try_advisory_xact_lock')) {
          return { rows: [{ acquired: true }], rowCount: 1 };
        }
        if (text.includes('INSERT INTO data_retention_cleanup_run')) {
          return { rows: [{ id: '00000000-0000-4000-8000-000000000098' }], rowCount: 1 };
        }
        return { rows: [], rowCount: 1 };
      }),
    };
    database.transaction.mockImplementation(async (callback) => callback(client));

    await expect(runApprovedRetentionCleanup('scheduled')).rejects.toThrow(
      'RETENTION_POLICY_IMPLEMENTATION_REQUIRED',
    );
    expect(database.query).toHaveBeenLastCalledWith(
      expect.stringContaining("VALUES ('failed'"),
      ['scheduled', 1, 'RETENTION_POLICY_IMPLEMENTATION_REQUIRED'],
    );
  });
});
