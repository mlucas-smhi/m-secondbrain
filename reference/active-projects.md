---
type: reference
status: active
importance: core
retrieval_priority: startup
created: 2026-08-27
updated: 2026-08-27
---

# Active Projects

## Purpose

This note provides a concise startup index of Michael Lucas's currently active, high-priority projects.

It is not the canonical record for project details.

Detailed objectives, decisions, tasks, people, and history belong in the linked Project notes.

## Primary Active Project

### Alfred Memory System

Project:

[[Projects/alfred-memory-system|Alfred Memory System]]

Status:

Active

Importance:

High

Objective:

Design and validate a durable long-term knowledge and memory system for Alfred.

Current architecture:

- GitHub repository as the canonical knowledge store
- Markdown as the durable storage format
- GitHub MCP as the candidate agent access layer
- Obsidian as an optional human interface
- ElevenLabs as the conversational and voice layer
- Separate Bootstrap, Classifier, and Writer prompts

Current focus:

- Define startup retrieval
- Complete Bootstrap reference notes
- Draft and test the Bootstrap prompt
- Validate ElevenLabs connectivity to the GitHub MCP server
- Keep initial GitHub access read-only while testing retrieval

Related architectural decision:

[[Decisions/2026-08-27-git-as-canonical-brain|Git as Canonical Brain]]

## Supporting Project

### Obsidian POC

Project:

[[Projects/obsidian-poc|Obsidian POC]]

Status:

Active

Importance:

Normal

Objective:

Evaluate Obsidian as a human interface for viewing and editing the Git-backed knowledge repository.

Current understanding:

- Obsidian is not the canonical system of record.
- Obsidian's local REST plugins are not the preferred cloud integration layer.
- Obsidian remains useful as a visual Markdown interface.
- The knowledge repository must remain usable without Obsidian.

Relationship to Alfred Memory System:

The Obsidian POC is a supporting interface evaluation within the broader Alfred Memory System effort.

## Current Workstream

The immediate workstream is Bootstrap.

Current sequence:

1. Complete all startup Reference notes.
2. Finalize `bootstrap-prompt.md`.
3. Connect ElevenLabs to the GitHub MCP server.
4. Give Alfred read-only repository access.
5. Test retrieval of startup Reference notes.
6. Test entity resolution for known people, pets, projects, and decisions.
7. Observe context quality before introducing repository write access.

## Retrieval Guidance

At startup:

- Include the project names, current objectives, and immediate focus.
- Do not load every linked Project, Decision, or Task note automatically.
- Retrieve the full Project note when the conversation concerns that project.
- Retrieve related Decision and Task notes only when relevant.

This file should remain concise.

When a project becomes inactive, remove it from this startup index after updating the canonical Project note.
