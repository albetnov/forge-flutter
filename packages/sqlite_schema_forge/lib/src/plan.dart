/// Kind of work a single [PlanStep] performs.
enum ChangeType {
  /// Create a missing table.
  createTable,

  /// Add a column to an existing table.
  addColumn,

  /// Copy-and-swap an existing table (SQLite cannot drop or retype columns
  /// in place).
  rebuildTable,

  /// Create a missing index.
  createIndex,

  /// Drop an index that is no longer declared.
  dropIndex,

  /// Run a user-supplied migration callback.
  executeCallback,
}

/// One step in a [MigrationPlan].
final class PlanStep {
  /// Kind of change this step performs.
  final ChangeType type;

  /// Table the step applies to.
  final String targetTable;

  /// SQL statement(s) executed for the step.
  final String sql;

  /// Whether the step can lose data (drops or a table rebuild).
  final bool isDestructive;

  /// Human-readable summary of the step.
  final String description;

  /// Creates a plan step; [isDestructive] defaults to `false`.
  const PlanStep({
    required this.type,
    required this.targetTable,
    required this.sql,
    required this.description,
    this.isDestructive = false,
  });
}

/// Ordered steps that migrate a database from [fromVersion] to [toVersion].
final class MigrationPlan {
  /// Schema version the plan starts from.
  final int fromVersion;

  /// Schema version the plan migrates to.
  final int toVersion;

  /// Steps to apply, in order.
  final List<PlanStep> steps;

  /// Creates a plan for the given version range and [steps].
  const MigrationPlan({
    required this.fromVersion,
    required this.toVersion,
    required this.steps,
  });

  /// True if any step drops columns/tables or performs a table copy-swap
  bool get hasDestructiveChanges => steps.any((s) => s.isDestructive);

  /// True if current version equals target version
  bool get isUpToDate => steps.isEmpty;
}
