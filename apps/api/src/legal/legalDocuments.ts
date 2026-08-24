import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import type { QueryResult, QueryResultRow } from 'pg';
import { AppError } from '../middleware/error';

type LegalDocumentType =
  | 'privacy'
  | 'terms'
  | 'acceptable_use'
  | 'important_notices'
  | 'account_deletion'
  | 'subprocessors'
  | 'open_source';

type LegalDocumentStatus = 'draft' | 'approved' | 'retired';

interface LegalSection {
  heading: string;
  paragraphs: string[];
  bullets: string[];
}

interface LegalDocument {
  type: LegalDocumentType;
  slug: string;
  locale: string;
  version: string;
  title: string;
  status: LegalDocumentStatus;
  effectiveAt: string | null;
  counselApproved: boolean;
  requiresRenewedAcceptance: boolean;
  summary: string;
  sections: LegalSection[];
  contentSha256: string;
}

interface LegalCatalog {
  schemaVersion: number;
  documents: LegalDocument[];
}

interface SignupAcceptanceInput {
  document_type: string;
  version: string;
  locale: string;
  affirmative?: boolean;
}

interface QueryExecutor {
  query<T extends QueryResultRow = QueryResultRow>(
    text: string,
    params?: unknown[],
  ): Promise<QueryResult<T>>;
}

const allowedTypes = new Set<LegalDocumentType>([
  'privacy',
  'terms',
  'acceptable_use',
  'important_notices',
  'account_deletion',
  'subprocessors',
  'open_source',
]);
const mandatoryAcceptanceTypes = ['terms', 'acceptable_use'] as const;
const slugPattern = /^[a-z][a-z0-9-]{1,79}$/;
const versionPattern = /^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$/;
const localePattern = /^[a-z]{2}(?:-[A-Z]{2})?$/;
const maxCatalogBytes = 512 * 1024;

let cachedCatalog:
  | { filePath: string; modifiedAtMs: number; catalog: LegalCatalog }
  | undefined;

const requiredString = (value: unknown, label: string, maxLength: number): string => {
  if (typeof value !== 'string') {
    throw new Error(`${label} must be a string`);
  }
  const trimmed = value.trim();
  if (!trimmed || trimmed.length > maxLength) {
    throw new Error(`${label} must contain 1-${maxLength} characters`);
  }
  return trimmed;
};

const resolveCatalogPath = (): string => {
  const candidates = [
    path.resolve(process.cwd(), 'docs', 'legal', 'legal-documents.json'),
    path.resolve(process.cwd(), 'apps', 'api', 'docs', 'legal', 'legal-documents.json'),
    path.resolve(__dirname, '..', '..', 'docs', 'legal', 'legal-documents.json'),
    path.resolve(__dirname, '..', '..', '..', 'apps', 'api', 'docs', 'legal', 'legal-documents.json'),
  ];
  const match = candidates.find((candidate) => fs.existsSync(candidate));
  if (!match) {
    throw new Error(`Legal document catalog was not found. Checked: ${candidates.join(', ')}`);
  }
  return match;
};

const parseSection = (value: unknown, documentLabel: string, index: number): LegalSection => {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error(`${documentLabel} section ${index} must be an object`);
  }
  const record = value as Record<string, unknown>;
  const paragraphs = Array.isArray(record.paragraphs)
    ? record.paragraphs.map((item, paragraphIndex) =>
        requiredString(item, `${documentLabel} paragraph ${paragraphIndex}`, 4000),
      )
    : [];
  const bullets = Array.isArray(record.bullets)
    ? record.bullets.map((item, bulletIndex) =>
        requiredString(item, `${documentLabel} bullet ${bulletIndex}`, 2000),
      )
    : [];
  if (paragraphs.length + bullets.length === 0) {
    throw new Error(`${documentLabel} section ${index} cannot be empty`);
  }
  return {
    heading: requiredString(record.heading, `${documentLabel} section heading`, 200),
    paragraphs,
    bullets,
  };
};

