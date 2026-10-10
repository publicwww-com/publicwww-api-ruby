# PublicWWW API - Ruby

A small client for the [PublicWWW API](https://publicwww.com/docs/api/): search the
source code (HTML, JavaScript, CSS) of hundreds of millions of websites from your
own code. Standard library only, Ruby 2.7+.

## Setup

Issue a token on your [profile page](https://publicwww.com/profile/api) (a paid
plan is required for the API) and keep it in the environment, not in the code:

```sh
export PUBLICWWW_KEY=...
```

## Command line

```sh
bin/publicwww account                          # plan and quota, spends nothing
bin/publicwww search '"angular.min.js"' 20     # one page
bin/publicwww export '"angular.min.js"' > sites.txt   # every url your plan covers
```

## As a library

```ruby
require_relative "lib/publicwww"

pw = PublicWWW::Client.new                         # key from $PUBLICWWW_KEY

page = pw.search('"angular.min.js"', per_page: 20)
puts "#{page['total']} sites match"
page["results"].each { |r| puts [r["rank"], r["domain"], r["url"]].join("\t") }   # rank is nil for unranked sites

# Everything at once, streamed as NDJSON: one search, nothing held in memory.
meta = pw.each_result('"angular.min.js" site:de') { |r| puts r["domain"] }
puts "the plan returned #{meta['returned']} of #{meta['total']}" if meta["truncated"]
```

The query is the usual [PublicWWW syntax](https://publicwww.com/docs/query-syntax/):
`"exact phrase"`, several words for all of them, `-word` to exclude, `site:de`,
`depth:all` for inner pages.

## Clusters

A cluster is a saved list of sites - the results of a search or your own list - to
pull values out of their page source or to combine with other clusters. See
[clusters in the API](https://publicwww.com/docs/api/clusters/).

```sh
bin/publicwww cluster-create --query '"googletagmanager.com/gtm.js"'   # prints id, size, created, name
bin/publicwww extract 12 --presets email,phone > contacts.csv          # the whole cluster, part after part
bin/publicwww extract 12 --regex '/data-site-id="([0-9]+)"/i' > ids.csv
bin/publicwww cluster-combine diff 14 12 --name "new this month"       # also: and, or
bin/publicwww clusters      # and: cluster ID, presets, cluster-rename ID NAME, cluster-delete ID
```

```ruby
gtm = pw.create_cluster(query: '"googletagmanager.com/gtm.js"')      # costs one search
mine = pw.create_cluster(domains: ["example.com", "https://example.org/"], name: "mine")

# Every site, in parts of up to 1000 (following next_offset); spends extraction points.
pw.each_extract_row(gtm["id"], presets: %w[email phone]) do |row|
  emails, phones = row["values"]                     # one array per expression
  puts [row["domain"], emails.join(" "), phones.join(" ")].join("\t")
end

hotjar = pw.create_cluster(query: '"static.hotjar.com"')
both = pw.combine_clusters("and", [gtm["id"], hotjar["id"]])   # "or"; "diff" - the first without the second
pw.each_cluster_domain(both["id"]) { |domain| puts domain }
pw.delete_cluster(hotjar["id"])
```

`cluster_presets` lists the ready-made expressions: email, phone, whatsapp,
telegram, skype, facebook, instagram, twitter, linkedin, gtm, ga4, ua, hotjar,
adsense, bitcoin. Your own `regex:` is a PCRE in slashes; the first group is the
value. `extract` is one part, `next_offset` says where the next one starts. An
account keeps up to 100 clusters (`409 cluster_limit` past that). If the day's
extraction points run out midway, `each_extract_row` raises `extract_quota_exceeded`
with the offset to resume from (`extract ... --offset N`).

## Errors

Any refusal raises `PublicWWW::Error` with `.status` and `.code`, except one: `429 too_many_requests` (more than ten
requests a minute) is waited out using `Retry-After` and the request is repeated.
`429 quota_exceeded` is different - the day's searches are used up, retrying will
not help. All codes: [errors](https://publicwww.com/docs/api/errors/).

`PUBLICWWW_API` overrides the API address if you ever need to.

## See also

- [API documentation](https://publicwww.com/docs/api/)
- [MCP server](https://publicwww.com/docs/mcp/) - the same search for AI assistants:
  `https://api.publicwww.com/mcp`
- The same client in [Python](https://github.com/publicwww-com/publicwww-api-python), [JavaScript](https://github.com/publicwww-com/publicwww-api-javascript), [PHP](https://github.com/publicwww-com/publicwww-api-php), [Go](https://github.com/publicwww-com/publicwww-api-go)

## License

MIT
