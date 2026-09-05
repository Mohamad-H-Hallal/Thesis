#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const repoRoot = path.resolve(__dirname, '..');
const readinessPath = path.join(
  repoRoot,
  'apps',
  'api',
  'docs',
  'legal',
  'release-readiness.json',
);
const documentsPath = path.join(
  repoRoot,
  'apps',
  'api',
  'docs',
  'legal',
  'legal-documents.json',
);

const requiredDocumentTypes = [
  'privacy',
  'terms',
  'acceptable_use',
  'important_notices',
  'account_deletion',
  'subprocessors',
  'open_source',
];

const requiredDecisionKeys = [
  'legalOperatorController',
  'controllerProcessorRoles',
  'targetTerritoriesAndDistribution',
  'minimumAgeAndMinors',
  'privacyContact',
  'hostingRegionsAndSubprocessors',
  'retentionMatrix',
  'retainedInstitutionalRecordBasis',
  'maskedContributorDisplayPolicy',
  'photosPreciseLocationFreeTextTreatment',
  'backupAgeingPeriod',
  'contributorAndDeletionNoticeWording',
  'mapAndOfflineRights',
  'gisOwnershipAndPublication',
  'aiTrainingAndPublication',
  'governingLawAndDisputes',
  'requiredLanguages',
  'lebanonLaw81Formalities',
];

const requiredStoreDisclosureKeys = ['appleApproved', 'googlePlayApproved'];
const requiredPlatformReadinessKeys = [
  'accountDeletionVerified',
  'iosPurposeStringsVerified',
  'privacyManifestInventoryVerified',
  'productionIdentifiersVerified',
  'privacyRightsFulfillmentVerified',
  'retentionAutomationVerified',
  'notificationPrivacyVerified',
  'ugcModerationVerified',
  'accessibilityVerified',
  'softwareLicenseAndSbomVerified',
  'importProvenanceEnforcementVerified',
];
const requiredMapSourceKeys = [
  'openstreetmapOnlineReviewed',
  'esriOnlineLicensed',
  'offlinePackageSourceRights',
  'attributionVerified',
];

const allowedStatuses = new Set(['approved', 'blocked', 'not_in_release_scope']);
const immutableReferencePattern = /(?:sha256:[0-9a-f]{64}|git:[0-9a-f]{40}|provider:[^\s]+|counsel:[^\s]+)/i;
const forbiddenEvidencePattern = /(?:\bTODO\b|\bTBD\b|placeholder|replace[-_ ]?me|example\.(?:com|net|org))/i;

function isNonEmptyString(value) {
  return typeof value === 'string' && value.trim().length > 0;
}

function isIsoDate(value) {
  if (!isNonEmptyString(value)) return false;
  const parsed = new Date(value);
  return !Number.isNaN(parsed.valueOf()) && parsed.toISOString() === value;
}

function validateEvidenceRecord(record, label, failures, { allowNotInScope = false } = {}) {
  if (!record || typeof record !== 'object' || Array.isArray(record)) {
    failures.push(`evidence record is missing: ${label}`);
    return null;
  }
  if (!allowedStatuses.has(record.status)) {
    failures.push(`evidence status is invalid: ${label}`);
    return null;
  }
  if (!isNonEmptyString(record.responsibleOwner)) {
    failures.push(`responsible owner is missing: ${label}`);
  }
  if (!isNonEmptyString(record.applicableVersion)) {
    failures.push(`applicable version is missing: ${label}`);
  }
  if (record.status === 'blocked') {
    failures.push(`readiness item is blocked: ${label}`);
    return record.status;
  }
  if (record.status === 'not_in_release_scope' && !allowNotInScope) {
    failures.push(`not_in_release_scope is not permitted for: ${label}`);
  }
  if (record.status === 'not_in_release_scope' && !isNonEmptyString(record.rationale)) {
    failures.push(`out-of-scope rationale is missing: ${label}`);
  }
  if (!isIsoDate(record.reviewedAt)) {
    failures.push(`review date is missing or invalid: ${label}`);
  }
  if (
    !isNonEmptyString(record.evidenceReference) ||
    !immutableReferencePattern.test(record.evidenceReference) ||
    forbiddenEvidencePattern.test(record.evidenceReference)
  ) {
    failures.push(`immutable evidence reference is missing or invalid: ${label}`);
  }
  return record.status;
}

function validateRequiredGroup(readiness, groupName, requiredKeys, failures, options = {}) {
  const group = readiness[groupName];
  if (!group || typeof group !== 'object' || Array.isArray(group)) {
    for (const key of requiredKeys) {
      failures.push(`required readiness item is missing: ${groupName}.${key}`);
    }
    return;
  }
  for (const key of requiredKeys) {
    if (!Object.prototype.hasOwnProperty.call(group, key)) {
      failures.push(`required readiness item is missing: ${groupName}.${key}`);
      continue;
    }
    validateEvidenceRecord(group[key], `${groupName}.${key}`, failures, {
      allowNotInScope: options.allowedNotInScope?.has(key) === true,
    });
  }
}

