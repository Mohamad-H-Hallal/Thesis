const {
  buildMaskedContributorLabel,
  normalizePersonName,
} = require('../src/services/privacyIdentity.service');
const {
  scrubStructuredValue,
} = require('../src/services/accountDeletion.service');

describe('privacy identity handling', () => {
  test.each([
    ['Ali Hassan', 'A. H.'],
    ['  Ali   Hassan  ', 'A. H.'],
    ['Ali', 'A.'],
    ['علي حسن', 'ع. ح.'],
    ['李 小龍', '李. 小.'],
    ["Jean-Luc O'Neill", 'J. O.'],
    ['... Ali --- Hassan ...', 'A. H.'],
  ])('builds a stable masked label for %s', (name, expected) => {
    expect(buildMaskedContributorLabel(name)).toBe(expected);
  });

  test('uses one Unicode grapheme instead of splitting a composed character', () => {
    expect(buildMaskedContributorLabel('E\u0301lodie Martin')).toBe('É. M.');
  });

  test('normalizes names and rejects empty or control-character values', () => {
    expect(normalizePersonName('  Ali   Hassan ')).toBe('Ali Hassan');
    expect(() => normalizePersonName('   ')).toThrow('INVALID_FULL_NAME');
    expect(() => normalizePersonName('Ali\u0000Hassan')).toThrow('INVALID_FULL_NAME');
  });

  test('removes direct contacts and masks names in structured snapshots', () => {
    const scrubbed = scrubStructuredValue(
      {
        full_name: 'Ali Hassan',
        profile: {
          email: 'ali@example.com',
          phone_e164: '+96170123456',
          note: 'Reviewed by Ali Hassan; contact ali@example.com.',
        },
        unchanged: 'project evidence',
      },
      'A. H.',
      {
        fullName: 'Ali Hassan',
        email: 'ali@example.com',
        phone: '+96170123456',
      },
    );
    expect(scrubbed).toEqual({
      full_name: 'A. H.',
      profile: {
        email: null,
        phone_e164: null,
        note: 'Reviewed by A. H.; contact [removed].',
      },
      unchanged: 'project evidence',
    });
    expect(JSON.stringify(scrubbed)).not.toContain('Ali Hassan');
    expect(JSON.stringify(scrubbed)).not.toContain('ali@example.com');
  });
});
