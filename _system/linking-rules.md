# Linking Rules

## Canonical Link Format

Use folder-qualified Obsidian links that exactly match the target filename.

Examples:

[[People/curtis-miller|Curtis Miller]]

[[Projects/alfred-memory-system|Alfred Memory System]]

[[Decisions/2026-08-27-git-as-canonical-brain|Git as Canonical Brain]]

The portion before the pipe is the canonical repository path.

The portion after the pipe is the human-readable display name.

## Entity Linking Rules

Always link known:

- People
- Pets
- Projects
- Decisions
- Events

Link when relevant:

- Tasks
- Meetings
- Learnings
- Incidents
- Runbooks
- Ideas

Do not:

- Link common nouns
- Create a link for every mention
- Create multiple links to the same target in one short section
- Link to an entity that cannot be confidently resolved
- Invent a target filename
- Create duplicate entities under shortened names

## Link Resolution Rules

Before creating a link:

1. Search for the exact canonical name.
2. Search known aliases.
3. Confirm the target note exists.
4. Use the target note's exact repository path.
5. Use the canonical display name after the pipe.

If the entity cannot be resolved confidently, do not create the link.

If the entity is durable and genuinely new, create the entity note before linking to it.

## Update Rules

Before creating a note:

1. Search existing entities.
2. Search aliases.
3. Search for notes describing the same subject.
4. Update an existing note when possible.
5. Create a note only when the subject is genuinely new.

Do not create:

- `People/curtis.md` when `People/curtis-miller.md` exists
- `People/andrew.md` when `People/andrew-everett.md` exists
- A second Project note because the project was described differently
- A second Decision note when new information merely clarifies an existing decision

## Canonical Naming

Use lowercase kebab-case filenames.

Examples:

People:

- People/curtis-miller.md
- People/andrew-everett.md
- People/jennifer-lucas.md

Pets:

- Pets/watts.md
- Pets/biggie.md

Projects:

- Projects/alfred-memory-system.md
- Projects/obsidian-poc.md

Tasks:

- Tasks/build-bootstrap-prompt.md
- Tasks/create-classifier-prompt.md

Date-centered records:

- Decisions/2026-08-27-git-as-canonical-brain.md
- Meetings/2026-08-27-memory-architecture-review.md
- Incidents/2026-08-27-memory-service-outage.md
- Events/2026-08-27-github-repository-created.md

## Display Names

Filenames use lowercase kebab-case.

Note titles and displayed links use normal human-readable capitalization.

Example filename:

People/jesus-llorca.md

Example note title:

# Jesus Llorca

Example link:

[[People/jesus-llorca|Jesus Llorca]]

## Reference File Linking

Reference files provide high-level orientation and link to detailed entity records.

Examples:

Reference/relationships.md links to:

- People
- Pets

Reference/active-projects.md links to:

- Projects

Reference/current-narrative.md may link to:

- People
- Pets
- Projects
- Decisions
- Events

Reference files must not duplicate the detailed contents of linked notes.

Example:

Reference/relationships.md records:

- Curtis Miller is Michael's manager.

People/curtis-miller.md records:

- Detailed role information
- Associated projects
- Relevant interests
- Durable facts
- Additional relationship context

## Relationship Direction

Links should appear in sections that explain the relationship.

Example:

## Associated People

- [[People/curtis-miller|Curtis Miller]]: Michael's manager
- [[People/ross-guidry|Ross Guidry]]: Member of Michael's team

Do not rely on a link alone to explain why two notes are connected.

## Broken and Unresolved Links

Do not intentionally create unresolved links during normal writing.

An unresolved link is permitted only when:

- The entity is known to be durable
- The entity note is scheduled for immediate creation
- The intended canonical filename is unambiguous

Unresolved links must not be used as placeholders for uncertain information.
