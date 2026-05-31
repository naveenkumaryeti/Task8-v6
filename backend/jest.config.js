module.exports = {
  testEnvironment: 'node',
  collectCoverageFrom: [
    'src/**/*.js',
    '!src/**/*.test.js'
  ],
  coverageThreshold: {
    global: {
      branches:   40,
      functions:  40,
      lines:      40,
      statements: 40
    }
  },
  testTimeout: 10000
};
