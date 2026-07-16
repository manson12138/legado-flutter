# M4 书源合集分类校验样本

## 样本来源与安全边界

- 原始文件：`/Users/ocean/Downloads/1783948195.json.html`
- 原始文件 SHA-256：`5addcc2c9238212b736036b60567cfb273f08f122a303594c20a6d87fb779dcb`
- 原始内容是包含 100 个 Legado 书源的 JSON 数组，文件后缀虽为 `.json.html`，内容并不是 HTML。
- 统计到 82 个带 JavaScript 特征的书源、68 个调用 `java.*` 的书源、17 个依赖 Rhino/Java 专属能力的书源。
- 媒体类型分布为 83 个文本源、1 个音频源、16 个图片源；合集不含文件源和视频源。
- 原始合集包含看起来仍可使用的 Cookie。本文只保留兼容性所需片段，Cookie、账号和令牌统一替换为占位符。
- 本文样本用于确认解析类型和兼容边界，不等于网站当前仍可访问，也不等于 M4 已经通过真机验收。

## 分类矩阵

| 编号 | 兼容类型 | 代表书源 | 核心能力 | 当前预期 |
|---|---|---|---|---|
| S1 | 普通规则 | 📖笔趣阁 | CSS 规则、普通搜索/详情/目录/正文 | 由 M3 验证 |
| S2 | 标准 JavaScript | 101看书 | `@js:`、标准 URI 编码、POST 描述 | M4 第一优先样本 |
| S3 | `jsLib` 与四段 JS | 🍅番茄小说源 | 公共函数、搜索/详情/目录/正文脚本 | 部分 API 尚未支持 |
| S4 | Legado `java.*` | 得奇小说 | `java.ajax`、脚本生成请求 | 被同步网络语义阻塞 |
| S5 | Rhino/Java 类 | 热门小说网 | `Packages.org.jsoup.Jsoup` | 必须明确失败或建立白名单替代 |
| S6 | 登录脚本 | 69书吧 | Cookie、验证页、浏览器等待 | 需要登录与 WebView 平台能力 |
| S7 | WebView 脚本 | 爱丽书屋 | `java.webView`、页面 HTML 回传 | M10 已接页面桥，待双端真机 |
| S8 | Cookie Header | 书包书库 | 持久 Cookie 与自定义 Header | 仅用脱敏值验证存储和日志 |
| S9 | 音频书源 | 懒人听书 | 音频地址、付费状态、分页目录 | 原始 Token 必须脱敏 |
| S10 | 图片书源 | 🎨武芊漫画 | 图片列表转正文图片标签 | 验证类型 2 与图片顺序 |

## 完整可导入核心样本

以下文件均从原始合集完整提取，每个文件都是只包含一个书源的 JSON 数组，可单独导入：

- `samples/s2_101kanshu_standard_js.json`：标准 JavaScript 与四段链路基线。
- `samples/s3_fanqie_jslib.json`：`jsLib`、注入对象和内存缓存 API。
- `samples/s4_deqixs_java_ajax.json`：Legado `java.ajax` 同步网络语义。
- `samples/s5_remexs_rhino_java.json`：Rhino `Packages.org.jsoup.Jsoup` 与 WebView 边界。

四份核心样本均未包含真实 Cookie 值、Authorization 值、账号、Token 或登录脚本；S5 保留了用于验证兼容边界的 Cookie API 调用。首轮统一使用关键词“斗破苍穹”；必须选择标题完全匹配的结果和第一章免费正文。如果书源没有完全匹配结果，应记录 `BLOCKED / 无固定样本结果`，不得临时改用其他书籍掩盖差异。

## S1：普通规则书源

来源：`📖笔趣阁`，`http://www.biquge.site`

```json
{
  "bookSourceName": "📖笔趣阁",
  "bookSourceUrl": "http://www.biquge.site",
  "searchUrl": "http://www.biquge.site/search/result.html?searchkey={{key}}",
  "ruleSearch": {
    "bookList": "li",
    "bookUrl": ".novelname@href",
    "name": ".novelname@text",
    "author": "span:nth-child(2) > a@text"
  },
  "ruleBookInfo": {
    "name": "h1@text",
    "author": ".novelinfo-l li:nth-child(1) > a@text",
    "tocUrl": ".dirlist@href"
  },
  "ruleToc": {
    "chapterList": ".dirlist > li",
    "chapterName": "a@text",
    "chapterUrl": "a@href"
  },
  "ruleContent": {
    "content": "p@text"
  }
}
```

