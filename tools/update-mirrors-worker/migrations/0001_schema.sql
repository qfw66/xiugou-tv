CREATE TABLE mirror_manifest (
  singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
  revision INTEGER NOT NULL CHECK (revision BETWEEN 1 AND 9007199254740991)
) STRICT;

INSERT INTO mirror_manifest (singleton, revision) VALUES (1, 1);

CREATE TABLE mirrors (
  id TEXT PRIMARY KEY NOT NULL,
  label TEXT NOT NULL CHECK (length(label) BETWEEN 1 AND 80),
  prefix TEXT NOT NULL UNIQUE CHECK (length(prefix) BETWEEN 1 AND 512),
  proxies_api INTEGER NOT NULL DEFAULT 0 CHECK (proxies_api IN (0, 1)),
  enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
  priority INTEGER NOT NULL CHECK (priority BETWEEN -9007199254740991 AND 9007199254740991)
) STRICT;

CREATE INDEX mirrors_order ON mirrors (priority, id);

CREATE TRIGGER mirror_manifest_revision_increases
BEFORE UPDATE OF revision ON mirror_manifest
WHEN NEW.revision <= OLD.revision
BEGIN
  SELECT RAISE(ABORT, 'manifest revision must increase');
END;

CREATE TRIGGER mirror_manifest_keep_singleton
BEFORE DELETE ON mirror_manifest
BEGIN
  SELECT RAISE(ABORT, 'manifest singleton cannot be deleted');
END;

CREATE TRIGGER mirrors_insert_revision
AFTER INSERT ON mirrors
BEGIN
  UPDATE mirror_manifest SET revision = revision + 1 WHERE singleton = 1;
END;

CREATE TRIGGER mirrors_update_revision
AFTER UPDATE ON mirrors
BEGIN
  UPDATE mirror_manifest SET revision = revision + 1 WHERE singleton = 1;
END;

CREATE TRIGGER mirrors_delete_revision
AFTER DELETE ON mirrors
BEGIN
  UPDATE mirror_manifest SET revision = revision + 1 WHERE singleton = 1;
END;