const parseDocument = (value: unknown, index: number): LegalDocument => {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error(`Legal document ${index} must be an object`);
  }
  const record = value as Record<string, unknown>;
  const type = requiredString(record.type, `document ${index} type`, 80) as LegalDocumentType;
  const slug = requiredString(record.slug, `document ${index} slug`, 80);
  const version = requiredString(record.version, `document ${index} version`, 80);
  const locale = requiredString(record.locale, `document ${index} locale`, 12);
  const status = requiredString(record.status, `document ${index} status`, 20) as LegalDocumentStatus;
  if (!allowedTypes.has(type) || !slugPattern.test(slug) || !versionPattern.test(version)) {
    throw new Error(`Legal document ${index} contains an unsupported identity`);
  }
  if (!localePattern.test(locale) || !['draft', 'approved', 'retired'].includes(status)) {
    throw new Error(`Legal document ${index} contains an unsupported locale or status`);
  }
  const effectiveAt = record.effectiveAt == null ? null : requiredString(record.effectiveAt, 'effectiveAt', 80);
  if (effectiveAt && Number.isNaN(Date.parse(effectiveAt))) {
    throw new Error(`Legal document ${index} effectiveAt is invalid`);
  }
  const counselApproved = record.counselApproved === true;
  const requiresRenewedAcceptance = record.requiresRenewedAcceptance === true;
  if (
    mandatoryAcceptanceTypes.includes(type as (typeof mandatoryAcceptanceTypes)[number]) &&
    typeof record.requiresRenewedAcceptance !== 'boolean'
  ) {
    throw new Error(
      `Legal document ${slug} must explicitly classify whether the change requires renewed acceptance`,
    );
  }
  if (status === 'approved' && (!counselApproved || !effectiveAt)) {
    throw new Error(`Approved legal document ${slug} requires counsel approval and effectiveAt`);
  }
  if (!Array.isArray(record.sections) || record.sections.length === 0 || record.sections.length > 50) {
    throw new Error(`Legal document ${slug} requires 1-50 sections`);
  }
  const base = {
    type,
    slug,
    locale,
    version,
    title: requiredString(record.title, `document ${index} title`, 200),
    status,
    effectiveAt,
    counselApproved,
    requiresRenewedAcceptance,
    summary: requiredString(record.summary, `document ${index} summary`, 1000),
    sections: record.sections.map((section, sectionIndex) =>
      parseSection(section, slug, sectionIndex),
    ),
  };
  return {
    ...base,
    contentSha256: createHash('sha256').update(JSON.stringify(base)).digest('hex'),
  };
};

const loadLegalCatalog = (): LegalCatalog => {
  const filePath = resolveCatalogPath();
  const descriptor = fs.openSync(filePath, 'r');
  try {
    const stat = fs.fstatSync(descriptor);
    if (stat.size > maxCatalogBytes) {
      throw new Error('Legal document catalog exceeds the 512 KB safety limit');
    }
    if (cachedCatalog?.filePath === filePath && cachedCatalog.modifiedAtMs === stat.mtimeMs) {
      return cachedCatalog.catalog;
    }
    const parsed = JSON.parse(fs.readFileSync(descriptor, 'utf8')) as Record<string, unknown>;
    if (parsed.schemaVersion !== 1 || !Array.isArray(parsed.documents)) {
      throw new Error('Unsupported legal document catalog schema');
    }
    const documents = parsed.documents.map(parseDocument);
    const identities = new Set<string>();
    for (const document of documents) {
      const identity = `${document.type}:${document.locale}:${document.version}`;
      if (identities.has(identity)) {
        throw new Error(`Duplicate legal document identity: ${identity}`);
      }
      identities.add(identity);
    }
    const catalog = { schemaVersion: 1, documents };
    cachedCatalog = { filePath, modifiedAtMs: stat.mtimeMs, catalog };
    return catalog;
  } finally {
    fs.closeSync(descriptor);
  }
};

const environmentFlag = (name: string, fallback: boolean): boolean => {
  const value = process.env[name]?.trim().toLowerCase();
  if (!value) return fallback;
  return ['1', 'true', 'yes'].includes(value);
};

