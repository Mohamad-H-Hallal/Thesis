const String exportDateHint = 'YYYY-MM-DD';
const String exportBboxHint = 'minLon,minLat,maxLon,maxLat';

String? validateExportDateInput(String label, String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    return null;
  }

  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(trimmed)) {
    return '$label must use $exportDateHint.';
  }

  final parsed = DateTime.tryParse(trimmed);
  if (parsed == null || _formatDate(parsed) != trimmed) {
    return '$label must use a real calendar date in $exportDateHint.';
  }

  return null;
}

String? validateExportDateRange(String fromDate, String toDate) {
  final fromError = validateExportDateInput('From date', fromDate);
  final toError = validateExportDateInput('To date', toDate);
  if (fromError != null || toError != null) {
    return null;
  }

  if (fromDate.trim().isEmpty || toDate.trim().isEmpty) {
    return null;
  }

  final from = DateTime.parse(fromDate.trim());
  final to = DateTime.parse(toDate.trim());
  if (from.isAfter(to)) {
    return 'To date must be the same day or later than From date.';
  }

  return null;
}

String? validateExportBboxInput(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    return null;
  }

  final parts = trimmed.split(',');
  if (parts.length != 4) {
    return 'BBOX must use $exportBboxHint.';
  }

  final numbers = parts.map((part) => double.tryParse(part.trim())).toList();
  if (numbers.any((value) => value == null)) {
    return 'BBOX must use numeric values in $exportBboxHint.';
  }

  final minLon = numbers[0]!;
  final minLat = numbers[1]!;
  final maxLon = numbers[2]!;
  final maxLat = numbers[3]!;

  if (minLon < -180 || maxLon > 180 || minLat < -90 || maxLat > 90) {
    return 'BBOX coordinates must stay within valid longitude and latitude ranges.';
  }

  if (!(minLon < maxLon && minLat < maxLat)) {
    return 'BBOX must keep min values smaller than max values.';
  }

  return null;
}

String _formatDate(DateTime value) {
  final month = value.month.toString().padLeft(2, '0');
  final day = value.day.toString().padLeft(2, '0');
  return '${value.year}-$month-$day';
}
