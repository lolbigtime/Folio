CREATE TABLE IF NOT EXISTS doc_chunk_vectors (
  rowid INTEGER PRIMARY KEY,
  dim   INTEGER NOT NULL,
  vec   BLOB    NOT NULL,
  FOREIGN KEY(rowid) REFERENCES doc_chunks(rowid) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_vectors_rowid ON doc_chunk_vectors(rowid);
