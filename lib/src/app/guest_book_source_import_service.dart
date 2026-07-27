import 'dart:convert';

import '../api/http/http_contract.dart';
import '../api/remote_app/remote_app_api.dart';
import '../domain/model/book_source_import_result.dart';
import '../domain/usecase/import_book_sources_use_case.dart';
import '../help/error/app_result.dart';
import '../help/logging/app_logger.dart';
import '../model/book_source/book_source_import_text_resolver.dart';

/// 游客 URL 或邀请码书源导入的当前阶段。
enum GuestBookSourceImportStage {
  /// 正在判断输入属于远程地址还是管理员邀请码。
  resolvingInput,

  /// 正在下载 URL 返回的书源 JSON。
  downloadingUrl,

  /// 正在使用管理员邀请码兑换临时游客凭证。
  exchangingInvitation,

  /// 正在获取一批游客可见书源。
  fetchingBatch,

  /// 正在通过既有 JSON 导入事务提交当前批次。
  importingBatch,
}

/// 游客书源导入的计数型进度，不携带输入、Token 或书源内容。
final class GuestBookSourceImportProgress {
  /// 创建可安全展示的游客导入进度。
  const GuestBookSourceImportProgress({
    required this.stage,
    this.batchNumber,
    this.processedCount = 0,
    this.totalCount,
  });

  /// 当前执行阶段。
  final GuestBookSourceImportStage stage;

  /// 当前游客分页批次，从一开始。
  final int? batchNumber;

  /// 已经成功提交导入事务的服务端条目数。
  final int processedCount;

  /// 服务端最近声明的实时总数，仅用于展示。
  final int? totalCount;
}

/// 接收不包含敏感数据的游客书源导入进度。
typedef GuestBookSourceImportProgressListener =
    void Function(GuestBookSourceImportProgress progress);

/// 游客输入处理完成后的受控结果。
sealed class GuestBookSourceInputResult {
  /// 限制结果类型只能由本文件声明。
  const GuestBookSourceInputResult();
}

/// URL 已解析为待现有导入对话框确认的 JSON 文本。
final class GuestBookSourceUrlResolved extends GuestBookSourceInputResult {
  /// 创建 URL JSON 解析结果。
  const GuestBookSourceUrlResolved(this.sourceJson);

  /// 下载并完成字符集解码的不可信书源 JSON。
  final String sourceJson;
}

/// 管理员邀请码游客分页同步完成后的安全摘要。
final class GuestBookSourceInvitationImported
    extends GuestBookSourceInputResult {
  /// 创建游客分页同步摘要。
  const GuestBookSourceInvitationImported({
    required this.importedCount,
    required this.invalidCount,
    required this.blockedCount,
    required this.processedCount,
    required this.batchCount,
    required this.totalCount,
  });

  /// 本轮实际新增或覆盖的本地书源数。
  final int importedCount;

  /// 本轮无法转换为有效书源的条目数。
  final int invalidCount;

  /// 本轮命中本地成人内容策略的数量；同步时只统计而不删除远端事实。
  final int blockedCount;

  /// 本轮成功提交事务的服务端条目总数。
  final int processedCount;

  /// 本轮成功提交的分页批次数。
  final int batchCount;

  /// 最后一批响应声明的实时总数。
  final int totalCount;
}

/// 游客 URL/邀请码导入的稳定失败分类。
enum GuestBookSourceImportFailureKind {
  /// 输入既不是有效 URL，也不是安全的邀请码候选。
  invalidInput,

  /// 邀请码不存在、无效或已经过期。
  invalidInvitation,

  /// 邀请人、产品、角色或权限不能用于游客同步。
  invitationNotAllowed,

  /// 服务端限制了当前请求频率。
  rateLimited,

  /// 临时游客凭证在分页期间失效。
  sessionExpired,

  /// App HMAC 或设备时间未通过服务端校验。
  signatureRejected,

  /// URL 或游客 API 网络请求失败。
  network,

  /// 服务端响应信封、凭证或游标协议不符合约定。
  protocol,

  /// 当前批次未能通过既有书源导入事务。
  importFailed,

  /// 页面离开或会话切换主动取消了请求。
  cancelled,
}

/// 游客导入失败的安全异常，不携带原始输入和远端响应正文。
final class GuestBookSourceImportException implements Exception {
  /// 创建可由 Route 转换为固定用户提示的异常。
  const GuestBookSourceImportException(this.kind, this.message);

  /// 稳定失败分类。
  final GuestBookSourceImportFailureKind kind;

  /// 不包含敏感值的中文提示。
  final String message;
}

