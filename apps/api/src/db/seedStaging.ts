import 'dotenv/config';
import bcrypt from 'bcryptjs';
import type { PoolClient } from 'pg';
import { pool } from '../config/database';
import { validateEnv } from '../config/env';
import { ensureSuperAdminExists } from '../lib/userWorkflow';
const logger = require('../utils/logger');

interface SeedConfig {
  reset: boolean;
  admins: number;
  contributors: number;
  viewers: number;
  projects: number;
  contributorsPerProject: number;
  featuresPerProject: number;
  photoRatio: number;
  exportsPerProject: number;
  defaultPassword: string;
}

interface SeedUser {
  id: string;
  role: 'admin' | 'contributor' | 'viewer';
}

interface SeedProject {
  id: string;
  createdByUserId: string;
  targetStatus: 'draft' | 'active' | 'paused';
}

const parseIntEnv = (name: string, fallback: number, min = 0): number => {
  const raw = process.env[name];
  if (!raw) {
    return fallback;
  }
  const parsed = Number.parseInt(raw, 10);
  if (!Number.isFinite(parsed) || parsed < min) {
    return fallback;
  }
  return parsed;
};

const parseFloatEnv = (name: string, fallback: number, min: number, max: number): number => {
  const raw = process.env[name];
  if (!raw) {
    return fallback;
  }
  const parsed = Number.parseFloat(raw);
  if (!Number.isFinite(parsed) || parsed < min || parsed > max) {
    return fallback;
  }
  return parsed;
};

const parseBooleanEnv = (name: string, fallback: boolean): boolean => {
  const raw = process.env[name];
  if (!raw) {
    return fallback;
  }
  const normalized = raw.trim().toLowerCase();
  if (['1', 'true', 'yes', 'y'].includes(normalized)) {
    return true;
  }
  if (['0', 'false', 'no', 'n'].includes(normalized)) {
    return false;
  }
  return fallback;
};

const buildConfig = (): SeedConfig => ({
  reset: parseBooleanEnv('STAGING_SEED_RESET', true),
  admins: parseIntEnv('STAGING_SEED_ADMINS', 6, 1),
  contributors: parseIntEnv('STAGING_SEED_CONTRIBUTORS', 55, 1),
  viewers: parseIntEnv('STAGING_SEED_VIEWERS', 15, 0),
  projects: parseIntEnv('STAGING_SEED_PROJECTS', 18, 1),
  contributorsPerProject: parseIntEnv('STAGING_SEED_CONTRIBUTORS_PER_PROJECT', 8, 1),
  featuresPerProject: parseIntEnv('STAGING_SEED_FEATURES_PER_PROJECT', 350, 1),
  photoRatio: parseFloatEnv('STAGING_SEED_PHOTO_RATIO', 0.35, 0, 1),
  exportsPerProject: parseIntEnv('STAGING_SEED_EXPORTS_PER_PROJECT', 2, 1),
  defaultPassword: process.env.STAGING_SEED_DEFAULT_PASSWORD ?? 'Phase11@Seed123',
});

const assertResetIsSafe = (config: SeedConfig): void => {
  if (!config.reset) {
    return;
  }

  const nodeEnv = String(process.env.NODE_ENV ?? 'development').trim().toLowerCase();
  const allowDestructiveReset =
    String(process.env.ALLOW_DESTRUCTIVE_STAGING_RESET ?? '')
      .trim()
      .toLowerCase() === 'true';

  if (nodeEnv === 'test' || allowDestructiveReset) {
    return;
  }

  throw new Error(
    'Refusing to run STAGING_SEED_RESET=true outside an isolated test environment. ' +
      'Use a dedicated staging database or set ALLOW_DESTRUCTIVE_STAGING_RESET=true intentionally.'
  );
};

const randomInt = (maxExclusive: number): number => Math.floor(Math.random() * maxExclusive);

const pickRandom = <T>(items: T[]): T => items[randomInt(items.length)];

