import fs from 'node:fs';
import path from 'node:path';
import { parse } from 'yaml';

type OpenApiDocument = {
  openapi: string;
  servers?: Array<{ url: string; description?: string }>;
  paths?: Record<string, unknown>;
  [key: string]: unknown;
};

const primaryDocumentedPrefix = '/api/v1';
const openApiYamlPath = path.resolve(__dirname, '..', '..', 'docs', 'openapi.yaml');

const normalizeApiPrefix = (value: unknown): string => {
  const trimmed = String(value || primaryDocumentedPrefix).trim() || primaryDocumentedPrefix;
  const prefixed = trimmed.startsWith('/') ? trimmed : `/${trimmed}`;
  return prefixed.replace(/\/+$/, '') || primaryDocumentedPrefix;
};

const loadOpenApiDocument = (apiPrefix: unknown): OpenApiDocument => {
  const source = fs.readFileSync(openApiYamlPath, 'utf8');
  const document = parse(source) as OpenApiDocument;
  if (!document || typeof document !== 'object' || !document.openapi || !document.paths) {
    throw new Error('OpenAPI document is missing required top-level fields.');
  }

  const normalizedPrefix = normalizeApiPrefix(apiPrefix);
  if (normalizedPrefix !== primaryDocumentedPrefix) {
    document.paths = Object.fromEntries(
      Object.entries(document.paths).map(([routePath, operation]) => [
        routePath === primaryDocumentedPrefix
          ? normalizedPrefix
          : routePath.startsWith(`${primaryDocumentedPrefix}/`)
            ? `${normalizedPrefix}${routePath.slice(primaryDocumentedPrefix.length)}`
            : routePath,
        operation,
      ]),
    );
  }

  // The documented paths already contain the API version prefix. A same-origin
  // root server keeps Swagger "Try it out" correct in local, reverse-proxy, and
  // production deployments without duplicating /api/v1.
  document.servers = [
    {
      url: '/',
      description: 'Current TerraLeb API host',
    },
  ];
  return document;
};

export { loadOpenApiDocument, openApiYamlPath };
