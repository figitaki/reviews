WITH bounds AS (
  SELECT date_trunc('second', transaction_timestamp()) AT TIME ZONE 'UTC' AS finish
), events AS MATERIALIZED (
  SELECT r.inserted_at, r.author_id, 'reviews' AS kind
  FROM public.reviews r, bounds b
  WHERE r.inserted_at >= b.finish - interval '30 days' AND r.inserted_at < b.finish
  UNION ALL
  SELECT p.inserted_at, NULL::bigint, 'revisions'
  FROM public.patchsets p, bounds b
  WHERE p.inserted_at >= b.finish - interval '30 days' AND p.inserted_at < b.finish
  UNION ALL
  SELECT c.inserted_at, c.author_id, 'comments'
  FROM public.comments c, bounds b
  WHERE c.inserted_at >= b.finish - interval '30 days' AND c.inserted_at < b.finish
  UNION ALL
  SELECT d.inserted_at, d.author_id, 'decisions'
  FROM public.packet_section_decisions d, bounds b
  WHERE d.inserted_at >= b.finish - interval '30 days' AND d.inserted_at < b.finish
), windows AS (
  SELECT days, finish, finish - days * interval '1 day' AS start
  FROM (VALUES (7), (30)) d(days), bounds
), counts AS (
  SELECT w.days, w.start, w.finish,
    count(*) FILTER (WHERE e.kind = 'reviews') AS reviews,
    count(*) FILTER (WHERE e.kind = 'revisions') AS revisions,
    count(*) FILTER (WHERE e.kind = 'comments') AS comments,
    count(*) FILTER (WHERE e.kind = 'decisions') AS decisions,
    count(DISTINCT i.owner_user_id) AS active_accounts
  FROM windows w
  LEFT JOIN events e ON e.inserted_at >= w.start
  LEFT JOIN public.identities i ON i.id = e.author_id
  GROUP BY w.days, w.start, w.finish
)
SELECT json_build_object('version', 1, 'source', 'reviews aggregate endpoint v1',
  'collected_at', date_trunc('second', transaction_timestamp()), 'windows', json_agg(json_build_object(
    'days', days, 'start', start AT TIME ZONE 'UTC', 'end', finish AT TIME ZONE 'UTC',
    'active_accounts', active_accounts, 'reviews', reviews, 'revisions', revisions,
    'comments', comments, 'decisions', decisions) ORDER BY days)) FROM counts;
