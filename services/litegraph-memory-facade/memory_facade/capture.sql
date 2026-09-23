-- Private queue in the already-isolated POC schema. No public API grants.
CREATE TABLE IF NOT EXISTS litegraph_two_poc.memory_captures (
  id uuid PRIMARY KEY,
  workspace_id text NOT NULL,
  owner_ref text NOT NULL,
  source_session_ref text NOT NULL,
  source_thread_ref text NOT NULL,
  request_digest text NOT NULL,
  content text NOT NULL,
  context text NOT NULL,
  state text NOT NULL DEFAULT 'pending'
    CHECK (state IN ('pending','processing','complete','partial','needs_attention')),
  plan jsonb,
  attempts integer NOT NULL DEFAULT 0,
  lease_token uuid,
  lease_until timestamptz,
  available_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  error_code text,
  CHECK (length(content) BETWEEN 1 AND 24000),
  CHECK (length(context) <= 4000)
);
CREATE INDEX IF NOT EXISTS memory_captures_pending
 ON litegraph_two_poc.memory_captures(workspace_id,owner_ref,created_at)
 WHERE state IN ('pending','processing');
REVOKE ALL ON litegraph_two_poc.memory_captures FROM PUBLIC;
