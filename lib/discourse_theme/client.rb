# frozen_string_literal: true
module DiscourseTheme
  class Client
    THEME_CREATOR_REGEX = /^https:\/\/theme-creator.discourse.org$/i

    def initialize(dir, settings, reset:)
      @reset = reset
      @url = guess_url(settings)
      @api_key = guess_api_key(settings)

      raise "Missing site to synchronize with!" if !@url
      raise "Missing api key!" if !@api_key

      @is_theme_creator = !!(THEME_CREATOR_REGEX =~ @url)

      if !self.class.has_needed_version?(discourse_version, "2.3.0.beta1")
        UI.info "discourse_theme is designed for Discourse 2.3.0.beta1 or above"
        UI.info "download will not function, and syncing destination will be unpredictable"
      end
    end

    # From https://github.com/discourse/discourse/blob/master/lib/version.rb
    def self.has_needed_version?(current, needed)
      current_split = current.split('.')
      needed_split = needed.split('.')

      (0..[current_split.size, needed_split.size].max).each do |idx|
        current_str = current_split[idx] || ''

        c0 = (needed_split[idx] || '').sub('beta', '').to_i
        c1 = (current_str || '').sub('beta', '').to_i

        # beta is less than stable
        return false if current_str.include?('beta') && (c0 == 0) && (c1 > 0)

        return true if c1 > c0
        return false if c0 > c1
      end

      true
    end

    def get_themes_list
      endpoint = root +
        if @is_theme_creator
          "/user_themes.json"
        else
          "/admin/customize/themes.json"
        end

      response = request(Net::HTTP::Get.new(endpoint), never_404: true)
      json = JSON.parse(response.body)
      @is_theme_creator ? json["user_themes"] : json["themes"]
    end

    def get_raw_theme_export(id)
      endpoint = root +
        if @is_theme_creator
          "/user_themes/#{id}/export"
        else
          "/admin/customize/themes/#{id}/export"
        end

      response = request(Net::HTTP::Get.new endpoint)
      raise "Error downloading theme: #{response.code}" unless response.code.to_i == 200
      raise "Error downloading theme: no content disposition" unless response["content-disposition"]
      [response.body, response["content-disposition"].match(/filename=(\"?)(.+)\1/)[2]]
    end

    def update_theme(id, args)
      endpoint = root +
        if @is_theme_creator
          "/user_themes/#{id}"
        else
          "/admin/themes/#{id}"
        end

      put = Net::HTTP::Put.new(endpoint, 'Content-Type' => 'application/json')
      put.body = args.to_json
      request(put)
    end

    def upload_full_theme(tgz, theme_id:, components:)
      endpoint = root +
        if @is_theme_creator
          "/user_themes/import.json"
        else
          "/admin/themes/import.json"
        end

      post = Net::HTTP::Post::Multipart.new(
        endpoint,
        "theme_id" => theme_id,
        "components" => components,
        "bundle" => UploadIO.new(tgz, "application/tar+gzip", "bundle.tar.gz")
      )
      request(post)
    end

    def discourse_version
      endpoint = "#{root}/about.json"
      response = request(Net::HTTP::Get.new(endpoint), never_404: true)
      json = JSON.parse(response.body)
      json["about"]["version"]
    end

    def root
      URI.parse(@url).path
    end

    def is_theme_creator
      @is_theme_creator
    end

    private

    def request(request, never_404: false)
      uri = URI.parse(@url)

      if uri.userinfo
        username, password = uri.userinfo.split(":", 2)
        request.basic_auth username, password
      end

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = URI::HTTPS === uri
      add_headers(request)
      http.request(request).tap do |response|
        if response.code == '404' && never_404
          raise DiscourseTheme::ThemeError.new "Error: Incorrect site URL, or API key does not have the correct privileges"
        elsif !['200', '201'].include?(response.code)
          errors = JSON.parse(response.body)["errors"].join(', ') rescue nil
          raise DiscourseTheme::ThemeError.new "Error #{response.code} for #{request.path.split("?")[0]}#{(": " + errors) if errors}"
        end
      end
    rescue Errno::ECONNREFUSED
      raise DiscourseTheme::ThemeError.new "Connection refused for #{request.path}"
    end

    def add_headers(request)
      if @is_theme_creator
        request["User-Api-Key"] = @api_key
      else
        request["Api-Key"] = @api_key
      end
    end

    def guess_url(settings)
      url = ENV['DISCOURSE_URL']
      if url
        UI.progress "Using #{url} from DISCOURSE_URL"
      end

      if !url && settings.url
        url = settings.url
        UI.progress "Using #{url} from #{DiscourseTheme::Cli::SETTINGS_FILE}"
      end

      if !url || @reset
        url = UI.ask("What is the root URL of your Discourse site?", default: url).strip
        url = "http://#{url}" unless url =~ /^https?:\/\//

        # maybe this is an HTTPS redirect
        uri = URI.parse(url)
        if URI::HTTP === uri && uri.port == 80 && is_https_redirect?(url)
          UI.info "Detected that #{url} should be accessed over https"
          url = url.sub("http", "https")
        end

        if UI.yes?("Would you like this site name stored in #{DiscourseTheme::Cli::SETTINGS_FILE}?")
          settings.url = url
        else
          settings.url = nil
        end
      end

      url
    end

    def guess_api_key(settings)
      api_key = ENV['DISCOURSE_API_KEY']
      if api_key
        UI.progress "Using api key from DISCOURSE_API_KEY"
      end

      if !api_key && settings.api_key
        api_key = settings.api_key
        UI.progress "Using api key from #{DiscourseTheme::Cli::SETTINGS_FILE}"
      end

      if !api_key || @reset
        api_key = UI.ask("What is your API key?", default: api_key).strip
        if UI.yes?("Would you like this API key stored in #{DiscourseTheme::Cli::SETTINGS_FILE}?")
          settings.api_key = api_key
        else
          settings.api_key = nil
        end
      end

      api_key
    end

    def is_https_redirect?(url)
      url = URI.parse(url)
      path = url.path
      path = "/" if path.empty?
      req = Net::HTTP::Get.new("/")
      response = Net::HTTP.start(url.host, url.port) { |http| http.request(req) }
      Net::HTTPRedirection === response && response['location'] =~ /^https/i
    end

  end
end
