const {
  listPublicLegalDocuments,
  getExistingUserAcceptanceStatus,
  recordLegalAcceptances,
  validateSignupAcceptances,
} = require('../src/legal/legalDocuments');

describe('versioned legal documents and acceptance', () => {
  const previousEnforcement = process.env.LEGAL_ENFORCEMENT_ENABLED;

  afterEach(() => {
    if (previousEnforcement === undefined) {
      delete process.env.LEGAL_ENFORCEMENT_ENABLED;
    } else {
      process.env.LEGAL_ENFORCEMENT_ENABLED = previousEnforcement;
    }
  });

  test('publishes immutable version and digest metadata for every draft document', () => {
    const documents = listPublicLegalDocuments('en');

    expect(documents).toHaveLength(7);
    for (const document of documents) {
      expect(document.version).toMatch(/^draft-/);
      expect(document.contentSha256).toMatch(/^[a-f0-9]{64}$/);
      expect(document.counselApproved).toBe(false);
      expect(JSON.stringify(document)).not.toMatch(
        /\[\s*(?:DECISION|OWNER|LEGAL)[^\]]*REQUIRED/i,
      );
      expect(document.title).not.toMatch(/legal review draft|approval pending/i);
    }
  });

  test('requires affirmative current Terms and AUP when enforcement is enabled', () => {
    process.env.LEGAL_ENFORCEMENT_ENABLED = 'true';
    const documents = listPublicLegalDocuments('en');
    const acceptances = documents
      .filter((document) => ['terms', 'acceptable_use'].includes(document.type))
      .map((document) => ({
        document_type: document.type,
        version: document.version,
        locale: document.locale,
        affirmative: true,
      }));

    expect(validateSignupAcceptances(acceptances)).toEqual(acceptances);
    expect(() => validateSignupAcceptances([])).toThrow(
      'Accept the current Terms of Use and Acceptable Use Policy.',
    );
  });

  test('requires existing-user renewal only for versions classified as material', async () => {
    process.env.LEGAL_ENFORCEMENT_ENABLED = 'true';
    const executor = {
      query: jest.fn(async () => ({ rows: [], rowCount: 0 })),
    };

    const result = await getExistingUserAcceptanceStatus({
      executor,
      userId: '00000000-0000-4000-8000-000000000010',
    });

    expect(result.required).toBe(true);
    expect(result.missing.map((document) => document.type).sort()).toEqual([
      'acceptable_use',
      'terms',
    ]);
    expect(executor.query).toHaveBeenCalledTimes(1);
  });

  test('rejects bundled privacy consent during signup', () => {
    process.env.LEGAL_ENFORCEMENT_ENABLED = 'false';
    const privacy = listPublicLegalDocuments('en').find(
      (document) => document.type === 'privacy',
    );

    expect(() =>
      validateSignupAcceptances([
        {
          document_type: 'privacy',
          version: privacy.version,
          locale: privacy.locale,
          affirmative: true,
        },
      ]),
    ).toThrow('Privacy notices must not be submitted as bundled consent.');
  });

  test('records only acceptance evidence tied to the exact document digest', async () => {
    const terms = listPublicLegalDocuments('en').find(
      (document) => document.type === 'terms',
    );
    const statements = [];
    const executor = {
      query: jest.fn(async (text, params) => {
        statements.push({ text, params });
        return { rows: [], rowCount: 1 };
      }),
    };

    await recordLegalAcceptances({
      executor,
      userId: '00000000-0000-4000-8000-000000000010',
      acceptances: [
        {
          document_type: terms.type,
          version: terms.version,
          locale: terms.locale,
          affirmative: true,
        },
      ],
      source: 'signup',
    });

    expect(executor.query).toHaveBeenCalledTimes(3);
    expect(statements[1].params).toContain(terms.contentSha256);
    expect(statements[2].params.join(' ')).not.toContain('privacy');
  });
});
