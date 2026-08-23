import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/webdav_library/webdav_library.dart';
import 'package:venera_next/features/webdav_library/webdav_library_cache.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';

void main() {
  late _FakeWebDavLibraryOps ops;
  late Directory dataDir;

  setUp(() {
    dataDir = Directory.systemTemp.createTempSync('venera-webdav-library-');
    App.dataPath = dataDir.path;
    WebDavLibrarySource.resetCacheForTesting();
    ops = _FakeWebDavLibraryOps();
    WebDavLibrarySource.ops = ops;
    appdata.settings['webdavComicLibrary'] = [
      'https://example.com/dav',
      'user',
      'pass',
    ];
    appdata.settings['webdavComicLibraryPath'] = '/manga/';
    appdata.settings['webdavComicLibraryAutoSync'] = false;
  });

  tearDown(() async {
    if (WebDavLibrarySource.syncStatus.value.isSyncing) {
      await WebDavLibrarySource.synchronize();
    }
    WebDavLibrarySource.resetOps();
    WebDavLibrarySource.resetCacheForTesting();
    appdata.settings['webdavComicLibrary'] = [];
    appdata.settings['webdavComicLibraryPath'] = '/venera_comics/';
    appdata.settings['webdavComicLibraryAutoSync'] = true;
    dataDir.deleteSync(recursive: true);
  });

  test('loadComics lists directories and ignores archives', () async {
    ops.dirs['/manga/'] = const [
      WebDavLibraryEntry(name: 'Cat Eye', isDirectory: true),
      WebDavLibraryEntry(name: 'archive.cbz', isDirectory: false),
      WebDavLibraryEntry(name: '.DS_Store', isDirectory: false),
    ];
    ops.dirs['/manga/Cat Eye/'] = const [
      WebDavLibraryEntry(name: 'cover.jpg', isDirectory: false),
      WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
    ];

    await WebDavLibrarySource.loadComics(1);
    await WebDavLibrarySource.synchronize();
    final result = await WebDavLibrarySource.loadComics(1);

    expect(result.success, isTrue);
    expect(result.data.single.cover, '/manga/Cat Eye/cover.jpg');
    expect(result.subData, 1);
    expect(result.data.map((comic) => comic.title), ['Cat Eye']);
    expect(result.data.single.sourceKey, WebDavLibrarySource.sourceKey);
  });

  test(
    'loadComics keeps folder title and finds chapter cover from unmodifiable lists',
    () async {
      ops.dirs['/manga/'] = List.unmodifiable([
        const WebDavLibraryEntry(name: '猫之眼[北条司]', isDirectory: true),
      ]);
      ops.dirs['/manga/猫之眼[北条司]/'] = List.unmodifiable([
        const WebDavLibraryEntry(name: '第01卷', isDirectory: true),
        const WebDavLibraryEntry(name: '第02卷', isDirectory: true),
      ]);
      ops.dirs['/manga/猫之眼[北条司]/第01卷/'] = List.unmodifiable([
        const WebDavLibraryEntry(name: '002.jpg', isDirectory: false),
        const WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ]);

      await WebDavLibrarySource.loadComics(1);
      await WebDavLibrarySource.synchronize();
      final result = await WebDavLibrarySource.loadComics(1);

      expect(result.success, isTrue);
      expect(result.data.single.title, '猫之眼[北条司]');
      expect(result.data.single.cover, '/manga/猫之眼[北条司]/第01卷/001.jpg');
    },
  );

  test(
    'loadComics keeps folder title when metadata inspection fails',
    () async {
      ops.dirs['/manga/'] = const [
        WebDavLibraryEntry(name: 'Cat Eye', isDirectory: true),
      ];
      ops.errors['/manga/Cat Eye/'] = UnsupportedError(
        'Cannot remove from an unmodifiable list',
      );

      final result = await WebDavLibrarySource.loadComics(1);

      expect(result.success, isTrue);
      expect(result.data.single.title, 'Cat Eye');
      expect(result.data.single.cover, '');
    },
  );

  test(
    'initial list returns before comic metadata inspection finishes',
    () async {
      ops.dirs['/manga/'] = const [
        WebDavLibraryEntry(name: 'Slow Book', isDirectory: true),
      ];
      ops.dirs['/manga/Slow Book/'] = const [
        WebDavLibraryEntry(name: 'cover.jpg', isDirectory: false),
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      final blocker = Completer<void>();
      ops.blockers['/manga/Slow Book/'] = blocker;

      final initial = await WebDavLibrarySource.loadComics(1);

      expect(initial.success, isTrue);
      expect(initial.data.single.title, 'Slow Book');
      expect(initial.data.single.cover, isEmpty);
      expect(WebDavLibrarySource.syncStatus.value.isSyncing, isTrue);

      blocker.complete();
      await WebDavLibrarySource.synchronize();
      final updated = await WebDavLibrarySource.loadComics(1);

      expect(updated.data.single.cover, '/manga/Slow Book/cover.jpg');
    },
  );

  test('cached comic list is paged without additional WebDAV reads', () async {
    ops.dirs['/manga/'] = [
      for (var index = 1; index <= 45; index++)
        WebDavLibraryEntry(
          name: 'Book ${index.toString().padLeft(2, '0')}',
          isDirectory: true,
          eTag: 'v1',
        ),
    ];
    for (var index = 1; index <= 45; index++) {
      final name = 'Book ${index.toString().padLeft(2, '0')}';
      ops.dirs['/manga/$name/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
    }

    await WebDavLibrarySource.synchronize();
    ops.readPaths.clear();

    final first = await WebDavLibrarySource.loadComics(1);
    final second = await WebDavLibrarySource.loadComics(2);
    final third = await WebDavLibrarySource.loadComics(3);

    expect(first.data, hasLength(20));
    expect(second.data, hasLength(20));
    expect(third.data, hasLength(5));
    expect(first.subData, 3);
    expect(second.subData, 3);
    expect(third.subData, 3);
    expect(ops.readPaths, isEmpty);
  });

  test('incremental sync only re-inspects changed directories', () async {
    ops.dirs['/manga/'] = const [
      WebDavLibraryEntry(name: 'Book A', isDirectory: true, eTag: 'v1'),
      WebDavLibraryEntry(name: 'Book B', isDirectory: true, eTag: 'v1'),
    ];
    ops.dirs['/manga/Book A/'] = const [
      WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
    ];
    ops.dirs['/manga/Book B/'] = const [
      WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
    ];
    await WebDavLibrarySource.synchronize();
    ops.readPaths.clear();

    await WebDavLibrarySource.synchronize();
    expect(ops.readPaths, ['/manga/']);

    ops.readPaths.clear();
    ops.dirs['/manga/'] = const [
      WebDavLibraryEntry(name: 'Book A', isDirectory: true, eTag: 'v2'),
      WebDavLibraryEntry(name: 'Book B', isDirectory: true, eTag: 'v1'),
    ];
    await WebDavLibrarySource.synchronize();

    expect(ops.readPaths, ['/manga/', '/manga/Book A/']);
  });

  test('failed refresh keeps the last successful cached list', () async {
    ops.dirs['/manga/'] = const [
      WebDavLibraryEntry(name: 'Cached Book', isDirectory: true),
    ];
    ops.dirs['/manga/Cached Book/'] = const [
      WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
    ];
    await WebDavLibrarySource.synchronize();
    ops.errors['/manga/'] = StateError('WebDAV unavailable');

    final refresh = await WebDavLibrarySource.synchronize(force: true);
    final cached = await WebDavLibrarySource.loadComics(1);

    expect(refresh.error, isTrue);
    expect(cached.success, isTrue);
    expect(cached.data.single.title, 'Cached Book');
  });

  test('concurrent detail loads share one snapshot request', () async {
    ops.dirs['/manga/Book/'] = const [
      WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
    ];

    final results = await Future.wait([
      WebDavLibrarySource.loadComicInfo('Book'),
      WebDavLibrarySource.loadComicInfo('Book'),
    ]);

    expect(results.every((result) => result.success), isTrue);
    expect(ops.readPaths, ['/manga/Book/']);
  });

  test(
    'a detail-only cache entry does not replace the full library index',
    () async {
      ops.dirs['/manga/'] = const [
        WebDavLibraryEntry(name: 'Book A', isDirectory: true),
        WebDavLibraryEntry(name: 'Book B', isDirectory: true),
      ];
      ops.dirs['/manga/Book A/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/Book B/'] = const [
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];

      await WebDavLibrarySource.loadComicInfo('Book A');
      await WebDavLibrarySource.loadComics(1);
      await WebDavLibrarySource.synchronize();
      final comics = await WebDavLibrarySource.loadComics(1);

      expect(comics.data.map((comic) => comic.id), ['Book A', 'Book B']);
    },
  );

  test(
    'loadComicInfo lists every chapter directory and uses the first page as cover',
    () async {
      ops.dirs['/manga/Cat Eye/'] = const [
        WebDavLibraryEntry(name: '第01卷', isDirectory: true),
        WebDavLibraryEntry(name: '第02卷', isDirectory: true),
        WebDavLibraryEntry(name: '第03卷', isDirectory: true),
        WebDavLibraryEntry(name: '第04卷', isDirectory: true),
        WebDavLibraryEntry(name: '第05卷', isDirectory: true),
        WebDavLibraryEntry(name: 'book.cbz', isDirectory: false),
      ];
      ops.dirs['/manga/Cat Eye/第01卷/'] = const [
        WebDavLibraryEntry(name: '002.jpg', isDirectory: false),
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/Cat Eye/第02卷/'] = const [
        WebDavLibraryEntry(name: '001.webp', isDirectory: false),
      ];

      final result = await WebDavLibrarySource.loadComicInfo('Cat Eye');

      expect(result.success, isTrue);
      expect(result.data.cover, '/manga/Cat Eye/第01卷/001.jpg');
      expect(result.data.chapters!.allChapters, {
        '第01卷': '第01卷',
        '第02卷': '第02卷',
        '第03卷': '第03卷',
        '第04卷': '第04卷',
        '第05卷': '第05卷',
        // book.cbz is a single-archive chapter (see the 'archive-file
        // chapters' group below), not an ignored file.
        'book.cbz': 'book.cbz',
      });
      expect(ops.readPaths, ['/manga/Cat Eye/', '/manga/Cat Eye/第01卷/']);
    },
  );

  test(
    'incremental sync rebuilds snapshots from the old cache format',
    () async {
      const comicId = 'Cached Book';
      final config = WebDavLibraryConfig.fromSettings();
      final cache = WebDavLibraryCache.instance;
      cache.replaceDirectoryIndex(config.cacheKey, const [
        WebDavLibraryRemoteDirectory(id: comicId, sortIndex: 0, eTag: 'v1'),
      ]);
      cache.upsertSnapshot(
        config.cacheKey,
        const WebDavLibraryCachedComic(
          id: comicId,
          sortIndex: 0,
          title: comicId,
          author: '',
          tags: [],
          cover: '/manga/Cached Book/cover.jpg',
          snapshot: {
            'title': comicId,
            'author': '',
            'tags': [],
            'cover': '/manga/Cached Book/cover.jpg',
            'chapters': {
              'Chapter 01': 'Chapter 01',
              'Chapter 02': 'Chapter 02',
              'Chapter 03': 'Chapter 03',
            },
            'metadataChapters': {},
            'rootImages': [],
          },
          remoteETag: 'v1',
          remoteModifiedAt: null,
        ),
      );
      ops.dirs['/manga/'] = const [
        WebDavLibraryEntry(name: comicId, isDirectory: true, eTag: 'v1'),
      ];
      ops.dirs['/manga/Cached Book/'] = const [
        WebDavLibraryEntry(name: 'cover.jpg', isDirectory: false),
        WebDavLibraryEntry(name: 'Chapter 01', isDirectory: true),
        WebDavLibraryEntry(name: 'Chapter 02', isDirectory: true),
        WebDavLibraryEntry(name: 'Chapter 03', isDirectory: true),
        WebDavLibraryEntry(name: 'Chapter 04', isDirectory: true),
        WebDavLibraryEntry(name: 'Chapter 05', isDirectory: true),
      ];

      final sync = await WebDavLibrarySource.synchronize();
      final details = await WebDavLibrarySource.loadComicInfo(comicId);

      expect(sync.success, isTrue);
      expect(details.success, isTrue);
      expect(details.data.chapters!.allChapters, hasLength(5));
      expect(ops.readPaths, ['/manga/', '/manga/Cached Book/']);
    },
  );

  test(
    'loadComicInfo handles Chinese comic and chapter directories from unmodifiable lists',
    () async {
      ops.dirs['/manga/猫之眼[北条司]/'] = List.unmodifiable([
        const WebDavLibraryEntry(name: '第01卷', isDirectory: true),
        const WebDavLibraryEntry(name: '第02卷', isDirectory: true),
      ]);
      ops.dirs['/manga/猫之眼[北条司]/第01卷/'] = List.unmodifiable([
        const WebDavLibraryEntry(name: '002.jpg', isDirectory: false),
        const WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ]);
      ops.dirs['/manga/猫之眼[北条司]/第02卷/'] = List.unmodifiable([
        const WebDavLibraryEntry(name: '001.webp', isDirectory: false),
      ]);

      final result = await WebDavLibrarySource.loadComicInfo('猫之眼[北条司]');

      expect(result.success, isTrue);
      expect(result.data.cover, '/manga/猫之眼[北条司]/第01卷/001.jpg');
      expect(result.data.chapters!.allChapters, {
        '第01卷': '第01卷',
        '第02卷': '第02卷',
      });
      expect(ops.readPaths, ['/manga/猫之眼[北条司]/', '/manga/猫之眼[北条司]/第01卷/']);
    },
  );

  test('loadComicInfo uses root cover and root images when present', () async {
    ops.dirs['/manga/Cat Eye/'] = const [
      WebDavLibraryEntry(name: 'cover.jpg', isDirectory: false),
      WebDavLibraryEntry(name: '002.jpg', isDirectory: false),
      WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
    ];

    final result = await WebDavLibrarySource.loadComicInfo('Cat Eye');

    expect(result.success, isTrue);
    expect(result.data.cover, '/manga/Cat Eye/cover.jpg');
    expect(result.data.chapters, isNull);
  });

  test('loadComicPages returns chapter image paths in reading order', () async {
    ops.dirs['/manga/Cat Eye/第01卷/'] = const [
      WebDavLibraryEntry(name: 'cover.jpg', isDirectory: false),
      WebDavLibraryEntry(name: '010.jpg', isDirectory: false),
      WebDavLibraryEntry(name: '002.jpg', isDirectory: false),
    ];

    final result = await WebDavLibrarySource.loadComicPages('Cat Eye', '第01卷');

    expect(result.success, isTrue);
    expect(result.data, [
      '/manga/Cat Eye/第01卷/002.jpg',
      '/manga/Cat Eye/第01卷/010.jpg',
    ]);
  });

  test('loadComicPages handles Chinese directory paths', () async {
    ops.dirs['/manga/猫之眼[北条司]/第01卷/'] = List.unmodifiable([
      const WebDavLibraryEntry(name: '010.jpg', isDirectory: false),
      const WebDavLibraryEntry(name: '002.jpg', isDirectory: false),
    ]);

    final result = await WebDavLibrarySource.loadComicPages('猫之眼[北条司]', '第01卷');

    expect(result.success, isTrue);
    expect(result.data, [
      '/manga/猫之眼[北条司]/第01卷/002.jpg',
      '/manga/猫之眼[北条司]/第01卷/010.jpg',
    ]);
  });

  group('archive-file chapters', () {
    late Directory cacheDir;

    setUp(() {
      cacheDir = Directory.systemTemp.createTempSync(
        'venera-webdav-library-cache-',
      );
      App.cachePath = cacheDir.path;
    });

    tearDown(() {
      cacheDir.deleteSync(recursive: true);
    });

    List<int> buildZip(Map<String, List<int>> filesByName) {
      final archive = Archive();
      for (final entry in filesByName.entries) {
        archive.addFile(
          ArchiveFile(entry.key, entry.value.length, entry.value),
        );
      }
      return ZipEncoder().encode(archive);
    }

    test(
      'loadComicPages downloads and extracts a single-cbz chapter',
      () async {
        ops.dirs['/manga/'] = const [
          WebDavLibraryEntry(name: 'Comic', isDirectory: true),
        ];
        ops.dirs['/manga/Comic/'] = const [
          WebDavLibraryEntry(
            name: 'Chapter1.cbz',
            isDirectory: false,
            eTag: 'etag-1',
          ),
        ];
        ops.binaryFiles['/manga/Comic/Chapter1.cbz'] = buildZip({
          '001.jpg': [1, 2, 3],
          '002.jpg': [4, 5, 6],
        });

        final result = await WebDavLibrarySource.loadComicPages(
          'Comic',
          'Chapter1.cbz',
        );

        expect(result.success, isTrue);
        expect(result.data, hasLength(2));
        expect(result.data.every((path) => path.startsWith('file://')), isTrue);
        expect(result.data[0], endsWith('001.jpg'));
        expect(result.data[1], endsWith('002.jpg'));
        final firstFile = File(result.data[0].replaceFirst('file://', ''));
        expect(await firstFile.readAsBytes(), [1, 2, 3]);
      },
    );

    test(
      'loadComicPages reuses the extracted cache instead of downloading again',
      () async {
        ops.dirs['/manga/'] = const [
          WebDavLibraryEntry(name: 'Comic', isDirectory: true),
        ];
        ops.dirs['/manga/Comic/'] = const [
          WebDavLibraryEntry(
            name: 'Chapter1.cbz',
            isDirectory: false,
            eTag: 'etag-1',
          ),
        ];
        ops.binaryFiles['/manga/Comic/Chapter1.cbz'] = buildZip({
          '001.jpg': [1, 2, 3],
        });

        final first = await WebDavLibrarySource.loadComicPages(
          'Comic',
          'Chapter1.cbz',
        );
        final second = await WebDavLibrarySource.loadComicPages(
          'Comic',
          'Chapter1.cbz',
        );

        expect(first.data, second.data);
        expect(ops.binaryReadPaths, ['/manga/Comic/Chapter1.cbz']);
      },
    );

    test(
      'loadComicPages re-downloads once the remote eTag changes',
      () async {
        ops.dirs['/manga/'] = const [
          WebDavLibraryEntry(name: 'Comic', isDirectory: true),
        ];
        ops.dirs['/manga/Comic/'] = const [
          WebDavLibraryEntry(
            name: 'Chapter1.cbz',
            isDirectory: false,
            eTag: 'etag-1',
          ),
        ];
        ops.binaryFiles['/manga/Comic/Chapter1.cbz'] = buildZip({
          '001.jpg': [1, 2, 3],
        });
        await WebDavLibrarySource.loadComicPages('Comic', 'Chapter1.cbz');

        // Simulate the remote file changing: new eTag, new content.
        WebDavLibrarySource.resetCacheForTesting();
        ops.dirs['/manga/Comic/'] = const [
          WebDavLibraryEntry(
            name: 'Chapter1.cbz',
            isDirectory: false,
            eTag: 'etag-2',
          ),
        ];
        ops.binaryFiles['/manga/Comic/Chapter1.cbz'] = buildZip({
          '001.jpg': [9, 9, 9],
        });

        final result = await WebDavLibrarySource.loadComicPages(
          'Comic',
          'Chapter1.cbz',
        );

        expect(result.success, isTrue);
        final file = File(result.data.single.replaceFirst('file://', ''));
        expect(await file.readAsBytes(), [9, 9, 9]);
        expect(ops.binaryReadPaths, [
          '/manga/Comic/Chapter1.cbz',
          '/manga/Comic/Chapter1.cbz',
        ]);
      },
    );
  });

  test(
    'CBZ metadata enriches list and details and maps virtual chapter pages',
    () async {
      ops.dirs['/manga/'] = const [
        WebDavLibraryEntry(name: '猫之眼[北条司]', isDirectory: true),
      ];
      ops.dirs['/manga/猫之眼[北条司]/'] = const [
        WebDavLibraryEntry(name: 'metadata.JSON', isDirectory: false),
        WebDavLibraryEntry(name: 'ComicInfo.xml', isDirectory: false),
        WebDavLibraryEntry(name: 'cover.jpg', isDirectory: false),
        WebDavLibraryEntry(name: '0004.jpg', isDirectory: false),
        WebDavLibraryEntry(name: '0002.jpg', isDirectory: false),
        WebDavLibraryEntry(name: '0001.jpg', isDirectory: false),
        WebDavLibraryEntry(name: '0003.jpg', isDirectory: false),
      ];
      ops.textFiles['/manga/猫之眼[北条司]/metadata.JSON'] = jsonEncode({
        'title': '猫之眼',
        'author': '北条司',
        'tags': ['动作', '漫画'],
        'chapters': [
          {'title': '第01卷', 'start': 1, 'end': 2},
          {'title': '第02卷', 'start': 3, 'end': 4},
        ],
      });

      await WebDavLibrarySource.loadComics(1);
      await WebDavLibrarySource.synchronize();
      final comics = await WebDavLibrarySource.loadComics(1);
      final details = await WebDavLibrarySource.loadComicInfo('猫之眼[北条司]');
      final pages = await WebDavLibrarySource.loadComicPages(
        '猫之眼[北条司]',
        '__cbz_range_1',
      );

      expect(comics.success, isTrue);
      expect(comics.data.single.title, '猫之眼');
      expect(comics.data.single.subtitle, '北条司');
      expect(comics.data.single.tags, ['WebDAV', '动作', '漫画']);
      expect(comics.data.single.cover, '/manga/猫之眼[北条司]/cover.jpg');
      expect(details.success, isTrue);
      expect(details.data.title, '猫之眼');
      expect(details.data.subTitle, '北条司');
      expect(details.data.tags['Tags'], ['动作', '漫画']);
      expect(details.data.chapters!.allChapters, {
        '__cbz_range_0': '第01卷',
        '__cbz_range_1': '第02卷',
      });
      expect(pages.success, isTrue);
      expect(pages.data, [
        '/manga/猫之眼[北条司]/0003.jpg',
        '/manga/猫之眼[北条司]/0004.jpg',
      ]);
      expect(ops.textReadPaths, ['/manga/猫之眼[北条司]/metadata.JSON']);
    },
  );

  test(
    'CBZ metadata without chapters keeps root pages as one chapter',
    () async {
      ops.dirs['/manga/Flat Book/'] = const [
        WebDavLibraryEntry(name: 'metadata.json', isDirectory: false),
        WebDavLibraryEntry(name: '0002.webp', isDirectory: false),
        WebDavLibraryEntry(name: '0001.webp', isDirectory: false),
      ];
      ops.textFiles['/manga/Flat Book/metadata.json'] = jsonEncode({
        'title': 'Flat Export',
        'author': '',
        'tags': <String>[],
        'chapters': null,
      });

      final details = await WebDavLibrarySource.loadComicInfo('Flat Book');
      final pages = await WebDavLibrarySource.loadComicPages('Flat Book', null);

      expect(details.success, isTrue);
      expect(details.data.title, 'Flat Export');
      expect(details.data.chapters, isNull);
      expect(pages.success, isTrue);
      expect(pages.data, [
        '/manga/Flat Book/0001.webp',
        '/manga/Flat Book/0002.webp',
      ]);
    },
  );

  test('malformed CBZ metadata falls back to folder inference', () async {
    ops.dirs['/manga/Broken Book/'] = const [
      WebDavLibraryEntry(name: 'metadata.json', isDirectory: false),
      WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
    ];
    ops.textFiles['/manga/Broken Book/metadata.json'] = '{broken';

    final details = await WebDavLibrarySource.loadComicInfo('Broken Book');
    final pages = await WebDavLibrarySource.loadComicPages(
      'Broken Book',
      WebDavLibrarySource.rootChapterId,
    );

    expect(details.success, isTrue);
    expect(details.data.title, 'Broken Book');
    expect(details.data.chapters, isNull);
    expect(pages.success, isTrue);
    expect(pages.data, ['/manga/Broken Book/001.jpg']);
  });

  for (final invalidCase in <String, List<Map<String, Object>>>{
    'out-of-range': [
      {'title': 'Chapter 1', 'start': 1, 'end': 3},
    ],
    'overlapping': [
      {'title': 'Chapter 1', 'start': 1, 'end': 2},
      {'title': 'Chapter 2', 'start': 2, 'end': 2},
    ],
    'reversed': [
      {'title': 'Chapter 1', 'start': 2, 'end': 1},
    ],
  }.entries) {
    test(
      '${invalidCase.key} CBZ chapter ranges fall back to root pages',
      () async {
        ops.dirs['/manga/Invalid Book/'] = const [
          WebDavLibraryEntry(name: 'metadata.json', isDirectory: false),
          WebDavLibraryEntry(name: '002.jpg', isDirectory: false),
          WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
        ];
        ops.textFiles['/manga/Invalid Book/metadata.json'] = jsonEncode({
          'title': 'Must Not Replace Folder Name',
          'author': 'Author',
          'tags': ['tag'],
          'chapters': invalidCase.value,
        });

        final details = await WebDavLibrarySource.loadComicInfo('Invalid Book');
        final pages = await WebDavLibrarySource.loadComicPages(
          'Invalid Book',
          null,
        );

        expect(details.success, isTrue);
        expect(details.data.title, 'Invalid Book');
        expect(details.data.chapters, isNull);
        expect(pages.success, isTrue);
        expect(pages.data, [
          '/manga/Invalid Book/001.jpg',
          '/manga/Invalid Book/002.jpg',
        ]);
      },
    );
  }

  test(
    'getImageLoadingConfig builds encoded URL and basic auth header',
    () async {
      final config = await WebDavLibrarySource.getImageLoadingConfig(
        '/manga/Cat Eye/第01卷/001.jpg',
        'Cat Eye',
        '第01卷',
      );

      expect(
        config['url'],
        'https://example.com/dav/manga/Cat%20Eye/%E7%AC%AC01%E5%8D%B7/001.jpg',
      );
      expect(config['headers'], {'authorization': 'Basic dXNlcjpwYXNz'});
    },
  );
}

class _FakeWebDavLibraryOps implements WebDavLibraryOps {
  final dirs = <String, List<WebDavLibraryEntry>>{};
  final errors = <String, Object>{};
  final textFiles = <String, String>{};
  final binaryFiles = <String, List<int>>{};
  final readPaths = <String>[];
  final textReadPaths = <String>[];
  final binaryReadPaths = <String>[];
  final blockers = <String, Completer<void>>{};

  @override
  Future<List<WebDavLibraryEntry>> readDir(
    WebDavLibraryConfig config,
    String remotePath,
  ) async {
    readPaths.add(remotePath);
    await blockers[remotePath]?.future;
    final error = errors[remotePath];
    if (error != null) throw error;
    return dirs[remotePath] ?? const [];
  }

  @override
  Future<String> readText(WebDavLibraryConfig config, String remotePath) async {
    textReadPaths.add(remotePath);
    final value = textFiles[remotePath];
    if (value == null) throw StateError('Missing text file: $remotePath');
    return value;
  }

  @override
  Future<List<int>> readBytes(
    WebDavLibraryConfig config,
    String remotePath,
  ) async {
    binaryReadPaths.add(remotePath);
    final value = binaryFiles[remotePath];
    if (value == null) throw StateError('Missing binary file: $remotePath');
    return value;
  }

  @override
  Future<void> test(WebDavLibraryConfig config) async {}
}
