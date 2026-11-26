import 'package:sqlite_schema_forge/sqlite_schema_forge.dart';

import 'schemas.dart';

void main() => print(SchemaSnapshot.encode(schemaV1));
