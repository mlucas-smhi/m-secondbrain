# 11 trust policy

This directory is the version-controlled source for 11's deterministic trust
policy. It contains no live identities, credentials, voiceprints, phone
numbers, transcripts, or customer data.

The policy separates three independent concerns:

- `sensitivity_level`: 1 shared, 2 confidential, 3 private/restricted.
- `risk_level`: 0 informational through 5 privileged/high-impact action.
- `minimum_auth_assurance`: 0 unidentified through 4 stepped-up authentication.

Compartments further restrict access. A higher clearance does not grant access
to an unrelated compartment. `read`, `use`, and `disclose` are separate
permissions.

`policy.v1.json` is installed into Supabase by the matching migration. Runtime
decisions record the immutable policy version and content hash. Changing policy
requires a new version rather than editing an active database row.

Live identity and authorization records belong in Supabase. Conversational
memory will sit behind a policy-enforcing gateway and may move from the current
Git adapter to LiteGraph without changing this contract.
