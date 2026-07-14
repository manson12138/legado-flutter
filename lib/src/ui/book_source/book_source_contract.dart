import '../../domain/model/book_source.dart';
import '../../domain/model/book_source_import_result.dart';

/// 书源列表当前筛选范围。
enum BookSourceFilter {
  /// 展示全部书源。
  all,

  /// 只展示启用书源。
  enabled,

  /// 只展示停用书源。
  disabled,

  /// 只展示未分组书源。
  ungrouped,

  /// 只展示包含 JavaScript 的书源。
  javaScript,
}

/// 书源编辑器使用的不可变草稿。
final class BookSourceEditorDraft {
  /// 创建包含完整第一批可编辑字段的草稿。
  const BookSourceEditorDraft({
    required this.originalUrl,
    required this.name,
    required this.url,
    required this.group,
    required this.type,
    required this.enabled,
    required this.enabledExplore,
    required this.header,
    required this.searchUrl,
    required this.exploreUrl,
    required this.jsLib,
    required this.ruleSearch,
    required this.ruleBookInfo,
    required this.ruleToc,
    required this.ruleContent,
    required this.loginUrl,
    required this.loginUi,
    required this.loginCheckJs,
    required this.comment,
  });

  /// 编辑前的主键 URL；新增书源时为空。
  final String originalUrl;

  /// 书源显示名称。
  final String name;

  /// 书源主键 URL。
  final String url;

  /// 逗号分隔的分组文本。
  final String group;

  /// Android 兼容书源类型文本。
  final String type;

  /// 是否参与搜索。
  final bool enabled;

  /// 是否参与发现。
  final bool enabledExplore;

  /// 请求 Header JSON 或规则文本。
  final String header;

  /// 搜索 URL 或脚本。
  final String searchUrl;

  /// 发现 URL 或脚本。
  final String exploreUrl;

  /// 公共 JavaScript 库。
  final String jsLib;

  /// 搜索规则 JSON 或文本。
  final String ruleSearch;

  /// 详情规则 JSON 或文本。
  final String ruleBookInfo;

  /// 目录规则 JSON 或文本。
  final String ruleToc;

  /// 正文规则 JSON 或文本。
  final String ruleContent;

  /// 登录页面地址。
  final String loginUrl;

  /// 登录表单定义。
  final String loginUi;

  /// 登录检测脚本。
  final String loginCheckJs;

  /// 书源说明。
  final String comment;
}

/// 基础调试中单个检查项的结果。
final class BookSourceDebugItem {
  /// 创建带类别和说明的调试项。
  const BookSourceDebugItem({
    required this.category,
    required this.message,
    required this.isError,
  });

  /// 网络、规则或 JavaScript 分类。
  final String category;

  /// 不包含 Cookie、Header 正文或脚本正文的诊断说明。
  final String message;

  /// 是否为阻塞当前书源执行的错误。
  final bool isError;
}

/// 书源管理页面当前显示的对话框。
sealed class BookSourceDialog {
  /// 限制对话框类型只能由本文件声明。
  const BookSourceDialog();
}

/// 文本或剪贴板导入对话框。
final class ImportTextDialog extends BookSourceDialog {
  /// 创建文本导入对话框。
  const ImportTextDialog({required this.initialText});

  /// 剪贴板或空白初始文本。
  final String initialText;
}

/// 新增或编辑书源对话框。
final class EditBookSourceDialog extends BookSourceDialog {
  /// 创建编辑对话框。
  const EditBookSourceDialog({required this.draft});

  /// 页面需要渲染的编辑草稿。
  final BookSourceEditorDraft draft;
}

/// 删除书源确认对话框。
final class DeleteBookSourcesDialog extends BookSourceDialog {
  /// 创建删除确认对话框。
  DeleteBookSourcesDialog({required Set<String> sourceUrls})
      : sourceUrls = Set<String>.unmodifiable(sourceUrls);

  /// 待删除书源主键集合。
  final Set<String> sourceUrls;
}

/// 批量设置分组对话框。
final class SetBookSourceGroupDialog extends BookSourceDialog {
  /// 创建分组输入对话框。
  SetBookSourceGroupDialog({required Set<String> sourceUrls})
      : sourceUrls = Set<String>.unmodifiable(sourceUrls);

