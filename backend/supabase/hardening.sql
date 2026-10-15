-- Applied to project yrigwegtumlybprrhdgv after advisor review.
CREATE INDEX IF NOT EXISTS poi_suggestions_poi_id_idx ON pausepath.poi_suggestions(poi_id);
-- Supabase's existing event trigger remains functional; clients cannot invoke it.
REVOKE EXECUTE ON FUNCTION public.rls_auto_enable() FROM PUBLIC,anon,authenticated;
