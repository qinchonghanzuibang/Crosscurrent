import Foundation
import GRDB

enum CanonicalSchema {
    static let version = 5

    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("canonical-v1") { db in
            for statement in statements {
                try db.execute(sql: statement)
            }
            try db.execute(sql: "PRAGMA user_version = 1")
        }
        migrator.registerMigration("canonical-v2-preferences") { db in
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS app_preferences (key TEXT PRIMARY KEY NOT NULL, value_json BLOB NOT NULL, updated_at REAL NOT NULL) STRICT")
            try db.execute(sql: "PRAGMA user_version = 2")
        }
        migrator.registerMigration("canonical-v3-user-library") { db in
            try db.execute(sql: "CREATE UNIQUE INDEX IF NOT EXISTS saved_entries_target ON saved_entries(target_kind, target_id)")
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS library_folders (id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, parent_id TEXT REFERENCES library_folders(id) ON DELETE SET NULL, sort_order INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL) STRICT")
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS tags (id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, normalized_name TEXT NOT NULL UNIQUE, created_at REAL NOT NULL) STRICT")
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS saved_entry_tags (saved_entry_id TEXT NOT NULL REFERENCES saved_entries(id) ON DELETE CASCADE, tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE, PRIMARY KEY(saved_entry_id, tag_id)) WITHOUT ROWID, STRICT")
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS smart_collections (id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, query_json BLOB NOT NULL, created_at REAL NOT NULL) STRICT")
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS stars (target_kind TEXT NOT NULL, target_id TEXT NOT NULL, starred_at REAL NOT NULL, PRIMARY KEY(target_kind, target_id)) WITHOUT ROWID, STRICT")
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS history_entries (id TEXT PRIMARY KEY NOT NULL, target_kind TEXT NOT NULL, target_id TEXT NOT NULL, revision_id TEXT, visited_at REAL NOT NULL) STRICT")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS history_entries_recent ON history_entries(visited_at DESC)")
            try db.execute(sql: "PRAGMA user_version = 3")
        }
        migrator.registerMigration("canonical-v4-source-folders") { db in
            try db.execute(sql: "CREATE TABLE source_folders (id TEXT PRIMARY KEY NOT NULL, parent_id TEXT REFERENCES source_folders(id) ON DELETE CASCADE, path_key TEXT NOT NULL UNIQUE, name TEXT NOT NULL, attributes_json BLOB, sort_order INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL) STRICT")
            try db.execute(sql: "CREATE TABLE source_folder_memberships (folder_id TEXT NOT NULL REFERENCES source_folders(id) ON DELETE CASCADE, source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE, sort_order INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(folder_id, source_id)) WITHOUT ROWID, STRICT")
            try db.execute(sql: "PRAGMA user_version = 4")
        }
        migrator.registerMigration("canonical-v5-topic-identity") { db in
            // Pre-release databases may contain aliases that normalize to the same value.
            // Keep the oldest immutable assertion and make later ingestion converge on it.
            try db.execute(sql: "DELETE FROM topic_aliases WHERE id NOT IN (SELECT MIN(id) FROM topic_aliases GROUP BY normalized_name)")
            try db.execute(sql: "CREATE UNIQUE INDEX IF NOT EXISTS topic_aliases_normalized ON topic_aliases(normalized_name)")
            try db.execute(sql: "PRAGMA user_version = 5")
        }
        return migrator
    }

    static let statements: [String] = [
        """
        CREATE TABLE database_change_generations (
          domain TEXT PRIMARY KEY NOT NULL,
          generation INTEGER NOT NULL DEFAULT 0,
          committed_at REAL NOT NULL,
          writer_instance TEXT NOT NULL
        ) STRICT
        """,
        """
        CREATE TABLE idempotency_commits (
          idempotency_key TEXT PRIMARY KEY NOT NULL,
          committed_at REAL NOT NULL,
          writer_instance TEXT NOT NULL
        ) STRICT
        """,
        """
        CREATE TABLE sources (
          id TEXT PRIMARY KEY NOT NULL,
          current_revision_id TEXT NOT NULL,
          kind TEXT NOT NULL,
          is_followed INTEGER NOT NULL DEFAULT 1,
          is_archived INTEGER NOT NULL DEFAULT 0,
          created_at REAL NOT NULL
        ) STRICT
        """,
        """
        CREATE TABLE source_revisions (
          id TEXT PRIMARY KEY NOT NULL,
          source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE RESTRICT,
          display_name TEXT NOT NULL,
          summary TEXT,
          avatar_url TEXT,
          configuration_json BLOB,
          created_at REAL NOT NULL
        ) STRICT
        """,
        "CREATE INDEX source_revisions_source ON source_revisions(source_id, created_at DESC)",
        """
        CREATE TABLE connector_accounts (
          id TEXT PRIMARY KEY NOT NULL,
          connector_kind TEXT NOT NULL,
          external_identity TEXT,
          browser_profile_uuid TEXT,
          keychain_reference BLOB,
          consent_state_json BLOB,
          created_at REAL NOT NULL
        ) STRICT
        """,
        """
        CREATE TABLE source_endpoints (
          id TEXT PRIMARY KEY NOT NULL,
          source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE RESTRICT,
          connector_kind TEXT NOT NULL,
          account_id TEXT REFERENCES connector_accounts(id) ON DELETE SET NULL,
          external_id TEXT NOT NULL,
          canonical_url TEXT,
          access_requirement TEXT NOT NULL,
          content_privacy TEXT NOT NULL,
          health TEXT NOT NULL,
          capabilities_json BLOB,
          refresh_policy_json BLOB,
          last_successful_sync REAL,
          UNIQUE(connector_kind, account_id, external_id)
        ) STRICT
        """,
        "CREATE INDEX source_endpoints_source ON source_endpoints(source_id)",
        """
        CREATE TABLE source_endpoint_relations (
          id TEXT PRIMARY KEY NOT NULL,
          from_endpoint_id TEXT NOT NULL REFERENCES source_endpoints(id) ON DELETE CASCADE,
          to_endpoint_id TEXT NOT NULL REFERENCES source_endpoints(id) ON DELETE CASCADE,
          relationship TEXT NOT NULL,
          UNIQUE(from_endpoint_id, to_endpoint_id, relationship)
        ) STRICT
        """,
        """
        CREATE TABLE source_ai_classifications (
          id TEXT PRIMARY KEY NOT NULL,
          source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE RESTRICT,
          access_requirement TEXT NOT NULL,
          content_privacy TEXT NOT NULL,
          provenance TEXT NOT NULL,
          confidence REAL NOT NULL,
          created_at REAL NOT NULL,
          supersedes_id TEXT REFERENCES source_ai_classifications(id) ON DELETE SET NULL,
          is_current INTEGER NOT NULL DEFAULT 1
        ) STRICT
        """,
        "CREATE INDEX source_ai_current ON source_ai_classifications(source_id, is_current)",
        """
        CREATE TABLE source_coverage_assertions (
          id TEXT PRIMARY KEY NOT NULL,
          source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE RESTRICT,
          ecosystem TEXT NOT NULL,
          provenance TEXT NOT NULL,
          confidence REAL NOT NULL,
          rationale TEXT,
          effective_at REAL NOT NULL,
          supersedes_id TEXT REFERENCES source_coverage_assertions(id) ON DELETE SET NULL,
          is_current INTEGER NOT NULL DEFAULT 1
        ) STRICT
        """,
        "CREATE INDEX source_coverage_current ON source_coverage_assertions(source_id, is_current)",
        """
        CREATE TABLE sync_cursors (
          endpoint_id TEXT PRIMARY KEY NOT NULL REFERENCES source_endpoints(id) ON DELETE CASCADE,
          cursor_family TEXT NOT NULL,
          cursor_data BLOB NOT NULL,
          updated_at REAL NOT NULL
        ) STRICT
        """,
        """
        CREATE TABLE sync_runs (
          id TEXT PRIMARY KEY NOT NULL,
          endpoint_id TEXT NOT NULL REFERENCES source_endpoints(id) ON DELETE RESTRICT,
          started_at REAL NOT NULL,
          completed_at REAL,
          result TEXT,
          item_count INTEGER NOT NULL DEFAULT 0,
          error_class TEXT,
          checkpoint BLOB
        ) STRICT
        """,
        """
        CREATE TABLE connector_health_events (
          id TEXT PRIMARY KEY NOT NULL,
          endpoint_id TEXT NOT NULL REFERENCES source_endpoints(id) ON DELETE RESTRICT,
          health TEXT NOT NULL,
          message TEXT,
          observed_at REAL NOT NULL
        ) STRICT
        """,
        """
        CREATE TABLE blobs (
          id TEXT PRIMARY KEY NOT NULL,
          sha256 TEXT NOT NULL UNIQUE,
          relative_path TEXT NOT NULL,
          byte_count INTEGER NOT NULL,
          media_type TEXT,
          retention_class TEXT NOT NULL,
          created_at REAL NOT NULL,
          quarantined_at REAL
        ) STRICT
        """,
        """
        CREATE TABLE raw_fetches (
          id TEXT PRIMARY KEY NOT NULL,
          endpoint_id TEXT REFERENCES source_endpoints(id) ON DELETE SET NULL,
          safe_url TEXT NOT NULL,
          redacted_request_metadata BLOB,
          redacted_response_metadata BLOB,
          status_code INTEGER,
          response_sha256 TEXT,
          blob_id TEXT REFERENCES blobs(id) ON DELETE SET NULL,
          fetched_at REAL NOT NULL,
          retention_class TEXT NOT NULL,
          extraction_outcome TEXT
        ) STRICT
        """,
        """
        CREATE TABLE entities (
          id TEXT PRIMARY KEY NOT NULL,
          current_revision_id TEXT NOT NULL,
          kind TEXT NOT NULL,
          normalized_name TEXT NOT NULL,
          is_followed INTEGER NOT NULL DEFAULT 0,
          created_at REAL NOT NULL
        ) STRICT
        """,
        """
        CREATE TABLE entity_revisions (
          id TEXT PRIMARY KEY NOT NULL,
          entity_id TEXT NOT NULL REFERENCES entities(id) ON DELETE RESTRICT,
          display_name TEXT NOT NULL,
          summary TEXT,
          external_identifiers_json BLOB,
          created_at REAL NOT NULL
        ) STRICT
        """,
        """
        CREATE TABLE entity_aliases (
          id TEXT PRIMARY KEY NOT NULL,
          entity_id TEXT NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
          value TEXT NOT NULL,
          normalized_value TEXT NOT NULL,
          language_code TEXT,
          script_code TEXT,
          provenance TEXT NOT NULL,
          confidence REAL NOT NULL,
          valid_from REAL,
          valid_until REAL
        ) STRICT
        """,
        "CREATE INDEX entity_alias_lookup ON entity_aliases(normalized_value)",
        """
        CREATE TABLE source_entities (
          id TEXT PRIMARY KEY NOT NULL,
          source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE RESTRICT,
          entity_id TEXT NOT NULL REFERENCES entities(id) ON DELETE RESTRICT,
          role TEXT NOT NULL,
          provenance TEXT NOT NULL,
          confidence REAL NOT NULL,
          UNIQUE(source_id, entity_id, role)
        ) STRICT
        """,
        """
        CREATE TABLE items (
          id TEXT PRIMARY KEY NOT NULL,
          source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE RESTRICT,
          endpoint_id TEXT NOT NULL REFERENCES source_endpoints(id) ON DELETE RESTRICT,
          connector_external_id TEXT NOT NULL,
          canonical_key TEXT NOT NULL,
          current_revision_id TEXT NOT NULL,
          remote_state TEXT NOT NULL,
          user_deletion_state TEXT NOT NULL DEFAULT 'active',
          created_at REAL NOT NULL,
          UNIQUE(endpoint_id, connector_external_id)
        ) STRICT
        """,
        "CREATE INDEX items_source ON items(source_id, created_at DESC)",
        """
        CREATE TABLE item_revisions (
          id TEXT PRIMARY KEY NOT NULL,
          item_id TEXT NOT NULL REFERENCES items(id) ON DELETE RESTRICT,
          ordinal INTEGER NOT NULL,
          title TEXT NOT NULL,
          author TEXT,
          published_at REAL,
          modified_at REAL,
          fetched_at REAL NOT NULL,
          language_code TEXT,
          plain_text TEXT NOT NULL,
          sanitized_html_blob_id TEXT REFERENCES blobs(id) ON DELETE SET NULL,
          evidence_blob_id TEXT REFERENCES blobs(id) ON DELETE SET NULL,
          content_hash TEXT NOT NULL,
          extraction_state TEXT NOT NULL,
          revision_reason TEXT NOT NULL,
          UNIQUE(item_id, ordinal),
          UNIQUE(item_id, content_hash)
        ) STRICT
        """,
        "CREATE INDEX item_revisions_item ON item_revisions(item_id, ordinal DESC)",
        """
        CREATE TABLE item_aliases (
          id TEXT PRIMARY KEY NOT NULL,
          item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
          alias_kind TEXT NOT NULL,
          alias_value TEXT NOT NULL,
          UNIQUE(alias_kind, alias_value)
        ) STRICT
        """,
        """
        CREATE TABLE item_relations (
          id TEXT PRIMARY KEY NOT NULL,
          from_item_id TEXT NOT NULL REFERENCES items(id) ON DELETE RESTRICT,
          to_item_id TEXT NOT NULL REFERENCES items(id) ON DELETE RESTRICT,
          relationship TEXT NOT NULL,
          confidence REAL NOT NULL,
          UNIQUE(from_item_id, to_item_id, relationship)
        ) STRICT
        """,
        """
        CREATE TABLE duplicate_groups (
          id TEXT PRIMARY KEY NOT NULL,
          canonical_item_id TEXT NOT NULL REFERENCES items(id) ON DELETE RESTRICT,
          created_at REAL NOT NULL
        ) STRICT
        """,
        """
        CREATE TABLE duplicate_group_members (
          group_id TEXT NOT NULL REFERENCES duplicate_groups(id) ON DELETE CASCADE,
          item_id TEXT NOT NULL REFERENCES items(id) ON DELETE RESTRICT,
          classification TEXT NOT NULL,
          PRIMARY KEY(group_id, item_id)
        ) WITHOUT ROWID, STRICT
        """,
        """
        CREATE TABLE item_segments (
          id TEXT PRIMARY KEY NOT NULL,
          item_revision_id TEXT NOT NULL REFERENCES item_revisions(id) ON DELETE RESTRICT,
          lineage_id TEXT NOT NULL,
          ordinal INTEGER NOT NULL,
          kind TEXT NOT NULL,
          utf8_start INTEGER NOT NULL,
          utf8_length INTEGER NOT NULL,
          heading_path TEXT,
          segment_hash TEXT NOT NULL,
          text TEXT NOT NULL,
          embedding_input TEXT NOT NULL,
          UNIQUE(item_revision_id, ordinal)
        ) STRICT
        """,
        "CREATE INDEX item_segments_lineage ON item_segments(lineage_id)",
        """
        CREATE TABLE item_assets (
          id TEXT PRIMARY KEY NOT NULL,
          item_revision_id TEXT NOT NULL REFERENCES item_revisions(id) ON DELETE RESTRICT,
          blob_id TEXT NOT NULL REFERENCES blobs(id) ON DELETE RESTRICT,
          role TEXT NOT NULL,
          retention_state TEXT NOT NULL
        ) STRICT
        """,
        """
        CREATE TABLE item_metric_snapshots (
          id TEXT PRIMARY KEY NOT NULL,
          item_id TEXT NOT NULL REFERENCES items(id) ON DELETE RESTRICT,
          endpoint_id TEXT NOT NULL REFERENCES source_endpoints(id) ON DELETE RESTRICT,
          metric_type TEXT NOT NULL,
          connector_metric_key TEXT,
          value REAL NOT NULL,
          captured_at REAL NOT NULL,
          provenance TEXT NOT NULL
        ) STRICT
        """,
        "CREATE INDEX item_metrics_series ON item_metric_snapshots(item_id, metric_type, captured_at)",
        """
        CREATE TABLE item_entity_mentions (
          id TEXT PRIMARY KEY NOT NULL,
          item_revision_id TEXT NOT NULL REFERENCES item_revisions(id) ON DELETE RESTRICT,
          item_segment_id TEXT NOT NULL REFERENCES item_segments(id) ON DELETE RESTRICT,
          entity_id TEXT NOT NULL REFERENCES entities(id) ON DELETE RESTRICT,
          utf8_start INTEGER NOT NULL,
          utf8_length INTEGER NOT NULL,
          excerpt_hash TEXT NOT NULL,
          mentioned_text TEXT NOT NULL,
          provenance TEXT NOT NULL,
          confidence REAL NOT NULL
        ) STRICT
        """,
        """
        CREATE TABLE topics (
          id TEXT PRIMARY KEY NOT NULL,
          current_revision_id TEXT NOT NULL,
          is_followed INTEGER NOT NULL DEFAULT 0
        ) STRICT
        """,
        """
        CREATE TABLE topic_revisions (
          id TEXT PRIMARY KEY NOT NULL,
          topic_id TEXT NOT NULL REFERENCES topics(id) ON DELETE RESTRICT,
          name TEXT NOT NULL,
          summary TEXT,
          created_at REAL NOT NULL
        ) STRICT
        """,
        """
        CREATE TABLE topic_aliases (
          id TEXT PRIMARY KEY NOT NULL,
          topic_id TEXT NOT NULL REFERENCES topics(id) ON DELETE CASCADE,
          normalized_name TEXT NOT NULL,
          language_code TEXT
        ) STRICT
        """,
        """
        CREATE TABLE item_topic_assertions (
          id TEXT PRIMARY KEY NOT NULL,
          item_revision_id TEXT NOT NULL REFERENCES item_revisions(id) ON DELETE RESTRICT,
          item_segment_id TEXT REFERENCES item_segments(id) ON DELETE RESTRICT,
          topic_id TEXT NOT NULL REFERENCES topics(id) ON DELETE RESTRICT,
          confidence REAL NOT NULL,
          provenance TEXT NOT NULL,
          supersedes_id TEXT REFERENCES item_topic_assertions(id) ON DELETE SET NULL
        ) STRICT
        """,
        """
        CREATE TABLE events (
          id TEXT PRIMARY KEY NOT NULL,
          current_revision_id TEXT NOT NULL,
          lifecycle_state TEXT NOT NULL DEFAULT 'active',
          created_at REAL NOT NULL,
          is_tombstoned INTEGER NOT NULL DEFAULT 0
        ) STRICT
        """,
        """
        CREATE TABLE event_membership_assertions (
          id TEXT PRIMARY KEY NOT NULL,
          event_id TEXT NOT NULL REFERENCES events(id) ON DELETE RESTRICT,
          item_revision_id TEXT NOT NULL REFERENCES item_revisions(id) ON DELETE RESTRICT,
          item_segment_id TEXT NOT NULL REFERENCES item_segments(id) ON DELETE RESTRICT,
          segment_lineage_id TEXT NOT NULL,
          decision TEXT NOT NULL,
          role TEXT NOT NULL,
          confidence REAL NOT NULL,
          identity_weight REAL NOT NULL,
          independence_group TEXT,
          provenance TEXT NOT NULL,
          supersedes_id TEXT REFERENCES event_membership_assertions(id) ON DELETE SET NULL,
          created_at REAL NOT NULL
        ) STRICT
        """,
        "CREATE INDEX memberships_event ON event_membership_assertions(event_id, created_at)",
        "CREATE INDEX memberships_segment ON event_membership_assertions(segment_lineage_id, created_at)",
        """
        CREATE TABLE event_revisions (
          id TEXT PRIMARY KEY NOT NULL,
          event_id TEXT NOT NULL REFERENCES events(id) ON DELETE RESTRICT,
          ordinal INTEGER NOT NULL,
          title TEXT NOT NULL,
          summary TEXT NOT NULL,
          started_at REAL,
          ended_at REAL,
          change_kind TEXT NOT NULL,
          primary_membership_assertion_id TEXT REFERENCES event_membership_assertions(id) ON DELETE SET NULL,
          score_snapshot_json BLOB,
          generation_metadata_json BLOB,
          created_at REAL NOT NULL,
          UNIQUE(event_id, ordinal)
        ) STRICT
        """,
        "CREATE INDEX event_revisions_event ON event_revisions(event_id, ordinal DESC)",
        """
        CREATE TABLE event_revision_memberships (
          event_revision_id TEXT NOT NULL REFERENCES event_revisions(id) ON DELETE RESTRICT,
          membership_assertion_id TEXT NOT NULL REFERENCES event_membership_assertions(id) ON DELETE RESTRICT,
          PRIMARY KEY(event_revision_id, membership_assertion_id)
        ) WITHOUT ROWID, STRICT
        """,
        """
        CREATE TABLE event_topic_assertions (
          id TEXT PRIMARY KEY NOT NULL,
          event_revision_id TEXT NOT NULL REFERENCES event_revisions(id) ON DELETE RESTRICT,
          topic_id TEXT NOT NULL REFERENCES topics(id) ON DELETE RESTRICT,
          confidence REAL NOT NULL,
          provenance TEXT NOT NULL,
          supersedes_id TEXT REFERENCES event_topic_assertions(id) ON DELETE SET NULL
        ) STRICT
        """,
        """
        CREATE TABLE event_lineage_operations (
          id TEXT PRIMARY KEY NOT NULL,
          operation TEXT NOT NULL,
          prior_event_revision_id TEXT NOT NULL REFERENCES event_revisions(id) ON DELETE RESTRICT,
          result_event_ids_json BLOB NOT NULL,
          weighted_overlap_json BLOB NOT NULL,
          created_at REAL NOT NULL
        ) STRICT
        """,
        """
        CREATE TABLE event_aliases (
          losing_event_id TEXT PRIMARY KEY NOT NULL REFERENCES events(id) ON DELETE RESTRICT,
          surviving_event_id TEXT NOT NULL REFERENCES events(id) ON DELETE RESTRICT,
          operation_id TEXT NOT NULL REFERENCES event_lineage_operations(id) ON DELETE RESTRICT
        ) STRICT
        """,
        """
        CREATE TABLE clustering_constraints (
          id TEXT PRIMARY KEY NOT NULL,
          kind TEXT NOT NULL,
          left_lineage_id TEXT NOT NULL,
          right_lineage_id TEXT,
          event_id TEXT REFERENCES events(id) ON DELETE RESTRICT,
          scope_json BLOB,
          provenance TEXT NOT NULL DEFAULT 'user',
          reason TEXT,
          is_active INTEGER NOT NULL DEFAULT 1,
          created_at REAL NOT NULL,
          revoked_at REAL
        ) STRICT
        """,
        """
        CREATE TABLE user_membership_decisions (
          id TEXT PRIMARY KEY NOT NULL,
          event_id TEXT NOT NULL REFERENCES events(id) ON DELETE RESTRICT,
          segment_lineage_id TEXT NOT NULL,
          decision TEXT NOT NULL,
          source_action TEXT NOT NULL,
          created_at REAL NOT NULL,
          revoked_at REAL
        ) STRICT
        """,
        """
        CREATE TABLE prompt_templates (
          id TEXT PRIMARY KEY NOT NULL,
          task TEXT NOT NULL UNIQUE,
          name TEXT NOT NULL,
          bundled_default_revision_id TEXT NOT NULL
        ) STRICT
        """,
        """
        CREATE TABLE prompt_revisions (
          id TEXT PRIMARY KEY NOT NULL,
          template_id TEXT NOT NULL REFERENCES prompt_templates(id) ON DELETE RESTRICT,
          parent_revision_id TEXT REFERENCES prompt_revisions(id) ON DELETE SET NULL,
          origin TEXT NOT NULL,
          body TEXT NOT NULL,
          variables_json BLOB NOT NULL,
          compatibility_json BLOB,
          created_at REAL NOT NULL
        ) STRICT
        """,
        """
        CREATE TABLE prompt_bindings (
          template_id TEXT PRIMARY KEY NOT NULL REFERENCES prompt_templates(id) ON DELETE CASCADE,
          active_revision_id TEXT NOT NULL REFERENCES prompt_revisions(id) ON DELETE RESTRICT,
          provider_route_json BLOB,
          updated_at REAL NOT NULL
        ) STRICT
        """,
        """
        CREATE TABLE generation_runs (
          id TEXT PRIMARY KEY NOT NULL,
          task TEXT NOT NULL,
          provider_id TEXT NOT NULL,
          model_id TEXT NOT NULL,
          prompt_revision_id TEXT NOT NULL REFERENCES prompt_revisions(id) ON DELETE RESTRICT,
          input_hash TEXT NOT NULL,
          policy_decision TEXT NOT NULL,
          consent_revision_id TEXT,
          usage_json BLOB,
          created_at REAL NOT NULL
        ) STRICT
        """,
        """
        CREATE TABLE claims (
          id TEXT PRIMARY KEY NOT NULL,
          event_revision_id TEXT REFERENCES event_revisions(id) ON DELETE RESTRICT,
          digest_revision_id TEXT,
          generation_run_id TEXT REFERENCES generation_runs(id) ON DELETE SET NULL,
          text TEXT NOT NULL,
          confidence REAL NOT NULL,
          support_state TEXT NOT NULL DEFAULT 'supported'
        ) STRICT
        """,
        """
        CREATE TABLE evidence_assertions (
          id TEXT PRIMARY KEY NOT NULL,
          claim_id TEXT NOT NULL REFERENCES claims(id) ON DELETE RESTRICT,
          item_revision_id TEXT NOT NULL REFERENCES item_revisions(id) ON DELETE RESTRICT,
          item_segment_id TEXT NOT NULL REFERENCES item_segments(id) ON DELETE RESTRICT,
          utf8_start INTEGER NOT NULL,
          utf8_length INTEGER NOT NULL,
          excerpt_hash TEXT NOT NULL,
          relationship TEXT NOT NULL,
          confidence REAL NOT NULL
        ) STRICT
        """,
        """
        CREATE TABLE digests (
          id TEXT PRIMARY KEY NOT NULL,
          briefing_day TEXT NOT NULL UNIQUE,
          current_revision_id TEXT NOT NULL
        ) STRICT
        """,
        """
        CREATE TABLE digest_revisions (
          id TEXT PRIMARY KEY NOT NULL,
          digest_id TEXT NOT NULL REFERENCES digests(id) ON DELETE RESTRICT,
          parent_revision_id TEXT REFERENCES digest_revisions(id) ON DELETE RESTRICT,
          reason TEXT NOT NULL,
          ranking_snapshot_json BLOB,
          created_at REAL NOT NULL
        ) STRICT
        """,
        """
        CREATE TABLE digest_entries (
          id TEXT PRIMARY KEY NOT NULL,
          digest_revision_id TEXT NOT NULL REFERENCES digest_revisions(id) ON DELETE RESTRICT,
          event_revision_id TEXT NOT NULL REFERENCES event_revisions(id) ON DELETE RESTRICT,
          section TEXT NOT NULL,
          rank INTEGER NOT NULL,
          score REAL NOT NULL,
          explanation_json BLOB NOT NULL,
          UNIQUE(digest_revision_id, section, rank)
        ) STRICT
        """,
        """
        CREATE TABLE event_read_states (
          event_id TEXT PRIMARY KEY NOT NULL REFERENCES events(id) ON DELETE CASCADE,
          last_seen_event_revision_id TEXT REFERENCES event_revisions(id) ON DELETE SET NULL,
          last_seen_ordinal INTEGER,
          last_seen_at REAL,
          manual_unread INTEGER NOT NULL DEFAULT 0
        ) STRICT
        """,
        """
        CREATE TABLE item_read_states (
          item_id TEXT PRIMARY KEY NOT NULL REFERENCES items(id) ON DELETE CASCADE,
          last_seen_item_revision_id TEXT REFERENCES item_revisions(id) ON DELETE SET NULL,
          last_seen_ordinal INTEGER,
          last_seen_at REAL,
          manual_unread INTEGER NOT NULL DEFAULT 0
        ) STRICT
        """,
        """
        CREATE TABLE app_preferences (
          key TEXT PRIMARY KEY NOT NULL,
          value_json BLOB NOT NULL,
          updated_at REAL NOT NULL
        ) STRICT
        """,
        """
        CREATE TABLE interactions (
          id TEXT PRIMARY KEY NOT NULL,
          action TEXT NOT NULL,
          target_kind TEXT NOT NULL,
          target_id TEXT NOT NULL,
          created_at REAL NOT NULL,
          metadata_json BLOB
        ) STRICT
        """,
        """
        CREATE TABLE user_interest_rules (
          id TEXT PRIMARY KEY NOT NULL,
          target_kind TEXT NOT NULL,
          target_id TEXT NOT NULL,
          weight REAL NOT NULL,
          is_active INTEGER NOT NULL DEFAULT 1,
          created_at REAL NOT NULL
        ) STRICT
        """,
        """
        CREATE TABLE saved_entries (
          id TEXT PRIMARY KEY NOT NULL,
          target_kind TEXT NOT NULL,
          target_id TEXT NOT NULL,
          folder_id TEXT,
          tags_json BLOB,
          saved_at REAL NOT NULL
        ) STRICT
        """,
        """
        CREATE TABLE jobs (
          id TEXT PRIMARY KEY NOT NULL,
          kind TEXT NOT NULL,
          input_hash TEXT NOT NULL,
          idempotency_key TEXT NOT NULL UNIQUE,
          payload BLOB NOT NULL,
          state TEXT NOT NULL,
          attempt_count INTEGER NOT NULL DEFAULT 0,
          cancellation_requested INTEGER NOT NULL DEFAULT 0,
          retry_class TEXT,
          checkpoint BLOB,
          next_attempt_at REAL NOT NULL,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL
        ) STRICT
        """,
        "CREATE INDEX jobs_ready ON jobs(state, next_attempt_at)",
        """
        CREATE TABLE job_leases (
          job_id TEXT PRIMARY KEY NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
          owner TEXT NOT NULL,
          token TEXT NOT NULL UNIQUE,
          acquired_at REAL NOT NULL,
          expires_at REAL NOT NULL
        ) STRICT
        """,
        """
        CREATE TABLE search_inputs (
          stable_id TEXT NOT NULL,
          kind TEXT NOT NULL,
          current_revision_id TEXT,
          language_code TEXT,
          title TEXT NOT NULL,
          body TEXT NOT NULL,
          normalized_fields_json BLOB,
          input_hash TEXT NOT NULL,
          updated_at REAL NOT NULL,
          PRIMARY KEY(kind, stable_id)
        ) WITHOUT ROWID, STRICT
        """,
        """
        CREATE TABLE derived_index_manifests (
          namespace TEXT PRIMARY KEY NOT NULL,
          canonical_input_generation INTEGER NOT NULL,
          indexed_generation INTEGER NOT NULL,
          descriptor_json BLOB,
          relative_path TEXT NOT NULL,
          promoted_at REAL
        ) STRICT
        """,
        """
        CREATE TABLE provider_configs (
          id TEXT PRIMARY KEY NOT NULL,
          provider_kind TEXT NOT NULL,
          display_name TEXT NOT NULL,
          keychain_reference BLOB,
          enabled INTEGER NOT NULL DEFAULT 1,
          configuration_json BLOB NOT NULL
        ) STRICT
        """,
        """
        CREATE TABLE consent_revisions (
          id TEXT PRIMARY KEY NOT NULL,
          source_id TEXT REFERENCES sources(id) ON DELETE RESTRICT,
          provider_id TEXT NOT NULL,
          content_privacy TEXT NOT NULL,
          allowed_tasks_json BLOB NOT NULL,
          granted_at REAL NOT NULL,
          revoked_at REAL
        ) STRICT
        """,
        """
        CREATE TABLE ai_cache (
          cache_key TEXT PRIMARY KEY NOT NULL,
          provider_id TEXT NOT NULL,
          model_id TEXT NOT NULL,
          prompt_revision_id TEXT NOT NULL REFERENCES prompt_revisions(id) ON DELETE RESTRICT,
          policy_decision TEXT NOT NULL,
          response BLOB NOT NULL,
          created_at REAL NOT NULL,
          expires_at REAL
        ) STRICT
        """,
        """
        CREATE TABLE tombstones (
          id TEXT PRIMARY KEY NOT NULL,
          target_kind TEXT NOT NULL,
          target_id TEXT NOT NULL,
          deletion_kind TEXT NOT NULL,
          permitted_metadata_json BLOB,
          created_at REAL NOT NULL,
          UNIQUE(target_kind, target_id)
        ) STRICT
        """
    ]
}
