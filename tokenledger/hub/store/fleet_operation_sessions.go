package store

import (
	"database/sql"
	"regexp"
	"strings"
)

// A request can name several durable sessions (for example a move). Keep all
// UUID references, including legacy envelopes, so indexing does not weaken the
// conservative hide rule. Parsing happens once on write, never on a list read.
var operationSessionUUID = regexp.MustCompile(`[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}`)

func indexOperationSessions(tx *sql.Tx, o FleetOperation) error {
	ids := append(operationSessionUUID.FindAllString(o.Request, -1), "", "casefold-v1") // empty = backfill receipt
	for _, id := range ids {
		// The old SQLite LIKE predicate is ASCII-case-insensitive; PostgreSQL LIKE
		// is not. Preserve that distinction for non-canonical legacy references.
		if lower := strings.ToLower(id); lower != id {
			var matched bool
			if err := tx.QueryRow(`SELECT ? LIKE ?`, o.Request, "%"+lower+"%").Scan(&matched); err != nil {
				return err
			}
			if !matched {
				continue
			}
			id = lower
		}
		if _, err := tx.Exec(`INSERT INTO fleet_operation_sessions(operation_id,session_id,status) VALUES(?,?,?) ON CONFLICT(operation_id,session_id) DO NOTHING`, o.ID, id, o.Status); err != nil {
			return err
		}
	}
	return nil
}

func (s *Store) ensureOperationSessions() error {
	if _, err := s.write.Exec(s.d.ddl(`CREATE TABLE IF NOT EXISTS fleet_operation_sessions (
 operation_id TEXT NOT NULL REFERENCES fleet_operations(id) ON DELETE CASCADE,
 session_id TEXT NOT NULL, status TEXT NOT NULL, PRIMARY KEY(operation_id,session_id));
 CREATE INDEX IF NOT EXISTS fleet_operation_sessions_history_pending ON fleet_operation_sessions(session_id) WHERE status NOT IN ('succeeded','failed');
 CREATE INDEX IF NOT EXISTS fleet_operation_sessions_pending ON fleet_operation_sessions(session_id) WHERE status NOT IN ('succeeded','failed','expired');
 CREATE INDEX IF NOT EXISTS fleet_operations_reconcile ON fleet_operations(updated,id) WHERE status IN ('pending','accepted','running','unknown') AND fleet_id <> '';
 CREATE INDEX IF NOT EXISTS fleet_operations_unfinished_age ON fleet_operations(created) WHERE status NOT IN ('succeeded','failed','expired');`)); err != nil {
		return err
	}
	// The PostgreSQL trigger also indexes writes from the old replica during a
	// rolling release. No JSON decoding assumption: old requests may be raw text.
	if s.d == postgresDialect {
		if _, err := s.write.Exec(`CREATE OR REPLACE FUNCTION fleet_operation_expired_guard() RETURNS trigger LANGUAGE plpgsql AS $body$
 BEGIN IF OLD.status='expired' THEN RETURN OLD; END IF; RETURN NEW; END $body$;
 DROP TRIGGER IF EXISTS fleet_operation_expired_guard ON fleet_operations;
 CREATE TRIGGER fleet_operation_expired_guard BEFORE UPDATE ON fleet_operations FOR EACH ROW EXECUTE FUNCTION fleet_operation_expired_guard();
 CREATE OR REPLACE FUNCTION fleet_operation_sessions_sync() RETURNS trigger LANGUAGE plpgsql AS $body$
 BEGIN
 IF TG_OP = 'UPDATE' AND NEW.request = OLD.request THEN
   IF NEW.status <> OLD.status THEN UPDATE fleet_operation_sessions SET status=NEW.status WHERE operation_id=NEW.id; END IF;
   RETURN NEW;
 END IF;
 DELETE FROM fleet_operation_sessions WHERE operation_id=NEW.id;
 INSERT INTO fleet_operation_sessions(operation_id,session_id,status)
 SELECT NEW.id, x, NEW.status FROM (SELECT '' AS x UNION SELECT (regexp_matches(NEW.request,'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}','g'))[1]) refs;
 RETURN NEW;
 END $body$;
 DROP TRIGGER IF EXISTS fleet_operation_sessions_sync ON fleet_operations;
 CREATE TRIGGER fleet_operation_sessions_sync AFTER INSERT OR UPDATE OF request,status ON fleet_operations FOR EACH ROW EXECUTE FUNCTION fleet_operation_sessions_sync();`); err != nil {
			return err
		}
	} else {
		if _, err := s.write.Exec(`CREATE TRIGGER IF NOT EXISTS fleet_operation_expired_guard BEFORE UPDATE ON fleet_operations WHEN OLD.status='expired' BEGIN SELECT RAISE(IGNORE); END;
 CREATE TRIGGER IF NOT EXISTS fleet_operation_sessions_status AFTER UPDATE OF status ON fleet_operations BEGIN UPDATE fleet_operation_sessions SET status=NEW.status WHERE operation_id=NEW.id; END;`); err != nil {
			return err
		}
	}
	tx, err := s.write.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	receipt := ""
	if s.d != postgresDialect {
		receipt = "casefold-v1"
	}
	rows, err := tx.Query(`SELECT id,request,status FROM fleet_operations o WHERE NOT EXISTS (SELECT 1 FROM fleet_operation_sessions r WHERE r.operation_id=o.id AND r.session_id=?)`, receipt)
	if err != nil {
		return err
	}
	var ops []FleetOperation
	for rows.Next() {
		var o FleetOperation
		if err := rows.Scan(&o.ID, &o.Request, &o.Status); err != nil {
			rows.Close()
			return err
		}
		ops = append(ops, o)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	for _, o := range ops {
		// Lock/re-read: a terminal result may have landed during the migration.
		if err := tx.QueryRow(`SELECT request,status FROM fleet_operations WHERE id=?`+s.d.forUpdate(), o.ID).Scan(&o.Request, &o.Status); err != nil {
			return err
		}
		if err := indexOperationSessions(tx, o); err != nil {
			return err
		}
	}
	return tx.Commit()
}
