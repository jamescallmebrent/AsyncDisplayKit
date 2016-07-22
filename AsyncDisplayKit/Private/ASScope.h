
#define weakify(var) __weak __typeof__(var) ASWeak_##var = var;

#define strongify(var) \
  _Pragma("clang diagnostic push") \
  _Pragma("clang diagnostic ignored \"-Wshadow\"") \
  __strong __typeof__(var) var = ASWeak_##var; \
  _Pragma("clang diagnostic pop")

#define strongifyOrExit(var) \
  strongify(var); \
  if (var == nil) { return; }
