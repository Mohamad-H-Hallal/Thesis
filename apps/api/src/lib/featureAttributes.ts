const normalizeFeatureAttributeKey = (key: string): string =>
  key.trim().toLowerCase().replace(/[^a-z0-9]/g, '');

const shouldStripManagedFeatureAttributeKey = (key: string): boolean => {
  const normalized = normalizeFeatureAttributeKey(key);
  return (
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