const legalEnforcementEnabled = (): boolean =>
  environmentFlag('LEGAL_ENFORCEMENT_ENABLED', false);

const draftsMayBeServed = (): boolean =>
  process.env.NODE_ENV !== 'production' && environmentFlag('LEGAL_DRAFTS_PUBLIC_ENABLED', true);

const listPublicLegalDocuments = (locale = 'en'): LegalDocument[] => {
  const normalizedLocale = localePattern.test(locale) ? locale : 'en';
  return loadLegalCatalog().documents.filter(
    (document) =>
      document.locale === normalizedLocale &&
      document.status !== 'retired' &&
      ((document.status === 'approved' && document.counselApproved) || draftsMayBeServed()),
  );
};

const findPublicLegalDocument = ({
  slug,
  locale = 'en',
  version,
}: {
  slug: string;
  locale?: string;
  version?: string;
}): LegalDocument | undefined =>
  listPublicLegalDocuments(locale).find(
    (document) => document.slug === slug && (version == null || document.version === version),
  );

const currentDocumentByType = (type: LegalDocumentType, locale = 'en'): LegalDocument | undefined =>
  listPublicLegalDocuments(locale).find((document) => document.type === type);

const getExistingUserAcceptanceStatus = async ({
  executor,
  userId,
  locale = 'en',
}: {
  executor: QueryExecutor;
  userId: string;
  locale?: string;
}): Promise<{ required: boolean; missing: LegalDocument[] }> => {
  if (!legalEnforcementEnabled()) {
    return { required: false, missing: [] };
  }
  const renewalDocuments = mandatoryAcceptanceTypes
    .map((type) => currentDocumentByType(type, locale))
    .filter(
      (document): document is LegalDocument =>
        Boolean(document?.requiresRenewedAcceptance),
    );
  if (renewalDocuments.length === 0) {
    return { required: false, missing: [] };
  }
  const accepted = await executor.query<{
    document_type: string;
    document_version: string;
    locale: string;
  }>(
    `SELECT document_type, document_version, locale
     FROM legal_acceptance
     WHERE user_id = $1
       AND withdrawn_at IS NULL
       AND document_type = ANY($2::TEXT[])`,
    [userId, renewalDocuments.map((document) => document.type)],
  );
  const missing = renewalDocuments.filter(
    (document) =>
      !accepted.rows.some(
        (row) =>
          row.document_type === document.type &&
          row.document_version === document.version &&
          row.locale === document.locale,
      ),
  );
  return { required: missing.length > 0, missing };
};

const validateSignupAcceptances = (value: unknown): SignupAcceptanceInput[] => {
  const requiredDocuments = mandatoryAcceptanceTypes.map((type) => currentDocumentByType(type));
  if (legalEnforcementEnabled() && requiredDocuments.some((document) => !document)) {
    throw new AppError('Registration is unavailable until approved legal documents are published.', 503, {
      code: 'LEGAL_DOCUMENTS_NOT_READY',
      disposition: 'retry',
      retryable: false,
    });
  }
  const inputs = Array.isArray(value) ? value : [];
  if (inputs.length === 0 && !legalEnforcementEnabled()) {
    return [];
  }
  if (inputs.length > 4) {
    throw new AppError('Legal acceptance evidence is invalid.', 422);
  }
  const accepted = inputs.map((input) => {
    if (!input || typeof input !== 'object' || Array.isArray(input)) {
      throw new AppError('Legal acceptance evidence is invalid.', 422);
    }
    const record = input as Record<string, unknown>;
    return {
      document_type: requiredString(record.document_type, 'document_type', 80),
      version: requiredString(record.version, 'version', 80),
      locale: requiredString(record.locale, 'locale', 12),
      affirmative: record.affirmative === true,
    };
  });
  if (
    accepted.some(
      (input) =>
        !mandatoryAcceptanceTypes.includes(
          input.document_type as (typeof mandatoryAcceptanceTypes)[number],
        ),
    )
  ) {
    throw new AppError('Privacy notices must not be submitted as bundled consent.', 422);
  }
  for (const type of mandatoryAcceptanceTypes) {
    const document = currentDocumentByType(type);
    if (!document) continue;
    const match = accepted.find(
      (input) =>
        input.document_type === type &&
        input.version === document.version &&
        input.locale === document.locale &&
        input.affirmative,
    );
    if (!match) {
      throw new AppError('Accept the current Terms of Use and Acceptable Use Policy.', 422, {
        code: 'LEGAL_ACCEPTANCE_REQUIRED',
        disposition: 'permanent_rejection',
        retryable: false,
      });
    }
  }
  return accepted;
};

