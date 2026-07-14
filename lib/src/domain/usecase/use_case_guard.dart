import '../../help/error/app_error.dart';
import '../../help/error/app_result.dart';

/// 执行领域动作并将稳定 [AppError] 转换为显式失败结果。
Future<AppResult<T>> guardUseCase<T>(Future<T> Function() operation) async {
  try {
    /// 领域动作成功产生的值。
    final T value = await operation();
    return AppSuccess<T>(value);
  } on AppError catch (error) {
    return AppFailure<T>(error);
  } catch (error, stackTrace) {
    return AppFailure<T>(
      AppError(
        kind: AppErrorKind.unknown,
        message: '领域操作失败',
        cause: error,
        stackTrace: stackTrace,
      ),
    );
  }
}

/// 创建输入校验失败结果，避免 UseCase 把非法值传入 DAO。
AppFailure<T> validationFailure<T>(String message) {
  return AppFailure<T>(
    AppError(kind: AppErrorKind.validation, message: message),
  );
}
