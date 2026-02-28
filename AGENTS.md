# Aurora Agent Guardrails (SwiftUI)

These rules are mandatory for any SwiftUI edits in this repository.

## Non-negotiable rules

1. `onChange`
- Do not use the deprecated one-parameter closure form: `.onChange(of:) { newValue in ... }`.
- Use either:
  - zero-parameter form: `.onChange(of: value) { ... }`
  - old/new form: `.onChange(of: value) { oldValue, newValue in ... }`

2. `GeometryReader`
- Do not add `GeometryReader` unless layout/measurement cannot be solved with modern modifiers.
- Every `GeometryReader` must have an inline justification comment immediately above it:
  - `// swiftui-allow:geometryreader <reason>`

3. Nested scroll containers
- Do not nest `ScrollView`, `List`, or `Form` inside another scroll container.
- Prefer a single scroll container with `LazyVStack`/`LazyHStack` composition.

## Required check before finalizing SwiftUI changes

Run:

```bash
./scripts/swiftui_guardrails.sh
```

If the script fails, fix all reported issues before completing the task.
