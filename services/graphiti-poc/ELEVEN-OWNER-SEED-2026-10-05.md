# Eleven owner memory seed: preparation and hosting blocker

## Status

The user approved separately hosted Graphiti infrastructure and separately
credentialed storage for 11's real memories. No real memories have been uploaded
and no ElevenLabs agent connection has been changed.

Azure provisioning failed during preflight: the subscription has 20 public IP
addresses against a limit of 20, and the proposed database VM requires one more
for outbound package and image downloads. Only the empty resource group
`rg-eleven-graphiti-poc` was created. A subsequent resource listing returned no
resources. No existing addresses or network resources were repurposed.

Resolve the quota or approve an alternative egress design before retrying.

## Prepared seed

`github_seed.py` is an offline planner, not an uploader. The reviewed starter
selection is seven records: Michael Lucas, Pharr Andrews, Andrew Everett,
Curtis Miller, SEACOR management context, Alfred Memory System, and the Latin
America & Caribbean Scouting Tour.

The inspected source commit was
`9447c6485ed5a32a59214c7166ebd00031c785a3`. The planner records source path,
commit, blob, file hash and source dates. Source dates are not assumed to be
effective dates. It refuses selected files that differ from the selected commit.

Selected sections exclude retrieval instructions and known unfilled placeholders.
The credential tripwire is conservative, not a substitute for reviewing source
content before upload. Historical project architecture is source context, not
an instruction to the agent. Tentative travel plans are not bookings. Identity
aliases in the trip note need review before import.

Repeat safety distinguishes verified receipts, changed sources and ambiguous
prior submissions. An accepted queue submission is not proof of persistence.
There is no live import receipt yet.

## Intended isolation

- Resource group: `rg-eleven-graphiti-poc`.
- Resource prefix: `eleven-graphiti`.
- VNet: `10.43.0.0/16`; app subnet: `10.43.0.0/23`.
- Database subnet: `10.43.4.0/24`; database address: `10.43.4.4`.
- Proposed memory group: `eleven_owner_memory_v1`.
- Independent database and gateway credentials; do not reuse the synthetic
  deployment's database or edge credentials.

The templates now accept deployment tags and a memory group while preserving
the existing cook-off defaults. A group parameter alone is not an authorization
boundary.

## Gates before real import or agent activation

1. Provision isolated hosting with secure database transport and independent
   backups. The current private plaintext database transport is not approved
   here for uploading real memories.
2. Run a synthetic correction canary, including stale entity summaries and
   shared preference attributes observed in the Morgan test.
3. Review selected source facts, aliases, uncertainty and secret exclusions.
4. Import sequentially and verify completed writes and relationship readback.
5. Verify owner/guest access boundaries before connecting 11.

## Local checks

The Graphiti test suite passed 34 tests. All three Bicep templates compiled;
shell syntax and diff-whitespace checks passed. These checks do not establish
that hosting or a real-data import has succeeded.

## Shared-host alternative, prepared October 5

The user subsequently selected reuse of existing hosting without a new public
IP. Read-only checks of `graphiti-cookoff-db` found approximately 7 GB available
RAM and 30 GB free on its managed data disk. The existing database used about
25 MiB at that moment; this is not a workload capacity benchmark.

Prepared additive deployment:

- `owner-database.bicep` / `configure-owner-database.sh`: new
  `eleven-owner-falkordb` container, its own password and
  `/srv/graphiti/eleven-owner` directory. Refuses replacement or disk formatting.
  TLS-only private port 6380; 1.5 GiB container limit and 768 MiB Redis limit.
- `owner-app.bicep`: new `eleven-owner-graphiti` app in the existing environment,
  with separate edge credentials and the unchanged native Graphiti image.
- `tls_relay.py` / `OwnerTransport.Dockerfile`: a loopback-to-TLS transport
  sidecar because the pinned native database factory lacks TLS configuration.
  Verifies the database certificate and does not inspect or rewrite MCP tools.
- Planned narrow NSG rule: app subnet `10.42.0.0/23` to `10.42.4.4:6380` only.

The permission reviewer blocked the VM/network modification pending explicit
approval of repurposing this shared test host for real owner data. No owner
database, NSG change or app deployment has run. An ACR transport-image build
completed separately: run `cd1r`, image
`ca773a2b28d9acr.azurecr.io/eleven-owner/tls-relay@sha256:869b262f3640de1822bb68a3ce0527c1646cfd87882a5d8cd0f6f99c97e6d61b`.
The initial build omitted the new source due to the explicit `.dockerignore`
allowlist; that was corrected. Native TLS support in the database image and
end-to-end transport remain unverified.

Live read-only agent checks confirmed recognized-owner routing with the startup
code gate disabled and a separate guest agent with no MCP connectors. Owner 11
still has its previous LiteGraph configuration. No agent configuration changed.

Shared hosting separates processes, credentials and directories, not machine
administrators, kernel access, outages or storage failure. Independent backup,
source review, consistency canary and readback gates remain required. Certificate
renewal also needs an operational plan; the prepared server certificate lifetime
is 180 days, not an automatic renewal mechanism.
