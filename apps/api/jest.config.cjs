module.exports = {
  testEnvironment: 'node',
  testTimeout: 30000,
  testMatch: ['**/test/**/*.test.js'],
  setupFiles: ['<rootDir>/test/helpers/jest.setup.js'],
  moduleFileExtensions: ['ts', 'js', 'json'],
  transform: {
    '^.+\\.ts$': ['@swc/jest'],
  },
  collectCoverageFrom: ['src/**/*.ts', '!src/**/*.d.ts'],
  coverageThreshold: {
    global: {
      lines: 25,
      statements: 25,
      functions: 20,
      branches: 15,
    },
  },
};
