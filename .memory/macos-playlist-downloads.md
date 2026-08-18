# macOS provider playlist downloads

- YouTube playlist parsing carries a source-row position cursor across continuation pages. Fallback positions advance for every legacy or lockup row, including unavailable and duplicate rows; explicit indices are normalized against the cursor so page-local or backward values cannot reorder tracks. The service carries the parser's last position independently of deduplication and the 500-track output cap.
