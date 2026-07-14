import '../../help/error/app_result.dart';
import '../gateway/book_source_gateway.dart';
import '../model/book_source_import_result.dart';
import 'use_case_guard.dart';

/// 导入 Android 兼容书源 JSON，并由 Repository 保证批量写入原子性。
final class ImportBookSourcesUseCase {
  /// 创建书源导入 UseCase。
  const ImportBookSourcesUseCase(this._gateway);

  /// 书源数据领域边界。
  final BookSourceGateway _gateway;

  /// 校验非空输入后解码并导入，返回新增、覆盖、跳过和无效数量。
  Future<AppResult<BookSourceImportResult>> execute(
    String sourceJson, {
    BookSourceConflictPolicy conflictPolicy = BookSourceConflictPolicy.overwrite,
  }) {
    if (sourceJson.trim().isEmpty) {
      return Future<AppResult<BookSourceImportResult>>.value(
        validationFailure<BookSourceImportResult>('书源 JSON 不能为空'),
      );
    }
    return guardUseCase<BookSourceImportResult>(
      () => _gateway.importSourceJson(
        sourceJson,
        conflictPolicy: conflictPolicy,
      ),
    );
  }
}
