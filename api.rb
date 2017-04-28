require 'bundler/setup'
%w(yaml json csv digest).each { |req| require req }
Bundler.require(:default)
require 'sinatra'
require_relative 'models/models'

# feature flag: toggle redis
$use_redis = true

$config = YAML::load_file(File.join(__dir__, ENV['RACK_ENV'] == 'test' ? 'test_config.yaml' : 'config.yaml'))

$redis = Redis.new host: ENV.fetch('REDIS_PORT_6379_TCP_ADDR', 'localhost'),
                   port: ENV.fetch('REDIS_PORT_6379_TCP_PORT', 6379)

ActiveSupport::Deprecation.silenced = true
ActiveRecord::Base.establish_connection($config['db']['fb'])

class API < Sinatra::Application
  before do
    $route = request.path

    # set headers
    headers 'Content-Type' => 'application/json; charset=utf8'
    headers 'Access-Control-Allow-Methods' => 'HEAD, GET'
    headers 'Access-Control-Allow-Origin' => '*'
    cache_control :public, :must_revalidate, max_age: 60

    # prevent certain verbs
    if request.request_method != 'GET'
      halt 405
    end

    # use redis caching
    if $config['caching'] && $use_redis
      if request.path_info != "/"
        @cache_key = Digest::MD5.hexdigest(request.url)
        if $redis.exists(@cache_key)
          headers 'Cache-Hit' => 'true'
          halt 200, $redis.get(@cache_key)
        end
      end
    end

    # set correct db connection
    @slb_or_fb = request.script_name == '/sealifebase' ? 'slb' : 'fb'
    ActiveRecord::Base.establish_connection($config['db'][@slb_or_fb])
  end

  after do
    # cache response in redis
    if $config['caching'] &&
      $use_redis &&
      !response.headers['Cache-Hit'] &&
      response.status == 200 &&
      request.path_info != "/" &&
      request.path_info != ""

      $redis.set(@cache_key, response.body[0], ex: $config['caching']['expires'])
    end
  end

  configure do
    mime_type :apidocs, 'text/html'
  end

  # handle missed route
  not_found do
    halt 404, { error: 'route not found' }.to_json
  end

  # handle other errors
  error do
    halt 500, { error: 'server error' }.to_json
  end

  # handler - redirects any /foo -> /foo/
  #  - if has any query params, passes to handler as before
  get %r{(/.*[^\/])$} do
    if request.query_string == "" or request.query_string.nil?
      redirect request.script_name + "#{params[:captures].first}/"
    else
      pass
    end
  end

  # default to landing page
  ## used to go to /heartbeat
  get '/?' do
    @slb_or_fb = request.script_name == '/sealifebase' ? '/index_sb.html' : '/index.html'
    content_type :apidocs
    send_file File.join(settings.public_folder, @slb_or_fb)
  end

  # route listing route
  get '/heartbeat/?' do
    db_routes = Models.models.map do |m|
      "/#{m.downcase}#{Models.const_get(m).primary_key ? '/:id' : '' }?<params>"
    end
    { routes: %w( /docs/:table? /heartbeat /mysqlping /listfields ) + db_routes }.to_json
  end

  # docs route
  get '/docs/?:table?/?' do
    table = params[:table] || 'tables'
    filename = "docs/docs-sources/#{table}.csv"
    halt not_found unless File.exists?(filename)
    hash = CSV.new(File.read(filename), headers: true).map { |row| row.to_hash }
    { count: hash.length, returned: hash.length, data: hash, error: nil }.to_json
  end

  # db status route
  get '/mysqlping/?' do
    {
        mysql_server_up: true,
        mysql_host: $config['db'][@slb_or_fb]['host']
    }.to_json
  end

  # list fields route
  get '/listfields/?' do
    fields, exact = params[:fields], params[:exact]
    data = Models.list_fields($config['db'][@slb_or_fb]['database'])
    unless fields.nil?
      fields = fields.gsub(',', '|')
      fields = fields.split('|').map { |field| "^#{field}$" }.join('|') if exact
      data.keep_if { |a| a[:column_name].match(fields) }
    end
    { count: data.length, returned: data.length, data: data, error: nil }.to_json
  end

  # generate routes from the models
  Models.models.each do |model_name|
    model = Models.const_get(model_name)
    get "/#{model_name.to_s.downcase}/?#{model.primary_key ? ':id?/?' : '' }" do
      begin
        data = model.endpoint(params)
        raise Exception.new('no results found') if data.length.zero?
        { count: data.limit(nil).count(1), returned: data.length, data: data, error: nil }.to_json
      rescue Exception => e
        halt 400, { count: 0, returned: 0, data: nil, error: { message: e.message }}.to_json
      end
    end
  end
end