  /// 待修改书源主键集合。
  final Set<String> sourceUrls;
}

/// 导入结果摘要对话框。
final class ImportSummaryDialog extends BookSourceDialog {
  /// 创建导入摘要对话框。
  const ImportSummaryDialog({required this.result});

  /// 包含新增、覆盖、跳过和失败数量的结果。
  final BookSourceImportResult result;
}

/// 基础调试结果对话框。
final class BookSourceDebugDialog extends BookSourceDialog {
  /// 创建不可变调试结果对话框。
  BookSourceDebugDialog({required this.sourceName, required List<BookSourceDebugItem> items})
      : items = List<BookSourceDebugItem>.unmodifiable(items);

  /// 当前被调试书源名称。
  final String sourceName;

  /// 分类后的调试结果。
  final List<BookSourceDebugItem> items;
}

/// 书源管理页面长期状态。
final class BookSourceManagementUiState {
  /// 创建不可变页面状态。
  BookSourceManagementUiState({
    this.loading = true,
    this.busy = false,
    List<BookSource> sources = const <BookSource>[],
    this.query = '',
    this.filter = BookSourceFilter.all,
    Set<String> selectedUrls = const <String>{},
    this.dialog,
    this.errorMessage,
  }) : sources = List<BookSource>.unmodifiable(sources),
       selectedUrls = Set<String>.unmodifiable(selectedUrls);

  /// 是否仍在等待首次数据库结果。
  final bool loading;

  /// 是否正在执行写入、导入或删除。
  final bool busy;

  /// 数据库提供的全部书源。
  final List<BookSource> sources;

  /// 当前名称、URL 或分组搜索词。
  final String query;

  /// 当前筛选范围。
  final BookSourceFilter filter;

  /// 选择模式中的书源 URL。
  final Set<String> selectedUrls;

  /// 当前需要展示的业务对话框。
  final BookSourceDialog? dialog;

  /// 可恢复错误摘要。
  final String? errorMessage;

  /// 根据搜索词和筛选器生成可见列表。
  List<BookSource> get visibleSources {
    /// 小写搜索词。
    final String normalizedQuery = query.trim().toLowerCase();
    return sources.where((BookSource source) {
      /// 当前书源是否符合类型筛选。
      final bool matchesFilter = switch (filter) {
        BookSourceFilter.all => true,
        BookSourceFilter.enabled => source.enabled,
        BookSourceFilter.disabled => !source.enabled,
        BookSourceFilter.ungrouped => source.bookSourceGroup?.trim().isEmpty ?? true,
        BookSourceFilter.javaScript => _containsJavaScript(source),
      };
      if (!matchesFilter || normalizedQuery.isEmpty) {
        return matchesFilter;
      }
      return source.bookSourceName.toLowerCase().contains(normalizedQuery) ||
          source.bookSourceUrl.toLowerCase().contains(normalizedQuery) ||
          (source.bookSourceGroup?.toLowerCase().contains(normalizedQuery) ?? false);
    }).toList(growable: false);
  }

  /// 判断书源核心字段是否包含 JavaScript 规则。
  static bool _containsJavaScript(BookSource source) {
    /// 需要扫描的脚本相关字段。
    final List<String?> values = <String?>[
      source.jsLib,
      source.searchUrl,
      source.exploreUrl,
      source.ruleSearch,
      source.ruleBookInfo,
      source.ruleToc,
      source.ruleContent,
      source.loginCheckJs,
    ];
    return values.any((String? value) {
      /// 当前字段的小写文本。
      final String text = value?.toLowerCase() ?? '';
      return text.contains('@js:') || text.contains('<js>') || text.contains('java.');
    });
  }

  /// 复制页面状态并替换指定字段。
  BookSourceManagementUiState copyWith({
    bool? loading,
    bool? busy,
    List<BookSource>? sources,
    String? query,
    BookSourceFilter? filter,
    Set<String>? selectedUrls,
    BookSourceDialog? dialog,
    bool clearDialog = false,
    String? errorMessage,
    bool clearError = false,
  }) {
    return BookSourceManagementUiState(
      loading: loading ?? this.loading,
      busy: busy ?? this.busy,
      sources: sources ?? this.sources,
      query: query ?? this.query,
      filter: filter ?? this.filter,
      selectedUrls: selectedUrls ?? this.selectedUrls,
      dialog: clearDialog ? null : dialog ?? this.dialog,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
    );
  }
}

