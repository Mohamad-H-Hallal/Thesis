const {
  calculateCompatibleMigrationChecksums,
  calculateMigrationChecksum,
  findMigrationIntegrityIssues,
  resolveMigrationChecksumCompatibility,
} = require('../src/db/migrationIntegrity');
const fs = require('node:fs');
const path = require('node:path');

describe('migration integrity', () => {
  test('uses stable SHA-256 checksums', () => {
    expect(calculateMigrationChecksum('SELECT 1;\n')).toBe(
      'b4e0497804e46e0a0b0b8c31975b062152d551bac49c3c2e80932567b4085dcd',
    );
    expect(calculateMigrationChecksum('SELECT 1;\r\n')).toBe(
      'b4e0497804e46e0a0b0b8c31975b062152d551bac49c3c2e80932567b4085dcd',
    );
  });

  test('accepts an unchanged applied migration set', () => {
    const records = [
      { filename: '0001_extensions.sql', checksum: 'checksum-1' },
      { filename: '0002_schema.sql', checksum: 'checksum-2' },
    ];

    expect(findMigrationIntegrityIssues(records, records)).toEqual([]);
  });

  test('reports changed and missing applied migrations', () => {
    const available = [{ filename: '0001_extensions.sql', checksum: 'new-checksum' }];
    const applied = [
      { filename: '0001_extensions.sql', checksum: 'old-checksum' },
      { filename: '0002_schema.sql', checksum: 'checksum-2' },
    ];

    expect(findMigrationIntegrityIssues(available, applied)).toEqual([
      'Applied migration checksum changed: 0001_extensions.sql ' +
        '(database=old-checksum, source=new-checksum)',
      'Applied migration is missing from the source tree: 0002_schema.sql',
    ]);
  });

  test('accepts a legacy checksum that differs only by line endings', () => {
    const sql = 'CREATE TABLE example (\n  id INTEGER\n);\n';
    const compatibleChecksums = calculateCompatibleMigrationChecksums(sql);
    const available = [
      {
        filename: '0001_example.sql',
        checksum: calculateMigrationChecksum(sql),
        compatibleChecksums,
      },
    ];

    expect(compatibleChecksums).toHaveLength(2);
    expect(
      findMigrationIntegrityIssues(available, [
        {
          filename: '0001_example.sql',
          checksum: compatibleChecksums[1],
        },
      ]),
    ).toEqual([]);
  });

  test('resolves only source-pinned migration compatibility entries', () => {
    const source = [
      {
        filename: '0001_example.sql',
        checksum: 'a'.repeat(64),
      },
    ];
    const resolved = resolveMigrationChecksumCompatibility(
      {
        version: 1,
        migrations: [
          {
            filename: '0001_example.sql',
            sourceChecksum: 'a'.repeat(64),
            acceptedChecksums: ['b'.repeat(64)],
            reason: 'Historical pre-release database provenance.',
          },
        ],
      },
      source,
    );

    expect(resolved.get('0001_example.sql')).toEqual(['b'.repeat(64)]);
    expect(() =>
      resolveMigrationChecksumCompatibility(
        {
          version: 1,
          migrations: [
            {
              filename: '0001_example.sql',
              sourceChecksum: 'c'.repeat(64),
              acceptedChecksums: ['b'.repeat(64)],
              reason: 'Stale source pin.',
            },
          ],
        },
        source,
      ),
    ).toThrow('Compatibility entry source checksum is stale: 0001_example.sql');
  });

  test('accepts the documented pre-release 0059 checksum', () => {
    const migrationsDir = path.resolve(__dirname, '../../../infra/migrations');
    const filename = '0059_compliance_governance.sql';
    const sql = fs.readFileSync(path.join(migrationsDir, filename), 'utf8');
    const source = [{ filename, checksum: calculateMigrationChecksum(sql) }];
    const fullConfig = JSON.parse(
      fs.readFileSync(path.join(migrationsDir, 'checksum-compatibility.json'), 'utf8'),
    );
    const config = {
      version: 1,
      migrations: fullConfig.migrations.filter((entry) => entry.filename === filename),
    };
    const compatibility = resolveMigrationChecksumCompatibility(config, source);

    expect(source[0].checksum).toBe(
      'c2a69755d125e883850b4f74c5e783e17074bb67261e7454fc66e7d880d554a0',
    );
    expect(
      findMigrationIntegrityIssues(
        [
          {
            ...source[0],
            compatibleChecksums: compatibility.get(filename),
          },
        ],
        [
          {
            filename,
            checksum: 'b10c0a3eda8b1114d4544edc25ea389c48ed1f57738c2ab7126617668ce424ae',
          },
        ],
      ),
    ).toEqual([]);
  });
});
