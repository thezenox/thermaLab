// Keeps docs/ in step with the code (see AGENTS.md). Fails when a source
// file is missing from docs/architecture.md, or when the docs name a path or
// identifier that no longer exists.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source folders whose files must each be named in docs/architecture.md.
const List<String> _mappedDirs = <String>[
  'lib',
  'android/app/src/main/kotlin',
  'assets/web',
];
const Set<String> _mappedExtensions = <String>{'.dart', '.kt', '.html'};

/// Folders searched when a doc names a file without its folder.
const List<String> _searchDirs = <String>[
  'lib',
  'test',
  'docs',
  'tools',
  'assets',
  'android/app/src',
  'packages/flutter_ffi_uvc',
];

/// Paths that are documented but rightly absent from the repository.
const Set<String> _allowedMissing = <String>{
  'android/key.properties', // created by the developer, ignored by git
};

const List<String> _repoRoots = <String>[
  'lib/',
  'test/',
  'docs/',
  'tools/',
  'assets/',
  'android/',
  'packages/',
];

List<File> _docFiles() => <File>[
      File('AGENTS.md'),
      ...Directory('docs')
          .listSync()
          .whereType<File>()
          .where((File f) => f.path.endsWith('.md')),
    ];

String _ext(String path) {
  final int dot = path.lastIndexOf('.');
  return dot < 0 ? '' : path.substring(dot);
}

String _basename(String path) => path.split(RegExp(r'[/\\]')).last;

Iterable<File> _filesIn(String dir) => Directory(dir)
    .listSync(recursive: true)
    .whereType<File>()
    // Skip build output and other generated folders inside packages.
    .where((File f) => !f.path.contains(RegExp(r'[/\\](build|\.cxx|\.dart_tool)[/\\]')));

Iterable<String> _codeSpans(String text) =>
    RegExp(r'`([^`\n]+)`').allMatches(text).map((Match m) => m.group(1)!);

void main() {
  test('every source file is named in docs/architecture.md', () {
    final String map = File('docs/architecture.md').readAsStringSync();
    final List<String> missing = <String>[
      for (final String dir in _mappedDirs)
        for (final File f in _filesIn(dir))
          if (_mappedExtensions.contains(_ext(f.path)) &&
              !map.contains(_basename(f.path)))
            f.path,
    ];
    expect(missing, isEmpty,
        reason: 'Add these files to the table in docs/architecture.md');
  });

  test('paths named in the docs exist', () {
    final Set<String> knownNames = <String>{
      for (final String dir in _searchDirs)
        if (Directory(dir).existsSync())
          for (final File f in _filesIn(dir)) _basename(f.path),
      for (final FileSystemEntity e in Directory('.').listSync())
        _basename(e.path),
    };
    final List<String> broken = <String>[];
    for (final File doc in _docFiles()) {
      final String text = doc.readAsStringSync();
      for (final String span in _codeSpans(text)) {
        if (span.contains(' ') || span.contains('…')) continue;
        if (_allowedMissing.contains(span)) continue;
        final String path = span.replaceAll(RegExp(r'\(\)$'), '');
        if (_repoRoots.any(path.startsWith)) {
          final bool exists = path.endsWith('/')
              ? Directory(path).existsSync()
              : File(path).existsSync() || Directory(path).existsSync();
          if (!exists) broken.add('${doc.path}: $span');
        } else if (!path.contains('/') &&
            RegExp(r'\.(dart|kt|py|md|html)$').hasMatch(path) &&
            !knownNames.contains(path)) {
          broken.add('${doc.path}: $span');
        }
      }
      // Relative markdown links, e.g. [Cameras](cameras.md#both).
      for (final Match m in RegExp(r'\]\(([^)\s]+)\)').allMatches(text)) {
        final String target = m.group(1)!.split('#').first;
        if (target.isEmpty || target.contains('://')) continue;
        final String resolved = '${doc.parent.path}/$target';
        if (!File(resolved).existsSync() && !Directory(resolved).existsSync()) {
          broken.add('${doc.path}: link $target');
        }
      }
    }
    expect(broken, isEmpty, reason: 'Fix or remove these references');
  });

  test('class and function names in the docs exist in the code', () {
    final String source = <String>[
      for (final String dir in <String>['lib', 'android/app/src/main/kotlin'])
        for (final File f in _filesIn(dir))
          if (f.path.endsWith('.dart') || f.path.endsWith('.kt'))
            f.readAsStringSync(),
    ].join('\n');
    final List<String> unknown = <String>[];
    for (final File doc in _docFiles()) {
      for (final String span in _codeSpans(doc.readAsStringSync())) {
        // CamelCase type names (ProbeController) and calls (buildScene()).
        final RegExpMatch? m =
            RegExp(r'^([A-Z][A-Za-z0-9]+|[a-z][A-Za-z0-9]*\(\))$')
                .firstMatch(span);
        if (m == null) continue;
        final String name = span.replaceAll('()', '');
        if (!RegExp('\\b${RegExp.escape(name)}\\b').hasMatch(source)) {
          unknown.add('${doc.path}: $span');
        }
      }
    }
    expect(unknown, isEmpty, reason: 'Renamed or removed in the code?');
  });
}
