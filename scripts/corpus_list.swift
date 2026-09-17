// corpus_list — prints SteadyHeartBeat's spoken vocabulary as `id|text`, one
// clip per line, straight from Corpus.swift.
//
// The offline renderer works from the SHIPPED manifest by default, which cannot
// contain a phrase that was only just added to Corpus.swift. When the vocabulary
// changes, generate the work list from source instead, and feed it to the
// renderer:
//
//   swiftc -parse-as-library scripts/corpus_list.swift ios/Runner/Kokoro/Corpus.swift -o /tmp/corpus_list
//   /tmp/corpus_list > /tmp/corpus.txt

@main
enum CorpusList {
    static func main() {
        for item in Corpus.all() { print("\(item.id)|\(item.text)") }
    }
}
