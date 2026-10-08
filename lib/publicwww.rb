# A small client for the PublicWWW API - https://publicwww.com/docs/api/
# Ruby 2.7+, standard library only.
#
#   require_relative "lib/publicwww"
#   pw = PublicWWW::Client.new                  # key from $PUBLICWWW_KEY
#   page = pw.search('"angular.min.js"', per_page: 20)
#   pw.each_result('"angular.min.js"') { |row| puts row["domain"] }

require "json"
require "net/http"
require "uri"

module PublicWWW
  USER_AGENT = "publicwww-api-ruby/1.0"

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

    # Plan, quota and limits. Spends nothing.
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

    private

    # GET a path and hand the 200 response to the block. Waits out the rate
    # limit; any other error is raised.
    def get(path, params = {})
      uri = URI(@api + path)
      uri.query = URI.encode_www_form(params) unless params.empty?
      loop do
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", read_timeout: 600) do |http|
          req = Net::HTTP::Get.new(uri)
          req["Authorization"] = "Bearer #{@key}"
          req["User-Agent"] = USER_AGENT
          http.request(req) do |res|
            return yield(res) if res.code == "200"

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
