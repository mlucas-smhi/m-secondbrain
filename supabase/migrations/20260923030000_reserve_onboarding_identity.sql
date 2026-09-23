-- Trusted provisioning may reserve identity IDs before a first call so its
-- empty memory store can be scoped correctly. Reservation is NOT verification:
-- no user, workspace, actor, identifier, or trust session exists until the
-- original single-use code checks succeed. Existing invites remain unchanged.
ALTER TABLE public.onboarding_invites
  ADD COLUMN provision_user_id uuid UNIQUE,
  ADD COLUMN provision_workspace_id uuid UNIQUE,
  ADD CONSTRAINT onboarding_invite_reserved_identity_pair CHECK (
    (provision_user_id IS NULL) = (provision_workspace_id IS NULL)
  );

-- Preserve the deployed verification logic and grants; change only ID
-- allocation after successful validation. Abort if the expected body changes.
DO $migration$
DECLARE
  definition text;
  allocation text := E'  v_user_id := gen_random_uuid();\n  v_workspace_id := gen_random_uuid();';
BEGIN
  definition := pg_get_functiondef(
    'public.verify_and_provision_onboarding_base(uuid,text,text,text,text,text,text,text)'::regprocedure
  );
  IF (length(definition) - length(replace(definition, allocation, ''))) <> length(allocation) THEN
    RAISE EXCEPTION 'Verification ID allocation differs; review before applying';
  END IF;
  EXECUTE replace(definition, allocation,
    E'  v_user_id := COALESCE(v_invite.provision_user_id, gen_random_uuid());\n  v_workspace_id := COALESCE(v_invite.provision_workspace_id, gen_random_uuid());');
END;
$migration$;

COMMENT ON COLUMN public.onboarding_invites.provision_user_id IS
  'Optional trusted reservation for an uncreated user. Does not authenticate or provision before valid code consumption.';
COMMENT ON COLUMN public.onboarding_invites.provision_workspace_id IS
  'Optional trusted reservation matching an empty memory scope; paired with provision_user_id.';
