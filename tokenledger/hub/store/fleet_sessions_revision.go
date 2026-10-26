package store

import "fmt"

// A cheap committed revision makes the short cache coherent across replicas,
// including writes from an older binary during rollout. No data is cached by
// this table. Revisions roll back with their writes.
func (s *Store) ensureSessionListRevision() error {
	if _, err := s.write.Exec(`CREATE TABLE IF NOT EXISTS fleet_sessions_revision (name TEXT PRIMARY KEY, revision BIGINT NOT NULL DEFAULT 0)`); err != nil {
		return err
	}
	if s.d == postgresDialect {
		if _, err := s.write.Exec(`CREATE OR REPLACE FUNCTION fleet_sessions_changed() RETURNS trigger LANGUAGE plpgsql AS $body$ BEGIN UPDATE fleet_sessions_revision SET revision=revision+1 WHERE name=TG_TABLE_NAME; RETURN NULL; END $body$;`); err != nil {
			return err
		}
	}
	for _, table := range []string{"fleet_fleets", "fleet_machines", "fleet_ids", "fleet_id_results", "fleet_history_hides", "fleet_operations", "fleet_tasks", "hub_chat_mirrors", "fleet_accounts", "fleet_principals", "fleet_settings", "endpoints", "nodes", "pool_usage"} {
		if _, err := s.write.Exec(`INSERT INTO fleet_sessions_revision(name) VALUES(?) ON CONFLICT(name) DO NOTHING`, table); err != nil {
			return err
		}
		if s.d == postgresDialect {
			if _, err := s.write.Exec(fmt.Sprintf(`DROP TRIGGER IF EXISTS fleet_sessions_changed ON %s; CREATE TRIGGER fleet_sessions_changed AFTER INSERT OR UPDATE OR DELETE ON %s FOR EACH STATEMENT EXECUTE FUNCTION fleet_sessions_changed();`, table, table)); err != nil {
				return err
			}
		} else {
			for _, event := range []string{"INSERT", "UPDATE", "DELETE"} {
				if _, err := s.write.Exec(fmt.Sprintf(`CREATE TRIGGER IF NOT EXISTS fleet_sessions_%s_%s AFTER %s ON %s BEGIN UPDATE fleet_sessions_revision SET revision=revision+1 WHERE name='%s'; END;`, table, event, event, table, table)); err != nil {
					return err
				}
			}
		}
	}
	return nil
}

func (s *Store) FleetSessionsRevision() (int64, error) {
	var revision int64
	err := s.read.QueryRow(`SELECT COALESCE(SUM(revision),0) FROM fleet_sessions_revision`).Scan(&revision)
	return revision, err
}
