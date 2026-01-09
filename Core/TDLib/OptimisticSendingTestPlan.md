# Optimistic Sending Test Plan

## Event ordering
- Send a message and simulate TDLib function response arriving before `updateNewMessage`.
- Send a message and simulate `updateNewMessage` arriving before the function response.
- Validate only one message appears in the timeline and the DB for each send.

## Duplicate text safety
- Send two identical short messages back-to-back (e.g., "ok", "+", "ага").
- Verify they remain distinct and reconciliation never stitches them together.

## Pending restore
- Start a send, force-quit, relaunch.
- Ensure pending messages either reconcile (if fresh) or flip to failed with a timeout reason.

## History + live updates
- Load history while live updates stream in (new messages + edits).
- Ensure no duplicates and no lost messages after merge.

## Retry + cancel
- Force a send failure and retry; verify the same localId is reused and only one placeholder exists.
- Cancel a pending message; confirm it is removed from the timeline and DB.
