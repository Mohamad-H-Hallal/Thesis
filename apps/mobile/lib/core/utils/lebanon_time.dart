import 'package:timezone/data/latest.dart' as timezone_data;
import 'package:timezone/timezone.dart' as timezone;

const String lebanonTimeZoneName = 'Asia/Beirut';

bool _timeZonesInitialized = false;

timezone.Location _lebanonLocation() {
  if (!_timeZonesInitialized) {
    timezone_data.initializeTimeZones();
    _timeZonesInitialized = true;
  }
  return timezone.getLocation(lebanonTimeZoneName);
}

timezone.TZDateTime toLebanonTime(DateTime value) {
  return timezone.TZDateTime.from(value, _lebanonLocation());
}

String formatLebanonDateTime(DateTime value) {
  final local = toLebanonTime(value);
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '${local.year}-$month-$day $hour:$minute';
}

String formatLebanonTime(DateTime value) {
  final local = toLebanonTime(value);
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}

String formatLebanonDate(DateTime? value) {
  if (value == null) {
    return 'Not set';
  }
  final local = toLebanonTime(value);
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  return '${local.year}-$month-$day';
}
