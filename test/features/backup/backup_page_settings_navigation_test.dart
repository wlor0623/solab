import '../../support/business_test_harness.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:solab/core/database/business_preferences.dart';
import 'package:solab/core/database/business_repository.dart';
import 'package:solab/core/providers/backup_reminder_provider.dart';
import 'package:solab/core/providers/settings_provider.dart';
import 'package:solab/core/services/chat/chat_service.dart';
import 'package:solab/features/backup/pages/backup_page.dart';
import 'package:solab/l10n/app_localizations.dart';

Future<BackupReminderProvider> _createReminderProvider(
  BusinessPreferences preferences,
) async {
  final provider = BackupReminderProvider(
    preferences: preferences,
    autoLoad: false,
  );
  await provider.load(startTimer: false);
  return provider;
}

Widget _buildHarness({
  required SettingsProvider settings,
  required BackupReminderProvider reminder,
  required BusinessRepository businessRepository,
  required BusinessPreferences businessPreferences,
}) {
  return MultiProvider(
    providers: [
      Provider<BusinessRepository>.value(value: businessRepository),
      Provider<BusinessPreferences>.value(value: businessPreferences),
      ChangeNotifierProvider<SettingsProvider>.value(value: settings),
      ChangeNotifierProvider<ChatService>(create: (_) => ChatService()),
      ChangeNotifierProvider<BackupReminderProvider>.value(value: reminder),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const BackupPage(),
    ),
  );
}

Future<void> _pumpBackupPage(
  WidgetTester tester, {
  required SettingsProvider settings,
  required BusinessTestHarness business,
}) async {
  final reminder = await _createReminderProvider(business.preferences);

  await tester.pumpWidget(
    _buildHarness(
      settings: settings,
      reminder: reminder,
      businessRepository: business.repository,
      businessPreferences: business.preferences,
    ),
  );
  await tester.pump();
}

Future<void> _openSettingsPage(WidgetTester tester, String label) async {
  final target = find.text(label);
  await tester.scrollUntilVisible(
    target,
    120,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void _expectAbove(WidgetTester tester, String upper, String lower) {
  final upperTop = tester.getTopLeft(find.text(upper).first).dy;
  final lowerTop = tester.getTopLeft(find.text(lower).first).dy;

  expect(upperTop, lessThan(lowerTop));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BackupPage mobile backup settings navigation', () {
    testWidgets('opens WebDAV settings as a full page and saves config', (
      tester,
    ) async {
      final business = await createBusinessTestHarness();
      final settings = SettingsProvider(business.preferences);
      await settings.loaded;

      await _pumpBackupPage(tester, settings: settings, business: business);

      await _openSettingsPage(tester, 'WebDAV Server Settings');

      expect(find.byType(BottomSheet), findsNothing);
      expect(find.widgetWithText(AppBar, 'WebDAV Server Settings'), findsOne);
      expect(find.text('WebDAV Server URL'), findsOneWidget);
      expect(find.text('User-Agent'), findsOneWidget);

      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), ' https://dav.example.com/root ');
      await tester.enterText(fields.at(4), ' KelivoTest/1.0 ');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(AppBar, 'WebDAV Server Settings'),
        findsNothing,
      );
      expect(settings.webDavConfig.url, 'https://dav.example.com/root');
      expect(settings.webDavConfig.userAgent, 'KelivoTest/1.0');
    });

    testWidgets('shows local backup before WebDAV and S3 backup sections', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(900, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final business = await createBusinessTestHarness();
      final settings = SettingsProvider(business.preferences);
      await settings.loaded;

      await _pumpBackupPage(tester, settings: settings, business: business);

      expect(find.text('Backup Reminder'), findsOneWidget);
      expect(find.text('Local Backup'), findsOneWidget);
      expect(find.text('WebDAV Backup'), findsOneWidget);
      expect(find.text('S3 Backup'), findsOneWidget);
      _expectAbove(tester, 'Backup Reminder', 'Local Backup');
      _expectAbove(tester, 'Local Backup', 'WebDAV Backup');
      _expectAbove(tester, 'WebDAV Backup', 'S3 Backup');
    });

    testWidgets('opens S3 settings as a full page and saves config', (
      tester,
    ) async {
      final business = await createBusinessTestHarness();
      final settings = SettingsProvider(business.preferences);
      await settings.loaded;

      await _pumpBackupPage(tester, settings: settings, business: business);

      await _openSettingsPage(tester, 'S3 Settings');

      expect(find.byType(BottomSheet), findsNothing);
      expect(find.widgetWithText(AppBar, 'S3 Settings'), findsOne);
      expect(find.text('Endpoint'), findsOneWidget);
      expect(find.text('User-Agent'), findsOneWidget);

      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), ' https://s3.example.com ');
      await tester.enterText(fields.at(7), ' KelivoS3/1.0 ');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(AppBar, 'S3 Settings'), findsNothing);
      expect(settings.s3Config.endpoint, 'https://s3.example.com');
      expect(settings.s3Config.userAgent, 'KelivoS3/1.0');
    });
  });
}