const sampleUnique = <T>(items: T[], count: number): T[] => {
  if (count >= items.length) {
    return [...items];
  }
  const poolItems = [...items];
  for (let i = poolItems.length - 1; i > 0; i -= 1) {
    const j = randomInt(i + 1);
    [poolItems[i], poolItems[j]] = [poolItems[j], poolItems[i]];
  }
  return poolItems.slice(0, count);
};

const resetDatabase = async (client: PoolClient): Promise<void> => {
  await client.query(`
    TRUNCATE TABLE
      notification_push_delivery,
      notification_delivery,
      notification,
      audit_log,
      photo,
      spatial_feature,
      shapefile_export,
      password_reset_request,
      app_support_settings,
      push_device_registration,
      project_assignment,
      project,
      project_category,
      "user",
      lebanon_offline_map
    RESTART IDENTITY CASCADE
  `);
};

const createUsers = async (
  client: PoolClient,
  config: SeedConfig,
  seedTag: string
): Promise<SeedUser[]> => {
  const users: SeedUser[] = [];
  const passwordHash = await bcrypt.hash(config.defaultPassword, 10);
  const rolePlans: Array<{ role: SeedUser['role']; count: number; title: string }> = [
    { role: 'admin', count: config.admins, title: 'Admin' },
    { role: 'contributor', count: config.contributors, title: 'Contributor' },
    { role: 'viewer', count: config.viewers, title: 'Viewer' },
  ];

  for (const rolePlan of rolePlans) {
    for (let i = 0; i < rolePlan.count; i += 1) {
      const seq = i + 1;
      const email = `${rolePlan.role}.${seq}.${seedTag}@gis.gov.lb`;
      const fullName = `Phase11 ${rolePlan.title} ${seq}`;
      const phone = `+96170${String(100000 + randomInt(899999))}`;

      const result = await client.query<{ id: string; role: SeedUser['role'] }>(
        `INSERT INTO "user" (
           email,
           password_hash,
           full_name,
           phone,
           role,
           is_active,
           created_at,
           last_login
         )
         VALUES ($1, $2, $3, $4, $5::user_role, TRUE, NOW() - ($6 || ' days')::interval, NOW() - ($7 || ' days')::interval)
         RETURNING id, role`,
        [email, passwordHash, fullName, phone, rolePlan.role, randomInt(200), randomInt(30)]
      );

      users.push(result.rows[0]);
    }
  }

  return users;
};

const createCategories = async (client: PoolClient, seedTag: string): Promise<string[]> => {
  const categoryNames = [
    'Fruit Trees - Bekaa',
    'Fruit Trees - Mount Lebanon',
    'Fruit Trees - North',
    'Fruit Trees - South',
    'Fruit Trees - Nabatieh',
    'Urban Green Trees',
  ];

  const categoryIds: string[] = [];
  for (const baseName of categoryNames) {
    const name = `${baseName} (${seedTag})`;
    const result = await client.query<{ id: string }>(
      `INSERT INTO project_category (name, description)
       VALUES ($1, $2)
       ON CONFLICT (name) DO UPDATE
       SET description = EXCLUDED.description
       RETURNING id`,
      [name, `Staging category seeded in phase 11 (${baseName})`]
    );
    categoryIds.push(result.rows[0].id);
  }

  return categoryIds;
};

