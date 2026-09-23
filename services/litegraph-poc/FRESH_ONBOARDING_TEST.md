# Fresh onboarding acceptance test

Do not reset the live POC until the durable database passes the replacement
test. Scope all resets to the selected 2 POC workspace/graph. Keep the old
graph and identity-state export offline for recovery, never as new-call context.

## Storage gate

1. Create a consistent source backup; copy outside the container.
2. Verify backup checksum and SQLite integrity, plus record counts.
3. Configure a separate persistent PostgreSQL database or isolated schema/role.
   Use TLS, secret references, bounded connection pooling, and no anonymous API
   exposure. Do not put PostgreSQL files or SQLite on the existing SMB share.
4. Write a synthetic sentinel in a test graph through the facade, replace the
   container, then retrieve exactly that sentinel from the new replica.
5. Back up and remove the sentinel/test graph before real onboarding. Never
   count a mere healthy HTTP endpoint as a successful persistence test.

## Clean-start gate

- Snapshot the exact workspace's onboarding, identifiers, sessions, and invite
  state before reset. Do not delete unrelated users, GitHub, or Eleven data.
- No seeded people or facts in the new authorized graph.
- A fresh single-use code starts onboarding. Never revive a consumed invite.
- First call greets once; unverified callers cannot read/write personal memory.
- A verified returning number resumes without another invite-code challenge.
- Persist topic/checkpoint only after authorized saves succeed. Explicitly
  distinguish the last completed topic from an in-progress topic.

## Natural capture and recall

During a call, supply several real particulars about one person naturally:
dietary preference, interest/hobby, role, location, and communication preference.
Do not instruct the agent to remember them. Include unimportant chatter such as
"he emailed me last week" as a negative control.

Pause and hang up. On a fresh call ask "What have we said about Andrew so far?"
Then add a new particular without a save command. Hang up and call again.

Pass criteria:
- Every important directly stated particular is present in stored records.
- Facts belong to the same canonical person, including spoken-name variants.
- No unsupported inferences and no false precision (vegan != vegetarian).
- Transient chatter is not saved absent a meaningful underlying fact/task.
- Recaps reflect retrieved facts, including the newly added detail.
- Stored source session/thread and successful write results are auditable.
- Ambiguous identities prompt clarification, not silent merges.
- Save failures are disclosed; no false claims of a complete profile/checkpoint.

Verify records after each call independently of what the agent says. Record
missing-capture, wrong-entity, storage-error, and retrieval-error failures
separately. Passing mock tests does not replace this live acceptance test.
