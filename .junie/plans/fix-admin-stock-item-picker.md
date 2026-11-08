---
sessionId: session-261108-175703-ec0m
---

# Requirements

Make catalog and stock loading reliable beyond API page limits using ID-based keyset pagination, retaining existing filtering, access rules, stock batches and display order. Separate requests do not provide a database snapshot.

# Delivery Steps

### ✓ Step 1: Inspect and implement pagination
- Inspect the discussed catalog, overview, category and employee stock queries and existing test conventions.
- Implement keyset pagination until an empty page, preserving permissions, filters and alphabetical display; page inventory by batch ID with smaller ID chunks.
- Avoid introducing a category RPC that can itself be truncated; retrieve categories from all visible items while preserving active-item filtering.

### ✓ Step 2: Test and verify
- Add focused tests covering server-capped pages, more than 1,000 items, stock batches, filtering and ordering.
- Run targeted tests, Flutter analysis and the project build; report limitations and existing failures.