# frozen_string_literal: true

require 'base64'
require 'json'
require 'net/http'
require 'uri'

module TeamChat
  # The speech worker is reached only through a local Incus proxy. It receives
  # audio or the already-authorized message text; neither is placed in logs.
  class VoiceClient
    MAX_AUDIO = 4.megabytes
    MAX_TEXT = 4_000
    class Error < StandardError; end

    def self.configured?
      uri = URI.parse(ENV.fetch('RUPERT_VOICE_URL', ''))
      uri.scheme == 'http' && uri.host == '127.0.0.1' && uri.userinfo.nil? && ENV.fetch('RUPERT_VOICE_TOKEN', '').bytesize >= 32
    rescue URI::InvalidURIError
      false
    end

    def transcribe(upload)
      raise Error, 'Choose a recording under 4 MB.' unless upload.respond_to?(:size) && upload.size.to_i.between?(1, MAX_AUDIO)

      audio = upload.read(MAX_AUDIO + 1)
      raise Error, 'Choose a recording under 4 MB.' unless audio && audio.bytesize.between?(1, MAX_AUDIO)
      result = request('/transcribe', audio, 'application/octet-stream')
      text = result['text']
      raise Error, 'The recording could not be transcribed.' unless text.is_a?(String) && text.strip.present? && text.length <= MAX_TEXT

      text.strip
    end

    def speak(text)
      raise Error, 'That message cannot be read aloud.' unless text.is_a?(String) && text.strip.present? && text.length <= MAX_TEXT

      result = request('/speak', JSON.generate(text: text), 'application/json')
      audio = Base64.strict_decode64(result.fetch('audio'))
      raise Error, 'The speech response was invalid.' unless audio.bytesize.between?(44, 16.megabytes) && audio.start_with?('RIFF')

      audio
    rescue KeyError, ArgumentError
      raise Error, 'The speech response was invalid.'
    end

    private

    def request(path, data, content_type)
      raise Error, 'Voice is not configured.' unless self.class.configured?

      uri = URI.parse(ENV.fetch('RUPERT_VOICE_URL'))
      uri.path = path
      uri.query = nil
      request = Net::HTTP::Post.new(uri)
      request['Authorization'] = "Bearer #{ENV.fetch('RUPERT_VOICE_TOKEN')}"
      request['Content-Type'] = content_type
      request.body = data
      response = Net::HTTP.start(uri.host, uri.port, open_timeout: 3, read_timeout: 210) { |http| http.request(request) }
      raise Error, 'Voice is busy. Try again shortly.' if response.code.to_i == 429
      raise Error, 'The speech service could not process that.' unless response.is_a?(Net::HTTPSuccess)
      raise Error, 'The speech response was too large.' if response.body.to_s.bytesize > 24.megabytes

      JSON.parse(response.body)
    rescue JSON::ParserError, IOError, SystemCallError, Timeout::Error, Net::HTTPError
      raise Error, 'The speech service is unavailable.'
    end
  end
end