function validateApprovedDocument(record, type, catalog, requiredLocales, failures) {
  if (record?.status !== 'approved') return;
  for (const locale of requiredLocales) {
    const approved = catalog.documents.filter(
      (document) =>
        document?.type === type &&
        document?.locale === locale &&
        document?.status === 'approved' &&
        document?.counselApproved === true &&
        isNonEmptyString(document?.effectiveAt),
    );
    if (approved.length !== 1) {
      failures.push(`exactly one current approved ${locale} document is required: ${type}`);
      continue;
    }
    const serialized = JSON.stringify(approved[0]);
    if (/\[\s*(?:DECISION|OWNER|LEGAL)[^\]]*REQUIRED/i.test(serialized)) {
      failures.push(`approved document still contains a decision placeholder: ${type}.${locale}`);
    }
    if (
      ['terms', 'acceptable_use'].includes(type) &&
      typeof approved[0].requiresRenewedAcceptance !== 'boolean'
    ) {
      failures.push(`material-change acceptance classification is required: ${type}.${locale}`);
    }
  }
}

function inspectLegalReadiness(readiness, catalog) {
  const failures = [];
  if (!readiness || readiness.schemaVersion !== 2) {
    failures.push('release-readiness.json must use schemaVersion 2');
    return failures;
  }
  const scope = readiness.releaseScope;
  if (
    !scope ||
    scope.releaseName !== 'android-web-v1' ||
    !Array.isArray(scope.platforms) ||
    !scope.platforms.includes('android') ||
    !scope.platforms.includes('web') ||
    scope.platforms.includes('ios') ||
    !Array.isArray(scope.territories) ||
    !scope.territories.includes('LB') ||
    !Array.isArray(scope.requiredLocales) ||
    !scope.requiredLocales.includes('en') ||
    !scope.requiredLocales.includes('ar')
  ) {
    failures.push('release scope must explicitly describe Lebanon-only Android/web v1 with Arabic and English');
  }

  const authorizationStatus = validateEvidenceRecord(
    readiness.productionAuthorization,
    'productionAuthorization',
    failures,
  );
  if (readiness.productionAuthorized !== (authorizationStatus === 'approved')) {
    failures.push('productionAuthorized must exactly match the approved authorization evidence');
  }
  validateEvidenceRecord(readiness.counselApproval, 'counselApproval', failures);
  validateRequiredGroup(readiness, 'decisions', requiredDecisionKeys, failures);
  validateRequiredGroup(readiness, 'storeDisclosures', requiredStoreDisclosureKeys, failures, {
    allowedNotInScope: new Set(['appleApproved']),
  });
  validateRequiredGroup(
    readiness,
    'platformReadiness',
    requiredPlatformReadinessKeys,
    failures,
    { allowedNotInScope: new Set(['iosPurposeStringsVerified']) },
  );
  validateRequiredGroup(readiness, 'mapSources', requiredMapSourceKeys, failures);

  validateEvidenceRecord(
    readiness.excludedCapabilities?.esriOfflineRedistribution,
    'excludedCapabilities.esriOfflineRedistribution',
    failures,
    { allowNotInScope: true },
  );

  if (!catalog || catalog.schemaVersion !== 1 || !Array.isArray(catalog.documents)) {
    failures.push('legal-documents.json must use schemaVersion 1 with a documents array');
    return failures;
  }
  for (const type of requiredDocumentTypes) {
    const record = readiness.legalDocuments?.[type];
    validateEvidenceRecord(record, `legalDocuments.${type}`, failures);
    validateApprovedDocument(record, type, catalog, scope?.requiredLocales ?? [], failures);
  }
  return failures;
}

function loadJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function run({ allowIncomplete = false } = {}) {
  const failures = inspectLegalReadiness(loadJson(readinessPath), loadJson(documentsPath));
  if (failures.length === 0) {
    process.stdout.write('TerraLeb legal production-readiness gate: PASS\n');
    return { ok: true, failures };
  }
  process.stdout.write(
    `TerraLeb legal production-readiness gate: BLOCKED (${failures.length} findings)\n${failures
      .map((failure) => `- ${failure}`)
      .join('\n')}\n`,
  );
  if (!allowIncomplete) process.exitCode = 1;
  return { ok: false, failures };
}

if (require.main === module) {
  run({ allowIncomplete: process.argv.includes('--allow-incomplete') });
}

module.exports = {
  inspectLegalReadiness,
  requiredDecisionKeys,
  requiredDocumentTypes,
  requiredMapSourceKeys,
  requiredPlatformReadinessKeys,
  requiredStoreDisclosureKeys,
  run,
};
