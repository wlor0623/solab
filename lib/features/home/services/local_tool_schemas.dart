part of 'local_tools_service.dart';

const kSoAnalyzeActionCatalog = <String>[
  'open',
  'open_url',
  'workspaces',
  'close',
  'list_sources',
  'analyze_apk',
  'read_elf',
  'crypto_scan',
  'jni_bridge',
  'read_stats',
  'disasm',
  'hexdump',
  'strings',
  'search',
  'list',
  'overview',
  'analysis_report',
  'edit_open',
  'edit_snapshot',
  'edit_rollback',
  'edit_undo',
  'edit_redo',
  'edit_reset',
  'edit_hex',
  'edit_asm',
  'edit_symbol',
  'edit_check',
  'fix_sections',
  'xanso_build_sections',
  'build',
  'build_many',
  'list_builds',
  'diff',
  'rz_diff',
  'audit',
  'audit_persist',
  'audit_load',
  'list_audits',
  'rz_analyze',
  'rz_functions',
  'rz_xrefs',
  'rz_decompile',
  'rz_crypto',
  'rz_cfg',
  'rz_esil',
  'rz_search_bytes',
  'rz_command',
  'rz_asm',
  'lief_dispatch',
  'lief_patch_address',
  'lief_add_export',
  'lief_remove_symbol',
  'xanso_dispatch',
  'emulate',
  'emulate_dump',
  'emulation_status',
  'unidbg_dispatch',
  'unidbg_batch',
  'blutter',
  'suggest',
  'capabilities',
  'asset_status',
  'asset_download',
];

