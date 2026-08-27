---
type: system
document: taxonomy
version: 1.0
status: active
created: 2026-08-27
updated: 2026-08-27
owner: Michael Lucas
---

# Knowledge Taxonomy

## Purpose

This document defines the approved knowledge model for the m-secondbrain repository.

Its purpose is to:

- Keep the repository predictable
- Prevent category sprawl
- Separate durable knowledge from temporary conversation
- Give Alfred deterministic rules for classifying information
- Support reliable startup retrieval and contextual retrieval
- Preserve knowledge in a human-readable and platform-independent format

GitHub is the canonical system of record.

Obsidian is a human interface for viewing and editing the repository.

Alfred may only create notes using the approved types defined in this document.

## Core Principles

1. Store durable knowledge, not raw conversation.
2. Prefer updating an existing note over creating a duplicate.
3. Use the narrowest valid note type.
4. Do not invent new types, folders, statuses, or metadata values.
5. Preserve the distinction between facts, ideas, decisions, and actions.
6. Record uncertainty explicitly.
7. Do not present assumptions as facts.
8. Link related entities whenever associations are known.
9. Keep reference notes concise.
10. Keep detailed facts in the appropriate entity note.
11. The Git repository is canonical. Interfaces and indexes are replaceable.
12. When information does not deserve long-term retention, do not write it.

# Approved Note Types

The approved note types are:

- Reference
- Person
- Pet
- Project
- Decision
- Meeting
- Incident
- Runbook
- Learning
- Event
- Idea
- Task

No additional note types are permitted.

When classification is uncertain, use the routing rules and examples in this document.

If no approved type fits, do not create a note. Record the rejected item in processing logs only if logging is enabled.

# Type Definitions

## Reference

Folder:

`Reference/`

Question answered:

"What foundational context should Alfred know at the beginning of every session?"

Purpose:

Reference notes provide high-level orientation. They contain stable context that is useful across many conversations.

Examples:

- Myself
- Relationships
- WorkOrg
- Preferences
- ActiveProjects
- CurrentNarrative

Rules:

- Loaded during session startup
- Kept concise
- Updated infrequently
- May link to detailed entity notes
- Must not become a collection of every known fact
- Must not duplicate detailed Person, Pet, Project, or Event records
- Changes should reflect meaningful shifts in identity, relationships, priorities, or circumstances

Example:

`Reference/Relationships.md` establishes that Curtis Miller is Michael's manager.

Detailed knowledge about Curtis belongs in:

`People/Curtis-Miller.md`

## Person

Folder:

`people/`

Question answered:

"Who is this person, and what durable context is known about them?"

Purpose:

Person notes hold detailed, factual knowledge about specific human beings.

Examples:

- Jennifer Lucas
- Andrew Everett
- Curtis Miller
- Ross Guidry
- Jesus Llorca
- John Gellert
- Pharr

May contain:

- Relationship to Michael
- Role
- Organization
- Location
- Known aliases
- Important dates
- Interests
- Associated people
- Associated projects
- Topics frequently discussed
- Verified preferences
- Durable facts
- Retrieval guidance

Rules:

- Create one canonical note per person
- Add alternate names to aliases
- Update the existing note when new facts are learned
- Do not create separate notes for different roles held by the same person
- Do not infer personality, feelings, intentions, or opinions
- Do not store rumors
- Distinguish current facts from historical facts
- Mark approximate information as approximate
- Do not add a person to `Reference/relationships.md` unless that person has sustained relevance

## Pet

Folder:

`Pets/`

Question answered:

"Who is this animal, and how are they connected to Michael's life?"

Purpose:

Pet notes represent named animals that are relevant to recurring personal context.

Examples:

- Watts
- Biggie

May contain:

- Species
- Breed
- Birth date
- Approximate age
- Owner
- Namesake
- Associated people
- Durable facts
- Retrieval guidance

Rules:

- Create one canonical note per pet
- Keep Pet separate from Person
- Use exact dates when known
- Use approximate dates or ages only when explicitly identified as approximate
- Link the pet to its owner and other relevant people
- Do not create Pet notes for animals mentioned casually with no expected future relevance

## Project

Folder:

`Projects/`

Question answered:

"What are we trying to accomplish?"

Purpose:

Project notes are containers for ongoing, multi-step efforts with an objective and lifecycle.

Examples:

- Alfred Memory System
- Obsidian POC
- Vendor Onboarding Workflow
- Infrastructure Modernization

A Project normally has:

- Objective
- Status
- Scope
- Owner
- Associated people
- Associated decisions
- Associated tasks
- Related projects
- Current state
- Next milestone