/// 书源管理页面的全部用户意图。
sealed class BookSourceManagementIntent {
  /// 限制意图类型只能由本文件声明。
  const BookSourceManagementIntent();
}

/// 修改搜索词。
final class ChangeBookSourceQueryIntent extends BookSourceManagementIntent {
  /// 创建搜索意图。
  const ChangeBookSourceQueryIntent(this.query);

  /// 新搜索词。
  final String query;
}

/// 修改筛选范围。
final class ChangeBookSourceFilterIntent extends BookSourceManagementIntent {
  /// 创建筛选意图。
  const ChangeBookSourceFilterIntent(this.filter);

  /// 新筛选范围。
  final BookSourceFilter filter;
}

/// 切换单个书源选择状态。
final class ToggleBookSourceSelectionIntent extends BookSourceManagementIntent {
  /// 创建选择意图。
  const ToggleBookSourceSelectionIntent(this.sourceUrl);

  /// 目标书源 URL。
  final String sourceUrl;
}

/// 清空选择状态。
final class ClearBookSourceSelectionIntent extends BookSourceManagementIntent {
  /// 创建清空选择意图。
  const ClearBookSourceSelectionIntent();
}

/// 请求系统文件导入。
final class RequestBookSourceFileIntent extends BookSourceManagementIntent {
  /// 创建文件导入意图。
  const RequestBookSourceFileIntent();
}

/// 请求剪贴板导入。
final class RequestBookSourceClipboardIntent extends BookSourceManagementIntent {
  /// 创建剪贴板导入意图。
  const RequestBookSourceClipboardIntent();
}

/// 请求二维码导入。
final class RequestBookSourceQrIntent extends BookSourceManagementIntent {
  /// 创建二维码导入意图。
  const RequestBookSourceQrIntent();
}

/// 显示手动文本导入对话框。
final class ShowBookSourceTextImportIntent extends BookSourceManagementIntent {
  /// 创建文本导入意图。
  const ShowBookSourceTextImportIntent({this.initialText = ''});

  /// 对话框初始文本。
  final String initialText;
}

/// 解析扫码取得的书源 JSON 或远程书源地址。
final class ResolveScannedBookSourceIntent extends BookSourceManagementIntent {
  /// 创建扫码内容解析意图。
  const ResolveScannedBookSourceIntent(this.scannedText);

  /// 相机取得且尚未信任的二维码文本。
  final String scannedText;
}

/// 执行书源 JSON 导入。
final class ImportBookSourceTextIntent extends BookSourceManagementIntent {
  /// 创建导入执行意图。
  const ImportBookSourceTextIntent({required this.text, required this.conflictPolicy});

  /// 未经信任的外部 JSON 文本。
  final String text;

  /// 同 URL 冲突策略。
  final BookSourceConflictPolicy conflictPolicy;
}

/// 修改单个书源启用状态。
final class SetSingleBookSourceEnabledIntent extends BookSourceManagementIntent {
  /// 创建单项启停意图。
  const SetSingleBookSourceEnabledIntent({required this.sourceUrl, required this.enabled});

  /// 目标书源 URL。
  final String sourceUrl;

  /// 新启用状态。
  final bool enabled;
}

/// 修改全部选中书源启用状态。
final class SetSelectedBookSourcesEnabledIntent extends BookSourceManagementIntent {
  /// 创建批量启停意图。
  const SetSelectedBookSourcesEnabledIntent(this.enabled);

  /// 新启用状态。
  final bool enabled;
}

/// 请求批量设置分组。
final class RequestSetBookSourceGroupIntent extends BookSourceManagementIntent {
  /// 创建分组请求意图。
  const RequestSetBookSourceGroupIntent();
}

/// 保存批量分组。
final class SaveBookSourceGroupIntent extends BookSourceManagementIntent {
  /// 创建分组保存意图。
  const SaveBookSourceGroupIntent(this.group);

