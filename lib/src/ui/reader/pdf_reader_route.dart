import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:pdfx/pdfx.dart';

import '../../app/app_dependencies.dart';
import '../../domain/model/book.dart';
import '../../domain/model/reading_progress.dart';
import '../../help/error/app_result.dart';
import '../../model/local_book/local_book_parser.dart';

/// 使用独立页面模型渲染本地 PDF，并以页码保存恢复阅读进度。
final class PdfReaderRoute extends StatefulWidget {
  /// 创建 PDF 页面阅读路由。
  const PdfReaderRoute({required this.dependencies, required this.book, super.key});

  /// 应用组合根依赖。
  final AppDependencies dependencies;

  /// 已从书架读取的本地 PDF 书籍。
  final Book book;

  /// 创建 PDF 阅读状态。
  @override
  State<PdfReaderRoute> createState() => _PdfReaderRouteState();
}

/// 管理 PDFx 控制器、页码进度和页面跳转生命周期。
final class _PdfReaderRouteState extends State<PdfReaderRoute> with WidgetsBindingObserver {
  /// PDFx 页面与缩放控制器；文件路径解析成功后创建。
  PdfControllerPinch? _controller;

  /// 当前一开始显示的页码，从一开始。
  late int _currentPage;

  /// PDF 打开失败时可安全展示的错误。
  String? _errorMessage;

  /// 创建文件路径解析任务并注册前后台观察者。
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _currentPage = widget.book.durChapterIndex + 1;
    unawaited(_initialize());
  }

  /// 恢复应用内 PDF 路径并创建页面控制器。
  Future<void> _initialize() async {
    try {
      /// 当前安装中 PDF 应用私有副本路径。
      final String filePath = await widget.dependencies.localBookStorage.resolveBook(widget.book);
      if (!await File(filePath).exists()) {
        throw const LocalBookException('PDF 应用内副本已丢失，请重新导入');
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _controller = PdfControllerPinch(
          document: PdfDocument.openFile(filePath),
          initialPage: _currentPage,
        );
      });
    } on LocalBookException catch (error) {
      if (mounted) {
        setState(() {
          _errorMessage = error.message;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _errorMessage = 'PDF 无法打开，文件可能损坏或加密';
        });
      }
    }
  }

  /// 应用进入后台时立即保存当前页码。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_saveProgress());
    }
  }

  /// 将当前一基页码转换为数据库零基章节索引保存。
  Future<void> _saveProgress() async {
    /// 当前时间戳同时作为最近阅读和本地同步时间。
    final int now = DateTime.now().millisecondsSinceEpoch;
    /// 页码阅读进度；chapterPos 固定为零，不伪装成文本字符位置。
    final ReadingProgress progress = ReadingProgress(
      bookUrl: widget.book.bookUrl,
      chapterIndex: _currentPage - 1,
      chapterPos: 0,
      readTime: now,
      chapterTitle: '第 $_currentPage 页',
      syncTime: now,
    );
    /// 持久化结果；失败只在页面仍可见时提示。
    final AppResult<bool> result = await widget.dependencies.saveReadingProgress.execute(progress);
    if (result case AppFailure<bool>(error: final error)) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(error.message)));
      }
    }
  }

  /// 打开页码目录，并在用户选择后跳转目标页面。
  Future<void> _showPageDirectory() async {
    /// 已完成初始化的 PDF 控制器。
    final PdfControllerPinch? controller = _controller;
    /// 当前文档页数。
    final int pageCount = controller?.pagesCount ?? widget.book.totalChapterNum;
    if (controller == null || pageCount <= 0) {
      return;
    }
    /// 用户从页面目录选中的一基页码。
    final int? page = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext context) {
        return ListView.builder(
          itemCount: pageCount,
          itemBuilder: (BuildContext context, int index) {
            /// 当前列表项的一基页码。
            final int pageNumber = index + 1;
            return ListTile(
              selected: pageNumber == _currentPage,
              leading: const Icon(Icons.picture_as_pdf_outlined),
              title: Text('第 $pageNumber 页'),
              onTap: () => Navigator.of(context).pop(pageNumber),
            );
          },
        );
      },
    );
    if (page != null) {
      controller.jumpToPage(page);
    }
  }

  /// 保存进度、释放页面控制器和生命周期观察者。
  @override
  void dispose() {
    unawaited(_saveProgress());
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  /// 构建带页码、目录、缩放和错误恢复的 PDF 页面阅读器。
  @override
  Widget build(BuildContext context) {
    /// 当前已经创建的 PDF 控制器。
    final PdfControllerPinch? controller = _controller;
    return PopScope<Object?>(
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) {
          unawaited(_saveProgress());
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.book.name),
          actions: <Widget>[
            IconButton(
              onPressed: controller == null ? null : _showPageDirectory,
              icon: const Icon(Icons.format_list_numbered),
              tooltip: '页码目录',
            ),
          ],
        ),
        body: switch ((_errorMessage, controller)) {
          (final String message, _) => _PdfErrorView(message: message),
          (null, final PdfControllerPinch value) => Stack(
            children: <Widget>[
              PdfViewPinch(
                controller: value,
                scrollDirection: Axis.vertical,
                onPageChanged: (int page) {
                  setState(() {
                    _currentPage = page;
                  });
                },
                onDocumentError: (Object error) {
                  setState(() {
                    _errorMessage = 'PDF 页面渲染失败';
                  });
                },
              ),
              Positioned(
                right: 16,
                bottom: 16,
                child: Chip(label: Text('$_currentPage / ${value.pagesCount ?? widget.book.totalChapterNum}')),
              ),
            ],
          ),
          _ => const Center(child: CircularProgressIndicator()),
        },
      ),
    );
  }
}

/// 展示 PDF 打开或渲染失败，不以空页面冒充成功。
final class _PdfErrorView extends StatelessWidget {
  /// 创建 PDF 错误视图。
  const _PdfErrorView({required this.message});

  /// 可安全展示的错误摘要。
  final String message;

  /// 构建居中的错误图标和文本。
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.error_outline, color: Theme.of(context).colorScheme.error, size: 48),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
