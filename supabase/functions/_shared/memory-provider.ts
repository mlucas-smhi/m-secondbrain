export type MemoryPermission = "read" | "use" | "disclose";

export type MemoryRecord = {
  id: string;
  subject_ref: string;
  owner_ref: string;
  memory_type: string;
  content: string;
  sensitivity_level: 1 | 2 | 3;
  compartment: string;
  source_ref: string;
  valid_from: string;
  valid_until: string | null;
  status: "active" | "superseded" | "expired";
  supersedes: string | null;
};

export type MemorySearchRequest = {
  subject_ref: string;
  query: string;
  limit: number;
  now: Date;
};

export interface MemoryProvider {
  readonly providerKey: string;
  search(request: MemorySearchRequest): Promise<MemoryRecord[]>;
}

const SYNTHETIC_MEMORIES: MemoryRecord[] = [
  {
    id: "git-memory:test-owner:travel-location-v1",
    subject_ref: "test:owner",
    owner_ref: "test:owner",
    memory_type: "preference",
    content: "For New York hotels, location matters more than loyalty points.",
    sensitivity_level: 1,
    compartment: "travel",
    source_ref: "fixture:synthetic-owner-statement-1",
    valid_from: "2026-09-10T00:00:00Z",
    valid_until: null,
    status: "active",
    supersedes: null,
  },
  {
    id: "git-memory:test-owner:business-counsel-v1",
    subject_ref: "test:owner",
    owner_ref: "test:owner",
    memory_type: "confidential_context",
    content: "Synthetic private legal strategy exists for the example transaction.",
    sensitivity_level: 3,
    compartment: "business",
    source_ref: "fixture:synthetic-private-conversation-1",
    valid_from: "2026-09-10T00:00:00Z",
    valid_until: null,
    status: "active",
    supersedes: null,
  },
  {
    id: "git-memory:test-owner:family-breakfast-v1",
    subject_ref: "test:owner",
    owner_ref: "test:owner",
    memory_type: "preference",
    content: "The synthetic household prefers an early breakfast on travel days.",
    sensitivity_level: 1,
    compartment: "family",
    source_ref: "fixture:synthetic-family-statement-1",
    valid_from: "2026-09-10T00:00:00Z",
    valid_until: null,
    status: "active",
    supersedes: null,
  },
];

function tokens(value: string): string[] {
  return value.toLowerCase().match(/[a-z0-9]+/g) ?? [];
}

export class GitMemoryProvider implements MemoryProvider {
  readonly providerKey = "git-poc";

  search(request: MemorySearchRequest): Promise<MemoryRecord[]> {
    const queryTokens = new Set(tokens(request.query));
    const minimumScore = queryTokens.size >= 3 ? 2 : 1;
    const matches = SYNTHETIC_MEMORIES
      .filter((memory) => memory.subject_ref === request.subject_ref)
      .filter((memory) => memory.status === "active")
      .filter((memory) => memory.valid_until === null || new Date(memory.valid_until) > request.now)
      .map((memory) => ({
        memory,
        score: tokens(`${memory.memory_type} ${memory.content} ${memory.compartment}`)
          .filter((token) => queryTokens.has(token)).length,
      }))
      .filter(({ score }) => queryTokens.size === 0 || score >= minimumScore)
      .sort((left, right) => right.score - left.score || left.memory.id.localeCompare(right.memory.id))
      .slice(0, request.limit)
      .map(({ memory }) => memory);

    return Promise.resolve(matches);
  }
}
