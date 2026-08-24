import type { PoolClient, QueryResult, QueryResultRow } from 'pg';

interface QueryExecutor {
  query<T extends QueryResultRow = QueryResultRow>(
    text: string,
    params?: unknown[],
  ): Promise<QueryResult<T>>;
}

const meaningfulNameComponentPattern = /[\p{L}\p{N}][\p{L}\p{M}\p{N}'’.-]*/gu;

const containsControlCharacter = (value: string): boolean =>
  [...value].some((character) => {
    const codePoint = character.codePointAt(0) ?? 0;
    return codePoint <= 0x1f || codePoint === 0x7f;
  });

const normalizePersonName = (value: unknown): string => {
  if (typeof value !== 'string' || containsControlCharacter(value)) {
    throw new Error('INVALID_FULL_NAME');
  }
  const normalized = value.trim().replace(/\s+/gu, ' ');
  if (normalized.length < 1 || normalized.length > 200) {
    throw new Error('INVALID_FULL_NAME');
  }
  return normalized;
};

const firstGrapheme = (value: string): string => {
  const segmenter = new Intl.Segmenter(undefined, { granularity: 'grapheme' });
  return segmenter.segment(value)[Symbol.iterator]().next().value?.segment ?? '';
};

const buildMaskedContributorLabel = (fullName: string): string => {
  const normalized = normalizePersonName(fullName);
  const components = normalized.match(meaningfulNameComponentPattern) ?? [];
  const initials = components
    .map(firstGrapheme)
    .filter((value) => value.length > 0)
    .map((value) => `${value.toLocaleUpperCase()}.`);
  return initials.length > 0 ? initials.join(' ') : 'Former contributor';
};

const applyCorrectableProfileField = async (
  executor: QueryExecutor | PoolClient,
  {
    userId,
    field,
    requestedValue,
  }: {
    userId: string;
    field: string;
    requestedValue: unknown;
  },
): Promise<{
  field: 'full_name';
  beforeEvidence: { present: boolean; length: number };
  afterEvidence: { present: boolean; length: number };
}> => {
  if (field !== 'full_name') {
    throw new Error('CORRECTION_FIELD_REQUIRES_SEPARATE_VERIFICATION');
  }
  const fullName = normalizePersonName(requestedValue);
  const current = await executor.query<{ full_name: string | null; account_status: string }>(
    `SELECT full_name, account_status
     FROM "user"
     WHERE id = $1
     FOR UPDATE`,
    [userId],
  );
  const row = current.rows[0];
  if (!row || row.account_status === 'deleted') {
    throw new Error('CORRECTION_ACCOUNT_UNAVAILABLE');
  }
  await executor.query(`UPDATE "user" SET full_name = $2 WHERE id = $1`, [userId, fullName]);
  return {
    field: 'full_name',
    beforeEvidence: {
      present: Boolean(row.full_name),
      length: row.full_name?.length ?? 0,
    },
    afterEvidence: { present: true, length: fullName.length },
  };
};

export {
  applyCorrectableProfileField,
  buildMaskedContributorLabel,
  normalizePersonName,
};
