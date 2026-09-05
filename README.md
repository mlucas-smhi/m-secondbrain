# m-secondbrain

> **Hosted turn engine status (2026-09-05):** Service is restored after the
> runaway RPC incident. Deterministic conflicts are non-retryable, wake
> deliveries expose an atomic replay flag, transition RPCs are executable only
> by `service_role`, and the replay gate passed a monitored hosted canary.
> See [Turn engine architecture](docs/turn-engine.md), the
> [operations runbook](docs/turn-engine-runbook.md), and the
> [incident record](docs/incidents/2026-09-04-runaway-turn-rpc.md).

## Overview

`m-secondbrain` is a GitHub-backed knowledge repository for Alfred, Michael Lucas's ElevenLabs voice agent.

The project began as an exploration of Obsidian as a possible alternative to Zep. The architecture changed after determining that the Obsidian REST plugins under consideration relied on local loopback endpoints and were therefore not suitable as the primary cloud-facing integration for ElevenLabs.

The current model is:

- GitHub is the canonical knowledge store.
- Markdown is the durable knowledge format.
- GitHub MCP is the agent access layer.
- ElevenLabs is the voice and conversational interface.
- Alfred is the reasoning and orchestration layer.
- Obsidian is an optional human interface for viewing and editing the repository.

The repository is intended to provide Alfred with durable context, deterministic entity retrieval, governed memory creation, and a future foundation for action tools such as restaurant booking, travel, home automation, and shared household projects.

The repository also contains a Supabase-backed deterministic turn engine. It
stores task state, records an immutable event history, exposes authenticated
Edge Functions, and uses n8n as the durable pause/wake integration layer for
callbacks and external events. Its implementation is under `supabase/`.

## Current Status

The initial read path is operational as a proof of concept.

Completed or substantially defined:

- GitHub repository created as `m-secondbrain`
- ElevenLabs connected to GitHub through MCP
- Repository paths normalized to lowercase
- Startup Reference notes created
- Detailed People and Pet notes created
- Project, Decision, and Task note patterns created
- Knowledge taxonomy created
- Approved status values separated into a system document
- Linking rules established
- Positive and negative classification examples created
- Bootstrap, Classifier, and Writer responsibilities separated
- ElevenLabs root agent prompt drafted
- Entity retrieval and no-guessing rules strengthened

Initial testing showed that model capability materially affected retrieval quality. A smaller model produced unsupported relationship and age guesses. After changing the model and increasing reasoning, Alfred retrieved the correct records and answered accurately. This confirms that the repository and MCP connection can work, while also demonstrating that retrieval discipline and model selection remain important operational concerns.

## Architectural Principles

### GitHub is the brain

GitHub stores the canonical Markdown records and provides version history.

The knowledge must remain usable without Obsidian, ElevenLabs, or any particular model.

### Obsidian is a GUI

Obsidian may be used to browse, link, and edit the repository, but it is not the system of record or the cloud API layer.

### Read and write paths are separate

The read path provides context for conversation.

The write path decides whether new information deserves storage and then updates the appropriate record.

### Retrieval precedes claims

When a named entity has a repository record, Alfred must retrieve that record before making factual claims about the entity.

### No guessing

If the repository and current conversation do not support an answer, Alfred must say that the information is unknown or that retrieval failed.

A partial accurate answer is better than a complete fabricated answer.

### Update before create

Alfred must search canonical names and aliases before creating a note. Existing records should be updated rather than duplicated.

### The taxonomy is finite

Alfred may not invent new note types, folders, status values, or filename conventions. Changes require an explicit architectural decision.

## Current System Diagram

```text
Michael or an authorized participant
                |
                v
       ElevenLabs voice agent
                |
                v
              Alfred
                |
                v
          GitHub MCP server
                |
                v
     GitHub repository: m-secondbrain
                |
        -------------------
        |                 |
        v                 v
  Obsidian GUI       Other clients
```

Future action tools may attach to Alfred independently of the knowledge repository:

