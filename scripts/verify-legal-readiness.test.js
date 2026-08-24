'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const { inspectLegalReadiness, requiredDecisionKeys } = require('./verify-legal-readiness');

const requiredTypes = [
  'privacy',
  'terms',
  'acceptable_use',
  'important_notices',
  'account_deletion',
  'subprocessors',
  'open_source',
];

function approvedFixture() {
  return {
    readiness: {
      schemaVersion: 1,
      productionAuthorized: true,
      counselApproval: { approved: true, approvalReference: 'legal-review-2026-001' },
      decisions: Object.fromEntries(requiredDecisionKeys.map((decision) => [decision, true])),
      storeDisclosures: { appleApproved: true, googlePlayApproved: true },
      platformReadiness: { accountDeletionVerified: true },
      mapSources: { attributionVerified: true },
    },
    catalog: {
      schemaVersion: 1,
      documents: requiredTypes.map((type) => ({
        type,
        locale: 'en',
        version: '1.0.0',
        status: 'approved',
        counselApproved: true,
        effectiveAt: '2026-09-01T00:00:00Z',
        requiresRenewedAcceptance: ['terms', 'acceptable_use'].includes(type),
        sections: [{ heading: 'Approved', paragraphs: ['Final text'], bullets: [] }],
      })),
    },
  };
}

test('approved fixture passes the legal production gate', () => {
  const fixture = approvedFixture();
  assert.deepEqual(inspectLegalReadiness(fixture.readiness, fixture.catalog), []);
});

test('unresolved decisions and draft documents fail closed', () => {
  const fixture = approvedFixture();
  fixture.readiness.productionAuthorized = false;
  fixture.readiness.decisions.retentionMatrix = false;
  fixture.catalog.documents[0].status = 'draft';
  const failures = inspectLegalReadiness(fixture.readiness, fixture.catalog);
  assert.ok(failures.some((failure) => failure.includes('productionAuthorized')));
  assert.ok(failures.some((failure) => failure.includes('retentionMatrix')));
  assert.ok(failures.some((failure) => failure.includes('privacy')));
});

test('a required decision cannot be omitted to bypass the release gate', () => {
  const fixture = approvedFixture();
  delete fixture.readiness.decisions.maskedContributorDisplayPolicy;
  assert.ok(
    inspectLegalReadiness(fixture.readiness, fixture.catalog).some((failure) =>
      failure.includes('required legal decision is missing: maskedContributorDisplayPolicy'),
    ),
  );
});

test('approved text cannot retain decision placeholders', () => {
  const fixture = approvedFixture();
  fixture.catalog.documents[1].sections[0].paragraphs[0] = '[DECISION REQUIRED: operator]';
  assert.ok(
    inspectLegalReadiness(fixture.readiness, fixture.catalog).some((failure) =>
      failure.includes('placeholder'),
    ),
  );
});
