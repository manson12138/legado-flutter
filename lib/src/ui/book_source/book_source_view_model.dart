import 'dart:async';

import '../../domain/gateway/book_source_gateway.dart';
import '../../domain/model/book_source.dart';
import '../../domain/model/book_source_import_result.dart';
import '../../domain/usecase/import_book_sources_use_case.dart';
import '../../help/error/app_result.dart';
import '../../help/logging/app_logger.dart';
import '../../api/http/http_contract.dart';
import '../../model/book_source/book_source_import_text_resolver.dart';
import 'book_source_contract.dart';

/// 管理书源列表、导入、编辑和危险操作确认的 MVI ViewModel。
final class BookSourceManagementViewModel {
  /// 创建书源管理 ViewModel 并开始观察数据库。
  BookSourceManagementViewModel({
    required BookSourceGateway gateway,
    required ImportBookSourcesUseCase importBookSources,
    required BookSourceImportTextResolver importTextResolver,
    required HttpCancellationToken Function() cancellationTokenFactory,
    required AppLogger logger,
  }) : _gateway = gateway,
       _importBookSources = importBookSources,
       _importTextResolver = importTextResolver,
       _cancellationTokenFactory = cancellationTokenFactory,
       _logger = logger {
    _subscribeSources();
  }

  /// 书源持久化领域边界。
  final BookSourceGateway _gateway;

  /// 带输入校验和结果模型的导入用例。
  final ImportBookSourcesUseCase _importBookSources;

  /// 扫码 JSON 或远程书源地址的只读解析服务。
  final BookSourceImportTextResolver _importTextResolver;

  /// 为每次远程扫码导入创建独立网络取消令牌的工厂。
  final HttpCancellationToken Function() _cancellationTokenFactory;

  /// 不记录规则正文、Header 或 Cookie 的日志抽象。
  final AppLogger _logger;

  /// 当前页面状态。
  BookSourceManagementUiState _state = BookSourceManagementUiState();

  /// 页面状态广播流。
  final StreamController<BookSourceManagementUiState> _stateController =
      StreamController<BookSourceManagementUiState>.broadcast();

  /// 一次性副作用广播流。
  final StreamController<BookSourceManagementEffect> _effectController =
      StreamController<BookSourceManagementEffect>.broadcast();

  /// 数据库书源观察订阅。
  StreamSubscription<List<BookSource>>? _sourceSubscription;

  /// 当前扫码书源解析所使用的网络取消令牌。
  HttpCancellationToken? _scanImportCancellationToken;

  /// 【扫码诊断日志】是否正在等待用户确认扫码解析出的书源文本。
  bool _awaitingScannedImportConfirmation = false;

  /// 对 Route 公开的当前状态。
  BookSourceManagementUiState get state => _state;

  /// 对 Route 公开的后续状态流。
  Stream<BookSourceManagementUiState> get states => _stateController.stream;

  /// 对 Route 公开的一次性副作用流。
  Stream<BookSourceManagementEffect> get effects => _effectController.stream;

