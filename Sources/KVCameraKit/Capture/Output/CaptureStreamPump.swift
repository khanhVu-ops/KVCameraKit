import Foundation

/// Carries segments from the writer to the host's sink, in order, without blocking the
/// writer.
///
/// Two mismatches to bridge, and getting either wrong is silent. `AVAssetWriterDelegate`
/// hands over segments synchronously on a queue that must not be held up — a real-time
/// encoder that is made to wait drops what it could not deliver, and the file simply plays
/// fast. The sink is `async` and may be slow: encrypting and appending a segment is disk
/// work. So segments are enqueued without waiting and consumed by one task.
///
/// **Order is the whole contract.** The first segment is the initialization segment and the
/// rest are meaningless without it, in sequence — so this is one consumer over a FIFO, never
/// a task per segment.
final class CaptureStreamPump: Sendable {

    private let continuation: AsyncStream<Data>.Continuation
    /// Returns the first failure, once every segment enqueued before `finish()` has been
    /// offered to the sink.
    private let consumer: Task<Error?, Never>

    init(sink: any CaptureVideoSink) {
        // Unbounded, and that is a measured choice rather than optimism: sealing a segment is
        // memory-speed work against a source producing a few megabytes a second, so the queue
        // is empty in the steady state. Bounding it would mean deciding what to do when it
        // filled, and both answers are worse — blocking stalls the encoder, dropping
        // corrupts the file.
        var escaped: AsyncStream<Data>.Continuation!
        let stream = AsyncStream<Data>(bufferingPolicy: .unbounded) { escaped = $0 }
        continuation = escaped

        consumer = Task {
            var failure: Error?
            for await chunk in stream {
                // After a failure the recording is already lost, but the stream is still
                // drained rather than left buffered: the alternative is holding every
                // remaining segment in memory until the writer is torn down.
                guard failure == nil else { continue }
                do {
                    try await sink.write(chunk)
                } catch {
                    failure = error
                }
            }
            return failure
        }
    }

    /// Called on whichever queue the writer delivered the segment on. Never blocks.
    func enqueue(_ chunk: Data) {
        continuation.yield(chunk)
    }

    /// Waits for every enqueued segment to reach the sink, and reports the first failure.
    ///
    /// Awaiting the drain is not optional: the last segment is delivered during
    /// `finishWriting`, so returning before it has been written would commit a recording
    /// missing its own ending.
    func finish() async -> Error? {
        continuation.finish()
        return await consumer.value
    }
}
