---
type: reference
status: active
importance: core
retrieval_priority: startup
created: 2026-08-27
updated: 2026-08-27
---

# Current Narrative

## Purpose

This note describes the current chapter of Michael Lucas' ongoing work and thinking.

It provides Alfred with directional context at session startup.

It should explain what is currently happening without duplicating the detailed contents of Project, Decision, Idea, or Task notes.

## Current Focus

Michael is actively designing an alternative long-term memory and knowledge architecture for Alfred.

The effort began as an evaluation of Obsidian as a possible alternative to Zep.

The architecture evolved after identifying that common Obsidian REST plugins depend on local endpoints and are therefore unsuitable as the primary cloud-facing access layer for ElevenLabs.

The current direction is:

- GitHub is the canonical knowledge store.
- Markdown files are the durable knowledge format.
- Git history provides change history and auditability.
- GitHub MCP is the candidate connection between ElevenLabs and the repository.
- Obsidian is an optional human interface.
- Alfred is the conversational reasoning layer.

## Current Architectural Model

Canonical knowledge:

GitHub repository named `m-secondbrain`

Human interface:

Obsidian or another Markdown-compatible client

Conversational interface:

ElevenLabs and Alfred

Agent access:

GitHub MCP

Behavioral governance:

- Taxonomy
- Approved status values
- Linking rules
- Classification examples
- Note templates
- Bootstrap prompt
- Classifier prompt
- Writer prompt

## Current Design Principle

The read path and write path are separate responsibilities.

Read path:

1. Begin a session.
2. Retrieve foundational Reference notes.
3. Establish high-level orientation.
4. Detect entities during conversation.
5. Retrieve deeper entity or historical notes when relevant.
6. Use context naturally in Alfred's response.

Write path:

1. Identify potentially durable information.
2. Classify the information.
3. Search for an existing canonical note.
4. Select the appropriate template.
5. Update an existing note or create a new note.
6. Commit the change to GitHub.

The Bootstrap prompt controls the read path.

The Classifier and Writer prompts will control the write path.

## Current Repository Structure

The repository includes knowledge folders for:

- Reference
- People
- Pets
- Projects
- Decisions
- Tasks
- Meetings
- Learnings
- Incidents
- Runbooks
- Events
- Ideas

The `_system` folder contains governance, prompts, examples, templates, and architecture documentation.

## Current Knowledge Model

The system uses three retrieval tiers.

Tier 1: Startup Context

- Myself
- Relationships
- Work Organization
- Preferences
- Active Projects
- Current Narrative

Tier 2: Entity Context

- People
- Pets
- Projects
- Current decisions
- Active tasks

Tier 3: Historical and Supporting Context

- Meetings
- Incidents
- Learnings
- Events
- Prior decisions
- Completed tasks
- Runbooks

The purpose of the tiers is to provide orientation first and retrieve detail only when it improves the conversation.

## Current Priority

The immediate priority is to complete and validate Bootstrap behavior.

Bootstrap success means Alfred can:

- Retrieve all required startup Reference notes
- Understand Michael's current architecture and priorities
- Recognize known people and pets
- Recognize active projects
- Resolve named entities to canonical repository records
- Use retrieved context naturally
- Avoid reciting memory unnecessarily
- Avoid requiring Michael to repeat established context

## Current Guardrail

Alfred should begin with read-only access to the repository.

Write access should be introduced only after:

- Bootstrap retrieval is reliable
- Entity resolution is reliable
- The taxonomy is stable
- Classification behavior is defined
- Writer behavior is constrained by templates
- Duplicate prevention is tested

## Retrieval Guidance

Use this note to understand what Michael is currently building and why.

Do not treat this note as permanent identity.

Do not copy every short-lived task into this note
