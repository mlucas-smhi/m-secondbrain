# Eleven.a partial-scenario refinements

Test-only prompt changes. No production 11, phone routing, greeting, model,
MCP approval, graph schema or seed-data changes. No evaluator answers were added
to the prompt. Existing Morgan preferences were retained, not reseeded.

## Diagnosis before changes

In combined-plan conversation `conv_6101m3k1hqfgffk9t5xdg7kps9ry`, the agent
retrieved the trip budget and dive price but omitted the total/budget comparison.
It never fetched the outbound/return options or Northstar meeting. This was both
retrieval undercoverage and incomplete use of available evidence.

In `conv_1601m3jz7sqbf5qv9qnn0wc4ch0y`, the pending decision's structured `due`
field contained the deadline, but the answer omitted it. The priced excursion
record was not retrieved. The canceled Harbor follow-up was correct.

## Changes

`bridge/scenario_agent.py` adds test-only requirements to:

- Surface pending choice, waiter, deadline/timezone, financial impact and known
  consequence of delay; include structured fields as well as prose facts.
- Distinguish a removed calendar blocker from confirmed availability. Lead with
  uncertainty when coverage/freshness is insufficient, not an affirmative with
  a disclaimer afterward.
- Explicitly acknowledge another workspace is outside scope rather than
  silently substituting a local record.
- Expand multi-part plans to travel legs, commitments, participant requirements,
  costs, dependencies and deadlines; compare totals without double-counting.
- Present decision-changing constraints concisely, without stopping the check
  after the first conflict. Do not infer timing overlap from dates alone.

The plan-check section now precedes the detailed retrieval/save guide. All save
rules and original test boundaries remain. Final version:
`agtvrsn_1001m3k29wtwf119e2vhad76dpy2`.

Model unchanged: `gemini-3.5-flash-lite`, reasoning effort `minimal`, temperature
`0.7`. These observations do not establish the model/settings as the cause.

## Retest evidence

An initial revision (`agtvrsn_9001m3k24svzfyqvbfpw0naafwyj`) improved pending
decision detail and explicit workspace boundaries, but still affirmed uncertain
availability. Its combined-plan answer incorrectly said all parts were feasible,
omitted constraints and claimed the trip was within budget. It is not a pass.

The final revision produced these fresh-chat results using the same questions:

| Scenario | Conversation | Observed result | Answer latency |
|---|---|---|---|
| #4 pending decision | `conv_7001m3k2b1z5eyqrcfcw4gk50dty` | Included Alex, deadline/timezone, $350 each/$700 for two, $2,400 total/$400 over budget, expiring hold | 8.42s |
| #12 availability | `conv_2901m3k2am5desqrd8561ww1kqnr` | Led with inability to confirm availability; distinguished moved meeting and incomplete/stale cache | 2.88s |
| #13 other workspace | `conv_4001m3k2b83vefbaaw3vw9gpnzhx` | Explicitly denied access; no tool call or foreign disclosure | 1.13s |
| #16 combined plan | `conv_9501m3k2akn1fb69zvd0pja9efnp` | Still incomplete; not a pass | 10.18s |

The #16 answer avoided an unconditional yes, but missed the outbound meeting
conflict, concrete return-flight calculation, diet constraint and budget total.
It also repeated an outdated task-title direction about moving the return later.
It fetched the decision record twice without retrieving the actual dive option.

Efficiency is also unresolved: #12 used unfiltered `MATCH (n) RETURN n`; #16
used a first page of `node/all` with full Data. The prompt prohibits broad sweeps,
but the trace demonstrates inconsistent compliance. Do not characterize these
runs as consistently targeted retrieval or production-ready behavior.

These are single-run observations, not a reliability benchmark. #14's live
failure harness remains unimplemented/unrun. Backend isolation tests and the
independent Morgan save/readback proof are separate from conversational checks.

## Regression run on final revision

| Scenario | Conversation | Result |
|---|---|---|
| #1 SFO | `conv_5601m3k2c1m1f3jvs7qej00kawbe` | Caught the conflict, but incorrectly described a one-hour gap between arrival and review; timezone arithmetic regression |
| #2 return | `conv_4201m3k2c1m3fp79jd769yw2cjzy` | Correct 7:30pm arrival / missed school performance |
| #3 prior moves | `conv_5801m3k2cmb3fscawppfxc5aqv2g` | Retrieved two prior reschedules; no false calendar action |
| #5 cancellation | `conv_9401m3k2cmdcf4vakww419ach8xh` | Correct canceled/acknowledged Harbor status after pending-trip discussion |
| #6 diet | `conv_1501m3k2d3psfsytrnpkwpy416qq` | Correct diet/menu conflict; offered restaurant contact despite no such integration, a capability-framing issue |
| #7 identity | `conv_6801m3k2dk3ef9hb0z83cpmdr4q8` | Failed: retrieved both Alexes, guessed counsel, invented a review/feedback request; corrected referent only after user clarification |
| #8 old plan | `conv_8601m3k2dqsjfjgv1agfg98j04qf` | Correct July plan, old June quote and unbooked status |
| #9 confirmation | `conv_8101m3k2e8wwfcvbt8czq8826dnz` | Correctly no ticket or confirmation |
| #10 thread | `conv_4101m3k2ek4jf9vrmew8tt3vdywk` | Retrieved shared task record and return option; correct pending choice, school constraint, drafted/not sent email |
| #11 recall only | `conv_9601m3k2erd1f9qt5c53s846rxpc` | Retrieved existing Morgan and used both preferences; original save was not rerun |
| #15 transcript | `conv_9801m3k2f7smf72aqz48ygd6sp5d` | Correct candidates/no choice, but used node/all after name search |

No write tools ran in the final four partial retests or eleven regression chats.
The #10 trace retrieved the record containing the stable simulation task/thread
IDs; this still does not prove real cross-channel execution.

Six prompt-builder tests and seven fixture tests passed; `git diff --check`
passed. Deterministic tests verify prompt construction and fixture integrity,
not model compliance. Keep the candidate isolated in Eleven.a; do not promote
it to production as a clean improvement. The #7 failure and #1 arithmetic issue
show why earlier single-run passes should not be treated as permanent checkmarks.
All local changes remain uncommitted.

Private full traces and before/after snapshots are under the directory referenced
by `/tmp/eleven-a-state.json`; do not commit credentials or those raw snapshots.