const createProjects = async (
  client: PoolClient,
  config: SeedConfig,
  admins: SeedUser[],
  categoryIds: string[]
): Promise<SeedProject[]> => {
  const statuses: Array<'active' | 'paused' | 'draft'> = [
    'active',
    'active',
    'active',
    'active',
    'paused',
    'draft',
  ];
  const projects: SeedProject[] = [];

  for (let i = 0; i < config.projects; i += 1) {
    const createdBy = pickRandom(admins);
    const categoryId = categoryIds[i % categoryIds.length];
    const status = statuses[i % statuses.length];
    const formSchema = {
      schemaVersion: '0.1.0',
      fields: [
        { key: 'tree_type', type: 'select', required: true },
        { key: 'condition', type: 'select', required: true },
        { key: 'dbh_cm', type: 'number', required: false },
        { key: 'height_m', type: 'number', required: false },
      ],
    };

    const result = await client.query<{ id: string }>(
      `INSERT INTO project (
         category_id,
         created_by_user_id,
         name,
         description,
         objectives,
         status,
         start_date,
         end_date,
         collection_form_schema,
         requires_photos,
         min_photos,
         max_photos
       )
       VALUES (
         $1,
         $2,
         $3,
         $4,
         $5,
         'draft',
         CURRENT_DATE - ($6 * INTERVAL '1 day'),
         CURRENT_DATE + ($7 * INTERVAL '1 day'),
         $8::jsonb,
         TRUE,
         1,
         5
       )
       RETURNING id`,
      [
        categoryId,
        createdBy.id,
        `Phase11 Project ${i + 1}`,
        'Staging project with realistic field collection records',
        'Pilot readiness and deployment validation',
        30 + randomInt(90),
        30 + randomInt(180),
        JSON.stringify(formSchema),
      ]
    );

    projects.push({
      id: result.rows[0].id,
      createdByUserId: createdBy.id,
      targetStatus: status,
    });
  }

  return projects;
};

const promoteProjectsToTargetStatus = async (
  client: PoolClient,
  projects: SeedProject[]
): Promise<void> => {
  const transitionPaths: Record<SeedProject['targetStatus'], Array<'active' | 'paused'>> = {
    draft: [],
    active: ['active'],
    paused: ['active', 'paused'],
  };

  for (const project of projects) {
    const path = transitionPaths[project.targetStatus];
    for (const nextStatus of path) {
      await client.query(
        `UPDATE project
         SET status = $1::project_status
         WHERE id = $2`,
        [nextStatus, project.id]
      );
    }
  }
};

const seedAssignments = async (
  client: PoolClient,
  config: SeedConfig,
  projects: SeedProject[],
  contributors: SeedUser[]
): Promise<Map<string, string[]>> => {
  const projectContributorMap = new Map<string, string[]>();

  for (const project of projects) {
    await client.query(
      `INSERT INTO project_assignment (
         project_id,
         user_id,
         role,
         status,
         assigned_date,
         approved_date,
         approved_by_user_id
       )
       VALUES ($1, $2, 'admin', 'approved', CURRENT_DATE, CURRENT_DATE, $2)
       ON CONFLICT (project_id, user_id) DO NOTHING`,
      [project.id, project.createdByUserId]
    );

    const selectedContributors = sampleUnique(contributors, config.contributorsPerProject);
    projectContributorMap.set(
      project.id,
      selectedContributors.map((contributor) => contributor.id)
    );

    for (const contributor of selectedContributors) {
      await client.query(
        `INSERT INTO project_assignment (
           project_id,
           user_id,
           role,
           status,
           assigned_date,
           approved_date,
           approved_by_user_id
         )
         VALUES ($1, $2, 'contributor', 'approved', CURRENT_DATE - ($3 * INTERVAL '1 day'), CURRENT_DATE - ($4 * INTERVAL '1 day'), $5)
         ON CONFLICT (project_id, user_id) DO NOTHING`,
        [project.id, contributor.id, randomInt(45), randomInt(20), project.createdByUserId]
      );
    }
  }

  return projectContributorMap;
};

const seedFeatures = async (
  client: PoolClient,
  config: SeedConfig,
  projects: SeedProject[],
  projectContributors: Map<string, string[]>
): Promise<void> => {
  for (const project of projects) {
    const contributorIds = projectContributors.get(project.id);
    if (!contributorIds || contributorIds.length === 0) {
      continue;
    }

    await client.query(
      `WITH src AS (
         SELECT random() AS r, gs
         FROM generate_series(1, $2) AS gs
       )
       INSERT INTO spatial_feature (
         project_id,
         collected_by_user_id,
         geom,
         attributes,
         status,
         collected_at,
         submitted_at,
         reviewed_at,
         reviewed_by_user_id,
         review_notes,
         accuracy_meters,
         collected_offline,
         synced_at,
         version
       )
       SELECT
         $1::uuid,
         ($3::uuid[])[(1 + floor(random() * array_length($3::uuid[], 1)))::int],
         ST_SetSRID(ST_MakePoint(35 + random() * 1.7, 33 + random() * 1.7), 4326),
         jsonb_build_object(
           'tree_type', (ARRAY['olive','apple','citrus','cherry','apricot'])[1 + floor(random() * 5)::int],
           'condition', (ARRAY['excellent','good','fair','poor'])[1 + floor(random() * 4)::int],
           'dbh_cm', round((15 + random() * 45)::numeric, 1),
           'height_m', round((2 + random() * 8)::numeric, 1),
           'source', 'phase11-staging-seed'
         ),
         'draft'::feature_status,
         NOW() - (random() * interval '180 days'),
         NULL,
         NULL,
         NULL,
         NULL,
         round((3 + random() * 15)::numeric, 2),
         (random() < 0.45),
         NOW() - (random() * interval '45 days'),
         1 + floor(random() * 3)::int
      FROM src`,
      [project.id, config.featuresPerProject, contributorIds]
    );
  }
};

