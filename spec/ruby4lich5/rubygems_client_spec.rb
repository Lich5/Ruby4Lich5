# frozen_string_literal: true

require 'ruby4lich5/rubygems_client'

RSpec.describe Ruby4Lich5::RubygemsClient do
  let(:unused_http_get) { ->(_uri) { raise 'http_get should not have been called' } }

  describe '#versions' do
    it 'parses the versions JSON response into an array of hashes' do
      body = '[{"number":"1.7.3","platform":"ruby"},{"number":"1.7.3","platform":"x64-mingw-ucrt"}]'
      http_get = ->(_uri) { body }
      client = described_class.new(http_get: http_get)

      result = client.versions('sqlite3')

      expect(result).to eq(
        [
          { 'number' => '1.7.3', 'platform' => 'ruby' },
          { 'number' => '1.7.3', 'platform' => 'x64-mingw-ucrt' }
        ]
      )
    end

    it 'requests the expected rubygems.org versions endpoint' do
      requested_uri = nil
      http_get = lambda do |uri|
        requested_uri = uri
        '[]'
      end
      client = described_class.new(http_get: http_get)

      client.versions('sqlite3')

      expect(requested_uri.to_s).to eq('https://rubygems.org/api/v1/versions/sqlite3.json')
    end

    it 'raises RequestError when the response is not valid JSON' do
      http_get = ->(_uri) { 'not json' }
      client = described_class.new(http_get: http_get)

      expect { client.versions('sqlite3') }
        .to raise_error(Ruby4Lich5::RubygemsClient::RequestError, /malformed versions response/)
    end

    it 'raises RequestError when the response is valid JSON but not an array' do
      http_get = ->(_uri) { '{"error":"not found"}' }
      client = described_class.new(http_get: http_get)

      expect { client.versions('sqlite3') }
        .to raise_error(Ruby4Lich5::RubygemsClient::RequestError, /unexpected versions response shape/)
    end

    it 'raises RequestError when the response is an array of non-hash elements' do
      http_get = ->(_uri) { '["not", "a", "hash"]' }
      client = described_class.new(http_get: http_get)

      expect { client.versions('sqlite3') }
        .to raise_error(Ruby4Lich5::RubygemsClient::RequestError, /unexpected versions response shape/)
    end

    it 'raises RequestError when array entries are missing the expected keys' do
      http_get = ->(_uri) { '[{"number":"1.7.3"}]' }
      client = described_class.new(http_get: http_get)

      expect { client.versions('sqlite3') }
        .to raise_error(Ruby4Lich5::RubygemsClient::RequestError, /unexpected versions response shape/)
    end

    it 'raises ArgumentError for a nil gem name without making a request' do
      client = described_class.new(http_get: unused_http_get)

      expect { client.versions(nil) }.to raise_error(ArgumentError, /must not be nil or empty/)
    end

    it 'raises ArgumentError for an empty gem name without making a request' do
      client = described_class.new(http_get: unused_http_get)

      expect { client.versions('') }.to raise_error(ArgumentError, /must not be nil or empty/)
    end

    it 'raises ArgumentError for a gem name containing a path traversal sequence' do
      client = described_class.new(http_get: unused_http_get)

      expect { client.versions('../../etc/passwd') }
        .to raise_error(ArgumentError, /disallowed characters/)
    end
  end

  describe '#download_gem' do
    it 'requests the ruby-platform filename when no platform is given' do
      requested_uri = nil
      http_get = lambda do |uri|
        requested_uri = uri
        'gem bytes'
      end
      client = described_class.new(http_get: http_get)

      client.download_gem('sqlite3', '1.7.3')

      expect(requested_uri.to_s).to eq('https://rubygems.org/downloads/sqlite3-1.7.3.gem')
    end

    it 'requests the platform-qualified filename when a platform is given' do
      requested_uri = nil
      http_get = lambda do |uri|
        requested_uri = uri
        'gem bytes'
      end
      client = described_class.new(http_get: http_get)

      client.download_gem('sqlite3', '1.7.3', platform: 'x64-mingw-ucrt')

      expect(requested_uri.to_s).to eq('https://rubygems.org/downloads/sqlite3-1.7.3-x64-mingw-ucrt.gem')
    end

    it 'writes the response body to a file and returns its path' do
      http_get = ->(_uri) { 'gem bytes' }
      client = described_class.new(http_get: http_get)

      path = client.download_gem('sqlite3', '1.7.3')

      expect(File.read(path)).to eq('gem bytes')
      expect(File.basename(path)).to eq('sqlite3-1.7.3.gem')
    end

    it 'raises ArgumentError for a nil gem name without making a request' do
      client = described_class.new(http_get: unused_http_get)

      expect { client.download_gem(nil, '1.7.3') }.to raise_error(ArgumentError, /must not be nil or empty/)
    end

    it 'raises ArgumentError for a gem name containing a path traversal sequence' do
      client = described_class.new(http_get: unused_http_get)

      expect { client.download_gem('../../etc/passwd', '1.7.3') }
        .to raise_error(ArgumentError, /disallowed characters/)
    end

    it 'raises ArgumentError for a platform containing a path separator' do
      client = described_class.new(http_get: unused_http_get)

      expect { client.download_gem('sqlite3', '1.7.3', platform: '../../etc') }
        .to raise_error(ArgumentError, /disallowed characters/)
    end

    it 'raises ArgumentError for a nil version without making a request' do
      client = described_class.new(http_get: unused_http_get)

      expect { client.download_gem('sqlite3', nil) }.to raise_error(ArgumentError, /must not be nil or empty/)
    end

    it 'raises ArgumentError for an empty version without making a request' do
      client = described_class.new(http_get: unused_http_get)

      expect { client.download_gem('sqlite3', '') }.to raise_error(ArgumentError, /must not be nil or empty/)
    end

    it 'raises ArgumentError for a version that is not RubyGems-correct' do
      client = described_class.new(http_get: unused_http_get)

      expect { client.download_gem('sqlite3', 'not-a-version!!') }
        .to raise_error(ArgumentError, /not a valid RubyGems version/)
    end
  end
end
