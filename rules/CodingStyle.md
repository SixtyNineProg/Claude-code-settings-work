# Java Code Style

You are a Java coding assistant. Always follow these rules when generating, completing, or refactoring Java code.

---

## Formatter

All code must comply with **google-java-format** style rules:
- 2-space indentation (no tabs).
- Column limit: **100 characters**.
- Opening braces on the same line — never on a new line.
- One blank line between methods; no trailing blank lines inside a method body.

---

## Naming

| Element | Style | Example |
|---|---|---|
| Class / Interface | `UpperCamelCase` | `UserAccountService` |
| Method | `lowerCamelCase` | `getUserById()` |
| Variable | `lowerCamelCase` | `userAccount` |
| Constant (`static final`) | `UPPER_SNAKE_CASE` | `MAX_RETRY_COUNT` |
| Package | `lowercase.dot.separated` | `com.example.billing` |
| Generic type param | Single uppercase letter or descriptive `UpperCamelCase` | `T`, `RequestT` |

- Never abbreviate unless universally known (`id`, `url`, `http`).
- Boolean variables and methods must read as a question: `isActive`, `hasPermission`, `canRetry`.

---

## File & Class Structure

Always order class members as follows:

1. Constants (`static final` fields)
2. Static fields
3. Instance fields
4. Constructors
5. Static factory methods
6. Public methods
7. Package-private / protected methods
8. Private methods
9. `equals`, `hashCode`, `toString` — always last

---

## Imports

- Never use wildcard imports (`import java.util.*` is forbidden).
- Never generate unused imports.
- Group imports with a blank line between each group:
    1. `java.*` and `javax.*`
    2. Third-party libraries
    3. Internal project packages

---

## Declarations

- Declare variables as close to their first use as possible.
- One variable per declaration line — never declare multiple variables on one line.
- Always use `final` for variables that are never reassigned.
- Always specify generic types — never use raw types.
- Use the interface type on the left-hand side of collection declarations.

```java
// ✅ Correct
final List<String> names = new ArrayList<>();

// ❌ Wrong
ArrayList names = new ArrayList();
String a, b;
```

---

## Methods

- Each method must do one thing only.
- Maximum **30 lines** per method body.
- Maximum **4 parameters** — use a builder or parameter object when more are needed.
- Always apply guard clauses: validate inputs at the top and return early to avoid deep nesting.

```java
// ✅ Correct
public Invoice generateInvoice(Order order) {
  if (order == null) {
    throw new IllegalArgumentException("Order must not be null");
  }
  if (!order.isConfirmed()) {
    throw new IllegalStateException("Order is not confirmed");
  }
  // main logic ...
}
```

---

## Error Handling

- Never swallow exceptions silently — always log or rethrow.
- Never catch `Exception` or `Throwable` unless at a top-level boundary (e.g., global handler).
- Always use specific exception types with a meaningful message.
- Use `Optional<T>` instead of returning `null` for absent values.

```java
// ✅ Correct
return userRepository.findById(id)
    .orElseThrow(() -> new UserNotFoundException("User not found: " + id));

// ❌ Wrong
try {
  ...
} catch (Exception e) {}
```

---

## Nullability

- Annotate all method parameters and return types with `@NonNull` or `@Nullable`.
- Call `Objects.requireNonNull()` at the top of constructors and public methods for all mandatory parameters.
- Never return `null` from a public method that returns a collection — return an empty collection instead.

---

## Input Validation & Parameter Design

### Input validation

- Apply guard clauses at the entry of every `public` method and constructor: validate inputs before any work begins.
- Move validation into a private helper so the public method stays under the 30-line limit and keeps a single responsibility (orchestrating steps).
- Error messages must name the field and the rule, not be generic.
- Validate only what the method actually consumes (YAGNI).

### Parameter design

- Prefer concrete value parameters over container or service objects.
- A factory/module method must be a pure function of its inputs — never call external services (orchestrator, DB, HTTP) to fetch its own arguments; the caller resolves dependencies and passes concrete values.
- When this shifts small boilerplate to the caller, it is acceptable: a pure factory plus decoupling (SRP) outweigh minor duplication.
- Keep reusable identifiers (asset names, keys) as constants in the owning module (DRY) so callers share one source of truth without the module touching services.
- Prefer the concrete data type over a generic/container type (type safety), but depend on **data** types, not **service** types, when only data is required.

---

## Comments & Javadoc

- Every `public` class and every `public` / `protected` method must have a Javadoc comment.
- Javadoc must explain **why** and **what**, not just restate the method name.
- Use inline comments (`//`) only for non-obvious logic; never narrate obvious code.

```java
/**
 * Calculates a prorated refund for a subscription cancelled mid-cycle.
 *
 * @param subscription the active subscription, must not be null
 * @param cancellationDate the date the cancellation was requested
 * @return the refund amount in cents, zero if no refund applies
 */
public long calculateRefund(Subscription subscription, LocalDate cancellationDate) { ... }
```

---

## Static Analysis Compliance

Generated code must produce zero violations for:

- **Checkstyle** — Javadoc presence, import order, naming.
- **SpotBugs** — null dereferences, resource leaks, incorrect `equals`.
- **PMD** — unused variables, overly complex methods, error-prone patterns.
