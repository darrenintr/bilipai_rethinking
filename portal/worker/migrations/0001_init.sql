-- Paladala Portal — Phase 1 schema
-- Run via:
--   wrangler d1 execute paladala-portal --local  --file=./migrations/0001_init.sql
--   wrangler d1 execute paladala-portal --remote --file=./migrations/0001_init.sql

CREATE TABLE IF NOT EXISTS reports (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  received_at     INTEGER NOT NULL,                 -- unix ms
  app_build       TEXT    NOT NULL,                 -- "0.5.22.322"
  app_version     TEXT    NOT NULL,                 -- "0.5.22"
  os_version      TEXT    NOT NULL,                 -- "iOS 18.5"
  device_model    TEXT,                             -- "iPad13,4"
  locale          TEXT,                             -- "zh-HK"
  session_id      TEXT,                             -- anonymous per-launch
  error_class     TEXT    NOT NULL,                 -- "NSException" / Swift type
  message         TEXT    NOT NULL,
  stacktrace      TEXT,
  fingerprint     TEXT    NOT NULL,                 -- SHA-256 hex of normalized stack
  r2_key          TEXT,                             -- path to R2 dump
  count           INTEGER NOT NULL DEFAULT 1,        -- dedup counter
  first_seen      INTEGER NOT NULL,
  last_seen       INTEGER NOT NULL,
  resolved        INTEGER NOT NULL DEFAULT 0         -- 0 = open, 1 = resolved
);

-- Triage: dedup by fingerprint, ordered by recency
CREATE INDEX IF NOT EXISTS idx_reports_fingerprint
  ON reports(fingerprint, last_seen DESC);

-- Triage: list by recency (newest first)
CREATE INDEX IF NOT EXISTS idx_reports_received_at
  ON reports(received_at DESC);

-- Triage: filter by build + class (release regression queries)
CREATE INDEX IF NOT EXISTS idx_reports_app_build
  ON reports(app_build, error_class);

-- Triage: filter by class
CREATE INDEX IF NOT EXISTS idx_reports_error_class
  ON reports(error_class, last_seen DESC);

-- Triage: only open (resolved = 0) sorted by last_seen
CREATE INDEX IF NOT EXISTS idx_reports_open
  ON reports(resolved, last_seen DESC)
  WHERE resolved = 0;

-- Phase 2: full-text search over message + stacktrace.
-- External content table — the text lives in `reports`; this only stores the index.
CREATE VIRTUAL TABLE IF NOT EXISTS reports_fts USING fts5(
  message,
  stacktrace,
  content='reports',
  content_rowid='id'
);

-- Triggers to keep FTS5 in sync with the source table.
CREATE TRIGGER IF NOT EXISTS reports_ai_fts AFTER INSERT ON reports BEGIN
  INSERT INTO reports_fts(rowid, message, stacktrace)
  VALUES (new.id, new.message, COALESCE(new.stacktrace, ''));
END;

CREATE TRIGGER IF NOT EXISTS reports_ad_fts AFTER DELETE ON reports BEGIN
  INSERT INTO reports_fts(reports_fts, rowid, message, stacktrace)
  VALUES ('delete', old.id, old.message, COALESCE(old.stacktrace, ''));
END;

CREATE TRIGGER IF NOT EXISTS reports_au_fts AFTER UPDATE ON reports BEGIN
  INSERT INTO reports_fts(reports_fts, rowid, message, stacktrace)
  VALUES ('delete', old.id, old.message, COALESCE(old.stacktrace, ''));
  INSERT INTO reports_fts(rowid, message, stacktrace)
  VALUES (new.id, new.message, COALESCE(new.stacktrace, ''));
END;
