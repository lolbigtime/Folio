CREATE TABLE IF NOT EXISTS doc_chunk_vectors (
  chunk_id TEXT PRIMARY KEY,
  dim      INTEGER NOT NULL,
  vec      BLOB    NOT NULL,
  FOREIGN KEY(chunk_id) REFERENCES doc_chunks(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_vectors_chunk_id ON doc_chunk_vectors(chunk_id);
