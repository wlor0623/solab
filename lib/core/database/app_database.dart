import 'dart:io';
import 'dart:isolate';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:sqlite3/common.dart' show AllowedArgumentCount;

import '../../utils/app_directories.dart';

part 'app_database.g.dart';

typedef SqliteExecutionIsolateProbeResult = ({
  int samples,
  int openingIsolateCalls,
  int backgroundIsolateCalls,
});

class MicrosecondDateTimeConverter extends TypeConverter<DateTime, int> {
  const MicrosecondDateTimeConverter();

  @override
  DateTime fromSql(int fromDb) => DateTime.fromMicrosecondsSinceEpoch(fromDb);

  @override
  int toSql(DateTime value) => value.microsecondsSinceEpoch;
}

@TableIndex(
  name: 'idx_conversations_updated_at',
  columns: {
    IndexedColumn(#updatedAt, orderBy: OrderingMode.desc),
    IndexedColumn(#id, orderBy: OrderingMode.asc),
  },
)
@TableIndex(name: 'idx_conversations_assistant', columns: {#assistantId})
class ConversationRows extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  IntColumn get createdAt =>
      integer().map(const MicrosecondDateTimeConverter())();
  IntColumn get updatedAt =>
      integer().map(const MicrosecondDateTimeConverter())();
  BoolColumn get isPinned => boolean().withDefault(const Constant(false))();
  TextColumn get assistantId => text().nullable()();
  IntColumn get truncateIndex => integer()
      // ignore: recursive_getters
      .check(truncateIndex.isBiggerOrEqualValue(-1))
      .withDefault(const Constant(-1))();
  TextColumn get versionSelectionsJson =>
      text().withDefault(const Constant('{}'))();
  TextColumn get summary => text().nullable()();
  IntColumn get lastSummarizedMessageCount => integer()
      // ignore: recursive_getters
      .check(lastSummarizedMessageCount.isBiggerOrEqualValue(0))
      .withDefault(const Constant(0))();
  TextColumn get chatSuggestionsJson =>
      text().withDefault(const Constant('[]'))();
  TextColumn get injectedMemoryHash => text().nullable()();
  IntColumn get lastMemoryExtractedOrder => integer()
      // ignore: recursive_getters
      .check(lastMemoryExtractedOrder.isBiggerOrEqualValue(-1))
      .withDefault(const Constant(-1))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@TableIndex(
  name: 'idx_messages_conversation_order',
  columns: {#conversationId, #messageOrder, #id},
)
@TableIndex(
  name: 'idx_messages_conversation_timestamp',
  columns: {#conversationId, #timestamp, #id},
)
@TableIndex(
  name: 'idx_messages_group',
  columns: {#conversationId, #groupId, #version, #id},
)
@TableIndex.sql(
  'CREATE INDEX idx_message_rows_streaming '
  'ON message_rows (id) WHERE is_streaming = 1',
)
class MessageRows extends Table {
  TextColumn get id => text()();
  TextColumn get conversationId =>
      text().references(ConversationRows, #id, onDelete: KeyAction.cascade)();
  TextColumn get role =>
      text()
      // ignore: recursive_getters
      .check(role.isNotValue(''))();
  IntColumn get timestamp =>
      integer().map(const MicrosecondDateTimeConverter())();
  TextColumn get modelId => text().nullable()();
  TextColumn get providerId => text().nullable()();
  IntColumn get totalTokens => integer()
      // ignore: recursive_getters
      .check(totalTokens.isBiggerOrEqualValue(0))
      .nullable()();
  BoolColumn get isStreaming => boolean().withDefault(const Constant(false))();
  IntColumn get reasoningStartAt =>
      integer().map(const MicrosecondDateTimeConverter()).nullable()();
  IntColumn get reasoningFinishedAt =>
      integer().map(const MicrosecondDateTimeConverter()).nullable()();
  TextColumn get translation => text().nullable()();
  TextColumn get reasoningSegmentsJson => text().nullable()();
  TextColumn get groupId => text().nullable()();
  IntColumn get version => integer()
      // ignore: recursive_getters
      .check(version.isBiggerOrEqualValue(0))
      .withDefault(const Constant(0))();
  IntColumn get promptTokens => integer()
      // ignore: recursive_getters
      .check(promptTokens.isBiggerOrEqualValue(0))
      .nullable()();
  IntColumn get completionTokens => integer()
      // ignore: recursive_getters
      .check(completionTokens.isBiggerOrEqualValue(0))
      .nullable()();
  IntColumn get cachedTokens => integer()
      // ignore: recursive_getters
      .check(cachedTokens.isBiggerOrEqualValue(0))
      .nullable()();
  IntColumn get durationMs => integer()
      // ignore: recursive_getters
      .check(durationMs.isBiggerOrEqualValue(0))
      .nullable()();
  IntColumn get messageOrder =>
      integer()
      // ignore: recursive_getters
      .check(messageOrder.isBiggerOrEqualValue(0))();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {conversationId, messageOrder},
    {conversationId, groupId, version},
  ];
}

class ConversationMcpServerRows extends Table {
  TextColumn get conversationId =>
      text().references(ConversationRows, #id, onDelete: KeyAction.cascade)();
  TextColumn get serverId => text()();
  IntColumn get ordinal =>
      integer()
      // ignore: recursive_getters
      .check(ordinal.isBiggerOrEqualValue(0))();

  @override
  Set<Column<Object>> get primaryKey => {conversationId, serverId};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {conversationId, ordinal},
  ];
}

class ChatStorageMetaRows extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column<Object>> get primaryKey => {key};
}

@TableIndex(
  name: 'idx_message_parts_revision_ordinal',
  columns: {#conversationId, #revisionId, #ordinal},
)
class MessagePartRows extends Table {
  IntColumn get partId => integer().autoIncrement()();
  TextColumn get conversationId => text()();
  TextColumn get revisionId => text()();
  IntColumn get ordinal =>
      integer()
      // ignore: recursive_getters
      .check(ordinal.isBiggerOrEqualValue(0))();
  TextColumn get kind => text().check(
    // Forward-compat: unknown future kinds persist as UnknownPart.
    // ignore: recursive_getters
    kind.isNotValue(''),
  )();
  TextColumn get payload => text()();
  IntColumn get createdAt =>
      integer().map(const MicrosecondDateTimeConverter())();
  IntColumn get updatedAt =>
      integer().map(const MicrosecondDateTimeConverter())();

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {revisionId, ordinal},
  ];

  @override
  List<String> get customConstraints => [
    'FOREIGN KEY (revision_id) '
        'REFERENCES message_rows (id) '
        'ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED',
    'CHECK (updated_at >= created_at)',
  ];
}

@TableIndex(
  name: 'idx_provider_artifacts_revision_kind',
  columns: {#conversationId, #revisionId, #kind},
)
class ProviderArtifactRows extends Table {
  TextColumn get conversationId => text()();
  TextColumn get revisionId => text()();
  TextColumn get kind => text().check(
    // ignore: recursive_getters
    kind.isNotValue(''),
  )();
  TextColumn get payload => text()();
  IntColumn get createdAt =>
      integer().map(const MicrosecondDateTimeConverter())();
  IntColumn get updatedAt =>
      integer().map(const MicrosecondDateTimeConverter())();

  @override
  Set<Column<Object>> get primaryKey => {revisionId, kind};

  @override
  List<String> get customConstraints => [
    'FOREIGN KEY (revision_id) '
        'REFERENCES message_rows (id) '
        'ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED',
    'CHECK (updated_at >= created_at)',
  ];
}

class AssetRows extends Table {
  TextColumn get id => text()();
  TextColumn get contentHash => text().unique()();
  TextColumn get path => text()();
  IntColumn get byteSize =>
      integer()
      // ignore: recursive_getters
      .check(byteSize.isBiggerOrEqualValue(0))();
  IntColumn get width => integer()
      // ignore: recursive_getters
      .check(width.isBiggerThanValue(0))
      .nullable()();
  IntColumn get height => integer()
      // ignore: recursive_getters
      .check(height.isBiggerThanValue(0))
      .nullable()();
  TextColumn get thumbnailPath => text().nullable()();
  IntColumn get createdAt =>
      integer().map(const MicrosecondDateTimeConverter())();
  IntColumn get lastReferencedAt =>
      integer().map(const MicrosecondDateTimeConverter())();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@TableIndex(name: 'idx_message_assets_asset', columns: {#assetId, #revisionId})
class MessageAssetRows extends Table {
  TextColumn get conversationId => text()();
  TextColumn get revisionId =>
      text().references(MessageRows, #id, onDelete: KeyAction.cascade)();
  TextColumn get assetId =>
      text().references(AssetRows, #id, onDelete: KeyAction.cascade)();
  TextColumn get kind =>
      text()
      // ignore: recursive_getters
      .check(kind.isNotValue(''))();

  @override
  Set<Column<Object>> get primaryKey => {revisionId, assetId, kind};
}

class AssetGcRows extends Table {
  TextColumn get assetId =>
      text().references(AssetRows, #id, onDelete: KeyAction.cascade)();
  IntColumn get notBefore =>
      integer().map(const MicrosecondDateTimeConverter())();
  IntColumn get attempts => integer()
      // ignore: recursive_getters
      .check(attempts.isBiggerOrEqualValue(0))
      .withDefault(const Constant(0))();
  IntColumn get generation => integer()
      // ignore: recursive_getters
      .check(generation.isBiggerOrEqualValue(0))
      .withDefault(const Constant(0))();

  @override
  Set<Column<Object>> get primaryKey => {assetId};
}

class GcAuditRows extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get kind => text()();
  TextColumn get entityId => text()();
  IntColumn get completedAt =>
      integer().map(const MicrosecondDateTimeConverter())();
}

class AssetReferenceDirtyRows extends Table {
  TextColumn get revisionId =>
      text().references(MessageRows, #id, onDelete: KeyAction.cascade)();

  @override
  Set<Column<Object>> get primaryKey => {revisionId};
}

@TableIndex.sql(
  'CREATE UNIQUE INDEX idx_generation_runs_active_target '
  'ON generation_run_rows (conversation_id, target_revision_id) '
  "WHERE state IN ('preparing', 'requesting', 'streaming', 'waiting_tool')",
)
@TableIndex(
  name: 'idx_generation_runs_state_updated',
  columns: {#state, #updatedAt, #id},
)
class GenerationRunRows extends Table {
  TextColumn get id => text()();
  TextColumn get conversationId =>
      text().references(ConversationRows, #id, onDelete: KeyAction.cascade)();
  TextColumn get targetRevisionId => text()();
  TextColumn get state => text().check(
    // ignore: recursive_getters
    state.isIn(const [
      'preparing',
      'requesting',
      'streaming',
      'waiting_tool',
      'completed',
      'failed',
      'cancelled',
      'interrupted',
    ]),
  )();
  IntColumn get stateRevision => integer()
      // ignore: recursive_getters
      .check(stateRevision.isBiggerOrEqualValue(0))
      .withDefault(const Constant(0))();
  IntColumn get checkpointSeq => integer()
      // ignore: recursive_getters
      .check(checkpointSeq.isBiggerOrEqualValue(0))
      .withDefault(const Constant(0))();
  TextColumn get errorCode => text().nullable()();
  IntColumn get createdAt =>
      integer().map(const MicrosecondDateTimeConverter())();
  IntColumn get updatedAt =>
      integer().map(const MicrosecondDateTimeConverter())();
  IntColumn get terminalAt =>
      integer().map(const MicrosecondDateTimeConverter()).nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'FOREIGN KEY (target_revision_id) '
        'REFERENCES message_rows (id) '
        'DEFERRABLE INITIALLY DEFERRED',
    'CHECK (updated_at >= created_at)',
    'CHECK (terminal_at IS NULL OR terminal_at >= created_at)',
    "CHECK ((state IN ('preparing', 'requesting', 'streaming', "
        "'waiting_tool') AND terminal_at IS NULL) OR "
        "(state IN ('completed', 'failed', 'cancelled', 'interrupted') "
        'AND terminal_at IS NOT NULL))',
    "CHECK (error_code IS NULL OR (length(error_code) BETWEEN 1 AND 128 "
        "AND state IN ('failed', 'cancelled', 'interrupted')))",
  ];
}

class AssistantRows extends Table {
  TextColumn get id => text()();
  IntColumn get sortOrder =>
      integer()
      // ignore: recursive_getters
      .check(sortOrder.isBiggerOrEqualValue(0))();
  TextColumn get payload => text()();
  IntColumn get updatedAt =>
      integer().map(const MicrosecondDateTimeConverter())();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class ProviderRows extends Table {
  TextColumn get providerKey => text()();
  IntColumn get sortOrder =>
      integer()
      // ignore: recursive_getters
      .check(sortOrder.isBiggerOrEqualValue(0))();
  TextColumn get payload => text()();
  IntColumn get updatedAt =>
      integer().map(const MicrosecondDateTimeConverter())();

  @override
  Set<Column<Object>> get primaryKey => {providerKey};
}

class ProviderGroupRows extends Table {
  TextColumn get id => text()();
  IntColumn get sortOrder =>
      integer()
      // ignore: recursive_getters
      .check(sortOrder.isBiggerOrEqualValue(0))();
  TextColumn get payload => text()();
  IntColumn get updatedAt =>
      integer().map(const MicrosecondDateTimeConverter())();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class McpServerRows extends Table {
  TextColumn get id => text()();
  IntColumn get sortOrder =>
      integer()
      // ignore: recursive_getters
      .check(sortOrder.isBiggerOrEqualValue(0))();
  TextColumn get payload => text()();
  IntColumn get updatedAt =>
      integer().map(const MicrosecondDateTimeConverter())();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class WorldBookRows extends Table {
  TextColumn get id => text()();
  IntColumn get sortOrder =>
      integer()
      // ignore: recursive_getters
      .check(sortOrder.isBiggerOrEqualValue(0))();
  TextColumn get payload => text()();
  IntColumn get updatedAt =>
      integer().map(const MicrosecondDateTimeConverter())();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@TableIndex(
  name: 'idx_assistant_memories_assistant',
  columns: {#assistantId, #id},
)
class AssistantMemoryRows extends Table {
  TextColumn get id => text()();
  IntColumn get sortOrder =>
      integer()
      // ignore: recursive_getters
      .check(sortOrder.isBiggerOrEqualValue(0))();
  TextColumn get assistantId => text()();
  TextColumn get payload => text()();
  IntColumn get updatedAt =>
      integer().map(const MicrosecondDateTimeConverter())();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class QuickPhraseRows extends Table {
  TextColumn get id => text()();
  IntColumn get sortOrder =>
      integer()
      // ignore: recursive_getters
      .check(sortOrder.isBiggerOrEqualValue(0))();
  TextColumn get payload => text()();
  IntColumn get updatedAt =>
      integer().map(const MicrosecondDateTimeConverter())();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class SearchServiceRows extends Table {
  TextColumn get id => text()();
  IntColumn get sortOrder =>
      integer()
      // ignore: recursive_getters
      .check(sortOrder.isBiggerOrEqualValue(0))();
  TextColumn get payload => text()();
  IntColumn get updatedAt =>
      integer().map(const MicrosecondDateTimeConverter())();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class TtsServiceRows extends Table {
  TextColumn get id => text()();
  IntColumn get sortOrder =>
      integer()
      // ignore: recursive_getters
      .check(sortOrder.isBiggerOrEqualValue(0))();
  TextColumn get payload => text()();
  IntColumn get updatedAt =>
      integer().map(const MicrosecondDateTimeConverter())();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class InstructionInjectionRows extends Table {
  TextColumn get id => text()();
  IntColumn get sortOrder =>
      integer()
      // ignore: recursive_getters
      .check(sortOrder.isBiggerOrEqualValue(0))();
  TextColumn get payload => text()();
  IntColumn get updatedAt =>
      integer().map(const MicrosecondDateTimeConverter())();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class AssistantTagRows extends Table {
  TextColumn get id => text()();
  IntColumn get sortOrder =>
      integer()
      // ignore: recursive_getters
      .check(sortOrder.isBiggerOrEqualValue(0))();
  TextColumn get payload => text()();
  IntColumn get updatedAt =>
      integer().map(const MicrosecondDateTimeConverter())();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class PreferenceRows extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();
  IntColumn get updatedAt =>
      integer().map(const MicrosecondDateTimeConverter())();

  @override
  Set<Column<Object>> get primaryKey => {key};
}

@TableIndex(
  name: 'idx_memory_entries_visible',
  columns: {#status, #type, #scope, #assistantId},
)
@TableIndex(
  name: 'idx_memory_entries_recent',
  columns: {#status, #type, #entryUpdatedAt, #id},
)
@TableIndex(
  name: 'idx_memory_entries_dedupe',
  columns: {#scope, #assistantId, #type, #contentNormalized},
)
class MemoryEntryRows extends Table {
  TextColumn get id => text()();
  IntColumn get sortOrder =>
      integer()
      // ignore: recursive_getters
      .check(sortOrder.isBiggerOrEqualValue(0))();
  TextColumn get scope => text().check(
    // ignore: recursive_getters
    scope.isIn(const ['global', 'assistant']),
  )();
  TextColumn get assistantId => text().nullable()();
  TextColumn get type => text().check(
    // ignore: recursive_getters
    type.isIn(const [
      'identity',
      'workflow',
      'voice',
      'instruction',
      'apk_patch',
      'apk_note',
    ]),
  )();
  TextColumn get status => text().check(
    // ignore: recursive_getters
    status.isIn(const ['active', 'archived']),
  )();
  TextColumn get content => text()();
  TextColumn get contentNormalized => text()();
  IntColumn get entryCreatedAt =>
      integer().map(const MicrosecondDateTimeConverter())();
  IntColumn get entryUpdatedAt =>
      integer().map(const MicrosecondDateTimeConverter())();
  TextColumn get payload => text()();
  IntColumn get updatedAt =>
      integer().map(const MicrosecondDateTimeConverter())();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    "CHECK ((scope = 'global' AND assistant_id IS NULL) OR "
        "(scope = 'assistant' AND assistant_id IS NOT NULL))",
    'CHECK (entry_updated_at >= entry_created_at)',
  ];
}

class UserProfileFieldRows extends Table {
  TextColumn get id => text()(); // = field key, e.g. preferred_name
  IntColumn get sortOrder =>
      integer()
      // ignore: recursive_getters
      .check(sortOrder.isBiggerOrEqualValue(0))();
  TextColumn get payload => text()();
  IntColumn get updatedAt =>
      integer().map(const MicrosecondDateTimeConverter())();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@TableIndex(
  name: 'idx_message_prompts_conversation_snapshot',
  columns: {#conversationId, #carriesMemorySnapshot},
)
class MessagePromptRows extends Table {
  TextColumn get revisionId => text()();
  TextColumn get conversationId => text()();
  TextColumn get payload => text()();
  BoolColumn get carriesMemorySnapshot =>
      boolean().withDefault(const Constant(false))();
  IntColumn get createdAt =>
      integer().map(const MicrosecondDateTimeConverter())();

  @override
  Set<Column<Object>> get primaryKey => {revisionId};

  // 无外键：prompt 行是派生缓存（读不到就重算）。合成修订
  // （context-summary-* 摘要消息）从未落 message_rows，保留 FK 会
  // 在冻结时 FOREIGN KEY constraint failed。删除消息时由
  // chat_database_repository 显式清理本表。
}

/// SoLab APK 项目记录：一个确定版本的安装包 + 分析元数据。
/// 大体积分析报告本体存 SharedPreferences/文件，表中只放引用与指纹。
class ApkProjectRows extends Table {
  TextColumn get id => text()();
  TextColumn get sourcePath => text()();
  TextColumn get fileName => text()();
  TextColumn get packageName => text().nullable()();
  TextColumn get versionName => text().nullable()();
  IntColumn get versionCode => integer().nullable()();
  TextColumn get apkSha256 => text()();
  TextColumn get certificateSha256 => text().nullable()();
  IntColumn get analysisVersion => integer().withDefault(const Constant(0))();
  IntColumn get ruleSetVersion => integer().withDefault(const Constant(1))();
  TextColumn get conversationId => text().nullable()();
  TextColumn get latestReportId => text().nullable()();
  IntColumn get createdAt =>
      integer().map(const MicrosecondDateTimeConverter())();
  IntColumn get lastOpenedAt =>
      integer().map(const MicrosecondDateTimeConverter())();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// SoLab APK 规则库条目：一条规则对应一个可编辑的匹配模式
/// （SDK 包 / 类关键词 / 方法 / URL / 组件 / 权限等）。
/// 规则库页面修改后同步写 SharedPreferences 的规则 key（与原生
/// SolabChannel 约定一致）；hitCount/successCount/failureCount 为暂存统计，
/// 供后续分析回写。
class ModifyRuleRows extends Table {
  TextColumn get id =>
      text()(); // 稳定 ID：seed 为 "<category>:<pattern>"，用户自建为 uuid
  TextColumn get name => text()();
  TextColumn get category => text().check(
    // ignore: recursive_getters
    category.isNotValue(''),
  )();

  /// JSON 编码的匹配器：`{"type": "<category>", "patterns": ["..."]}`
  TextColumn get matcherJson => text()();
  BoolColumn get enabled => boolean().withDefault(const Constant(true))();

  /// 规则来源：seed（内置种子）/ user（手动新增）/ import（粘贴导入）
  TextColumn get source => text().withDefault(const Constant('seed'))();

  /// 风险等级：low / medium / high
  TextColumn get risk => text().withDefault(const Constant('low'))();
  IntColumn get hitCount => integer()
      // ignore: recursive_getters
      .check(hitCount.isBiggerOrEqualValue(0))
      .withDefault(const Constant(0))();
  IntColumn get successCount => integer()
      // ignore: recursive_getters
      .check(successCount.isBiggerOrEqualValue(0))
      .withDefault(const Constant(0))();
  IntColumn get failureCount => integer()
      // ignore: recursive_getters
      .check(failureCount.isBiggerOrEqualValue(0))
      .withDefault(const Constant(0))();
  IntColumn get version => integer()
      // ignore: recursive_getters
      .check(version.isBiggerOrEqualValue(0))
      .withDefault(const Constant(0))();
  IntColumn get updatedAt =>
      integer().map(const MicrosecondDateTimeConverter())();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// SoLab APK 规则订阅源：网络 URL 订阅（ad_patterns.json 格式）。
/// 订阅元信息存库；拉取到的规则合并进 modify_rule_rows
/// （source 标记 'subscription'），不落文件。
class RuleSubscriptionRows extends Table {
  TextColumn get id => text()(); // 稳定 ID：预置源为 'default'，用户新增为 uuid
  TextColumn get name => text()();
  TextColumn get url => text()();
  BoolColumn get enabled => boolean().withDefault(const Constant(true))();

  /// 最近一次成功同步时间；null = 从未同步。
  IntColumn get lastSyncAt =>
      integer().nullable().map(const MicrosecondDateTimeConverter())();

  /// 最近一次同步合并的规则总数（含订阅前已存在的）。
  IntColumn get lastRuleCount => integer().withDefault(const Constant(0))();
  IntColumn get createdAt =>
      integer().map(const MicrosecondDateTimeConverter())();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// M6: SO 分析工作区（内置 SO 引擎）。
/// sourceKey = path|size|modified 去重键；editSessionId 为最近编辑会话。
class SoWorkspaceRows extends Table {
  TextColumn get id => text()();
  TextColumn get path => text()();
  TextColumn get sourceKey => text()();
  BoolColumn get temporary => boolean().withDefault(const Constant(false))();
  TextColumn get editSessionId => text().nullable()();
  IntColumn get createdAt =>
      integer().map(const MicrosecondDateTimeConverter())();
  IntColumn get lastOpenedAt =>
      integer().map(const MicrosecondDateTimeConverter())();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// M6: SO 引擎工具统计（ToolStats 持久化）。
class EngineStatsRows extends Table {
  TextColumn get toolName => text()();
  IntColumn get calls => integer().withDefault(const Constant(0))();
  IntColumn get ok => integer().withDefault(const Constant(0))();
  IntColumn get failed => integer().withDefault(const Constant(0))();
  IntColumn get avgMs => integer().withDefault(const Constant(0))();
  IntColumn get maxMs => integer().withDefault(const Constant(0))();
  TextColumn get lastError => text().nullable()();
  IntColumn get lastAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column<Object>> get primaryKey => {toolName};
}

@DriftDatabase(
  tables: [
    ConversationRows,
    MessageRows,
    ConversationMcpServerRows,
    ChatStorageMetaRows,
    MessagePartRows,
    ProviderArtifactRows,
    AssetRows,
    MessageAssetRows,
    AssetGcRows,
    GcAuditRows,
    AssetReferenceDirtyRows,
    GenerationRunRows,
    AssistantRows,
    ProviderRows,
    ProviderGroupRows,
    McpServerRows,
    WorldBookRows,
    AssistantMemoryRows,
    QuickPhraseRows,
    SearchServiceRows,
    TtsServiceRows,
    InstructionInjectionRows,
    AssistantTagRows,
    PreferenceRows,
    MemoryEntryRows,
    UserProfileFieldRows,
    MessagePromptRows,
    ApkProjectRows,
    ModifyRuleRows,
    RuleSubscriptionRows,
    SoWorkspaceRows,
    EngineStatsRows,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.executor);

  static const databaseFileName = 'kelivo.db';

  // Schema 1 is the first published SQLite contract. Schema 2 adds the
  // apk_project_rows table (SoLab APK projects). Schema 3 adds the
  // modify_rule_rows table (SoLab APK rule library). Schema 4 rebuilds
  // message_prompt_rows without its FK to message_rows — prompt rows are a
  // derived cache and the FK breaks synthetic revisions (context-summary-*).
  // Schema 5 widens memory_entry_rows.type CHECK to accept apk_patch/apk_note
  // (SoLab APK memories folded into the memory system). Schema 6 repairs
  // memory_entry_rows indexes lost by an early schema-5 migration (partial
  // migration left userVersion=5 without visible/recent indexes); the repair
  // is idempotent (IF NOT EXISTS) and also covers fresh schema-5 databases.
  // Schema 7 adds so_workspace_rows (SO analysis workspaces) and
  // engine_stats_rows (SO engine tool stats).
  // Schema 8 adds rule_subscription_rows (SoLab APK rule subscriptions).
  // Every other non-zero version belongs to an unpublished or future format
  // and is rejected.
  static const currentSchemaVersion = 8;
  // Keep SQLite's established 1000-page cadence explicit. At the usual 4 KiB
  // page size this starts a checkpoint around 4 MiB, but page size remains the
  // source of truth.
  static const walAutoCheckpointPages = 1000;
  // This limits retained journal/WAL storage after reset/checkpoint; it is not
  // a promise that an active WAL can never temporarily exceed 16 MiB.
  static const journalSizeLimitBytes = 16 << 20;
  static const busyTimeoutMillis = 5000;
  // Under WAL, NORMAL still guarantees crash consistency; a power loss can
  // only drop transactions since the last checkpoint, which the
  // generation-run recovery path already tolerates. FULL would add an fsync
  // per write transaction on the streaming hot path.
  static const synchronousNormal = 1;
  static const _executionIsolateProbeFunction =
      'kelivo_sqlite_on_opening_isolate';
  static const _maxExecutionIsolateProbeSamples = 1000;

  factory AppDatabase.open({File? file}) {
    final databaseFile = file;
    if (databaseFile != null) {
      return AppDatabase(_openExecutor(databaseFile));
    }
    return AppDatabase(
      LazyDatabase(() async {
        final dir = await AppDirectories.getAppDataDirectory();
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
        return _openExecutor(File('${dir.path}/$databaseFileName'));
      }),
    );
  }

  static QueryExecutor _openExecutor(File file) {
    final openingIsolatePort = Isolate.current.controlPort;
    return NativeDatabase.createInBackground(
      file,
      setup: (database) {
        final installedSchema = database.userVersion;
        // 只拒绝「比当前新」的 schema（需升级 App）。旧 schema 由 drift
        // onUpgrade 迁移后 userVersion 更新；此处若要求严格相等，迁移
        // 永远不会执行（setup 先于 onUpgrade 运行），升级用户直接失败屏。
        if (installedSchema != 0 &&
            installedSchema > AppDatabase.currentSchemaVersion) {
          throw StateError('database_schema_version');
        }
        // This callback is registered and invoked by SQLite on drift's worker
        // isolate. Keep it non-deterministic so a multi-row profile query
        // cannot be folded into a single callback by SQLite.
        database.createFunction(
          functionName: _executionIsolateProbeFunction,
          argumentCount: const AllowedArgumentCount(0),
          deterministic: false,
          directOnly: true,
          function: (_) =>
              Isolate.current.controlPort == openingIsolatePort ? 1 : 0,
        );
        database.execute('PRAGMA journal_mode = WAL;');
        database.execute('PRAGMA foreign_keys = ON;');
        database.execute('PRAGMA busy_timeout = $busyTimeoutMillis;');
        database.execute('PRAGMA synchronous = NORMAL;');
        database.execute(
          'PRAGMA wal_autocheckpoint = $walAutoCheckpointPages;',
        );
        database.execute('PRAGMA journal_size_limit = $journalSizeLimitBytes;');
      },
    );
  }

  /// Samples the isolate executing callbacks on the live SQLite connection.
  ///
  /// The opening isolate is the Flutter UI isolate in the profile harness.
  Future<SqliteExecutionIsolateProbeResult> probeExecutionIsolate({
    int samples = 64,
  }) async {
    RangeError.checkValueInInterval(
      samples,
      1,
      _maxExecutionIsolateProbeSamples,
      'samples',
    );
    final row = await customSelect(
      '''
WITH RECURSIVE probe(sample) AS (
  VALUES (1)
  UNION ALL
  SELECT sample + 1 FROM probe WHERE sample < ?
)
SELECT
  COUNT(*) AS sample_count,
  COALESCE(SUM($_executionIsolateProbeFunction()), 0)
    AS opening_isolate_calls
FROM probe;
''',
      variables: [Variable.withInt(samples)],
    ).getSingle();
    final sampleCount = row.read<int>('sample_count');
    final openingIsolateCalls = row.read<int>('opening_isolate_calls');
    return (
      samples: sampleCount,
      openingIsolateCalls: openingIsolateCalls,
      backgroundIsolateCalls: sampleCount - openingIsolateCalls,
    );
  }

  @override
  int get schemaVersion => currentSchemaVersion;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        await m.createTable($ApkProjectRowsTable(m.database));
      }
      if (from < 3) {
        await m.createTable($ModifyRuleRowsTable(m.database));
      }
      if (from < 4) {
        // Schema 4：message_prompt_rows 去掉 message_rows 外键。SQLite 无法
        // ALTER 删除约束，用新表定义重建并拷贝数据（新表无 FK；索引重建）。
        final newTable = $MessagePromptRowsTable(
          m.database,
        ).createAlias('message_prompt_rows_new');
        await m.database.customStatement(
          'DROP TABLE IF EXISTS message_prompt_rows_new;',
        );
        await m.createTable(newTable);
        await m.database.customStatement(
          'INSERT INTO message_prompt_rows_new '
          '(revision_id, conversation_id, payload, carries_memory_snapshot, created_at) '
          'SELECT revision_id, conversation_id, payload, '
          'carries_memory_snapshot, created_at FROM message_prompt_rows;',
        );
        await m.database.customStatement('DROP TABLE message_prompt_rows;');
        await m.database.customStatement(
          'ALTER TABLE message_prompt_rows_new RENAME TO message_prompt_rows;',
        );
        await m.database.customStatement(
          'CREATE INDEX IF NOT EXISTS idx_message_prompts_conversation_snapshot '
          'ON message_prompt_rows (conversation_id, carries_memory_snapshot);',
        );
      }
      if (from < 5) {
        // Schema 5：memory_entry_rows 的 type CHECK 扩为 6 值。SQLite 无法
        // ALTER CHECK，列结构不变（仅约束变化），按列原样重建表。
        final newTable = $MemoryEntryRowsTable(
          m.database,
        ).createAlias('memory_entry_rows_new');
        await m.database.customStatement(
          'DROP TABLE IF EXISTS memory_entry_rows_new;',
        );
        await m.createTable(newTable);
        await m.database.customStatement(
          'INSERT INTO memory_entry_rows_new '
          '(id, sort_order, scope, assistant_id, type, status, content, '
          'content_normalized, entry_created_at, entry_updated_at, payload, '
          'updated_at) '
          'SELECT id, sort_order, scope, assistant_id, type, status, content, '
          'content_normalized, entry_created_at, entry_updated_at, payload, '
          'updated_at FROM memory_entry_rows;',
        );
        await m.database.customStatement('DROP TABLE memory_entry_rows;');
        await m.database.customStatement(
          'ALTER TABLE memory_entry_rows_new RENAME TO memory_entry_rows;',
        );
      }
      if (from < 6) {
        // Schema 6：补建 memory_entry_rows 索引（幂等）。早期 schema-5 迁移
        // 只建了 dedupe 索引就把 userVersion 提交为 5，导致部分迁移卡死
        //（visible/recent 缺失 → index_schema 校验失败）；此处对任何
        // 1..5 的库都幂等补全，与表定义 @TableIndex 的 DDL 完全一致。
        await m.database.customStatement(
          'CREATE INDEX IF NOT EXISTS idx_memory_entries_visible '
          'ON memory_entry_rows (status, type, scope, assistant_id);',
        );
        await m.database.customStatement(
          'CREATE INDEX IF NOT EXISTS idx_memory_entries_recent '
          'ON memory_entry_rows (status, type, entry_updated_at, id);',
        );
        await m.database.customStatement(
          'CREATE INDEX IF NOT EXISTS idx_memory_entries_dedupe '
          'ON memory_entry_rows (scope, assistant_id, type, content_normalized);',
        );
      }
      if (from < 7) {
        // Schema 7：SO 引擎表（so_workspace_rows / engine_stats_rows）
        await m.createTable($SoWorkspaceRowsTable(m.database));
        await m.createTable($EngineStatsRowsTable(m.database));
      }
      if (from < 8) {
        // Schema 8：规则订阅源表（rule_subscription_rows）
        await m.createTable($RuleSubscriptionRowsTable(m.database));
      }
      if (from > to) {
        // A newer database format must not be silently downgraded.
        throw StateError('database_schema_version');
      }
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON;');
      await customStatement('PRAGMA busy_timeout = 5000;');
    },
  );
}
