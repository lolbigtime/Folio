CREATE VIRTUAL TABLE IF NOT EXISTS doc_chunks_fts USING fts5(
  content, source_id, course_code, section_title,
  content='doc_chunks', content_rowid='rowid',
  tokenize='unicode61 remove_diacritics 2 tokenchars ''-_'''
);
