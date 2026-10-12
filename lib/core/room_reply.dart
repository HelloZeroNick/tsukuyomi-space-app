/// Mirrors the website's roomReplyPresentation.mjs; stored turns stay intact.
final _replyNewlines = RegExp(r'\r\n?');
final _replyWhitespace = RegExp(r'\s');
final _replyUrl = RegExp(r'https?://|www\.', caseSensitive: false);
final _replyAbbreviation = RegExp(
  r'^(?:Mr|Mrs|Ms|Dr|Prof|St|vs|etc|e\.g|i\.e|[A-Z])\.$',
  caseSensitive: false,
);

List<String> splitRoomReply(String value) {
  final text = value.replaceAll(_replyNewlines, '\n').trim();
  if (text.isEmpty) return [];
  final parts = <String>[], brackets = <String>[];
  const closing = {
    '(': ')',
    '（': '）',
    '[': ']',
    '【': '】',
    '「': '」',
    '『': '』',
    '“': '”',
  };
  var start = 0, tokenStart = 0, inline = false, fenced = false;
  void push(int end) {
    final part = text.substring(start, end).trim();
    if (part.isNotEmpty) parts.add(part);
    start = end;
  }

  String charAt(int index) =>
      index >= 0 && index < text.length ? text[index] : '\u0000';
  String tokenAt(int index) => _replyWhitespace.hasMatch(text[index])
      ? ''
      : text.substring(tokenStart < start ? start : tokenStart, index + 1);
  bool isUrl(String token) => _replyUrl.hasMatch(token);
  for (var i = 0; i < text.length; i++) {
    final char = text[i];
    final whitespace = _replyWhitespace.hasMatch(char);
    if (whitespace) tokenStart = i + 1;
    if (text.startsWith('```', i)) {
      fenced = !fenced;
      i += 2;
      continue;
    }
    if (fenced) continue;
    if (char == '`') inline = !inline;
    if (inline) continue;
    if (closing.containsKey(char)) {
      brackets.add(closing[char]!);
    } else if (brackets.isNotEmpty && char == brackets.last) {
      brackets.removeLast();
    }
    if (brackets.isNotEmpty) continue;
    // Track word boundaries once. Scanning the whole prefix for every character
    // makes long, unbroken replies quadratic while scrolling or streaming.
    final token = '.!?'.contains(char) ? tokenAt(i) : '';
    final period =
        char == '.' &&
        (i + 1 == text.length || _replyWhitespace.hasMatch(charAt(i + 1))) &&
        !isUrl(token) &&
        !_replyAbbreviation.hasMatch(token);
    final sentence =
        '。！？'.contains(char) ||
        ('!?'.contains(char) && !isUrl(token)) ||
        period ||
        ('」』”'.contains(char) && '。！？!?'.contains(charAt(i - 1)));
    if (sentence) {
      while ('。！？!?.…～~」』”’'.contains(charAt(i + 1))) {
        i++;
      }
      push(i + 1);
    } else if (char == '\n' && charAt(i + 1) == '\n') {
      push(i);
      while (charAt(i + 1) == '\n') {
        i++;
      }
      start = i + 1;
    } else if ((i - start >= 140 && '，,；;'.contains(char)) ||
        (i - start >= 240 && whitespace)) {
      if (!isUrl(tokenAt(i))) push(i + 1);
    }
  }
  push(text.length);
  return parts;
}
