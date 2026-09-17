part of 'assistant_settings_edit_page.dart';

class _LocalToolsTab extends StatelessWidget {
  const _LocalToolsTab({required this.assistantId});
  final String assistantId;

  @override
  Widget build(BuildContext context) {
    final ap = context.watch<AssistantProvider>();
    final assistant = ap.getById(assistantId)!;
    final timeEnabled = assistant.localToolIds.contains(
      LocalToolNames.timeInfo,
    );
    final clipboardEnabled = assistant.localToolIds.contains(
      LocalToolNames.clipboard,
    );
    final textToSpeechEnabled = assistant.localToolIds.contains(
      LocalToolNames.textToSpeech,
    );
    final askUserEnabled = assistant.localToolIds.contains(
      LocalToolNames.askUser,
    );
    final calculateEnabled = assistant.localToolIds.contains(
      LocalToolNames.calculate,
    );
    final screenTimeEnabled = assistant.localToolIds.contains(
      LocalToolNames.screenTime,
    );
    final calendarQueryEnabled = assistant.localToolIds.contains(
      LocalToolNames.calendarQuery,
    );
    final calendarCreateEnabled = assistant.localToolIds.contains(
      LocalToolNames.calendarCreate,
    );

    final l10n = AppLocalizations.of(context)!;

    Future<void> updateTool(String toolId, bool value) {
      final ids = assistant.localToolIds.toSet();
      if (value) {
        ids.add(toolId);
      } else {
        ids.remove(toolId);
      }
      return context.read<AssistantProvider>().updateAssistant(
        assistant.copyWith(localToolIds: ids.toList(growable: false)),
      );
    }

    Future<void> toggleTool(String toolId, bool value) async {
      if (!value) {
        await updateTool(toolId, false);
        return;
      }

      if (toolId == LocalToolNames.screenTime &&
          DeviceLocalTools.screenTimeSupported) {
        final granted = await DeviceLocalTools.hasUsageStatsPermission();
        if (!granted) {
          if (context.mounted) {
            showAppSnackBar(
              context,
              message: l10n.chatMessageWidgetScreenTimePermissionRequired,
              type: NotificationType.warning,
            );
          }
          await DeviceLocalTools.openUsageAccessSettings();
        }
        // Still enable even if Usage Access is not granted yet.
        await updateTool(toolId, true);
        return;
      }

      if ((toolId == LocalToolNames.calendarQuery ||
              toolId == LocalToolNames.calendarCreate) &&
          DeviceLocalTools.calendarSupported) {
        final granted = await DeviceLocalTools.hasCalendarPermission();
        if (!granted) {
          final requested = await DeviceLocalTools.requestCalendarPermission();
          if (!requested) {
            // Do not enable until the user grants calendar access.
            return;
          }
        }
        await updateTool(toolId, true);
        return;
      }

      await updateTool(toolId, true);
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      children: [
        _iosSectionCard(
          children: [
            _LocalToolRow(
              icon: Lucide.clock,
              title: l10n.assistantEditLocalToolTimeInfoTitle,
              subtitle: l10n.assistantEditLocalToolTimeInfoSubtitle,
              enabled: timeEnabled,
              onChanged: (value) => toggleTool(LocalToolNames.timeInfo, value),
            ),
            _iosDivider(context),
            _LocalToolRow(
              icon: Lucide.Clipboard,
              title: l10n.assistantEditLocalToolClipboardTitle,
              subtitle: l10n.assistantEditLocalToolClipboardSubtitle,
              enabled: clipboardEnabled,
              onChanged: (value) => toggleTool(LocalToolNames.clipboard, value),
            ),
            _iosDivider(context),
            _LocalToolRow(
              icon: Lucide.Volume2,
              title: l10n.assistantEditLocalToolTextToSpeechTitle,
              subtitle: l10n.assistantEditLocalToolTextToSpeechSubtitle,
              enabled: textToSpeechEnabled,
              onChanged: (value) =>
                  toggleTool(LocalToolNames.textToSpeech, value),
            ),
            _iosDivider(context),
            _LocalToolRow(
              icon: Lucide.MessageCircleQuestionMark,
              title: l10n.assistantEditLocalToolAskUserTitle,
              subtitle: l10n.assistantEditLocalToolAskUserSubtitle,
              enabled: askUserEnabled,
              onChanged: (value) => toggleTool(LocalToolNames.askUser, value),
            ),
            _iosDivider(context),
            _LocalToolRow(
              icon: Lucide.Calculator,
              title: l10n.assistantEditLocalToolCalculateTitle,
              subtitle: l10n.assistantEditLocalToolCalculateSubtitle,
              enabled: calculateEnabled,
              onChanged: (value) => toggleTool(LocalToolNames.calculate, value),
            ),
            if (DeviceLocalTools.screenTimeSupported) ...[
              _iosDivider(context),
              _LocalToolRow(
                icon: Lucide.Smartphone,
                title: l10n.assistantEditLocalToolScreenTimeTitle,
                subtitle: l10n.assistantEditLocalToolScreenTimeSubtitle,
                enabled: screenTimeEnabled,
                onChanged: (value) =>
                    toggleTool(LocalToolNames.screenTime, value),
              ),
            ],
            if (DeviceLocalTools.calendarSupported) ...[
              _iosDivider(context),
              _LocalToolRow(
                icon: Lucide.Calendar,
                title: l10n.assistantEditLocalToolCalendarQueryTitle,
                subtitle: l10n.assistantEditLocalToolCalendarQuerySubtitle,
                enabled: calendarQueryEnabled,
                onChanged: (value) =>
                    toggleTool(LocalToolNames.calendarQuery, value),
              ),
              _iosDivider(context),
              _LocalToolRow(
                icon: Lucide.CalendarPlus,
                title: l10n.assistantEditLocalToolCalendarCreateTitle,
                subtitle: l10n.assistantEditLocalToolCalendarCreateSubtitle,
                enabled: calendarCreateEnabled,
                onChanged: (value) =>
                    toggleTool(LocalToolNames.calendarCreate, value),
              ),
            ],
            // SoLab APK 本地工具（本地二改）：上游基础工具之外的扩展开关。
            for (final entry in kLocalToolUiMetadata.entries)
              if (!const [
                LocalToolNames.timeInfo,
                LocalToolNames.clipboard,
                LocalToolNames.textToSpeech,
                LocalToolNames.askUser,
                LocalToolNames.calculate,
                LocalToolNames.screenTime,
                LocalToolNames.calendarQuery,
                LocalToolNames.calendarCreate,
              ].contains(entry.key)) ...[
                _iosDivider(context),
                _LocalToolRow(
                  icon: _iconForTool(entry.key),
                  title: entry.value.title,
                  subtitle: entry.value.subtitle,
                  enabled: assistant.localToolIds.contains(entry.key),
                  onChanged: (value) => updateTool(entry.key, value),
                ),
              ],
          ],
        ),
      ],
    );
  }