  /// 书源管理所有用户操作的唯一入口。
  void onIntent(BookSourceManagementIntent intent) {
    switch (intent) {
      case ChangeBookSourceQueryIntent(query: final String query):
        _emit(_state.copyWith(query: query));
      case ChangeBookSourceFilterIntent(filter: final BookSourceFilter filter):
        _emit(_state.copyWith(filter: filter));
      case ToggleBookSourceSelectionIntent(sourceUrl: final String sourceUrl):
        _toggleSelection(sourceUrl);
      case ClearBookSourceSelectionIntent():
        _emit(_state.copyWith(selectedUrls: <String>{}));
      case RequestBookSourceFileIntent():
        _effectController.add(const PickBookSourceFileEffect());
      case RequestBookSourceClipboardIntent():
        _effectController.add(const ReadBookSourceClipboardEffect());
      case RequestBookSourceQrIntent():
        // 【扫码诊断日志】扫一扫添加书源全链路起点。
        _logger.info(message: '$bookSourceQrScanLogTag stage=flow_started');
        _effectController.add(const ScanBookSourceQrEffect());
      case ShowBookSourceTextImportIntent(initialText: final String initialText):
        _emit(_state.copyWith(dialog: ImportTextDialog(initialText: initialText)));
      case ResolveScannedBookSourceIntent(scannedText: final String scannedText):
        _resolveScannedText(scannedText);
      case ImportBookSourceTextIntent(
        text: final String text,
        conflictPolicy: final BookSourceConflictPolicy conflictPolicy,
      ):
        _importText(text, conflictPolicy);
      case SetSingleBookSourceEnabledIntent(
        sourceUrl: final String sourceUrl,
        enabled: final bool enabled,
      ):
        _setEnabled(<String>{sourceUrl}, enabled);
      case SetSelectedBookSourcesEnabledIntent(enabled: final bool enabled):
        _setEnabled(_state.selectedUrls, enabled);
      case RequestSetBookSourceGroupIntent():
        if (_state.selectedUrls.isNotEmpty) {
          _emit(
            _state.copyWith(
              dialog: SetBookSourceGroupDialog(sourceUrls: _state.selectedUrls),
            ),
          );
        }
      case SaveBookSourceGroupIntent(group: final String group):
        _saveGroup(group);
      case RequestAddBookSourceIntent():
        _emit(_state.copyWith(dialog: EditBookSourceDialog(draft: _emptyDraft())));
      case RequestEditBookSourceIntent(sourceUrl: final String sourceUrl):
        _showEditor(sourceUrl);
      case SaveBookSourceDraftIntent(draft: final BookSourceEditorDraft draft):
        _saveDraft(draft);
      case RequestDeleteBookSourcesIntent(sourceUrls: final Set<String>? sourceUrls):
        _requestDelete(sourceUrls);
      case ConfirmDeleteBookSourcesIntent():
        _confirmDelete();
      case DebugBookSourceIntent(sourceUrl: final String sourceUrl):
        _showDebug(sourceUrl);
      case LoginBookSourceIntent(sourceUrl: final String sourceUrl):
        _requestLogin(sourceUrl);
      case DismissBookSourceDialogIntent():
        if (_awaitingScannedImportConfirmation) {
          // 【扫码诊断日志】用户在预览阶段关闭，未执行数据库导入。
          _logger.info(
            message:
                '$bookSourceQrScanLogTag stage=flow_finished result=confirmation_cancelled',
          );
          _awaitingScannedImportConfirmation = false;
        }
        _emit(_state.copyWith(clearDialog: true));
      case RetryBookSourceLoadIntent():
        _subscribeSources();
      case BackFromBookSourceManagementIntent():
        if (_state.selectedUrls.isNotEmpty) {
          _emit(_state.copyWith(selectedUrls: <String>{}));
        } else {
          _effectController.add(const CloseBookSourceManagementEffect());
        }
    }
  }

  /// 观察书源表，并把数据库变化映射成页面状态。
  void _subscribeSources() {
    _sourceSubscription?.cancel();
    _emit(_state.copyWith(loading: true, clearError: true));
    _sourceSubscription = _gateway.watchAll().listen(
      (List<BookSource> sources) {
        /// 仍存在于数据库的选择项。
        final Set<String> existingUrls = sources
            .map((BookSource source) => source.bookSourceUrl)
            .toSet();
        _emit(
          _state.copyWith(
            loading: false,
            sources: sources,
            selectedUrls: _state.selectedUrls.intersection(existingUrls),
            clearError: true,
          ),
        );
      },
      onError: (Object error, StackTrace stackTrace) {
        _logger.error(message: '观察书源列表失败', error: error, stackTrace: stackTrace);
        _emit(
          _state.copyWith(
            loading: false,
            errorMessage: '读取书源失败，请重试。',
          ),
        );
      },
    );
  }

  /// 切换稳定 URL 主键的选择状态。
  void _toggleSelection(String sourceUrl) {
    /// 可修改选择集合。
    final Set<String> selected = Set<String>.from(_state.selectedUrls);
    if (!selected.add(sourceUrl)) {
      selected.remove(sourceUrl);
    }
    _emit(_state.copyWith(selectedUrls: selected));
  }

