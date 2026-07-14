# domain

领域层目录。M2 已放置不依赖 Flutter、sqflite 和平台对象的不可变领域模型、Gateway 与核心
UseCase。数据库行映射和 Repository 实现仅位于 `data/`，不得反向泄漏到本目录。