```text
                       GitHub MCP
                          |
                          v
                     m-secondbrain
                          ^
                          |
Michael -> ElevenLabs -> Alfred -> Action MCPs
                          |
             -----------------------------
             |             |             |
             v             v             v
         OpenTable       Travel      Home Assistant
```

The repository provides context. Action MCPs perform external operations.

## Repository Structure

```text
m-secondbrain/
├── reference/
│   ├── myself.md
│   ├── relationships.md
│   ├── workorg.md
│   ├── preferences.md
│   ├── active-projects.md
│   └── current-narrative.md
├── people/
├── pets/
├── projects/
├── decisions/
├── tasks/
├── meetings/
├── learnings/
├── incidents/
├── runbooks/
├── events/
├── ideas/
├── _templates/
└── _system/
    ├── architecture.md
    ├── repository-manifest.md
    ├── taxonomy.md
    ├── status-values.md
    ├── linking-rules.md
    ├── classification-examples.md
    ├── bootstrap-prompt.md
    ├── classifier-prompt.md
    └── writer-prompt.md
```

All repository paths are lowercase. Filenames use lowercase kebab-case.

Examples:

```text
people/jennifer-lucas.md
people/andrew-everett.md
pets/watts.md
projects/alfred-memory-system.md
decisions/2026-08-27-git-as-canonical-brain.md
tasks/build-bootstrap-prompt.md
```

## Knowledge Layers

### Tier 1: Startup orientation

Loaded at the beginning of each ElevenLabs session:

- `reference/myself.md`
- `reference/relationships.md`
- `reference/workorg.md`
- `reference/preferences.md`
- `reference/active-projects.md`
- `reference/current-narrative.md`
- `_system/repository-manifest.md`

These files give Alfred a compact mental model before conversation begins.

### Tier 2: Entity context

Retrieved when a named or strongly associated entity appears:

- People
- Pets
- Projects
- Current decisions
- Active tasks

Example:

```text
"Tell me about Andrew"
        |
        v
people/andrew-everett.md
```

### Tier 3: Historical and supporting context

Retrieved only when relevant:

- Meetings
- Incidents
- Learnings
- Events
- Prior decisions
- Completed tasks
- Runbooks

This tier prevents startup context from becoming unnecessarily large.

## Reference Notes vs Entity Notes

Reference notes are maps, not warehouses.

For example:

- `reference/relationships.md` says that Jennifer Lucas is Michael's mother.
- `people/jennifer-lucas.md` contains Jennifer's detailed record.
- `reference/active-projects.md` identifies the current projects.
- `projects/alfred-memory-system.md` holds the detailed project record.

The startup note identifies the entity. The entity note provides the facts.

## Approved Note Types

The current approved types are:

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

The detailed definitions, routing rules, lifecycle, and critical distinctions live in `_system/taxonomy.md`.

A compact mental model is:

- Project: What are we trying to accomplish?
- Decision: What was chosen, and why?
- Task: What should happen next?
- Idea: What possibility may be worth exploring?
- Learning: What durable knowledge was discovered?
- Runbook: How should a repeatable process be performed?
- Reference: What orientation should Alfred have at startup?
- Person or Pet: What durable facts belong to this entity?

## Prompt Separation

The system deliberately separates three responsibilities.

### Bootstrap Prompt

Purpose:

- Retrieve startup context
- Resolve named entities
- Support natural conversation
- Prevent repeated explanations
- Enforce retrieve-before-claiming behavior

The Bootstrap Prompt does not classify or write memories.

### Classifier Prompt

Purpose:

- Decide whether information has durable future value
- Select an approved note type
- Decide between CREATE, UPDATE, and IGNORE
- Search for existing canonical records
- Reject secrets and unsupported inferences

The Classifier does not write Markdown.

### Writer Prompt

Purpose:

- Use the selected template
- Create or update the classified target
- Preserve existing facts and history
- Apply metadata and linking rules
- Return repository-ready Markdown

The Writer does not decide whether information should be saved.

## Read Path

```text
Session starts
    |
    v
Load startup Reference notes and repository manifest
    |
    v
Build internal orientation
    |
    v
Begin conversation
    |
    v
Detect a named entity or relevant topic
    |
    v
Retrieve the canonical entity note
    |
    v
Answer only from retrieved or explicitly stated facts
```

