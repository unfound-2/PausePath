-- The API uses a direct database connection as table owner. No client Data API
-- policies are granted: all writes must go through authenticated FastAPI routes.
DO $$
DECLARE table_name text; role_name text;
BEGIN
    FOREACH table_name IN ARRAY ARRAY['pois','poi_reports','poi_suggestions',
        'moderation_audit','osm_edit_queue','commercial_place_links',
        'api_request_receipts','api_rate_buckets','schema_migrations'] LOOP
        -- Integration fixtures can apply migrations without the migration ledger.
        IF to_regclass(format('%I.%I',current_schema(),table_name)) IS NULL THEN CONTINUE; END IF;
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY',table_name);
        EXECUTE format('REVOKE ALL ON TABLE %I FROM PUBLIC',table_name);
        FOREACH role_name IN ARRAY ARRAY['anon','authenticated'] LOOP
            IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname=role_name) THEN
                EXECUTE format('REVOKE ALL ON TABLE %I FROM %I',table_name,role_name);
            END IF;
        END LOOP;
    END LOOP;
    EXECUTE format('REVOKE ALL ON FUNCTION %I.update_poi_confidence(uuid) FROM PUBLIC', current_schema());
    EXECUTE format('REVOKE ALL ON FUNCTION %I.guard_poi_report() FROM PUBLIC', current_schema());
    EXECUTE format('REVOKE ALL ON FUNCTION %I.report_confidence_trigger() FROM PUBLIC', current_schema());
END $$;
-- Keep the legacy Google-ID table for migration compatibility, but no endpoint
-- uses it. Mapbox data (including IDs) is request-scoped and never stored here.
