-- $1: the MCP resource identifier; $2/$3: known connector client IDs and app names.
WITH bounds AS (
  SELECT date_trunc('second', transaction_timestamp()) AT TIME ZONE 'UTC' AS finish
), events AS MATERIALIZED (
  SELECT r.inserted_at, r.author_id, NULL::text AS owner, 'reviews' AS kind
  FROM public.reviews r, bounds b
  WHERE r.inserted_at >= b.finish - interval '30 days' AND r.inserted_at < b.finish
  UNION ALL
  SELECT p.inserted_at, NULL::bigint, NULL, 'revisions'
  FROM public.patchsets p, bounds b
  WHERE p.inserted_at >= b.finish - interval '30 days' AND p.inserted_at < b.finish
  UNION ALL
  SELECT c.inserted_at, c.author_id, NULL, 'comments'
  FROM public.comments c, bounds b
  WHERE c.inserted_at >= b.finish - interval '30 days' AND c.inserted_at < b.finish
  UNION ALL
  SELECT d.inserted_at, d.author_id, NULL, 'decisions'
  FROM public.packet_section_decisions d, bounds b
  WHERE d.inserted_at >= b.finish - interval '30 days' AND d.inserted_at < b.finish
  UNION ALL
  SELECT u.inserted_at, NULL, NULL, 'signups'
  FROM public.users u, bounds b
  WHERE u.inserted_at >= b.finish - interval '30 days' AND u.inserted_at < b.finish
  UNION ALL
  SELECT g.inserted_at, NULL, NULL, 'mcp_connections'
  FROM public.gatekeep_grants g, bounds b
  WHERE g.resource = $1
    AND g.inserted_at >= b.finish - interval '30 days' AND g.inserted_at < b.finish
  UNION ALL
  -- last_used_at is a grant's latest use, so a use inside a window means activity in it.
  SELECT g.last_used_at, NULL, g.owner, 'mcp_use'
  FROM public.gatekeep_grants g, bounds b
  WHERE g.resource = $1
    AND g.last_used_at >= b.finish - interval '30 days' AND g.last_used_at < b.finish
), windows AS (
  SELECT days, finish, finish - days * interval '1 day' AS start
  FROM (VALUES (7), (30)) d(days), bounds
), counts AS (
  SELECT w.days, w.start, w.finish,
    count(*) FILTER (WHERE e.kind = 'reviews') AS reviews,
    count(*) FILTER (WHERE e.kind = 'revisions') AS revisions,
    count(*) FILTER (WHERE e.kind = 'comments') AS comments,
    count(*) FILTER (WHERE e.kind = 'decisions') AS decisions,
    count(*) FILTER (WHERE e.kind = 'signups') AS signups,
    count(*) FILTER (WHERE e.kind = 'mcp_connections') AS mcp_connections,
    count(DISTINCT i.owner_user_id) AS active_accounts,
    count(DISTINCT e.owner) FILTER (WHERE e.kind = 'mcp_use') AS mcp_active_accounts
  FROM windows w
  LEFT JOIN events e ON e.inserted_at >= w.start
  LEFT JOIN public.identities i ON i.id = e.author_id
  GROUP BY w.days, w.start, w.finish
), apps AS (
  SELECT a.app, a.ord FROM unnest($3::text[]) WITH ORDINALITY a(app, ord)
  UNION ALL
  SELECT 'Unrecognized', 2147483647
), connected AS (
  -- Connected now: not revoked and not expired. Only configured app names leave the database.
  SELECT COALESCE(k.app, 'Unrecognized') AS app, g.owner
  FROM public.gatekeep_grants g
  CROSS JOIN bounds b
  LEFT JOIN unnest($2::text[], $3::text[]) k(client_id, app) ON k.client_id = g.client_id
  WHERE g.resource = $1 AND g.revoked_at IS NULL
    AND (g.expires_at IS NULL OR g.expires_at > b.finish)
), clients AS (
  SELECT a.app, a.ord, count(c.app) AS connections, count(DISTINCT c.owner) AS accounts
  FROM apps a LEFT JOIN connected c ON c.app = a.app
  GROUP BY a.app, a.ord
)
SELECT json_build_object('version', 2, 'source', 'reviews aggregate endpoint v2',
  'collected_at', date_trunc('second', transaction_timestamp()),
  'accounts', (SELECT count(*) FROM public.users),
  'mcp_clients', (SELECT json_agg(json_build_object(
    'app', app, 'connected_accounts', accounts, 'connections', connections) ORDER BY ord)
    FROM clients),
  'windows', (SELECT json_agg(json_build_object(
    'days', days, 'start', start AT TIME ZONE 'UTC', 'end', finish AT TIME ZONE 'UTC',
    'active_accounts', active_accounts, 'reviews', reviews, 'revisions', revisions,
    'comments', comments, 'decisions', decisions, 'signups', signups,
    'mcp_connections', mcp_connections, 'mcp_active_accounts', mcp_active_accounts)
    ORDER BY days) FROM counts));
