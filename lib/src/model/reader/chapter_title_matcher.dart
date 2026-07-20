import 'dart:math' as math;

import '../../domain/model/book_chapter.dart';

/// 移植 Android `BookHelp.getDurChapter` 的模糊标题匹配，用于单章换源在候选目录中
/// 预选与旧章节最接近的一章；不跳过卷标题，由调用方按需过滤。
///
/// 简化点：Android 章节号兜底同时解析中文数字和阿拉伯数字，这里只解析阿拉伯数字——
/// Jaccard 标题相似度是主要判据，多数网络小说同一章标题跨书源高度一致，数字兜底只作为
/// 相似度不足时的补充，不影响主要匹配质量。
int resolveMatchingChapterIndex({
  required int oldChapterIndex,
  required String oldChapterTitle,
  required List<BookChapter> newChapters,
  required int oldChapterListSize,
}) {
  if (newChapters.isEmpty) {
    return -1;
  }
  if (oldChapterListSize <= 0) {
    return oldChapterIndex.clamp(0, newChapters.length - 1).toInt();
  }
  /// 按旧/新目录长度比例换算的初始猜测索引。
  final int guess = ((oldChapterIndex * newChapters.length) / oldChapterListSize)
      .round()
      .clamp(0, newChapters.length - 1)
      .toInt();
  /// 旧标题清理后的比较文本。
  final String normalizedOldTitle = _purifyTitle(oldChapterTitle);
  /// 旧标题解析出的章节号；解析失败为空。
  final int? oldNumber = _extractChapterNumber(oldChapterTitle);
  /// 窗口内最佳相似度候选。
  int bestIndex = guess;
  double bestScore = -1;
  /// 窗口内按章节号命中的候选；相似度不足时优先使用。
  int? numberMatchIndex;
  /// ±10 索引窗口内逐一比较标题相似度。
  final int start = math.max(0, guess - 10);
  final int end = math.min(newChapters.length - 1, guess + 10);
  for (int index = start; index <= end; index += 1) {
    /// 当前候选章节。
    final BookChapter candidate = newChapters[index];
    /// 候选与旧标题的 Jaccard 相似度。
    final double score = _jaccardSimilarity(normalizedOldTitle, _purifyTitle(candidate.title));
    if (score > bestScore) {
      bestScore = score;
      bestIndex = index;
    }
    if (numberMatchIndex == null && oldNumber != null) {
      /// 候选标题解析出的章节号。
      final int? candidateNumber = _extractChapterNumber(candidate.title);
      if (candidateNumber != null && candidateNumber == oldNumber) {
        numberMatchIndex = index;
      }
    }
  }
  if (bestScore >= 0.96) {
    return bestIndex;
  }
  if (numberMatchIndex != null) {
    return numberMatchIndex;
  }
  return bestIndex;
}

/// 去除常见编号、方括号和空白后的标题，仅用于相似度比较。
String _purifyTitle(String title) {
  return title
      .replaceAll(RegExp(r'^\s*第?\s*[0-9零一二三四五六七八九十百千万〇]+\s*[章回卷节部篇]'), '')
      .replaceAll(RegExp(r'[\[［【(（].*?[\]］】)）]'), '')
      .replaceAll(RegExp(r'\s+'), '')
      .trim();
}

/// 从标题中提取首个连续阿拉伯数字段作为章节号；未找到返回空。
int? _extractChapterNumber(String title) {
  /// 标题中的首个数字片段。
  final RegExpMatch? match = RegExp(r'\d+').firstMatch(title);
  if (match == null) {
    return null;
  }
  return int.tryParse(match.group(0)!);
}

/// 基于双字符 n-gram 集合计算 Jaccard 相似度，短文本退化为整串比较。
double _jaccardSimilarity(String left, String right) {
  if (left.isEmpty && right.isEmpty) {
    return 1;
  }
  if (left.isEmpty || right.isEmpty) {
    return 0;
  }
  if (left == right) {
    return 1;
  }
  /// 左侧字符二元组集合。
  final Set<String> leftGrams = _bigrams(left);
  /// 右侧字符二元组集合。
  final Set<String> rightGrams = _bigrams(right);
  if (leftGrams.isEmpty || rightGrams.isEmpty) {
    return left == right ? 1 : 0;
  }
  /// 交集大小。
  final int intersection = leftGrams.intersection(rightGrams).length;
  /// 并集大小。
  final int union = leftGrams.union(rightGrams).length;
  return union == 0 ? 0 : intersection / union;
}

/// 生成字符二元组集合；单字符文本退化为单字符集合。
Set<String> _bigrams(String text) {
  if (text.length < 2) {
    return <String>{text};
  }
  /// 收集到的二元组。
  final Set<String> grams = <String>{};
  for (int index = 0; index < text.length - 1; index += 1) {
    grams.add(text.substring(index, index + 2));
  }
  return grams;
}
