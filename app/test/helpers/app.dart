import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:hexapod_app/l10n/l10n.dart';

/// A MaterialApp with the app's translations, in Portuguese by default (the
/// texts most tests look for).
MaterialApp testApp({required Widget home, Locale locale = const Locale('pt'), ThemeData? theme}) =>
    MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: locale,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      theme: theme,
      home: home,
    );
