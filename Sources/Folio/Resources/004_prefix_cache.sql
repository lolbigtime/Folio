CREATE TABLE IF NOT EXISTS prefix_cache (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  meta  TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (STRFTIME('%Y-%m-%dT%H:%M:%fZ','now'))
);
