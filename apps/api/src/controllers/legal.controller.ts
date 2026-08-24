import type { Request, Response } from 'express';
import { query, transaction } from '../config/database';
import {
  draftsMayBeServed,
  findPublicLegalDocument,
  getExistingUserAcceptanceStatus,
  listPublicLegalDocuments,
  publicDocumentJson,
  recordLegalAcceptances,
  validateSignupAcceptances,
} from '../legal/legalDocuments';

const escapeHtml = (value: string): string =>
  value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');

const legalPageStyles = `
  :root { color-scheme: light dark; font-family: system-ui, -apple-system, sans-serif; }
  body { margin: 0; line-height: 1.55; background: Canvas; color: CanvasText; }
  main { max-width: 820px; margin: 0 auto; padding: 32px 20px 64px; }
  nav { display: flex; flex-wrap: wrap; gap: 12px; margin: 20px 0 28px; }
  a { color: LinkText; }
  .status { border: 2px solid #b45309; background: #fef3c7; color: #451a03; padding: 12px; border-radius: 8px; }
  .meta { color: GrayText; }
  section { margin-top: 28px; }
  h1, h2 { line-height: 1.2; }
  label { display: block; font-weight: 600; margin: 20px 0 6px; }
  input { box-sizing: border-box; width: 100%; max-width: 520px; padding: 10px; }
  button { margin-top: 20px; padding: 10px 16px; font: inherit; }
`;

const setLegalHeaders = (res: Response, isDraft: boolean): void => {
  res.setHeader(
    'Content-Security-Policy',
    "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'",
  );
  res.setHeader('X-Robots-Tag', isDraft ? 'noindex, nofollow' : 'index, follow');
  res.setHeader('Cache-Control', isDraft ? 'no-store' : 'public, max-age=300');
};

const legalIndexHtml = (
  documents: ReturnType<typeof listPublicLegalDocuments>,
): string => `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>TerraLeb Legal</title><style>${legalPageStyles}</style></head><body><main>
<h1>TerraLeb legal information</h1>
${draftsMayBeServed() ? '<p class="status"><strong>Legal-review draft.</strong> These pages are not approved for public production.</p>' : ''}
<nav>${documents.map((document) => `<a href="/legal/${encodeURIComponent(document.slug)}">${escapeHtml(document.title)}</a>`).join('')}</nav>
<p>Each page identifies its exact version and approval state. Contact details and final legal positions are published only after owner and counsel approval.</p>
</main></body></html>`;

const legalDocumentHtml = (
  document: NonNullable<ReturnType<typeof findPublicLegalDocument>>,
  allDocuments: ReturnType<typeof listPublicLegalDocuments>,
): string => `<!doctype html>
<html lang="${escapeHtml(document.locale)}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${escapeHtml(document.title)}</title><style>${legalPageStyles}</style></head><body><main>
<a href="/legal">← Legal information</a>
<h1>${escapeHtml(document.title)}</h1>
${document.status !== 'approved' ? '<p class="status"><strong>Legal-review draft.</strong> This document is not approved for public production and contains unresolved decisions.</p>' : ''}
<p class="meta">Version ${escapeHtml(document.version)} · Locale ${escapeHtml(document.locale)}${document.effectiveAt ? ` · Effective ${escapeHtml(document.effectiveAt)}` : ''}</p>
<p>${escapeHtml(document.summary)}</p>
${document.sections
  .map(
    (section) =>
      `<section><h2>${escapeHtml(section.heading)}</h2>${section.paragraphs
        .map((paragraph) => `<p>${escapeHtml(paragraph)}</p>`)
        .join(
          '',
        )}${section.bullets.length ? `<ul>${section.bullets.map((bullet) => `<li>${escapeHtml(bullet)}</li>`).join('')}</ul>` : ''}</section>`,
  )
  .join('')}
<nav aria-label="Other legal documents">${allDocuments
  .filter((candidate) => candidate.slug !== document.slug)
  .map(
    (candidate) =>
      `<a href="/legal/${encodeURIComponent(candidate.slug)}">${escapeHtml(candidate.title)}</a>`,
  )
  .join('')}</nav>
</main></body></html>`;

const accountDeletionRequestHtml = (submitted = false): string => `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>TerraLeb account deletion request</title><style>${legalPageStyles}</style></head><body><main>
<a href="/legal/account-deletion">← Account deletion information</a>
<h1>Request account deletion</h1>
${draftsMayBeServed() ? '<p class="status"><strong>Legal-review draft.</strong> Final controller contact and process terms require approval.</p>' : ''}
${
  submitted
    ? '<p role="status"><strong>If the details match a TerraLeb account, a deletion request has been recorded for identity verification.</strong> The same response is shown whether or not an account exists.</p>'
    : `<p>Enter the email address used for your account. This form never confirms whether an account exists and does not delete an account without identity verification.</p>
<form method="post" action="/legal/account-deletion/request">
  <label for="account-email">Account email</label>
  <input id="account-email" name="email" type="email" autocomplete="email" maxlength="320" required>
  <button type="submit">Submit deletion request</button>
</form>`
}
<p>For an active account, the in-app Privacy center is the preferred route because it supports reauthentication and request status.</p>
</main></body></html>`;

const getPublicAccountDeletionRequest = (_req: Request, res: Response): void => {
  setLegalHeaders(res, draftsMayBeServed());
  res.setHeader('Cache-Control', 'no-store');
  res.type('html').send(accountDeletionRequestHtml());
};

