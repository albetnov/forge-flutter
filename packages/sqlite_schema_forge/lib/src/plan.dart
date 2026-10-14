enum ChangeType {
  createTable,
  addColumn,
  rebuildTable,
  createIndex,
  dropIndex,
  executeCallback,
}

final class PlanStep {
  final ChangeType type;
  final String targetTable;
  final String sql;
  final bool isDestructive;
  final String description;

  const PlanStep({
    required this.type,
    required this.targetTable,
    required this.sql,
    required this.description,
    this.isDestructive = false,
  });
}

final class MigrationPlan {
  final int fromVersion;
  final int toVersion;
  final List<PlanStep> steps;

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