  /// 新分组文本；空字符串表示清除分组。
  final String group;
}

/// 请求新增书源。
final class RequestAddBookSourceIntent extends BookSourceManagementIntent {
  /// 创建新增意图。
  const RequestAddBookSourceIntent();
}

/// 请求编辑书源。
final class RequestEditBookSourceIntent extends BookSourceManagementIntent {
  /// 创建编辑意图。
  const RequestEditBookSourceIntent(this.sourceUrl);

  /// 目标书源 URL。
  final String sourceUrl;
}

/// 保存书源编辑草稿。
final class SaveBookSourceDraftIntent extends BookSourceManagementIntent {
  /// 创建编辑保存意图。
  const SaveBookSourceDraftIntent(this.draft);

  /// 待校验并持久化的草稿。
  final BookSourceEditorDraft draft;
}

/// 请求删除单项或选中项。
final class RequestDeleteBookSourcesIntent extends BookSourceManagementIntent {
  /// 创建删除请求意图；未传 URL 时使用当前选择。
  RequestDeleteBookSourcesIntent({Set<String>? sourceUrls})
      : sourceUrls = sourceUrls == null ? null : Set<String>.unmodifiable(sourceUrls);

  /// 可选的明确删除目标。
  final Set<String>? sourceUrls;
}

/// 确认删除当前对话框中的书源。
final class ConfirmDeleteBookSourcesIntent extends BookSourceManagementIntent {
  /// 创建确认删除意图。
  const ConfirmDeleteBookSourcesIntent();
}

/// 请求基础调试信息。
final class DebugBookSourceIntent extends BookSourceManagementIntent {
  /// 创建调试意图。
  const DebugBookSourceIntent(this.sourceUrl);

  /// 待调试书源 URL。
  final String sourceUrl;
}

/// 请求打开书源登录边界。
final class LoginBookSourceIntent extends BookSourceManagementIntent {
  /// 创建登录意图。
  const LoginBookSourceIntent(this.sourceUrl);

  /// 需要登录的书源 URL。
  final String sourceUrl;
}

/// 关闭当前对话框。
final class DismissBookSourceDialogIntent extends BookSourceManagementIntent {
  /// 创建关闭对话框意图。
  const DismissBookSourceDialogIntent();
}

/// 重试数据库观察。
final class RetryBookSourceLoadIntent extends BookSourceManagementIntent {
  /// 创建重试意图。
  const RetryBookSourceLoadIntent();
}

/// 请求离开页面。
final class BackFromBookSourceManagementIntent extends BookSourceManagementIntent {
  /// 创建返回意图。
  const BackFromBookSourceManagementIntent();
}

/// 书源管理页面的一次性副作用。
sealed class BookSourceManagementEffect {
  /// 限制副作用类型只能由本文件声明。
  const BookSourceManagementEffect();
}

/// 请求 Route 打开系统文件选择器。
final class PickBookSourceFileEffect extends BookSourceManagementEffect {
  /// 创建文件选择副作用。
  const PickBookSourceFileEffect();
}

/// 请求 Route 读取剪贴板。
final class ReadBookSourceClipboardEffect extends BookSourceManagementEffect {
  /// 创建剪贴板副作用。
  const ReadBookSourceClipboardEffect();
}

/// 请求 Route 扫描二维码。
final class ScanBookSourceQrEffect extends BookSourceManagementEffect {
  /// 创建二维码副作用。
  const ScanBookSourceQrEffect();
}

/// 请求 Route 打开平台 WebView 登录。
final class OpenBookSourceLoginEffect extends BookSourceManagementEffect {
  /// 创建登录副作用。
  const OpenBookSourceLoginEffect(this.sourceUrl);

  /// 书源 URL。
  final String sourceUrl;
}

/// 请求 Route 展示一次性消息。
final class ShowBookSourceMessageEffect extends BookSourceManagementEffect {
  /// 创建消息副作用。
  const ShowBookSourceMessageEffect(this.message);

  /// 可安全展示的消息。
  final String message;
}

/// 请求 Route 返回上一页。
final class CloseBookSourceManagementEffect extends BookSourceManagementEffect {
  /// 创建返回副作用。
  const CloseBookSourceManagementEffect();
}
