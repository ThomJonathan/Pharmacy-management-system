---
sessionId: session-261108-175703-ec0m
---

# Requirements

### Outcome
Resolve the duplicate picker declarations and make the admin add-stock item picker reliably searchable. Users can browse all products, search without regard to case, select or change an item, and see an appropriate empty state. Preserve stock submission and unit handling; the employee stock picker already has search and is outside this change.

# Technical Design

### Approach
- In `lib/screens/admin/inventory.dart`, compare the repeated `_AdminItemPickerSheet` / `_AdminItemPickerSheetState` blocks and retain one complete implementation, removing only duplicate blocks without disturbing surrounding widgets.
- Preserve `_AddStockSheetState._pickItem` and its `showAdaptiveSheet<CatalogItem>` result, including item ID and default unit updates. Retain the existing `SearchField` from `adminui.dart`, with trimmed, case-insensitive filtering by name, category, unit and business type; clear restores all items.
- Distinguish an empty catalog from a search with no matches, and ensure the search and results remain usable with the keyboard open and on small screens. Preserve cancellation and changing an existing selection.

# Testing

### Validation
- Add focused widget coverage for browsing, case-insensitive partial search, clearing, no matches, empty catalog, selection, cancellation and changing an item; account for `SearchField`'s debounce.
- Verify the picker remains usable at a small viewport with keyboard insets and that selection preserves the default unit.
- Run Flutter analysis and targeted tests; report any unrelated existing failures, including the stock template smoke test if applicable.

# Delivery Steps

### * Step 1: Remove duplicate picker declarations
The admin inventory library contains exactly one picker widget and state declaration.

- Compare the repeated blocks in `lib/screens/admin/inventory.dart` and retain the complete picker implementation.
- Remove redundant declarations without changing neighboring widgets or the stock submission flow.
- Run analysis to verify the reported duplicate-name errors are gone.

###   Step 2: Complete and verify searchable stock selection
Admin users can search and select a catalog item when adding stock.

- Verify and refine the retained picker’s filtering, empty states and keyboard-responsive layout using the existing `SearchField` and sheet patterns.
- Preserve selection, cancellation, change-item behavior and default-unit handling in `_AddStockSheetState`.
- Add focused widget coverage and run targeted Flutter tests and analysis.