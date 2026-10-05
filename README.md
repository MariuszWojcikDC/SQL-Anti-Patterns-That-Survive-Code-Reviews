# SQL Anti-Patterns

Practical SQL Server anti-patterns: reproducible AdventureWorks demos,
showing how incorrect assumptions can cause non-obvious problems and how to
address them safely.

The examples in this repository were presented at **SQLDay Lite 2026**.

## What is included

- Numbered `.sql` scripts — standalone demonstrations of a specific SQL Server
  anti-pattern, its hidden failure mode, and its recommended solution.

## Requirements

Most examples require:

- SQL Server 2016 or later;
- the AdventureWorks OLTP sample database;
- a client that understands `GO`, such as SQL Server Management Studio or
  `sqlcmd`.

`02-identity-int-exhaustion.sql` and `09-isnumeric-is-not-int-validation.sql`
can run in any demo database. Refer to the header of each script for its exact
requirements and side effects.

## Running the examples

Run each script separately in a non-production environment. The scripts create
demo objects under `dbo` and/or temporary tables, then remove them during their
cleanup section. Some examples intentionally raise errors to demonstrate the
anti-pattern; their comments explain the expected result.

## Examples

| Script | Topic |
| --- | --- |
| `01-select-into-with-identity.sql` | `SELECT INTO` can inherit `IDENTITY`, changing the writable-column contract of `INSERT ... EXEC`. |
| `02-identity-int-exhaustion.sql` | An `int IDENTITY` key reaches its limit and a staged migration to `bigint` preserves availability. |
| `03-unqualified-column-in-subquery.sql` | An unqualified subquery column can bind to the outer query and silently change results. |
| `04-temp-table-collation.sql` | A temporary table can use `tempdb` collation and conflict with a user-database column. |
| `05-isnull-silent-truncation.sql` | `ISNULL` takes the first argument's type and length, which can silently truncate a fallback value. |
| `06-current-assignment-cardinality.sql` | A history-table key may allow multiple simultaneous active assignments for one employee. |
| `07-max-id-concurrent-load.sql` | `MAX(ID) + ROW_NUMBER()` is unsafe under concurrent loads; use `IDENTITY` or `SEQUENCE`. |
| `08-coalesce-hidden-behaviors.sql` | `COALESCE` can evaluate expressions more than once and has type-precedence and nullability implications. |
| `09-isnumeric-is-not-int-validation.sql` | `ISNUMERIC` does not validate an `int` or a business field's expected format. |

## Scope

These are focused teaching examples, not production migration scripts. Before
adopting an approach in production, account for the application's schema,
dependencies, workload, deployment process, and rollback plan.