Rules:

- A project must represent an ongoing effort, not a single action
- A project should have a defined objective
- A project may contain many tasks and decisions
- Tasks must not be embedded as the only record of actionable work
- Decisions must have their own Decision notes when the reasoning is durable
- Update the existing Project note as its status changes
- Do not create a new Project note for every conversation about the project

## Decision

Folder:

`Decisions/`

Question answered:

"What was chosen, and why was it chosen?"

Purpose:

Decision notes preserve selected directions and the reasoning behind them.

Examples:

- Use GitHub as the canonical knowledge store
- Treat Obsidian as a user interface
- Separate the Classifier and Writer prompts

A Decision normally has:

- Decision statement
- Date
- Status
- Reasoning
- Alternatives considered
- Expected benefits
- Tradeoffs
- Confidence
- Associated project
- Outcome
- Review date, when appropriate

Rules:

- Create a Decision only when a direction has actually been selected
- A possibility is an Idea, not a Decision
- A recommendation is not a Decision until adopted
- Preserve reasoning when it is available
- Link superseding and superseded decisions
- Do not silently rewrite historical reasoning
- Update outcome and review information as evidence develops
- Use Git history for document evolution, but keep important reversals explicit in the note

## Meeting

Folder:

`Meetings/`

Question answered:

"What occurred in a scheduled discussion, and what resulted from it?"

Purpose:

Meeting notes summarize relevant discussions and outcomes.

A Meeting normally has:

- Date and time
- Title
- Participants, when known
- Purpose
- Summary
- Decisions
- Tasks
- Open questions
- Associated projects
- Source

Rules:

- Do not store a raw transcript as the primary Meeting note
- Summarize only information supported by the source
- Identify decisions separately
- Create or update linked Decision and Task notes when appropriate
- Do not infer attendance from an invitation alone
- Do not create a Meeting note for casual conversation without durable value
- Use the meeting date in the filename

## Incident

Folder:

`Incidents/`

Question answered:

"What failed, what was affected, and what was learned?"

Purpose:

Incident notes document operational failures, outages, security events, and material service disruptions.

An Incident normally has:

- Date
- Status
- Services affected
- Impact
- Timeline
- Detection method
- Cause
- Resolution
- Follow-up tasks
- Lessons learned
- Related runbooks

Rules:

- Do not label an inconvenience as an Incident unless it produced meaningful operational impact
- Separate confirmed cause from suspected cause
- Do not present a hypothesis as root cause
- Link remediation work to Task notes
- Promote reusable remediation procedures into Runbook notes
- Promote generalized discoveries into Learning notes
- Use the incident date in the filename

## Runbook

Folder:

`Runbooks/`

Question answered:

"How should this repeatable process be performed?"

Purpose:

Runbook notes contain validated, reusable procedures.

Examples:

- Restore a failed service
- Rotate an API credential
- Deploy the Alfred memory service
- Recover the Git-backed knowledge repository

A Runbook normally has:

- Purpose
- Prerequisites
- Inputs
- Procedure
- Validation steps
- Rollback steps
- Risks
- Ownership
- Last validation date
- Related incidents

Rules:

- A procedure should be repeatable
- Do not create a Runbook from an unvalidated guess
- Mark untested instructions clearly
- Keep temporary debugging steps in an Incident or Learning until validated
- Update the existing Runbook rather than creating versioned duplicates
- Use Git history for prior versions
- Never store secrets, passwords, tokens, or private keys

## Learning

Folder:

`Learnings/`

Question answered:

"What durable and reusable knowledge was discovered?"

Purpose:

Learning notes preserve verified insights that can apply beyond a single moment.

Examples:

- Obsidian Local REST plugins depend on a local endpoint
- GitHub can serve as the canonical Markdown store
- Read and write paths should remain separate
- Classifier and Writer prompts perform different responsibilities

Rules:

- A Learning must be more durable than a one-time observation
- Generalize the lesson when evidence supports generalization
- Keep the source context
- Distinguish verified behavior from personal interpretation
- Do not promote every troubleshooting message into a Learning
- Do not store unsupported claims as Learnings
- If the learning changes a chosen direction, link it to the relevant Decision

## Event

Folder:

`Events/`

Question answered:

"What significant occurrence is associated with a date or period?"

Purpose:

Event notes represent meaningful past or future happenings.

Examples:

- Conference
- Vacation
- Product launch
- Certification
- Major milestone
- Anniversary
- Scheduled adoption or migration

An Event normally has:

- Date or date range
- Status
- Location
- Associated people
- Associated project
- Significance
- Preparation or follow-up

Rules:

