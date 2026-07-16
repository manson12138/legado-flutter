import '../model/book_source.dart';
import '../model/book_source_import_result.dart';

/// 定义书源持久化领域边界；实现不得向调用方返回数据库专属对象。
abstract interface class BookSourceGateway {
  /// 观察全部书源，按用户手动顺序返回。
  Stream<List<BookSource>> watchAll();

  /// 按未经规范化的书源 URL 查询。
  Future<BookSource?> getByUrl(String sourceUrl);

  /// 读取当前启用书源，供搜索层稳定复用。
  Future<List<BookSource>> getEnabled();

  /// 在一个事务中导入书源，并返回实际处理数量。
  Future<int> importSources(List<BookSource> sources);

  /// 解码并事务导入 Android 兼容书源 JSON，返回实际处理数量。
  Future<BookSourceImportResult> importSourceJson(
    String sourceJson, {
    required BookSourceConflictPolicy conflictPolicy,
  });

  /// 保存新增或编辑后的完整书源；URL 变化时删除旧主键但不删除书架书籍。
  Future<void> saveSource(BookSource source, {String? previousUrl});

  /// 读取 Android `source.getVariable()` 对应的书源自定义变量；未配置时返回空字符串。
  Future<String> getSourceVariable(String sourceUrl);

  /// 保存书源自定义变量；[value] 为 null 时删除 Flutter 独立缓存中的配置。
  Future<void> saveSourceVariable(String sourceUrl, String? value);

  /// 批量修改书源启用状态。
  Future<void> setEnabled(Set<String> sourceUrls, {required bool enabled});

  /// 批量替换书源分组文本。
  Future<void> setGroup(Set<String> sourceUrls, String? group);

  /// 删除书源，并由数据库关联约束删除其搜索缓存。
  Future<void> deleteByUrl(String sourceUrl);

  /// 在单一事务中删除多个书源，不触碰书架表。
  Future<void> deleteByUrls(Set<String> sourceUrls);
}