const recordLegalAcceptances = async ({
  executor,
  userId,
  sessionId,
  requestId,
  acceptances,
  source,
}: {
  executor: QueryExecutor;
  userId: string;
  sessionId?: string | null;
  requestId?: string | null;
  acceptances: SignupAcceptanceInput[];
  source: 'signup' | 'existing_user';
}): Promise<void> => {
  for (const acceptance of acceptances) {
    const document = loadLegalCatalog().documents.find(
      (candidate) =>
        candidate.type === acceptance.document_type &&
        candidate.version === acceptance.version &&
        candidate.locale === acceptance.locale,
    );
    if (!document || acceptance.affirmative !== true) {
      throw new AppError('Legal acceptance evidence is invalid or obsolete.', 422);
    }
    await executor.query(
      `UPDATE legal_document_version
       SET is_current = FALSE, updated_at = CURRENT_TIMESTAMP
       WHERE document_type = $1 AND locale = $2 AND version <> $3 AND is_current = TRUE`,
      [document.type, document.locale, document.version],
    );
    await executor.query(
      `INSERT INTO legal_document_version
         (document_type, version, locale, title, content_sha256, status,
          effective_at, counsel_approved_at, approval_reference, is_current)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, TRUE)
       ON CONFLICT (document_type, version, locale) DO UPDATE SET
         title = EXCLUDED.title,
         content_sha256 = EXCLUDED.content_sha256,
         status = EXCLUDED.status,
         effective_at = EXCLUDED.effective_at,
         counsel_approved_at = EXCLUDED.counsel_approved_at,
         approval_reference = EXCLUDED.approval_reference,
         is_current = TRUE,
         updated_at = CURRENT_TIMESTAMP`,
      [
        document.type,
        document.version,
        document.locale,
        document.title,
        document.contentSha256,
        document.status,
        document.effectiveAt,
        document.counselApproved ? document.effectiveAt : null,
        document.counselApproved ? process.env.LEGAL_COUNSEL_APPROVAL_REFERENCE ?? null : null,
      ],
    );
    await executor.query(
      `INSERT INTO legal_acceptance
         (user_id, document_type, document_version, locale, session_id, request_id, evidence)
       VALUES ($1, $2, $3, $4, $5, $6, $7::JSONB)
       ON CONFLICT (user_id, document_type, document_version, locale) DO NOTHING`,
      [
        userId,
        document.type,
        document.version,
        document.locale,
        sessionId ?? null,
        requestId?.slice(0, 160) ?? null,
        JSON.stringify({ source, affirmative: true }),
      ],
    );
  }
};

const publicDocumentJson = (document: LegalDocument) => ({
  type: document.type,
  slug: document.slug,
  locale: document.locale,
  version: document.version,
  title: document.title,
  status: document.status,
  effective_at: document.effectiveAt,
  counsel_approved: document.counselApproved,
  requires_renewed_acceptance: document.requiresRenewedAcceptance,
  summary: document.summary,
  sections: document.sections,
  content_sha256: document.contentSha256,
});

export {
  draftsMayBeServed,
  findPublicLegalDocument,
  getExistingUserAcceptanceStatus,
  legalEnforcementEnabled,
  listPublicLegalDocuments,
  publicDocumentJson,
  recordLegalAcceptances,
  validateSignupAcceptances,
};
export type { LegalDocument, LegalDocumentType, SignupAcceptanceInput };
