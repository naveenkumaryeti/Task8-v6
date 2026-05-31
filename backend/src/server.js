/**
 * ============================================================
 * Enterprise Node.js API Server
 * ============================================================
 *
 * Architecture decisions:
 *   - All secrets come from environment variables (injected by Vault Agent)
 *   - Database connection pool is created lazily (readiness probe validates it)
 *   - Liveness probe (/api/ping) NEVER touches the DB — only checks if process is alive
 *   - Readiness probe (/api/health) checks DB connectivity — gates traffic admission
 *   - Helmet adds security headers; rate limiter prevents abuse
 *   - Graceful shutdown on SIGTERM (sent by Kubernetes during rolling updates)
 *
 * Secret injection flow:
 *   Vault Agent sidecar reads Vault → writes to /vault/secrets/db-creds
 *   Container reads that file OR uses env vars injected by Vault Agent Injector
 *   process.env.DB_PASSWORD, process.env.DB_USER, etc. are set by Vault
 */

'use strict';

const express       = require('express');
const mysql         = require('mysql2/promise');
const helmet        = require('helmet');
const morgan        = require('morgan');
const cors          = require('cors');
const rateLimit     = require('express-rate-limit');

// ── App Setup ─────────────────────────────────────────────────────────────────
const app  = express();
const PORT = process.env.PORT || 3000;

// ── Middleware ────────────────────────────────────────────────────────────────
app.use(helmet());                    // Security headers (XSS, HSTS, etc.)
app.use(cors());                      // Allow frontend origin
app.use(morgan('combined'));           // Access logging
app.use(express.json({ limit: '1mb' }));

// Rate limiting — 100 requests per minute per IP
const limiter = rateLimit({
  windowMs: 60 * 1000,
  max:      100,
  standardHeaders: true,
  legacyHeaders:   false,
  message: { error: 'Too many requests, please slow down.' }
});
app.use('/api/', limiter);

// ── Database Connection Pool ───────────────────────────────────────────────────
// Secrets arrive via Vault Agent Injector as environment variables.
// NEVER hardcode these. NEVER commit .env files.
const dbConfig = {
  host:               process.env.DB_HOST     || 'mysql-service',
  port:     parseInt(process.env.DB_PORT)     || 3306,
  user:               process.env.DB_USER     || 'appuser',      // Set by Vault
  password:           process.env.DB_PASSWORD || '',             // Set by Vault — empty fallback will fail, which is correct
  database:           process.env.DB_NAME     || 'appdb',
  waitForConnections: true,
  connectionLimit:    10,        // Max concurrent DB connections
  queueLimit:         0,
  enableKeepAlive:    true,
  keepAliveInitialDelay: 0
};

let pool = null;

/**
 * Get (or lazily create) the MySQL connection pool.
 * Separating creation from startup means the server starts even if DB isn't ready yet.
 * Kubernetes readiness probe will hold traffic until /api/health passes.
 */
async function getPool() {
  if (!pool) {
    pool = mysql.createPool(dbConfig);
  }
  return pool;
}

// ── Routes ────────────────────────────────────────────────────────────────────

/**
 * GET /api/ping
 * Liveness probe target.
 * MUST NOT check external dependencies.
 * Returns 200 as long as the Node.js process is running.
 */
app.get('/api/ping', (req, res) => {
  res.json({ status: 'alive', timestamp: new Date().toISOString() });
});

/**
 * GET /api/health
 * Readiness probe target.
 * Validates that the app can actually serve traffic (DB is reachable).
 * Kubernetes will stop sending traffic if this returns non-200.
 */
app.get('/api/health', async (req, res) => {
  try {
    const db   = await getPool();
    const conn = await db.getConnection();
    await conn.query('SELECT 1');    // Lightweight connectivity check
    conn.release();

    res.json({
      status:    'healthy',
      database:  'connected',
      timestamp: new Date().toISOString(),
      version:   process.env.APP_VERSION || '1.0.0'
    });
  } catch (err) {
    // Return 503 so Kubernetes knows pod is NOT ready to receive traffic
    res.status(503).json({
      status:    'unhealthy',
      database:  'disconnected',
      error:     err.message,
      timestamp: new Date().toISOString()
    });
  }
});

/**
 * GET /api/users
 * Sample resource endpoint — fetch users from DB.
 */
app.get('/api/users', async (req, res) => {
  try {
    const db   = await getPool();
    const [rows] = await db.query('SELECT id, name, email, created_at FROM users LIMIT 100');
    res.json({ success: true, data: rows, count: rows.length });
  } catch (err) {
    console.error('[GET /api/users] Error:', err.message);
    res.status(500).json({ success: false, error: 'Database error' });
  }
});

/**
 * POST /api/users
 * Create a new user.
 */
app.post('/api/users', async (req, res) => {
  const { name, email } = req.body;

  if (!name || !email) {
    return res.status(400).json({ success: false, error: 'name and email are required' });
  }

  try {
    const db = await getPool();
    const [result] = await db.query(
      'INSERT INTO users (name, email) VALUES (?, ?)',
      [name, email]
    );
    res.status(201).json({ success: true, id: result.insertId, name, email });
  } catch (err) {
    if (err.code === 'ER_DUP_ENTRY') {
      return res.status(409).json({ success: false, error: 'Email already exists' });
    }
    console.error('[POST /api/users] Error:', err.message);
    res.status(500).json({ success: false, error: 'Database error' });
  }
});

/**
 * GET /api/info
 * Returns runtime environment info (non-sensitive).
 * Useful for debugging which pod / version is serving.
 */
app.get('/api/info', (req, res) => {
  res.json({
    version:     process.env.APP_VERSION   || '1.0.0',
    environment: process.env.NODE_ENV      || 'production',
    hostname:    require('os').hostname(),  // Pod name in Kubernetes
    uptime:      process.uptime(),
    memory:      process.memoryUsage()
  });
});

// ── 404 Handler ───────────────────────────────────────────────────────────────
app.use((req, res) => {
  res.status(404).json({ error: 'Route not found', path: req.path });
});

// ── Global Error Handler ──────────────────────────────────────────────────────
app.use((err, req, res, _next) => {
  console.error('[Unhandled Error]', err);
  res.status(500).json({ error: 'Internal server error' });
});

// ── Start Server ──────────────────────────────────────────────────────────────
const server = app.listen(PORT, () => {
  console.log(`[server] Listening on port ${PORT}`);
  console.log(`[server] Environment: ${process.env.NODE_ENV || 'production'}`);
  console.log(`[server] DB Host: ${dbConfig.host}:${dbConfig.port}`);
});

// ── Graceful Shutdown ──────────────────────────────────────────────────────────
// Kubernetes sends SIGTERM before killing a pod (during rolling updates).
// We finish in-flight requests, close the DB pool, then exit cleanly.
// This is what enables zero-downtime rolling deployments.
const shutdown = async (signal) => {
  console.log(`[server] ${signal} received — graceful shutdown initiated`);

  server.close(async () => {
    console.log('[server] HTTP server closed');

    if (pool) {
      await pool.end();
      console.log('[server] DB pool closed');
    }

    console.log('[server] Shutdown complete');
    process.exit(0);
  });

  // Force exit after 30s if shutdown hangs
  setTimeout(() => {
    console.error('[server] Shutdown timeout — forcing exit');
    process.exit(1);
  }, 30000);
};

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT',  () => shutdown('SIGINT'));

module.exports = app; // Export for testing