const submitPublicAccountDeletionRequest = async (req: Request, res: Response): Promise<void> => {
  const email = typeof req.body?.email === 'string' ? req.body.email.trim().toLowerCase() : '';
  if (email.length > 0 && email.length <= 320 && email.includes('@')) {
    await transaction(async (client) => {
      const userResult = await client.query<{ id: string }>(
        `SELECT id
         FROM "user"
         WHERE email_canonical = $1
           AND account_status <> 'deleted'
         LIMIT 1`,
        [email],
      );
      const userId = userResult.rows[0]?.id;
      if (!userId) return;
      const requestResult = await client.query<{ id: string }>(
        `INSERT INTO privacy_request (
           user_id, request_type, status, request_details, last_user_visible_message
         )
         VALUES (
           $1, 'deletion', 'pending_verification',
           '{"source":"public_account_deletion_form"}'::JSONB,
           'Deletion request received. Identity verification is required before action.'
         )
         ON CONFLICT (user_id, request_type)
           WHERE user_id IS NOT NULL
             AND status IN ('pending_verification', 'submitted', 'in_review', 'scheduled', 'processing', 'failed')
         DO UPDATE SET updated_at = CURRENT_TIMESTAMP
         RETURNING id`,
        [userId],
      );
      const requestId = requestResult.rows[0]?.id;
      if (!requestId) return;
      await client.query(
        `INSERT INTO audit_log (
           user_id, action_type, entity_type, entity_id, new_values, ip_address
         )
         VALUES ($1, 'create', 'privacy_request', $2,
                 '{"source":"public_account_deletion_form","identity_verification_required":true}'::JSONB,
                 NULLIF($3, '')::INET)`,
        [userId, requestId, req.ip ?? ''],
      );
    });
  }
  setLegalHeaders(res, draftsMayBeServed());
  res.setHeader('Cache-Control', 'no-store');
  res.status(202).type('html').send(accountDeletionRequestHtml(true));
};

const listDocuments = (req: Request, res: Response): void => {
  const locale = typeof req.query.locale === 'string' ? req.query.locale : 'en';
  const documents = listPublicLegalDocuments(locale);
  if (documents.length === 0) {
    res.status(503).json({
      success: false,
      message: 'Approved legal documents are not yet published.',
      error: {
        code: 'LEGAL_DOCUMENTS_NOT_READY',
        disposition: 'retry',
        retryable: false,
      },
    });
    return;
  }
  setLegalHeaders(
    res,
    documents.some((document) => document.status !== 'approved'),
  );
  if (req.query.format === 'json' || req.path.startsWith('/documents')) {
    res.json({
      success: true,
      data: {
        documents: documents.map(publicDocumentJson),
        mandatory_acceptance_types: ['terms', 'acceptable_use'],
      },
    });
    return;
  }
  res.type('html').send(legalIndexHtml(documents));
};

const getDocument = (req: Request, res: Response): void => {
  const locale = typeof req.query.locale === 'string' ? req.query.locale : 'en';
  const version = typeof req.params.version === 'string' ? req.params.version : undefined;
  const document = findPublicLegalDocument({ slug: req.params.slug, locale, version });
  if (!document) {
    res.status(process.env.NODE_ENV === 'production' ? 503 : 404).json({
      success: false,
      message:
        process.env.NODE_ENV === 'production'
          ? 'Approved legal document is not yet published.'
          : 'Legal document was not found.',
    });
    return;
  }
  setLegalHeaders(res, document.status !== 'approved');
  if (req.query.format === 'json' || req.path.startsWith('/documents')) {
    res.json({ success: true, data: { document: publicDocumentJson(document) } });
    return;
  }
  res.type('html').send(legalDocumentHtml(document, listPublicLegalDocuments(locale)));
};

const getAcceptanceStatus = async (req: Request, res: Response): Promise<void> => {
  const acceptanceStatus = await getExistingUserAcceptanceStatus({
    executor: { query },
    userId: req.user!.id,
  });
  const mandatory = listPublicLegalDocuments('en').filter((document) =>
    ['terms', 'acceptable_use'].includes(document.type),
  );
  const accepted = await query<{
    document_type: string;
    document_version: string;
    locale: string;
    accepted_at: Date | string;
  }>(
    `SELECT document_type, document_version, locale, accepted_at
     FROM legal_acceptance
     WHERE user_id = $1
       AND withdrawn_at IS NULL
       AND document_type = ANY($2::TEXT[])
     ORDER BY accepted_at DESC`,
    [req.user!.id, mandatory.map((document) => document.type)],
  );
  res.json({
    success: true,
    data: {
      current: !acceptanceStatus.required,
      acceptance_required: acceptanceStatus.required,
      missing: acceptanceStatus.missing.map(publicDocumentJson),
      required_documents: mandatory.map(publicDocumentJson),
      accepted: accepted.rows,
    },
  });
};

const acceptCurrentDocuments = async (req: Request, res: Response): Promise<void> => {
  const acceptances = validateSignupAcceptances(req.body?.acceptances);
  await transaction((client) =>
    recordLegalAcceptances({
      executor: client,
      userId: req.user!.id,
      sessionId: req.authSessionId ?? null,
      requestId: req.requestId ?? null,
      acceptances,
      source: 'existing_user',
    }),
  );
  res.status(201).json({
    success: true,
    message: 'Legal document acceptance recorded.',
  });
};

export {
  acceptCurrentDocuments,
  getAcceptanceStatus,
  getDocument,
  getPublicAccountDeletionRequest,
  listDocuments,
  submitPublicAccountDeletionRequest,
};
