-- Provider-neutral tool substrate. Task steps ask for capabilities; runtime
-- configuration selects an MCP/API/native adapter without changing the graph.

CREATE TABLE public.tool_adapters (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid NOT NULL REFERENCES public.workspaces(id) ON DELETE CASCADE,
  adapter_key text NOT NULL,
  provider text NOT NULL,
  transport text NOT NULL,
  status text NOT NULL DEFAULT 'active',
  capabilities text[] NOT NULL,
  credential_ref text,
  configuration jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (workspace_id, adapter_key),
  UNIQUE (id, workspace_id),
  CONSTRAINT tool_adapters_key_check CHECK (btrim(adapter_key) <> ''),
  CONSTRAINT tool_adapters_provider_check CHECK (btrim(provider) <> ''),
  CONSTRAINT tool_adapters_transport_check CHECK (
    transport IN ('mcp', 'api', 'native', 'browser')
  ),
  CONSTRAINT tool_adapters_status_check CHECK (
    status IN ('active', 'disabled', 'degraded')
  ),
  CONSTRAINT tool_adapters_capabilities_check CHECK (
    cardinality(capabilities) > 0
    AND array_position(capabilities, NULL) IS NULL
  ),
  CONSTRAINT tool_adapters_credential_ref_check CHECK (
    credential_ref IS NULL OR btrim(credential_ref) <> ''
  ),
  CONSTRAINT tool_adapters_configuration_check CHECK (
    jsonb_typeof(configuration) = 'object'
  )
);

CREATE TABLE public.task_step_tool_requirements (
  task_id uuid NOT NULL REFERENCES public.tasks(id) ON DELETE CASCADE,
  step_id uuid NOT NULL,
  capability text NOT NULL,
  access_mode text NOT NULL DEFAULT 'read',
  required boolean NOT NULL DEFAULT true,
  preferred_adapter_id uuid,
  constraints jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (step_id, capability),
  FOREIGN KEY (step_id, task_id)
    REFERENCES public.task_steps(id, task_id) ON DELETE CASCADE,
  FOREIGN KEY (preferred_adapter_id)
    REFERENCES public.tool_adapters(id) ON DELETE RESTRICT,
  CONSTRAINT task_step_tool_requirements_capability_check CHECK (
    btrim(capability) <> ''
  ),
  CONSTRAINT task_step_tool_requirements_access_check CHECK (
    access_mode IN ('read', 'hold', 'execute')
  ),
  CONSTRAINT task_step_tool_requirements_constraints_check CHECK (
    jsonb_typeof(constraints) = 'object'
  )
);

CREATE TABLE public.task_step_tool_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id uuid NOT NULL REFERENCES public.tasks(id) ON DELETE CASCADE,
  step_id uuid NOT NULL,
  adapter_id uuid NOT NULL REFERENCES public.tool_adapters(id) ON DELETE RESTRICT,
  capability text NOT NULL,
  operation text NOT NULL,
  status text NOT NULL DEFAULT 'running',
  idempotency_key text NOT NULL,
  external_run_id text,
  request_summary jsonb NOT NULL DEFAULT '{}'::jsonb,
  result_ref text,
  evidence jsonb NOT NULL DEFAULT '{}'::jsonb,
  error text,
  started_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  UNIQUE (step_id, idempotency_key),
  FOREIGN KEY (step_id, task_id)
    REFERENCES public.task_steps(id, task_id) ON DELETE CASCADE,
  CONSTRAINT task_step_tool_runs_capability_check CHECK (btrim(capability) <> ''),
  CONSTRAINT task_step_tool_runs_operation_check CHECK (btrim(operation) <> ''),
  CONSTRAINT task_step_tool_runs_status_check CHECK (
    status IN ('running', 'completed', 'failed', 'cancelled')
  ),
  CONSTRAINT task_step_tool_runs_idempotency_check CHECK (btrim(idempotency_key) <> ''),
  CONSTRAINT task_step_tool_runs_request_check CHECK (
    jsonb_typeof(request_summary) = 'object'
  ),
  CONSTRAINT task_step_tool_runs_evidence_check CHECK (
    jsonb_typeof(evidence) = 'object'
  ),
  CONSTRAINT task_step_tool_runs_completion_check CHECK (
    (status = 'running' AND completed_at IS NULL)
    OR (status <> 'running' AND completed_at IS NOT NULL)
  )
);

CREATE INDEX tool_adapters_capabilities_idx
  ON public.tool_adapters USING gin (capabilities)
  WHERE status = 'active';
CREATE INDEX task_step_tool_runs_step_idx
  ON public.task_step_tool_runs (step_id, started_at, id);

CREATE TRIGGER tool_adapters_updated_at
  BEFORE UPDATE ON public.tool_adapters
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

ALTER TABLE public.tool_adapters ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.task_step_tool_requirements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.task_step_tool_runs ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.tool_adapters,
  public.task_step_tool_requirements,
  public.task_step_tool_runs
  FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.tool_adapters,
  public.task_step_tool_requirements,
  public.task_step_tool_runs
  TO service_role;