/// 分类游客输入，并编排 URL JSON 或邀请码游标分页导入。
final class GuestBookSourceImportService {
  /// 创建游客书源导入服务。
  GuestBookSourceImportService({
    required RemoteAppApi api,
    required BookSourceImportTextResolver importTextResolver,
    required ImportBookSourcesUseCase importBookSources,
    required AppLogger logger,
  }) : _api = api,
       _importTextResolver = importTextResolver,
       _importBookSources = importBookSources,
       _logger = logger;

  /// 远端游客凭证和分页 API。
  final RemoteAppApi _api;

  /// 复用现有大小、超时和字符集规则的 URL 文本解析器。
  final BookSourceImportTextResolver _importTextResolver;

  /// 既有书源 JSON 校验和原子导入动作。
  final ImportBookSourcesUseCase _importBookSources;

  /// 只记录阶段、数量和错误分类的统一日志边界。
  final AppLogger _logger;

  /// 当前单飞操作，阻止重复提交创建多套游客凭证和分页事务。
  Future<GuestBookSourceInputResult>? _activeOperation;

  /// 分类并处理一次游客输入；并发调用复用当前单飞结果。
  Future<GuestBookSourceInputResult> submit(
    String rawInput, {
    required HttpCancellationToken cancellationToken,
    GuestBookSourceImportProgressListener? onProgress,
  }) {
    /// 已经运行的单飞操作；新调用只等待同一结果。
    final Future<GuestBookSourceInputResult>? activeOperation =
        _activeOperation;
    if (activeOperation != null) {
      return activeOperation;
    }
    /// 本轮新建且在完成后自动清除的游客操作。
    late final Future<GuestBookSourceInputResult> operation;
    operation = _run(
      rawInput,
      cancellationToken: cancellationToken,
      onProgress: onProgress,
    ).whenComplete(() {
      if (identical(_activeOperation, operation)) {
        _activeOperation = null;
      }
    });
    _activeOperation = operation;
    return operation;
  }

  /// 执行输入分类，并保证失败日志不附带原始输入或凭证。
  Future<GuestBookSourceInputResult> _run(
    String rawInput, {
    required HttpCancellationToken cancellationToken,
    GuestBookSourceImportProgressListener? onProgress,
  }) async {
    /// 仅用于安全耗时分桶和阶段日志的计时器。
    final Stopwatch stopwatch = Stopwatch()..start();
    onProgress?.call(
      const GuestBookSourceImportProgress(
        stage: GuestBookSourceImportStage.resolvingInput,
      ),
    );
    try {
      /// 去除外围空白后只在当前调用栈内短暂保留的输入。
      final String candidate = rawInput.trim();
      /// 不可信输入的分类结果。
      final _GuestBookSourceInputKind inputKind = _classifyInput(candidate);
      _throwIfCancelled(cancellationToken);
      switch (inputKind) {
        case _GuestBookSourceInputKind.remoteUrl:
          _logger.info(
            tag: guestBookSourceImportLogTag,
            message: 'stage=url_started',
          );
          onProgress?.call(
            const GuestBookSourceImportProgress(
              stage: GuestBookSourceImportStage.downloadingUrl,
            ),
          );
          /// 下载后仍需由现有导入对话框确认的不可信 JSON 文本。
          final String sourceJson;
          try {
            sourceJson = await _importTextResolver.resolveRemoteUrl(
              candidate,
              cancellationToken: cancellationToken,
            );
          } on UnifiedHttpException catch (error) {
            throw _mapUrlHttpFailure(error);
          }
          _throwIfCancelled(cancellationToken);
          _logger.info(
            tag: guestBookSourceImportLogTag,
            message:
                'stage=url_completed chars=${sourceJson.length} elapsedMs=${stopwatch.elapsedMilliseconds}',
          );
          return GuestBookSourceUrlResolved(sourceJson);
        case _GuestBookSourceInputKind.invitation:
          return await _syncWithInvitation(
            candidate,
            cancellationToken: cancellationToken,
            onProgress: onProgress,
            stopwatch: stopwatch,
          );
      }
    } on GuestBookSourceImportException catch (error) {
      _logger.warning(
        tag: guestBookSourceImportLogTag,
        message:
            'stage=failed category=${error.kind.name} elapsedMs=${stopwatch.elapsedMilliseconds}',
      );
      rethrow;
    } on FormatException catch (error) {
      _logger.warning(
        tag: guestBookSourceImportLogTag,
        message:
            'stage=failed category=format elapsedMs=${stopwatch.elapsedMilliseconds}',
      );
      throw GuestBookSourceImportException(
        GuestBookSourceImportFailureKind.invalidInput,
        error.message.toString(),
      );
    } on UnifiedHttpException catch (error) {
      /// 统一 HTTP 异常转换后的无敏感值错误。
      final GuestBookSourceImportException safeError =
          _mapHttpFailure(error, exchangingInvitation: false);
      _logger.warning(
        tag: guestBookSourceImportLogTag,
        message:
            'stage=failed category=${safeError.kind.name} elapsedMs=${stopwatch.elapsedMilliseconds}',
      );
      throw safeError;
    } catch (error) {
      _logger.warning(
        tag: guestBookSourceImportLogTag,
        message:
            'stage=failed category=unexpected type=${error.runtimeType} elapsedMs=${stopwatch.elapsedMilliseconds}',
      );
      throw const GuestBookSourceImportException(
        GuestBookSourceImportFailureKind.network,
        '游客书源导入失败，请检查网络后重试',
      );
    }
  }

