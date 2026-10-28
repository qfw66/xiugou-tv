ALTER TABLE submission ADD COLUMN hidden INTEGER NOT NULL DEFAULT 0;

DROP INDEX IF EXISTS one_shot;

CREATE UNIQUE INDEX IF NOT EXISTS one_shot ON submission(ep_key, client_id, category) WHERE hidden = 0;

CREATE TABLE IF NOT EXISTS feedback (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  ep_key       TEXT    NOT NULL,
  category     TEXT    NOT NULL,
  client_id    TEXT    NOT NULL,
  ip_hash      TEXT    NOT NULL,
  verdict      TEXT    NOT NULL,
  start_ms     INTEGER NOT NULL,
  end_ms       INTEGER NOT NULL,
  duration_ms  INTEGER NOT NULL,
  created_at   INTEGER NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS feedback_once ON feedback(ep_key, category, client_id);

CREATE INDEX IF NOT EXISTS feedback_by_ip ON feedback(ip_hash, created_at);