const promoteSeededFeatures = async (
  client: PoolClient,
  projects: SeedProject[]
): Promise<void> => {
  for (const project of projects) {
    await client.query(
      `WITH eligible AS (
         SELECT
           sf.id,
           random() AS r
         FROM spatial_feature sf
         JOIN project p ON p.id = sf.project_id
         WHERE sf.project_id = $1::uuid
           AND (
             NOT p.requires_photos
             OR (
               SELECT COUNT(*)
               FROM photo ph
               WHERE ph.feature_id = sf.id
             ) >= COALESCE(p.min_photos, 0)
           )
       )
       UPDATE spatial_feature sf
       SET
         status = CASE
           WHEN eligible.r < 0.72 THEN 'approved'::feature_status
           WHEN eligible.r < 0.9 THEN 'pending_review'::feature_status
           ELSE 'draft'::feature_status
         END,
         submitted_at = CASE
           WHEN eligible.r < 0.9 THEN NOW() - (random() * interval '120 days')
           ELSE NULL
         END,
         reviewed_at = CASE
           WHEN eligible.r < 0.72 THEN NOW() - (random() * interval '90 days')
           ELSE NULL
         END,
         reviewed_by_user_id = CASE
           WHEN eligible.r < 0.72 THEN $2::uuid
           ELSE NULL
         END,
         review_notes = CASE
           WHEN eligible.r < 0.72 THEN 'Approved during phase 11 staging seed'
           WHEN eligible.r < 0.9 THEN 'Queued for admin review'
           ELSE NULL
         END
       FROM eligible
       WHERE sf.id = eligible.id`,
      [project.id, project.createdByUserId]
    );
  }
};

const seedPhotos = async (
  client: PoolClient,
  config: SeedConfig,
  projects: SeedProject[]
): Promise<void> => {
  for (const project of projects) {
    await client.query(
      `INSERT INTO photo (
         feature_id,
         file_path,
         thumbnail_path,
         location,
         accuracy_meters,
         taken_at,
         exif_data,
         file_size_bytes,
         status,
         display_order,
         uploaded_at
       )
       SELECT
         sf.id,
         format('/staging/photos/%s/%s.jpg', $1::text, sf.id::text),
         format('/staging/photos/%s/%s_thumb.jpg', $1::text, sf.id::text),
         sf.geom::geometry(Point, 4326),
         round((1 + random() * 10)::numeric, 2),
         sf.collected_at + (random() * interval '30 minutes'),
         jsonb_build_object('device_model', 'staging-device', 'orientation', 'portrait'),
         (400000 + floor(random() * 1600000))::bigint,
         CASE WHEN random() < 0.88 THEN 'approved'::photo_status ELSE 'pending'::photo_status END,
         0,
         NOW() - (random() * interval '30 days')
       FROM spatial_feature sf
       WHERE sf.project_id = $1::uuid
         AND random() < $2`,
      [project.id, config.photoRatio]
    );
  }
};

