import 'package:flutter/material.dart';

import '../../icons/lucide_adapter.dart';
import '../../theme/app_font_weights.dart';
import '../../theme/app_semantic_colors.dart';
import 'ios_tactile.dart';

class SettingsSectionCard extends StatelessWidget {
  const SettingsSectionCard({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: context.appColors.surfaceCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: cs.outlineVariant.withValues(
            alpha: theme.brightness == Brightness.dark ? 0.08 : 0.06,
          ),
          width: 0.6,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(children: children),
      ),
    );
  }
}

Widget settingsSectionDivider(BuildContext context) {
  final cs = Theme.of(context).colorScheme;
  return Divider(
    height: 6,
    thickness: 0.6,
    indent: 54,
    endIndent: 12,
    color: cs.outlineVariant.withValues(alpha: 0.18),
  );
}

class SettingsActionRow extends StatelessWidget {
  const SettingsActionRow({
    super.key,
    required this.icon,
    required this.label,
    this.detailText,
    this.trailing,
    this.enabled = true,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String? detailText;
  final Widget? trailing;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final opacity = enabled ? 1.0 : 0.55;
    final color = cs.onSurface.withValues(alpha: 0.9 * opacity);
    return IosCardPress(
      baseColor: Colors.transparent,
      borderRadius: BorderRadius.zero,
      pressedBlendStrength: 0,
      pressedScale: 1,
      haptics: onTap != null,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        child: Row(
          children: [
            SizedBox(width: 36, child: Icon(icon, size: 20, color: color)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: AppFontWeights.medium,
                      color: color,
                    ),
                  ),
                  if (detailText?.isNotEmpty == true) ...[
                    const SizedBox(height: 2),
                    Text(
                      detailText!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: cs.onSurface.withValues(alpha: 0.6 * opacity),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null)
              trailing!
            else if (onTap != null)
              Icon(Lucide.ChevronRight, size: 16, color: color),
          ],
        ),
      ),
    );
  }
}