校验点：不进入 JavaScript 引擎；搜索、详情、目录、正文均走 M3 普通规则链路。

## S2：标准 JavaScript 书源

来源：`101看书`，`https://101kanshu.net`

```json
{
  "bookSourceName": "101看书",
  "bookSourceUrl": "https://101kanshu.net",
  "searchUrl": "@js:'/101search/,'+JSON.stringify({method:'POST',body:'searchkey='+encodeURIComponent(key)})",
  "ruleSearch": {
    "bookList": "div.bookbox",
    "bookUrl": "h4.bookname a@href",
    "name": "h4.bookname a@text",
    "author": "div.author.0@text##作者："
  },
  "ruleBookInfo": {
    "name": "meta[property='og:novel:book_name']@content",
    "author": "meta[property='og:novel:author']@content",
    "tocUrl": "{{baseUrl}}"
  },
  "ruleToc": {
    "chapterList": "#list-chapterAll dd a",
    "chapterName": "text",
    "chapterUrl": "href"
  },
  "ruleContent": {
    "content": "#rtext@html",
    "nextContentUrl": "id.linkNext@href"
  }
}
```

校验点：只需要标准 JavaScript、`key` 注入和 URL 请求描述生成，不依赖 `java.*`、Cookie、登录或 Rhino 类。它应作为 M4 第一份真实执行样本。

## S3：`jsLib` 与四段 JavaScript 书源

来源：`🍅番茄小说源`，`https://novel.cooks.tw`

```javascript
// 详情初始化片段
var j = J(result);
var d = j.data || j;
var id = d.articleid || '';
if (!id) {
  var m = String(baseUrl || '').match(/detail\/(\d+)/);
  if (m) id = m[1];
}
try {
  cache.putMemory('articleid', String(id));
} catch (e) {}
result;
```

```javascript
// 目录 URL 片段
var aid = '';
try {
  aid = cache.getFromMemory('articleid') || '';
} catch (e) {}
Base() + '/api/chapter/content/' + aid + '/' + result + '?lang=zh-CN';
```

校验点：公共 `jsLib` 必须在同一书源 Scope 中只初始化一次；搜索、详情、目录和正文脚本应共享公共函数。当前原型尚未实现 `cache.putMemory/getFromMemory`，预期得到包含具体方法名的“不支持 API”错误，不能静默返回空值。

## S4：Legado `java.*` 网络书源

来源：`得奇小说`，`https://www.deqixs.co`

```javascript
let [, aid, cid] = baseUrl.match(/\/books\/(\d+)\/(\d+)\.html/);
let url = `https://www.deqixs.co/scripts/chapter.js.php?aid=${aid}&cid=${cid}&referrer=${baseUrl}`;
let tokenHtml = java.ajax(url);
eval(String(tokenHtml));

let params = { aid, cid, token: chapterToken, timestamp, nonce };
let paramStr = Object.entries(params).map(x => x.join('=')).join('&');
url = 'https://www.deqixs.co/modules/article/ajax2.php?' + paramStr;
java.ajax(url);
```

校验点：Android Rhino 的 `java.ajax` 同步返回字符串，而 Dart/JSF 宿主网络返回 Promise。当前样本应被记录为同步语义差异，不允许把 Promise 强制转成字符串后宣称通过。

## S5：Rhino/Java 专属类书源

来源：`热门小说网`，`https://www.remexs.org`

```javascript
var JsDom = Packages.org.jsoup.Jsoup;
var document = JsDom.parse(src);
var list = [];
var base = source.getKey();

var select = document.select('select option');
for (var i = 0; i < select.size(); i++) {
  var url = select.get(i).attr('value');
  if (url) list.push(url);
}
```

校验点：iOS 没有 JVM，不能暴露任意 `Packages.*`。当前原型应抛出包含 `Packages.org.jsoup.Jsoup` 的明确错误；后续只能改用 Dart HTML DTO、普通规则或经过审计的固定白名单。

## S6：登录与验证页书源

来源：`69书吧[🪜]`，`https://www.69shuba.com`

```javascript
let original = result;
let url = result.url();
let ck = cookie.getCookie(url)
  .split('; ')
  .filter(item => !item.startsWith('jieqiVisitTime'))
  .join('; ');
cookie.setCookie(url, ck);

if (Regex.test(original.body())) {
  cookie.removeCookie(url);
  result = java.startBrowserAwait(url, '验证');
}
result;
```

校验点：Cookie 读取、覆盖、删除必须使用统一 Cookie 存储；验证页必须进入独立 WebView/浏览器边界。当前还缺少 `cookie.removeCookie` 和 `java.startBrowserAwait` 平台实现，预期为明确失败。