  /// 导入文本并展示精确统计结果。
  Future<void> _importText(
    String text,
    BookSourceConflictPolicy conflictPolicy,
  ) async {
    /// 【扫码诊断日志】当前导入是否来自刚完成解析的二维码。
    final bool isScannedImport = _awaitingScannedImportConfirmation;
    if (isScannedImport) {
      _awaitingScannedImportConfirmation = false;
      _logger.info(
        message:
            '$bookSourceQrScanLogTag stage=confirmation_accepted policy=${conflictPolicy.name} chars=${text.length}',
      );
      _logger.info(
        message:
            '$bookSourceQrScanLogTag stage=database_import_started policy=${conflictPolicy.name}',
      );
    }
    _emit(_state.copyWith(busy: true, clearDialog: true, clearError: true));
    /// 领域导入结果。
    final AppResult<BookSourceImportResult> result = await _importBookSources.execute(
      text,
      conflictPolicy: conflictPolicy,
    );
    switch (result) {
      case AppSuccess<BookSourceImportResult>(value: final BookSourceImportResult value):
        if (isScannedImport) {
          _logger.info(
            message:
                '$bookSourceQrScanLogTag stage=database_import_finished total=${value.total} added=${value.added} overwritten=${value.overwritten} skipped=${value.skipped} invalid=${value.invalid}',
          );
          _logger.info(
            message:
                '$bookSourceQrScanLogTag stage=flow_finished result=imported total=${value.total} added=${value.added} overwritten=${value.overwritten} skipped=${value.skipped} invalid=${value.invalid}',
          );
        }
        _emit(_state.copyWith(busy: false, dialog: ImportSummaryDialog(result: value)));
      case AppFailure<BookSourceImportResult>(error: final error):
        if (isScannedImport) {
          _logger.warning(
            message: '$bookSourceQrScanLogTag stage=database_import_failed',
            error: error,
          );
          _logger.warning(
            message: '$bookSourceQrScanLogTag stage=flow_finished result=import_failed',
            error: error,
          );
        }
        _emit(_state.copyWith(busy: false, errorMessage: error.message));
        _effectController.add(ShowBookSourceMessageEffect(error.message));
    }
  }

  /// 解析扫码 JSON 或下载远程书源列表，再交给现有导入对话框预览确认。
  Future<void> _resolveScannedText(String scannedText) async {
    if (_state.busy) {
      _logger.warning(
        message: '$bookSourceQrScanLogTag stage=resolve_skipped reason=view_model_busy',
      );
      _effectController.add(const ShowBookSourceMessageEffect('当前正在处理其他书源操作'));
      return;
    }
    // 【扫码诊断日志】进入业务解析阶段，只记录长度，不记录正文。
    _logger.info(
      message: '$bookSourceQrScanLogTag stage=resolve_started chars=${scannedText.length}',
    );
    _scanImportCancellationToken?.cancel('开始新的扫码书源解析');
    /// 本次扫码解析独占的网络取消令牌。
    final HttpCancellationToken cancellationToken = _cancellationTokenFactory();
    _scanImportCancellationToken = cancellationToken;
    _emit(_state.copyWith(busy: true, clearError: true));
    try {
      /// 已下载或保持原样的待确认书源 JSON 文本。
      final String resolvedText = await _importTextResolver.resolve(
        scannedText,
        cancellationToken: cancellationToken,
      );
      if (!identical(_scanImportCancellationToken, cancellationToken)) {
        _logger.debug(
          message: '$bookSourceQrScanLogTag stage=resolve_ignored reason=stale_request',
        );
        return;
      }
      _awaitingScannedImportConfirmation = true;
      _logger.info(
        message:
            '$bookSourceQrScanLogTag stage=confirmation_opening chars=${resolvedText.length}',
      );
      _emit(
        _state.copyWith(
          busy: false,
          dialog: ImportTextDialog(initialText: resolvedText),
        ),
      );
    } on FormatException catch (error) {
      if (identical(_scanImportCancellationToken, cancellationToken)) {
        _logger.warning(
          message: '$bookSourceQrScanLogTag stage=flow_finished result=format_error',
          error: error,
        );
        _showScanImportError(error.message.toString());
      }
    } on UnifiedHttpException catch (error) {
      if (identical(_scanImportCancellationToken, cancellationToken) &&
          error.kind != HttpFailureKind.cancelled) {
        _logger.warning(
          message:
              '$bookSourceQrScanLogTag stage=flow_finished result=http_error kind=${error.kind.name} status=${error.statusCode ?? 'none'}',
          error: error,
        );
        _showScanImportError('读取远程书源失败：${error.message}');
      } else if (error.kind == HttpFailureKind.cancelled) {
        _logger.info(
          message: '$bookSourceQrScanLogTag stage=flow_finished result=request_cancelled',
        );
      }
    } catch (error, stackTrace) {
      if (identical(_scanImportCancellationToken, cancellationToken)) {
        _logger.error(
          message: '$bookSourceQrScanLogTag stage=flow_finished result=unexpected_error',
          error: error,
          stackTrace: stackTrace,
        );
        _showScanImportError('无法识别二维码中的书源内容');
      }
    } finally {
      if (identical(_scanImportCancellationToken, cancellationToken)) {
        _scanImportCancellationToken = null;
      }
    }
  }

