# Native ontology rollout — 2026-10-01

## Deployment

Committed source: `2a68f8c`.
Ontology: `ea-graphiti.v1`.
Ontology JSON SHA-256:
`27b21aafef0532eec940a18274997ff740d0a3702f67954eb7942defeec28c7e`.

ACR build `cd1n` succeeded for linux/amd64. Deployed image:
`ca773a2b28d9acr.azurecr.io/graphiti-cookoff/mcp@sha256:01d6c6c9b971d18b524dbd14cdf68db328dc42cacb73fbf9d059f03e070fe378`.

Only the `graphiti` container image in `graphiti-cookoff-mcp`, resource group
`rg-graphiti-cookoff-poc`, was updated. Revision
`graphiti-cookoff-mcp--0000001` became the latest ready revision with 100% ingress
traffic. Startup logs listed all 21 domain entity and 31 relationship types.
Existing secrets, gateway, database, models, production agents and routing were
not changed. No agent is connected to this endpoint yet.

HTTPS health, unauthorized MCP denial and native database status passed after
rollout. Sixteen offline tests passed again. Image vulnerability scanning remains
unverified (see the initial rollout's Docker Scout login limitation).

## Live extraction test: partial, not a full pass

Used only the first episode string from `ontology-acceptance.json` case
`one-person-many-relationships`. No evaluator checks, expected answers, extra
`custom_extraction_instructions`, or pre-created entities were submitted.

- Fresh synthetic group: `ea_ontology_2a68f8c_multi_v1`.
- Episode: `one-person-many-relationships-v1`.
- Generated episode ID: `dbd1cfc3-82fa-40c4-9473-7057cc8a657f`.
- Submitted at 17:47:22 UTC; acceptance round trip 0.101s.
- Provenance observed 28.79s after submission; provenance query took 0.195s.
  This is an observation bound, not exact extraction duration.
- A separate MCP session's native fact search returned the four edges in 0.456s.

Input describes fictional Rowan as Casey's partner, Juniper and Eli's parent,
Meridian Studio's CFO, vegetarian, a weekend hiking enthusiast, with a May 12
partnership anniversary (no year given).

| Expected representation | Observed result |
| --- | --- |
| One Rowan Person across roles | Pass: `8ffeb2d4-74f2-4d61-b2fe-bf8bdab2e3cc` |
| PartnerOf Rowan -> Casey | Pass |
| ParentOf Rowan -> Juniper | Pass |
| ParentOf Rowan -> Eli | Pass |
| WorksFor Rowan -> Meridian Studio, role CFO | Pass, including edge attribute `role` |
| HasDietaryPreference -> Vegetarian | Missing; no Preference node |
| Enjoys -> Hiking, weekends | Missing; no Activity node |
| PartnerOf anniversary_date May 12, unknown year | Missing; partnership had only `relationship_kind` |
| Do not infer Casey is the children's parent or assert marriage | No such assertions observed |

Result: five nodes (four people and one organization), four typed edges. This
demonstrates multiple relationships on one entity, **not exhaustive capture**.
The dietary, hobby and anniversary details remain in the original episode text
but are absent from extracted nodes/edges/attributes and from the returned
summaries. Do not describe raw episode retention as structured recall success.

The type schema supplies available vocabulary and attributes; it does not force
the extractor to materialize all supplied facts. Upstream text extraction also
instructs the model to exclude abstract concepts, generic words and adjectives.
That may contribute to missing preference/activity nodes, but this single run
does not establish causation. The anniversary omission is a separate coverage
failure and should not be explained away by the missing nodes.

## Guided comparison: first case passes, 18:00 UTC

The exact same paragraph, reference time and source description were submitted
to fresh group `ea_ontology_2a68f8c_guided_v1`. The deployed image, schema and
models were unchanged. The only extraction input change was native
`custom_extraction_instructions`: existing catalog rules plus the general policy
in `extraction-guidance.txt`, assembled by `extraction.py`. No expected names,
trait values or dates were put into the policy. No manual graph repairs occurred.

- Guidance SHA-256: `ad10f927516da43c8df726e305694304cc2eca5da21c79c706a958eb9240b968`.
- Episode: `15c07d17-f360-49ae-937e-83c8293d8c06`.
- One Rowan: `0e33d5a4-020a-4242-bd31-cee882dfcc82`.
- Seven nodes: four people, organization, Preference vegetarian, Activity hiking.
- Six edges: PartnerOf, two ParentOf, WorksFor, HasDietaryPreference, Enjoys.
- PartnerOf fact preserves May 12 and unknown year; `anniversary_date: 05-12`.
- WorksFor retains `role: CFO`; Enjoys retains `frequency: weekends`.
- All six edges reference the submitted episode and originate from the same
  Rowan. No Casey parenthood, marriage or separate role-person was observed.
- Queue acknowledgment: 0.112s. Provenance observed at +45.19s, queried in 0.200s.
  This is an upper observation bound, **not measured extraction duration**.
- New-session fact recall: 0.968s, all six edges and attributes returned.
- Assertions on the saved provenance and recall responses passed. Eighteen
  offline tests passed; these are not eighteen live extraction tests.

This single guided trial passes the first case, not the entire acceptance suite
or a statistical reliability test. The policy is applied by this evaluation
caller only; other native MCP writes do not automatically inherit it. No agent
has been connected or modified. `ontology.json` and the deployed schema hash
above remain unchanged.

The known `NoneType` database-client error recurred on the pre-write empty-group
check. No episode was submitted at that point. Restarting only the isolated
revision `graphiti-cookoff-mcp--0000001` restored operation before the guided
submission. This remains an unresolved connection/recovery problem.

## Open issues and next gate

- Before rollout the old revision again returned the native database-client
  `NoneType` error after idle time. The new revision was healthy. Reconnect/idle
  recovery remains unproven; a new image/startup is not a permanent fix.
- The first guided test recovered the missing person traits and anniversary.
  Repeat across varied wording and test corrections before treating extraction
  as dependable; keep groups, policy and source provenance explicit.
- Do not inject expected test answers into ingestion or manually add missing
  edges and call that an extraction pass.
- Then test adding a child in a later episode without losing identity or earlier
  relationships. The other seven acceptance cases have not run.
- Do not switch an agent on the strength of one passing case. No existing test
  graph was cleared or reinterpreted.

This file records evidence; it does not change the committed ontology or deploy
another revision. The rollout documentation updates require a separate commit.
