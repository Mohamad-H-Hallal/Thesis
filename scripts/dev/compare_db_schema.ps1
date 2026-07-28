param(
  [Parameter(Mandatory = $true)][string]$ReferenceDatabase,
  [Parameter(Mandatory = $true)][string]$CandidateDatabase,
  [string]$ContainerName = 'gis_app-db-1',
  [string]$User = $(if ($env:POSTGRES_USER) { $env:POSTGRES_USER } else { 'gis_user' }),
  [switch]$PassThru
)

$ErrorActionPreference = 'Stop'

$running = docker inspect -f '{{.State.Running}}' $ContainerName 2>$null
if ($LASTEXITCODE -ne 0 -or $running -ne 'true') {
  throw "Database container '$ContainerName' is not running."
}
if ($ReferenceDatabase -eq $CandidateDatabase) {
  throw 'Reference and candidate databases must be different.'
}

$schemaSql = @'
WITH schema_objects AS (
  SELECT
    'column'::text AS object_kind,
    format('%I.%I.%I', namespace.nspname, relation.relname, attribute.attname) AS identity,
    concat_ws(
      '|',
      format_type(attribute.atttypid, attribute.atttypmod),
      attribute.attnotnull::text,
      COALESCE(pg_get_expr(default_value.adbin, default_value.adrelid), ''),
      attribute.attidentity::text,
      attribute.attgenerated::text
    ) AS definition
  FROM pg_attribute AS attribute
  JOIN pg_class AS relation ON relation.oid = attribute.attrelid
  JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
  LEFT JOIN pg_attrdef AS default_value
    ON default_value.adrelid = attribute.attrelid
   AND default_value.adnum = attribute.attnum
  WHERE namespace.nspname = 'public'
    AND relation.relkind IN ('r', 'p', 'v', 'm', 'f')
    AND attribute.attnum > 0
    AND NOT attribute.attisdropped

  UNION ALL

  SELECT
    'constraint',
    format('%I.%I.%I', namespace.nspname, relation.relname, constraint_value.conname),
    pg_get_constraintdef(constraint_value.oid, true)
  FROM pg_constraint AS constraint_value
  JOIN pg_class AS relation ON relation.oid = constraint_value.conrelid
  JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
  WHERE namespace.nspname = 'public'

  UNION ALL

  SELECT
    'index',
    format('%I.%I', schemaname, indexname),
    indexdef
  FROM pg_indexes
  WHERE schemaname = 'public'

  UNION ALL

  SELECT
    'function',
    format(
      '%I.%I(%s)',
      namespace.nspname,
      procedure_value.proname,
      pg_get_function_identity_arguments(procedure_value.oid)
    ),
    replace(pg_get_functiondef(procedure_value.oid), E'\r', '')
  FROM pg_proc AS procedure_value
  JOIN pg_namespace AS namespace ON namespace.oid = procedure_value.pronamespace
  WHERE namespace.nspname = 'public'
    AND procedure_value.prokind IN ('f', 'p')

  UNION ALL

  SELECT
    'trigger',
    format('%I.%I.%I', namespace.nspname, relation.relname, trigger_value.tgname),
    pg_get_triggerdef(trigger_value.oid, true)
  FROM pg_trigger AS trigger_value
  JOIN pg_class AS relation ON relation.oid = trigger_value.tgrelid
  JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
  WHERE namespace.nspname = 'public'
    AND NOT trigger_value.tgisinternal

  UNION ALL

  SELECT
    'enum',
    format('%I.%I', namespace.nspname, type_value.typname),
    string_agg(enum_value.enumlabel, '|' ORDER BY enum_value.enumsortorder)
  FROM pg_type AS type_value
  JOIN pg_namespace AS namespace ON namespace.oid = type_value.typnamespace
  JOIN pg_enum AS enum_value ON enum_value.enumtypid = type_value.oid
  WHERE namespace.nspname = 'public'
  GROUP BY namespace.nspname, type_value.typname

  UNION ALL

  SELECT
    'view',
    format('%I.%I', namespace.nspname, relation.relname),
    pg_get_viewdef(relation.oid, true)
  FROM pg_class AS relation
  JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
  WHERE namespace.nspname = 'public'
    AND relation.relkind IN ('v', 'm')

  UNION ALL

  SELECT
    'sequence',
    format('%I.%I', namespace.nspname, relation.relname),
    concat_ws(
      '|',
      sequence_value.seqtypid::regtype::text,
      sequence_value.seqstart::text,
      sequence_value.seqincrement::text,
      sequence_value.seqmax::text,
      sequence_value.seqmin::text,
      sequence_value.seqcache::text,
      sequence_value.seqcycle::text
    )
  FROM pg_sequence AS sequence_value
  JOIN pg_class AS relation ON relation.oid = sequence_value.seqrelid
  JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
  WHERE namespace.nspname = 'public'

  UNION ALL

  SELECT
    'policy',
    format('%I.%I.%I', namespace.nspname, relation.relname, policy_value.polname),
    concat_ws(
      '|',
      policy_value.polcmd,
      policy_value.polpermissive::text,
      COALESCE(pg_get_expr(policy_value.polqual, policy_value.polrelid), ''),
      COALESCE(pg_get_expr(policy_value.polwithcheck, policy_value.polrelid), '')
    )
  FROM pg_policy AS policy_value
  JOIN pg_class AS relation ON relation.oid = policy_value.polrelid
  JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
  WHERE namespace.nspname = 'public'
)
SELECT concat_ws(E'\t', object_kind, identity, md5(definition))
FROM schema_objects
ORDER BY object_kind, identity;
'@

function Get-SchemaRows {
  param([Parameter(Mandatory = $true)][string]$Database)

  $rows = @(
    docker exec $ContainerName psql `
      -U $User `
      -d $Database `
      -At `
      -v ON_ERROR_STOP=1 `
      -c $schemaSql
  )
  if ($LASTEXITCODE -ne 0) {
    throw "Could not fingerprint database '$Database'."
  }
  return @($rows | Where-Object { $_ -ne '' })
}

$referenceRows = Get-SchemaRows -Database $ReferenceDatabase
$candidateRows = Get-SchemaRows -Database $CandidateDatabase
$differences = @(
  Compare-Object `
    -ReferenceObject $referenceRows `
    -DifferenceObject $candidateRows
)

if ($differences.Count -gt 0) {
  $preview = $differences | Select-Object -First 30 | Out-String
  throw "Database schemas are not semantically equivalent.`n$preview"
}

$fingerprintInput = [string]::Join("`n", $referenceRows)
$fingerprintBytes = [System.Text.Encoding]::UTF8.GetBytes($fingerprintInput)
$fingerprint = [Convert]::ToHexString(
  [System.Security.Cryptography.SHA256]::HashData($fingerprintBytes)
).ToLowerInvariant()

Write-Host "[OK] Semantic schemas match: $ReferenceDatabase == $CandidateDatabase"
Write-Host "[OK] Compared objects: $($referenceRows.Count)"
Write-Host "[OK] Schema fingerprint: $fingerprint"

if ($PassThru) {
  [pscustomobject]@{
    ReferenceDatabase = $ReferenceDatabase
    CandidateDatabase = $CandidateDatabase
    ComparedObjects = $referenceRows.Count
    Sha256 = $fingerprint
  }
}