  /// 发布扫码导入失败状态和不包含二维码原文、目标地址的安全提示。
  void _showScanImportError(String message) {
    _emit(_state.copyWith(busy: false, errorMessage: message));
    _effectController.add(ShowBookSourceMessageEffect(message));
  }

  /// 批量修改启用状态。
  Future<void> _setEnabled(Set<String> sourceUrls, bool enabled) async {
    if (sourceUrls.isEmpty) {
      return;
    }
    await _runWrite(
      operation: () => _gateway.setEnabled(sourceUrls, enabled: enabled),
      successMessage: enabled ? '已启用 ${sourceUrls.length} 个书源' : '已停用 ${sourceUrls.length} 个书源',
      clearSelection: sourceUrls.length > 1,
    );
  }

  /// 保存选中书源的新分组。
  Future<void> _saveGroup(String group) async {
    /// 当前对话框保存的目标 URL。
    final Set<String> sourceUrls = switch (_state.dialog) {
      SetBookSourceGroupDialog(sourceUrls: final Set<String> urls) => urls,
      _ => <String>{},
    };
    if (sourceUrls.isEmpty) {
      return;
    }
    await _runWrite(
      operation: () => _gateway.setGroup(sourceUrls, group.trim()),
      successMessage: group.trim().isEmpty ? '已清除分组' : '已设置分组：${group.trim()}',
      clearSelection: true,
    );
  }

  /// 显示已有书源编辑草稿。
  Future<void> _showEditor(String sourceUrl) async {
    /// 数据库观察状态中的目标书源。
    final BookSource? source = _findSource(sourceUrl);
    if (source == null) {
      _effectController.add(const ShowBookSourceMessageEffect('书源已不存在'));
      return;
    }
    try {
      /// Flutter 独立缓存中保存的书源自定义变量。
      final String variable = await _gateway.getSourceVariable(sourceUrl);
      if (_findSource(sourceUrl) == null) {
        _effectController.add(const ShowBookSourceMessageEffect('书源已不存在'));
        return;
      }
      _emit(
        _state.copyWith(
          dialog: EditBookSourceDialog(
            draft: _draftFromSource(source, variable: variable),
          ),
        ),
      );
    } catch (error, stackTrace) {
      _logger.error(
        message: '读取书源变量失败',
        error: error,
        stackTrace: stackTrace,
      );
      _effectController.add(const ShowBookSourceMessageEffect('读取书源变量失败'));
    }
  }

