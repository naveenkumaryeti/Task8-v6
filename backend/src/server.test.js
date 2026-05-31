/**
 * Unit tests for the Express API
 * Run with: npm test
 */
'use strict';

const request = require('supertest');

// Mock mysql2 so tests don't need a real DB
jest.mock('mysql2/promise', () => ({
  createPool: jest.fn(() => ({
    getConnection: jest.fn().mockResolvedValue({
      query:   jest.fn().mockResolvedValue([[{ '1': 1 }]]),
      release: jest.fn()
    }),
    query: jest.fn().mockResolvedValue([[{ id: 1, name: 'Test', email: 'test@test.com', created_at: new Date() }]]),
    end:   jest.fn()
  }))
}));

const app = require('./server');

describe('GET /api/ping', () => {
  it('returns 200 with alive status', async () => {
    const res = await request(app).get('/api/ping');
    expect(res.status).toBe(200);
    expect(res.body.status).toBe('alive');
  });
});

describe('GET /api/health', () => {
  it('returns 200 when DB is reachable', async () => {
    const res = await request(app).get('/api/health');
    expect(res.status).toBe(200);
    expect(res.body.database).toBe('connected');
  });
});

describe('GET /api/info', () => {
  it('returns runtime info', async () => {
    const res = await request(app).get('/api/info');
    expect(res.status).toBe(200);
    expect(res.body).toHaveProperty('hostname');
    expect(res.body).toHaveProperty('uptime');
  });
});

describe('Unknown routes', () => {
  it('returns 404 for unmatched paths', async () => {
    const res = await request(app).get('/api/nonexistent');
    expect(res.status).toBe(404);
  });
});