  IconData _iconForTool(String toolId) {
    switch (toolId) {
      case LocalToolNames.timeInfo:
        return Lucide.clock;
      case LocalToolNames.clipboard:
        return Lucide.Clipboard;
      case LocalToolNames.textToSpeech:
        return Lucide.Volume2;
      case LocalToolNames.askUser:
        return Lucide.MessageCircleQuestionMark;
      case LocalToolNames.calculate:
        return Lucide.Calculator;
      case LocalToolNames.apkReport:
        return Lucide.FileText;
      case LocalToolNames.apkSkill:
      case LocalToolNames.apkKnowledge:
        return Lucide.BookOpen;
      case LocalToolNames.installedSkills:
        return Lucide.Sparkles;
      case LocalToolNames.agentRuntimeGuide:
        return Lucide.ListOrdered;
      case LocalToolNames.apkProjectInfo:
      case LocalToolNames.apkRecordPatchVerification:
        return Lucide.Shield;
      case LocalToolNames.apkRules:
        return Lucide.Database;
      case LocalToolNames.apkPatchDex:
      case LocalToolNames.apkPatchManifest:
        return Lucide.Wrench;
      case LocalToolNames.apkAnalyzeWorkspace:
        return Lucide.Search;
      case LocalToolNames.apkToolMap:
        return Lucide.ListOrdered;
      case LocalToolNames.dexXref:
        return Lucide.Link2;
      case LocalToolNames.apkPatchMemory:
      case LocalToolNames.apkSavePatchMemory:
        return Lucide.History;
      case LocalToolNames.apkNoteRead:
      case LocalToolNames.apkNoteWrite:
        return Lucide.NotebookTabs;
      case LocalToolNames.apkListWorkspace:
        return Lucide.Folder;
      case LocalToolNames.apkListBuilds:
        return Lucide.FolderOpen;
      case LocalToolNames.jadxDecompile:
      case LocalToolNames.apkRebuild:
        return Lucide.FileCode2;
      case LocalToolNames.apkSign:
        return Lucide.PenLine;
      case LocalToolNames.dexSearch:
      case LocalToolNames.stringScan:
        return Lucide.ScanSearch;
      case LocalToolNames.classOutline:
        return Lucide.ListTree;
      case LocalToolNames.smaliRead:
        return Lucide.FileText;
      case LocalToolNames.soAnalyze:
        return Lucide.Cpu;
      case LocalToolNames.file:
        return Lucide.Files;
      case LocalToolNames.routeTask:
        return Lucide.Workflow;
      default:
        return Lucide.Wrench;
    }
  }
}

class _LocalToolRow extends StatelessWidget {
  const _LocalToolRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.enabled,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return _TactileRow(
      onTap: () => onChanged(!enabled),
      builder: (pressed) {
        final baseColor = cs.onSurface.withValues(alpha: 0.9);
        return _AnimatedPressColor(
          pressed: pressed,
          base: baseColor,
          builder: (color) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 36,
                    child: Icon(
                      icon,
                      size: 20,
                      color: enabled ? cs.primary : color,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            color: color,
                            fontWeight: AppFontWeights.semibold,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          subtitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.25,
                            color: cs.onSurface.withValues(alpha: 0.62),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  IosSwitch(value: enabled, onChanged: onChanged),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
