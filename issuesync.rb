begin
  require 'net/http/persistent'
  require 'time'
  require 'json'
  require 'pathname'
  require 'fileutils'
  require 'cgi'
rescue LoadError
  abort $!.to_s
end

# Downloads GitHub issues & pull requests for the current project to the "issues"
# directory. If downloaded issues already exist, it only fetches new issues/comments.
#
# An issue with comments is stored in Markdown format in a file named "{number}.md".
# A patch file for open pull requests is downloaded to "{number}.patch".
#
# Depends on:
# - net-http-persistent
# - Ruby 1.9
#
# Enable ruby's verbose mode (`RUBYOPT=-w`) to display fetched URLs on stderr.
# Enable debug mode (`RUBYOPT=-d`) to dump in-depth info about each HTTP request.
#
# The rate limit of GitHub's API might not be enough to download all issues for
# a popular project. If such an exception occurs, wait an hour, then start the
# sync again; it will continue where it left off.
class IssueSync
  def self.start(*args)
    new(*args).start
  end

  attr_reader :repo, :path, :api_client

  def initialize repo, path
    @repo = repo
    @path = Pathname.new(path).expand_path
    @api_client = ApiClient.new
  end

  def start
    issue_fetcher = IssueFetcher.new(api_client, Issue)
    comment_fetcher = CommentFetcher.new(api_client, Comment)
    formatter = IssueFormatter.new

    FileUtils.mkdir_p path
    last_updated = Dir.entries(path).grep(/\.md$/).map {|name| (path+name).mtime }.max

    issues = issue_fetcher.call(repo, last_updated)

    for issue in issues
      issue_file = path + "#{issue.number}.md"
      patch_file = path + "#{issue.number}.patch"

      issue_file.open('w') do |file|
        formatter.format(file, issue, comment_fetcher.call(issue))
      end if stale?(issue_file, issue)

      if patch_url = issue.patch_url and issue.open? and stale?(patch_file, issue)
        patch = api_client.get_response patch_url
        patch_file.open('w') {|f| f << patch.body }
      end
    end
  rescue Net::HTTPExceptions => error
    warn "Aborted: GitHub API returned #{error.message}"
    warn error.response.body
    exit 1
  end

  def stale? file, issue
    !file.exist? or file.mtime < issue.updated_at
  end

  class IssueFormatter
    def format(io, issue, comments)
      format_body(io, issue)
      for comment in comments
        format_comment(io, comment)
      end
    end

    def format_body(io, issue)
      title = "##{issue.number}: #{issue.title.strip} "
      for label in issue.labels
        title << " [#{label}]"
      end
      title << " [CLOSED]" if issue.closed?
      title = title.strip

      io.puts title
      io.puts "=" * title.size
      io.puts
      io.puts "## #{issue.user}"
      io.puts
      io.puts issue.body
    end

    def format_comment(io, comment)
      io.puts
      io.puts "## #{comment.user}"
      io.puts
      io.puts comment.body
    end
  end

  IssueFetcher = Struct.new(:api_client, :data_class) do
    def raw_issues(repo, state, since)
      path = "/repos/#{repo}/issues?state=#{state}&sort=updated"
      path << "&since=#{since.utc.iso8601}" if since.respond_to? :utc
      api_client.get path
    end

    def issues(repo, state, since)
      raw_issues(repo, state, since).map {|entry| data_class.new entry }
    end

    def call(repo, since = nil)
      issues(repo, 'open', since) + issues(repo, 'closed', since)
    end
  end

  CommentFetcher = Struct.new(:api_client, :data_class) do
    def raw_comments issue
      api_client.get issue.comments_url
    end

    def call issue
      if issue.has_comments?
        raw_comments(issue).map {|entry| data_class.new entry }
      else
        []
      end
    end
  end

  class ApiClient
    def base_uri() URI 'https://api.github.com' end

    def auth_token() ENV['GITHUB_TOKEN'] end

    def proxy_uri
      no_proxy = get_env('no_proxy')
      return if no_proxy == '*'

      if proxy = get_env('https_proxy') || get_env('all_proxy')
        proxy = "http://#{proxy}" unless proxy =~ /^https?:/
        proxy += "?no_proxy=#{CGI.escape no_proxy}" if no_proxy
        URI proxy
      end
    end

    def get_env key
      val = ENV[key]
      if val && !val.empty?
        val
      elsif key !~ /[A-Z]/
        get_env key.upcase
      end
    end

    def http
      @http ||= begin
        conn = Net::HTTP::Persistent.new name: self.class.name, proxy: proxy_uri
        conn.debug_output = $stderr if $DEBUG
        conn
      end
    end

    def headers(host)
      all = {
        'Accept' => 'application/vnd.github.v3.raw+json',
      }
      if host == base_uri.host && !auth_token.to_s.empty?
        all['Authorization'] = "token #{auth_token}"
      end
      all
    end

    def get path
      data = nil
      uri  = base_uri + path

      while uri
        res  = get_response uri
        data = data ? data.concat(res.data) : res.data
        uri  = res.next_url
      end

      data
    end

    def get_response uri
      req = Net::HTTP::Get.new uri.request_uri, headers(uri.host)
      $stderr.puts "GET #{uri}" if $VERBOSE
      res = ApiResponse.new http.request(uri, req)

      if res.redirect?
        get_response uri + res.redirect_location
      elsif !res.success?
        res.response.error!
      else
        if $VERBOSE && uri.host == base_uri.host
          $stderr.puts "ratelimit remaining: %d" % res.ratelimit_remaining
        end
        res
      end
    end

    ApiResponse = Struct.new(:response) do
      def body() response.body end

      def success?() Net::HTTPSuccess === response end

      def redirect?() Net::HTTPRedirection === response end

      def redirect_location
        response['location']
      end

      def data
        @data ||= JSON.parse body
      end

      def links
        response['link'].to_s.
          scan(/<(.+?)>; rel="(.+?)"/).
          each_with_object({}) {|(url, type), all| all[type] = url }
      end

      def ratelimit_remaining
        response['x-ratelimit-remaining'].to_i
      end

      def next_url
        if rel_next = links['next']
          URI rel_next
        end
      end
    end
  end

  Issue = Struct.new(:data) do
    def number() data['number'] end
    def title() data['title'] end
    def body() data['body'].to_s.strip.gsub("\r\n", "\n") end
    def user() data['user']['login'] end
    def comments_url() URI(data['url'] + '/') + 'comments' end
    def patch_url
      pr = data['pull_request']
      url = pr && pr['patch_url'] and URI(url)
    end
    def updated_at() Time.parse(data['updated_at']) end
    def has_comments?() !data['comments'].zero? end
    def open?() data['state'] == 'open' end
    def closed?() !open? end
    def labels() data['labels'].map {|x| x['name']} end
  end

  class Comment < Issue
    def body
      super.
        gsub(/^[> ]*On .+?<reply@reply\.github\.com>[>\s]+wrote:[>\s]*(\n|\Z)/m, '').
        gsub(/^(>+\n)?>+ --\n>+ Reply to this email .+?https:\/\/github\.com\/.+?(\n|\Z)/m, '')
    end
  end
end

if __FILE__ == $0
  remotes = `git remote`.lines
  remote_urls = remotes.map {|remote| `git remote get-url #{remote}` }
  remote_urls.find {|rem| %r{github\.com[:/](.+?)/(.+?)(\.git)?$} =~ rem }
  repo_with_owner = "#$1/#$2" if $1
  abort "no GitHub repo found among git remotes" if repo_with_owner.nil?

  IssueSync.start(repo_with_owner, 'issues')
end
