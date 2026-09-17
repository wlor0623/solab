abstract final class LocalToolNames {
  static const timeInfo = 'get_time_info';
  static const clipboard = 'clipboard_tool';
  static const textToSpeech = 'text_to_speech';
  static const askUser = 'ask_user_input_v0';
  static const calculate = 'calculate';
  static const screenTime = 'get_screen_time';
  static const calendarQuery = 'calendar_query';
  static const calendarCreate = 'calendar_create';
  static const apkReport = 'get_current_apk_report';
  static const apkSkill = 'get_solab_skill';
  static const apkKnowledge = 'get_apk_knowledge';
  static const installedSkills = 'get_installed_skills';
  static const agentRuntimeGuide = 'get_agent_runtime_guide';
  static const apkProjectInfo = 'get_apk_project_info';
  static const apkRules = 'list_apk_rules';
  static const apkPatchDex = 'patch_apk_dex_methods';
  static const apkSignatureBypass = 'signature_bypass';
  static const apkPatchManifest = 'patch_apk_manifest';
  static const apkToolMap = 'get_solab_tool_map';
  static const apkPatchMemory = 'get_apk_patch_memory';
  static const apkSavePatchMemory = 'save_apk_patch_memory';
  static const apkRecordPatchVerification = 'record_apk_patch_verification';
  static const apkListBuilds = 'list_apk_builds';
  static const apkCleanupBuilds = 'cleanup_apk_builds';
  static const apkNoteRead = 'apk_note_read';
  static const apkNoteWrite = 'apk_note_write';
  static const apkListWorkspace = 'list_workspace_apks';
  static const apkAnalyzeWorkspace = 'analyze_apk_workspace';
  static const apkArchive = 'apk_archive';
  static const apkExportReport = 'export_apk_report';
  static const jadxDecompile = 'jadx_decompile';
  static const apkSign = 'apk_sign';
  static const apkRebuild = 'apk_rebuild';
  static const dexSearch = 'dex_search';
  static const stringScan = 'string_scan';
  static const dexXref = 'dex_xref';
  static const classOutline = 'class_outline';
  static const smaliRead = 'smali_read';
  static const soAnalyze = 'so_analyze';
  static const soPatchIntoApk = 'so_patch_into_apk';
  static const file = 'file';
  static const routeTask = 'route_task';

  // ---- 系统级内置工具（不进 LocalToolRegistry，由 ToolHandlerService 直接分发；
  //      仅供 ToolRouter 等路由层引用，避免名单散落成裸字符串）----
  static const memoryRead = 'memory_read';
  static const memoryUpdate = 'memory_update';
  static const memorySearchProfile = 'memory_search_profile';
  static const memoryEdit = 'memory_edit';
  static const memoryDelete = 'memory_delete';
  static const updateUserProfile = 'update_user_profile';
  static const chatSearch = 'chat_search';
  static const getToolResult = 'get_tool_result';

  /// 服务端搜索工具（provider 流内建，见 stream_chunk_handler），非本地注册表工具。
  static const searchWeb = 'search_web';

  static const builtin = <String>[
    memoryRead,
    memoryUpdate,
    memorySearchProfile,
    memoryEdit,
    memoryDelete,
    updateUserProfile,
    chatSearch,
    getToolResult,
    searchWeb,
  ];

  static const all = <String>[
    timeInfo,
    clipboard,
    textToSpeech,
    askUser,
    calculate,
    screenTime,
    calendarQuery,
    calendarCreate,
    apkReport,
    apkSkill,
    apkKnowledge,
    installedSkills,
    agentRuntimeGuide,
    apkProjectInfo,
    apkRules,
    apkPatchDex,
    apkSignatureBypass,
    apkPatchManifest,
    apkToolMap,
    apkPatchMemory,
    apkSavePatchMemory,
    apkRecordPatchVerification,
    apkListBuilds,
    apkCleanupBuilds,
    apkNoteRead,
    apkNoteWrite,
    apkListWorkspace,
    apkAnalyzeWorkspace,
    apkArchive,
    apkExportReport,
    jadxDecompile,
    apkSign,
    apkRebuild,
    dexSearch,
    stringScan,
    dexXref,
    classOutline,
    smaliRead,
    soAnalyze,
    soPatchIntoApk,
    file,
    routeTask,
  ];
}
