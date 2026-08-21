# FeedFlow implementation rules

- Preserve the invariant: Item is evidence; Event is interpretation.
- Never replace revisioned Event membership with a mutable `item.eventID`.
- Historical Item, Event, Digest, Claim, membership, prompt, and provenance
  revisions are immutable.
- Foreground FeedFlow must remain fully writable when FeedFlowAgent is absent.
- Only the main app runs schema migrations. Agent waits on incompatible schema.
- Every canonical writer uses shared short transactions, durable leases, and
  transactional change generations.
- GRDB observation is process-local. External commits require generation checks
  and explicit invalidation/refetch.
- BrowserWorker exclusively owns authenticated WKWebsiteDataStore profiles.
  Never export cookies as the authentication architecture.
- Authenticate XPC peers by exact signing requirement and Team ID. App Group
  membership and Mach-service names are not authentication.
- Redact secrets before persisting HTTP metadata, not only before logging.
- `accessRequirement` and `contentPrivacy` are independent Source dimensions.
- Cloud AI never crosses AIContentPolicy without explicit applicable consent.
- User clustering constraints are durable hard constraints until revoked.
- Default search indexes current revisions. Historical search is explicit.
- Embedding runtime, model, dimensions, and dtype remain dynamic.
- Keep dependencies permissively licensed. Do not copy or link GPL/AGPL
  PaperRss or RSSHub implementation code.
- Keep repository documentation minimal; put stable engineering rules here.

## Testing

- Keep tests compact and risk-based. Prioritize migrations, canonical/revision
  invariants, evidence memberships, user clustering constraints, Today and read
  semantics, foreground fallback, leases/idempotency, cross-process invalidation,
  redaction/privacy, XPC, search revision scope, connector normalization, and
  Reader security.
- Add focused regressions for product bugs. Do not add tests for trivial value
  initialization, cosmetic modifiers, duplicate paths, or coverage statistics.
- Real build, launch, and visual inspection are required for native UI changes;
  screenshot-golden matrices are not a substitute for product use.

## Git

- Inspect status and history before editing. Preserve unrelated user changes and
  exclude generated/local files.
- Use reviewable Conventional Commits at meaningful engineering checkpoints,
  after inspecting the diff and running relevant checks.
- Own the appropriate push/PR/CI/merge workflow. Fix failures and clean merged
  branches; when work is merged, finish on clean synchronized `main`.
