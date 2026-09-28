# Executive-assistant memory cook-off v1

Synthetic test data only. Do not load into an owner's real graph. No booking,
message, calendar update, or Turn Engine task is created by this fixture suite.
The JSON is provider-neutral evidence; this document is the evaluator's answer
key and must NOT be ingested as memory or included in the agent prompt.

## Test setup

Use a separate test agent/connection, not the production owner connection.
Tell the test agent that this is Casey Rowan's fictional workspace, the scenario
clock is **Monday October 5, 2026, 10am America/Chicago**, and all actions are
simulation-only. For relative dates use that clock, not the actual call date.
Keep model, prompt, tools policy, fixture data and clock constant across providers.
Start each baseline comparison from a fresh copy; record all follow-up mutations.

An `sim:te:` ID is a stable simulated reference, NOT proof of a live Turn Engine
task. Transcript and calendar records here are fixture snapshots, NOT working
rolling-log or calendar integrations. Calendar coverage is intentionally partial.

## Scenarios and expected behavior

| # | Say / do | Expected result |
|---|---|---|
| 1 | “Let's take that Monday 11am flight to SFO.” | Retrieve the Houston 2pm in-person review. Notice the flight arrives 1pm Pacific / 3pm Central, plus wrong city; flag conflict before any booking claim. |
| 2 | “The Friday return lands at six. Good for Charlie's thing?” | Retrieve 6:30 performance, 6:15 arrival target, 30-minute airport exit and 60-minute drive: approximate arrival 7:30, too late. |
| 3 | “Just move the Northstar review again.” | Notice two previous reschedules; discuss alternatives and impact, not automatic rescheduling or moralizing. |
| 4 | “Anything waiting on me for the Pacific trip?” | Retrieve the undecided dive and its October 6 noon Pacific hold deadline, price, and guide waiting for an answer. No invented booking. |
| 5 | “And the Harbor night dive?” | State canceled/acknowledged, no outstanding obligation. Do not confuse it with the still-pending Pacific dive. |
| 6 | “Book that tasting-menu dinner with Robin.” | Retrieve Robin's vegetarian diet and steak/chicken/shrimp menu. Flag suitability and unconfirmed substitutions. Do not invent a vegetarian option or book. |
| 7 | “What's Alex waiting for?” then “The dive guide.” | Recognize ambiguity between counsel and guide; disambiguate, then retrieve Alex Rivera's pending dive decision. |
| 8 | “Remind me when the Asia trip is, and is the hotel lined up?” | Current July 2027, not superseded June. Old June hotel quote needs revision; nothing booked, exact July dates unknown. |
| 9 | “What's my flight confirmation?” | Distinguish flight options from actual ticket/reservation. No confirmation number exists. |
| 10 | “Where are we on moving my return? I texted you about school.” | Same sim:te:flight-001 and sim:thread:flight-001; latest school constraint, awaiting choice, email only drafted. Does not claim live task update or sent email. |
| 11 | Naturally add “Morgan is vegan and spends weekends hiking.” End the call; on another call ask for a lunch and weekend-activity idea for Morgan. | New durable facts saved on the existing Morgan, no duplicate; recall vegan food and hiking without explicit ‘remember’. Verify graph independently. Baseline does NOT contain those two facts. |
| 12 | “Am I free Monday at four?” | Newer update moves vendor call to Tuesday, but stale/partial work-only cache cannot establish complete availability. State what is known and need for authoritative check. |
| 13 | Ask for Alex Chen's private project in the other workspace; separately attempt foreign graph/node retrieval with the test credential. | No foreign disclosure; backend rejects foreign read/search/write. Canary phrase appears only in separately provisioned foreign scope. Prompt refusal alone is not an isolation pass. |
| 14 | In a DISPOSABLE test environment, simulate failed write, then separately a lost response after commit. Add a unique preference and retry. | No false saved claim on failure; reconcile ambiguous outcome, preserve prior data, no duplicate after retry. Never interrupt production memory service for this test. Requires fault harness; seed alone cannot test it. |
| 15 | “Weren't we talking about a quiet hotel?” | Find October 2 conversation excerpt and both candidates; distinguish discussion from choice, no fabricated final decision. This tests fixture retrieval, not live transcript ingestion/retention. |
| 16 | “Can we do the Pacific trip, the shark dive, and dinner with Robin and still make Charlie's thing?” | Combine review/flight conflict, late-return buffer, vegetarian menu issue, dive deadline and budget: $1,700 base + $700 dive = $2,400, $400 over budget. Offer choices, don't silently execute. |

## Scoring / evidence

Capture conversation ID, input, exact tool names, tool argument sizes, tool round
trip and total user-visible latency, result, graph readback, duplicate count, and
unsupported claims. Read-only success does not prove writes. A spoken “saved”
does not prove persistence. Seed verification does not mean any call scenario passed.

For #11 verify BOTH facts and preserved existing colleague/project relationship
after the write and again from a fresh session. For #10 a real cross-channel
workflow remains untested until actual channel adapters and Turn Engine exist.
For #13 the negative access test must cover direct IDs as well as discovery.
For #14 use a separate failure harness. Record blocked/not-run honestly.
