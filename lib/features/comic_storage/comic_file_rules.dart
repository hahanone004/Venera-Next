const comicImageExtensions = {
  'jpg',
  'jpeg',
  'png',
  'webp',
  'gif',
  'jpe',
  'avif',
};

const comicArchiveExtensions = {'cbz', 'zip', '7z', 'cb7'};

String comicFileExtension(String name) {
  final baseName = _baseName(name);
  final dot = baseName.lastIndexOf('.');
  if (dot <= 0 || dot == baseName.length - 1) return '';
  return baseName.substring(dot + 1).toLowerCase();
}

String comicFileStem(String name) {
  final baseName = _baseName(name);
  final dot = baseName.lastIndexOf('.');
  return dot <= 0 ? baseName : baseName.substring(0, dot);
}

bool isComicImageFileName(String name) {
  return comicImageExtensions.contains(comicFileExtension(name));
}

bool isComicArchiveFileName(String name) {
  return comicArchiveExtensions.contains(comicFileExtension(name));
}

bool isNamedComicCover(String name) {
  return isComicImageFileName(name) &&
      comicFileStem(name).toLowerCase() == 'cover';
}

bool isIgnoredComicStorageEntry(String name) {
  final baseName = _baseName(name);
  return baseName == '__MACOSX' ||
      baseName == '.DS_Store' ||
      baseName.startsWith('.');
}

List<T> sortedComicImageEntries<T>(
  Iterable<T> entries, {
  required String Function(T entry) nameOf,
  bool includeCover = true,
}) {
  final result = entries.where((entry) {
    final name = nameOf(entry);
    return !isIgnoredComicStorageEntry(name) &&
        isComicImageFileName(name) &&
        (includeCover || !isNamedComicCover(name));
  }).toList();
  result.sort((a, b) => compareComicFileNames(nameOf(a), nameOf(b)));
  return result;
}

T? findNamedComicCover<T>(
  Iterable<T> entries, {
  required String Function(T entry) nameOf,
}) {
  for (final entry in entries) {
    if (isNamedComicCover(nameOf(entry))) return entry;
  }
  return null;
}

/// Compares two file/directory names using natural sort order, so that
/// numeric runs are compared by value instead of lexically
/// (e.g. "Chapter 2" sorts before "Chapter 10").
int compareComicFileNames(String a, String b) {
  final aName = _baseName(a);
  final bName = _baseName(b);
  final naturalComparison = _naturalCompare(
    aName.toLowerCase(),
    bName.toLowerCase(),
  );
  return naturalComparison != 0 ? naturalComparison : aName.compareTo(bName);
}

int _naturalCompare(String a, String b) {
  var i = 0;
  var j = 0;
  while (i < a.length && j < b.length) {
    if (_isDigit(a.codeUnitAt(i)) && _isDigit(b.codeUnitAt(j))) {
      var iEnd = i;
      while (iEnd < a.length && _isDigit(a.codeUnitAt(iEnd))) {
        iEnd++;
      }
      var jEnd = j;
      while (jEnd < b.length && _isDigit(b.codeUnitAt(jEnd))) {
        jEnd++;
      }
      final numComparison = BigInt.parse(
        a.substring(i, iEnd),
      ).compareTo(BigInt.parse(b.substring(j, jEnd)));
      if (numComparison != 0) return numComparison;
      i = iEnd;
      j = jEnd;
    } else {
      final charComparison = a[i].compareTo(b[j]);
      if (charComparison != 0) return charComparison;
      i++;
      j++;
    }
  }
  return (a.length - i).compareTo(b.length - j);
}

bool _isDigit(int codeUnit) => codeUnit >= 0x30 && codeUnit <= 0x39;

String _baseName(String name) {
  final slash = name.lastIndexOf('/');
  final backslash = name.lastIndexOf('\\');
  final separator = slash > backslash ? slash : backslash;
  return separator < 0 ? name : name.substring(separator + 1);
}
