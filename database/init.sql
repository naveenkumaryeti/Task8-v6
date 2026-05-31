-- ============================================================
-- Database Initialization Script
-- Runs automatically when MySQL container starts for the first time
-- Mounted as ConfigMap → /docker-entrypoint-initdb.d/init.sql
-- ============================================================

-- Create the application database (idempotent)
CREATE DATABASE IF NOT EXISTS appdb
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

USE appdb;

-- ── Tables ────────────────────────────────────────────────────────────────────

-- Users table
CREATE TABLE IF NOT EXISTS users (
  id         INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  name       VARCHAR(255)        NOT NULL,
  email      VARCHAR(255) UNIQUE NOT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  INDEX idx_email (email)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Application events / audit log
CREATE TABLE IF NOT EXISTS events (
  id         BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  user_id    INT UNSIGNED,
  event_type VARCHAR(100) NOT NULL,
  payload    JSON,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  INDEX idx_user_id   (user_id),
  INDEX idx_event_type (event_type),
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ── Application User (least-privilege) ───────────────────────────────────────
-- The app uses 'appuser' (not root) for all queries.
-- Password is managed by Vault — this script creates the account;
-- Vault will rotate the password after Vault is configured.
-- The password below is a placeholder that Vault will overwrite.
CREATE USER IF NOT EXISTS 'appuser'@'%' IDENTIFIED BY 'PLACEHOLDER_REPLACED_BY_VAULT';
GRANT SELECT, INSERT, UPDATE, DELETE ON appdb.* TO 'appuser'@'%';
FLUSH PRIVILEGES;

-- ── Seed Data (development reference) ────────────────────────────────────────
-- Remove or gate behind an env variable in production if not needed
INSERT IGNORE INTO users (name, email) VALUES
  ('Admin User',   'admin@example.com'),
  ('Test User',    'test@example.com'),
  ('DevOps Team',  'devops@example.com');