  /// 使用邀请码兑换内存会话，并逐批获取和提交游客书源。
  Future<GuestBookSourceInvitationImported> _syncWithInvitation(
    String invitationCode, {
    required HttpCancellationToken cancellationToken,
    required Stopwatch stopwatch,
    GuestBookSourceImportProgressListener? onProgress,
  }) async {
    onProgress?.call(
      const GuestBookSourceImportProgress(
        stage: GuestBookSourceImportStage.exchangingInvitation,
      ),
    );
    _logger.info(
      tag: guestBookSourceImportLogTag,
      message: 'stage=invitation_exchange_started',
    );
    /// 只存在于当前调用栈的游客凭证和失效时间。
    final RemoteGuestBookSourceSession session;
    try {
      session = await _api.createGuestBookSourceSession(
        invitationCode,
        cancellationToken: cancellationToken,
      );
    } on RemoteAppBusinessException catch (error) {
      throw _mapBusinessFailure(error, exchangingInvitation: true);
    } on UnifiedHttpException catch (error) {
      throw _mapHttpFailure(error, exchangingInvitation: true);
    }
    _throwIfCancelled(cancellationToken);
    /// 下一批请求使用的内存游标；首次为空。
    int? beforeId;
    /// 已经成功提交导入事务的服务端条目数。
    int processedCount = 0;
    /// 已经成功提交的分页批次数。
    int batchCount = 0;
    /// 最近一批响应声明的实时总数。
    int totalCount = 0;
    /// 本轮实际新增或覆盖的书源数。
    int importedCount = 0;
    /// 本轮无法转换为有效书源的条目数。
    int invalidCount = 0;
    /// 本轮成人内容策略统计数。
    int blockedCount = 0;
    while (true) {
      _throwIfCancelled(cancellationToken);
      if (!DateTime.now().toUtc().isBefore(session.expiresAt)) {
        throw const GuestBookSourceImportException(
          GuestBookSourceImportFailureKind.sessionExpired,
          '游客凭证已过期，请重新输入邀请码',
        );
      }
      /// 当前将要请求的分页批次号。
      final int batchNumber = batchCount + 1;
      onProgress?.call(
        GuestBookSourceImportProgress(
          stage: GuestBookSourceImportStage.fetchingBatch,
          batchNumber: batchNumber,
          processedCount: processedCount,
          totalCount: totalCount == 0 ? null : totalCount,
        ),
      );
      /// 当前游客凭证可见的一批远端书源。
      final RemoteBookSourceCursorPage page;
      try {
        page = await _api.fetchGuestBookSourceCursorPage(
          session.guestToken,
          beforeId: beforeId,
          cancellationToken: cancellationToken,
        );
      } on RemoteAppBusinessException catch (error) {
        throw _mapBusinessFailure(error, exchangingInvitation: false);
      } on UnifiedHttpException catch (error) {
        throw _mapHttpFailure(error, exchangingInvitation: false);
      }
      _validatePage(page, beforeId);
      totalCount = page.total;
      onProgress?.call(
        GuestBookSourceImportProgress(
          stage: GuestBookSourceImportStage.importingBatch,
          batchNumber: batchNumber,
          processedCount: processedCount,
          totalCount: totalCount,
        ),
      );
      if (page.items.isNotEmpty) {
        /// 当前批次通过现有 JSON 导入边界得到的事务结果。
        final AppResult<BookSourceImportResult> importResult =
            await _importBookSources.execute(
              jsonEncode(page.items),
              conflictPolicy: BookSourceConflictPolicy.overwrite,
              filterBlockedSources: false,
            );
        final BookSourceImportResult batchResult = switch (importResult) {
          AppSuccess<BookSourceImportResult>(
            value: final BookSourceImportResult value,
          ) =>
            value,
          AppFailure<BookSourceImportResult>(error: final error) =>
            throw GuestBookSourceImportException(
              GuestBookSourceImportFailureKind.importFailed,
              error.message,
            ),
        };
        importedCount += batchResult.imported;
        invalidCount += batchResult.invalid;
        blockedCount += batchResult.blockedAdult;
      }
      processedCount += page.items.length;
      batchCount = batchNumber;
      _logger.info(
        tag: guestBookSourceImportLogTag,
        message:
            'stage=batch_imported batch=$batchCount processed=$processedCount imported=$importedCount',
      );
      if (!page.hasMore) {
        _logger.info(
          tag: guestBookSourceImportLogTag,
          message:
              'stage=invitation_completed batches=$batchCount processed=$processedCount imported=$importedCount elapsedMs=${stopwatch.elapsedMilliseconds}',
        );
        return GuestBookSourceInvitationImported(
          importedCount: importedCount,
          invalidCount: invalidCount,
          blockedCount: blockedCount,
          processedCount: processedCount,
          batchCount: batchCount,
          totalCount: totalCount,
        );
      }
      beforeId = page.nextCursor;
    }
  }

