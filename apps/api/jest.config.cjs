module.exports = {
  testEnvironment: 'node',
  testMatch: ['**/test/**/*.test.js'],
  moduleFileExtensions: ['ts', 'js', 'json'],
  transform: {
    '^.+\\.ts$': ['@swc/jest'],
  },
  collectCoverageFrom: ['src/**/*.ts', '!src/**/*.d.ts'],
  coverageThreshold: {
    global: {
      lines: 30,
      statements: 30,
      functions: 20,
      branches: 15,
    },
  },
};
