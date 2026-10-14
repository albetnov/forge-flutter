/// The lifecycle state of a read.
///
/// A read starts [idle], moves to [loading] while a fetch is in flight and then
/// settles on [success] or [error]. It never returns to [idle]: firing a second
/// read after the first one settled goes through [loading] again, which is what
/// makes `AsyncValueLoading(previous: ...)` possible.
enum QueryStatus {
  /// Nothing has been requested yet.
  idle,

  /// A fetch is in flight.
  ///
  /// The read may already hold data from an earlier fetch; the companion
  /// signals distinguish a first load from a refresh.
  loading,

  /// The last fetch resolved successfully.
  success,

  /// The last fetch failed.
  error,
}

/// The lifecycle state of a write.
///
/// A write starts [idle], moves to [pending] while it is in flight and then
/// settles on [success] or [error]. [pending] is the write's counterpart of
/// [QueryStatus.loading].
enum MutationStatus {
  /// Nothing has been submitted yet.
  idle,

  /// The write is in flight.
  pending,

  /// The write succeeded.
  success,

  /// The write failed.
  error,
}
