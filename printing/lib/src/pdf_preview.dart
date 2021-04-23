import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'callback.dart';
import 'printing.dart';
import 'printing_info.dart';
import 'raster.dart';

/// Flutter widget that uses the rasterized pdf pages to display a document.
class PdfPreview extends StatefulWidget {
  /// Show a pdf document built on demand
  const PdfPreview({
    Key? key,
    required this.build,
    this.initialPageFormat,
    this.allowPrinting = true,
    this.allowSharing = true,
    this.maxPageWidth,
    this.canChangePageFormat = true,
    this.canChangeOrientation = true,
    this.actions,
    this.pageFormats,
    this.onError,
    this.onPrinted,
    this.onPrintError,
    this.onShared,
    this.scrollViewDecoration,
    this.pdfPreviewPageDecoration,
    this.pdfFileName,
    this.useActions = true,
    this.pages,
    this.dynamicLayout = true,
    this.shareActionExtraBody,
    this.shareActionExtraSubject,
    this.shareActionExtraEmails,
    this.previewPageMargin,
    this.padding,
    this.shouldRepaint = false,
  }) : super(key: key);

  /// Called when a pdf document is needed
  final LayoutCallback build;

  /// Pdf page format asked for the first display
  final PdfPageFormat? initialPageFormat;

  /// Add a button to print the pdf document
  final bool allowPrinting;

  /// Add a button to share the pdf document
  final bool allowSharing;

  /// Allow disable actions
  final bool useActions;

  /// Maximum width of the pdf document on screen
  final double? maxPageWidth;

  /// Add a drop-down menu to choose the page format
  final bool canChangePageFormat;

  /// Add a switch to change the page orientation
  final bool canChangeOrientation;

  /// Additionnal actions to add to the widget
  final List<PdfPreviewAction>? actions;

  /// List of page formats the user can choose
  final Map<String, PdfPageFormat>? pageFormats;

  /// Widget to display if the PDF document cannot be displayed
  final Widget Function(BuildContext context)? onError;

  /// Called if the user prints the pdf document
  final void Function(BuildContext context)? onPrinted;

  /// Called if an error creating the Pdf occured
  final void Function(BuildContext context, dynamic error)? onPrintError;

  /// Called if the user shares the pdf document
  final void Function(BuildContext context)? onShared;

  /// Decoration of scrollView
  final Decoration? scrollViewDecoration;

  /// Decoration of _PdfPreviewPage
  final Decoration? pdfPreviewPageDecoration;

  /// Name of the PDF when sharing. It must include the extension.
  final String? pdfFileName;

  /// Pages to display. Default will display all the pages.
  final List<int>? pages;

  /// Request page re-layout to match the printer paper and margins.
  /// Mitigate an issue with iOS and macOS print dialog that prevent any
  /// channel message while opened.
  final bool dynamicLayout;

  /// email subject when email application is selected from the share dialog
  final String? shareActionExtraSubject;

  /// extra text to share with Pdf document
  final String? shareActionExtraBody;

  /// list of email addresses which will be filled automatically if the email application
  /// is selected from the share dialog.
  /// This will work only for Android platform.
  final List<String>? shareActionExtraEmails;

  /// margin for the document preview page
  ///
  /// defaults to [EdgeInsets.only(left: 20, top: 8, right: 20, bottom: 12)],
  final EdgeInsets? previewPageMargin;

  /// padding for the pdf_preview widget
  final EdgeInsets? padding;

  /// Force repainting the PDF document
  final bool shouldRepaint;

  @override
  _PdfPreviewState createState() => _PdfPreviewState();
}

class _PdfPreviewState extends State<PdfPreview> {
  final GlobalKey<State<StatefulWidget>> shareWidget = GlobalKey();
  final GlobalKey<State<StatefulWidget>> listView = GlobalKey();

  final List<_PdfPreviewPage> pages = <_PdfPreviewPage>[];

  late PdfPageFormat pageFormat;

  bool? horizontal;

  PrintingInfo info = PrintingInfo.unavailable;
  bool infoLoaded = false;

  double dpi = 10;

  Object? error;

  int? preview;

  double? updatePosition;

  final scrollController = ScrollController(
    keepScrollOffset: true,
  );

  final transformationController = TransformationController();

  Timer? previewUpdate;

  var _rastering = false;

