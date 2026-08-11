const fs = require('node:fs');
const path = require('node:path');
const SwaggerParser = require('@apidevtools/swagger-parser');
const ts = require('typescript');

const apiRoot = path.resolve(__dirname, '..');
const openApiPath = path.join(apiRoot, 'docs', 'openapi.yaml');
const expectedPrefix =
  String(process.env.API_VERSION_PREFIX || '/api/v1').replace(/\/+$/, '') || '/api/v1';

const routeFiles = [
  {
    file: 'src/routes/auth.routes.ts',
    mounts: { router: `${expectedPrefix}/auth` },
  },
  {
    file: 'src/routes/project.routes.ts',
    mounts: { router: `${expectedPrefix}/projects` },
  },
  {
    file: 'src/routes/feature.routes.ts',
    mounts: { router: `${expectedPrefix}/features` },
  },
  {
    file: 'src/routes/import.routes.ts',
    mounts: { router: `${expectedPrefix}/imports` },
  },
  {
    file: 'src/routes/export.routes.ts',
    mounts: { router: `${expectedPrefix}/exports` },
  },
  {
    file: 'src/routes/ai.routes.ts',
    mounts: { router: `${expectedPrefix}/ai` },
  },
  {
    file: 'src/routes/me.routes.ts',
    mounts: { router: `${expectedPrefix}/me` },
  },
  {
    file: 'src/routes/privateMedia.routes.ts',
    mounts: { router: '/uploads' },
  },
  {
    file: 'src/routes/index.ts',
    mounts: {
      assignmentRouter: `${expectedPrefix}/assignments`,
      photoRouter: `${expectedPrefix}/photos`,
      categoryRouter: `${expectedPrefix}/categories`,
      notificationRouter: `${expectedPrefix}/notifications`,
      settingsRouter: `${expectedPrefix}/settings`,
      offlineMapRouter: `${expectedPrefix}/offline-map`,
      userRouter: `${expectedPrefix}/users`,
    },
  },
];

const httpMethods = new Set(['get', 'post', 'put', 'patch', 'delete']);
const normalizeExpressPath = (routePath) => routePath.replace(/:([A-Za-z][A-Za-z0-9_]*)/g, '{$1}');

const joinRoutePath = (mount, routePath) =>
  normalizeExpressPath(routePath === '/' ? mount : `${mount}${routePath}`);

const collectRouteOperations = () => {
  const operations = new Set([
    'GET /health',
    'GET /ready',
    'GET /metrics',
    `GET ${expectedPrefix}`,
  ]);

  for (const routeFile of routeFiles) {
    const absolutePath = path.join(apiRoot, routeFile.file);
    const sourceText = fs.readFileSync(absolutePath, 'utf8');
    const source = ts.createSourceFile(
      absolutePath,
      sourceText,
      ts.ScriptTarget.Latest,
      true,
      ts.ScriptKind.TS,
    );

    const visit = (node) => {
      if (
        ts.isCallExpression(node) &&
        ts.isPropertyAccessExpression(node.expression) &&
        httpMethods.has(node.expression.name.text)
      ) {
        const routerName = node.expression.expression.getText(source);
        const mount = routeFile.mounts[routerName];
        const firstArgument = node.arguments[0];
        if (mount && firstArgument && ts.isStringLiteralLike(firstArgument)) {
          operations.add(
            `${node.expression.name.text.toUpperCase()} ${joinRoutePath(mount, firstArgument.text)}`,
          );
        }
      }
      ts.forEachChild(node, visit);
    };
    visit(source);
  }
  return operations;
};

const collectDocumentedOperations = (document) => {
  const operations = new Set();
  for (const [routePath, pathItem] of Object.entries(document.paths || {})) {
    for (const method of httpMethods) {
      if (pathItem && typeof pathItem === 'object' && pathItem[method]) {
        operations.add(`${method.toUpperCase()} ${routePath}`);
      }
    }
  }
  return operations;
};

const difference = (left, right) => [...left].filter((value) => !right.has(value)).sort();

const main = async () => {
  if (!fs.existsSync(openApiPath)) {
    throw new Error(`OpenAPI file not found: ${openApiPath}`);
  }

  const document = await SwaggerParser.validate(openApiPath);
  if (!document.servers?.some((server) => server.url === '/')) {
    throw new Error('OpenAPI must include the same-origin root server URL (/).');
  }
  if (document.components?.securitySchemes?.bearerAuth?.scheme !== 'bearer') {
    throw new Error('OpenAPI bearerAuth security scheme is missing or invalid.');
  }

  const actualOperations = collectRouteOperations();
  const documentedOperations = collectDocumentedOperations(document);
  const missing = difference(actualOperations, documentedOperations);
  const stale = difference(documentedOperations, actualOperations);
  if (missing.length > 0 || stale.length > 0) {
    const details = [];
    if (missing.length > 0) {
      details.push(`Missing OpenAPI operations:\n- ${missing.join('\n- ')}`);
    }
    if (stale.length > 0) {
      details.push(`Documented operations without an Express route:\n- ${stale.join('\n- ')}`);
    }
    throw new Error(details.join('\n'));
  }

  const incomplete = [];
  for (const operationKey of documentedOperations) {
    const separator = operationKey.indexOf(' ');
    const method = operationKey.slice(0, separator).toLowerCase();
    const routePath = operationKey.slice(separator + 1);
    const operation = document.paths[routePath][method];
    if (!Array.isArray(operation.tags) || operation.tags.length === 0) {
      incomplete.push(`${operationKey} has no tag`);
    }
    if (!operation.responses || Object.keys(operation.responses).length === 0) {
      incomplete.push(`${operationKey} has no responses`);
    }
  }
  if (incomplete.length > 0) {
    throw new Error(`Incomplete OpenAPI operations:\n- ${incomplete.join('\n- ')}`);
  }

  const publicOperations = new Set([
    'GET /health',
    'GET /ready',
    `GET ${expectedPrefix}`,
    `POST ${expectedPrefix}/auth/register`,
    `POST ${expectedPrefix}/auth/login`,
    `POST ${expectedPrefix}/auth/reactivate-login`,
    `POST ${expectedPrefix}/auth/forgot-password`,
    `POST ${expectedPrefix}/auth/verify-reset-otp`,
    `POST ${expectedPrefix}/auth/reset-password`,
    `POST ${expectedPrefix}/auth/refresh-token`,
  ]);
  const securityFailures = [];
  for (const operationKey of documentedOperations) {
    const separator = operationKey.indexOf(' ');
    const method = operationKey.slice(0, separator).toLowerCase();
    const routePath = operationKey.slice(separator + 1);
    const security = document.paths[routePath][method].security;
    if (publicOperations.has(operationKey)) {
      continue;
    }
    const expectedScheme =
      operationKey === 'GET /metrics'
        ? 'metricsToken'
        : operationKey === `POST ${expectedPrefix}/ai/runs/{runId}/callback`
          ? 'aiCallbackSecret'
          : 'bearerAuth';
    if (
      !Array.isArray(security) ||
      !security.some(
        (requirement) =>
          requirement && typeof requirement === 'object' && expectedScheme in requirement,
      )
    ) {
      securityFailures.push(`${operationKey} must declare ${expectedScheme}`);
    }
  }
  if (securityFailures.length > 0) {
    throw new Error(`OpenAPI authentication gaps:\n- ${securityFailures.join('\n- ')}`);
  }

  console.log(
    `OpenAPI contract check passed (${documentedOperations.size} Express operations, prefix=${expectedPrefix})`,
  );
};

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exit(1);
});
