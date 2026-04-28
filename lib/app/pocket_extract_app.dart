import 'package:flutter/material.dart';
import 'package:pocket_extract/presentation/pages/pocket_extract_home_page.dart';

class PocketExtractApp extends StatelessWidget {
  const PocketExtractApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PocketExtract',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0E7490)),
        useMaterial3: true,
      ),
      home: const PocketExtractHomePage(),
    );
  }
}
