import 'package:flutter/widgets.dart';

import 'app_localizations.dart';

export 'app_localizations.dart';

/// `context.l10n.someText`: the strings of the current language
/// (lib/l10n/app_<code>.arb).
extension L10nContext on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);
}

/// The [Locale] for a Settings.language code; null follows the phone.
Locale? localeFor(String code) => code.isEmpty ? null : Locale(code);