## Planned Write Path

```text
Conversation produces potentially durable information
    |
    v
Classifier evaluates value, type, and existing records
    |
    +--> IGNORE
    |
    +--> UPDATE existing canonical note
    |
    +--> CREATE a genuinely new note
                  |
                  v
             Writer applies template
                  |
                  v
            Commit change to GitHub
```

The current implementation emphasis is read-only retrieval. Write access should be introduced gradually after the Classifier and Writer are tested.

Recommended progression:

1. Read and search repository
2. Retrieve entity notes
3. Create Ideas
4. Create Tasks
5. Update low-risk entity notes
6. Create Decisions
7. Modify Reference notes only after strict validation

## Linking Convention

Canonical links use folder-qualified Obsidian syntax with a human-readable display name.

Examples:

```markdown
[[people/curtis-miller|Curtis Miller]]
[[projects/alfred-memory-system|Alfred Memory System]]
[[decisions/2026-08-27-git-as-canonical-brain|Git as Canonical Brain]]
```

The path before the pipe is the canonical machine identifier.

The text after the pipe is the human-readable name.

Detailed rules live in `_system/linking-rules.md`.

## Security Rules

Never store:

- Passwords
- API keys
- Personal access tokens
- OAuth tokens
- Private certificates
- SSH private keys
- Recovery codes
- Other authentication secrets

Secrets belong in a dedicated secret manager, platform credential store, environment variable, or password manager.

If conversation content appears to contain secret material, the Classifier must reject it and alert Michael rather than writing it to the repository.

## Model and Retrieval Lessons

Early testing exposed two independent configuration concerns.

### Case-sensitive paths

The repository was normalized to lowercase because literal path resolution may fail when prompts refer to paths with different capitalization.

All prompts, links, manifests, examples, and templates should use the exact lowercase repository paths.

### Model capability and reasoning level

A smaller model produced unsupported guesses, including an incorrect relationship for Jennifer Lucas and invented ages for Watts. A stronger model with higher reasoning correctly retrieved and used the records.

The practical lesson is not that maximum reasoning should always be used. Entity lookup should be retrieval-heavy rather than reasoning-heavy. The target configuration is the lowest reasoning level that still reliably:

- Performs tool calls when needed
- Opens the correct canonical note
- Uses retrieved facts
- Refuses to guess when retrieval is incomplete

Higher reasoning may add noticeable conversational latency, so latency and accuracy should be tested together.

## Shared and Communal Layer

A future phase may expose selected repository portions to authorized participants such as Pharr.

Potential shared use cases include:

- Landscaping projects
- Household projects
- Travel itineraries
- Hotel research and booking
- Restaurant recommendations and reservations
- Pet information
- Shared events and decisions

The communal layer should not grant access to the full private repository by default.

A future permission model should distinguish:

- Private knowledge
- Shared household knowledge
- Public or reusable reference knowledge

Shared access must be enforced by repository, branch, service, or agent permissions. Prompt instructions alone are not a security boundary.

## Action Layer

Memory and actions are separate concerns.

GitHub MCP handles knowledge retrieval.

Other MCP servers may eventually handle actions such as:

- Restaurant search and reservation
- Travel research and booking
- Calendar operations
- Home automation
- Navigation
- Music

Actions that spend money, create reservations, change travel, unlock doors, open garages, or affect safety should require explicit confirmation and clear reporting of the result.

The knowledge repository may inform an action, but an action should not automatically become permanent memory.

Example:

- Booking a restaurant is an action.
- "Pharr loved that restaurant; remember it" is a candidate memory update.

## ElevenLabs Agent Prompt

The following is the current root prompt for the ElevenLabs Alfred agent. It is intentionally more direct than the earlier draft because testing showed that optional retrieval language allowed the model to answer from partial startup context or guess.

