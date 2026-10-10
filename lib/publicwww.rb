# A small client for the PublicWWW API - https://publicwww.com/docs/api/
# Ruby 2.7+, standard library only.
#
#   require_relative "lib/publicwww"
#   pw = PublicWWW::Client.new                  # key from $PUBLICWWW_KEY
#   page = pw.search('"angular.min.js"', per_page: 20)
#   pw.each_result('"angular.min.js"') { |row| puts row["domain"] }
#
#   c = pw.create_cluster(query: '"googletagmanager.com/gtm.js"')
#   pw.each_extract_row(c["id"], presets: %w[email phone]) { |row| p row }

require "json"
require "net/http"
require "uri"

module PublicWWW
  USER_AGENT = "publicwww-api-ruby/1.1"

  # An error answer from the API.
  class Error < StandardError
    attr_reader :status, :code

    def initialize(status, code, message)
      super("#{status} #{code}: #{message}")
      @status = status
      @code = code
    end
  end

  class Client
    def initialize(key: ENV["PUBLICWWW_KEY"], api: ENV["PUBLICWWW_API"] || "https://api.publicwww.com")
      raise Error.new(0, "missing_key", "set PUBLICWWW_KEY or pass key:") if key.nil? || key.empty?
      @key = key
      @api = api.chomp("/")
    end

    # Plan, quota and limits, clusters included. Spends nothing.
    def account
      get("/v1/account") { |res| JSON.parse(res.body) }
    end

    # One page of results: total, total_pages, truncated, results, ...
    def search(query, page: 1, per_page: 100, **params)
      get("/v1/search", params.merge(query: query, page: page, per_page: per_page)) { |res| JSON.parse(res.body) }
    end

    # Every row of a query your plan covers, streamed as NDJSON: one search,
    # nothing held in memory. per_page defaults to the plan's max_per_page
    # (asking for more is a 400 per_page_too_large). Returns the metadata line
    # (total, returned, truncated).
    def each_result(query, per_page: nil, **params)
      per_page ||= account["limits"]["max_per_page"]
      meta = nil
      get("/v1/search", params.merge(query: query, per_page: per_page, format: "ndjson")) do |res|
        buf = +""
        emit = lambda do |line|
          next if line.strip.empty?
          obj = JSON.parse(line)
          if obj["object"] == "meta" then meta = obj   # the first line
          else yield obj
          end
        end
        res.read_body do |chunk|
          buf << chunk
          while (i = buf.index("\n"))
            emit.call(buf.slice!(0..i))
          end
        end
        emit.call(buf)
      end
      meta
    end

    # ---- clusters: saved lists of sites, to extract data from or combine ----

    # The account's clusters, newest first: count, max, clusters (id, name,
    # size, created).
    def clusters
      json("/v1/clusters")
    end

    # One cluster and a page of its domains (per_page up to 10000).
    def cluster(id, page: 1, per_page: 1000)
      json("/v1/clusters/#{Integer(id)}", params: { page: page, per_page: per_page })
    end

    # Every domain of a cluster, page after page.
    def each_cluster_domain(id, per_page: 10_000, &block)
      page = 1
      loop do
        res = cluster(id, page: page, per_page: per_page)
        res["domains"].each(&block)
        break if page >= res["total_pages"]
        page += 1
      end
    end

    # A new cluster from a search (query:, costs one search like #search) or
    # from a list of domains or urls (domains:; only sites in the index are
    # kept). 409 cluster_limit when the account has 100.
    def create_cluster(query: nil, domains: nil, name: nil)
      body = query ? { query: query } : { domains: Array(domains) }
      body[:name] = name if name
      json("/v1/clusters", body: body)
    end

    # A new cluster: "and" - domains in every cluster, "or" - in any, "diff" -
    # in the first but not in the second (exactly two).
    def combine_clusters(operation, ids, name: nil)
      body = { operation: operation, clusters: ids.map { |i| Integer(i) } }
      body[:name] = name if name
      json("/v1/clusters/combine", body: body)
    end

    # Ready-made extraction expressions: presets (name, regex, about).
    def cluster_presets
      json("/v1/clusters/presets")
    end

    # One part of an extraction: domains [offset, offset + limit) of the
    # cluster (limit up to 1000). presets are names ("email", "phone", ...),
    # regex your own PCRE in slashes, the first group is the value. The answer
    # has rows (domain, values - one array per expression, matches) and
    # next_offset, nil when the cluster is done. Costs extraction points.
    def extract(id, presets: [], regex: [], offset: 0, limit: 1000, skip_empty: true)
      json("/v1/clusters/#{Integer(id)}/extract",
           body: { presets: presets, regex: regex, offset: offset, limit: limit, skip_empty: skip_empty })
    end

    # Every row of an extraction over the whole cluster from offset on, part
    # after part (following next_offset). Returns the last part without its rows (regex,
    # points_left, ...). If the day's extraction points run out midway, raises
    # Error extract_quota_exceeded; its message says the offset to resume from.
    def each_extract_row(id, presets: [], regex: [], offset: 0, limit: 1000, skip_empty: true, &block)
      loop do
        part = extract(id, presets: presets, regex: regex, offset: offset, limit: limit, skip_empty: skip_empty)
        part.delete("rows").each(&block)
        if part["stopped"] == "extract_quota_exceeded"
          raise Error.new(429, "extract_quota_exceeded",
                          "the day's extraction points ran out; resume with offset=#{part['next_offset']}")
        end
        offset = part["next_offset"]
        return part if offset.nil?
      end
    end

    def rename_cluster(id, name)
      json("/v1/clusters/#{Integer(id)}/rename", body: { name: name })
    end

    # Deletes the cluster for good: deleted (the id), name.
    def delete_cluster(id)
      json("/v1/clusters/#{Integer(id)}/delete", body: {})
    end

    private

    def json(path, params: {}, body: nil)
      get(path, params, body) { |res| JSON.parse(res.body) }
    end

    # GET a path - or POST body as JSON when it is given - and hand the 2xx
    # response to the block. Waits out the rate limit; any other error is
    # raised.
    def get(path, params = {}, body = nil)
      uri = URI(@api + path)
      uri.query = URI.encode_www_form(params) unless params.empty?
      loop do
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", read_timeout: 600) do |http|
          req = body.nil? ? Net::HTTP::Get.new(uri) : Net::HTTP::Post.new(uri)
          req["Authorization"] = "Bearer #{@key}"
          req["User-Agent"] = USER_AGENT
          unless body.nil?
            req["Content-Type"] = "application/json"
            req.body = JSON.generate(body)
          end
          http.request(req) do |res|
            return yield(res) if res.is_a?(Net::HTTPSuccess)

            err = (JSON.parse(res.body)["error"] rescue nil) || {}
            # Two different 429s: too_many_requests means "slow down and
            # repeat", quota_exceeded means "come back tomorrow".
            if res.code == "429" && err["code"] == "too_many_requests"
              sleep((res["Retry-After"] || err["retry_after"] || 10).to_i)
            else
              raise Error.new(res.code.to_i, err["code"] || "http_error", err["message"] || res.message)
            end
          end
        end
      end
    end
  end
end