  /// 校验并保存书源草稿。
  Future<void> _saveDraft(BookSourceEditorDraft draft) async {
    if (draft.name.trim().isEmpty || draft.url.trim().isEmpty) {
      _effectController.add(const ShowBookSourceMessageEffect('书源名称和 URL 不能为空'));
      return;
    }
    /// 书源类型解析结果。
    final int? sourceType = int.tryParse(draft.type.trim());
    if (sourceType == null || sourceType < 0 || sourceType > 4) {
      _effectController.add(const ShowBookSourceMessageEffect('书源类型必须是 0～4'));
      return;
    }
    /// 编辑前原始书源；新增时为空。
    final BookSource? original = draft.originalUrl.isEmpty ? null : _findSource(draft.originalUrl);
    /// 当前毫秒更新时间。
    final int updatedAt = DateTime.now().millisecondsSinceEpoch;
    /// 完整持久化书源，未在第一批编辑器展示的字段沿用原值。
    final BookSource source = BookSource(
      bookSourceUrl: draft.url.trim(),
      bookSourceName: draft.name.trim(),
      bookSourceGroup: _nullableText(draft.group),
      bookSourceType: sourceType,
      bookUrlPattern: original?.bookUrlPattern,
      customOrder: original?.customOrder ?? _state.sources.length,
      enabled: draft.enabled,
      enabledExplore: draft.enabledExplore,
      jsLib: _nullableText(draft.jsLib),
      enabledCookieJar: original?.enabledCookieJar ?? true,
      concurrentRate: original?.concurrentRate,
      header: _nullableText(draft.header),
      loginUrl: _nullableText(draft.loginUrl),
      loginUi: _nullableText(draft.loginUi),
      loginCheckJs: _nullableText(draft.loginCheckJs),
      coverDecodeJs: original?.coverDecodeJs,
      bookSourceComment: _nullableText(draft.comment),
      variableComment: original?.variableComment,
      lastUpdateTime: updatedAt,
      respondTime: original?.respondTime ?? 180000,
      weight: original?.weight ?? 0,
      exploreUrl: _nullableText(draft.exploreUrl),
      exploreScreen: original?.exploreScreen,
      ruleExplore: original?.ruleExplore,
      searchUrl: _nullableText(draft.searchUrl),
      ruleSearch: _nullableText(draft.ruleSearch),
      ruleBookInfo: _nullableText(draft.ruleBookInfo),
      ruleToc: _nullableText(draft.ruleToc),
      ruleContent: _nullableText(draft.ruleContent),
      ruleReview: original?.ruleReview,
      eventListener: original?.eventListener ?? false,
      customButton: original?.customButton ?? false,
      homepageModules: original?.homepageModules,
      extraFieldsJson: original?.extraFieldsJson,
    );
    await _runWrite(
      operation: () async {
        /// 编辑前主键；新增书源时为空。
        final String? previousUrl = draft.originalUrl.isEmpty ? null : draft.originalUrl;
        await _gateway.saveSource(source, previousUrl: previousUrl);
        await _gateway.saveSourceVariable(
          source.bookSourceUrl,
          draft.variable.isEmpty ? null : draft.variable,
        );
        if (previousUrl != null && previousUrl != source.bookSourceUrl) {
          await _gateway.saveSourceVariable(previousUrl, null);
        }
      },
      successMessage: original == null ? '书源已新增' : '书源已保存',
    );
  }

  /// 显示删除确认，禁止无确认直接删除。
  void _requestDelete(Set<String>? explicitUrls) {
    /// 本次删除目标。
    final Set<String> sourceUrls = explicitUrls ?? _state.selectedUrls;
    if (sourceUrls.isEmpty) {
      return;
    }
    _emit(_state.copyWith(dialog: DeleteBookSourcesDialog(sourceUrls: sourceUrls)));
  }

  /// 删除确认对话框中的书源。
  Future<void> _confirmDelete() async {
    /// 当前确认对话框中的 URL。
    final Set<String> sourceUrls = switch (_state.dialog) {
      DeleteBookSourcesDialog(sourceUrls: final Set<String> urls) => urls,
      _ => <String>{},
    };
    if (sourceUrls.isEmpty) {
      return;
    }
    await _runWrite(
      operation: () => _gateway.deleteByUrls(sourceUrls),
      successMessage: '已删除 ${sourceUrls.length} 个书源；书架书籍未删除',
      clearSelection: true,
    );
  }