```markdown
You are Alfred, Michael Lucas's long-term AI collaborator.

You have access to a GitHub repository named `m-secondbrain` through MCP tools.

The repository is the canonical source for Michael's durable knowledge, relationships, projects, decisions, preferences, and current context.

Your job is to retrieve the correct context, use it naturally, and answer accurately.

RETRIEVE BEFORE CLAIMING.

If a named entity has a repository record, retrieve that record before answering factual questions about the entity.

If retrieval fails or the record does not contain the answer, say you do not know.

Never guess.

# Mandatory Session Startup

At the beginning of every session, before answering substantive questions, retrieve and read these exact files:

- `reference/myself.md`
- `reference/relationships.md`
- `reference/workorg.md`
- `reference/preferences.md`
- `reference/active-projects.md`
- `reference/current-narrative.md`
- `_system/repository-manifest.md`

These files provide startup orientation.

Do not recite or summarize them unless Michael asks.

Do not treat them as substitutes for detailed entity notes.

# Mandatory Entity Resolution

Whenever Michael asks about or mentions a named Person, Pet, Project, Decision, Event, Incident, or Runbook, search the corresponding repository folder and retrieve the canonical entity note before making factual claims about that entity.

Use these lowercase paths:

- People: `people/`
- Pets: `pets/`
- Projects: `projects/`
- Decisions: `decisions/`
- Events: `events/`
- Incidents: `incidents/`
- Runbooks: `runbooks/`

Examples:

- Jennifer or Jennifer Lucas: retrieve `people/jennifer-lucas.md`
- Andrew or Andrew Everett: retrieve `people/andrew-everett.md`
- Jesus or Jesus Llorca: retrieve `people/jesus-llorca.md`
- Curtis or Curtis Miller: retrieve `people/curtis-miller.md`
- Pharr: retrieve `people/pharr.md`
- Watts: retrieve `pets/watts.md`
- Biggie: retrieve `pets/biggie.md`
- Alfred Memory System: retrieve `projects/alfred-memory-system.md`

Do not answer from `reference/relationships.md` alone when a detailed entity note exists.

The Reference note identifies the entity.

The entity note provides the details.

# No-Guessing Rule

Never guess, fabricate, complete, or infer a fact that is not explicitly supported by either:

1. The current conversation, or
2. A successfully retrieved repository note.

If you do not know something:

1. Search the appropriate repository folder.
2. Search the exact name.
3. Search known aliases.
4. Retrieve the most likely canonical note.
5. If the answer is still unsupported, say that you do not know.

Do not substitute a plausible answer for a missing answer.

Do not infer:

- Relationships
- Job titles
- Reporting structures
- Locations
- Dates
- Ages
- Interests
- Project involvement
- Decisions
- Opinions
- Motivations
- Feelings
- Intentions

If the repository says Jennifer Lucas is Michael's mother, never describe Jennifer Lucas as Michael's girlfriend.

If the repository identifies Pharr as Michael's girlfriend, do not transfer that relationship to another person.

If `pets/watts.md` provides Watts's birth date, use that date. Do not invent an age. If age must be calculated, calculate it from the retrieved birth date and the current date.

A partial, accurate answer is always better than a complete, fabricated answer.

# Retrieval Failure

A failed search is not evidence that information does not exist.

If a requested note cannot be retrieved:

- Do not guess its contents.
- Do not silently answer from general assumptions.
- State which record could not be retrieved.
- Answer only with facts successfully retrieved or explicitly stated in the current conversation.

Never conceal a retrieval failure with a plausible response.

# Context Use

Use repository knowledge to:

- Understand recurring people and pets
- Understand active projects
- Understand prior decisions and their rationale
- Maintain continuity
- Avoid making Michael repeat established context
- Improve recommendations and reasoning

Do not use repository knowledge to:

- Show off memory
- Recite facts unnecessarily
- Force unrelated context into the conversation
- Claim certainty unsupported by the records

# Retrieval Scope

Retrieve only the context that improves the current conversation.

Prefer the canonical note over broad repository search results.

Prefer current active records over archived material unless Michael asks for history.

# Conversation Style

Be direct, practical, technically informed, collaborative, and honest.

For simple factual lookups, retrieve the record and answer concisely.

Do not use heavy reasoning when a direct repository lookup resolves the question.

For architecture and systems discussions:

- Think in layers
- Separate responsibilities
- Explain tradeoffs
- Identify dependencies and failure modes
- Prefer durable and reversible designs

# Memory Writes

Do not write new memory merely because information appears in conversation.

Until write behavior is explicitly enabled and tested, treat repository access as read-only.

When write behavior is enabled, follow:

- `_system/taxonomy.md`
- `_system/status-values.md`
- `_system/linking-rules.md`
- `_system/classification-examples.md`
- `_system/classifier-prompt.md`
- `_system/writer-prompt.md`
- The appropriate template in `_templates/`

Never store secrets or credentials.

Prefer updating an existing canonical note over creating a duplicate.

# Final Operating Rule

Retrieve first.

Answer from evidence.

Never guess.

Use memory to improve reasoning, not to replace reasoning.
```

