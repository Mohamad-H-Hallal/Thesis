const { AppError, errorHandler } = require('../src/middleware/error');
const logger = require('../src/utils/logger');

const createResponse = () => {
  const response = {
    setHeader: jest.fn(),
    status: jest.fn(),
    json: jest.fn(),
  };
  response.status.mockReturnValue(response);
  return response;
};

describe('central API error logging', () => {
  let previousNodeEnv;

  beforeEach(() => {
    previousNodeEnv = process.env.NODE_ENV;
    process.env.NODE_ENV = 'production';
  });

  afterEach(() => {
    if (previousNodeEnv === undefined) {
      delete process.env.NODE_ENV;
    } else {
      process.env.NODE_ENV = previousNodeEnv;
    }
    jest.restoreAllMocks();
  });

  test('logs an unexpected error stack while returning a safe production response', () => {
    const log = jest.spyOn(logger, 'error').mockImplementation(() => undefined);
    const response = createResponse();
    const error = new Error('database adapter failed internally');
    error.stack = 'Error: database adapter failed internally\n    at controlled-test';

    errorHandler(
      error,
      {
        headers: {},
        method: 'GET',
        originalUrl: '/api/v1/projects/88b10e32-d91f-4c04-a582-b1f03c4fb853?token=hidden',
        requestId: 'request-test-1',
        user: { id: 'user-test-1' },
      },
      response,
      jest.fn(),
    );

    expect(log).toHaveBeenCalledWith(
      'Request failed',
      expect.objectContaining({
        component: 'http',
        requestId: 'request-test-1',
        path: '/api/v1/projects/:id',
        statusCode: 500,
        stack: expect.stringContaining('controlled-test'),
      }),
    );
    expect(response.status).toHaveBeenCalledWith(500);
    expect(response.json).toHaveBeenCalledWith({
      success: false,
      requestId: 'request-test-1',
      message: 'Internal Server Error',
    });
  });

  test('preserves a safe operational error response contract', () => {
    jest.spyOn(logger, 'error').mockImplementation(() => undefined);
    const response = createResponse();

    errorHandler(
      new AppError('Temporary provider failure.', 503, {
        code: 'PROVIDER_UNAVAILABLE',
        disposition: 'retry',
        retryable: true,
      }),
      {
        headers: {},
        method: 'POST',
        originalUrl: '/api/v1/ai/jobs',
        requestId: 'request-test-2',
      },
      response,
      jest.fn(),
    );

    expect(response.json).toHaveBeenCalledWith(
      expect.objectContaining({
        success: false,
        message: 'Temporary provider failure.',
        error: {
          code: 'PROVIDER_UNAVAILABLE',
          disposition: 'retry',
          retryable: true,
        },
      }),
    );
  });
});