  /// 把不可信输入严格分类为绝对网络地址或短邀请码候选。
  _GuestBookSourceInputKind _classifyInput(String candidate) {
    if (candidate.isEmpty) {
      throw const GuestBookSourceImportException(
        GuestBookSourceImportFailureKind.invalidInput,
        '请输入书源 URL 或管理员邀请码',
      );
    }
    if (candidate.length > 4096) {
      throw const GuestBookSourceImportException(
        GuestBookSourceImportFailureKind.invalidInput,
        '输入内容过长，请检查后重试',
      );
    }
    /// 尝试按 URI 语法解析，但只接受带 host 的 HTTP/HTTPS。
    final Uri? uri = Uri.tryParse(candidate);
    /// 小写协议；相对文本没有协议。
    final String scheme = uri?.scheme.toLowerCase() ?? '';
    if (scheme == 'http' || scheme == 'https') {
      if (uri == null || uri.host.trim().isEmpty) {
        throw const GuestBookSourceImportException(
          GuestBookSourceImportFailureKind.invalidInput,
          '请输入有效的 HTTP 或 HTTPS 书源地址',
        );
      }
      return _GuestBookSourceInputKind.remoteUrl;
    }
    if ((uri?.hasScheme ?? false) ||
        candidate.contains('://') ||
        candidate.startsWith('{') ||
        candidate.startsWith('[')) {
      throw const GuestBookSourceImportException(
        GuestBookSourceImportFailureKind.invalidInput,
        '只支持 HTTP/HTTPS URL；JSON 请使用“粘贴 JSON 文本”',
      );
    }
    if (candidate.length > 128 || RegExp(r'\s').hasMatch(candidate)) {
      throw const GuestBookSourceImportException(
        GuestBookSourceImportFailureKind.invalidInput,
        '管理员邀请码格式无效',
      );
    }
    return _GuestBookSourceInputKind.invitation;
  }

  /// 校验游客游标协议，拒绝空循环、倒退或完成状态矛盾。
  void _validatePage(RemoteBookSourceCursorPage page, int? beforeId) {
    if (page.total < 0 || page.pageSize != 50) {
      throw const GuestBookSourceImportException(
        GuestBookSourceImportFailureKind.protocol,
        '游客书源同步批次元数据无效',
      );
    }
    if (page.items.isEmpty && page.hasMore) {
      throw const GuestBookSourceImportException(
        GuestBookSourceImportFailureKind.protocol,
        '游客书源同步提前结束',
      );
    }
    /// 服务端提供的下一批游标。
    final int? nextCursor = page.nextCursor;
    if (page.hasMore && (nextCursor == null || nextCursor <= 0)) {
      throw const GuestBookSourceImportException(
        GuestBookSourceImportFailureKind.protocol,
        '游客书源同步游标无效',
      );
    }
    if (!page.hasMore && nextCursor != null) {
      throw const GuestBookSourceImportException(
        GuestBookSourceImportFailureKind.protocol,
        '游客书源同步完成状态无效',
      );
    }
    if (beforeId != null &&
        nextCursor != null &&
        nextCursor >= beforeId) {
      throw const GuestBookSourceImportException(
        GuestBookSourceImportFailureKind.protocol,
        '游客书源同步游标未前进',
      );
    }
  }

