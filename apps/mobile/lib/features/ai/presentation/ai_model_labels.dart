String formatModelName(String? value) {
  final text = value?.trim();
  if (text == null || text.isEmpty) {
    return 'Not recorded';
  }
  final normalized = text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');
  switch (normalized) {
    case 'rf':
    case 'random_forest':
      return 'Random Forest';
    case 'svm':
    case 'svm_rbf':
    case 'support_vector_machine':
      return 'Support Vector Machine';
    case 'gb':
    case 'gradient_boost':
    case 'gradient_boosting':
    case 'gradient_tree_boost':
      return 'Gradient Boosting';
    case 'xgb':
    case 'xgboost':
      return 'Extreme Gradient Boosting';
    case 'nn':
    case 'neural':
    case 'neural_network':
      return 'Neural Network';
    case 'auto':
      return 'Auto';
    default:
      return _titleCase(text.replaceAll('_', ' '));
  }
}

String _titleCase(String value) {
  return value
      .split(RegExp(r'\s+'))
      .where((word) => word.isNotEmpty)
      .map(
        (word) => word.length == 1
            ? word.toUpperCase()
            : '${word.substring(0, 1).toUpperCase()}${word.substring(1)}',
      )
      .join(' ');
}