List<Map<String, dynamic>> buildLocalToolSchemas({
  required Assistant? assistant,
  required bool supportsTools,
  required Map<String, Object> apkPathParameter,
  required String Function() deviceTimezoneHint,
}) {
  if (!supportsTools || assistant == null) {
    return const <Map<String, dynamic>>[];
  }

  final registeredToolIds = LocalToolRegistry.specs
      .map((spec) => spec.name)
      .toSet();
  final tools = <Map<String, dynamic>>[];
  if (assistant.localToolIds.contains(LocalToolNames.agentRuntimeGuide)) {
    tools.add(const {
      'type': 'function',
      'function': {
        'name': LocalToolNames.agentRuntimeGuide,
        'description':
            'Read the current APK Agent capability guide only when the active instructions, memory, World Books, Skills, or available tools could change the next action. Do not treat names alone as task evidence.',
        'parameters': {
          'type': 'object',
          'properties': {
            'tool': {
              'type': 'string',
              'description':
                  'Optional tool name. Pass so_analyze to get its complete action catalog and parameters.',
            },
          },
        },
      },
    });
  }
  if (assistant.localToolIds.contains(LocalToolNames.timeInfo)) {
    tools.add(const {
      'type': 'function',
      'function': {
        'name': LocalToolNames.timeInfo,
        'description':
            'Get the current local date and time info from the device. Returns year, month, day, weekday, ISO date and time strings, timezone, UTC offset, and timestamp.',
        'parameters': {'type': 'object', 'properties': <String, dynamic>{}},
      },
    });
  }
  if (assistant.localToolIds.contains(LocalToolNames.clipboard)) {
    tools.add(const {
      'type': 'function',
      'function': {
        'name': LocalToolNames.clipboard,
        'description':
            'Read or write plain text from the device clipboard. Use action: read or write. For write, provide text. Do NOT write to the clipboard unless the user has explicitly requested it.',
        'parameters': {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'enum': ['read', 'write'],
              'description': 'Operation to perform: read or write',
            },
            'text': {
              'type': 'string',
              'description':
                  'Text to write to the clipboard. Required for write.',
            },
          },
          'required': ['action'],
        },
      },
    });
  }
  if (assistant.localToolIds.contains(LocalToolNames.textToSpeech)) {
    tools.add(const {
      'type': 'function',
      'function': {
        'name': LocalToolNames.textToSpeech,
        'description':
            'Speak text aloud to the user using the configured text-to-speech playback. Use this when the user asks you to read something aloud, or when audio output is appropriate. The tool returns after playback has been requested; audio may continue in the background. Provide natural, readable text without markdown formatting.',
        'parameters': {
          'type': 'object',
          'properties': {
            'text': {
              'type': 'string',
              'description': 'The text to speak aloud.',
            },
          },
          'required': ['text'],
        },
      },
    });
  }
  if (assistant.localToolIds.contains(LocalToolNames.askUser)) {
    tools.add(const {
      'type': 'function',
      'function': {
        'name': LocalToolNames.askUser,
        'description':
            'Ask the user one or more short choice questions when you need clarification, additional information, or a decision before continuing. Supports single-choice and multi-choice questions. The UI will provide Other and Skip options automatically, so do not include those options yourself.',
        'parameters': {
          'type': 'object',
          'properties': {
            'questions': {
              'type': 'array',
              'description': 'One to four questions to ask the user.',
              'items': {
                'type': 'object',
                'properties': {
                  'id': {
                    'type': 'string',
                    'description':
                        'Unique stable identifier for this question.',
                  },
                  'question': {
                    'type': 'string',
                    'description': 'The full question text shown to the user.',
                  },
                  'type': {
                    'type': 'string',
                    'enum': ['single', 'multi'],
                    'description':
                        'Answer type: single choice or multi choice.',
                  },
                  'options': {
                    'type': 'array',
                    'description':
                        'Suggested options for the user to choose from.',
                    'items': {'type': 'string'},
                  },
                },
                'required': ['id', 'question'],
              },
            },
          },
          'required': ['questions'],
        },
      },
    });
  }
  if (assistant.localToolIds.contains(LocalToolNames.calculate)) {
    tools.add(const {
      'type': 'function',
      'function': {
        'name': LocalToolNames.calculate,
        'description':
            'Evaluate a mathematical expression. Supports: + - * / ^ % !, sin() cos() tan() sqrt() ln() abs() floor() ceil() sgn(), log(base, value), constants pi e. Example: "5!", "sin(pi/4)", "log(2, 8)", "floor(3.7)"',
        'parameters': {
          'type': 'object',
          'properties': {
            'expression': {
              'type': 'string',
              'description':
                  'A mathematical expression in standard notation, e.g. "(15 + 3) * 2", "2^10", "sqrt(144)"',
            },
          },
          'required': ['expression'],
        },
      },
    });
  }
  if (DeviceLocalTools.screenTimeSupported &&
      assistant.localToolIds.contains(LocalToolNames.screenTime)) {
    tools.add({
      'type': 'function',
      'function': {
        'name': LocalToolNames.screenTime,
        'description':
            "Get the user's app screen usage (screen time) over a time range. "
            "Specify a custom interval with 'begin'/'end', or use the 'range' preset (today/week). "
            'Returns the total foreground time and a per-app breakdown sorted by usage time (descending). '
            '${deviceTimezoneHint()} '
            "Requires the 'Usage access' special permission; if it is not granted, the device's usage "
            'access settings page is opened automatically and an error is returned.',
        'parameters': {
          'type': 'object',
          'properties': {
            'begin': {
              'type': 'string',
              'description':
                  "Start time (inclusive). Accepts an ISO-8601 date 'yyyy-MM-dd', a local "
                  "date-time 'yyyy-MM-ddTHH:mm:ss', an offset date-time, or epoch milliseconds. "
                  "When provided, 'range' is ignored.",
            },
            'end': {
              'type': 'string',
              'description':
                  "End time (exclusive), same formats as 'begin'. Defaults to now.",
            },
            'range': {
              'type': 'string',
              'enum': ['today', 'week'],
              'description':
                  "Convenience preset, used only when 'begin' is omitted: today or week. Default today.",
            },
            'top': {
              'type': 'integer',
              'description':
                  'Maximum number of top apps to return, sorted by usage time. Default 10.',
            },
          },
        },
      },
    });
  }
  if (DeviceLocalTools.calendarSupported &&
      assistant.localToolIds.contains(LocalToolNames.calendarQuery)) {
    tools.add({
      'type': 'function',
      'function': {
        'name': LocalToolNames.calendarQuery,
        'description':
            "Query calendar events on the user's device within a time range. "
            "Specify a custom interval with 'begin'/'end', or use the 'range' preset (today/week/month). "
            'Returns a list of events with title, description, location, start/end times, and calendar info. '
            '${deviceTimezoneHint()} '
            "Requires the 'Calendar' permission; if it is not granted, an error is returned.",
        'parameters': {
          'type': 'object',
          'properties': {
            'begin': {
              'type': 'string',
              'description':
                  "Start time (inclusive). Accepts an ISO-8601 date 'yyyy-MM-dd', a local "
                  "date-time 'yyyy-MM-ddTHH:mm:ss', an offset date-time, or epoch milliseconds. "
                  "When provided, 'range' is ignored.",
            },
            'end': {
              'type': 'string',
              'description': "End time (exclusive), same formats as 'begin'.",
            },
            'range': {
              'type': 'string',
              'enum': ['today', 'week', 'month'],
              'description':
                  "Convenience preset, used only when 'begin' is omitted: today, week, or month. Default today.",
            },
            'query': {
              'type': 'string',
              'description':
                  'Optional keyword to filter events by title (case-insensitive substring match).',
            },
            'limit': {
              'type': 'integer',
              'description': 'Maximum number of events to return. Default 20.',
            },
          },
        },
      },
    });
  }
  if (DeviceLocalTools.calendarSupported &&
      assistant.localToolIds.contains(LocalToolNames.calendarCreate)) {
    tools.add({
      'type': 'function',
      'function': {
        'name': LocalToolNames.calendarCreate,
        'description':
            "Create a new calendar event on the user's device. "
            'Requires title and start time at minimum. End time defaults to 1 hour after start. '
            'The user will be asked to confirm before the event is created. '
            '${deviceTimezoneHint()} '
            "Requires the 'Calendar' permission; if it is not granted, an error is returned.",
        'parameters': {
          'type': 'object',
          'properties': {
            'title': {'type': 'string', 'description': 'Event title.'},
            'description': {
              'type': 'string',
              'description': 'Event description or notes.',
            },
            'location': {'type': 'string', 'description': 'Event location.'},
            'start': {
              'type': 'string',
              'description':
                  "Start time. Accepts an ISO-8601 date 'yyyy-MM-dd', a local "
                  "date-time 'yyyy-MM-ddTHH:mm:ss', an offset date-time, or epoch milliseconds.",
            },
            'end': {
              'type': 'string',
              'description':
                  "End time, same formats as 'start'. Defaults to 1 hour after start.",
            },
            'all_day': {
              'type': 'boolean',
              'description': 'Whether this is an all-day event. Default false.',
            },
          },
          'required': ['title', 'start'],
        },
      },
    });
  }
  if (assistant.localToolIds.contains(LocalToolNames.apkReport)) {
    tools.add({
      'type': 'function',
      'function': {
        'name': LocalToolNames.apkReport,
        'description':
            'Read the current SoLab APK analysis report. Always read decision first and use its verified signals as the target scope. Do not search file by file without report evidence. The report contains verified facts, not AI guesses.',
        'parameters': {
          'type': 'object',
          'properties': {
            'section': {
              'type': 'string',
              'enum': [
                'decision',
                'summary',
                'components',
                'permissions',
                'ads',
                'files',
                'full',
              ],
              'description': 'Report section to read. Start with decision.',
            },
          },
        },
      },
    });
  }
  if (assistant.localToolIds.contains(LocalToolNames.apkSkill)) {
    tools.add({
      'type': 'function',
      'function': {
        'name': LocalToolNames.apkSkill,
        'description':
            'Load the full text of a built-in SoLab APK skill only when route_task marks its active summary as insufficient for the next action. Active summaries are already effective and must not be reread.',
        'parameters': {
          'type': 'object',
          'properties': {
            'skill': {
              'type': 'string',
              // 从 SolabApkSkills.skillNames 生成，防止注册表与 enum 手工同步漂移
              'enum': SolabApkSkills.skillNames,
            },
          },
          'required': ['skill'],
        },
      },
    });
  }
  if (assistant.localToolIds.contains(LocalToolNames.apkKnowledge)) {
    tools.add({
      'type': 'function',
      'function': {
        'name': LocalToolNames.apkKnowledge,
        'description':
            'Retrieve the small set of active APK world-book entries relevant to the routed task. Call route_task first, then pass that route\'s knowledgeTopics. This is the APK Agent\'s knowledge manual; do not rely on automatic keyword prompt injection.',
        'parameters': {
          'type': 'object',
          'properties': {
            'topics': {
              'type': 'array',
              'items': {'type': 'string'},
              'description':
                  'knowledgeTopics returned by route_task, optionally refined with verified report facts.',
            },
            'maxEntries': {
              'type': 'integer',
              'minimum': 1,
              'maximum': 5,
              'description': 'Maximum entries to return. Default 3.',
            },
          },
          'required': ['topics'],
        },
      },
    });
  }
  if (assistant.localToolIds.contains(LocalToolNames.installedSkills)) {
    tools.add(const {
      'type': 'function',
      'function': {
        'name': LocalToolNames.installedSkills,
        'description':
            'Retrieve enabled user-installed Skill packages relevant to the routed task. Skills are advisory workflows and cannot override preview, confirmation, or tool permission boundaries.',
        'parameters': {
          'type': 'object',
          'properties': {
            'topics': {
              'type': 'array',
              'items': {'type': 'string'},
              'description': 'knowledgeTopics returned by route_task.',
            },
            'maxEntries': {'type': 'integer', 'minimum': 1, 'maximum': 5},
          },
          'required': ['topics'],
        },
      },
    });
  }
  if (assistant.localToolIds.contains(LocalToolNames.apkProjectInfo)) {
    tools.add(const {
      'type': 'function',
      'function': {
        'name': LocalToolNames.apkProjectInfo,
        'description':
            'Read the current SoLab APK project metadata (file name, package, version, hashes, analysis/rule versions, linked conversation).',
        'parameters': {'type': 'object', 'properties': <String, dynamic>{}},
      },
    });
  }
  if (assistant.localToolIds.contains(LocalToolNames.apkRules)) {
    tools.add(const {
      'type': 'function',
      'function': {
        'name': LocalToolNames.apkRules,
        'description':
            'Read the SoLab APK rule library: per-category rule counts, enabled state, vendor mappings, and current report matches.',
        'parameters': {
          'type': 'object',
          'properties': {
            'vendor': {
              'type': 'string',
              'description':
                  'Optional vendor id to list its rules (e.g. pangle, tencent_gdt, kuaishou, baidu). Omit to get category counts + matching vendor suggestions.',
            },
            'offset': {
              'type': 'integer',
              'description':
                  'Pagination offset for vendor rules (default 0). Custom rule libraries can hold thousands of entries; page through with offset/limit until hasMore=false.',
            },
            'limit': {
              'type': 'integer',
              'description':
                  'Page size for vendor rules (default 50, max 1000). Only fetch more when actually needed.',
            },
          },
        },
      },
    });
  }
  if (assistant.localToolIds.contains(LocalToolNames.apkPatchDex)) {
    tools.add({
      'type': 'function',
      'function': {
        'name': LocalToolNames.apkPatchDex,
        'description':
            'DEX write tool. Patch targets must come from class_outline / dex_xref / smali_read / Analyzer evidence — report string hits are clues, never patch targets. For an already-authorized exact change: call once with dryRun=true and applyAfterPreview=true (preview + apply in one). Use pure dryRun to see exact applyArguments when a decision is still needed. Output path goes to apk_sign; never overwrite the source APK.',
        'parameters': {
          'type': 'object',
          'properties': {
            'voidMethods': {
              'type': 'array',
              'items': {'type': 'string'},
              'description':
                  'Exact void-returning ad method names to neutralize, or class-qualified DEX identifiers (Lpkg/Class;->name) returned by class_outline, dex_xref or smali_read.',
            },
            'classMethods': {
              'type': 'array',
              'items': {'type': 'string'},
              'description':
                  'Exact class-qualified method identifiers from class_outline, dex_xref or smali_read (qualifiedId, e.g. Lcom/bytedance/.../TTAdSdk;->init). Accepted forms: Lpkg/Class;->name or pkg.Class.methodName. The engine dispatches by real return type: void is neutralized, boolean/int is forced false, callbacks and unsupported types are skipped and reported. This is the recommended way to patch any located method.',
            },
            'trueMethods': {
              'type': 'array',
              'items': {'type': 'string'},
              'description':
                  'Exact membership/VIP state method names to force true (B3). Obtain them from class_outline, dex_xref or smali_read after verifying the real boolean-returning definition. Report string hits are clues and CANNOT be patched directly. Accepted forms: exact method name, Lpkg/Class;->name, or full qualifiedId with signature (Lpkg/Class;->name(params)ret). Matching is case-insensitive; the dryRun response returns the original DEX spelling.',
            },
            'falseMethods': {
              'type': 'array',
              'items': {'type': 'string'},
              'description':
                  'Exact boolean/integer ad-state method names to force false.',
            },
            'sdkPackages': {
              'type': 'array',
              'items': {'type': 'string'},
              'description':
                  'Ad SDK package names matched in the report (adSdkMatches). Only loadLibrary calls whose library-name string is statically present are NOPed. A runtime argument is intentionally not guessed; use the matched upstream init method instead.',
            },
            'removeVpnDetection': {
              'type': 'boolean',
              'description':
                  'Force VPN-detection methods (name contains isvpn/checkvpn/vpnconnected/... , boolean/int return) to false. Preview first.',
            },
            'removeEmulatorDetection': {
              'type': 'boolean',
              'description':
                  'Force emulator-detection methods (name contains isemulator/checkemulator/isvirtualdevice/... , boolean/int return) to false. Preview first.',
            },
            'removeRootDetection': {
              'type': 'boolean',
              'description':
                  'Force root-detection methods (name contains isrooted/checkroot/hasroot/suavailable/... , boolean/int return) to false. Preview first.',
            },
            'removeScreenCaptureDetection': {
              'type': 'boolean',
              'description':
                  'Force screen-capture/recording-detection methods (name contains onscreencapture/screencapturecallback/isrecording/isprojection/... , boolean/int return) to false so the app cannot detect or react to screenshots or screen recording. Preview first and confirm the hit list — isrecording is broad by design.',
            },
            'removeFlagSecure': {
              'type': 'boolean',
              'description':
                  'Re-enable screenshots: clear the FLAG_SECURE (0x2000) bit from constants flowing into Window.setFlags/addFlags, keeping other flag bits intact (0x2008 stays 0x0008). Surgical instruction-level patch — it does not void onCreate or whole methods. Covers the common addFlags(FLAG_SECURE)/setFlags(FLAG_SECURE, FLAG_SECURE) pattern; or-int bit-composition is not covered yet (locate manually with smali_read + classMethods).',
            },
            'removeDebugDetection': {
              'type': 'boolean',
              'description':
                  'Force debugger-detection methods (name contains isdebuggable/isdebuggerconnected/ptrace/antidebug/... , boolean/int return) to false. Preview first.',
            },
            'timeMethods': {
              'type': 'array',
              'items': {'type': 'string'},
              'description':
                  'Exact expiry/remaining-time method names to hijack to a far-future value (long-return only), from the report timeMethodCandidates.',
            },
            'nullMethods': {
              'type': 'array',
              'items': {'type': 'string'},
              'description':
                  'Exact object-returning method names to stub to return null (REQ-06). Only affects methods whose return type is an object (starts with L).',
            },
            'shortenSplashCountdown': {
              'type': 'boolean',
              'description':
                  'Shorten splash-screen ad countdowns: in classes whose type contains "splash", track CONST values written to registers; when Handler.postDelayed / sendEmptyMessageDelayed / sendMessageDelayed / CountDownTimer.<init> is hit with delay >= 1000ms, zero out the delay constant so the countdown ends immediately and the app enters the main UI. Preview counts how many will be shortened.',
            },
            'signatureBypass': {
              'type': 'boolean',
              'default': false,
              'description':
                  'Signature-compatibility injection. Defaults false: this tool patches business logic only. Use the dedicated signature_bypass tool as the first write against the unchanged original APK instead of mixing it into a patch call. If you still set it here, run it alone against the unchanged original (no business patch in the same call), then pass the returned nextInputPath to later modifications with signatureBypass=false.',
            },
            'signatureBypassMode': {
              'type': 'string',
              'enum': ['normal', 'original_apk'],
              'description':
                  'Signature compatibility mode. Use normal by default. original_apk is the fallback for whole-APK verification and uses embedded-original I/O redirection plus ZIP data multiplexing. Only relevant when signatureBypass=true.',
            },
            'originalApkPath': {
              'type': 'string',
              'description':
                  'Absolute path of the unchanged original APK. Required when upgrading an already modified normal-mode package; optional when apkPath itself is the unchanged original.',
            },
            'stripDebugInfo': {
              'type': 'boolean',
              'description':
                  'Size optimization (from ref 2.9): when writing back a patched DEX, strip debug info (line numbers / local variable tables / param names) from ALL classes in that DEX, shrinking it by 5%~15% with zero runtime impact. Only applies to DEX files already being rewritten by this patch call; does not touch unmodified DEX files. Recommended true when size matters.',
            },
            ...apkPathParameter,
            'dryRun': {'type': 'boolean'},
            'applyAfterPreview': {
              'type': 'boolean',
              'description':
                  'When the user already authorized this exact modification, set true with dryRun=true. The tool previews and, only if the preview has no warning, applies the same parameters in this call.',
            },
            'confirm': {'type': 'boolean'},
            'previewToken': {'type': 'string'},
          },
          'required': ['dryRun'],
        },
      },
    });
  }
  if (assistant.localToolIds.contains(LocalToolNames.apkSignatureBypass)) {
    tools.add({
      'type': 'function',
      'function': {
        'name': LocalToolNames.apkSignatureBypass,
        'description':
            'Standalone signature handling — three independent 原包过签 modes, freely switchable per user instruction. Omit mode to follow the APK 工作台 setting (new-install default: normal); an explicit user mode always wins. mode=normal fakes PackageInfo signatures in-process; mode=original_apk embeds the original APK and redirects file reads; mode=dpatch writes only its independent DEX/native payload plus the unchanged original APK, then starts through its component factory before application creation. Every mode returns an output path: use it as apkPath for every later modification with signatureBypass=false. Does NOT analyze, patch business logic, or sign. Call it alone; do not reuse patch_apk_dex_methods(signatureBypass=true) for this. 用户说“DPatch/第三种”时用 mode=dpatch；它必须从未修改原包生成独立产物，不能直接修改原包，也不能混入普通/原包模式的 DEX、库或标记。',
        'parameters': {
          'type': 'object',
          'properties': {
            ...apkPathParameter,
            'mode': {
              'type': 'string',
              'enum': ['normal', 'original_apk', 'dpatch'],
              'description':
                  '省略时跟随 APK 工作台当前设置（新装默认 normal）；显式传入时以用户指定为准。normal=Application 代理 | original_apk=原包嵌入重定向 | dpatch=独立 DEX/原生载荷和组件工厂启动（从未修改原包生成独立产物）。',
            },
            'originalApkPath': {
              'type': 'string',
              'description':
                  'Absolute path of the unchanged original APK, required when upgrading an already-modified normal-mode package to original_apk.',
            },
          },
          'required': ['apkPath'],
        },
      },
    });
  }
  if (assistant.localToolIds.contains(LocalToolNames.apkPatchManifest)) {
    tools.add({
      'type': 'function',
      'function': {
        'name': LocalToolNames.apkPatchManifest,
        'description':
            'Apply AndroidManifest.xml edits to remove ad components, permissions, or ad SDK meta-data. For an exact modification already authorized by the user, call once with dryRun=true and applyAfterPreview=true; warning or no-change previews are never auto-applied. Pure dryRun returns exact applyArguments for a later call. Set auto=true to match the rule library. Removing components can cause ActivityNotFoundException; prefer verified meta-data edits. The source APK is never modified; sign the output before installing.',
        'parameters': {
          'type': 'object',
          'properties': {
            'removeComponents': {
              'type': 'array',
              'items': {'type': 'string'},
              'description':
                  'Exact component full names (e.g. com.ad.sdk.AdActivity) to remove. Empty to skip.',
            },
            'removePermissions': {
              'type': 'array',
              'items': {'type': 'string'},
              'description':
                  'Exact permission names (e.g. android.permission.READ_PHONE_STATE) to remove. Empty to skip.',
            },
            'removeMetaData': {
              'type': 'array',
              'items': {'type': 'string'},
              'description':
                  'Exact ad SDK meta-data config keys (e.g. com.qq.e.comm.AppId) to remove. Safer than removing components: ad SDK init fails silently. Empty to skip.',
            },
            'auto': {
              'type': 'boolean',
              'description':
                  'Match ad components and ad_permissions automatically from the rule library.',
            },
            ...apkPathParameter,
            'dryRun': {'type': 'boolean'},
            'applyAfterPreview': {
              'type': 'boolean',
              'description':
                  'For an already authorized exact modification: preview and apply the unchanged parameters in one call unless the preview contains a warning.',
            },
            'confirm': {'type': 'boolean'},
            'previewToken': {'type': 'string'},
          },
          'required': ['dryRun'],
        },
      },
    });
  }
  if (assistant.localToolIds.contains(LocalToolNames.apkToolMap)) {
    tools.add(const {
      'type': 'function',
      'function': {
        'name': LocalToolNames.apkToolMap,
        'description':
            'List the enabled APK tools as a compact index. Pass tool=<name> to get that tool\'s complete parameter schema and documentation.',
        'parameters': {
          'type': 'object',
          'properties': {
            'tool': {
              'type': 'string',
              'description':
                  'Optional exact tool name. Returns the complete schema for that one tool.',
            },
          },
        },
      },
    });
  }
  if (assistant.localToolIds.contains(LocalToolNames.apkPatchMemory)) {
    tools.add(const {
      'type': 'function',
      'function': {
        'name': LocalToolNames.apkPatchMemory,
        'description':
            'Two modes. (1) Default: read past patch memories matching the CURRENT APK by type fingerprint (ad SDK vendors + shell type + engine), NOT by package name/SHA/app name. Call before modifying to reuse a one-line solution. (2) lookupArtifactPath: identify a mysterious APK file by its content sha256 — answers "is this file an already-verified patched product / an analyzed source package?" across sessions, so you never redo an already-patched baseline from the original.',
        'parameters': {
          'type': 'object',
          'properties': {
            'lookupArtifactPath': {
              'type': 'string',
              'description':
                  'Absolute path of an APK to identify by content fingerprint. Returns matched verified-artifact records (with solution/targets) and/or the registered source project. Recommended before re-patching any pre-existing _signed/baseline APK found in the work directory.',
            },
            'listAll': {
              'type': 'boolean',
              'description':
                  'true = return a compact summary of ALL stored experiences (id/title/app/version/outcome) instead of the current-APK match. Use to browse; full details load via the default matched mode.',
            },
          },
        },
      },
    });
  }
  if (assistant.localToolIds.contains(LocalToolNames.apkSavePatchMemory)) {
    tools.add(const {
      'type': 'function',
      'function': {
        'name': LocalToolNames.apkSavePatchMemory,
        'description':
            'Stage the final APK modification record after apk_sign. This does NOT write long-term memory. It persists a pending draft on the signed artifact so it survives until the user installs the APK. After staging, Agent mode must call ask_user_input_v0 to ask whether the modification worked; MCP callers without a question tool may ask in text. Only record_apk_patch_verification may commit the staged draft.',
        'parameters': {
          'type': 'object',
          'properties': {
            'title': {
              'type': 'string',
              'description': 'Short type label, e.g. 穿山甲+开屏去广告',
            },
            'solution': {
              'type': 'string',
              'description':
                  'One-line minimal fix: which single place to patch to disable a whole class.',
            },
            'pitfall': {
              'type': 'string',
              'description':
                  'Optional how-to-do-it-right warning shown on reuse, e.g. 恒返回常量用 force_return_constant，勿裸 hex 改栈帧.',
            },
            'targets': {
              'type': 'array',
              'items': {'type': 'string'},
              'description':
                  'Concrete patch locators of this run (dex qualifiedId / so symbol / zip entry path). Same-type entries are merged into one memory; targets accumulate so future runs can locate the exact spots directly.',
            },
          },
          'required': ['title', 'solution'],
        },
      },
    });
  }
  if (assistant.localToolIds.contains(
    LocalToolNames.apkRecordPatchVerification,
  )) {
    tools.add(const {
      'type': 'function',
      'function': {
        'name': LocalToolNames.apkRecordPatchVerification,
        'description':
            'Commit the staged APK draft to long-term memory exactly once, only after the user explicitly reports the installed signed APK worked or failed. Tool success, byte verification, signing, or delivering the file is not user validation. A success automatically cleans the work directory and keeps exactly the original APK plus the final signed APK; failure keeps the diagnostic workspace.',
        'parameters': {
          'type': 'object',
          'properties': {
            'outcome': {
              'type': 'string',
              'enum': ['success', 'failure'],
            },
            'summary': {
              'type': 'string',
              'description': 'Installed behavior and any regression observed.',
            },
            'pitfall': {
              'type': 'string',
              'description':
                  'Optional pitfall learned in this run, e.g. 恒返回常量用 force_return_constant，勿裸 hex 改栈帧. Merged into the verified memory entry.',
            },
          },
          'required': ['outcome', 'summary'],
        },
      },
    });
  }
  if (assistant.localToolIds.contains(LocalToolNames.apkListBuilds)) {
    tools.add(const {
      'type': 'function',
      'function': {
        'name': LocalToolNames.apkListBuilds,
        'description':
            'List all indexed APK artifacts, including patch intermediates and MT builds (output path + timestamp + keep flag). Use it to inspect the exact artifact history before cleanup.',
        'parameters': {'type': 'object', 'properties': <String, dynamic>{}},
      },
    });
  }
  if (assistant.localToolIds.contains(LocalToolNames.apkCleanupBuilds)) {
    tools.add(const {
      'type': 'function',
      'function': {
        'name': LocalToolNames.apkCleanupBuilds,
        'description':
            'Reclaim workspace junk after a task chain: default scope deletes regenerable caches and stale outputs; aggressive=true restores the indexed clean baseline. Always dryRun first, then confirm=true with the previewToken. After the user confirms the installed final APK works, verified cleanup runs automatically and keeps only the original APK and final signed artifact.',
        'parameters': {
          'type': 'object',
          'properties': {
            'aggressive': {
              'type': 'boolean',
              'description':
                  'Also restore the clean baseline: remove everything in the work dir except signed builds, indexed source APKs, and the active modification target (Blutter results and jadx exports are deleted too — they will be rebuilt on demand). Default false.',
            },
            'dryRun': {'type': 'boolean'},
            'confirm': {'type': 'boolean'},
            'previewToken': {'type': 'string'},
          },
          'required': ['dryRun'],
        },
      },
    });
  }
  if (assistant.localToolIds.contains(LocalToolNames.apkNoteRead)) {
    tools.add(const {
      'type': 'function',
      'function': {
        'name': LocalToolNames.apkNoteRead,
        'description':
            'Read persisted notes of which methods/entries were already modified for the current APK (cross-session). Returns a list of locators with status + summary, so you do not re-patch or miss an already-patched method.',
        'parameters': {'type': 'object', 'properties': <String, dynamic>{}},
      },
    });
  }
  if (assistant.localToolIds.contains(LocalToolNames.apkNoteWrite)) {
    tools.add(const {
      'type': 'function',
      'function': {
        'name': LocalToolNames.apkNoteWrite,
        'description':
            'Stage a modification locator on the current artifact without writing long-term memory. The staged note is committed only after record_apk_patch_verification receives the user-installed result.',
        'parameters': {
          'type': 'object',
          'properties': {
            'locator': {
              'type': 'string',
              'description': 'Modified method/entry locator',
            },
            'status': {
              'type': 'string',
              'description': 'e.g. patched / nop / forced_true',
            },
            'summary': {
              'type': 'string',
              'description': 'One-line summary of the change',
            },
          },
          'required': ['locator'],
        },
      },
    });
  }
  if (assistant.localToolIds.contains(LocalToolNames.apkListWorkspace)) {
    tools.add(const {
      'type': 'function',
      'function': {
        'name': LocalToolNames.apkListWorkspace,
        'description':
            'List APK files in the configured workspace directory (工作目录). Use to discover which APKs are available to analyze/patch without the user manually picking them.',
        'parameters': {'type': 'object', 'properties': <String, dynamic>{}},
      },
    });
  }
  if (assistant.localToolIds.contains(LocalToolNames.apkAnalyzeWorkspace)) {
    tools.add(const {
      'type': 'function',
      'function': {
        'name': LocalToolNames.apkAnalyzeWorkspace,
        'description':
            'Analyze an APK in the workspace — call it on demand, not as a forced first step. This tool is independently callable whenever a report is needed. signatureMode is optional: omitted uses the APK 工作台 default (去签名默认开启). Three modes, freely switchable: normal=普通去签, original_apk=原包去签, dpatch=DPatch 去签（生成独立去签产物）, skip=不去签. Map user wording like 第一/第二/第三/普通/原包/DPatch flexibly — ask or offer choices when unclear. Any tool may be called standalone; do not run a fixed full pipeline.',
        'parameters': {
          'type': 'object',
          'properties': {
            'fileName': {
              'type': 'string',
              'description':
                  'APK file name inside the workspace directory, e.g. 橘汁_3.0.2.3_会员解锁去广告_v3.apk',
            },
            'signatureMode': {
              'type': 'string',
              'enum': ['normal', 'original_apk', 'dpatch', 'skip'],
              'description':
                  'normal=普通去签, original_apk=原包去签, dpatch=DPatch 去签（生成独立去签产物）, skip=不去签。自由切换，按用户意图；省略用工作台默认。',
            },
          },
        },
      },
    });
  }
  if (assistant.localToolIds.contains(LocalToolNames.apkArchive)) {
    tools.add({
      'type': 'function',
      'function': {
        'name': LocalToolNames.apkArchive,
        'description':
            'Browse an APK without extracting it. action=list returns a paged flat entry list and can filter by query; action=read returns a bounded text or hex window for one exact entry; action=certificates verifies and returns signer subject, issuer, validity and fingerprints. All actions are read-only and use the current APK when path is omitted.',
        'parameters': {
          'type': 'object',
          'properties': {
            'path': {
              'type': 'string',
              'description':
                  'APK path, or a work-directory file name. Omit to use the current APK.',
            },
            'action': {
              'type': 'string',
              'enum': ['list', 'read', 'strings', 'certificates'],
              'description': 'list (default), read, strings, or certificates.',
            },
            'query': {
              'type': 'string',
              'description': 'Case-insensitive path filter for list.',
            },
            'entry': {
              'type': 'string',
              'description': 'Exact APK entry path, required for read.',
            },
            'offset': {
              'type': 'integer',
              'description':
                  'list: entry offset; read: byte offset. Both are zero-based.',
            },
            'limit': {
              'type': 'integer',
              'description':
                  'list: entries per page (max 500); read: bytes per window (max 65536).',
            },
            'minLen': {
              'type': 'integer',
              'description': 'Minimum string length for strings (default 4).',
            },
          },
        },
      },
    });
  }
  if (assistant.localToolIds.contains(LocalToolNames.apkExportReport)) {
    tools.add({
      'type': 'function',
      'function': {
        'name': LocalToolNames.apkExportReport,
        'description':
            'Save the current fresh APK analysis report as JSON in the workspace directory. It does not reanalyze or modify the APK.',
        'parameters': {
          'type': 'object',
          'properties': {
            'fileName': {
              'type': 'string',
              'description':
                  'Optional output .json file name only, without a directory. A unique name is generated when omitted.',
            },
          },
        },
      },
    });
  }
  // ===== 静态分析工具链（jadx/baksmali/APKEditor/DexKit）=====
  if (assistant.localToolIds.contains(LocalToolNames.jadxDecompile)) {
    tools.add(const {
      'type': 'function',
      'function': {
        'name': LocalToolNames.jadxDecompile,
        'description':
            'Decompile an APK/DEX/JAR to Java. For action=class, copy both className and dexName from class_outline: only that dex is extracted and loaded. Without dexName, a large APK may scan dex files one by one. Use action=list with a small limit only to discover names; action=save is for a confirmed export need and may be slow.',
        'parameters': {
          'type': 'object',
          'properties': {
            'path': {
              'type': 'string',
              'description':
                  'Absolute APK/DEX/JAR path, or file name resolved against the workspace directory.',
            },
            'action': {
              'type': 'string',
              'enum': ['save', 'class', 'list'],
              'description':
                  'save (default) exports all; class returns one class source; list returns class names.',
            },
            'className': {
              'type': 'string',
              'description':
                  'Full class name for action=class, e.g. com.example.Foo.',
            },
            'dexName': {
              'type': 'string',
              'description':
                  'Optional classesN.dex returned by class_outline for action=class. Use it verbatim to avoid scanning every dex in a large APK.',
            },
            'limit': {
              'type': 'integer',
              'description': 'Max class names for action=list (default 500).',
            },
            'offset': {
              'type': 'integer',
              'description':
                  'For action=list pagination: skip this many classes first (use nextOffset from the previous response to page through large APKs).',
            },
          },
        },
      },
    });
  }
  if (assistant.localToolIds.contains(LocalToolNames.apkSign)) {
    tools.add(const {
      'type': 'function',
      'function': {
        'name': LocalToolNames.apkSign,
        'description':
            'Sign the latest patch/rebuild output with v1/v2/v3 schemes. Pass the output path returned by the write tool, not the original source APK. The built-in key differs from the official signature, so an existing official app may need uninstalling before installation.',
        'parameters': {
          'type': 'object',
          'properties': {
            'path': {
              'type': 'string',
              'description': 'APK to sign (absolute path).',
            },
            'outputApk': {
              'type': 'string',
              'description': 'Output path (default <原名>_成品.apk).',
            },
            'minSdk': {
              'type': 'integer',
              'description': 'Min SDK (default 26).',
            },
          },
        },
      },
    });
  }
  if (assistant.localToolIds.contains(LocalToolNames.apkRebuild)) {
    tools.add(const {
      'type': 'function',
      'function': {
        'name': LocalToolNames.apkRebuild,
        'description':
            'Full APK decode/build/merge/refactor via APKEditor (pure Java). action=decode splits an APK into an editable dir (resources + optional smali); action=build recompiles that dir into a full APK; action=merge combines split bundles (xapk/apks/apkm) into one APK; action=refactor restores obfuscated resource names. Sign the output with apk_sign before installing.',
        'parameters': {
          'type': 'object',
          'properties': {
            'path': {
              'type': 'string',
              'description':
                  'Input: APK file (decode/merge/refactor) or decoded directory (build).',
            },
            'action': {
              'type': 'string',
              'enum': ['decode', 'build', 'merge', 'refactor'],
              'description': 'decode (default) | build | merge | refactor.',
            },
            'output': {
              'type': 'string',
              'description':
                  'Output path (default <workDir>/SoLab/output/apkeditor/).',
            },
            'type': {
              'type': 'string',
              'enum': ['json', 'xml', 'raw'],
              'description': 'Resource format (default json).',
            },
            'dex': {
              'type': 'boolean',
              'description':
                  'decode: true (default) keeps raw dex (fast, resource/manifest edits only); false decompiles dex→smali (minutes-long, only when editing smali code).',
            },
            'force': {
              'type': 'boolean',
              'description':
                  'build: overwrite existing output (default false).',
            },
            'fixTypeNames': {
              'type': 'boolean',
              'description': 'build: fix type names (default false).',
            },
            'cleanMeta': {
              'type': 'boolean',
              'description':
                  'merge/refactor: clean META-INF old signatures (default true).',
            },
          },
        },
      },
    });
  }
  if (assistant.localToolIds.contains(LocalToolNames.dexSearch)) {
    tools.add(const {
      'type': 'function',
      'function': {
        'name': LocalToolNames.dexSearch,
        'description':
            'DEX 自动定位、过滤和候选判断,可独立使用。默认 auto: 组合类名、方法名、字段名、字符串、数字常量、指令序列及被调方法; 严格交集无结果时自动拆分证据、交叉计分和排序,无需用户选择定位路径。候选仍须按返回的 nextActions 验证真实代码与调用关系。',
        'parameters': {
          'type': 'object',
          'properties': {
            'path': {
              'type': 'string',
              'description': 'APK or bare .dex file absolute path.',
            },
            'keyword': {
              'type': 'string',
              'description':
                  'String/name to search. Multi-string and feature actions accept up to 16 terms joined by |.',
            },
            'numbers': {
              'type': 'array',
              'items': {'type': 'number'},
              'description':
                  'Up to 16 integer or decimal constants. auto combines them with every supplied evidence type and relaxes only after a strict miss.',
            },
            'className': {
              'type': 'string',
              'description':
                  'Candidate declaring class name; auto treats it as one evidence dimension.',
            },
            'methodName': {
              'type': 'string',
              'description':
                  'Candidate method name; auto treats it as one evidence dimension.',
            },
            'fieldNames': {
              'type': 'array',
              'items': {'type': 'string'},
              'description':
                  'Fields read or written by a candidate. auto first requires every name in one method, then ranks partial cross-evidence matches.',
            },
            'invokedMethodNames': {
              'type': 'array',
              'items': {'type': 'string'},
              'description':
                  'Methods invoked by a candidate; used as call evidence by auto.',
            },
            'opNames': {
              'type': 'array',
              'items': {'type': 'string'},
              'description':
                  'Ordered DEX opcode-name subsequence, such as const-string|invoke-virtual|if-eq; used as code evidence by auto.',
            },
            'action': {
              'type': 'string',
              'enum': [
                'auto',
                'method_by_string',
                'class_by_string',
                'method_by_strings',
                'class_by_strings',
                'method_by_numbers',
                'method_by_features',
                'method_by_name',
                'class_by_name',
              ],
              'description':
                  'Search mode (default auto). Keep auto unless a caller explicitly needs one isolated query.',
            },
            'matchType': {
              'type': 'string',
              'enum': ['Contains', 'Equals', 'StartsWith', 'EndsWith'],
              'description': 'Match type (default Contains).',
            },
            'ignoreCase': {
              'type': 'boolean',
              'description': 'Case-insensitive match (default false).',
            },
            'packagePrefix': {
              'type': 'string',
              'description': 'Limit search to package prefix (faster).',
            },
            'limit': {
              'type': 'integer',
              'description': 'Max results (default 100).',
            },
          },
          'required': ['path'],
        },
      },
    });
  }
  if (assistant.localToolIds.contains(LocalToolNames.stringScan)) {
    tools.add(const {
      'type': 'function',
      'function': {
        'name': LocalToolNames.stringScan,
        'description':
            'Scan an APK/DEX/SO/any file for sensitive values only: URLs, IPs, emails, JWTs, private keys, cloud AK-SK, and suspected key/password values. APK hits include source entries in locations. It does not locate Java field or method names; use class_outline, dex_search, or dex_xref for code symbols.',
        'parameters': {
          'type': 'object',
          'properties': {
            'path': {'type': 'string', 'description': 'File absolute path.'},
            'category': {
              'type': 'string',
              'enum': [
                'all',
                'url',
                'ip',
                'email',
                'jwt',
                'private_key',
                'aws_ak',
                'google_api',
                'aliyun_ak',
                'secret_field',
              ],
              'description': 'Category filter (default all).',
            },
            'minLen': {
              'type': 'integer',
              'description': 'Min string length (default 5).',
            },
            'limit': {
              'type': 'integer',
              'description': 'Max hits per category (default 100).',
            },
            'includePrivate': {
              'type': 'boolean',
              'description':
                  'category=ip: also report private/LAN ranges (10.x/172.16-31.x/192.168.x). Loopback/zero/broadcast/link-local are always filtered out as noise.',
            },
          },
        },
      },
    });
  }
  if (assistant.localToolIds.contains(LocalToolNames.dexXref)) {
    tools.add(const {
      'type': 'function',
      'function': {
        'name': LocalToolNames.dexXref,
        'description':
            'DEX 调用处、调用流程和重写方法证据,可独立验证已有 locator。to/from/both 返回精确 callSites、callers/callees；overrides 按类层级和方法签名查找重写实现。includeGraph 返回有向 nodes/edges,可直接画流程图。结果 qualifiedId 可交给 smali_read；空直接调用不等于无反射或动态分派。',
        'parameters': {
          'type': 'object',
          'properties': {
            'target': {
              'type': 'string',
              'description':
                  'Method qualifiedId, or dex_field:Lpkg/Class;->field:Type for field readers/writers.',
            },
            'path': {
              'type': 'string',
              'description':
                  'APK path (absolute, or a work-dir file name). Optional — defaults to the current continuous-modification artifact / analyzed source APK.',
            },
            'direction': {
              'type': 'string',
              'enum': ['to', 'from', 'both', 'overrides'],
              'description':
                  'to=call sites/callers, from=callees, both=two-way flow, overrides=subclass/interface implementations.',
            },
            'classPrefix': {
              'type': 'string',
              'description':
                  'Filter callers by class name prefix (business package, e.g. Lcom/platovpn).',
            },
            'callerPrefix': {
              'type': 'string',
              'description': 'Alias of classPrefix.',
            },
            'offset': {
              'type': 'integer',
              'description':
                  'Pagination offset into directCallers / field refs (default 0). Every offset is reachable — totals stay in summary, paging never drops data.',
            },
            'limit': {
              'type': 'integer',
              'description':
                  'Max rows per page (default 50; field refs default 500). Page deeper with offset=nextCursor until truncated=false.',
            },
            'callSiteOffset': {
              'type': 'integer',
              'description':
                  'Pagination offset into callSites (default 0). Reaches every call site, not just the first window.',
            },
            'callSiteLimit': {
              'type': 'integer',
              'description':
                  'Max call sites per page (default 300). Follow callSitesNextCursor for the rest.',
            },
            'includeGraph': {
              'type': 'boolean',
              'description':
                  'Return a bounded directed nodes/edges graph for flowchart rendering (default false).',
            },
          },
          'required': ['target'],
        },
      },
    });
  }
  if (assistant.localToolIds.contains(LocalToolNames.classOutline)) {
    tools.add(const {
      'type': 'function',
      'function': {
        'name': LocalToolNames.classOutline,
        'description':
            '读取 DEX 类的方法、字段、签名和精确 locator。Dart/Flutter 类须传 runtime=dart 和当前 Blutter jobId，直接走 Blutter ASM 索引，不能用 DEX 扫描。不要按短方法名合并不同类；按 qualifiedId、返回类型、字段形态和调用关系判断。结果可任选 dex_xref、smali_read 或字段使用分析继续,不是固定前置步骤。',
        'parameters': {
          'type': 'object',
          'properties': {
            'path': {
              'type': 'string',
              'description': 'APK or bare .dex file absolute path.',
            },
            'className': {
              'type': 'string',
              'description':
                  'DEX: full class name (Lpkg/Class;) or short name/substring. Dart: class/path hint for Blutter ASM.',
            },
            'runtime': {
              'type': 'string',
              'enum': ['dex', 'dart'],
              'description':
                  'Default dex. Use dart only with a Blutter jobId; it queries the same native index used by so_analyze.',
            },
            'jobId': {
              'type': 'string',
              'description':
                  'Required only when runtime=dart: current APK Blutter jobId.',
            },
            'offset': {
              'type': 'integer',
              'description': 'Pagination offset (default 0).',
            },
            'limit': {
              'type': 'integer',
              'description': 'Max methods/fields (default 200).',
            },
          },
          'required': ['path', 'className'],
        },
      },
    });
  }
  if (assistant.localToolIds.contains(LocalToolNames.smaliRead)) {
    tools.add(const {
      'type': 'function',
      'function': {
        'name': LocalToolNames.smaliRead,
        'description':
            '读取一个精确方法的真实指令、分支、字段和返回语义。它是强行为证据,可直接验证用户或任意产物给出的 qualifiedId,不要求先跑搜索链。qualifiedId 必须原样传入；方法体已直接表达目标时可据此 dryRun,仍有多种解释时再选 xref、字段读写或常量作为独立证据。',
        'parameters': {
          'type': 'object',
          'properties': {
            'path': {
              'type': 'string',
              'description':
                  'APK absolute path, or a file name resolved against the work directory; defaults to the current artifact when omitted.',
            },
            'qualifiedId': {
              'type': 'string',
              'description':
                  'Method qualifiedId from dex_search, class_outline, or dex_xref results, e.g. Lcom/foo/Bar;->isVip()Z.',
            },
          },
          'required': ['qualifiedId'],
        },
      },
    });
  }
  if (assistant.localToolIds.contains(LocalToolNames.soPatchIntoApk)) {
    tools.add({
      'type': 'function',
      'function': {
        'name': LocalToolNames.soPatchIntoApk,
        'description':
            'One-stop: write a patched .so back into the target APK. Auto-senses the latest successful build and resolves the APK entry. For an exact write-back already authorized by the user, use dryRun=true plus applyAfterPreview=true; the resolved SO path and entry are bound to the preview and applied in the same call. Pure dryRun returns exact applyArguments. Pass sign=true to produce an installable signed APK.',
        'parameters': {
          'type': 'object',
          'properties': {
            'soPath': {
              'type': 'string',
              'description':
                  'Patched .so path (absolute or work-dir relative). Omit to use the latest so_analyze(build) output remembered in this session.',
            },
            'entryName': {
              'type': 'string',
              'description':
                  'Explicit target entry, e.g. lib/arm64-v8a/libapp.so. Omit for auto-resolution.',
            },
            'abi': {
              'type': 'string',
              'description':
                  'Target ABI when the so exists under multiple lib/<abi>/ trees, e.g. arm64-v8a.',
            },
            'sign': {
              'type': 'boolean',
              'description':
                  'Chain built-in signing (v1/v2/v3) after write-back; output signedPath is directly installable. Recommended true when this is the final step.',
            },
            ...apkPathParameter,
            'dryRun': {
              'type': 'boolean',
              'description': 'true = preview only. Always preview first.',
            },
            'applyAfterPreview': {
              'type': 'boolean',
              'description':
                  'For an already authorized exact write-back: preview and apply in one call, preserving the resolved SO path and APK entry.',
            },
            'confirm': {
              'type': 'boolean',
              'description': 'true = execute with the matching previewToken.',
            },
            'previewToken': {
              'type': 'string',
              'description': 'Token from the matching dryRun preview.',
            },
          },
          'required': ['dryRun'],
        },
      },
    });
  }
  if (assistant.localToolIds.contains(LocalToolNames.soAnalyze)) {
    tools.add(const {
      'type': 'function',
      'function': {
        'name': LocalToolNames.soAnalyze,
        'description':
            '本地 SO/Flutter 证据入口。open、overview、search、函数、引用、Blutter、反汇编和编辑均可按现有证据独立进入,无需补齐固定前置链。混淆时以文件身份、VA、对象池引用、常量、函数边界和调用位置为主,符号名为辅；不同视图先映射 VA 再比较。Blutter path 传 APK 或含 libapp.so+libflutter.so 的目录。强制返回优先 force_return_constant,手写补丁不得破坏栈帧；callers 为空只表示没有解析到直接调用。精确修改仍须 dryRun/applyAfterPreview。',
        'parameters': {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'description':
                  '动作按域分为工作区、读取、Rizin/LIEF、Blutter、编辑构建和模拟。完整 action 列表及参数先调 get_solab_tool_map(tool=so_analyze) 获取；常用起点为 open、overview、search、rz_functions、blutter、edit_open、build。',
            },
            'path': {
              'type': 'string',
              'description':
                  'SO/APK absolute path inside the work directory, or a work-dir file name (action=open/analyze_apk).',
            },
            'url': {
              'type': 'string',
              'description':
                  'http(s) URL of a .so/ELF to download into the work dir then open (action=open_url).',
            },
            'asm': {
              'type': 'string',
              'description': 'Assembly text to assemble (action=rz_asm).',
            },
            'va': {
              'type': 'string',
              'description':
                  'Hex virtual address, e.g. 0x1234 (edit_hex VA mode / lief_patch_address / lief_add_export / blutterAction=disasm: function or instruction VA from locate/xref, returns the full function body with inline [pp+0x...] object-pool annotations; limit param controls max lines, default 400, max 2000).',
            },
            'patchHex': {
              'type': 'string',
              'description':
                  "Hex bytes to write at va, spaces allowed, e.g. '20 00 80 52' (edit_hex VA mode / lief_patch_address).",
            },
            'name': {
              'type': 'string',
              'description':
                  'Symbol name (lief_add_export/lief_remove_symbol).',
            },
            'file': {
              'type': 'string',
              'description': 'Audit file path (action=audit_load).',
            },
            'workspaceIdB': {
              'type': 'string',
              'description':
                  'Workspace B for two-SO structural diff (action=rz_diff).',
            },
            'editSessionIdB': {
              'type': 'string',
              'description': 'Edit session B (action=rz_diff).',
            },
            'outputs': {
              'type': 'array',
              'description':
                  'Output variants for multi-build (action=build_many).',
            },
            'writeReport': {
              'type': 'boolean',
              'description':
                  'Write patch-report JSON sidecar (build/build_many).',
            },
            'writeToWorkDir': {
              'type': 'boolean',
              'description':
                  'Mirror build output into work directory (build/build_many).',
            },
            'workspaceId': {
              'type': 'string',
              'description':
                  'Returned by action=open; required for all other actions.',
            },
            'editSessionId': {
              'type': 'string',
              'description':
                  'Returned by action=edit_open; edit_asm 会在旧会话失效时恢复空会话并返回新的 editSessionId，后续调用使用返回值。',
            },
            'locator': {
              'type': 'string',
              'description':
                  'so_symbol:/so_function:/so_section: locator, a bare symbol/function name, or a hex VA (disasm/hexdump/rz_*/edit_*). rz_xrefs also accepts addr, target, or va as a locator alias; byteOffset/edits[i].byteOffset are relative to the resolved target start.',
            },
            'edits': {
              'type': 'array',
              'items': {'type': 'object'},
              'description':
                  "Patch list for edit_hex/edit_asm/edit_symbol. Each item MUST be a JSON object (not a string): edit_hex → {va, newHex} (preferred: absolute VA exactly as returned by disasm/xref/locate, no offset math) or {byteOffset, newHex} (relative to the resolved locator start — do NOT pass absolute fileOffset/VA here); edit_asm → {instructionIndex?, byteLength?, mode?, writeAsm} or {mode:'force_return_constant', value, returnType?, valueEncoding?}; returnType=bool requires numeric value 0 or 1, not a boolean literal. 单个 edit_asm 可把这些字段直接放在顶层而不传 edits. force_return_constant auto-generates a stack-safe stub. valueEncoding=auto detects libapp.so/Dart AOT: bool uses NULL_REG+0x20/0x30, null/object uses NULL_REG, int uses Smi; use valueEncoding=native only for native ABI values. Dart strings require a located pool object and are rejected here. never hand-write prologue/epilogue rewrites, the engine rejects stack-imbalanced patches with STACK_IMBALANCE unless overrideStackCheck:true; edit_symbol → {op:'rename', newName}. Values as returned by the matching dryRun preview. For edit_hex you may instead pass va+patchHex (session-tracked VA patching with dryRun/undo) — see va/patchHex.",
            },
            'mode': {
              'type': 'string',
              'description':
                  "Single edit_asm shortcut, e.g. force_return_constant, nop_out, or replace_instructions.",
            },
            'value': {
              'type': 'integer',
              'description':
                  'Single edit_asm force_return_constant value. For returnType=bool use numeric 0 or 1. blutterAction=values also accepts one numeric value here as a shorthand for query.',
            },
            'returnType': {
              'type': 'string',
              'description':
                  'Single edit_asm constant type: int, enum, bool, null, object, or reference.',
            },
            'valueEncoding': {
              'type': 'string',
              'enum': ['auto', 'native', 'dart_aot'],
              'description':
                  'Single edit_asm constant encoding; auto selects from the target.',
            },
            'writeAsm': {
              'type': 'string',
              'description': 'Single edit_asm assembly text.',
            },
            'dryRun': {
              'type': 'boolean',
              'description':
                  'Mutating actions: true=preview only (default); false=apply after user approval.',
            },
            'applyAfterPreview': {
              'type': 'boolean',
              'description':
                  'For edit_hex/edit_asm/edit_symbol only. If the user already authorized the exact edit, set true with dryRun=true; the tool previews then immediately applies the same edit with the returned targetVersion.',
            },
            'targetVersion': {
              'type': 'string',
              'description':
                  'Version guard for edit_hex/edit_asm/edit_symbol with dryRun=false: pass the targetVersion returned by the dryRun preview; if the session changed since the preview, the engine rejects with VERSION_DRIFT and you must re-run the preview. Responses return newTargetVersion for chaining.',
            },
            'vaEnd': {
              'type': 'string',
              'description':
                  'so_analyze(action=disasm) exclusive upper VA bound; window stops before it. Alternative to limit when isolating a branch region. Also accepts byteOffset+bytes relative to function start.',
            },
            'includePseudocode': {
              'type': 'boolean',
              'description':
                  'so_analyze(action=disasm) only. Default false for fast raw disassembly. Set true only when the current window needs Rizin pseudocode; use rz_decompile when pseudocode itself is the goal.',
            },
            'byteOffset': {
              'type': 'integer',
              'description':
                  'disasm byte offset from the function start VA; combined with bytes builds vaEnd automatically (arm64: 4 bytes per instruction).',
            },
            'bytes': {
              'type': 'integer',
              'description':
                  'Byte span to include after byteOffset in disasm windows.',
            },
            'consumerExclude': {
              'type': 'array',
              'items': {'type': 'string'},
              'description':
                  'blutterAction=trace only. Substrings matched case-insensitively against consumer function/class/file to drop noisy third-party hits (e.g. pointycastle, rc2). Response also returns consumerClusters (per-directory counts) for choosing patterns.',
            },
            'compareToJobId': {
              'type': 'string',
              'description':
                  "blutterAction=diff only: jobId of the NEW package's analyze result to match against the current one.",
            },
            'classPrefix': {
              'type': 'string',
              'description':
                  'diff filter substring for old-side class/file/name; empty maps everything within limit.',
            },
            'minSimilarity': {
              'type': 'number',
              'description':
                  'diff anchor-set Jaccard threshold (default 0.45). Anchors are pooled-string references, rename-immune; re-disasm rows below ~0.8 before patching.',
            },
            'overrideAotObjectSafety': {
              'type': 'boolean',
              'description':
                  'Default false. Only set true when current disassembly proves the target uses a native scalar ABI rather than a Dart object/Smi. Raw MOV-immediate edits in Flutter/Dart AOT are otherwise previewed but blocked from apply.',
            },
            'limit': {
              'type': 'integer',
              'description': 'Max rows for list/read functions (default 100).',
            },
            'offset': {
              'type': 'integer',
              'description':
                  'Pagination offset (disasm instructionOffset / lists).',
            },
            'cursor': {
              'type': 'string',
              'description':
                  'Pagination cursor returned by the previous page (rz_functions/list/strings).',
            },
            'view': {
              'type': 'string',
              'description':
                  'action=list view: sections | symbols | relocs (default sections).',
            },
            'prefix': {
              'type': 'string',
              'description': 'Name prefix filter (list_sources/list/strings).',
            },
            'query': {
              'type': 'string',
              'description':
                  'Search query. Blutter search accepts up to 16 related terms joined with | and scans them together, e.g. isVip|isMember|vipLevel. Never issue one full scan per synonym. Blutter numeric evidence: blutterAction=values with comma/slash-separated decimal or hex values, e.g. 5,55 or 0x5/0x37.',
            },
            'target': {
              'type': 'string',
              'description': 'Search target (action=search, default overview).',
            },
            'pattern': {
              'type': 'string',
              'description':
                  "Rizin byte pattern for rz_search_bytes: compact hex such as 5F2403D5, nibble wildcard using '.' such as 5F24..D5, optional bytes:mask; spaced hex and '??' are normalized for compatibility.",
            },
            'fromVa': {
              'type': 'string',
              'description':
                  'Hex start VA (rz_search_bytes, blank/0 = from beginning).',
            },
            'toVa': {
              'type': 'string',
              'description': 'Hex end VA (rz_search_bytes, blank/0 = to end).',
            },
            'direction': {
              'type': 'string',
              'description': 'to | from (rz_xrefs, default to).',
            },
            'command': {
              'type': 'string',
              'description':
                  'Raw rizin command (rz_command, unsafe=true required for dangerous ones).',
            },
            'unsafe': {
              'type': 'boolean',
              'description': 'Allow dangerous rizin commands (default false).',
            },
            'op': {
              'type': 'string',
              'description':
                  'Backend dispatch op. unidbg_dispatch: status | session_open(editSessionId,callJniOnLoad) | session_list | session_close | session_call | session_call_address | session_dump | session_modules | session_exports | session_registers | session_memory_maps | session_memory_write/map/protect/unmap | session_trace_code/start/events/stop/clear | session_hook_start/list/stop | session_breakpoint_add/remove | session_single_step | session_emu_stop | debugger_plan | trace_plan | breakpoints_plan | framework_matrix | stub/hook/env_template. lief_dispatch: roots | methods | parse_any | validate | get | list | set | call. xanso_dispatch: status | help | capabilities. args[] carries each op positional arguments (e.g. session_call → [emulatorSessionId, symbolName, argsArray, trace]).',
            },
            'method': {
              'type': 'string',
              'description': 'Backend method (lief_dispatch/unidbg_dispatch).',
            },
            'args': {
              'type': 'array',
              'description': 'Backend/emulate call arguments (JSON array).',
            },
            'symbolName': {
              'type': 'string',
              'description':
                  'Function to emulate (emulate; JNI_OnLoad/Java_* supported).',
            },
            'trace': {
              'type': 'boolean',
              'description': 'Emulate with instruction trace (default false).',
            },
            'blutterAction': {
              'type': 'string',
              'enum': [
                'analyze',
                'inspect',
                'status',
                'result',
                'cancel',
                'packages',
                'search',
                'raw_strings',
                'values',
                'xref',
                'trace',
                'locate',
                'report',
                'callers',
                'diff',
                'disasm',
                'prune',
              ],
              'description':
                  'Blutter 独立证据动作。已有 jobId、池偏移、函数 VA、数值或专项报告时可直接调用 report、search、xref、trace、values、disasm、callers,无需重放 locate。result 读取 result.json 缓存视图,未就绪返回 REPORT_NOT_READY。trace 从任意字段键推导写入和同偏移读取,再用 24 指令寄存器切片证明字段是否流入比较、分支、布尔结果、返回或调用参数；优先 high confidence,low 不能作为结论。Blutter disasm 只用于定位,补丁验收必须读取当前文件真实字节。',
            },
            'jobId': {
              'type': 'string',
              'description':
                  'Blutter job id from a previous analyze (status/result/cancel/search/values/xref/locate; optional for search/values/xref/locate = latest succeeded).',
            },
            'wait': {
              'type': 'boolean',
              'description':
                  'action=blutter only. analyze always returns its background jobId immediately even when wait=true. status+wait=true returns on completion, failure, stage change, or a new heartbeat. Report progress before continuing with the same jobId.',
            },
            'timeoutMs': {
              'type': 'integer',
              'description':
                  'Maximum wait for one progress response, default 90000ms, clamped to 5000-90000. Calls normally return within one heartbeat instead of staying silent until completion. On timeout, reuse the same jobId with wait=true.',
            },
            'goal': {
              'type': 'string',
              'description':
                  'blutterAction=locate/values/trace user goal. 用户给出的文件名和数值只作为证据提示；locate/trace 会从真实字段写入和读取关系建立数据流,不会把示例名称或数值写成固定规则。Blutter 函数体缺失时 locate 的 rawDecisionFlow 会直接读取当前 libapp 字节,连接文案分支值、调用链与返回值阶梯。values 同时检查原始整数、Dart Smi 编码和对象池整数引用,但排除内存寻址偏移。',
            },
            'deep': {
              'type': 'boolean',
              'description':
                  'blutterAction=locate only. Default false always uses compact XREF + candidate-window verification and never starts a full semantic/value/field scan. Set true only when the fast result lacks enough evidence and a complete field-flow trace is explicitly needed.',
            },
            'poolOffset': {
              'type': 'string',
              'description':
                  'Hex object-pool offset(s) from blutterAction=search. Multiple offsets may be comma-separated and are resolved in one pass. Use xref for direct references or trace for key→field write→field readers. callers also accepts it to resolve Dart closure blr indirect calls when pp.txt does not expose the target Code VA.',
            },
            'scope': {
              'type': 'string',
              'description':
                  'blutterAction=search scope: pp (default) | asm | all.',
            },
            'fullScan': {
              'type': 'boolean',
              'description':
                  'blutterAction=search with scope=asm/all only. Default false searches the compact semantic index. Use true only after an indexed search returns no match and raw non-semantic lines are genuinely required; combine related terms with | in one call.',
            },
            'includePath': {
              'type': 'string',
              'description':
                  'Blutter ASM search path/class include filter. Separate alternatives with |, for example DiaryState|package:my_app/. Apply this before a full scan to avoid third-party noise.',
            },
            'excludePath': {
              'type': 'string',
              'description':
                  'Blutter ASM search path/class exclude filter. Separate terms with |, for example archive|dio|extended_image.',
            },
            'includeThirdParty': {
              'type': 'boolean',
              'description':
                  'Blutter fullScan only. Default false skips common Dart/Flutter dependency folders for speed and signal quality. Set true only when the target is known to be inside a dependency.',
            },
            'kind': {
              'type': 'string',
              'enum': ['libraries', 'classes', 'functions', 'objects'],
              'description':
                  'Reference preview kind for blutterAction=result only. Never exhaust classes/functions/objects pages for analysis; use locate/search/xref/disasm. pp.txt is not a result kind.',
            },
            'report': {
              'type': 'string',
              'enum': ['membership', 'capture', 'ads'],
              'description':
                  'blutterAction=report only. Read the latest saved focused report without rerunning analysis.',
            },
            'includeEvidence': {
              'type': 'boolean',
              'description':
                  'blutterAction=locate only. Default false. Return large PP context and class outline only when a specific evidence dispute requires them; never enable for the first pass.',
            },
            'fullInventory': {
              'type': 'boolean',
              'description':
                  'blutterAction=result/packages only. For result, allow complete artifact inventory paging only when explicitly exporting. For packages, include one paged slice of the historical coverage matrix; the default compact response already includes runner health and coverage totals.',
            },
            'olderThanMillis': {
              'type': 'integer',
              'description':
                  'blutterAction=prune only. Age threshold in milliseconds, default 7 days. The default dryRun=true returns reclaimable job/result counts and bytes without deleting anything.',
            },
            'abi': {
              'type': 'string',
              'description': 'Target ABI (blutter, default auto).',
            },
            'addr': {
              'type': 'string',
              'description':
                  'Hex address (rz_asm / disasm / emulate_dump / blutterAction=callers). For emulate_dump this is the Unidbg RUNTIME absolute address: add the module base from unidbg_dispatch(op=session_modules) to the ELF VA, not the raw ELF VA. For callers: target function VA; it returns bl/b direct sites and matching pool-backed blr closure sites.',
            },
            'size': {
              'type': 'integer',
              'description': 'Byte size (emulate_dump default 256).',
            },
            'maxBytes': {
              'type': 'integer',
              'description':
                  'Max bytes to read (hexdump default 512 / disasm 4096).',
            },
            'label': {
              'type': 'string',
              'description': 'Snapshot label (edit_snapshot).',
            },
            'snapshotIndex': {
              'type': 'integer',
              'description':
                  'Snapshot to roll back to (edit_rollback, -1=latest).',
            },
            'snapshotId': {
              'type': 'string',
              'description':
                  'Stable snapshot id returned by edit_snapshot or audit; preferred over snapshotIndex for edit_rollback.',
            },
            'compareWorkspaceId': {
              'type': 'string',
              'description': 'Other workspace for action=diff (optional).',
            },
            'compareSessionId': {
              'type': 'string',
              'description': 'Other edit session for action=diff (optional).',
            },
            'count': {
              'type': 'integer',
              'description':
                  'Undo/redo step count (edit_undo/edit_redo, default 1).',
            },
            'outputName': {
              'type': 'string',
              'description':
                  'Output file name (action=build, default patched.so).',
            },
            'conflictStrategy': {
              'type': 'string',
              'description': 'Build output conflict strategy (default rename).',
            },
            'force': {
              'type': 'boolean',
              'description':
                  'xanso_build_sections: rebuild even when a parseable section table already exists (default false).',
            },
            'strict': {
              'type': 'boolean',
              'description':
                  'rz_decompile: fail when rizin-ghidra pseudocode is unavailable instead of falling back to plain disassembly (default true).',
            },
            'ignoreCase': {
              'type': 'boolean',
              'description':
                  'strings: case-insensitive prefix/regex matching (default true).',
            },
            'minConfidence': {
              'type': 'number',
              'description':
                  'strings: minimum string confidence in [0,1]; raise to drop noisy UTF-16 candidates.',
            },
          },
        },
      },
    });
  }
  if (assistant.localToolIds.contains(LocalToolNames.file)) {
    tools.add(const {
      'type': 'function',
      'function': {
        'name': LocalToolNames.file,
        'description':
            'Unified file operations in the work directory. Call action=inventory to get this conversation\'s live work directory (its root entries include ALL files physically present there — user-added notes like .md, logs, builds — not just tracked artifacts), report source, active APK, SO output and artifact paths without searching. Every entry is stat-checked, so deleted outputs are marked missing. To read any listed file use action=read with its path; use list for subdirectories. Blutter pp.txt, JSONL and asm dumps are reference artifacts: grep a target or use so_analyze locate/search/xref/disasm; never read them page by page. Paths must be INSIDE the work directory; bare names are resolved against it.',
        'parameters': {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'enum': [
                'inventory',
                'read',
                'write',
                'list',
                'info',
                'delete',
                'copy',
                'diff',
                'mkdir',
                'rename',
                'zip',
                'unzip',
                'grep',
                'replace',
                'strings',
              ],
              'description':
                  'inventory returns the live per-conversation artifact ledger; otherwise performs the selected file operation.',
            },
            'path': {
              'type': 'string',
              'description':
                  'Target path (file or directory) in the work directory. When it points to an APK/ZIP file, action=list returns the archive entry listing (name/size/compressedSize/modified) instead of a directory listing.',
            },
            'entryPrefix': {
              'type': 'string',
              'description':
                  'Optional name-prefix filter for action=list on APK/ZIP archives (e.g. dex/, res/, lib/arm64-v8a/).',
            },
            'sourcePath': {
              'type': 'string',
              'description': 'Source path for copy/rename/diff.',
            },
            'targetPath': {
              'type': 'string',
              'description': 'Target path for copy/rename/diff.',
            },
            'context': {
              'type': 'integer',
              'description':
                  'Context lines around changes for diff (default 3, max 16).',
            },
            'content': {'type': 'string', 'description': 'Content for write.'},
            'pattern': {
              'type': 'string',
              'description': 'Regex pattern for grep/replace.',
            },
            'query': {
              'type': 'string',
              'description':
                  'Optional case-insensitive filter for action=strings.',
            },
            'encoding': {
              'type': 'string',
              'enum': ['auto', 'utf8', 'utf16le', 'utf16be'],
              'description':
                  'Binary string encoding for action=strings (default auto).',
            },
            'minLength': {
              'type': 'integer',
              'description':
                  'Minimum extracted string length for action=strings (default 3).',
            },
            'find': {
              'type': 'string',
              'description': 'Text to find for replace.',
            },
            'replacement': {
              'type': 'string',
              'description': 'Replacement text for replace.',
            },
            'offset': {
              'type': 'integer',
              'description':
                  'Text: 0-based start line. Binary: start byte offset. APK/ZIP list: entry offset (default 0, every offset reachable).',
            },
            'limit': {
              'type': 'integer',
              'description':
                  'Text: max lines. Binary: max bytes. List: max entries (directory default 200, archive default 200).',
            },
            'dryRun': {
              'type': 'boolean',
              'description':
                  'true to preview write/delete/copy/rename/zip/replace (default true).',
            },
            'recursive': {
              'type': 'boolean',
              'description': 'Recursive for delete.',
            },
            'overwrite': {
              'type': 'boolean',
              'description': 'Overwrite target for copy/rename.',
            },
            'output': {
              'type': 'string',
              'description': 'Output zip path for zip.',
            },
          },
          'required': ['action'],
        },
      },
    });
  }
  if (assistant.localToolIds.contains(LocalToolNames.routeTask)) {
    tools.add(const {
      'type': 'function',
      'function': {
        'name': LocalToolNames.routeTask,
        'description':
            '证据路线建议器,不是流程执行器。它按目标给出可独立使用的 DEX、Flutter、Native、资源和产物探针,以及冲突裁决规则；recommended/preferred tools 都是候选而非必经步骤。已有精确 locator 时可跳过 route_task 直接验证。调用后由证据区分力自由选择下一工具,不要机械照顺序执行。',
        'parameters': {
          'type': 'object',
          'properties': {
            'goal': {
              'type': 'string',
              'description': 'The user request in their own words.',
            },
          },
          'required': ['goal'],
        },
      },
    });
  }
  // SO 全域工具归口 so_analyze（40+ action）；外部原名别名已下线（U11）
  return tools
      .where(
        (tool) => registeredToolIds.contains(
          (tool['function'] as Map)['name'].toString(),
        ),
      )
      .toList(growable: false);
}