  /// 根据规则字段生成不执行网络的基础诊断结果。
  void _showDebug(String sourceUrl) {
    /// 待诊断书源。
    final BookSource? source = _findSource(sourceUrl);
    if (source == null) {
      return;
    }
    /// 规则与平台能力诊断项。
    final List<BookSourceDebugItem> items = <BookSourceDebugItem>[
      BookSourceDebugItem(
        category: '网络',
        message: source.searchUrl?.trim().isNotEmpty == true
            ? '已配置搜索地址；真实请求需在搜索调试阶段执行。'
            : '缺少搜索地址。',
        isError: source.searchUrl?.trim().isEmpty ?? true,
      ),
      BookSourceDebugItem(
        category: '规则',
        message: source.ruleSearch?.trim().isNotEmpty == true
            ? '已配置搜索规则。'
            : '缺少搜索规则。',
        isError: source.ruleSearch?.trim().isEmpty ?? true,
      ),
      ..._javaScriptDebugItems(source),
    ];
    _emit(
      _state.copyWith(
        dialog: BookSourceDebugDialog(sourceName: source.bookSourceName, items: items),
      ),
    );
  }

  /// 识别 JavaScript、Rhino 类和 WebView 依赖。
  List<BookSourceDebugItem> _javaScriptDebugItems(BookSource source) {
    /// 不写入日志的脚本聚合文本。
    final String scriptText = <String?>[
      source.jsLib,
      source.searchUrl,
      source.ruleSearch,
      source.ruleBookInfo,
      source.ruleToc,
      source.ruleContent,
      source.loginCheckJs,
    ].whereType<String>().join('\n');
    if (scriptText.contains('Packages.') || scriptText.contains('JavaImporter')) {
      return const <BookSourceDebugItem>[
        BookSourceDebugItem(
          category: 'JavaScript',
          message: '检测到 Rhino/Java 专属 API；iOS 必须明确拒绝或使用白名单替代。',
          isError: true,
        ),
      ];
    }
    if (scriptText.contains('java.webView') || scriptText.contains('startBrowserAwait')) {
      return const <BookSourceDebugItem>[
        BookSourceDebugItem(
          category: 'JavaScript',
          message: '检测到 WebView/浏览器依赖；页面桥已接入，但历史同步 Rhino 调用与 Promise 语义仍需兼容结论。',
          isError: true,
        ),
      ];
    }
    if (scriptText.contains('java.ajax') || scriptText.contains('java.connect')) {
      return const <BookSourceDebugItem>[
        BookSourceDebugItem(
          category: 'JavaScript',
          message: '检测到同步网络 helper；需要核对 Rhino 字符串与 Promise 语义。',
          isError: true,
        ),
      ];
    }
    if (scriptText.contains('@js:') || scriptText.contains('<js>') || source.jsLib != null) {
      return const <BookSourceDebugItem>[
        BookSourceDebugItem(
          category: 'JavaScript',
          message: '检测到标准 JavaScript；等待 M4 真机样本验证。',
          isError: false,
        ),
      ];
    }
    return const <BookSourceDebugItem>[
      BookSourceDebugItem(
        category: 'JavaScript',
        message: '未检测到 JavaScript 规则。',
        isError: false,
      ),
    ];
  }

  /// 执行受控写操作并统一恢复忙碌状态。
  Future<void> _runWrite({
    required Future<void> Function() operation,
    required String successMessage,
    bool clearSelection = false,
  }) async {
    _emit(_state.copyWith(busy: true, clearDialog: true, clearError: true));
    try {
      await operation();
      _emit(
        _state.copyWith(
          busy: false,
          selectedUrls: clearSelection ? <String>{} : _state.selectedUrls,
        ),
      );
      _effectController.add(ShowBookSourceMessageEffect(successMessage));
    } catch (error, stackTrace) {
      _logger.error(message: '书源管理写入失败', error: error, stackTrace: stackTrace);
      _emit(_state.copyWith(busy: false, errorMessage: '操作失败，已有书源未被修改。'));
      _effectController.add(const ShowBookSourceMessageEffect('操作失败，已有书源未被修改。'));
    }
  }