const seedExports = async (
  client: PoolClient,
  config: SeedConfig,
  projects: SeedProject[],
  projectContributors: Map<string, string[]>
): Promise<void> => {
  for (const project of projects) {
    const contributors = projectContributors.get(project.id);
    if (!contributors || contributors.length === 0) {
      continue;
    }

    for (let i = 0; i < config.exportsPerProject; i += 1) {
      const requesterId = pickRandom(contributors);
      const completed = i === 0;
      const status = completed ? 'completed' : i % 2 === 0 ? 'processing' : 'pending';
      const completedAt = completed ? `NOW() - (${randomInt(12)} * INTERVAL '1 day')` : 'NULL';
      const filePath = completed
        ? `/staging/exports/${project.id}_${i + 1}.zip`
        : null;
      const fileSize = completed ? 1000000 + randomInt(45000000) : null;

      await client.query(
        `INSERT INTO shapefile_export (
           project_id,
           requested_by_user_id,
           requested_at,
           completed_at,
           file_path,
           feature_count,
           export_parameters,
           status,
           file_size_bytes,
           error_message
         )
         VALUES (
           $1,
           $2,
           NOW() - ($3 * INTERVAL '1 day'),
           ${completedAt},
           $4,
           $5,
           $6::jsonb,
           $7::export_status,
           $8,
           $9
         )`,
        [
          project.id,
          requesterId,
          randomInt(15),
          filePath,
          completed ? 200 + randomInt(1500) : null,
          JSON.stringify({
            format: 'geojson',
            status_filter: ['approved'],
            seeded_in_phase: 11,
          }),
          status,
          fileSize,
          null,
        ]
      );
    }
  }
};

const seedNotifications = async (client: PoolClient): Promise<void> => {
  await client.query(
    `INSERT INTO notification (
       user_id,
       type,
       title,
       message,
       metadata,
       is_read,
       created_at,
       read_at
     )
     SELECT
       u.id,
       CASE
         WHEN random() < 0.4 THEN 'assignment'::notification_type
         WHEN random() < 0.8 THEN 'review_completed'::notification_type
         ELSE 'export_ready'::notification_type
       END,
       'Phase 11 Staging Notification',
       'Synthetic notification seeded for rollout readiness.',
       jsonb_build_object('user_id', u.id, 'seed_phase', 11, 'source', 'seed:staging'),
       random() < 0.45,
       NOW() - (random() * interval '25 days'),
       CASE WHEN random() < 0.45 THEN NOW() - (random() * interval '20 days') ELSE NULL END
     FROM "user" u
     WHERE random() < 0.8`
  );
};

const seedAuditLogs = async (client: PoolClient): Promise<void> => {
  await client.query(
    `INSERT INTO audit_log (
       user_id,
       action_type,
       entity_type,
       entity_id,
       old_values,
       new_values,
       ip_address,
       created_at
     )
     SELECT
       sf.collected_by_user_id,
       CASE
         WHEN random() < 0.5 THEN 'create'::audit_action_type
         WHEN random() < 0.8 THEN 'update'::audit_action_type
         ELSE 'approve'::audit_action_type
       END,
       'spatial_feature',
       sf.id,
       NULL,
       jsonb_build_object('seed_phase', 11, 'status', sf.status),
       '10.20.30.40'::inet,
       NOW() - (random() * interval '30 days')
     FROM spatial_feature sf
     WHERE random() < 0.08
     LIMIT 5000`
  );
};

const seedOfflineMapVersion = async (client: PoolClient): Promise<void> => {
  const version = `phase11-staging-${new Date().toISOString().slice(0, 10)}`;
  await client.query('UPDATE lebanon_offline_map SET is_current = FALSE');
  await client.query(
    `INSERT INTO lebanon_offline_map (
       version,
       zoom_level_min,
       zoom_level_max,
       downloaded_at,
       last_updated_at,
       tile_count,
       size_bytes,
       tile_source,
       is_current
     )
     VALUES ($1, 8, 18, NOW() - INTERVAL '21 days', NOW(), 92000, 2800000000, 'osm', TRUE)
     ON CONFLICT (version)
     DO UPDATE SET
       zoom_level_min = EXCLUDED.zoom_level_min,
       zoom_level_max = EXCLUDED.zoom_level_max,
       last_updated_at = EXCLUDED.last_updated_at,
       tile_count = EXCLUDED.tile_count,
       size_bytes = EXCLUDED.size_bytes,
       tile_source = EXCLUDED.tile_source,
       is_current = TRUE`,
    [version]
  );
};

