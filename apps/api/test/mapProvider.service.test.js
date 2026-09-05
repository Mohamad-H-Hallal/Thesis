jest.mock('../src/config/database', () => ({
  query: jest.fn(),
}));

const database = require('../src/config/database');

describe('ArcGIS online map provider boundary', () => {
  const originalFetch = global.fetch;
  let service;

  beforeAll(() => {
    process.env.ARCGIS_ONLINE_ENABLED = 'true';
    process.env.ARCGIS_CLIENT_ID = 'operator-client';
    process.env.ARCGIS_CLIENT_SECRET = 'operator-secret';
    process.env.ARCGIS_DAILY_TILE_SOFT_LIMIT = '1000';
    process.env.ARCGIS_ALLOWED_HOSTS =
      'www.arcgis.com,services.arcgisonline.com,server.arcgisonline.com';
    service = require('../src/services/arcgisMapProvider.service');
  });

  beforeEach(() => {
    jest.clearAllMocks();
    service.resetMapProviderCachesForTests();
    database.query.mockResolvedValue({ rows: [{ hybrid_basemap_enabled: true }] });
  });

  afterAll(() => {
    global.fetch = originalFetch;
  });

  test('rejects invalid and out-of-country tile coordinates before contacting ArcGIS', async () => {
    global.fetch = jest.fn();
    expect(() => service.assertLebanonTile(10, 0, 0)).toThrow('outside the Lebanon service area');
    expect(() => service.assertLebanonTile(10, 613.5, 409)).toThrow(
      'Map tile coordinates are invalid',
    );

    await expect(
      service.fetchTile({ layer: 'imagery', zoom: 10, x: 0, y: 0 }),
    ).rejects.toMatchObject({ code: 'MAP_TILE_OUTSIDE_AREA', status: 404 });
    expect(database.query).not.toHaveBeenCalled();
    expect(global.fetch).not.toHaveBeenCalled();
  });

  test('uses the operator credential server-side and returns only bounded image content', async () => {
    global.fetch = jest
      .fn()
      .mockResolvedValueOnce(
        new Response(JSON.stringify({ access_token: 'provider-token', expires_in: 3600 }), {
          status: 200,
          headers: { 'content-type': 'application/json' },
        }),
      )
      .mockResolvedValueOnce(
        new Response(Buffer.from('tile-bytes'), {
          status: 200,
          headers: {
            'content-type': 'image/jpeg',
            'cache-control': 'public, max-age=120',
          },
        }),
      );

    const tile = await service.fetchTile({ layer: 'imagery', zoom: 10, x: 613, y: 409 });
    const chunks = [];
    for await (const chunk of tile.stream) chunks.push(Buffer.from(chunk));

    expect(Buffer.concat(chunks).toString()).toBe('tile-bytes');
    expect(tile).toMatchObject({
      contentType: 'image/jpeg',
      cacheControl: 'public, max-age=120',
    });
    expect(global.fetch).toHaveBeenCalledTimes(2);
    const upstreamUrl = String(global.fetch.mock.calls[1][0]);
    expect(upstreamUrl).toContain('/tile/10/409/613');
    expect(upstreamUrl).toContain('token=provider-token');
  });

  test('caches the protected switch and exact provider attribution', async () => {
    global.fetch = jest
      .fn()
      .mockResolvedValueOnce(
        new Response(JSON.stringify({ access_token: 'provider-token', expires_in: 3600 }), {
          status: 200,
          headers: { 'content-type': 'application/json' },
        }),
      )
      .mockResolvedValueOnce(
        new Response(JSON.stringify({ copyrightText: 'Esri, Maxar, Earthstar Geographics' }), {
          status: 200,
          headers: { 'content-type': 'application/json' },
        }),
      );

    await expect(service.getProviderConfiguration()).resolves.toEqual({
      enabled: true,
      attribution: 'Esri, Maxar, Earthstar Geographics',
    });
    await expect(service.getProviderConfiguration()).resolves.toEqual({
      enabled: true,
      attribution: 'Esri, Maxar, Earthstar Geographics',
    });
    expect(database.query).toHaveBeenCalledTimes(1);
    expect(global.fetch).toHaveBeenCalledTimes(2);
  });
});
