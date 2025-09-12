CREATE TABLE IF NOT EXISTS sources (
  id TEXT PRIMARY KEY,
  display_name TEXT,
  file_path TEXT,
  course_code TEXT,
  pages INTEGER,
  chunks INTEGER,
  created_at TEXT DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS doc_chunks (
  id TEXT PRIMARY KEY,
  source_id TEXT NOT NULL,
  page INTEGER,
  content TEXT NOT NULL,
  section_title TEXT,
  FOREIGN KEY(source_id) REFERENCES sources(id)
);
