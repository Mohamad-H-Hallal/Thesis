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

function isNonEmptyString(value) {
  return typeof value === 'string' && value.trim().length > 0;
}

function inspectLegalReadiness(readiness, catalog) {
  const failures = [];
  if (!readiness || readiness.schemaVersion !== 1) {
    failures.push('release-readiness.json must use schemaVersion 1');
    return failures;
  }
  if (readiness.productionAuthorized !== true) {
    failures.push('productionAuthorized is not approved');
  }
  if (
    readiness.counselApproval?.approved !== true ||
    !isNonEmptyString(readiness.counselApproval?.approvalReference)
  ) {
    failures.push('counsel approval and its evidence reference are required');
  }
  for (const [decision, approved] of Object.entries(readiness.decisions ?? {})) {
    if (approved !== true) failures.push(`decision is unresolved: ${decision}`);
  }
  if (!readiness.decisions || Object.keys(readiness.decisions).length === 0) {
    failures.push('legal decision register is empty');
  }
  for (const decision of requiredDecisionKeys) {
    if (!Object.prototype.hasOwnProperty.call(readiness.decisions ?? {}, decision)) {
      failures.push(`required legal decision is missing: ${decision}`);
    }
  }
  for (const [item, approved] of Object.entries(readiness.storeDisclosures ?? {})) {
    if (approved !== true) failures.push(`store disclosure is not approved: ${item}`);
  }
  for (const [item, approved] of Object.entries(readiness.platformReadiness ?? {})) {
    if (approved !== true) failures.push(`platform readiness is incomplete: ${item}`);
  }
  for (const [item, approved] of Object.entries(readiness.mapSources ?? {})) {
    if (approved !== true) failures.push(`map/license readiness is incomplete: ${item}`);
  }

  if (!catalog || catalog.schemaVersion !== 1 || !Array.isArray(catalog.documents)) {
    failures.push('legal-documents.json must use schemaVersion 1 with a documents array');
    return failures;
  }
  for (const type of requiredDocumentTypes) {
    const approved = catalog.documents.filter(
      (document) =>
        document?.type === type &&
        document?.locale === 'en' &&
        document?.status === 'approved' &&
        document?.counselApproved === true &&
        isNonEmptyString(document?.effectiveAt),
    );
    if (approved.length !== 1) {
      failures.push(`exactly one current approved English document is required: ${type}`);
      continue;
    }
    const serialized = JSON.stringify(approved[0]);
    if (/\[\s*(?:DECISION|OWNER|LEGAL)[^\]]*REQUIRED/i.test(serialized)) {
      failures.push(`approved document still contains a decision placeholder: ${type}`);
    }
    if (
      ['terms', 'acceptable_use'].includes(type) &&
      typeof approved[0].requiresRenewedAcceptance !== 'boolean'
    ) {
      failures.push(`material-change acceptance classification is required: ${type}`);
    }
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

module.exports = { inspectLegalReadiness, requiredDecisionKeys, run };