  /// 根据稳定书源 URL 找到登录配置，优先打开 `loginUrl`，缺失时回退书源主页。
  void _requestLogin(String sourceUrl) {
    /// 当前用户请求登录的书源。
    final BookSource? source = _findSource(sourceUrl);
    if (source == null) {
      _effectController.add(const ShowBookSourceMessageEffect('书源已经不存在'));
      return;
    }
    /// 去除空白后的显式登录地址；空值表示书源没有单独登录页。
    final String configuredLoginUrl = source.loginUrl?.trim() ?? '';
    /// 实际交给受控 WebView 的地址。
    final String targetUrl = configuredLoginUrl.isEmpty
        ? source.bookSourceUrl
        : configuredLoginUrl;
    _effectController.add(OpenBookSourceLoginEffect(targetUrl));
  }

  /// 按 URL 查找当前状态中的书源。
  BookSource? _findSource(String sourceUrl) {
    for (final BookSource source in _state.sources) {
      if (source.bookSourceUrl == sourceUrl) {
        return source;
      }
    }
    return null;
  }

  /// 创建新增书源的空白编辑草稿。
  BookSourceEditorDraft _emptyDraft() {
    return const BookSourceEditorDraft(
      originalUrl: '',
      name: '',
      url: '',
      group: '',
      type: '0',
      enabled: true,
      enabledExplore: true,
      header: '',
      searchUrl: '',
      exploreUrl: '',
      jsLib: '',
      ruleSearch: '',
      ruleBookInfo: '',
      ruleToc: '',
      ruleContent: '',
      loginUrl: '',
      loginUi: '',
      loginCheckJs: '',
      variable: '',
      comment: '',
    );
  }

  /// 将完整书源转换为第一批编辑器草稿。
  BookSourceEditorDraft _draftFromSource(
    BookSource source, {
    required String variable,
  }) {
    return BookSourceEditorDraft(
      originalUrl: source.bookSourceUrl,
      name: source.bookSourceName,
      url: source.bookSourceUrl,
      group: source.bookSourceGroup ?? '',
      type: source.bookSourceType.toString(),
      enabled: source.enabled,
      enabledExplore: source.enabledExplore,
      header: source.header ?? '',
      searchUrl: source.searchUrl ?? '',
      exploreUrl: source.exploreUrl ?? '',
      jsLib: source.jsLib ?? '',
      ruleSearch: source.ruleSearch ?? '',
      ruleBookInfo: source.ruleBookInfo ?? '',
      ruleToc: source.ruleToc ?? '',
      ruleContent: source.ruleContent ?? '',
      loginUrl: source.loginUrl ?? '',
      loginUi: source.loginUi ?? '',
      loginCheckJs: source.loginCheckJs ?? '',
      variable: variable,
      comment: source.bookSourceComment ?? '',
    );
  }

  /// 将空白编辑字段转换为 null，保留非空脚本中的反斜杠和换行。
  String? _nullableText(String value) {
    return value.isEmpty ? null : value;
  }

  /// 发布新状态。
  void _emit(BookSourceManagementUiState state) {
    _state = state;
    if (!_stateController.isClosed) {
      _stateController.add(state);
    }
  }

  /// 释放数据库观察、状态流和 Effect 流。
  Future<void> dispose() async {
    if (_scanImportCancellationToken != null) {
      // 【扫码诊断日志】页面退出时取消仍在进行的远程书源请求。
      _logger.info(
        message: '$bookSourceQrScanLogTag stage=flow_finished result=page_disposed',
      );
    }
    _scanImportCancellationToken?.cancel('书源管理页面已关闭');
    await _sourceSubscription?.cancel();
    await _stateController.close();
    await _effectController.close();
  }
}