  static const defaultPageFormats = <String, PdfPageFormat>{
    'A4': PdfPageFormat.a4,
    'Letter': PdfPageFormat.letter,
  };

  PdfPageFormat get computedPageFormat => horizontal != null
      ? (horizontal! ? pageFormat.landscape : pageFormat.portrait)
      : pageFormat;

  Future<void> _raster() async {
    if (_rastering) {
      return;
    }
    _rastering = true;

    Uint8List _doc;

    if (!info.canRaster) {
      assert(() {
        if (kIsWeb) {
          FlutterError.reportError(FlutterErrorDetails(
            exception: Exception(
                'Unable to find the `pdf.js` library.\nPlease follow the installation instructions at https://github.com/DavBfr/dart_pdf/tree/master/printing#installing'),
            library: 'printing',
            context: ErrorDescription('while rendering a PDF'),
          ));
        }

        return true;
      }());

      _rastering = false;
      return;
    }

    try {
      _doc = await widget.build(computedPageFormat);
    } catch (exception, stack) {
      InformationCollector? collector;

      assert(() {
        collector = () sync* {
          yield StringProperty('PageFormat', computedPageFormat.toString());
        };
        return true;
      }());

      FlutterError.reportError(FlutterErrorDetails(
        exception: exception,
        stack: stack,
        library: 'printing',
        context: ErrorDescription('while generating a PDF'),
        informationCollector: collector,
      ));
      error = exception;
      _rastering = false;
      return;
    }

    if (error != null) {
      setState(() {
        error = null;
      });
    }

    var pageNum = 0;
    await for (final PdfRaster page in Printing.raster(
      _doc,
      dpi: dpi,
      pages: widget.pages,
    )) {
      if (!mounted) {
        _rastering = false;
        return;
      }
      setState(() {
        if (pages.length <= pageNum) {
          pages.add(_PdfPreviewPage(
            page: page,
            pdfPreviewPageDecoration: widget.pdfPreviewPageDecoration,
            pageMargin: widget.previewPageMargin,
          ));
        } else {
          pages[pageNum] = _PdfPreviewPage(
            page: page,
            pdfPreviewPageDecoration: widget.pdfPreviewPageDecoration,
            pageMargin: widget.previewPageMargin,
          );
        }
      });

      pageNum++;
    }

    pages.removeRange(pageNum, pages.length);
    _rastering = false;
  }

  @override
  void initState() {
    if (widget.initialPageFormat == null) {
      final locale = WidgetsBinding.instance!.window.locale;
      // ignore: unnecessary_cast
      final cc = (locale as Locale?)?.countryCode ?? 'US';

      if (cc == 'US' || cc == 'CA' || cc == 'MX') {
        pageFormat = PdfPageFormat.letter;
      } else {
        pageFormat = PdfPageFormat.a4;
      }
    } else {
      pageFormat = widget.initialPageFormat!;
    }

    final _pageFormats = widget.pageFormats ?? defaultPageFormats;
    if (!_pageFormats.containsValue(pageFormat)) {
      pageFormat = _pageFormats.values.first;
    }

    super.initState();
  }

  @override
  void dispose() {
    previewUpdate?.cancel();
    super.dispose();
  }

  @override
  void reassemble() {
    _raster();
    super.reassemble();
  }

  @override
  void didUpdateWidget(covariant PdfPreview oldWidget) {
    if (oldWidget.build != widget.build || widget.shouldRepaint) {
      preview = null;
      updatePosition = null;
      _raster();
    }
    super.didUpdateWidget(oldWidget);
  }

  @override
  void didChangeDependencies() {
    if (!infoLoaded) {
      Printing.info().then((PrintingInfo _info) {
        setState(() {
          infoLoaded = true;
          info = _info;
        });
      });
    }

    previewUpdate?.cancel();
    previewUpdate = Timer(const Duration(seconds: 1), () {
      final mq = MediaQuery.of(context);
      dpi = (min(mq.size.width - 16, widget.maxPageWidth ?? double.infinity)) *
          mq.devicePixelRatio /
          computedPageFormat.width *
          72;

      _raster();
    });
    super.didChangeDependencies();
  }

  Widget _showError() {
    if (widget.onError != null) {
      return widget.onError!(context);
    }

    return const Center(
      child: Text(
        'Unable to display the document',
        style: TextStyle(
          fontSize: 20,
        ),
      ),
    );
  }

