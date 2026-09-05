import type { Request, Response } from 'express';
import { pipeline } from 'node:stream/promises';
import { AppError } from '../middleware/error';
import {
  MapProviderError,
  fetchTile,
  getProviderConfiguration,
} from '../services/arcgisMapProvider.service';

const providerConfig = async (_req: Request, res: Response): Promise<void> => {
  const config = await getProviderConfiguration();
  res.json({
    success: true,
    data: {
      hybrid_enabled: config.enabled,
      hybrid_attribution: config.attribution,
      imagery_tile_template: '/maps/tiles/imagery/{z}/{y}/{x}',
      reference_tile_template: '/maps/tiles/reference/{z}/{y}/{x}',
      fallback_style: 'street',
    },
  });
};

const tile = async (req: Request, res: Response): Promise<void> => {
  try {
    const layer = req.params.layer;
    if (layer !== 'imagery' && layer !== 'reference') {
      throw new AppError('Map layer is invalid.', 404);
    }
    const result = await fetchTile({
      layer,
      zoom: Number(req.params.z),
      y: Number(req.params.y),
      x: Number(req.params.x),
    });
    res.setHeader('Content-Type', result.contentType);
    res.setHeader('Cache-Control', result.cacheControl);
    if (result.etag) res.setHeader('ETag', result.etag);
    await pipeline(result.stream, res);
  } catch (error) {
    if (error instanceof MapProviderError) {
      if (error.retryAfterSeconds) res.setHeader('Retry-After', String(error.retryAfterSeconds));
      throw new AppError(error.message, error.status, {
        code: error.code,
        disposition: 'retry',
        retryable: error.status >= 500,
      });
    }
    throw error;
  }
};

export { providerConfig, tile };
