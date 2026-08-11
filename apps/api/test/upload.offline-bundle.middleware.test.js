const express = require('express');
const request = require('supertest');

const {
  classifyMultipartUploadError,
  uploadOfflineFeatureBundle,
} = require('../src/config/upload');
const { errorHandler } = require('../src/middleware/error');

const buildApp = () => {
  const app = express();
  app.post('/bundle', uploadOfflineFeatureBundle, (req, res) => {
    const files = Array.isArray(req.files) ? req.files : [];
    res.json({
      payload: req.body.payload,
      fileCount: files.length,
      filesAreMemoryBacked: files.every(
        (file) => Buffer.isBuffer(file.buffer) && file.path === undefined,
      ),
    });
  });
  app.use(errorHandler);
  return app;
};

const expectPermanent = (response, code) => {
  expect(response.status).toBe(422);
  expect(response.body.error).toEqual({
    code,
    disposition: 'permanent_rejection',
    retryable: false,
  });
};

describe('offline feature bundle multipart middleware', () => {
  const app = buildApp();

  test('accepts one JSON payload and keeps up to ten allowed photos in memory', async () => {
    let operation = request(app)
      .post('/bundle')
      .field('payload', JSON.stringify({ feature: {} }));
    for (let index = 0; index < 10; index += 1) {
      operation = operation.attach('photos', Buffer.from(`image-${index}`), {
        filename: `photo-${index}.jpg`,
        contentType: 'image/jpeg',
      });
    }

    const response = await operation;

    expect(response.status).toBe(200);
    expect(response.body).toEqual({
      payload: JSON.stringify({ feature: {} }),
      fileCount: 10,
      filesAreMemoryBacked: true,
    });
  });

  test.each([
    {
      name: 'missing payload',
      build: () => request(app).post('/bundle'),
    },
    {
      name: 'malformed JSON',
      build: () => request(app).post('/bundle').field('payload', '{broken'),
    },
    {
      name: 'non-object JSON',
      build: () => request(app).post('/bundle').field('payload', '[]'),
    },
    {
      name: 'unknown text field',
      build: () => request(app).post('/bundle').field('unexpected', '{}'),
    },
    {
      name: 'oversized payload',
      build: () =>
        request(app)
          .post('/bundle')
          .field('payload', JSON.stringify({ value: 'a'.repeat(256 * 1024) })),
    },
  ])('permanently rejects $name', async ({ build }) => {
    expectPermanent(await build(), 'OFFLINE_SYNC_PAYLOAD_REJECTED');
  });

  test('permanently rejects unsafe filenames without requiring offline headers', async () => {
    const response = await request(app)
      .post('/bundle')
      .field('payload', '{}')
      .attach('photos', Buffer.from('not-inspected-here'), {
        filename: 'photo.html.jpg',
        contentType: 'image/jpeg',
      });

    expectPermanent(response, 'OFFLINE_SYNC_ATTACHMENT_REJECTED');
  });

  test('permanently rejects an eleventh photo', async () => {
    let operation = request(app).post('/bundle').field('payload', '{}');
    for (let index = 0; index < 11; index += 1) {
      operation = operation.attach('photos', Buffer.from(`image-${index}`), {
        filename: `photo-${index}.png`,
        contentType: 'image/png',
      });
    }

    expectPermanent(await operation, 'OFFLINE_SYNC_ATTACHMENT_REJECTED');
  });

  test('classifies a truncated multipart stream as retryable', () => {
    const error = classifyMultipartUploadError(
      { headers: {} },
      new Error('Unexpected end of form'),
      true,
      true,
    );

    expect(error).toMatchObject({
      statusCode: 503,
      errorCode: 'OFFLINE_SYNC_TEMPORARY_FAILURE',
      disposition: 'retry',
      retryable: true,
    });
  });
});