  Widget _createPreview() {
    if (error != null) {
      var content = _showError();
      assert(() {
        content = ErrorWidget(error!);
        return true;
      }());
      return content;
    }

    if (!info.canRaster) {
      return _showError();
    }

    if (pages.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    return ListView.builder(
      controller: scrollController,
      padding: widget.padding,
      itemCount: pages.length,
      itemBuilder: (BuildContext context, int index) => GestureDetector(
        onDoubleTap: () {
          setState(() {
            updatePosition = scrollController.position.pixels;
            preview = index;
            transformationController.value.setIdentity();
          });
        },
        child: pages[index],
      ),
    );
  }

  Widget _zoomPreview() {
    return GestureDetector(
      onDoubleTap: () {
        setState(() {
          preview = null;
        });
      },
      child: InteractiveViewer(
        transformationController: transformationController,
        maxScale: 5,
        child: Center(child: pages[preview!]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final iconColor = theme.primaryIconTheme.color ?? Colors.white;

    Widget page;

    if (preview != null) {
      page = _zoomPreview();
    } else {
      page = Container(
        constraints: widget.maxPageWidth != null
            ? BoxConstraints(maxWidth: widget.maxPageWidth!)
            : null,
        child: _createPreview(),
      );

      if (updatePosition != null) {
        Timer.run(() {
          scrollController.jumpTo(updatePosition!);
          updatePosition = null;
        });
      }
    }

    final Widget scrollView = Container(
      decoration: widget.scrollViewDecoration ??
          BoxDecoration(
            gradient: LinearGradient(
              colors: <Color>[Colors.grey.shade400, Colors.grey.shade200],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
      width: double.infinity,
      alignment: Alignment.center,
      child: page,
    );

    final actions = <Widget>[];

    if (widget.allowPrinting && info.canPrint) {
      actions.add(
        IconButton(
          icon: const Icon(Icons.print),
          onPressed: _print,
        ),
      );
    }

    if (widget.allowSharing && info.canShare) {
      actions.add(
        IconButton(
          key: shareWidget,
          icon: const Icon(Icons.share),
          onPressed: _share,
        ),
      );
    }

    if (widget.canChangePageFormat) {
      final _pageFormats = widget.pageFormats ?? defaultPageFormats;
      final keys = _pageFormats.keys.toList();
      actions.add(
        DropdownButton<PdfPageFormat>(
          dropdownColor: theme.primaryColor,
          icon: Icon(
            Icons.arrow_drop_down,
            color: iconColor,
          ),
          value: pageFormat,
          items: List<DropdownMenuItem<PdfPageFormat>>.generate(
            _pageFormats.length,
            (int index) {
              final key = keys[index];
              final val = _pageFormats[key];
              return DropdownMenuItem<PdfPageFormat>(
                value: val,
                child: Text(key, style: TextStyle(color: iconColor)),
              );
            },
          ),
          onChanged: (PdfPageFormat? _pageFormat) {
            setState(() {
              if (_pageFormat != null) {
                pageFormat = _pageFormat;
                _raster();
              }
            });
          },
        ),
      );

      if (widget.canChangeOrientation) {
        horizontal ??= pageFormat.width > pageFormat.height;

        final disabledColor = iconColor.withAlpha(120);
        actions.add(
          ToggleButtons(
            renderBorder: false,
            borderColor: disabledColor,
            color: disabledColor,
            selectedBorderColor: iconColor,
            selectedColor: iconColor,
            onPressed: (int index) {
              setState(() {
                horizontal = index == 1;
                _raster();
              });
            },
            isSelected: <bool>[horizontal == false, horizontal == true],
            children: <Widget>[
              Transform.rotate(
                  angle: -pi / 2, child: const Icon(Icons.note_outlined)),
              const Icon(Icons.note_outlined),
            ],
          ),
        );
      }
    }

    if (widget.actions != null) {
      for (final action in widget.actions!) {
        actions.add(
          IconButton(
            icon: action.icon,
            onPressed: action.onPressed == null
                ? null
                : () => action.onPressed!(
                      context,
                      widget.build,
                      computedPageFormat,
                    ),
          ),
        );
      }
    }

    assert(() {
      if (actions.isNotEmpty) {
        actions.add(
          Switch(
            activeColor: Colors.red,
            value: pw.Document.debug,
            onChanged: (bool value) {
              setState(
                () {
                  pw.Document.debug = value;
                  _raster();
                },
              );
            },
          ),
        );
      }

      return true;
    }());

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        Expanded(
            child: scrollController.hasClients
                ? Scrollbar(controller: scrollController, child: scrollView)
                : scrollView),
        if (actions.isNotEmpty && widget.useActions)
          IconTheme.merge(
            data: IconThemeData(
              color: iconColor,
            ),
            child: Material(
              elevation: 4,
              color: theme.primaryColor,
              child: SizedBox(
                width: double.infinity,
                child: SafeArea(
                  child: Wrap(
                    alignment: WrapAlignment.spaceAround,
                    children: actions,
                  ),
                ),
              ),
            ),
          )
      ],
    );
  }

  Future<void> _print() async {
    var format = computedPageFormat;

    if (!widget.canChangePageFormat && pages.isNotEmpty) {
      format = PdfPageFormat(
        pages.first.page!.width * 72 / dpi,
        pages.first.page!.height * 72 / dpi,
        marginAll: 5 * PdfPageFormat.mm,
      );
    }

    try {
      final result = await Printing.layoutPdf(
        onLayout: widget.build,
        name: widget.pdfFileName ?? 'Document',
        format: format,
        dynamicLayout: widget.dynamicLayout,
      );

      if (result && widget.onPrinted != null) {
        widget.onPrinted!(context);
      }
    } catch (e) {
      if (widget.onPrintError != null) {
        widget.onPrintError!(context, e);
      }
    }
  }

  Future<void> _share() async {
    // Calculate the widget center for iPad sharing popup position
    final referenceBox =
        shareWidget.currentContext!.findRenderObject() as RenderBox;
    final topLeft =
        referenceBox.localToGlobal(referenceBox.paintBounds.topLeft);
    final bottomRight =
        referenceBox.localToGlobal(referenceBox.paintBounds.bottomRight);
    final bounds = Rect.fromPoints(topLeft, bottomRight);

    final bytes = await widget.build(computedPageFormat);
    final result = await Printing.sharePdf(
      bytes: bytes,
      bounds: bounds,
      filename: widget.pdfFileName ?? 'document.pdf',
      body: widget.shareActionExtraBody,
      subject: widget.shareActionExtraSubject,
      emails: widget.shareActionExtraEmails,
    );

    if (result && widget.onShared != null) {
      widget.onShared!(context);
    }
  }
}

class _PdfPreviewPage extends StatelessWidget {
  const _PdfPreviewPage({
    Key? key,
    this.page,
    this.pdfPreviewPageDecoration,
    this.pageMargin,
  }) : super(key: key);

  final PdfRaster? page;
  final Decoration? pdfPreviewPageDecoration;
  final EdgeInsets? pageMargin;

  @override
  Widget build(BuildContext context) {
    final im = PdfRasterImage(page!);
    final scrollbarTrack = Theme.of(context)
            .scrollbarTheme
            .thickness
            ?.resolve({MaterialState.hovered}) ??
        12;

    return Container(
      margin: pageMargin ??
          EdgeInsets.only(
            left: 8 + scrollbarTrack,
            top: 8,
            right: 8 + scrollbarTrack,
            bottom: 12,
          ),
      decoration: pdfPreviewPageDecoration ??
          const BoxDecoration(
            color: Colors.white,
            boxShadow: <BoxShadow>[
              BoxShadow(
                offset: Offset(0, 3),
                blurRadius: 5,
                color: Color(0xFF000000),
              ),
            ],
          ),
      child: AspectRatio(
        aspectRatio: page!.width / page!.height,
        child: Image(
          image: im,
          fit: BoxFit.cover,
        ),
      ),
    );
  }
}

/// Action callback
typedef OnPdfPreviewActionPressed = void Function(
  BuildContext context,
  LayoutCallback build,
  PdfPageFormat pageFormat,
);

/// Action to add the the [PdfPreview] widget
class PdfPreviewAction {
  /// Represents an icon to add to [PdfPreview]
  const PdfPreviewAction({
    required this.icon,
    required this.onPressed,
  });

  /// The icon to display
  final Icon icon;

  /// The callback called when the user tap on the icon
  final OnPdfPreviewActionPressed? onPressed;
}
