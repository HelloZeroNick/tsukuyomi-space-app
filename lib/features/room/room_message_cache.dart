import 'dart:convert';
import 'dart:typed_data';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;

import '../../core/room_reply.dart';
import '../site/native_article_document.dart';

final _markdownPattern = RegExp(
  r'(^|\n)\s*(#{1,6} |[-*] |[0-9]+\. |~~~)|\*\*|\[[^\]]+\]\(',
);

bool roomReplyHasMarkdown(String text) =>
    _markdownPattern.hasMatch(text) || text.contains('```');

class RoomReplyPresentation {
  factory RoomReplyPresentation(String text, {bool streaming = false}) {
    final markdown = !streaming && roomReplyHasMarkdown(text);
    if (markdown && text.length > 6000) {
      // Resolve reference links and sanitize the complete document before
      // splitting. Each top-level fence, list, table and callout stays atomic.
      final fragment = html.parseFragment(
        parseNativeArticle(text, 'markdown').html,
      );
      final internalLink = fragment
          .querySelectorAll('a[href]')
          .any((link) => (link.attributes['href'] ?? '').startsWith('#'));
      // NativeRichText owns anchor scrolling. Keep footnotes and other local
      // links in one document until cross-sliver anchor navigation is available.
      if (!internalLink) {
        final chunks = <String>[];
        var buffer = StringBuffer(), blocks = 0;
        for (final node in fragment.nodes) {
          final value = node is dom.Element
              ? node.outerHtml
              : const HtmlEscape().convert(node.text ?? '');
          if (node is dom.Element &&
              blocks > 0 &&
              (blocks >= 6 || buffer.length + value.length > 6000)) {
            chunks.add(buffer.toString());
            buffer = StringBuffer();
            blocks = 0;
          }
          buffer.write(value);
          if (node is dom.Element) blocks++;
        }
        if (buffer.isNotEmpty) chunks.add(buffer.toString());
        if (chunks.length > 1) {
          return RoomReplyPresentation._(
            true,
            List.unmodifiable(chunks),
            'html',
          );
        }
      }
    }
    return RoomReplyPresentation._(
      markdown,
      List.unmodifiable(markdown ? [text] : splitRoomReply(text)),
      'markdown',
    );
  }
  const RoomReplyPresentation._(this.markdown, this.parts, this.format);

  final bool markdown;
  final List<String> parts;
  final String format;
}

/// Bounded, page-owned data cache. It never retains widgets, contexts or cookies.
/// Reusing byte identity also lets Flutter reuse the decoded MemoryImage.
class RoomMessageCache {
  RoomMessageCache({
    this.maxReplies = 128,
    this.maxReplyCharacters = 262144,
    this.maxImages = 24,
    this.maxImageBytes = 8 * 1024 * 1024,
  });

  final int maxReplies, maxReplyCharacters, maxImages, maxImageBytes;
  final _replies = <String, RoomReplyPresentation>{};
  final _images = <String, Uint8List>{};
  int _replyCharacters = 0, _imageBytes = 0;

  int get cachedReplyCharacters => _replyCharacters;
  int get cachedImageBytes => _imageBytes;
  int get replyCount => _replies.length;
  int get imageCount => _images.length;

  RoomReplyPresentation reply(String text, {bool streaming = false}) {
    if (streaming) return RoomReplyPresentation(text, streaming: true);
    final found = _replies.remove(text);
    if (found != null) {
      _replies[text] = found;
      return found;
    }
    final value = RoomReplyPresentation(text);
    // Count both the retained source and the split strings.
    final characters =
        text.length + value.parts.fold<int>(0, (n, p) => n + p.length);
    if (maxReplies > 0 && characters <= maxReplyCharacters) {
      _replies[text] = value;
      _replyCharacters += characters;
      while (_replies.length > maxReplies ||
          _replyCharacters > maxReplyCharacters) {
        final key = _replies.keys.first;
        final removed = _replies.remove(key)!;
        _replyCharacters -=
            key.length + removed.parts.fold<int>(0, (n, p) => n + p.length);
      }
    }
    return value;
  }

  Uint8List image(String dataUrl) {
    final found = _images.remove(dataUrl);
    if (found != null) {
      _images[dataUrl] = found;
      return found;
    }
    final comma = dataUrl.indexOf(',');
    if (comma < 0 || !dataUrl.substring(0, comma).endsWith(';base64')) {
      throw const FormatException('Expected a Base64 image');
    }
    final bytes = base64Decode(dataUrl.substring(comma + 1));
    if (maxImages > 0 && bytes.length <= maxImageBytes) {
      _images[dataUrl] = bytes;
      _imageBytes += bytes.length;
      while (_images.length > maxImages || _imageBytes > maxImageBytes) {
        _imageBytes -= _images.remove(_images.keys.first)!.length;
      }
    }
    return bytes;
  }

  void clear() {
    _replies.clear();
    _images.clear();
    _replyCharacters = 0;
    _imageBytes = 0;
  }
}