  /// 把受控服务端业务失败转换为不包含响应正文的固定提示。
  GuestBookSourceImportException _mapBusinessFailure(
    RemoteAppBusinessException error, {
    required bool exchangingInvitation,
  }) {
    if (error.statusCode == 429) {
      return const GuestBookSourceImportException(
        GuestBookSourceImportFailureKind.rateLimited,
        '请求过于频繁，请稍后重试',
      );
    }
    if (error.statusCode == 403) {
      return const GuestBookSourceImportException(
        GuestBookSourceImportFailureKind.invitationNotAllowed,
        '该邀请码不能用于游客书源同步',
      );
    }
    if (error.statusCode == 400 ||
        error.statusCode == 404 ||
        error.statusCode == 410) {
      return const GuestBookSourceImportException(
        GuestBookSourceImportFailureKind.invalidInvitation,
        '邀请码无效或已过期',
      );
    }
    if (error.statusCode == 401) {
      return exchangingInvitation
          ? const GuestBookSourceImportException(
              GuestBookSourceImportFailureKind.signatureRejected,
              '应用签名或设备时间校验失败',
            )
          : const GuestBookSourceImportException(
              GuestBookSourceImportFailureKind.sessionExpired,
              '游客凭证已失效，请重新输入邀请码',
            );
    }
    return const GuestBookSourceImportException(
      GuestBookSourceImportFailureKind.network,
      '游客书源服务请求失败，请稍后重试',
    );
  }

  /// 把统一 HTTP 失败转换为游客流程固定提示。
  GuestBookSourceImportException _mapHttpFailure(
    UnifiedHttpException error, {
    required bool exchangingInvitation,
  }) {
    if (error.kind == HttpFailureKind.cancelled) {
      return const GuestBookSourceImportException(
        GuestBookSourceImportFailureKind.cancelled,
        '游客书源导入已取消',
      );
    }
    if (error.statusCode == 429) {
      return const GuestBookSourceImportException(
        GuestBookSourceImportFailureKind.rateLimited,
        '请求过于频繁，请稍后重试',
      );
    }
    if (error.statusCode == 401) {
      return exchangingInvitation
          ? const GuestBookSourceImportException(
              GuestBookSourceImportFailureKind.signatureRejected,
              '应用签名或设备时间校验失败',
            )
          : const GuestBookSourceImportException(
              GuestBookSourceImportFailureKind.sessionExpired,
              '游客凭证已失效，请重新输入邀请码',
            );
    }
    if (error.statusCode == 403) {
      return const GuestBookSourceImportException(
        GuestBookSourceImportFailureKind.invitationNotAllowed,
        '该邀请码不能用于游客书源同步',
      );
    }
    if (error.statusCode == 400 ||
        error.statusCode == 404 ||
        error.statusCode == 410) {
      return const GuestBookSourceImportException(
        GuestBookSourceImportFailureKind.invalidInvitation,
        '邀请码无效或已过期',
      );
    }
    if (error.kind == HttpFailureKind.decode) {
      return const GuestBookSourceImportException(
        GuestBookSourceImportFailureKind.protocol,
        '游客书源服务返回格式异常',
      );
    }
    return const GuestBookSourceImportException(
      GuestBookSourceImportFailureKind.network,
      '网络请求失败，请检查网络后重试',
    );
  }

  /// 把普通 URL 下载失败转换为不涉及游客凭证的固定提示。
  GuestBookSourceImportException _mapUrlHttpFailure(
    UnifiedHttpException error,
  ) {
    if (error.kind == HttpFailureKind.cancelled) {
      return const GuestBookSourceImportException(
        GuestBookSourceImportFailureKind.cancelled,
        '游客书源导入已取消',
      );
    }
    if (error.kind == HttpFailureKind.decode) {
      return const GuestBookSourceImportException(
        GuestBookSourceImportFailureKind.protocol,
        '远程书源 JSON 响应无法解码',
      );
    }
    return const GuestBookSourceImportException(
      GuestBookSourceImportFailureKind.network,
      '读取远程书源失败，请检查地址和网络',
    );
  }

  /// 在网络或数据库批次之间响应页面销毁和会话切换。
  void _throwIfCancelled(HttpCancellationToken cancellationToken) {
    if (cancellationToken.isCancelled) {
      throw const GuestBookSourceImportException(
        GuestBookSourceImportFailureKind.cancelled,
        '游客书源导入已取消',
      );
    }
  }
}

/// 游客输入的内部分类，不越过应用服务边界。
enum _GuestBookSourceInputKind {
  /// 绝对 HTTP/HTTPS 远程 JSON 地址。
  remoteUrl,

  /// 需要交给固定 App API 验证的管理员邀请码。
  invitation,
}
