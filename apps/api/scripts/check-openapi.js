const fs = require('node:fs');
const path = require('node:path');

const openApiPath = path.resolve(__dirname, '..', 'docs', 'openapi.yaml');
const expectedPrefix = String(process.env.API_VERSION_PREFIX || '/api/v1').replace(/\/+$/, '') || '/api/v1';
const expectedServerUrl = `http://localhost:3000${expectedPrefix}`;

const requiredPaths = [
  '/health',
  '/ready',
  `${expectedPrefix}`,
  `${expectedPrefix}/auth/register`,
  `${expectedPrefix}/auth/login`,
  `${expectedPrefix}/auth/me`,
  `${expectedPrefix}/projects`,
  `${expectedPrefix}/projects/{projectId}`,
  `${expectedPrefix}/categories`,
  `${expectedPrefix}/assignments`,
  `${expectedPrefix}/features`,
  `${expectedPrefix}/features/bbox`,
  `${expectedPrefix}/photos/feature/{featureId}`,
  `${expectedPrefix}/notifications`,
  `${expectedPrefix}/exports`,
  `${expectedPrefix}/users`,
];

if (!fs.existsSync(openApiPath)) {
  console.error(`OpenAPI file not found: ${openApiPath}`);
  process.exit(1);
}

const raw = fs.readFileSync(openApiPath, 'utf8');

const pathMatches = [...raw.matchAll(/^\s{2}(\/[^\s:]+):\s*$/gm)].map((match) => match[1]);
const serverMatches = [...raw.matchAll(/^\s*-\s*url:\s*(\S+)\s*$/gm)].map((match) => match[1]);

const missingPaths = requiredPaths.filter((requiredPath) => !pathMatches.includes(requiredPath));
const hasExpectedServer = serverMatches.includes(expectedServerUrl);

if (missingPaths.length > 0 || !hasExpectedServer) {
  if (!hasExpectedServer) {
    console.error(`Missing expected server URL in openapi.yaml: ${expectedServerUrl}`);
    console.error(`Found servers: ${serverMatches.join(', ') || '(none)'}`);
  }

  if (missingPaths.length > 0) {
    console.error('Missing required OpenAPI paths:');
    for (const missingPath of missingPaths) {
      console.error(`- ${missingPath}`);
    }
  }

  process.exit(1);
}

console.log(`OpenAPI contract check passed (${requiredPaths.length} required paths, prefix=${expectedPrefix})`);
