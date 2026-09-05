'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const {
  inspectLegalReadiness,
  requiredDecisionKeys,
  requiredDocumentTypes,
  requiredMapSourceKeys,
  requiredPlatformReadinessKeys,
  requiredStoreDisclosureKeys,
} = require('./verify-legal-readiness');

const evidence = (status = 'approved') => ({
  status,
  responsibleOwner: 'accountable-owner',
  reviewedAt: '2026-08-26T00:00:00.000Z',
  evidenceReference: `sha256:${'a'.repeat(64)}`,
  applicableVersion: 'android-web-v1',
  ...(status === 'not_in_release_scope' ? { rationale: 'Excluded from this release.' } : {}),
});

function records(keys, status = 'approved') {
  return Object.fromEntries(keys.map((key) => [key, evidence(status)]));
}

function approvedFixture() {
  return {
    readiness: {
      schemaVersion: 2,
      productionAuthorized: true,
      releaseScope: {
        releaseName: 'android-web-v1',
        platforms: ['android', 'web'],
        territories: ['LB'],
        requiredLocales: ['ar', 'en'],
      },
      productionAuthorization: evidence(),
      counselApproval: evidence(),
      decisions: records(requiredDecisionKeys),
      storeDisclosures: records(requiredStoreDisclosureKeys),
      platformReadiness: records(requiredPlatformReadinessKeys),
      mapSources: records(requiredMapSourceKeys),
      excludedCapabilities: { esriOfflineRedistribution: evidence('not_in_release_scope') },
      legalDocuments: records(requiredDocumentTypes),
    },
    catalog: {
      schemaVersion: 1,
      documents: requiredDocumentTypes.flatMap((type) =>
        ['ar', 'en'].map((locale) => ({
          type,
          locale,
          version: '1.0.0',
          status: 'approved',
          counselApproved: true,
          effectiveAt: '2026-09-01T00:00:00Z',
          requiresRenewedAcceptance: ['terms', 'acceptable_use'].includes(type),
          sections: [{ heading: 'Approved', paragraphs: ['Final text'], bullets: [] }],
        })),
      ),
    },
  };
}

test('evidence-backed approved fixture passes the legal production gate', () => {
  const fixture = approvedFixture();
  assert.deepEqual(inspectLegalReadiness(fixture.readiness, fixture.catalog), []);
});

test('blocked decisions and legal documents fail closed without multiplying locale findings', () => {
  const fixture = approvedFixture();
  fixture.readiness.productionAuthorized = false;
  fixture.readiness.productionAuthorization = {
    ...evidence('blocked'),
    reviewedAt: null,
    evidenceReference: null,
  };
  fixture.readiness.decisions.retentionMatrix = {
    ...evidence('blocked'),
    reviewedAt: null,
    evidenceReference: null,
  };
  fixture.readiness.legalDocuments.privacy = {
    ...evidence('blocked'),
    reviewedAt: null,
    evidenceReference: null,
  };
  const failures = inspectLegalReadiness(fixture.readiness, fixture.catalog);
  assert.ok(failures.some((failure) => failure.includes('productionAuthorization')));
  assert.ok(failures.some((failure) => failure.includes('decisions.retentionMatrix')));
  assert.ok(failures.some((failure) => failure.includes('legalDocuments.privacy')));
  assert.equal(failures.filter((failure) => failure.includes('legalDocuments.privacy')).length, 1);
});

test('a required decision cannot be omitted to bypass the release gate', () => {
  const fixture = approvedFixture();
  delete fixture.readiness.decisions.maskedContributorDisplayPolicy;
  assert.ok(
    inspectLegalReadiness(fixture.readiness, fixture.catalog).some((failure) =>
      failure.includes('required readiness item is missing: decisions.maskedContributorDisplayPolicy'),
    ),
  );
});

test('non-blocked findings require immutable evidence and an exact review date', () => {
  const fixture = approvedFixture();
  fixture.readiness.decisions.minimumAgeAndMinors.evidenceReference = 'TODO';
  fixture.readiness.decisions.minimumAgeAndMinors.reviewedAt = 'yesterday';
  const failures = inspectLegalReadiness(fixture.readiness, fixture.catalog);
  assert.ok(failures.some((failure) => failure.includes('immutable evidence')));
  assert.ok(failures.some((failure) => failure.includes('review date')));
});

test('out-of-scope status is limited to explicitly allowed release exclusions', () => {
  const fixture = approvedFixture();
  fixture.readiness.storeDisclosures.appleApproved = evidence('not_in_release_scope');
  fixture.readiness.platformReadiness.iosPurposeStringsVerified = evidence(
    'not_in_release_scope',
  );
  assert.deepEqual(inspectLegalReadiness(fixture.readiness, fixture.catalog), []);

  fixture.readiness.decisions.retentionMatrix = evidence('not_in_release_scope');
  assert.ok(
    inspectLegalReadiness(fixture.readiness, fixture.catalog).some((failure) =>
      failure.includes('not_in_release_scope is not permitted'),
    ),
  );
});

test('approved Arabic and English legal text cannot retain decision placeholders', () => {
  const fixture = approvedFixture();
  const termsArabic = fixture.catalog.documents.find(
    (document) => document.type === 'terms' && document.locale === 'ar',
  );
  termsArabic.sections[0].paragraphs[0] = '[DECISION REQUIRED: operator]';
  assert.ok(
    inspectLegalReadiness(fixture.readiness, fixture.catalog).some((failure) =>
      failure.includes('approved document still contains a decision placeholder: terms.ar'),
    ),
  );
});

test('live register closes adopted owner decisions but preserves real external gates', () => {
  const readiness = JSON.parse(
    fs.readFileSync(
      path.join(__dirname, '..', 'apps', 'api', 'docs', 'legal', 'release-readiness.json'),
      'utf8',
    ),
  );
  const catalog = JSON.parse(
    fs.readFileSync(
      path.join(__dirname, '..', 'apps', 'api', 'docs', 'legal', 'legal-documents.json'),
      'utf8',
    ),
  );

  for (const key of [
    'controllerProcessorRoles',
    'targetTerritoriesAndDistribution',
    'minimumAgeAndMinors',
    'retentionMatrix',
    'retainedInstitutionalRecordBasis',
    'maskedContributorDisplayPolicy',
    'photosPreciseLocationFreeTextTreatment',
    'backupAgeingPeriod',
    'contributorAndDeletionNoticeWording',
    'gisOwnershipAndPublication',
    'aiTrainingAndPublication',
    'requiredLanguages',
  ]) {
    assert.equal(readiness.decisions[key].status, 'approved', key);
    assert.match(readiness.decisions[key].evidenceReference, /sha256:[0-9a-f]{64}/);
  }

  for (const key of [
    'legalOperatorController',
    'privacyContact',
    'hostingRegionsAndSubprocessors',
    'mapAndOfflineRights',
    'governingLawAndDisputes',
    'lebanonLaw81Formalities',
  ]) {
    assert.equal(readiness.decisions[key].status, 'blocked', key);
  }
  assert.equal(readiness.productionAuthorized, false);
  assert.equal(inspectLegalReadiness(readiness, catalog).length, 30);
});
