import 'dart:io';

double _parseLineCoverage(String lcovPath) {
  final file = File(lcovPath);
  if (!file.existsSync()) {
    throw StateError('Coverage file not found at $lcovPath');
  }

  final lines = file.readAsLinesSync();
  var lf = 0;
  var lh = 0;

  for (final line in lines) {
    if (line.startsWith('LF:')) {
      lf += int.tryParse(line.substring(3)) ?? 0;
      continue;
    }
    if (line.startsWith('LH:')) {
      lh += int.tryParse(line.substring(3)) ?? 0;
    }
  }

  if (lf == 0) {
    throw StateError('Invalid LCOV file: total executable lines (LF) is 0');
  }

  return (lh / lf) * 100;
}

void main(List<String> args) {
  var minLineCoverage = 20.0;
  var lcovPath = 'coverage/lcov.info';

  for (var i = 0; i < args.length; i += 1) {
    final arg = args[i];
    if (arg == '--min-line' && i + 1 < args.length) {
      minLineCoverage = double.parse(args[i + 1]);
      i += 1;
      continue;
    }
    if (arg == '--lcov' && i + 1 < args.length) {
      lcovPath = args[i + 1];
      i += 1;
    }
  }

  final lineCoverage = _parseLineCoverage(lcovPath);
  final rounded = lineCoverage.toStringAsFixed(2);

  stdout.writeln('Line coverage: $rounded%');
  stdout.writeln('Required minimum: ${minLineCoverage.toStringAsFixed(2)}%');

  if (lineCoverage < minLineCoverage) {
    stderr.writeln(
      'Coverage gate failed: line coverage $rounded% is below minimum '
      '${minLineCoverage.toStringAsFixed(2)}%',
    );
    exitCode = 1;
    return;
  }

  stdout.writeln('Coverage gate passed.');
}
