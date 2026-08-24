# TerraLeb AI model and dataset provenance register

The separate AI implementation is not fully contained in this repository.
Production AI remains blocked until deployed artifacts are registered.

## Per-model required record

- Stable model identifier, display name and version/digest
- Provider/owner and accountable operator
- Training code/repository commit and environment
- Training, validation and test dataset identifiers/licenses
- Intended use, users, geography and prohibited uses
- Input/output schema and personal/sensitive data assessment
- Evaluation metrics, thresholds, known limitations and subgroup/geographic tests
- Human review requirements and publication authority
- Security/supply-chain scan evidence
- Deployment date, supersession/retraction state and incident contact

## Per-dataset required record

- Dataset/source/product identifier and immutable version
- Provider, acquisition dates, geographic coverage and resolution
- License, attribution, offline/cache/derived-work and training permissions
- Collection purpose and lawful-basis decision where personal data is involved
- Quality, bias, completeness and sensitive-location assessment
- Retention and deletion/withdrawal propagation rule

## Current verified safeguards

- AI runs and outputs have explicit lifecycle/review/publication states.
- Prediction validation and admin review records exist.
- A `use_for_future_training` field exists, but that technical flag does not
  establish consent or another lawful basis.
- Project training use and viewer-facing publication now have separate,
  protected-super-admin authority records with a basis and approval reference.
  AI execution and publication fail closed when the applicable record is absent.
- The mobile AI settings screen displays both states and makes clear that
  ordinary AI enablement is not authority for private data reuse.

## Blocking gaps

The final model artifacts, exact datasets, licenses, external processing region,
training authority, evaluation approval and accountable human owner are not
established in this repository.