- Dates are properties of entities, not a separate note type
- Create an Event note only when the occurrence has independent significance
- A person's birthday may remain a property in the Person note unless planning or history justifies a separate Event
- A meeting belongs in Meeting, not Event
- An operational outage belongs in Incident, not Event
- Use the event date in the filename when known

## Idea

Folder:

`Ideas/`

Question answered:

"What possibility, hypothesis, or concept might be worth exploring?"

Purpose:

Idea notes preserve potentially valuable concepts that have not been adopted.

Examples:

- Use Git as Alfred's brain
- Add semantic search to the repository
- Create a web interface for the memory service
- Add confidence-based memory promotion

Rules:

- Ideas are speculative
- An Idea is not a Decision
- An Idea does not automatically create a Project
- Record the problem or opportunity the idea addresses
- Include supporting thoughts when available
- Mark assumptions clearly
- Promote the Idea when it becomes a Project or Decision
- Link the promoted record rather than deleting the Idea
- Do not save every casual "maybe" statement
- Save only ideas with plausible future value

## Task

Folder:

`Tasks/`

Question answered:

"What specific action should happen next?"

Purpose:

Task notes represent concrete, actionable commitments.

Examples:

- Draft the Bootstrap prompt
- Create the Person template
- Configure the GitHub MCP connection
- Test startup retrieval

A Task normally has:

- Objective
- Status
- Priority
- Owner
- Associated project
- Associated decision
- Due date, if explicitly established
- Next action
- Completion criteria
- Outcome

Rules:

- A Task must be actionable
- Do not create a Task from a vague aspiration
- Do not invent due dates
- Do not treat every request made during conversation as a durable Task
- Temporary conversational actions may be executed without becoming repository notes
- Completed tasks should remain linked to their Project if they document meaningful project history
- Routine or low-value completed tasks may be archived
- A task requiring many independent actions may actually be a Project

# Routing Rules

Use these routing rules in order.

1. Is it foundational context needed at most session starts?
   - Reference

2. Is it detailed information about a human?
   - Person

3. Is it detailed information about a named animal?
   - Pet

4. Is it an ongoing effort with an objective and multiple actions?
   - Project

5. Was a direction actually selected?
   - Decision

6. Did it occur during a scheduled discussion?
   - Meeting

7. Was it an operational failure or material disruption?
   - Incident

8. Is it a repeatable and validated procedure?
   - Runbook

9. Is it durable, verified, reusable knowledge?
   - Learning

10. Is it a significant occurrence associated with a date?
    - Event

11. Is it a possibility that has not been adopted?
    - Idea

12. Is it a concrete action that should be completed?
    - Task

13. Does it lack durable future value?
    - Do not save

# Critical Distinctions

## Project vs Task

Project:

"What are we trying to accomplish?"

Task:

"What action should happen next?"

Example:

- "Build Alfred's memory system" is a Project.
- "Draft the Bootstrap prompt" is a Task.

## Idea vs Decision

Idea:

"We could use GitHub as the knowledge store."

Decision:

"We will use GitHub as the canonical knowledge store."

Possibility belongs in Idea.

Adopted direction belongs in Decision.

## Learning vs Decision

Learning:

"Obsidian's local REST plugins expose services through the local machine."

Decision:

"Obsidian will be treated as a GUI rather than the canonical store."

The Learning is supporting evidence.

The Decision is the selected response.

## Learning vs Runbook

Learning:

"Git history provides a record of changes to knowledge notes."

Runbook:

"Follow these steps to restore a previous version of a knowledge note."

Learning explains.

Runbook instructs.

## Event vs Meeting

Event:

"Michael will attend an AI conference."

Meeting:

"Michael and Andrew discussed AI adoption."

An Event is a significant occurrence.

A Meeting is a scheduled discussion with conversational outcomes.

## Reference vs Person

Reference:

"Curtis is Michael's manager."

Person:

Detailed facts about Curtis, his role, associations, interests, and relevant history.

Reference provides orientation.

Person provides depth.

## Reference vs Project

Reference:

"Alfred Memory System is currently an active priority."

Project:

The objective, scope, status, decisions, work, and history of the Alfred Memory System.

## Pet vs Person

Pet:

Watts is Michael's long-haired German Shepherd.

Person:

Pharr is Michael's girlfriend and Biggie's owner.

Do not store pets as people, even when they are important relationship entities.

# Lifecycle Model

Knowledge may move through the following lifecycle:

```text
Idea
  |
  v
Project
  |
  +--> Decision
  |
  +--> Task
  |
  +--> Meeting
  |
  +--> Learning
  |
  +--> Runbook
