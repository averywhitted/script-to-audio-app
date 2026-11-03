// How much room the app has (#121). Decided from the window's width, not the device,
// so Split View, Slide Over and Stage Manager windows get the layout that fits them.

import 'package:flutter/widgets.dart';

enum SizeClass {
  /// iPhone, and iPad windows narrower than ~700 pt: one column.
  compact,

  /// A wide window: the script is centred, with room for the My Character label in the header.
  regular,

  /// Room for the script and the PDF side by side.
  wide,
}

SizeClass sizeClassOf(double width) => width >= 1100
    ? SizeClass.wide
    : width >= 700
    ? SizeClass.regular
    : SizeClass.compact;

/// The PDF can sit beside the script from this width on; narrower, it takes the screen.
const splitPdfMinWidth = 1000.0;

/// True on an iPad (the screen is big), whatever size its window is. Apple Pencil tools and the page / continuous
/// switch belong to the iPad.
bool isPadDisplay(BuildContext context) {
  final view = View.of(context);
  final size = view.display.size / view.display.devicePixelRatio;
  return size.shortestSide >= 600;
}

/// The width of sheets on a big window: a card in the middle, not edge to edge.
BoxConstraints? sheetConstraints(BuildContext context) => MediaQuery.sizeOf(context).width >= 700 ? const BoxConstraints(maxWidth: 560) : null;