## S7：WebView 页面脚本书源

来源：`爱丽书屋`，`https://m.ailisw.com`

```javascript
var r = source.getKey() + '/';
var js = 'setTimeout(function(){window.legado.getHTML(document.documentElement.outerHTML);},5000);';
var html = String(java.webView('', r, js));
if (html.indexOf('wafjs') !== -1 || html.indexOf('loading ailisw') !== -1) {
  java.startBrowserAwait(r, '请等待页面加载完成后点击返回');
}
result;
```

校验点：纯 QuickJS 不应模拟浏览器 DOM。请求必须进入 `WebViewScriptBridge`，同步统一 Cookie，执行超时后关闭页面，并把结果以 DTO 返回。M10 已接入 Flutter 官方 Android WebView/WKWebView；必须验证 DOM 回传、重定向域 Cookie、超时/取消和页面释放，未取得结果前保持 `NOT_STARTED`。

## S8：Cookie Header 脱敏书源

来源：`书包书库`，`https://www.shubaoku.org`

原始 Header 含疑似真实登录 Cookie，校验样本只能使用以下脱敏版本：

```json
{
  "bookSourceName": "书包书库（脱敏校验）",
  "bookSourceUrl": "https://www.shubaoku.org",
  "header": "{\"User-Agent\":\"M04-Test-Agent\",\"Cookie\":\"session=<REDACTED>; user_id=<REDACTED>\"}"
}
```

校验点：Header JSON 能正确解码；Cookie 进入统一 Cookie 管理器；异常、日志和兼容报告中不得出现 `<REDACTED>` 所替代的真实值。

## S9：音频书源

来源：`懒人听书`，`https://m.lrts.me/`，`bookSourceType = 1`

原始目录 URL 内含疑似可用的 Token，本文不复制该 URL。使用以下脱敏结构验证音频类型和返回值：

```json
{
  "bookSourceName": "懒人听书（脱敏校验）",
  "bookSourceUrl": "https://m.lrts.me/",
  "bookSourceType": 1,
  "searchUrl": "https://m.lrts.me/ajax/searchBook?keyWord={{key}}&pageSize=15&pageNum={{page}}",
  "ruleToc": {
    "chapterName": "$.name",
    "isVip": "$.payType",
    "chapterUrl": "https://m.lrts.me/ajax/getListenPath?...<REDACTED>"
  },
  "ruleContent": {
    "content": "@js:var data=JSON.parse(src); data.data==null ? '' : data.data.path;"
  }
}
```

校验点：书源类型保持为音频；正文结果是可播放媒体 URL，而不是 HTML 文本；付费章节明确返回受限状态；目录分页不泄漏 Token。当前合集只有这一份音频源，因此它同时是音频类型的唯一代表。

## S10：图片书源

来源：`🎨武芊漫画`，`https://comic.mkzcdn.com`，`bookSourceType = 2`

```json
{
  "bookSourceName": "🎨武芊漫画",
  "bookSourceUrl": "https://comic.mkzcdn.com",
  "bookSourceType": 2,
  "searchUrl": "https://comic.mkzcdn.com/search/keyword/?keyword={{key}}&page_num={{page}}&page_size=20",
  "ruleToc": {
    "chapterList": "$.data",
    "chapterName": "$.title",
    "chapterUrl": "https://comic.mkzcdn.com/chapter/content/?chapter_id={{$.chapter_id}}"
  },
  "ruleContent": {
    "content": "$.data[*].image\n@js:result.split('\\n').map(x=>'<img src=\"'+x+'\">').join('\\n')"
  }
}
```

校验点：书源类型保持为图片；正文图片顺序与接口数组一致；多个图片地址不会被合并、丢失或当作普通段落转义。

## 建议执行顺序

1. S1 验证 M3 普通规则基线。
2. S2 验证标准 JavaScript、绑定值和请求描述。
3. S3 验证 `jsLib` Scope，并记录内存缓存 API 缺口。
4. S4 固定同步网络差异，不把失败伪装成兼容。
5. S5 验证 Rhino/Java 专属调用能准确报错。
6. S8 验证 Cookie 与日志隐私。
7. S9、S10 分别验证音频和图片媒体类型。
8. Android/iOS WebView 平台实现完成后再执行 S6、S7。

每个样本都需要记录 Android Legado、Flutter Android 和 Flutter iOS 三列结果。只有搜索、详情、目录、正文的真实输出以及差异结论齐全后，M4 才能退出 `BLOCKED`。