## Current Test Cases

The following prompts serve as basic retrieval regression tests.

### Person lookup

Prompt:

```text
Who is Jennifer Lucas?
```

Expected record:

```text
people/jennifer-lucas.md
```

Expected behavior:

- Identify Jennifer as Michael's mother
- Use only details present in the note
- Never confuse Jennifer with Pharr

### Person detail lookup

Prompt:

```text
Tell me about Andrew Everett.
```

Expected record:

```text
people/andrew-everett.md
```

Expected behavior:

- Return the supported role, location, interests, and relationship context
- State retrieval failure rather than falling back to a generic description

### Organization lookup

Prompt:

```text
Tell me about Jesus Llorca.
```

Expected record:

```text
people/jesus-llorca.md
```

Expected behavior:

- Return only the organizational and personal details in the note
- Do not infer reporting relationships beyond stored facts

### Pet lookup

Prompt:

```text
Who is Watts?
```

Expected record:

```text
pets/watts.md
```

Expected behavior:

- Identify Watts as Michael's long-haired German Shepherd
- Use the stored birth date
- Do not invent an age

### Project lookup

Prompt:

```text
What am I currently building?
```

Expected records:

```text
reference/active-projects.md
reference/current-narrative.md
projects/alfred-memory-system.md
```

Expected behavior:

- Explain the current project and architecture
- Distinguish GitHub, GitHub MCP, Alfred, ElevenLabs, and Obsidian responsibilities

### Retrieval failure

Prompt:

```text
Tell me Gary's job title.
```

Expected behavior if the record does not contain a title:

- Retrieve `people/gary.md`
- State that Gary's job title is not known
- Do not invent an employer or title

## Immediate Next Steps

1. Keep GitHub MCP access read-only while tuning retrieval.
2. Test a lower reasoning level with the stronger model.
3. Run the retrieval regression tests after every prompt or model change.
4. Confirm that `_system/repository-manifest.md` accurately maps every folder.
5. Add a security rules file before enabling writes.
6. Complete and test templates for every approved note type.
7. Enable Classifier output without Writer execution and inspect its decisions.
8. Enable low-risk writes only after classification is stable.
9. Design the shared household boundary before granting another participant access.
10. Add one action MCP only after the memory read path remains reliable.

## Definition of Initial Success

The current proof of concept is successful when Alfred can consistently:

- Load the startup context
- Resolve known aliases
- Retrieve canonical entity records
- Answer from stored evidence
- Distinguish people and relationships correctly
- Avoid inventing dates, ages, roles, or relationships
- State when information is unknown
- Maintain useful conversational latency
- Preserve a clean boundary between knowledge retrieval and external actions

## Long-Term Direction

The long-term direction is a voice-accessible personal and shared operating context.

Potential capabilities include:

- Personal knowledge retrieval
- Shared household projects
- Travel planning and itinerary access
- Restaurant recommendations and reservations
- Home automation
- Context-aware calendar actions
- Governed memory updates
- Human review through Obsidian
- Versioned knowledge history through GitHub

The central design constraint remains unchanged:

The knowledge must stay portable, inspectable, editable, and independent of any single model, voice provider, action platform, or user interface.
