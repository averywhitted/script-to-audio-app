// A passing message at the bottom of the screen: short, and it never stays in the way
// (a newer one replaces it; swipe it away to dismiss it sooner).

import 'package:flutter/material.dart';

void showNotice(ScaffoldMessengerState messenger, String text) {
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(text),
        duration: const Duration(milliseconds: 1800),
        behavior: SnackBarBehavior.floating,
        dismissDirection: DismissDirection.down,
      ),
    );
}
