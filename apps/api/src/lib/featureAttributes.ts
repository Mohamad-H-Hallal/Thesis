const normalizeFeatureAttributeKey = (key: string): string =>
  key.trim().toLowerCase().replace(/[^a-z0-9]/g, '');

const managedFeatureAttributeKeys = new Set([
  'id',
  'featureid',
  'featid',
  'projectid',
  'userid',
  'ownerid',
  'creatorid',
  'collectedbyuserid',
  'collectedby',
  'collectby',
  'reviewedbyuserid',
  'reviewedby',
  'reviewerid',
  'status',
  'reviewstatus',
  'approvalstatus',
  'administrativestatus',
  'assignmentid',
  'taskid',
  'reviewtaskid',
  'formid',
  'role',
  'permissions',
  'version',
  'collectedoffline',
  'collectedat',
  'collectat',
  'submittedat',
  'reviewedat',
  'syncedat',
  'createdat',
  'updatedat',
  'deletedat',
  'photocount',
  'photocnt',
  'primaryphotopath',
  'photopaths',
  'photoref',
  'photomanifestref',
]);

const shouldStripManagedFeatureAttributeKey = (key: string): boolean => {
  const normalized = normalizeFeatureAttributeKey(key);
  return (
    managedFeatureAttributeKeys.has(normalized) ||
    normalized === 'accuracy' ||
    normalized === 'accuracymeter' ||
    normalized === 'accuracymeters'
  );
};

const sanitizeManagedFeatureAttributes = (
  attributesInput: unknown,
): Record<string, unknown> => {
  if (!attributesInput || typeof attributesInput !== 'object' || Array.isArray(attributesInput)) {
    return {};
  }

  const sanitizedEntries = Object.entries(
    attributesInput as Record<string, unknown>,
  ).filter(([key]) => !shouldStripManagedFeatureAttributeKey(key));

  return Object.fromEntries(sanitizedEntries);
};

export {
  sanitizeManagedFeatureAttributes,
  shouldStripManagedFeatureAttributeKey,
};