const seedSupportSettings = async (client: PoolClient): Promise<void> => {
  await client.query(
    `INSERT INTO app_support_settings (
       id,
       support_email,
       support_phone,
       office_hours,
       help_text,
       updated_at
     )
     VALUES (
       1,
       'support@gis.gov.lb',
       '+961 1 555 555',
       'Monday to Friday, 08:30-16:30',
       'For help with login, assignments, exports, or field collection workflows, contact the GIS support desk.',
       NOW()
     )
     ON CONFLICT (id) DO UPDATE
       SET support_email = EXCLUDED.support_email,
           support_phone = EXCLUDED.support_phone,
           office_hours = EXCLUDED.office_hours,
           help_text = EXCLUDED.help_text,
           updated_at = NOW()`
  );
};

const getSummaryCounts = async (
  client: PoolClient
): Promise<Record<string, number>> => {
  const statements = [
    ['users', 'SELECT COUNT(*)::int AS value FROM "user"'],
    ['projects', 'SELECT COUNT(*)::int AS value FROM project'],
    ['assignments', 'SELECT COUNT(*)::int AS value FROM project_assignment'],
    ['features', 'SELECT COUNT(*)::int AS value FROM spatial_feature'],
    ['photos', 'SELECT COUNT(*)::int AS value FROM photo'],
    ['exports', 'SELECT COUNT(*)::int AS value FROM shapefile_export'],
    ['notifications', 'SELECT COUNT(*)::int AS value FROM notification'],
    ['audit_logs', 'SELECT COUNT(*)::int AS value FROM audit_log'],
  ] as const;

  const summary: Record<string, number> = {};
  for (const [label, statement] of statements) {
    const result = await client.query<{ value: number }>(statement);
    summary[label] = result.rows[0]?.value ?? 0;
  }
  return summary;
};

const run = async (): Promise<void> => {
  const config = buildConfig();
  assertResetIsSafe(config);
  const seedTag = new Date().toISOString().replace(/[-:.TZ]/g, '').slice(0, 14);
  const client = await pool.connect();
  const start = Date.now();

  logger.info('Phase 11 staging seed started', {
    reset: config.reset,
    projects: config.projects,
    featuresPerProject: config.featuresPerProject,
    contributorsPerProject: config.contributorsPerProject,
  });

  try {
    await client.query('BEGIN');

    if (config.reset) {
      await resetDatabase(client);
    }

    const users = await createUsers(client, config, seedTag);
    const admins = users.filter((user) => user.role === 'admin');
    const contributors = users.filter((user) => user.role === 'contributor');

    const categoryIds = await createCategories(client, seedTag);
    const projects = await createProjects(client, config, admins, categoryIds);
    await promoteProjectsToTargetStatus(client, projects);
    const projectContributors = await seedAssignments(client, config, projects, contributors);
    await seedFeatures(client, config, projects, projectContributors);
    await seedPhotos(client, config, projects);
    await promoteSeededFeatures(client, projects);
    await seedExports(client, config, projects, projectContributors);
    await seedNotifications(client);
    await seedAuditLogs(client);
    await seedOfflineMapVersion(client);
    await seedSupportSettings(client);

    await client.query('COMMIT');

    const env = validateEnv();
    await ensureSuperAdminExists(env);

    const summary = await getSummaryCounts(client);
    const elapsedMs = Date.now() - start;
    logger.info('Phase 11 staging seed completed', {
      elapsedMs,
      summary,
      credentialsHint: {
        password: config.defaultPassword,
        adminPattern: `admin.1.${seedTag}@gis.gov.lb`,
      },
    });
  } catch (error: unknown) {
    await client.query('ROLLBACK');
    logger.error('Phase 11 staging seed failed:', error);
    process.exitCode = 1;
  } finally {
    client.release();
    await pool.end().catch(() => {});
  }
};

void run();
