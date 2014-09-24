require 'sinatra'
require 'json'
require 'yaml'

CONFIG_PATH = File.join __dir__, 'ci-deploys.json'

class ApiKeys
  class << self
    attr_writer :keys

    def keys
      @keys ||= {}
    end

    def load(h)
      keys.merge(h)
      h.each do |k,v|
        ENV[k.to_s] = v.to_s
      end
    end
  end
end

class ConfigManager
  class << self
    def load_or_init_config
      unless File.exist?(CONFIG_PATH)
        open(CONFIG_PATH, 'w') {|f| f.write '{}' }
        reset_config
      end

      reload_config
    end

    def reload_config
      @config = JSON.parse(IO.read CONFIG_PATH)
    end

    def save_config
      open(CONFIG_PATH, 'w') {|f| f.write JSON.pretty_unparse(@config)}
    end

    def reset_config
      if File.exist?('secrets.yml')
        @config = YAML.load(IO.read 'secrets.yml')["heroku_apps"].each_with_object({}) {|v,h| h[v] = ""}
      else
        @config = {}
        if ENV['DEPLOY_URLS']
          ENV['DEPLOY_URLS'].split(',').each_with_object({}) {|v,h| h[v] = ""}
        end
      end

      save_config
      @config
    end

    def update_config(app, branch)
      @config[app] = branch
      save_config
    end

    def next_available_heroku_app(branch)
      @config.keys.find { |k| @config[k] == branch } ||
        @config.keys.find { |k| @config[k].empty? }
    end

    def release_app_for_branch(branch)
      app_name = @config.keys.find { |k| @config[k] == branch }
      if app_name
        update_config(app_name, "")
      else
        puts "Tried to release app for branch #{branch}, but none associated. Ignoring"
      end
    end

    def config
      @config ||= load_or_init_config
    end
  end
end

configure do
  if File.exist? 'secrets.yml'
    ApiKeys.load YAML.load open('secrets.yml').read
  end

  ConfigManager.load_or_init_config
end

get '/reserve_next_app/:branch' do
  content_type :json

  next_app = ConfigManager.next_available_heroku_app(params[:branch])

  if next_app
    ConfigManager.update_config(next_app, params[:branch])
    { success: true, app: next_app }.to_json
  else
    { success: false, message: "No available apps" }.to_json
  end
end

get '/config' do
  content_type :json
  ConfigManager.config.to_json
end

get '/reset_config/:password' do
  content_type :json
  if params[:password] == ENV['RESET_PASSWORD']
    ConfigManager.reset_config

    status 200
    ConfigManager.config.to_json
  else
    status 401
    {nope: "wrong"}.to_json
  end
end

post '/pr_webhook' do
  data = JSON.parse(request.body.read)
  if data['action'] == 'closed'
    puts "Detected PR closed: #{data['number']}"
    ConfigManager.release_app_for_branch(data['pull_request']['head']['ref'])
  end
end
